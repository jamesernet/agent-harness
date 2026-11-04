import json

import pytest
from conftest import NOW, by_title, file_fetch, write_contract

from opinion_gallery.contract import load_contract
from opinion_gallery.llm import FakeLLM
from opinion_gallery.run import format_report, preflight, run_cycle
from opinion_gallery.state import State

ENV = {}


def _gh():
    seen = []

    def runner(argv):
        seen.append(argv)
        return f"https://github.com/example/repo/issues/{len(seen)}\n"

    runner.seen = seen
    return runner


def test_full_cycle_writes_pieces_issues_and_state(contract, llm, tmp_path):
    gh = _gh()
    report = run_cycle(contract, llm, env=ENV, now=NOW, fetch=file_fetch, gh_runner=gh)
    assert report.feed_errors == [] and report.failures == []
    assert len(report.stories) == 6
    kinds = {r.story.title[:12]: r.outcome.kind for r in report.results}
    assert kinds == {"Regulator pr": "two-views", "Payment proc": "single", "Startup clai": "merged"}
    files = sorted(p.name for p in (tmp_path / "drafts" / "2026-11-03").iterdir())
    assert any(f.endswith("-two-views.md") for f in files)
    assert any(f.endswith("-merged.md") for f in files)
    assert any(f.endswith("-operator.md") for f in files)
    assert "README.md" in files and len(files) == 4
    assert len(gh.seen) == 3 and all(r.issue and r.issue.url for r in report.results)
    st = State.load(tmp_path / "state.json")
    assert len(st.seen) == 6 and any(k.startswith("triage-skeptic-") for k in st.keys)
    assert any(k.startswith("issue-") for k in st.keys)
    injected = by_title(report.stories, "Attention automated")
    assert all(t.stance == 0 for t in report.triages if t.story_id == injected.id)
    readme = (tmp_path / "drafts" / "2026-11-03" / "README.md").read_text()
    assert "Pieces: 3" in readme and "two-views" in readme
    # calls: 3 triage + 5 drafts (skeptic 2, strategist 2, operator 1) + 4 debate + 1 merge
    assert len(llm.calls) == 13


def test_rerun_same_day_is_idempotent(contract, fake_replies, tmp_path):
    gh = _gh()
    run_cycle(contract, FakeLLM(fake_replies), env=ENV, now=NOW, fetch=file_fetch, gh_runner=gh)
    before = sorted(p.name for p in (tmp_path / "drafts" / "2026-11-03").iterdir())
    second = FakeLLM(fake_replies)
    report = run_cycle(contract, second, env=ENV, now=NOW, fetch=file_fetch, gh_runner=gh)
    assert len(second.calls) == 0 and len(gh.seen) == 3
    assert sorted(p.name for p in (tmp_path / "drafts" / "2026-11-03").iterdir()) == before
    assert len(report.results) == 3
    forced = FakeLLM(fake_replies)
    run_cycle(contract, forced, env=ENV, now=NOW, fetch=file_fetch, gh_runner=gh, force=True)
    assert len(forced.calls) == 13


def test_next_day_skips_seen_stories(contract, fake_replies, tmp_path):
    from datetime import timedelta

    run_cycle(contract, FakeLLM(fake_replies), env=ENV, now=NOW, fetch=file_fetch, gh_runner=_gh())
    later = FakeLLM(fake_replies)
    report = run_cycle(contract, later, env=ENV, now=NOW + timedelta(days=1), fetch=file_fetch, gh_runner=_gh())
    assert report.stories == [] and later.calls == []


def test_report_only_touches_nothing(contract, llm, tmp_path):
    gh = _gh()
    report = run_cycle(contract, llm, env=ENV, now=NOW, fetch=file_fetch, gh_runner=gh, report_only=True)
    assert report.report_only and len(report.results) == 3 and len(llm.calls) == 13
    assert not (tmp_path / "drafts").exists() and not (tmp_path / "state.json").exists() and gh.seen == []
    text = format_report(report, contract)
    assert "(report only)" in text and "| skeptic | 5 |" in text


def test_no_issues_flag_and_blank_repo(contract, llm, tmp_path):
    gh = _gh()
    run_cycle(contract, llm, env=ENV, now=NOW, fetch=file_fetch, gh_runner=gh, issues=False)
    assert gh.seen == [] and (tmp_path / "drafts").exists()


def test_two_views_mode_never_merges(tmp_path, fake_replies):
    c = load_contract(write_contract(tmp_path, overrides={"debate": {"outcome": "two-views"}}))
    llm = FakeLLM(fake_replies)
    report = run_cycle(c, llm, env=ENV, now=NOW, fetch=file_fetch, gh_runner=_gh())
    kinds = {r.story.title[:12]: r.outcome.kind for r in report.results}
    assert kinds["Startup clai"] == "single" and len(llm.calls) == 12
    assert not any("task=merge" in call.system for call in llm.calls)


def test_debate_disabled_gives_every_draft_its_own_piece(tmp_path, fake_replies):
    c = load_contract(write_contract(tmp_path, overrides={"debate": {"enabled": False}}))
    report = run_cycle(c, FakeLLM(fake_replies), env=ENV, now=NOW, fetch=file_fetch, gh_runner=_gh())
    assert [r.outcome.kind for r in report.results] == ["single"] * 5


def test_triage_only_stops_before_drafts(contract, llm, tmp_path):
    report = run_cycle(contract, llm, env=ENV, now=NOW, fetch=file_fetch, triage_only=True)
    assert len(llm.calls) == 3 and report.results == [] and len(report.flagged) == 5
    assert not (tmp_path / "state.json").exists()


def test_llm_failure_is_recorded_and_run_continues(contract, fake_replies, tmp_path):
    fake_replies["triage:strategist"] = ["not json at all"]
    report = run_cycle(contract, FakeLLM(fake_replies), env=ENV, now=NOW, fetch=file_fetch, gh_runner=_gh())
    assert any(f.startswith("triage strategist") for f in report.failures)
    assert {r.outcome.kind for r in report.results} == {"single"}  # skeptic alone on A and C, operator on G


def test_gh_failure_leaves_draft_on_disk(contract, llm, tmp_path):
    def broken(argv):
        raise OSError("gh: not logged in")

    report = run_cycle(contract, llm, env=ENV, now=NOW, fetch=file_fetch, gh_runner=broken)
    assert len(report.failures) == 3 and all(r.path and r.path.exists() for r in report.results)


def test_preflight_rules(tmp_path):
    c = load_contract(write_contract(tmp_path))
    assert preflight(c, ENV) == []
    (c.path / "guardrails.md").write_text("# edited\n")
    problems = preflight(load_contract(c.path), ENV)
    assert any("guardrails.md differs" in p for p in problems)
    c2 = load_contract(write_contract(tmp_path / "b", overrides={"review": {"reviewers": []}, "guardrails": {"modified": True}}))
    (c2.path / "guardrails.md").write_text("# edited\n")
    problems = preflight(load_contract(c2.path), ENV)
    assert problems == ["review.reviewers is empty; name who approves before anything runs"]
    c3 = load_contract(write_contract(tmp_path / "c", overrides={"provider": {"kind": "openai", "model": "m", "api_key_env": "K"}}))
    assert any("K" in p for p in preflight(c3, {})) and preflight(c3, {"K": "x"}) == []


def test_preflight_rejects_template_blanks():
    from conftest import STARTER

    problems = preflight(load_contract(STARTER), {"OPENAI_API_KEY": "x"})
    assert any("feed.sources[0].url" in p for p in problems) and any("display_name" in p for p in problems)


def test_failed_merge_keeps_the_debate_round(contract, fake_replies, tmp_path):
    without_merge = {k: v for k, v in fake_replies.items() if k != "merge"}
    first = FakeLLM(without_merge)
    report = run_cycle(contract, first, env=ENV, now=NOW, fetch=file_fetch, gh_runner=_gh())
    assert any(f.startswith("merge on") for f in report.failures)
    assert {r.outcome.kind for r in report.results} == {"two-views", "single"}
    st = State.load(tmp_path / "state.json")
    assert any(k.startswith("debate-") and v["merged_body"] is None for k, v in st.keys.items())
    second = FakeLLM(fake_replies)
    report = run_cycle(contract, second, env=ENV, now=NOW, fetch=file_fetch, gh_runner=_gh())
    assert [c.system.splitlines()[0] for c in second.calls] == ["<!-- opinion_gallery:task=merge persona=skeptic -->"]
    assert report.failures == [] and {r.outcome.kind for r in report.results} == {"two-views", "single", "merged"}
