"""One cycle: fetch, triage, draft, debate, deliver. The only module that wires I/O to the pipeline."""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Mapping
from zoneinfo import ZoneInfo

from . import delivery, feeds, pipeline, state as state_mod
from .config import ConfigError, is_blank
from .contract import Contract, ContractError
from .feeds import Fetcher, Story
from .ledger import Ledger
from .llm import LLM
from .pipeline import Draft, Outcome, Reply, Triage


@dataclass
class StoryResult:
    story: Story
    outcome: Outcome
    left_out: list[str] = field(default_factory=list)
    path: Path | None = None
    issue: delivery.IssueRef | None = None


@dataclass
class RunReport:
    day: date
    report_only: bool
    stories: list[Story] = field(default_factory=list)
    feed_errors: list[str] = field(default_factory=list)
    triages: list[Triage] = field(default_factory=list)
    results: list[StoryResult] = field(default_factory=list)
    failures: list[str] = field(default_factory=list)

    @property
    def flagged(self) -> list[Triage]:
        return [t for t in self.triages if t.flagged]


def preflight(contract: Contract, env: Mapping[str, str]) -> list[str]:
    """Everything that must be true before a network call. Returns problems; empty means go."""
    cfg = contract.config
    problems: list[str] = []
    if not cfg.review.reviewers or all(is_blank(r) for r in cfg.review.reviewers):
        problems.append("review.reviewers is empty; name who approves before anything runs")
    if not contract.guardrails_match_shipped and not cfg.guardrails.modified:
        problems.append("guardrails.md differs from the shipped copy; set guardrails.modified: true and say why in shared.md")
    for b in cfg.blanks():
        if b.startswith(("org.name", "feed.sources", "provider.model", "review.reviewers")):
            if b == "provider.model" and cfg.provider.kind == "fake":
                continue
            problems.append(f"{b} is still a template blank")
    problems.extend(f"{b} is still a template blank" for b in contract.persona_blanks())
    try:
        cfg.api_key(env)
    except ConfigError as e:
        problems.append(str(e))
    return problems


def _today(cfg_tz: str, now: datetime) -> date:
    return now.astimezone(ZoneInfo(cfg_tz)).date()


def run_cycle(
    contract: Contract,
    llm: LLM,
    *,
    env: Mapping[str, str],
    now: datetime | None = None,
    report_only: bool = False,
    issues: bool = True,
    force: bool = False,
    triage_only: bool = False,
    personas: list[str] | None = None,
    fetch: Fetcher | None = None,
    gh_runner: delivery.Runner | None = None,
) -> RunReport:
    cfg = contract.config
    fetch = fetch or feeds.http_fetch
    gh_runner = gh_runner or delivery.subprocess_runner
    now = now or datetime.now(timezone.utc)
    day = _today(cfg.run.timezone, now)
    writing = not (report_only or triage_only)
    report = RunReport(day=day, report_only=not writing)

    # State is always read, so a preview selects the stories a real run would
    # select. Only a writing run records anything.
    st = state_mod.State.load(Path(cfg.run.state_file))
    ledger = Ledger(state=st, day=day, failures=report.failures, writable=writing)
    if force:
        ledger.forget_redoable()

    selected = _select(cfg, st, fetch, now, report)
    if not selected:
        return report

    picks = _triage(contract, llm, ledger, selected, personas, report)
    if triage_only:
        return report

    for story in selected:
        flags = picks.get(story.id)
        if not flags:
            continue
        drafts = _draft(contract, llm, ledger, story, flags)
        if not drafts:
            continue
        for outcome, left_out in _settle(contract, llm, ledger, story, drafts):
            result = StoryResult(story=story, outcome=outcome, left_out=left_out)
            report.results.append(result)
            if outcome.kind != "none" and writing:
                _publish(contract, ledger, story, result, now, issues=issues, gh_runner=gh_runner, env=env)

    if writing:
        st.mark_seen([s.id for s in selected], day)
        if report.results:
            readme = Path(cfg.output.drafts_dir) / day.isoformat() / "README.md"
            delivery.write_piece(readme, format_report(report, contract))
        st.save()
    return report


def _select(cfg, st: state_mod.State, fetch: Fetcher, now: datetime, report: RunReport) -> list[Story]:
    """Every story worth reading today: recent, not recently seen, newest first."""
    stories, report.feed_errors = feeds.fetch_all(cfg.feed.sources, fetch=fetch, summary_chars=cfg.feed.summary_chars)
    report.stories = feeds.select(
        stories,
        now=now,
        lookback_hours=cfg.feed.lookback_hours,
        seen=st.seen,
        skip_seen_days=cfg.feed.skip_seen_days,
        max_stories=cfg.feed.max_stories,
    )
    return report.stories


def _triage(
    contract: Contract,
    llm: LLM,
    ledger: Ledger,
    selected: list[Story],
    personas: list[str] | None,
    report: RunReport,
) -> dict[str, list[Triage]]:
    """One call per persona, and the flags it would write about, by story."""
    by_id = {s.id: s for s in selected}
    picks: dict[str, list[Triage]] = {}
    for persona in contract.enabled_personas():
        if personas is not None and persona.name not in personas:
            continue
        triages = ledger.once(
            "triage",
            persona.name,
            produce=lambda p=persona: pipeline.triage_persona(llm, contract, p, selected),
            decode=lambda rows: [Triage(**row) for row in rows if row["story_id"] in by_id],
            encode=lambda ts: [t.__dict__ for t in ts],
        )
        if triages is None:
            continue
        report.triages.extend(triages)
        for flag in pipeline.select_flags(triages, contract.config.personas.max_drafts_per_persona):
            picks.setdefault(flag.story_id, []).append(flag)
    return picks


def _draft(contract: Contract, llm: LLM, ledger: Ledger, story: Story, flags: list[Triage]) -> list[Draft]:
    """A piece from each persona that flagged this story, strongest first."""
    drafts: list[Draft] = []
    for flag in sorted(flags, key=lambda f: (f.stance, f.weight), reverse=True):
        draft = ledger.once(
            "draft",
            flag.persona,
            story.id,
            produce=lambda p=contract.personas[flag.persona], f=flag: pipeline.write_draft(llm, contract, p, story, f),
            decode=lambda value: Draft(**value),
            encode=lambda d: d.__dict__,
        )
        if draft is not None:
            drafts.append(draft)
    return drafts


def _settle(
    contract: Contract, llm: LLM, ledger: Ledger, story: Story, drafts: list[Draft]
) -> list[tuple[Outcome, list[str]]]:
    """What gets published: one piece each, or one debate and whatever survives it."""
    cfg = contract.config
    if len(drafts) == 1 or not cfg.debate.enabled:
        return [(Outcome("single", [d]), []) for d in drafts]

    participants = drafts[: cfg.debate.max_participants]
    left_out = [d.persona for d in drafts[cfg.debate.max_participants :]]
    replies = ledger.once(
        "debate",
        story.id,
        produce=lambda: pipeline.debate_round(llm, contract, story, participants),
        decode=lambda rows: [Reply(**row) for row in rows],
        encode=lambda rs: [r.__dict__ for r in rs],
    )
    if replies is None:
        return []

    outcome = pipeline.resolve_debate(participants, replies, cfg.debate.outcome)
    if outcome.kind == "merged":
        merged = ledger.once(
            "merge",
            story.id,
            produce=lambda: pipeline.merge(llm, contract, story, outcome),
        )
        if merged is None:
            return []
        outcome.merged_body = merged
    return [(outcome, left_out)]


def _publish(
    contract: Contract,
    ledger: Ledger,
    story: Story,
    result: StoryResult,
    now: datetime,
    *,
    issues: bool,
    gh_runner: delivery.Runner,
    env: Mapping[str, str],
) -> None:
    """The piece to disk, and at most one issue per piece, ever."""
    cfg = contract.config
    outcome = result.outcome
    text = delivery.render(contract, story, outcome, now)
    path = delivery.piece_path(Path(cfg.output.drafts_dir), ledger.day, story, outcome)
    result.path = delivery.write_piece(path, text)

    repo = cfg.github_repo(env)
    if not (issues and repo):
        return
    # A single piece is named by its persona, so two personas writing separately
    # about one story do not share a record.
    parts = [story.id, outcome.kind]
    if outcome.kind == "single":
        parts.append(outcome.drafts[0].persona)
    result.issue = ledger.once(
        "issue",
        *parts,
        produce=lambda: delivery.open_issue(
            gh_runner,
            repo=repo,
            title=f"[opinion-gallery {ledger.day.isoformat()}] {story.title}",
            body=text,
            labels=cfg.output.github.labels,
            assignees=[a for a in cfg.output.github.assignees if not is_blank(a)],
        ),
        decode=lambda value: delivery.IssueRef(**value),
        encode=lambda ref: ref.__dict__,
        external=True,
        catching=(Exception,),
    )


def format_report(report: RunReport, contract: Contract) -> str:
    lines = [f"# Opinion gallery run {report.day.isoformat()}" + (" (report only)" if report.report_only else ""), ""]
    lines.append(f"Stories read: {len(report.stories)}. Flags: {len(report.flagged)}. Pieces: {len(report.results)}.")
    if report.feed_errors:
        lines += ["", "Feeds that failed:"] + [f"- {e}" for e in report.feed_errors]
    if report.failures:
        lines += ["", "Steps that failed:"] + [f"- {e}" for e in report.failures]
    by_id = {s.id: s for s in report.stories}
    if report.triages:
        lines += ["", "| persona | stance | section | story | reason |", "|---|---|---|---|---|"]
        for t in sorted(report.triages, key=lambda t: (-t.stance, t.persona)):
            if t.stance == 0:
                continue
            title = by_id[t.story_id].title if t.story_id in by_id else t.story_id
            lines.append(f"| {t.persona} | {t.stance} | {t.section} | {title[:60]} | {t.reason[:80]} |")
    if report.results:
        lines += ["", "Pieces:"]
        for r in report.results:
            who = ", ".join(contract.personas[d.persona].display_name for d in r.outcome.drafts) or "nobody"
            extra = f" (left out of the debate: {', '.join(r.left_out)})" if r.left_out else ""
            where = f" -> {r.path}" if r.path else ""
            issue = f" issue {r.issue.url}" if r.issue else ""
            lines.append(f"- {r.outcome.kind}: {r.story.title[:70]} by {who}{extra}{where}{issue}")
    return "\n".join(lines) + "\n"
