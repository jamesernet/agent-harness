"""What a rerun may and may not repeat.

Three rules, one per defect in #60. A step that only costs tokens may be redone.
An effect the world can see may not. A record the loader cannot read is redone
rather than raised.
"""

import json
from datetime import timedelta

from conftest import NOW, file_fetch

from opinion_gallery.llm import FakeLLM
from opinion_gallery.run import run_cycle

ENV: dict[str, str] = {}
CALLS_PER_CYCLE = 13  # 3 triage + 5 drafts + 4 debate replies + 1 merge, on the fixture set


def _gh():
    seen = []

    def runner(argv):
        seen.append(argv)
        return f"https://github.com/example/repo/issues/{len(seen)}\n"

    runner.seen = seen
    return runner


def test_force_regenerates_the_content_but_never_files_a_second_issue(contract, fake_replies, tmp_path):
    """--force means redo the thinking, not duplicate the paperwork."""
    gh = _gh()
    first = run_cycle(contract, FakeLLM(fake_replies), env=ENV, now=NOW, fetch=file_fetch, gh_runner=gh)
    filed = {r.story.id: r.issue.url for r in first.results if r.issue}
    assert len(filed) == 3 and len(gh.seen) == 3

    llm = FakeLLM(fake_replies)
    forced = run_cycle(contract, llm, env=ENV, now=NOW, fetch=file_fetch, gh_runner=gh, force=True)

    assert len(llm.calls) == CALLS_PER_CYCLE, "force must redo every model call"
    assert len(gh.seen) == 3, "force must not file a second issue for a story it already filed"
    assert {r.story.id: r.issue.url for r in forced.results if r.issue} == filed


def test_report_only_sees_exactly_what_a_real_run_would_see(contract, fake_replies, tmp_path):
    """A preview that reports stories a real run would skip cannot be used to tune a persona."""
    run_cycle(contract, FakeLLM(fake_replies), env=ENV, now=NOW, fetch=file_fetch, gh_runner=_gh())

    llm = FakeLLM(fake_replies)
    preview = run_cycle(
        contract, llm, env=ENV, now=NOW + timedelta(days=1), fetch=file_fetch, gh_runner=_gh(), report_only=True
    )

    assert preview.stories == [], "every story was seen yesterday, inside skip_seen_days"
    assert llm.calls == [], "a preview of nothing must cost nothing"


def test_a_record_the_loader_cannot_read_is_redone_not_raised(contract, fake_replies, tmp_path):
    """A state file written by an older shape of this package must not stop a run."""
    run_cycle(contract, FakeLLM(fake_replies), env=ENV, now=NOW, fetch=file_fetch, gh_runner=_gh())

    path = tmp_path / "state.json"
    data = json.loads(path.read_text())
    rewritten = 0
    for key, record in list(data["keys"].items()):
        if "triage" in key:
            data["keys"][key] = {"written_by": "a shape this version does not know"}
            rewritten += 1
    assert rewritten, "expected triage records to rewrite"
    path.write_text(json.dumps(data))

    llm = FakeLLM(fake_replies)
    report = run_cycle(contract, llm, env=ENV, now=NOW, fetch=file_fetch, gh_runner=_gh())

    assert report.failures == []
    assert len(llm.calls) >= rewritten, "the unreadable records must be redone"
    assert report.results, "the run must still produce its pieces"
