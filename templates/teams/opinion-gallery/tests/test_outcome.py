"""Who owns a settled outcome.

One module decides what a piece is. Rendering is total over every kind it can
receive, rather than total because the caller happened to filter first. Nothing
mutates an outcome after the module that owns it has returned it.
"""

import dataclasses

import pytest
from conftest import NOW

from opinion_gallery import delivery
from opinion_gallery.pipeline import Draft, Outcome, Reply, resolve_debate


def _draft(persona: str, stance: int = 4) -> Draft:
    return Draft(persona, "story-id", "SCIENCE", stance, "a reason", "# Headline\n\nBody.")


def test_rendering_the_empty_outcome_is_safe_without_a_caller_filtering_first(contract, stories):
    """The gallery writes nothing when every persona withdrew. Asking for that
    piece must say so, not raise."""
    empty = resolve_debate(
        [_draft("skeptic", 5), _draft("strategist", 4)],
        [Reply("skeptic", "withdraw", "conceded"), Reply("strategist", "withdraw", "also conceded")],
        "auto",
    )
    assert empty.kind == "none"
    assert delivery.render(contract, stories[0], empty, NOW) is None


def test_an_outcome_cannot_be_completed_by_mutation(contract, stories):
    """The merged body arrives through the owner, not by assignment from outside."""
    settled = resolve_debate(
        [_draft("skeptic", 5), _draft("strategist", 4)],
        [Reply("skeptic", "stand", "I stand."), Reply("strategist", "withdraw", "conceded")],
        "auto",
    )
    assert settled.kind == "merged" and settled.needs_merge

    with pytest.raises(dataclasses.FrozenInstanceError):
        settled.merged_body = "# Assigned from outside"

    completed = settled.with_merged("# Merged\n\nBody.")
    assert completed.merged_body == "# Merged\n\nBody." and not completed.needs_merge
    assert settled.needs_merge, "completing an outcome must leave the original alone"


def test_a_reply_is_looked_up_on_the_outcome_that_owns_it():
    settled = resolve_debate(
        [_draft("skeptic", 5), _draft("strategist", 4)],
        [Reply("skeptic", "stand", "I stand."), Reply("strategist", "stand", "So do I.")],
        "auto",
    )
    assert settled.reply_from("skeptic").reply == "I stand."
    assert settled.reply_from("nobody") is None


def test_a_complete_outcome_never_reports_needing_a_merge():
    for kind in ("single", "two-views", "none"):
        assert not Outcome(kind, (_draft("skeptic"),)).needs_merge
    assert Outcome("merged", (_draft("skeptic"),), merged_body="# done").needs_merge is False


def _gh():
    seen = []

    def runner(argv):
        seen.append(argv)
        return f"https://github.com/example/repo/issues/{len(seen)}\n"

    runner.seen = seen
    return runner


def test_a_story_everyone_withdrew_from_reaches_publishing_and_writes_nothing(contract, fake_replies, tmp_path):
    """The empty kind now goes through the publish step rather than being filtered
    out before it, which is what makes rendering's totality load-bearing."""
    import json

    from conftest import file_fetch

    from opinion_gallery.llm import FakeLLM
    from opinion_gallery.run import run_cycle

    withdrawn = json.dumps({"decision": "withdraw", "reply": "conceded", "revised_draft": None})
    replies = dict(fake_replies) | {"debate:skeptic": [withdrawn], "debate:strategist": [withdrawn]}

    gh = _gh()
    report = run_cycle(contract, FakeLLM(replies), env={}, now=NOW, fetch=file_fetch, gh_runner=gh)

    empty = [r for r in report.results if r.outcome.kind == "none"]
    assert empty, "the fixture set has a story two personas both flag"
    assert all(r.path is None and r.issue is None for r in empty)
    written = {p.name for p in (tmp_path / "drafts" / "2026-11-03").iterdir()}
    assert not any(name.startswith(empty[0].story.id) for name in written)
    assert report.failures == []
