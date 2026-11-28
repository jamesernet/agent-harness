#!/usr/bin/env python3
"""Extract path-like references from docs and resolve them against the tree.

Finds facts only. Severity and judgment belong to the skill, not to this script.

The point of this script is the staged resolver. A naive `test -e` on
references pulled from a hand-maintained module map reports most of them
missing, because docs write paths relative to an enclosing tree block or
section rather than to the repo root. Resolution runs cheapest-first, checks
the working tree as well as the git index, and only reports BROKEN when a
basename appears nowhere.

Statuses:
    OK           resolved exactly
    MOVED        resolved elsewhere in the tree — old -> new
    AMBIGUOUS    several plausible targets; needs a human
    UNTRACKED    on disk but not in git (gitignored, generated)
    UNVERIFIABLE glob, placeholder, or otherwise not mechanically checkable
    BROKEN       the basename exists nowhere

Usage:
    extract-refs.py [--root DIR] [--json] [--all] [DOC ...]

With no DOC arguments the usual instruction/context docs are discovered.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from collections import defaultdict

# Tree-diagram entry: "├── main.py  # comment" / "│   └── db.py"
TREE_ENTRY = re.compile(r"^(?P<indent>[\s│|]*)(?:├──|└──|\|--|`--)\s*(?P<name>[^\s#]+)")
# A bare "app/" line opening a tree block.
TREE_ROOT = re.compile(r"^(?P<name>[A-Za-z0-9_.@-][A-Za-z0-9_./@-]*/)\s*$")
# `inline/code.py` spans that look like paths.
INLINE_CODE = re.compile(r"`([^`\n]+)`")
# [text](relative/path.md) links, excluding URLs and anchors.
MD_LINK = re.compile(r"\[[^\]]*\]\((?!https?://|#|mailto:)([^)\s]+)\)")
# @./AGENTS.md style imports.
IMPORT_LINE = re.compile(r"^@(\S+)\s*$")

FENCE = re.compile(r"^\s*(```|~~~)")

# Box-drawing and rule characters. A "tree entry" made only of these is a
# diagram border, not a path.
BOX = set("─│┌┐└┘├┤┬┴┼━┃╭╮╯╰═╔╗╚╝╠╣╦╩╬-|+ ")

CODE_EXT = {
    "py", "ts", "tsx", "js", "jsx", "mjs", "cjs", "go", "rs", "rb", "java",
    "kt", "swift", "c", "h", "cc", "cpp", "sh", "bash", "zsh", "sql", "md",
    "mdx", "json", "yaml", "yml", "toml", "ini", "cfg", "conf", "tf", "tfvars",
    "html", "css", "scss", "vue", "svelte", "proto", "graphql", "lock", "txt",
    "env", "example", "template", "service", "plist", "xml", "csv",
}

DOC_CANDIDATES = [
    "AGENTS.md", "CLAUDE.md", "CLAUDE.local.md", "README.md", "CONTRIBUTING.md",
    "CONTEXT.md", ".claude/CLAUDE.md", ".claude/AGENTS.md",
]
# Live instruction docs only, by default. docs/** is opt-in because an ADR is
# an immutable record of a past decision — a path that has since moved is
# correct history, not drift — and a vendored doc mirror is someone else's
# site, whose links resolve against this repo only by accident.
DOC_GLOB_DIRS = [".claude/rules"]
OPT_IN_DOC_DIRS = ["docs"]
THIRD_PARTY = re.compile(r"(^|/)(vendor|vendors|vendor-snapshots|third[-_]party|node_modules)(/|$)")
ADR_DIR = re.compile(r"(^|/)(adr|adrs|decisions)(/|$)")

NOT_A_PATH = re.compile(
    r"^(https?:|mailto:|[A-Z_]{3,}=|\$|-{1,2}[a-z]|<)"
    r"|\("                       # any call-looking form: pytest.fixture(...)
    r"|\s"                       # commands / prose
)


def sh(args, cwd):
    try:
        out = subprocess.run(
            args, cwd=cwd, capture_output=True, text=True, check=False, timeout=60
        )
        return out.stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def build_index(root):
    """Every tracked file, plus lookup tables for suffix and basename matching."""
    listing = sh(["git", "ls-files", "-z"], root)
    if listing:
        files = [p for p in listing.split("\0") if p]
    else:  # not a git repo — fall back to a bounded walk
        files = []
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [
                d for d in dirnames
                if d not in {".git", "node_modules", "__pycache__", ".venv", "venv", "dist", "build"}
            ]
            for fn in filenames:
                files.append(os.path.relpath(os.path.join(dirpath, fn), root))

    by_basename = defaultdict(list)
    for f in files:
        by_basename[os.path.basename(f)].append(f)

    dirs = set()
    for f in files:
        parts = f.split("/")
        for i in range(1, len(parts)):
            dirs.add("/".join(parts[:i]))

    return {"files": set(files), "dirs": dirs, "by_basename": by_basename,
            "all": files, "literals": {}, "root": root}


def is_placeholder(text):
    return "<" in text or ">" in text or "{" in text or "…" in text


def is_glob(text):
    return "*" in text or "?" in text or "[" in text


def looks_like_path(text):
    if not text or NOT_A_PATH.search(text):
        return False
    if set(text) <= BOX:
        return False
    if text.endswith("/"):
        return True
    base = os.path.basename(text)
    if not base or base.startswith(".") and "." not in base[1:]:
        return False  # a bare extension like ".md"
    if "." not in base:
        return False
    ext = base.rsplit(".", 1)[1].lower()
    return ext in CODE_EXT


def norm(p):
    p = p.strip().strip("`'\"")
    p = re.sub(r"^@", "", p)      # `@AGENTS.md` is the import form of AGENTS.md
    p = re.sub(r"^\./", "", p)
    return p.rstrip("/")


def extract(doc_path, root):
    """Yield reference dicts with their line number and context root."""
    full = os.path.join(root, doc_path)
    try:
        with open(full, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return []

    refs = []
    in_fence = False
    tree_root = None
    stack = {}
    heading = ""

    for i, line in enumerate(lines, 1):
        if FENCE.match(line):
            in_fence = not in_fence
            if not in_fence:
                tree_root, stack = None, {}
            continue

        if not in_fence and line.startswith("#"):
            heading = line.lstrip("#").strip()

        if not in_fence:
            m = IMPORT_LINE.match(line)
            if m:
                refs.append(dict(ref=norm(m.group(1)), line=i, kind="import",
                                 context=None, heading=heading))
                continue

        if in_fence:
            m = TREE_ROOT.match(line)
            if m:
                tree_root = norm(m.group("name"))
                stack = {}
                continue

            m = TREE_ENTRY.match(line)
            if m:
                raw = m.group("name")
                name = norm(raw)
                if not name or set(name) <= BOX or is_placeholder(name):
                    continue
                depth = len(m.group("indent")) // 4
                is_dir = raw.endswith("/")
                # A bare word with no extension inside a tree is usually a
                # directory; keep it, but it must resolve to survive.
                parents = [stack[d] for d in sorted(stack) if d < depth]
                parts = ([tree_root] if tree_root else []) + parents + [name]
                candidate = "/".join(p for p in parts if p)
                if is_dir:
                    stack = {d: v for d, v in stack.items() if d < depth}
                    stack[depth] = name
                bare = "." not in os.path.basename(name)
                refs.append(dict(ref=name, line=i, kind="tree",
                                 context=candidate, heading=heading,
                                 speculative=bare and not is_dir))
                continue
            continue

        for target in MD_LINK.findall(line):
            t = norm(target)
            if t and not t.startswith("#"):
                refs.append(dict(ref=t, line=i, kind="link",
                                 context=None, heading=heading))

        # The label of a link is not a second reference to the same thing.
        rest = MD_LINK.sub(" ", line)
        for span in INLINE_CODE.findall(rest):
            t = norm(span)
            if is_placeholder(t) or is_glob(t):
                if looks_like_path(re.sub(r"[*?<>{}\[\]…]", "x", t)):
                    refs.append(dict(ref=t, line=i, kind="pattern",
                                     context=None, heading=heading))
                continue
            if looks_like_path(t):
                refs.append(dict(ref=t, line=i, kind="inline",
                                 context=None, heading=heading))

    return refs


def resolve(ref, index, doc_dir, root):
    """Stage cheapest-first. Only BROKEN when the basename exists nowhere."""
    target = ref["ref"]
    ctx = ref.get("context")

    if ref["kind"] == "pattern":
        return "UNVERIFIABLE", None, []

    # ~/… and /etc/… name the machine, not the repo.
    if target.startswith("~") or target.startswith("/"):
        return "UNVERIFIABLE", None, []

    def hit(path):
        return path in index["files"] or path in index["dirs"]

    # Stage A — the tree-block path, when the doc gave us one.
    if ctx and hit(ctx):
        return "OK", ctx, []

    # Stage B — literal, relative to the repo root.
    if hit(target):
        return "OK", target, []

    # Stage C — relative to the directory the doc lives in.
    if doc_dir:
        rel = os.path.normpath(os.path.join(doc_dir, target))
        if hit(rel):
            return "OK", rel, []

    # A doc that names a bare file ("see `tokens.ts`") never claimed a
    # location, so finding it elsewhere is not drift. Only a reference that
    # supplied a path can be wrong about the path.
    claims_path = "/" in target

    # Stage D — suffix match anywhere. This is the stage that rescues
    # "admin/compliance.py" -> "app/api/v1/internal/admin/compliance.py".
    suffix = "/" + target
    matches = [f for f in index["all"] if f.endswith(suffix)]
    if len(matches) == 1:
        return ("MOVED" if claims_path else "OK"), matches[0], matches
    if len(matches) > 1:
        return ("AMBIGUOUS" if claims_path else "OK"), None, matches[:8]

    # Stage E — basename only, lowest confidence.
    base = os.path.basename(target)
    matches = index["by_basename"].get(base, [])
    if len(matches) == 1:
        return ("MOVED" if claims_path else "OK"), matches[0], matches
    if len(matches) > 1:
        return ("AMBIGUOUS" if claims_path else "OK"), None, matches[:8]

    # Stage F — on disk but untracked (gitignored, generated). Not drift.
    for probe in (ctx, target):
        if probe and os.path.exists(os.path.join(root, probe.lstrip("~/"))):
            return "UNTRACKED", probe, []

    # Stage G — a name the tracked sources create at runtime (marker files,
    # generated output) is documented correctly even though it is not in the
    # tree. Only a handful of refs ever reach this stage, so the grep is cheap.
    if base not in index["literals"]:
        found = bool(sh(["git", "grep", "-lF", "--", base], index["root"]).strip())
        index["literals"][base] = found
    if index["literals"][base]:
        return "GENERATED", None, []

    # A bare tree word that resolves nowhere is a diagram label, not a path.
    if ref.get("speculative"):
        return None, None, []

    return "BROKEN", None, []


def discover_docs(root, include_docs=False, include_adr=False):
    found = []
    for c in DOC_CANDIDATES:
        if os.path.exists(os.path.join(root, c)):
            found.append(c)
    dirs = list(DOC_GLOB_DIRS) + (OPT_IN_DOC_DIRS if include_docs else [])
    for d in dirs:
        base = os.path.join(root, d)
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [x for x in dirnames if x not in {"node_modules", ".git"}]
            for fn in sorted(filenames):
                if not fn.endswith(".md"):
                    continue
                rel = os.path.relpath(os.path.join(dirpath, fn), root)
                if THIRD_PARTY.search(rel):
                    continue
                if ADR_DIR.search(rel) and not include_adr:
                    continue
                found.append(rel)
    seen, out = set(), []
    for f in found:
        if f not in seen:
            seen.add(f)
            out.append(f)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("docs", nargs="*", help="docs to audit (default: discover)")
    ap.add_argument("--root", default=".", help="repo root")
    ap.add_argument("--json", action="store_true", help="emit JSON")
    ap.add_argument("--all", action="store_true", help="also list OK references")
    ap.add_argument("--include-docs", action="store_true",
                    help="also audit docs/** (excludes vendored mirrors)")
    ap.add_argument("--include-adr", action="store_true",
                    help="also audit ADRs — historical records, judge accordingly")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    index = build_index(root)
    docs = args.docs or discover_docs(root, args.include_docs, args.include_adr)

    results = []
    for doc in docs:
        doc_dir = os.path.dirname(doc)
        for ref in extract(doc, root):
            status, resolved, candidates = resolve(ref, index, doc_dir, root)
            if status is None:
                continue
            results.append({
                "doc": doc, "line": ref["line"], "ref": ref["ref"],
                "kind": ref["kind"], "heading": ref["heading"],
                "status": status, "resolved_to": resolved,
                "candidates": candidates,
            })

    counts = defaultdict(int)
    for r in results:
        counts[r["status"]] += 1

    if args.json:
        json.dump({"root": root, "docs": docs, "counts": dict(counts),
                   "references": results}, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return

    print(f"root: {root}")
    print(f"docs: {len(docs)}   references: {len(results)}")
    print("  " + "  ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    order = ["BROKEN", "AMBIGUOUS", "MOVED", "UNTRACKED", "GENERATED", "UNVERIFIABLE"]
    if args.all:
        order.append("OK")
    for status in order:
        rows = [r for r in results if r["status"] == status]
        if not rows:
            continue
        print(f"\n--- {status} ({len(rows)}) ---")
        for r in rows:
            tail = ""
            if r["resolved_to"] and r["resolved_to"] != r["ref"]:
                tail = f"  -> {r['resolved_to']}"
            elif r["candidates"]:
                tail = f"  -> {len(r['candidates'])} candidates"
            print(f"{r['doc']}:{r['line']}  {r['ref']}{tail}")


if __name__ == "__main__":
    main()
