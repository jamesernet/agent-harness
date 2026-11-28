#!/usr/bin/env python3
"""Build the findings register of a website-audit-package from its evidence layer.

Stdlib only. The register is the step between evidence and argument (#69): every
finding in it is derived by running a measuring tool on files saved under the
package's evidence layer, so every claim carries pointers to the files the tool
actually read, and a claim that cannot be backed is refused rather than emitted.

Today the one constituent audit with a machine output is audit-metadata, whose
inventory.py reports facts and boolean checks and leaves severity to its skill.
This script runs it on each page saved under evidence/metadata-audit/<page>/
(page.html, and robots.txt, llms.txt, headers.txt, sitemap.xml, url and captured
where saved),
turns each true check into a finding with the severity audit-metadata's decision
tree gives that case, and writes register.json and a one-page register.md at the
package root, beside the capture tool's manifest.json.

Usage:
    python3 register.py build <package-dir> [--inventory <path to inventory.py>]
    python3 register.py check <package-dir>

`build` validates its own output before writing anything, and `check` validates an
existing register.json against the package: every evidence pointer must resolve
to a file inside the finding's own page directory, with the sha256 the register
recorded when it was measured; no finding may lack a measured sentence, a
falsifier, a state or a measuredBy; and each finding's id, gate, severity, source
and cited inputs must be what the severity table gives its check. `check` does
not re-measure: a changed evidence file is refused by hash, and `build` is how a
register is brought back in line. A finding's asOf is the capture time: the
one-line `captured` file (ISO 8601 with a timezone) if saved, else the last Date
header in headers.txt, else the page file's own timestamp, and asOfSource says
which. Exit 0 on success, 1 when the register is refused, 2 when the package or
the tool is not usable: no evidence directory, nothing measured, an input that
resolves outside the package, a captured file without a timezone, the tool
missing or failing. A refused or failed build removes a register.json and
register.md left by an earlier build, because they no longer describe the
evidence; a build that cannot even find the evidence directory touches nothing.
"""

import argparse
import datetime as dt
import email.utils
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

SCHEMA = "website-audit-package/register@1"
STATES = ("Live", "Fixed in source, awaiting publish", "Open")
SEVERITIES = ("P0", "P1", "P2", "P3")
TREE = "audit-metadata/references/decision-tree.md"
# The skill was called metadata-audit until 2026-11, and a register built before
# then cites the decision tree by that path. `validate` accepts either spelling,
# so a delivered package does not fail because a directory here was renamed.
# The evidence directory inside a package is part of the delivered format and
# keeps the old name.
TREE_BEFORE_RENAME = "metadata-audit/references/decision-tree.md"
OPTIONAL_INPUTS = ("robots.txt", "llms.txt", "headers.txt", "sitemap.xml", "url", "captured")

# Which saved inputs each group of checks needs. A page that lacks one has those
# checks recorded as not run, never as passed.
NEEDS = {
    "headers.txt": ("header_noindex", "header_nosnippet", "status_not_200", "redirect_chain"),
    "robots.txt": ("robots_is_html", "robots_blocks_everything", "robots_blocks_this_path"),
    "sitemap.xml": ("url_absent_from_sitemap", "sitemap_invalid"),
    # Without the page's URL the inventory cannot say whether the sitemap lists it
    # or robots.txt allows its path; it reports both as False, which is not a pass.
    "url": ("url_absent_from_sitemap", "robots_blocks_this_path"),
}

# Why a check that needs no missing input can still be unanswerable (None).
NOT_MEASURABLE = {
    "robots_blocks_everything": "the general crawler has a robots.txt group of its own, and the "
                                "inventory does not say what a named group blocks as a whole",
}


def _resp(r):
    return r.get("response") or {}


def _head(r):
    return r.get("head") or {}


def _sd(r):
    return r.get("structured_data") or {}


def _content(r):
    return r.get("content") or {}


def _robots(r):
    return r.get("robots_txt") or {}


def _xrt(r):
    tag = _resp(r).get("x_robots_tag")
    return ", ".join(tag) if isinstance(tag, list) else tag


def _plural(n, word):
    return "{} {}".format(n, word if n == 1 else word + "s")


# One row per check inventory.py can emit, plus three facts derived from its
# robots.txt section. Each row: gate, severity, the decision-tree line it comes
# from, the measured sentence built from the tool's own numbers, why it matters in
# the tree's words, which saved inputs back it, and an optional note where the
# tree is silent, page-type dependent, or calls the case a decision. A check with
# no row is refused at build time, so a new check in inventory.py cannot enter the
# register unlabelled.
RULES = {
    # Gate 0: reachable
    "status_not_200": dict(
        gate=0, severity="P0", source=f"{TREE}:35-36",
        measured=lambda r: "The saved response chain ends in HTTP {}; chain {}".format(
            _resp(r).get("status"), _resp(r).get("status_chain")),
        why="A page that does not return 200 is a Gate 0 problem: the crawler never reads "
            "its robots meta, canonical or structured data.",
        inputs=("headers.txt",),
        note="The tree calls a page that does not return 200 a Gate 0 problem without a "
             "P-level; P0 is register.py's reading, by analogy with the robots.txt rows at "
             ":27-30 where a fetch failure is P0."),
    "redirect_chain": dict(
        gate=0, severity="P2", source=f"{TREE}:35",
        measured=lambda r: "{} redirect hops before the final response; chain {}".format(
            _resp(r).get("redirect_hops"), _resp(r).get("status_chain")),
        why="The tree names a page that redirects in a chain a Gate 0 problem; each hop "
            "spends crawl budget and some crawlers stop early.",
        inputs=("headers.txt",),
        note="The decision tree gives no P-level for a redirect chain; P2 is register.py's reading."),
    "robots_is_html": dict(
        gate=0, severity="P1", source=f"{TREE}:31",
        measured=lambda r: "The saved robots.txt begins with an HTML document, not directives",
        why="A soft-404 robots.txt parses as garbage; the crawler cannot establish what is allowed.",
        inputs=("robots.txt",)),
    # Gate 1: crawlable and indexable
    "robots_blocks_everything": dict(
        gate=1, severity="P0", source=f"{TREE}:45",
        measured=lambda r: "robots.txt's User-agent: * group disallows every path",
        why="A disallowed URL is never fetched, so its meta robots, canonical, hreflang and "
            "JSON-LD are all unread.",
        inputs=("robots.txt",)),
    "robots_blocks_this_path": dict(
        gate=1, severity="P0", source=f"{TREE}:45",
        measured=lambda r: "robots.txt disallows {} for the general crawler".format(
            (_robots(r).get("path_access") or {}).get("path")),
        why="A disallowed URL is never fetched, so its meta robots, canonical, hreflang and "
            "JSON-LD are all unread.",
        inputs=("robots.txt",)),
    "meta_noindex": dict(
        gate=1, severity="P0", source=f"{TREE}:55",
        measured=lambda r: "meta robots is `{}`{}".format(
            _head(r).get("meta_robots"),
            ", googlebot `{}`".format(_head(r).get("meta_robots_googlebot"))
            if _head(r).get("meta_robots_googlebot") else ""),
        why="noindex removes the page from the index outright.",
        inputs=(),
        note="P0 if unintended, a confirmed decision if not; ask the owner which (staging and "
             "thank-you pages are usually intentional)."),
    "header_noindex": dict(
        gate=1, severity="P0", source=f"{TREE}:55",
        measured=lambda r: "X-Robots-Tag is `{}`".format(_xrt(r)),
        why="A noindex in a response header removes the page from the index and is invisible "
            "to every HTML-only check.",
        inputs=("headers.txt",),
        note="P0 if unintended, a confirmed decision if not; ask the owner which."),
    "meta_nofollow": dict(
        gate=1, severity="P2", source=f"{TREE}:58",
        measured=lambda r: "meta robots is `{}`".format(_head(r).get("meta_robots")),
        why="A site-wide nofollow is rarely what anyone means; it drops every outbound signal.",
        inputs=()),
    "meta_nosnippet": dict(
        gate=1, severity="P1", source=f"{TREE}:59",
        measured=lambda r: "meta robots is `{}`".format(_head(r).get("meta_robots")),
        why="nosnippet suppresses the text an answer engine would quote.",
        inputs=()),
    "header_nosnippet": dict(
        gate=1, severity="P1", source=f"{TREE}:59",
        measured=lambda r: "X-Robots-Tag is `{}`".format(_xrt(r)),
        why="nosnippet suppresses the text an answer engine would quote.",
        inputs=("headers.txt",)),
    "meta_noarchive": dict(
        gate=1, severity="P1", source=f"{TREE}:59",
        measured=lambda r: "meta robots is `{}`".format(_head(r).get("meta_robots")),
        why="noarchive withholds the cached copy some answer engines read from.",
        inputs=()),
    "url_absent_from_sitemap": dict(
        gate=1, severity="P2", source=f"{TREE}:76",
        measured=lambda r: "{} is not among the {} URLs in the saved sitemap".format(
            r.get("url"), (r.get("sitemap") or {}).get("url_count")),
        why="A page meant to be indexed that its own sitemap omits relies on being well linked.",
        inputs=("sitemap.xml",)),
    "sitemap_invalid": dict(
        gate=1, severity="P1", source=f"{TREE}:73-75",
        measured=lambda r: (
            "The saved sitemap.xml is not well-formed XML: {}".format((r.get("sitemap") or {}).get("error"))
            if (r.get("sitemap") or {}).get("valid") is False else
            "The saved sitemap.xml parses but its root is <{}>, not <urlset> or <sitemapindex>".format(
                (r.get("sitemap") or {}).get("root"))),
        why="A file that is not a sitemap is discarded whole; an HTML page served at the "
            "sitemap URL is the usual cause.",
        inputs=("sitemap.xml",)),
    # Gate 4: head identity
    "lang_missing": dict(
        gate=4, severity="P2", source=f"{TREE}:170",
        measured=lambda r: "<html> carries no lang attribute",
        why="Cheap, and it matters for both text-to-speech and language targeting.",
        inputs=()),
    "title_missing": dict(
        gate=4, severity="P1", source=f"{TREE}:171",
        measured=lambda r: "The page has no <title>",
        why="The title is the strongest single signal a search engine reads.",
        inputs=(),
        note="The tree calls this P0-adjacent for search; P1 is register.py's reading of that."),
    "title_over_60": dict(
        gate=4, severity="P3", source=f"{TREE}:173",
        measured=lambda r: "The title is {} characters".format(_head(r).get("title_len")),
        why="Truncation risk in results, not an error.",
        inputs=()),
    "description_missing": dict(
        gate=4, severity="P2", source=f"{TREE}:174",
        measured=lambda r: "The page has no meta description",
        why="Not a ranking factor; it is the click-through copy, and without one the engine "
            "writes its own.",
        inputs=()),
    "description_over_160": dict(
        gate=4, severity="P3", source=f"{TREE}:176",
        measured=lambda r: "The meta description is {} characters".format(
            _head(r).get("meta_description_len")),
        why="Truncation risk in results, not an error.",
        inputs=()),
    "canonical_missing": dict(
        gate=4, severity="P2", source=f"{TREE}:178",
        measured=lambda r: "The page has no rel=canonical link",
        why="Without a canonical, query-parameter variants compete with the page.",
        inputs=(),
        note="P1 on any page reachable via query parameters, which the evidence does not say."),
    "canonical_conflicting": dict(
        gate=4, severity="P1", source=f"{TREE}:92-94",
        measured=lambda r: "{} canonical links disagree: {}".format(
            _head(r).get("canonical_count"), _head(r).get("canonicals")),
        why="Two conflicting canonicals make the engine ignore both.",
        inputs=()),
    "og_incomplete": dict(
        gate=4, severity="P2", source=f"{TREE}:179",
        measured=lambda r: "Open Graph is missing {}".format(
            ", ".join(k for k in ("title", "description", "image")
                      if k not in (_head(r).get("open_graph") or {})) or "nothing"),
        why="Open Graph governs how the link renders when shared.",
        inputs=()),
    "og_image_relative": dict(
        gate=4, severity="P1", source=f"{TREE}:182",
        measured=lambda r: "og:image is relative: {}".format(
            (_head(r).get("open_graph") or {}).get("image")),
        why="A relative og:image will not render on any sharing surface.",
        inputs=()),
    # Gate 5: structured data
    "no_structured_data": dict(
        gate=5, severity="P2", source=f"{TREE}:208-213",
        measured=lambda r: "No JSON-LD, microdata or RDFa on the page",
        why="Display features and entity disambiguation are left on the table.",
        inputs=(),
        note="P1 for Product, LocalBusiness, Event, Recipe and JobPosting pages, P3 for a "
             "generic marketing page; the page type is not machine-known, so this is the "
             "Article default."),
    "invalid_jsonld_present": dict(
        gate=5, severity="P0", source=f"{TREE}:195",
        measured=lambda r: "{} of {} JSON-LD blocks fail to parse".format(
            _sd(r).get("jsonld_invalid_count"), _sd(r).get("jsonld_block_count")),
        why="An invalid block is discarded whole and silently.",
        inputs=()),
    "microdata_only": dict(
        gate=5, severity="P2", source=f"{TREE}:204",
        measured=lambda r: "{} microdata nodes and no JSON-LD".format(_sd(r).get("microdata_nodes")),
        why="Valid and still parsed, but coupled to presentation and harder to extend.",
        inputs=()),
    "jsonld_and_microdata_both": dict(
        gate=5, severity="P2", source=f"{TREE}:207",
        measured=lambda r: "{} JSON-LD blocks and {} microdata nodes".format(
            _sd(r).get("jsonld_block_count"), _sd(r).get("microdata_nodes")),
        why="Two descriptions of the same entity that disagree is worse than one.",
        inputs=()),
    "graph_unwired": dict(
        gate=5, severity="P2", source=f"{TREE}:224",
        measured=lambda r: "Types {} with no @id".format(_sd(r).get("types_found")),
        why="Without @id the entities are unrelated assertions rather than one connected graph.",
        inputs=()),
    "graph_dangling_refs": dict(
        gate=5, severity="P2", source=f"{TREE}:224",
        measured=lambda r: "@id references with no definition on the page: {}".format(
            _sd(r).get("dangling_refs")),
        why="A reference to an @id nothing defines leaves the graph disconnected.",
        inputs=(),
        note="The tree covers isolated entities; a dangling reference is the same gap seen "
             "from the other side."),
    "bad_context": dict(
        gate=5, severity="P0", source=f"{TREE}:217",
        measured=lambda r: "A JSON-LD block's @context is neither https nor http schema.org",
        why="A block with the wrong @context is discarded.",
        inputs=()),
    "http_context": dict(
        gate=5, severity="P3", source=f"{TREE}:217",
        measured=lambda r: "A JSON-LD block uses http://schema.org as its @context",
        why="The tree asks for https://schema.org.",
        inputs=(),
        note="The tree reads literally as P0 for any non-https @context; inventory.py "
             "separates the http form because consumers accept it, and register.py assigns P3."),
    "suspect_type_casing": dict(
        gate=5, severity="P0", source=f"{TREE}:218",
        measured=lambda r: "Types with suspect casing: {}".format(
            (r.get("checks") or {}).get("suspect_type_casing")),
        why="Types are case-sensitive; a miscased type is an unknown type and the block is ignored.",
        inputs=()),
    # Gate 6: clean copy
    "likely_js_rendered": dict(
        gate=6, severity="P1", source=f"{TREE}:249",
        measured=lambda r: "{} words of body text in {} bytes of HTML".format(
            _content(r).get("word_count"), r.get("html_bytes")),
        why="If the copy only exists after hydration, most retrieval crawlers see an empty page.",
        inputs=()),
    "thin_raw_text": dict(
        gate=6, severity="P2", source=f"{TREE}:249-262",
        measured=lambda r: "{} words of body text in the raw HTML".format(_content(r).get("word_count")),
        why="Thin raw text gives a retriever little to chunk and dilutes what it does take.",
        inputs=(),
        note="The tree's P1 is for near-zero text; under 200 words is thin, not empty, so P2."),
    "h1_missing": dict(
        gate=6, severity="P2", source=f"{TREE}:252",
        measured=lambda r: "{} h1 among {} headings".format(
            _content(r).get("h1_count"), _content(r).get("heading_count")),
        why="A missing h1 is a loss of the page's own statement of what it is about.",
        inputs=()),
    "h1_multiple": dict(
        gate=6, severity="P3", source=f"{TREE}:252",
        measured=lambda r: "{} h1 elements".format(_content(r).get("h1_count")),
        why="Legal in HTML5 and not a real problem; worth one line.",
        inputs=()),
    "heading_levels_skipped": dict(
        gate=6, severity="P3", source=f"{TREE}:255",
        measured=lambda r: "Heading levels skipped: {}".format(_content(r).get("skipped_levels")),
        why="Breaks the document tree used for chunking; mostly an outline and accessibility concern.",
        inputs=()),
    "no_semantic_landmarks": dict(
        gate=6, severity="P2", source=f"{TREE}:259",
        measured=lambda r: "No main, article, nav, header, footer, aside, section or figure element",
        why="Landmarks are how an extractor separates content from chrome.",
        inputs=()),
    "images_missing_alt": dict(
        gate=6, severity="P2", source=f"{TREE}:263",
        measured=lambda r: "{} of {} images have no alt attribute".format(
            _content(r).get("images_missing_alt"), _content(r).get("images_total")),
        why="Accessibility first, and secondarily the descriptive text a retriever reads.",
        inputs=()),
    "table_without_headers": dict(
        gate=6, severity="P2", source=f"{TREE}:264",
        measured=lambda r: "{} table(s) and {} th cells".format(
            _content(r).get("tables"), _content(r).get("table_headers")),
        why="A table with th survives extraction; one without does not.",
        inputs=()),
}


def utc_iso(ts=None):
    if ts is None:
        t = dt.datetime.now(dt.timezone.utc)
    elif isinstance(ts, dt.datetime):
        t = ts if ts.tzinfo else ts.replace(tzinfo=dt.timezone.utc)
        t = t.astimezone(dt.timezone.utc)
    else:
        t = dt.datetime.fromtimestamp(ts, dt.timezone.utc)
    return t.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def as_of_for(page_dir, inputs):
    """When the evidence was captured: (iso, the file it came from, how to say so).

    A file's mtime is set by whatever last copied it, not by the capture, so it is
    the last resort and is labelled as such.
    """
    if "captured" in inputs:
        lines = (page_dir / "captured").read_text(encoding="utf-8").strip().splitlines()
        text = lines[0].strip() if lines else ""
        try:
            t = dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
        except ValueError:
            print("register: {} is not an ISO 8601 timestamp: {!r}".format(
                page_dir / "captured", text), file=sys.stderr)
            raise SystemExit(2)
        if t.tzinfo is None:
            print("register: {} needs a timezone, for example 2026-11-18T12:00:00Z; "
                  "got {!r}".format(page_dir / "captured", text), file=sys.stderr)
            raise SystemExit(2)
        return utc_iso(t), "captured", "captured file"
    if "headers.txt" in inputs:
        found = None
        for line in (page_dir / "headers.txt").read_text(encoding="utf-8", errors="replace").splitlines():
            if line.lower().startswith("date:"):
                try:
                    found = email.utils.parsedate_to_datetime(line.split(":", 1)[1].strip())
                except (TypeError, ValueError):
                    found = None
        if found is not None:
            return utc_iso(found), "headers.txt", "headers.txt Date header"
    return (utc_iso((page_dir / "page.html").stat().st_mtime), "page.html",
            "page.html mtime; no captured file or Date header was saved")


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


def default_inventory():
    here = Path(__file__).resolve().parent
    return here.parent.parent / "audit-metadata" / "scripts" / "inventory.py"


def robots_facts(result):
    """The three Gate 0/1 facts the inventory reports about robots.txt without a check."""
    rb = result.get("robots_txt")
    if rb is None:
        return {}
    access = rb.get("path_access") or {}
    general = access.get("general_crawler") or {}
    # robots groups do not inherit: a crawler with a group of its own never reads
    # the * group. The inventory says whether the * group blocks everything, and
    # whether the general crawler may fetch the audited path, and nothing about
    # what a named group blocks as a whole. So "blocks everything" is measured only
    # when the general crawler has no group of its own; when it has one, that
    # question is NOT RUN (None), and its own group decides the audited path
    # through robots_blocks_this_path.
    has_own_group = any(a.lower() == "googlebot" for a in rb.get("named_agents") or [])
    blocks_all = None if has_own_group else bool(rb.get("wildcard_blocks_all"))
    blocks_path = access.get("path") is not None and general.get("allowed") is False
    return {
        "robots_is_html": bool(rb.get("looks_like_html")),
        "robots_blocks_everything": blocks_all,
        # Everything blocked already says this path is blocked; one finding, not two.
        "robots_blocks_this_path": blocks_path and not blocks_all,
    }


def sitemap_facts(result):
    """A sitemap that did not parse is its own finding, and says nothing about the URL."""
    sm = result.get("sitemap")
    if sm is None:
        return {}
    invalid = sm.get("valid") is False or sm.get("root") not in ("urlset", "sitemapindex")
    return {"sitemap_invalid": invalid, **({"url_absent_from_sitemap": False} if invalid else {})}


def first_line(path):
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.strip():
            return line.strip()
    return ""


def input_present(page_dir, name):
    """A url file counts only when it names a URL; a blank one is an absent input."""
    f = page_dir / name
    if not f.is_file():
        return False
    if name == "url":
        return bool(first_line(f))
    return True


def run_inventory(tool, page_dir, inputs):
    cmd = [sys.executable, str(tool), str(page_dir / "page.html"), "--compact"]
    for flag, name in (("--robots", "robots.txt"), ("--llms", "llms.txt"),
                       ("--headers", "headers.txt"), ("--sitemap", "sitemap.xml")):
        if name in inputs:
            cmd += [flag, str(page_dir / name)]
    if "url" in inputs:
        cmd += ["--url", first_line(page_dir / "url")]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError("{} exited {} on {}: {}".format(
            tool, proc.returncode, page_dir.name, proc.stderr.strip()[-400:]))
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as e:
        raise RuntimeError("{} did not print JSON for {}: {}".format(tool, page_dir.name, e))


def falsifier(check, url, slug, note):
    target = url or "page {}".format(slug)
    text = ("Re-run audit-metadata's inventory.py on a fresh capture of {}; this finding is "
            "retracted when `{}` is false.".format(target, check))
    if note and "decision" in note:
        text += " It is also not a defect if the owner confirms the setting is intentional."
    return text


def discard_previous(pkg):
    """A refused or failed build must not leave an earlier register standing."""
    gone = [f for f in (pkg / "register.json", pkg / "register.md") if f.exists()]
    for f in gone:
        f.unlink()
    for f in (pkg / "register.json.tmp", pkg / "register.md.tmp"):
        if f.exists():
            f.unlink()
    if gone:
        print("register: removed {} from an earlier build; it no longer described this "
              "evidence".format(" and ".join(f.name for f in gone)), file=sys.stderr)


def build(pkg, tool):
    pkg = Path(pkg).resolve()
    evdir = pkg / "evidence" / "metadata-audit"
    if not evdir.is_dir():
        print("register: no {} directory under {}; nothing to measure, so nothing to "
              "register".format("evidence/metadata-audit", pkg), file=sys.stderr)
        raise SystemExit(2)
    try:
        _build(pkg, evdir, Path(tool).resolve())
    except SystemExit as e:
        if e.code not in (0, None):
            discard_previous(pkg)
        raise
    except Exception as e:  # noqa: BLE001  an unreadable input, a bad encoding: unusable, not refused
        print("register: build failed on {}: {}".format(type(e).__name__, e), file=sys.stderr)
        discard_previous(pkg)
        raise SystemExit(2)


def _build(pkg, evdir, tool):
    if not tool.is_file():
        print("register: measuring tool not found: {}".format(tool), file=sys.stderr)
        raise SystemExit(2)
    tool_sha = sha256_of(tool)

    pages, findings, not_measured, checks_not_run, unknown, hashes = [], [], [], {}, {}, {}
    for page_dir in sorted(p for p in evdir.iterdir() if p.is_dir()):
        slug = page_dir.name
        # is_file() answers False for a directory that cannot be read, which would
        # make an unreadable page "not measured"; listing it raises instead.
        os.listdir(page_dir)
        if not (page_dir / "page.html").is_file():
            not_measured.append(slug)
            continue
        inputs = ["page.html"] + [n for n in OPTIONAL_INPUTS if input_present(page_dir, n)]
        absent = [n for n in OPTIONAL_INPUTS if n not in inputs]
        rel = lambda name: os.path.relpath(page_dir / name, pkg)  # noqa: E731
        for name in inputs:
            if not resolves(rel(name), pkg):
                print("register: {} resolves outside the package (a symlink or a path that "
                      "escapes it); evidence has to live inside the package".format(
                          page_dir / name), file=sys.stderr)
                raise SystemExit(2)
            hashes[rel(name)] = sha256_of(page_dir / name)
        ran_at = utc_iso()
        try:
            result = run_inventory(tool, page_dir, inputs)
        except RuntimeError as e:
            print("register: the measuring tool failed, so nothing is written. {}".format(e),
                  file=sys.stderr)
            raise SystemExit(2)
        as_of, as_of_file, as_of_source = as_of_for(page_dir, inputs)
        url = result.get("url")
        checks = dict(result.get("checks") or {})
        checks.update(robots_facts(result))
        checks.update(sitemap_facts(result))
        # One fact, one finding: near-zero text is also thin text.
        if checks.get("likely_js_rendered"):
            checks["thin_raw_text"] = False
        # Every skipped check carries its reason, so the page can say why rather
        # than filing an unanswerable question under "input not saved".
        skipped = {}
        for need, group in NEEDS.items():
            if need in absent:
                for c in group:
                    skipped[c] = "{} was not saved".format(need)
        for c, v in checks.items():
            if v is None and c not in skipped:
                skipped[c] = NOT_MEASURABLE.get(c, "not measurable from the inventory output")
        if skipped:
            checks_not_run[slug] = dict(sorted(skipped.items()))
            for c in skipped:
                checks.pop(c, None)
        for check in sorted(checks):
            if check not in RULES:
                unknown.setdefault(check, []).append(slug)
                continue
            if not checks[check]:
                continue
            rule = RULES[check]
            evidence = [rel("page.html")] + [rel(n) for n in rule["inputs"] if n in inputs]
            for extra in ("url", as_of_file):
                if extra in inputs and rel(extra) not in evidence:
                    evidence.append(rel(extra))
            finding = {
                "id": "metadata/{}/{}".format(slug, check),
                "page": slug,
                "url": url,
                "gate": rule["gate"],
                "severity": rule["severity"],
                "severitySource": rule["source"],
                "state": "Live",
                "asOf": as_of,
                "asOfSource": as_of_source,
                "measured": rule["measured"](result),
                "evidence": evidence,
                "whyItMatters": rule["why"],
                "howWeWouldKnowWeAreWrong": falsifier(check, url, slug, rule.get("note")),
                "measuredBy": {"tool": "audit-metadata/scripts/inventory.py", "sha256": tool_sha,
                               "check": check, "ranAt": ran_at},
            }
            if rule.get("note"):
                finding["severityNote"] = rule["note"]
            findings.append(finding)
        pages.append({"slug": slug, "url": url, "asOf": as_of, "asOfSource": as_of_source,
                      "ranAt": ran_at,
                      "evidence": [rel(n) for n in inputs], "inputsAbsent": absent,
                      "checksRun": sorted(c for c in checks if c in RULES),
                      "findings": sum(1 for f in findings if f["page"] == slug)})

    if unknown:
        print("register: refused. inventory.py emitted checks register.py has no severity "
              "row for, and a finding cannot be emitted unlabelled:", file=sys.stderr)
        for check, slugs in sorted(unknown.items()):
            print("  {} (on {})".format(check, ", ".join(slugs)), file=sys.stderr)
        print("  add a row to RULES in {} citing {}".format(Path(__file__).name, TREE),
              file=sys.stderr)
        raise SystemExit(1)
    if not pages:
        print("register: no page under {} has a page.html; nothing was measured, so nothing is "
              "registered (directories seen: {})".format(evdir, ", ".join(not_measured) or "none"),
              file=sys.stderr)
        raise SystemExit(2)

    findings.sort(key=lambda f: (f["gate"], f["severity"], f["id"]))
    register = {
        "schema": SCHEMA,
        "package": pkg.name,
        "generatedAt": utc_iso(),
        "measuredBy": {"tool": "audit-metadata/scripts/inventory.py", "sha256": tool_sha,
                       "invokedBy": "website-audit-package/scripts/register.py",
                       "python": ".".join(str(n) for n in sys.version_info[:3])},
        "pages": pages,
        "findings": findings,
        "evidenceHashes": hashes,
        "limits": {
            "sampleSize": len(pages),
            "pagesMeasured": [p["slug"] for p in pages],
            "pagesNotMeasured": not_measured,
            "checksNotRun": checks_not_run,
            "notes": [
                "Source: the metadata layer only. review-product-ux, web-perf and the capture "
                "emit no machine-readable findings yet, so nothing from them is in this register.",
                "State is Live as of each page's capture time (asOf, with asOfSource saying "
                "where it came from). Re-labelling against the tracker and the source branch is "
                "a human step this generator cannot take.",
                "Severity is the row audit-metadata's decision tree gives each check, applied by "
                "register.py; a severityNote marks where the tree is silent or depends on the "
                "page type.",
                "AI-crawler posture in robots.txt is a decision, not a defect, and is not emitted. "
                "When the general crawler has a robots.txt group of its own, whether that group "
                "blocks everything is not measurable from the inventory and is listed as not run; "
                "its own group is judged for the audited path.",
                "evidenceHashes were recorded by build and are compared by check, which does not "
                "re-measure: a file edited together with its recorded hash is not detected. A "
                "rebuild is how a register is brought back in line with its evidence.",
            ],
        },
    }
    problems = validate(register, pkg)
    if problems:
        print("register: refused its own output:", file=sys.stderr)
        for p in problems:
            print("  " + p, file=sys.stderr)
        raise SystemExit(1)
    reg_path, md_path = pkg / "register.json", pkg / "register.md"
    md_tmp, reg_tmp = md_path.with_suffix(".md.tmp"), reg_path.with_suffix(".json.tmp")
    md_tmp.write_text(render(register), encoding="utf-8")
    reg_tmp.write_text(json.dumps(register, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    os.replace(md_tmp, md_path)
    os.replace(reg_tmp, reg_path)
    print("register: {} findings over {} pages -> {}, {}".format(
        len(findings), len(pages), reg_path, md_path))


def resolves(pointer, pkg):
    if not isinstance(pointer, str) or not pointer or pointer.startswith("/"):
        return False
    if any(part == ".." for part in Path(pointer).parts):
        return False
    target = Path(os.path.realpath(pkg / pointer))
    root = Path(os.path.realpath(pkg))
    try:
        target.relative_to(root)
    except ValueError:
        return False
    return target.is_file()


def validate(register, pkg):
    pkg = Path(pkg)
    problems = []
    if register.get("schema") != SCHEMA:
        problems.append("schema is {!r}, expected {!r}".format(register.get("schema"), SCHEMA))
    pages = register.get("pages")
    findings = register.get("findings")
    limits = register.get("limits") or {}
    if not isinstance(pages, list) or not isinstance(findings, list):
        return problems + ["pages and findings must be lists"]
    slugs = {p.get("slug") for p in pages}
    hashes = register.get("evidenceHashes")
    if not isinstance(hashes, dict):
        problems.append("evidenceHashes is missing; nothing says what was measured")
        hashes = {}
    not_run = limits.get("checksNotRun") if isinstance(limits.get("checksNotRun"), dict) else {}
    run_by_page = {p.get("slug"): set(p.get("checksRun") or []) for p in pages}
    for slug, skipped in not_run.items():
        both = set(skipped or {}) & run_by_page.get(slug, set())
        if both:
            problems.append("page {}: {} listed both as run and as not run".format(
                slug, ", ".join(sorted(both))))

    def pointer_problems(where, ptr):
        if not resolves(ptr, pkg):
            return [where + " evidence pointer does not resolve inside the package: {}".format(ptr)]
        if ptr not in hashes:
            return [where + " evidence pointer has no recorded hash: {}".format(ptr)]
        if sha256_of(pkg / ptr) != hashes[ptr]:
            return [where + " evidence changed since it was measured: {}".format(ptr)]
        return []
    if limits.get("sampleSize") != len(pages):
        problems.append("limits.sampleSize is {} but {} pages were measured".format(
            limits.get("sampleSize"), len(pages)))
    if limits.get("pagesMeasured") != [p.get("slug") for p in pages]:
        problems.append("limits.pagesMeasured does not list the measured pages")
    if set(limits.get("pagesNotMeasured") or []) & slugs:
        problems.append("limits.pagesNotMeasured names a measured page")
    for p in pages:
        ev = p.get("evidence")
        if not isinstance(ev, list) or not ev:
            problems.append("page {}: evidence is empty".format(p.get("slug")))
            continue
        for ptr in ev:
            problems.extend(pointer_problems("page {}:".format(p.get("slug")), ptr))
    seen = set()
    for f in findings:
        fid = f.get("id") or "<no id>"
        where = "{}:".format(fid)
        if fid in seen:
            problems.append(where + " duplicate id")
        seen.add(fid)
        if f.get("page") not in slugs:
            problems.append(where + " page {!r} is not a measured page".format(f.get("page")))
        if not isinstance(f.get("gate"), int) or not 0 <= f["gate"] <= 6:
            problems.append(where + " gate must be 0-6")
        if f.get("severity") not in SEVERITIES:
            problems.append(where + " severity {!r} is not one of {}".format(
                f.get("severity"), "/".join(SEVERITIES)))
        if f.get("state") not in STATES:
            problems.append(where + " state {!r} is not one of the three states".format(f.get("state")))
        for key in ("asOf", "asOfSource", "measured", "whyItMatters", "howWeWouldKnowWeAreWrong"):
            if not isinstance(f.get(key), str) or not f[key].strip():
                problems.append(where + " {} is empty".format(key))
        ev = f.get("evidence")
        if not isinstance(ev, list) or not ev:
            problems.append(where + " evidence is empty; a claim with no pointer cannot stand")
        else:
            for ptr in ev:
                problems.extend(pointer_problems(where, ptr))
        mb = f.get("measuredBy") or {}
        for key in ("tool", "check", "ranAt"):
            if not isinstance(mb.get(key), str) or not mb[key].strip():
                problems.append(where + " measuredBy.{} is empty".format(key))
        # Provenance is checked against the table, not just for presence: a finding
        # claims the severity its check's row gives, and nothing else.
        rule = RULES.get(mb.get("check"))
        if rule is None:
            problems.append(where + " measuredBy.check {!r} is not a check register.py knows".format(
                mb.get("check")))
        else:
            if f.get("severity") != rule["severity"]:
                problems.append(where + " severity {!r} is not the {} the table gives `{}`".format(
                    f.get("severity"), rule["severity"], mb["check"]))
            if f.get("gate") != rule["gate"]:
                problems.append(where + " gate {!r} is not the {} the table gives `{}`".format(
                    f.get("gate"), rule["gate"], mb["check"]))
            if f.get("severitySource") not in (
                    rule["source"], rule["source"].replace(TREE, TREE_BEFORE_RENAME, 1)):
                problems.append(where + " severitySource is not the table's for `{}`".format(mb["check"]))
            if fid != "metadata/{}/{}".format(f.get("page"), mb["check"]):
                problems.append(where + " id does not name its page and check")
            if mb["check"] in (not_run.get(f.get("page")) or {}):
                problems.append(where + " the register says `{}` was not run on this page, yet "
                                        "here is a finding from it".format(mb["check"]))
            if mb["check"] not in run_by_page.get(f.get("page"), set()):
                problems.append(where + " `{}` is not in the page's checksRun".format(mb["check"]))
            # The pointers have to be the files the tool read for THIS page and check,
            # not any file that happens to exist: the page's own directory, including
            # page.html and every input the row needs.
            prefix = "evidence/metadata-audit/{}/".format(f.get("page"))
            page_ev = next((p.get("evidence") or [] for p in pages if p.get("slug") == f.get("page")), [])
            if isinstance(ev, list) and ev:
                for ptr in ev:
                    if not isinstance(ptr, str) or not ptr.startswith(prefix):
                        problems.append(where + " evidence pointer is not under {}: {}".format(
                            prefix, ptr))
                    elif ptr not in page_ev:
                        problems.append(where + " evidence pointer is not a file the tool read for "
                                                "this page: {}".format(ptr))
                for need in ("page.html",) + tuple(rule["inputs"]):
                    if prefix + need not in ev:
                        problems.append(where + " evidence does not cite {}, which `{}` is "
                                                "measured from".format(prefix + need, mb["check"]))
    return problems


def check(pkg):
    pkg = Path(pkg).resolve()
    reg_path = pkg / "register.json"
    if not reg_path.is_file():
        raise SystemExit("register check: no register.json under {}".format(pkg))
    try:
        register = json.loads(reg_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        raise SystemExit("register check: {} is not JSON: {}".format(reg_path, e))
    problems = validate(register, pkg)
    if problems:
        print("register check: {} problem(s) in {}".format(len(problems), reg_path), file=sys.stderr)
        for p in problems:
            print("  " + p, file=sys.stderr)
        raise SystemExit(1)
    print("register check: {} findings over {} pages; every evidence pointer resolves".format(
        len(register["findings"]), len(register["pages"])))


def render(register):
    lim = register["limits"]
    pages = register["pages"]
    findings = register["findings"]
    out = []
    out.append("# Findings register: {}".format(register["package"]))
    out.append("")
    out.append("Generated {} from the evidence layer by `register.py`, which ran "
               "`{}` (sha256 `{}`) on the saved inputs of every page below. {} over "
               "{}. Nothing on this page was typed by hand; every number traces to a "
               "file named beside it.".format(
                   register["generatedAt"], register["measuredBy"]["tool"],
                   register["measuredBy"]["sha256"][:12], _plural(len(findings), "finding"),
                   _plural(len(pages), "page")))
    out.append("")
    out.append("## Findings, by gate then severity")
    out.append("")
    if not findings:
        out.append("No check was true on any measured page.")
    for f in findings:
        head = "**{} · Gate {} · {}** `{}`".format(f["severity"], f["gate"], f["state"], f["id"])
        out.append("- {}".format(head))
        out.append("  - Measured: {} (as of {}, from the {})".format(
            f["measured"], f["asOf"], f["asOfSource"]))
        out.append("  - Why it matters: {}".format(f["whyItMatters"]))
        out.append("  - Evidence: {}".format(", ".join("`{}`".format(e) for e in f["evidence"])))
        out.append("  - How we would know we are wrong: {}".format(f["howWeWouldKnowWeAreWrong"]))
        if f.get("severityNote"):
            out.append("  - Severity note: {} ({})".format(f["severityNote"], f["severitySource"]))
        else:
            out.append("  - Severity source: {}".format(f["severitySource"]))
    out.append("")
    out.append("## Limits")
    out.append("")
    out.append("- Sample size: {} measured ({}).".format(
        _plural(lim["sampleSize"], "page"), ", ".join(lim["pagesMeasured"])))
    if lim["pagesNotMeasured"]:
        out.append("- Not measured, no page.html saved: {}.".format(", ".join(lim["pagesNotMeasured"])))
    if lim["checksNotRun"]:
        for slug, skipped in sorted(lim["checksNotRun"].items()):
            by_reason = {}
            for c, reason in skipped.items():
                by_reason.setdefault(reason, []).append(c)
            out.append("- Checks not run on {}: {}.".format(slug, "; ".join(
                "{} because {}".format(", ".join("`{}`".format(c) for c in sorted(cs)), reason)
                for reason, cs in sorted(by_reason.items()))))
    for note in lim["notes"]:
        out.append("- {}".format(note))
    out.append("")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build", help="measure the evidence layer and write register.json and register.md")
    b.add_argument("package", help="the audit package directory")
    b.add_argument("--inventory", default=None,
                   help="path to audit-metadata's inventory.py (default: the sibling skill's copy)")
    c = sub.add_parser("check", help="validate register.json against the package")
    c.add_argument("package", help="the audit package directory")
    args = ap.parse_args()
    if args.cmd == "build":
        build(args.package, args.inventory or default_inventory())
    else:
        check(args.package)


if __name__ == "__main__":
    main()
