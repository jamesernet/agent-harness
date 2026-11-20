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
SOURCE_ID = re.compile(r"[^\[\]\s]+")


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
    from markdown_it import MarkdownIt
    from mdit_py_plugins.footnote import footnote_plugin

    markdown = MarkdownIt("commonmark").use(footnote_plugin, inline=False, move_to_end=False, always_match_refs=True)
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
            edges[path] = index_targets(checker, path, body if state == "ok" else text, first_line if state == "ok" else 1)
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
        tokens = markdown.parse(body)
        check_raw_html(checker, path, tokens, first_line)
        if not sources:
            headings = {tokens[index + 1].content.strip().casefold() for index, token in enumerate(tokens) if token.type == "heading_open"}
            if not (meta.get("status") == "draft" and meta.get("x-repo-knowledge-gap") is True and {"questions", "evidence needed"} <= headings):
                checker.error(path, 1, "R007", "sources are required; a source-free gap needs draft status, x-repo-knowledge-gap: true, and Questions / Evidence needed headings")
        source_ids = check_sources(checker, path, sources)
        check_citations(checker, path, tokens, first_line, source_ids, bool(sources))

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


def check_raw_html(checker, path, tokens, first_line):
    for block in tokens:
        for token in (block, *(block.children or ())):
            if token.type in ("html_block", "html_inline") and re.sub(r"<!--.*?-->", "", token.content, flags=re.DOTALL).strip():
                line = first_line + block.map[0] if block.map else None
                checker.error(path, line, "R017", "raw HTML is unsupported by this profile except complete comments; use Markdown or fenced code examples")
                return


def index_targets(checker, path, body, first_line):
    from markdown_it import MarkdownIt

    tokens = MarkdownIt("commonmark").parse(body)
    check_raw_html(checker, path, tokens, first_line)
    targets = set()
    for block in tokens:
        for token in block.children or ():
            if token.type != "link_open":
                continue
            target = token.attrGet("href")
            line = first_line + block.map[0] if block.map else None
            if target.startswith("#"):
                continue
            kind, resolved = checker.resolve_path(path, target, field=False)
            if kind == "external":
                continue
            if kind == "missing" or resolved is None:
                checker.error(path, line, "R009", f"index link target does not exist: {target}")
                continue
            if resolved.is_dir():
                resolved = resolved / "index.md"
            if not resolved.is_file() or not checker.inside(resolved.resolve()):
                checker.error(path, line, "R009", f"index link must resolve to a file inside the bundle: {target}")
                continue
            targets.add(resolved)
    return targets


def check_sources(checker, path, sources):
    source_ids = set()
    for index, entry in enumerate(sources):
        if not isinstance(entry, dict):
            checker.error(path, 1, "R014", f"sources[{index}] must be a mapping with a non-blank string resource")
            continue
        resource = entry.get("resource")
        if not isinstance(resource, str) or not resource.strip():
            checker.error(path, 1, "R014", f"sources[{index}].resource must be a non-blank string")
        source_id = entry.get("id")
        if not isinstance(source_id, str) or not SOURCE_ID.fullmatch(source_id):
            checker.error(path, 1, "R015", f"sources[{index}].id must be a non-empty string without whitespace or brackets")
        else:
            source_ids.add(source_id)
    return source_ids


def check_citations(checker, path, tokens, first_line, source_ids, requires_citation):
    # Replace only the upstream regex footnote warning with parsed R011/R012
    # checks. Literal examples and hidden markup are not source references.
    relative = path.relative_to(checker.bundle).as_posix()
    checker.findings[:] = [item for item in checker.findings if not (item.path == relative and item.code == "W108")]
    definitions = set()
    references = set()
    claim_references = set()
    definition_depth = 0
    for token in tokens:
        if token.type == "footnote_reference_open":
            label = token.meta["label"]
            line = first_line + token.map[0] if token.map else None
            if label in definitions:
                checker.error(path, line, "R010", f"duplicate footnote definition: {label}")
            definitions.add(label)
            if label not in source_ids:
                checker.error(path, line, "R011", f"footnote definition has no matching sources id: {label}")
            definition_depth += 1
        elif token.type == "footnote_reference_close":
            definition_depth -= 1
        else:
            for child in token.children or ():
                if child.type == "footnote_ref":
                    label = child.meta["label"]
                    references.add(label)
                    if not definition_depth:
                        claim_references.add(label)
    for label in sorted(references - definitions):
        checker.error(path, None, "R012", f"citation has no Markdown footnote definition: {label}")
    if requires_citation and not claim_references & source_ids:
        checker.error(path, None, "R016", "a concept with sources must cite at least one source in rendered prose; metadata and footnote definitions alone are not claim attribution")


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
