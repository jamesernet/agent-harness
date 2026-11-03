import json

import pytest
from conftest import by_title

from newsroom import pipeline, prompts
from newsroom.llm import FakeLLM
from newsroom.pipeline import Draft, Reply, resolve_debate


def test_triage_applies_runtime_rules(contract, stories):
    skeptic = contract.personas["skeptic"]
    a, b, c = stories[0], stories[1], stories[2]
    reply = json.dumps(
        {
            "stories": [
                {"id": a.id, "section": "science", "stance": 5, "reason": "r"},
                {"id": b.id, "section": "LOCAL", "stance": 5, "reason": "weight 0 section"},
                {"id": "nope", "section": "SCIENCE", "stance": 5, "reason": "unknown id"},
                {"id": a.id, "section": "SCIENCE", "stance": 1, "reason": "duplicate id ignored"},
                {"id": c.id, "section": "MARKETS", "stance": 3, "reason": "unknown section"},
            ]
        }
    )
    fake = FakeLLM({"triage": [reply]})
    out = pipeline.triage_persona(fake, contract, skeptic, stories[:4])
    by_id = {t.story_id: t for t in out}
    assert by_id[a.id].stance == 5 and by_id[a.id].section == "SCIENCE" and by_id[a.id].flagged
    assert by_id[b.id].stance == 2 and not by_id[b.id].flagged  # capped by weight 0
    assert by_id[c.id].section == "BUSINESS"  # unknown section -> first declared
    assert by_id[stories[3].id].stance == 0 and by_id[stories[3].id].reason == "not rated"
    assert len(out) == 4 and "nope" not in by_id
    assert fake.calls[0].system.startswith("<!-- newsroom:task=triage persona=skeptic -->")
    assert "<<<ITEM" in fake.calls[0].user and "ITEM>>>" in fake.calls[0].user


def test_persona_threshold_override(contract, stories):
    strategist = contract.personas["strategist"]
    strategist.draft_threshold = 5
    reply = json.dumps({"stories": [{"id": stories[0].id, "section": "POLICY", "stance": 4, "reason": "r"}]})
    out = pipeline.triage_persona(FakeLLM({"triage": [reply]}), contract, strategist, stories[:1])
    assert not out[0].flagged


def test_select_flags_orders_by_stance_then_weight():
    T = pipeline.Triage
    ts = [
        T("p", "a", "X", 4, "", weight=1, flagged=True),
        T("p", "b", "X", 5, "", weight=1, flagged=True),
        T("p", "c", "X", 4, "", weight=3, flagged=True),
        T("p", "d", "X", 3, "", weight=3, flagged=False),
    ]
    assert [t.story_id for t in pipeline.select_flags(ts, 2)] == ["b", "c"]


def _d(p, stance=4, body="# h\n\nbody"):
    return Draft(p, "s", "X", stance, "r", body)


@pytest.mark.parametrize(
    "decisions,mode,kind,standing",
    [
        (("stand", "stand"), "auto", "two-views", ["a", "b"]),
        (("stand", "revise"), "auto", "two-views", ["a", "b"]),
        (("stand", "withdraw"), "auto", "merged", ["a"]),
        (("stand", "withdraw"), "two-views", "single", ["a"]),
        (("withdraw", "withdraw"), "auto", "none", []),
        (("withdraw", "stand"), "auto", "merged", ["b"]),
    ],
)
def test_resolve_debate_table(decisions, mode, kind, standing):
    drafts = [_d("a", 5), _d("b", 4)]
    replies = [Reply("a", decisions[0], "ra", "# revised a" if decisions[0] == "revise" else None), Reply("b", decisions[1], "rb", "# revised b" if decisions[1] == "revise" else None)]
    out = resolve_debate(drafts, replies, mode)
    assert out.kind == kind and [d.persona for d in out.drafts] == standing
    if "revise" in decisions:
        assert any(d.body.startswith("# revised") for d in out.drafts)


def test_resolve_debate_three_participants_keeps_top_two_first():
    drafts = [_d("a", 4), _d("b", 5), _d("c", 4)]
    replies = [Reply(p, "stand", "") for p in "abc"]
    out = resolve_debate(drafts, replies, "auto")
    assert out.kind == "two-views" and out.drafts[0].persona == "b" and len(out.drafts) == 3


def test_debate_round_and_merge_prompts(contract, stories, llm):
    story = stories[0]
    drafts = [_d("skeptic", 5), _d("strategist", 4)]
    replies = pipeline.debate_round(llm, contract, story, drafts)
    assert [r.decision for r in replies] == ["stand", "stand"]
    call = llm.calls[0]
    assert "<<<DRAFT by The Long View" in call.user and "DRAFT>>>" in call.user
    assert call.system.startswith("<!-- newsroom:task=debate persona=skeptic -->")
    out = resolve_debate(drafts, [Reply("skeptic", "stand", "x"), Reply("strategist", "withdraw", "conceded")], "auto")
    body = pipeline.merge(llm, contract, story, out)
    assert body.startswith("# ") and "conceded" in llm.calls[-1].user


def test_prompt_assembly_order(contract):
    p = contract.personas["skeptic"]
    s = prompts.system_prompt(contract, p, "triage")
    assert s.index("# Guardrails") < s.index("# Org brief") < s.index("# Persona: The Evidence Desk")
