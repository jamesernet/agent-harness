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
from .llm import LLM, LLMError
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
    stories: list[Story] | None = None,
) -> RunReport:
    cfg = contract.config
    fetch = fetch or feeds.http_fetch
    gh_runner = gh_runner or delivery.subprocess_runner
    now = now or datetime.now(timezone.utc)
    day = _today(cfg.run.timezone, now)
    writing = not (report_only or triage_only)
    st = state_mod.State.load(Path(cfg.run.state_file)) if writing else state_mod.State(path=None)
    if force:
        st.keys = {k: v for k, v in st.keys.items() if not k.endswith(day.isoformat())}
    report = RunReport(day=day, report_only=not writing)

    # 1-3. fetch, identify, select
    if stories is None:
        stories, report.feed_errors = feeds.fetch_all(cfg.feed.sources, fetch=fetch, summary_chars=cfg.feed.summary_chars)
    selected = feeds.select(
        stories,
        now=now,
        lookback_hours=cfg.feed.lookback_hours,
        seen=st.seen,
        skip_seen_days=cfg.feed.skip_seen_days,
        max_stories=cfg.feed.max_stories,
    )
    report.stories = selected
    by_id = {s.id: s for s in selected}
    if not selected:
        return report

    # 4. triage
    enabled = [p for p in contract.enabled_personas() if personas is None or p.name in personas]
    flags_by_story: dict[str, list[Triage]] = {}
    for persona in enabled:
        key = state_mod.triage_key(persona.name, day)
        cached = st.get(key)
        if cached is not None:
            triages = [Triage(**row) for row in cached if row["story_id"] in by_id]
        else:
            try:
                triages = pipeline.triage_persona(llm, contract, persona, selected)
            except LLMError as e:
                report.failures.append(f"triage {persona.name}: {e}")
                continue
            st.set(key, [t.__dict__ for t in triages])
            st.save()
        report.triages.extend(triages)
        for t in pipeline.select_flags(triages, cfg.personas.max_drafts_per_persona):
            flags_by_story.setdefault(t.story_id, []).append(t)
    if triage_only:
        return report

    # 5-7. draft, debate, deliver, story by story in selection order
    for story in selected:
        flags = flags_by_story.get(story.id)
        if not flags:
            continue
        drafts: list[Draft] = []
        for t in sorted(flags, key=lambda t: (t.stance, t.weight), reverse=True):
            persona = contract.personas[t.persona]
            key = state_mod.draft_key(t.persona, story.id, day)
            cached = st.get(key)
            if cached is not None:
                drafts.append(Draft(**cached))
                continue
            try:
                d = pipeline.write_draft(llm, contract, persona, story, t)
            except LLMError as e:
                report.failures.append(f"draft {t.persona} on {story.id}: {e}")
                continue
            st.set(key, d.__dict__)
            st.save()
            drafts.append(d)
        if not drafts:
            continue

        outcomes: list[tuple[Outcome, list[str]]] = []
        if len(drafts) == 1 or not cfg.debate.enabled:
            outcomes = [(Outcome("single", [d]), []) for d in drafts]
        else:
            participants = drafts[: cfg.debate.max_participants]
            left_out = [d.persona for d in drafts[cfg.debate.max_participants :]]
            key = state_mod.debate_key(story.id, day)
            cached = st.get(key) or {}
            if cached:
                replies = [Reply(**r) for r in cached["replies"]]
            else:
                try:
                    replies = pipeline.debate_round(llm, contract, story, participants)
                except LLMError as e:
                    report.failures.append(f"debate on {story.id}: {e}")
                    continue
                st.set(key, {"replies": [r.__dict__ for r in replies], "merged_body": None})
                st.save()
            outcome = pipeline.resolve_debate(participants, replies, cfg.debate.outcome)
            if outcome.kind == "merged":
                merged_body = cached.get("merged_body")
                if merged_body is None:
                    try:
                        merged_body = pipeline.merge(llm, contract, story, outcome)
                    except LLMError as e:
                        report.failures.append(f"merge on {story.id}: {e}")
                        continue
                    st.set(key, {"replies": [r.__dict__ for r in replies], "merged_body": merged_body})
                    st.save()
                outcome.merged_body = merged_body
            outcomes = [(outcome, left_out)]

        for outcome, left_out in outcomes:
            result = StoryResult(story=story, outcome=outcome, left_out=left_out)
            report.results.append(result)
            if outcome.kind == "none" or not writing:
                continue
            path = delivery.piece_path(Path(cfg.output.drafts_dir), day, story, outcome)
            text = delivery.render(contract, story, outcome, now)
            result.path = delivery.write_piece(path, text)
            repo = cfg.github_repo(env)
            if issues and repo:
                ikey = state_mod.issue_key(story.id, day) + ("" if outcome.kind != "single" else f"-{outcome.drafts[0].persona}")
                cached = st.get(ikey)
                if cached is not None:
                    result.issue = delivery.IssueRef(**cached)
                else:
                    try:
                        result.issue = delivery.open_issue(
                            gh_runner,
                            repo=repo,
                            title=f"[newsroom {day.isoformat()}] {story.title}",
                            body=text,
                            labels=cfg.output.github.labels,
                            assignees=[a for a in cfg.output.github.assignees if not is_blank(a)],
                        )
                    except Exception as e:  # gh missing, auth, network: the draft is on disk either way
                        report.failures.append(f"issue for {story.id}: {e}")
                    else:
                        st.set(ikey, result.issue.__dict__)
                        st.save()

    if writing:
        st.mark_seen([s.id for s in selected], day)
        if report.results:
            readme = Path(cfg.output.drafts_dir) / day.isoformat() / "README.md"
            delivery.write_piece(readme, format_report(report, contract))
        st.save()
    return report


def format_report(report: RunReport, contract: Contract) -> str:
    lines = [f"# Newsroom run {report.day.isoformat()}" + (" (report only)" if report.report_only else ""), ""]
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
