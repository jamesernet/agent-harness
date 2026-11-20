#!/usr/bin/env python3
"""Check pinned OKF conformance plus the repo-knowledge authoring profile.

Usage: python3 check.py BUNDLE [--json] [--now RFC3339]
Exit 0: clean (informational freshness findings allowed); 1: findings; 2: setup.
This check never verifies factual claims or writes trust attestations.
"""

import argparse
import hashlib
import importlib.util
import json
import sys
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path
import re

sys.dont_write_bytecode = True
KIT = Path(__file__).resolve().parent
DEFINITION = re.compile(r"^\s{0,3}\[\^([^\]\s]+)\]:")


def upstream_module():
    """Verify the verbatim snapshot before importing its parser and checker."""
    pin = json.loads((KIT / "upstream.json").read_text(encoding="utf-8"))
    for entry in pin["files"]:
        path = (KIT / entry["file"]).resolve()
        path.relative_to(KIT)
        if hashlib.sha256(path.read_bytes()).hexdigest() != entry["sha256"]:
            raise ValueError(f"upstream snapshot checksum mismatch: {entry['file']}")
    spec = importlib.util.spec_from_file_location("repo_knowledge_upstream", KIT / "upstream/validate.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module, pin


def profile(checker, upstream, pin):
    bundle = checker.bundle
    documents = []
    seen_paths = {}
    for path in sorted(bundle.rglob("*")):
        relative = path.relative_to(bundle)
        if any(part.startswith(".") for part in relative.parts):
            continue
        if not checker.inside(path.resolve()):
            continue
        folded = relative.as_posix().casefold()
        if folded in seen_paths and relative.as_posix() != seen_paths[folded]:
            checker.error(path, None, "R001", f"case-insensitive path collision with {seen_paths[folded]}")
        seen_paths[folded] = relative.as_posix()
        if path.is_file() and path.suffix == ".md":
            documents.append(path)
    if checker.okf_version != pin["okf_version"]:
        checker.error(bundle, None, "R002", f"root index.md must declare okf_version: \"{pin['okf_version']}\"")

    concepts = set()
    indexes = set()
    edges = {}
    for path in documents:
        text = path.read_text(encoding="utf-8").lstrip(upstream.BOM)
        state, meta, body, first_line = upstream.split_frontmatter(text)
        if path.name == "log.md":
            continue
        if path.name == "index.md":
            indexes.add(path)
            edges[path] = index_targets(checker, upstream, path, body if state == "ok" else text)
            continue
        concepts.add(path)
        if state != "ok":
            continue  # The upstream strict baseline reports unreadable documents.
        for key in ("type", "title", "description"):
            if not isinstance(meta.get(key), str) or not meta[key].strip():
                checker.error(path, 1, "R003", f"library profile requires non-empty {key}")
        tags = meta.get("tags")
        if not isinstance(tags, list) or not tags or any(not isinstance(tag, str) or not tag.strip() for tag in tags):
            checker.error(path, 1, "R004", "library profile requires a non-empty YAML list of string tags")
        generated = meta.get("generated")
        if not isinstance(generated, dict) or any(not isinstance(generated.get(key), str) or not generated[key].strip() for key in ("by", "at")):
            checker.error(path, 1, "R005", "library profile requires generated.by and generated.at")
        if meta.get("status") not in upstream.STATUSES:
            checker.error(path, 1, "R006", "library profile requires explicit status: draft, stable, or deprecated")
        sources = upstream.as_list(meta.get("sources"))
        if not sources:
            headings = {match.group(2).strip().casefold() for _, line in upstream.prose_lines(body) if (match := upstream.HEADING_RE.match(line))}
            if not (meta.get("status") == "draft" and meta.get("x-repo-knowledge-gap") is True and {"questions", "evidence needed"} <= headings):
                checker.error(path, 1, "R007", "sources are required; a source-free gap needs draft status, x-repo-knowledge-gap: true, and Questions / Evidence needed headings")
        check_citations(checker, upstream, path, body, first_line, sources)

    reachable = set()
    pending = [bundle / "index.md"]
    while pending:
        current = pending.pop()
        if current in reachable:
            continue
        reachable.add(current)
        pending.extend(edges.get(current, set()) - reachable)
    for path in sorted((concepts | indexes) - reachable):
        checker.error(path, None, "R008", "not reachable through index links from the bundle-root index.md")
    for path in sorted((concepts | indexes) - {bundle / "index.md"}):
        parent_index = (path.parent.parent if path.name == "index.md" else path.parent) / "index.md"
        if path not in edges.get(parent_index, set()):
            checker.error(path, None, "R013", f"not listed in its immediate parent index: {parent_index.relative_to(bundle).as_posix()}")


def index_targets(checker, upstream, path, body):
    targets = set()
    for offset, line in upstream.prose_lines(body):
        for target in upstream.LINK_RE.findall(line):
            if target.startswith("#"):
                continue
            kind, resolved = checker.resolve_path(path, target, field=False)
            if kind == "external":
                continue
            if kind == "missing" or resolved is None:
                checker.error(path, offset + 1, "R009", f"index link target does not exist: {target}")
                continue
            if resolved.is_dir():
                resolved = resolved / "index.md"
            if not resolved.is_file() or not checker.inside(resolved.resolve()):
                checker.error(path, offset + 1, "R009", f"index link must resolve to a file inside the bundle: {target}")
                continue
            targets.add(resolved)
    return targets


def check_citations(checker, upstream, path, body, first_line, sources):
    source_ids = {str(entry["id"]) for entry in sources if isinstance(entry, dict) and entry.get("id") is not None}
    definitions = set()
    references = set()
    for offset, line in upstream.prose_lines(body):
        definition = DEFINITION.match(line)
        if definition:
            label = definition.group(1)
            if label in definitions:
                checker.error(path, first_line + offset, "R010", f"duplicate footnote definition: {label}")
            definitions.add(label)
            if label not in source_ids:
                checker.error(path, first_line + offset, "R011", f"footnote definition has no matching sources id: {label}")
        else:
            references.update(upstream.FOOTNOTE_RE.findall(line))
    for label in sorted(references - definitions):
        checker.error(path, None, "R012", f"citation has no Markdown footnote definition: {label}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--now", help="RFC 3339 date-time used for freshness checks")
    args = parser.parse_args()
    try:
        upstream, pin = upstream_module()
        bundle = args.bundle.resolve()
        if not bundle.is_dir():
            raise ValueError(f"not a directory: {args.bundle}")
        now = datetime.now(timezone.utc)
        if args.now:
            now = upstream.parse_timestamp(args.now)
            if now is None or not upstream.DATETIME_RE.match(args.now):
                raise ValueError("--now must be an RFC 3339 date-time with an offset")
        checker = upstream.Checker(bundle, now)
        checker.run()
        profile(checker, upstream, pin)
    except (OSError, ValueError, KeyError, UnicodeError, ImportError) as exc:
        print(f"check.py: {exc}", file=sys.stderr)
        return 2
    counts = {level: sum(item.level == level for item in checker.findings) for level in ("error", "warning", "info")}
    result = {"bundle": str(bundle), "okf_version": checker.okf_version, "profile": "repo-knowledge", "upstream_commit": pin["commit"], "files_checked": checker.files_checked, "errors": counts["error"], "warnings": counts["warning"], "info": counts["info"], "findings": [asdict(item) for item in checker.findings]}
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        for item in checker.findings:
            location = f"{item.path}:{item.line}" if item.line else item.path
            print(f"{location}: {item.level} {item.code} {item.message}")
        print(f"{checker.files_checked} files checked: {counts['error']} errors, {counts['warning']} warnings, {counts['info']} info.")
    return 1 if counts["error"] or counts["warning"] else 0


if __name__ == "__main__":
    sys.exit(main())
