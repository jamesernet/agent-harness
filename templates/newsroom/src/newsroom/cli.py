"""newsroom run | triage | bench | fetch | check"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

from . import feeds, pipeline
from .config import ConfigError
from .contract import Contract, ContractError, load_contract
from .llm import LLMError, build_llm
from .run import format_report, preflight, run_cycle

EXIT_OK, EXIT_RUNTIME, EXIT_CONFIG = 0, 1, 2


def _contract(path: str) -> Contract:
    try:
        return load_contract(Path(path))
    except (ContractError, ConfigError) as e:
        _die(str(e))
        raise AssertionError  # unreachable; _die raises


def _die(msg: str, code: int = EXIT_CONFIG) -> None:
    print(f"newsroom: {msg}", file=sys.stderr)
    raise SystemExit(code)


def _llm(contract: Contract, fake_replies: str | None, provider: str | None = None):
    cfg = contract.config
    if provider:
        cfg.provider.kind = provider
    replies = None
    if cfg.provider.kind == "fake":
        path = Path(fake_replies or "fixtures/fake_replies.json")
        if path.is_file():
            replies = json.loads(path.read_text(encoding="utf-8"))
    try:
        return build_llm(cfg.provider, cfg.api_key(os.environ), fake_replies=replies)
    except (ConfigError, LLMError) as e:
        _die(str(e))


def _parse_date(value: str | None) -> datetime:
    if not value:
        return datetime.now(timezone.utc)
    return datetime.fromisoformat(value).replace(hour=6, tzinfo=timezone.utc)


def cmd_check(args: argparse.Namespace) -> int:
    contract = _contract(args.contract)
    cfg = contract.config
    problems = preflight(contract, os.environ)
    for w in cfg.warnings:
        print(f"warning: {w}")
    blanks = cfg.blanks() + contract.persona_blanks()
    for b in blanks:
        print(f"blank: {b}")
    for p in problems:
        print(f"problem: {p}")
    enabled = ", ".join(p.name for p in contract.enabled_personas())
    print(f"contract {contract.name}: personas on: {enabled or 'none'}; provider {cfg.provider.kind} {cfg.provider.model}")
    if cfg.github_repo(os.environ) and not shutil.which("gh"):
        print("problem: output.github.repo is set but `gh` is not on PATH")
        problems.append("gh")
    if problems:
        print("not ready to run")
        return EXIT_CONFIG
    print("ready" if not blanks else "ready, with blanks that are not needed to run")
    return EXIT_OK


def cmd_run(args: argparse.Namespace, triage_only: bool = False) -> int:
    contract = _contract(args.contract)
    if args.provider:
        contract.config.provider.kind = args.provider
    problems = preflight(contract, os.environ)
    if problems:
        for p in problems:
            print(f"problem: {p}", file=sys.stderr)
        return EXIT_CONFIG
    llm = _llm(contract, args.fake_replies, args.provider)
    report = run_cycle(
        contract,
        llm,
        env=os.environ,
        now=_parse_date(args.date),
        report_only=getattr(args, "report_only", False),
        issues=not getattr(args, "no_issues", False),
        force=getattr(args, "force", False),
        triage_only=triage_only,
        personas=args.personas.split(",") if getattr(args, "personas", None) else None,
    )
    if getattr(args, "json", False):
        print(json.dumps([t.__dict__ for t in report.triages], indent=2))
    else:
        print(format_report(report, contract), end="")
    nothing_ran = not report.stories and report.feed_errors
    all_failed = report.triages == [] and report.failures
    return EXIT_RUNTIME if (nothing_ran or all_failed) else EXIT_OK


def cmd_triage(args: argparse.Namespace) -> int:
    if args.persona:
        args.personas = args.persona
    return cmd_run(args, triage_only=True)


def cmd_fetch(args: argparse.Namespace) -> int:
    contract = _contract(args.contract)
    cfg = contract.config
    stories, errors = feeds.fetch_all(cfg.feed.sources, summary_chars=cfg.feed.summary_chars)
    selected = feeds.select(
        stories,
        now=datetime.now(timezone.utc),
        lookback_hours=cfg.feed.lookback_hours,
        seen={},
        skip_seen_days=cfg.feed.skip_seen_days,
        max_stories=cfg.feed.max_stories,
    )
    for e in errors:
        print(f"feed failed: {e}", file=sys.stderr)
    if args.json:
        print(json.dumps([feeds.to_dict(s) for s in selected], indent=2))
    else:
        for s in selected:
            when = s.published.date().isoformat() if s.published else "undated"
            print(f"{s.id}  {when}  {s.source[:20]:20}  {s.title[:70]}")
    return EXIT_RUNTIME if (errors and not stories) else EXIT_OK


def cmd_bench(args: argparse.Namespace) -> int:
    contract = _contract(args.contract)
    if args.persona not in contract.personas:
        _die(f"no persona named {args.persona} in {contract.name}")
    persona = contract.personas[args.persona]
    if args.stories:
        stories = [feeds.from_dict(d) for d in json.loads(Path(args.stories).read_text(encoding="utf-8"))]
    else:
        stories, errors = feeds.fetch_all(contract.config.feed.sources, summary_chars=contract.config.feed.summary_chars)
        for e in errors:
            print(f"feed failed: {e}", file=sys.stderr)
    llm = _llm(contract, args.fake_replies, args.provider)
    try:
        triages = pipeline.triage_persona(llm, contract, persona, stories)
    except LLMError as e:
        _die(str(e), EXIT_RUNTIME)
    by_id = {s.id: s for s in stories}
    for t in sorted(triages, key=lambda t: -t.stance):
        print(f"{t.stance}  {t.section:10}  {by_id[t.story_id].title[:60]:60}  {t.reason}")
    if args.draft:
        top = max(triages, key=lambda t: t.stance)
        if not top.flagged:
            print("nothing reached the draft threshold; nothing drafted")
            return EXIT_OK
        try:
            draft = pipeline.write_draft(llm, contract, persona, by_id[top.story_id], top)
        except LLMError as e:
            _die(str(e), EXIT_RUNTIME)
        print("\n" + draft.body)
    return EXIT_OK


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="newsroom", description="AI personas read a feed, draft, debate once, hand to a person.")
    sub = p.add_subparsers(dest="command", required=True)

    def common(sp: argparse.ArgumentParser) -> None:
        sp.add_argument("--contract", required=True, help="directory holding config.yml, shared.md, guardrails.md, personas/")
        sp.add_argument("--fake-replies", help="for provider.kind fake: path to scripted replies (default fixtures/fake_replies.json)")
        sp.add_argument("--provider", choices=["openai", "anthropic", "fake"], help="override provider.kind for this invocation")

    run = sub.add_parser("run", help="full cycle: fetch, triage, draft, debate, write drafts, open issues")
    common(run)
    run.add_argument("--date", help="YYYY-MM-DD to run as (default today)")
    run.add_argument("--report-only", action="store_true", help="do every step but write nothing and open nothing")
    run.add_argument("--no-issues", action="store_true", help="write drafts but open no issues")
    run.add_argument("--force", action="store_true", help="ignore cached steps for this date")
    run.add_argument("--personas", help="comma-separated subset of enabled personas")
    run.set_defaults(func=cmd_run)

    tr = sub.add_parser("triage", help="fetch and triage only; prints the stance table, writes nothing")
    common(tr)
    tr.add_argument("--date")
    tr.add_argument("--persona", help="one persona only")
    tr.add_argument("--json", action="store_true")
    tr.set_defaults(func=cmd_triage)

    be = sub.add_parser("bench", help="triage one persona against a fixed story set; writes nothing")
    common(be)
    be.add_argument("--persona", required=True)
    be.add_argument("--stories", help="stories.json from `newsroom fetch --json` (default: live fetch)")
    be.add_argument("--draft", action="store_true", help="also draft the top story and print it")
    be.set_defaults(func=cmd_bench)

    fe = sub.add_parser("fetch", help="fetch and select stories; prints them")
    common(fe)
    fe.add_argument("--json", action="store_true")
    fe.set_defaults(func=cmd_fetch)

    ch = sub.add_parser("check", help="validate the contract and the environment; no network")
    common(ch)
    ch.set_defaults(func=cmd_check)
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
