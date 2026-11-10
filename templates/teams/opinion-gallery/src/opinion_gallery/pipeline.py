"""The steps between a story list and a piece. Pure over an LLM: no disk, no network."""

from __future__ import annotations

from dataclasses import dataclass, replace

from . import prompts
from .contract import Contract, Persona
from .feeds import Story
from .llm import LLM, complete_json


@dataclass
class Triage:
    persona: str
    story_id: str
    section: str
    stance: int
    reason: str
    weight: int = 0
    flagged: bool = False


@dataclass
class Draft:
    persona: str
    story_id: str
    section: str
    stance: int
    reason: str
    body: str


@dataclass
class Reply:
    persona: str
    decision: str
    reply: str
    revised_draft: str | None = None


@dataclass(frozen=True)
class Outcome:
    """What gets published about one story, and the only thing that decides it.

    Frozen on purpose: an outcome is complete when the module that settled it
    returns it. A merged piece arrives incomplete exactly once, and `with_merged`
    is the only way to finish it.
    """

    kind: str  # single | two-views | merged | none
    drafts: tuple[Draft, ...] = ()
    replies: tuple[Reply, ...] = ()
    merged_body: str | None = None
    withdrew: tuple[str, ...] = ()

    @property
    def needs_merge(self) -> bool:
        """A merged piece whose body has not been written yet."""
        return self.kind == "merged" and not self.merged_body

    def with_merged(self, body: str) -> "Outcome":
        return replace(self, merged_body=body)

    def reply_from(self, persona: str) -> Reply | None:
        """What this persona said after reading the others, if it said anything."""
        return next((r for r in self.replies if r.persona == persona), None)

    @property
    def publishable(self) -> bool:
        return bool(self.drafts)


def triage_persona(llm: LLM, contract: Contract, persona: Persona, stories: list[Story]) -> list[Triage]:
    """One call: every story judged by one persona, with the runtime's rules applied."""
    cfg = contract.config
    data = complete_json(
        llm,
        prompts.system_prompt(contract, persona, "triage"),
        prompts.triage_user(stories, cfg.feed.sections, persona),
        prompts.TRIAGE_SCHEMA,
        max_tokens=cfg.provider.max_tokens.get("triage", 2048),
    )
    by_id = {s.id: s for s in stories}
    threshold = persona.threshold(cfg.personas.draft_threshold)
    out: dict[str, Triage] = {}
    for row in data["stories"]:
        if row["id"] not in by_id or row["id"] in out:
            continue
        section = str(row["section"]).upper()
        if section not in cfg.feed.sections:
            section = cfg.feed.sections[0]
        weight = persona.weight(section)
        stance = int(row["stance"])
        if weight == 0:
            stance = min(stance, 2)
        out[row["id"]] = Triage(
            persona=persona.name,
            story_id=row["id"],
            section=section,
            stance=stance,
            reason=str(row["reason"]).strip(),
            weight=weight,
            flagged=stance >= threshold,
        )
    for sid in by_id:
        out.setdefault(sid, Triage(persona=persona.name, story_id=sid, section=cfg.feed.sections[0], stance=0, reason="not rated"))
    return [out[s.id] for s in stories]


def select_flags(triages: list[Triage], max_drafts: int) -> list[Triage]:
    flagged = [t for t in triages if t.flagged]
    flagged.sort(key=lambda t: (t.stance, t.weight), reverse=True)
    return flagged[:max_drafts]


def write_draft(llm: LLM, contract: Contract, persona: Persona, story: Story, triage: Triage) -> Draft:
    body = llm.complete(
        prompts.system_prompt(contract, persona, "draft"),
        prompts.draft_user(story, triage.section, triage.stance, triage.reason),
        max_tokens=contract.config.provider.max_tokens.get("draft", 4096),
    )
    return Draft(persona.name, story.id, triage.section, triage.stance, triage.reason, body.strip())


def debate_round(llm: LLM, contract: Contract, story: Story, drafts: list[Draft]) -> list[Reply]:
    """Each participant reads the others once and answers stand, revise or withdraw."""
    cfg = contract.config
    replies: list[Reply] = []
    for d in drafts:
        persona = contract.personas[d.persona]
        others = [(contract.personas[o.persona].display_name, o.body) for o in drafts if o is not d]
        data = complete_json(
            llm,
            prompts.system_prompt(contract, persona, "debate"),
            prompts.debate_user(story, d.body, others, cfg.debate.max_words_per_reply),
            prompts.DEBATE_SCHEMA,
            max_tokens=cfg.provider.max_tokens.get("debate", 4096),
        )
        revised = data.get("revised_draft") or None
        replies.append(Reply(d.persona, data["decision"], str(data["reply"]).strip(), revised.strip() if revised else None))
    return replies


def resolve_debate(drafts: list[Draft], replies: list[Reply], outcome_mode: str) -> Outcome:
    """Who is left standing decides the shape. Pure."""
    by_persona = {r.persona: r for r in replies}
    standing: list[Draft] = []
    withdrew: list[str] = []
    for d in drafts:
        r = by_persona.get(d.persona)
        if r is None or r.decision == "withdraw":
            withdrew.append(d.persona)
            continue
        if r.decision == "revise" and r.revised_draft:
            d = Draft(d.persona, d.story_id, d.section, d.stance, d.reason, r.revised_draft)
        standing.append(d)
    standing.sort(key=lambda d: d.stance, reverse=True)
    settled, spoke, gone = tuple(standing), tuple(replies), tuple(withdrew)
    if len(settled) >= 2:
        return Outcome("two-views", settled, spoke, withdrew=gone)
    if len(settled) == 1:
        kind = "merged" if outcome_mode == "auto" and gone else "single"
        return Outcome(kind, settled, spoke, withdrew=gone)
    return Outcome("none", (), spoke, withdrew=gone)


def merge(llm: LLM, contract: Contract, story: Story, outcome: Outcome) -> str:
    survivor = outcome.drafts[0]
    persona = contract.personas[survivor.persona]
    concessions = [
        (contract.personas[r.persona].display_name, r.reply) for r in outcome.replies if r.persona in outcome.withdrew
    ]
    body = llm.complete(
        prompts.system_prompt(contract, persona, "merge"),
        prompts.merge_user(story, survivor.body, concessions),
        max_tokens=contract.config.provider.max_tokens.get("draft", 4096),
    )
    return body.strip()
