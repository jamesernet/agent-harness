"""Pieces become files, and optionally issues. Nothing here publishes."""

from __future__ import annotations

import re
import subprocess
import tempfile
from dataclasses import dataclass
from datetime import date, datetime
from pathlib import Path
from typing import Callable

import yaml

from .contract import Contract
from .feeds import Story
from .pipeline import Outcome

Runner = Callable[[list[str]], str]


def slugify(text: str, limit: int = 48) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return s[:limit].rstrip("-") or "story"


def split_headline(body: str, fallback: str) -> tuple[str, str]:
    lines = body.strip().splitlines()
    if lines and lines[0].startswith("# "):
        return lines[0][2:].strip(), "\n".join(lines[1:]).strip()
    return fallback, body.strip()


def disclosure(contract: Contract, display_name: str) -> str:
    return contract.config.output.disclosure.format_map({"display_name": display_name, "org": contract.config.org_name})


def _frontmatter(fields: dict) -> str:
    return "---\n" + yaml.safe_dump(fields, sort_keys=False, allow_unicode=True) + "---\n"


def _source_line(story: Story) -> str:
    when = story.published.date().isoformat() if story.published else "undated"
    return f"---\nSource: {story.title}, {story.source}, {when}. {story.link}\n"


def _common(contract: Contract, story: Story, run_at: datetime) -> dict:
    return {
        "contract": contract.name,
        "story_id": story.id,
        "story_title": story.title,
        "story_url": story.link,
        "source": story.source,
        "story_date": story.published.date().isoformat() if story.published else None,
        "run": run_at.isoformat(timespec="seconds"),
        "status": "unreviewed",
    }


def render_single(contract: Contract, story: Story, outcome: Outcome, run_at: datetime) -> str:
    d = outcome.drafts[0]
    name = contract.personas[d.persona].display_name
    headline, body = split_headline(d.body, story.title)
    fm = {"kind": "draft", "persona": d.persona, "display_name": name, **_common(contract, story, run_at), "stance": d.stance, "reason": d.reason}
    return f"{_frontmatter(fm)}\n> {disclosure(contract, name)}\n\n# {headline}\n\n{body}\n\n{_source_line(story)}"


def render_two_views(contract: Contract, story: Story, outcome: Outcome, run_at: datetime) -> str:
    names = [contract.personas[d.persona].display_name for d in outcome.drafts]
    fm = {
        "kind": "two-views",
        "personas": [d.persona for d in outcome.drafts],
        **_common(contract, story, run_at),
        "stances": {d.persona: d.stance for d in outcome.drafts},
        "withdrew": list(outcome.withdrew),
    }
    sections = []
    for i, d in enumerate(outcome.drafts):
        name = contract.personas[d.persona].display_name
        headline, body = split_headline(d.body, story.title)
        label = "Also weighing in" if i >= 2 else name
        sections.append(f"## {label}: {headline}\n\n{body}")
        r = outcome.reply_from(d.persona)
        if r and r.reply:
            sections.append(f"### {name}, after reading the other view\n\n{r.reply}")
    joined = "\n\n".join(sections)
    who = " and ".join(names[:2]) + (f" and {len(names) - 2} more" if len(names) > 2 else "")
    return f"{_frontmatter(fm)}\n> {disclosure(contract, who)}\n\n# {story.title}\n\n{joined}\n\n{_source_line(story)}"


def render_merged(contract: Contract, story: Story, outcome: Outcome, run_at: datetime) -> str:
    d = outcome.drafts[0]
    name = contract.personas[d.persona].display_name
    others = [contract.personas[p].display_name for p in outcome.withdrew]
    headline, body = split_headline(outcome.merged_body or d.body, story.title)
    fm = {
        "kind": "merged",
        "persona": d.persona,
        "display_name": name,
        "merged_after_debate_with": list(outcome.withdrew),
        **_common(contract, story, run_at),
        "stance": d.stance,
    }
    note = f"\n\n---\nMerged after a debate with {', '.join(others)}, who withdrew.\n" if others else "\n"
    return f"{_frontmatter(fm)}\n> {disclosure(contract, name)}\n\n# {headline}\n\n{body}{note}\n{_source_line(story)}"


def render(contract: Contract, story: Story, outcome: Outcome, run_at: datetime) -> str | None:
    """The piece, or None when there is nothing to publish.

    Total over every kind an outcome can carry, including the one where every
    persona withdrew. No caller has to filter first to make this safe.
    """
    if not outcome.publishable:
        return None
    if outcome.kind == "two-views":
        return render_two_views(contract, story, outcome, run_at)
    if outcome.kind == "merged":
        return render_merged(contract, story, outcome, run_at)
    return render_single(contract, story, outcome, run_at)


def piece_path(drafts_dir: Path, day: date, story: Story, outcome: Outcome) -> Path:
    suffix = {"two-views": "-two-views", "merged": "-merged"}.get(outcome.kind, "")
    if outcome.kind == "single":
        suffix = f"-{outcome.drafts[0].persona}"
    return drafts_dir / day.isoformat() / f"{story.id}-{slugify(story.title)}{suffix}.md"


def write_piece(path: Path, text: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


@dataclass
class IssueRef:
    number: int
    url: str


def subprocess_runner(argv: list[str]) -> str:
    return subprocess.run(argv, check=True, capture_output=True, text=True).stdout


def open_issue(
    runner: Runner,
    *,
    repo: str,
    title: str,
    body: str,
    labels: list[str],
    assignees: list[str],
) -> IssueRef:
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8") as f:
        f.write(body)
        body_file = f.name
    argv = ["gh", "issue", "create", "--repo", repo, "--title", title, "--body-file", body_file]
    for label in labels:
        argv += ["--label", label]
    for a in assignees:
        argv += ["--assignee", a]
    out = runner(argv).strip()
    url = out.splitlines()[-1] if out else ""
    m = re.search(r"/issues/(\d+)", url)
    return IssueRef(number=int(m.group(1)) if m else 0, url=url)
