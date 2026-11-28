#!/usr/bin/env python3
"""Extract a page's machine-readable layer into JSON for auditing.

Stdlib only. Facts, not judgment: this reports what is present and pre-computes the
mechanical checks. The gates and severities live in the skill, not here.

Usage:
    python3 inventory.py page.html
    python3 inventory.py page.html --robots robots.txt --llms llms.txt --url https://x.com/p
    python3 inventory.py page.html --headers headers.txt --sitemap sitemap.xml
    curl -sL https://example.com/ | python3 inventory.py - --url https://example.com/

Capture the header dump with `curl -sIL <url> > headers.txt`. X-Robots-Tag only
exists there, and a noindex in a header is invisible to every HTML-only check.
"""

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
from html.parser import HTMLParser
from urllib.parse import urljoin, urlparse

VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link",
        "meta", "param", "source", "track", "wbr"}
SKIP_TEXT = {"script", "style", "noscript", "template", "svg"}
LANDMARKS = {"main", "article", "nav", "header", "footer", "aside", "section", "figure"}


class PageParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.html_attrs = {}
        self.title_parts = []
        self.in_title = False
        self.metas = []
        self.links = []
        self.jsonld_raw = []
        self._jsonld_buf = None
        self.headings = []
        self._heading = None
        self.images = []
        self.anchors = []
        self.microdata = []
        self.rdfa = []
        self.landmarks = {}
        self.tables = 0
        self.th = 0
        self.lists = 0
        self.text_parts = []
        self._skip_depth = 0
        self.iframes = []

    # -- helpers -------------------------------------------------------
    @staticmethod
    def _d(attrs):
        return {k.lower(): (v if v is not None else "") for k, v in attrs}

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        a = self._d(attrs)
        if tag in SKIP_TEXT:
            self._skip_depth += 1

        if tag == "html":
            self.html_attrs = a
        elif tag == "title":
            self.in_title = True
        elif tag == "meta":
            self.metas.append(a)
        elif tag == "link":
            self.links.append(a)
        elif tag == "script":
            if a.get("type", "").strip().lower() == "application/ld+json":
                self._jsonld_buf = []
        elif tag in ("h1", "h2", "h3", "h4", "h5", "h6"):
            self._heading = {"level": int(tag[1]), "text": []}
        elif tag == "img":
            self.images.append({
                "src": a.get("src", ""),
                "has_alt": "alt" in a,
                "alt": a.get("alt", ""),
                "loading": a.get("loading", ""),
            })
        elif tag == "a":
            self.anchors.append({"href": a.get("href", ""), "rel": a.get("rel", "")})
        elif tag == "table":
            self.tables += 1
        elif tag == "th":
            self.th += 1
        elif tag in ("ul", "ol"):
            self.lists += 1
        elif tag == "iframe":
            self.iframes.append(a.get("src", ""))

        if tag in LANDMARKS:
            self.landmarks[tag] = self.landmarks.get(tag, 0) + 1
        if "itemscope" in a or "itemtype" in a:
            self.microdata.append({"tag": tag, "itemtype": a.get("itemtype", ""),
                                   "itemprop": a.get("itemprop", "")})
        if "typeof" in a or "vocab" in a:
            self.rdfa.append({"tag": tag, "typeof": a.get("typeof", ""),
                              "vocab": a.get("vocab", "")})

    def handle_endtag(self, tag):
        tag = tag.lower()
        if tag in SKIP_TEXT and self._skip_depth:
            self._skip_depth -= 1
        if tag == "title":
            self.in_title = False
        elif tag == "script" and self._jsonld_buf is not None:
            self.jsonld_raw.append("".join(self._jsonld_buf))
            self._jsonld_buf = None
        elif tag in ("h1", "h2", "h3", "h4", "h5", "h6") and self._heading:
            txt = re.sub(r"\s+", " ", "".join(self._heading["text"])).strip()
            self.headings.append({"level": self._heading["level"], "text": txt})
            self._heading = None

    def handle_data(self, data):
        if self.in_title:
            self.title_parts.append(data)
        if self._jsonld_buf is not None:
            self._jsonld_buf.append(data)
            return
        if self._heading is not None:
            self._heading["text"].append(data)
        if not self._skip_depth:
            self.text_parts.append(data)


def collect_types(node, types, ids, refs, depth=0):
    """Walk a parsed JSON-LD structure gathering @type, @id and @id references.

    Definitions and references must be counted apart. A node carrying @type
    defines an entity; a bare {"@id": ...} only points at one. Pooling them
    makes correct @graph wiring — where every entity is referenced at least
    once — look like a page full of duplicate-@id collisions.
    """
    if depth > 40:
        return
    if isinstance(node, dict):
        t = node.get("@type")
        if isinstance(t, str):
            types.append(t)
        elif isinstance(t, list):
            types.extend(x for x in t if isinstance(x, str))
        i = node.get("@id")
        if isinstance(i, str):
            (ids if t is not None else refs).append(i)
        for v in node.values():
            collect_types(v, types, ids, refs, depth + 1)
    elif isinstance(node, list):
        for v in node:
            collect_types(v, types, ids, refs, depth + 1)


def parse_jsonld(blocks):
    out = []
    for idx, raw in enumerate(blocks):
        entry = {"index": idx, "chars": len(raw)}
        stripped = raw.strip()
        stripped = re.sub(r"^<!\[CDATA\[", "", stripped)
        stripped = re.sub(r"\]\]>$", "", stripped).strip()
        entry["had_cdata_wrapper"] = stripped != raw.strip()
        try:
            data = json.loads(stripped)
            entry["valid"] = True
            types, ids, refs = [], [], []
            collect_types(data, types, ids, refs)
            entry["types"] = types
            entry["ids"] = ids
            entry["refs"] = refs
            ctx = data.get("@context") if isinstance(data, dict) else None
            entry["context"] = ctx if isinstance(ctx, str) else (
                "non-string" if ctx is not None else None)
            entry["has_graph"] = isinstance(data, dict) and "@graph" in data
            entry["top_level_keys"] = sorted(data.keys()) if isinstance(data, dict) else "array"
            entry["data"] = data
        except json.JSONDecodeError as e:
            entry["valid"] = False
            entry["error"] = str(e)
            entry["error_line"] = e.lineno
            entry["error_col"] = e.colno
            snip_start = max(0, e.pos - 90)
            entry["error_context"] = stripped[snip_start:e.pos + 90]
            # cheap hints for the usual culprits
            hints = []
            if re.search(r",\s*[}\]]", stripped):
                hints.append("trailing comma before } or ]")
            if re.search(r"[\u2018\u2019\u201c\u201d]", stripped):
                hints.append("smart/curly quotes present")
            if "{{" in stripped or "{%" in stripped:
                hints.append("unrendered template placeholder")
            if "<!--" in stripped:
                hints.append("HTML comment inside script")
            if "&quot;" in stripped or "&amp;" in stripped:
                hints.append("HTML-escaped entities inside JSON")
            entry["hints"] = hints
        out.append(entry)
    return out


def parse_robots(text):
    """Group-aware robots.txt parse. Groups do not inherit — that matters."""
    groups, current, sitemaps, other = [], None, [], []
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line or ":" not in line:
            continue
        field, _, value = line.partition(":")
        field, value = field.strip().lower(), value.strip()
        if field == "user-agent":
            if current and current["rules"]:
                groups.append(current)
                current = None
            if current is None:
                current = {"agents": [], "rules": []}
            current["agents"].append(value)
        elif field == "sitemap":
            sitemaps.append(value)
        elif field in ("allow", "disallow", "crawl-delay", "noindex"):
            if current is None:
                other.append({field: value})
            else:
                current["rules"].append({field: value})
        else:
            other.append({field: value})
    if current:
        groups.append(current)
    return {"groups": groups, "sitemaps": sitemaps, "unrecognized": other}


# Types are case-sensitive; these near-misses are silently ignored by consumers.
MISCASED = {
    "Blogposting": "BlogPosting", "BlogPost": "BlogPosting", "Newsarticle": "NewsArticle",
    "Localbusiness": "LocalBusiness", "Faqpage": "FAQPage", "FaqPage": "FAQPage",
    "Qapage": "QAPage", "Breadcrumblist": "BreadcrumbList", "Webpage": "WebPage",
    "Website": "WebSite", "Imageobject": "ImageObject", "Videoobject": "VideoObject",
    "Postaladdress": "PostalAddress", "Aggregaterating": "AggregateRating",
    "Jobposting": "JobPosting", "Contactpoint": "ContactPoint", "Howto": "HowTo",
    "Listitem": "ListItem", "Openinghoursspecification": "OpeningHoursSpecification",
    "Product ": "Product", "organization": "Organization", "product": "Product",
    "article": "Article", "person": "Person",
}

AI_TRAINING = ["gptbot", "ccbot", "google-extended", "applebot-extended", "claudebot",
               "anthropic-ai", "bytespider", "meta-externalagent", "facebookbot",
               "amazonbot", "diffbot", "omgili", "timpibot"]
AI_ANSWER = ["oai-searchbot", "chatgpt-user", "perplexitybot", "perplexity-user",
             "claude-user", "claude-searchbot", "bingbot", "google-cloudvertexbot",
             "duckassistbot", "mistralai-user"]


def rule_regex(pattern):
    """Compile a robots.txt path pattern: `*` is any run of characters and a
    trailing `$` anchors to the end of the path (RFC 9309)."""
    anchored = pattern.endswith("$")
    body = pattern[:-1] if anchored else pattern
    rx = "".join(".*" if ch == "*" else re.escape(ch) for ch in body)
    return re.compile("^" + rx + ("$" if anchored else ""))


def path_allowed(rules, path):
    """Resolve one path against one group's rules.

    Precedence is RFC 9309: the longest matching pattern wins, and Allow wins a
    tie. Both halves matter. Ignoring Allow reports `Disallow: /` + `Allow: /x/`
    as a site-wide block, which is a fabricated P0; ignoring `*` and `$` misses
    a real one.
    """
    best = None
    for r in rules:
        for field in ("allow", "disallow"):
            pat = r.get(field)
            # `Disallow:` with an empty value grants access; it is not a rule
            # matching every path.
            if not pat:
                continue
            if not rule_regex(pat).match(path):
                continue
            key = (len(pat), field == "allow")
            if best is None or key > best[0]:
                best = (key, field, pat)
    if best is None:
        return {"allowed": True, "matched_rule": None}
    return {"allowed": best[1] == "allow", "matched_rule": {best[1]: best[2]}}


def analyze_robots(parsed, path=None):
    named = {}
    for g in parsed["groups"]:
        for a in g["agents"]:
            named.setdefault(a.lower(), []).extend(g["rules"])

    def rules_for(agent):
        # Groups do not inherit. An agent obeys its own group if it has one and
        # the `*` group otherwise — never both.
        return named.get(agent, named.get("*", []))

    def blocks_everything(rules):
        # A representative deep path, so `Disallow: /*` counts alongside
        # `Disallow: /`.
        return not path_allowed(rules, "/a/b/c")["allowed"]

    out = {
        "groups_count": len(parsed["groups"]),
        "sitemaps": parsed["sitemaps"],
        "has_sitemap_line": bool(parsed["sitemaps"]),
        "named_agents": sorted(named.keys()),
        "ai_training_named": [a for a in AI_TRAINING if a in named],
        "ai_answer_named": [a for a in AI_ANSWER if a in named],
        "unrecognized_fields": parsed["unrecognized"],
    }
    out["ai_training_blocked"] = [a for a in out["ai_training_named"]
                                  if blocks_everything(named[a])]
    out["ai_answer_blocked"] = [a for a in out["ai_answer_named"]
                                if blocks_everything(named[a])]
    out["wildcard_blocks_all"] = blocks_everything(named.get("*", []))
    if path:
        # Gate 1 asks only about the search crawler. Pooling matches across
        # every group turns a deliberately blocked GPTBot into a false
        # site-wide P0, so the AI agents are answered separately at Gate 2.
        out["path_access"] = {
            "path": path,
            "general_crawler": path_allowed(rules_for("googlebot"), path),
            "ai_agents": {a: path_allowed(named[a], path)
                          for a in out["ai_training_named"] + out["ai_answer_named"]},
        }
    return out


def analyze_llms(text):
    lines = text.splitlines()
    h1 = [l for l in lines if l.startswith("# ")]
    h2 = [l for l in lines if l.startswith("## ")]
    md_links = re.findall(r"\[([^\]]*)\]\(([^)]+)\)", text)
    blockquote_after_h1 = False
    for i, l in enumerate(lines):
        if l.startswith("# "):
            for nxt in lines[i + 1:i + 5]:
                if nxt.strip().startswith(">"):
                    blockquote_after_h1 = True
                    break
            break
    return {
        "bytes": len(text.encode("utf-8")),
        "h1_count": len(h1),
        "h1": h1[:3],
        "h2_sections": [l[3:].strip() for l in h2],
        "has_blockquote_summary": blockquote_after_h1,
        "link_count": len(md_links),
        "relative_links": [u for _, u in md_links if not u.startswith(("http://", "https://"))],
        "has_optional_section": any("optional" in s.lower() for s in
                                    [l[3:].strip() for l in h2]),
        "looks_like_robots_syntax": bool(re.search(r"(?im)^\s*(user-agent|disallow)\s*:", text)),
        "looks_like_html": text.lstrip()[:200].lower().startswith(("<!doctype", "<html")),
    }


def analyze_headers(text):
    """Parse a `curl -sIL` dump. X-Robots-Tag lives only here, and a redirect
    chain is a Gate 0 fact the HTML cannot show."""
    statuses, headers = [], {}
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.upper().startswith("HTTP/"):
            parts = line.split()
            statuses.append(int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else None)
            continue
        if ":" in line:
            k, _, v = line.partition(":")
            headers.setdefault(k.strip().lower(), []).append(v.strip())
    xrt = headers.get("x-robots-tag", [])
    lowered = " ".join(xrt).lower()
    return {
        "status": statuses[-1] if statuses else None,
        "status_chain": statuses,
        "redirect_hops": max(0, len(statuses) - 1),
        "content_type": (headers.get("content-type") or [None])[0],
        "x_robots_tag": xrt,
        "x_robots_noindex": "noindex" in lowered,
        "x_robots_nosnippet": "nosnippet" in lowered or "max-snippet:0" in lowered,
        "location": headers.get("location", []),
        "headers": headers,
    }


def analyze_sitemap(text, url=None):
    """Structural facts about an XML sitemap: is it well-formed, and is the
    audited URL actually discoverable through it."""
    out = {"bytes": len(text.encode("utf-8"))}
    if "<!ENTITY" in text:
        # No legitimate sitemap declares entities, and expanding them from an
        # untrusted document is a denial-of-service vector.
        out["valid"] = False
        out["error"] = "entity declaration present; refused to parse"
        out["root"] = None
    else:
        try:
            out["root"] = ET.fromstring(text).tag.split("}")[-1]
            out["valid"] = True
        except ET.ParseError as e:
            out["valid"] = False
            out["error"] = str(e)
            out["root"] = None
    out["is_index"] = out["root"] == "sitemapindex"
    # Read <loc> textually so a namespaced or slightly malformed file still
    # yields its URLs rather than nothing at all.
    locs = [m.strip() for m in re.findall(r"<loc>\s*(.*?)\s*</loc>", text, re.S | re.I)]
    lastmods = [m.strip() for m in re.findall(r"<lastmod>\s*(.*?)\s*</lastmod>", text, re.S | re.I)]
    out["url_count"] = len(locs)
    out["sample"] = locs[:20]
    out["relative_locs"] = [u for u in locs if not u.startswith(("http://", "https://"))][:10]
    out["lastmod_count"] = len(lastmods)
    out["lastmod_invalid"] = [d for d in lastmods
                              if not re.match(r"^\d{4}-\d{2}-\d{2}([T ].*)?$", d)][:10]
    if url:
        out["contains_audited_url"] = url.rstrip("/") in {u.rstrip("/") for u in locs}
    return out


def build(html, robots_text=None, llms_text=None, url=None,
          headers_text=None, sitemap_text=None):
    p = PageParser()
    p.feed(html)

    def meta_get(*names, prop=False):
        key = "property" if prop else "name"
        for m in p.metas:
            if m.get(key, "").lower() in names:
                return m.get("content", "")
        return None

    title = re.sub(r"\s+", " ", "".join(p.title_parts)).strip()
    desc = meta_get("description")
    robots_meta = meta_get("robots")
    googlebot_meta = meta_get("googlebot")
    # Two conflicting canonicals make Google ignore both, so the count is the
    # finding — reporting only the first hides it.
    canonicals = [l.get("href") for l in p.links
                  if "canonical" in l.get("rel", "").lower()]
    canonical = canonicals[0] if canonicals else None
    hreflangs = [{"lang": l.get("hreflang"), "href": l.get("href")}
                 for l in p.links if l.get("hreflang")]

    og = {m.get("property", "")[3:]: m.get("content", "") for m in p.metas
          if m.get("property", "").lower().startswith("og:")}
    tw = {m.get("name", "")[8:]: m.get("content", "") for m in p.metas
          if m.get("name", "").lower().startswith("twitter:")}

    body_text = re.sub(r"\s+", " ", " ".join(p.text_parts)).strip()
    words = len(body_text.split())

    jsonld = parse_jsonld(p.jsonld_raw)
    all_types = sorted({t for b in jsonld if b.get("valid") for t in b.get("types", [])})
    all_ids = [i for b in jsonld if b.get("valid") for i in b.get("ids", [])]
    all_refs = [i for b in jsonld if b.get("valid") for i in b.get("refs", [])]
    dangling_refs = sorted({i for i in all_refs if i not in set(all_ids)})

    origin = ""
    path = None
    if url:
        u = urlparse(url)
        origin = f"{u.scheme}://{u.netloc}"
        path = u.path or "/"

    internal = external = 0
    for a in p.anchors:
        h = a["href"]
        if not h or h.startswith(("#", "mailto:", "tel:", "javascript:")):
            continue
        if h.startswith(("http://", "https://")):
            if origin and h.startswith(origin):
                internal += 1
            else:
                external += 1
        else:
            internal += 1

    # heading outline integrity
    levels = [h["level"] for h in p.headings]
    skipped = []
    for prev, cur in zip(levels, levels[1:]):
        if cur - prev > 1:
            skipped.append({"from": prev, "to": cur})

    out = {
        "url": url,
        "html_bytes": len(html.encode("utf-8", "replace")),
        "head": {
            "lang": p.html_attrs.get("lang"),
            "title": title or None,
            "title_len": len(title) if title else 0,
            "meta_description": desc,
            "meta_description_len": len(desc) if desc else 0,
            "meta_robots": robots_meta,
            "meta_robots_googlebot": googlebot_meta,
            "canonical": canonical,
            "canonical_count": len(canonicals),
            "canonicals": canonicals,
            "canonical_is_absolute": bool(canonical and canonical.startswith(("http://", "https://"))),
            "canonical_is_self": bool(canonical and url and
                                      urljoin(url, canonical).rstrip("/") == url.rstrip("/")),
            "hreflang": hreflangs,
            "has_viewport": meta_get("viewport") is not None,
            "meta_keywords_present": meta_get("keywords") is not None,
            "open_graph": og,
            "twitter": tw,
            "meta_count": len(p.metas),
        },
        "structured_data": {
            "jsonld_block_count": len(jsonld),
            "jsonld_valid_count": sum(1 for b in jsonld if b.get("valid")),
            "jsonld_invalid_count": sum(1 for b in jsonld if not b.get("valid")),
            "types_found": all_types,
            "ids_found": sorted(set(all_ids)),
            "duplicate_ids": sorted({i for i in all_ids if all_ids.count(i) > 1}),
            "refs_found": sorted(set(all_refs)),
            "dangling_refs": dangling_refs,
            "relative_ids": [i for i in set(all_ids)
                             if not i.startswith(("http://", "https://"))],
            "microdata_nodes": len(p.microdata),
            "microdata_types": sorted({m["itemtype"] for m in p.microdata if m["itemtype"]}),
            "rdfa_nodes": len(p.rdfa),
            "blocks": jsonld,
        },
        "content": {
            "word_count": words,
            "heading_count": len(p.headings),
            "h1_count": sum(1 for h in p.headings if h["level"] == 1),
            "outline": p.headings[:60],
            "skipped_levels": skipped,
            "semantic_landmarks": p.landmarks,
            "images_total": len(p.images),
            "images_missing_alt": sum(1 for i in p.images if not i["has_alt"]),
            "images_empty_alt": sum(1 for i in p.images if i["has_alt"] and not i["alt"].strip()),
            "tables": p.tables,
            "table_headers": p.th,
            "lists": p.lists,
            "iframes": len(p.iframes),
            "links_internal": internal,
            "links_external": external,
            "nofollow_links": sum(1 for a in p.anchors if "nofollow" in a["rel"].lower()),
            "text_sample": body_text[:600],
        },
    }

    if robots_text is not None:
        out["robots_txt"] = analyze_robots(parse_robots(robots_text), path)
        out["robots_txt"]["looks_like_html"] = robots_text.lstrip()[:200].lower().startswith(
            ("<!doctype", "<html"))
    if llms_text is not None:
        out["llms_txt"] = analyze_llms(llms_text)
    response = analyze_headers(headers_text) if headers_text is not None else None
    if response is not None:
        out["response"] = response
    if sitemap_text is not None:
        out["sitemap"] = analyze_sitemap(sitemap_text, url)

    # pre-computed mechanical checks so judgment isn't spent on arithmetic
    # meta name="googlebot" overrides name="robots" for Google specifically, so
    # a noindex living only there is invisible if you read the generic tag alone.
    r = " ".join(x.lower() for x in (robots_meta, googlebot_meta) if x)
    out["checks"] = {
        "meta_noindex": "noindex" in r,
        "meta_nofollow": "nofollow" in r,
        "meta_nosnippet": "nosnippet" in r or "max-snippet:0" in r,
        "meta_noarchive": "noarchive" in r,
        "title_missing": not title,
        "title_over_60": len(title) > 60 if title else False,
        "description_missing": not desc,
        "description_over_160": len(desc) > 160 if desc else False,
        "canonical_missing": canonical is None,
        "canonical_conflicting": len({c for c in canonicals if c}) > 1,
        "lang_missing": not p.html_attrs.get("lang"),
        "og_incomplete": not all(k in og for k in ("title", "description", "image")),
        "og_image_relative": bool(og.get("image") and
                                  not og["image"].startswith(("http://", "https://"))),
        "no_structured_data": len(jsonld) == 0 and len(p.microdata) == 0 and len(p.rdfa) == 0,
        "invalid_jsonld_present": any(not b.get("valid") for b in jsonld),
        "jsonld_and_microdata_both": len(jsonld) > 0 and len(p.microdata) > 0,
        "microdata_only": len(jsonld) == 0 and len(p.microdata) > 0,
        "graph_unwired": bool(all_types) and not all_ids,
        "graph_dangling_refs": bool(dangling_refs),
        "bad_context": any(b.get("valid") and b.get("context") not in
                           ("https://schema.org", "http://schema.org", None)
                           for b in jsonld),
        "http_context": any(b.get("context") == "http://schema.org" for b in jsonld),
        "suspect_type_casing": [t for t in all_types if t in MISCASED],
        "h1_missing": not any(h["level"] == 1 for h in p.headings),
        "h1_multiple": sum(1 for h in p.headings if h["level"] == 1) > 1,
        "heading_levels_skipped": bool(skipped),
        "no_semantic_landmarks": not p.landmarks,
        "thin_raw_text": words < 200,
        "likely_js_rendered": words < 60 and len(html) > 20000,
        "images_missing_alt": sum(1 for i in p.images if not i["has_alt"]) > 0,
        "table_without_headers": p.tables > 0 and p.th == 0,
    }
    if response is not None:
        out["checks"].update({
            "header_noindex": response["x_robots_noindex"],
            "header_nosnippet": response["x_robots_nosnippet"],
            "status_not_200": response["status"] not in (200, None),
            "redirect_chain": response["redirect_hops"] > 1,
        })
    if sitemap_text is not None:
        out["checks"]["url_absent_from_sitemap"] = (
            out["sitemap"].get("contains_audited_url") is False
            and not out["sitemap"]["is_index"])
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("html", help="path to HTML file, or - for stdin")
    ap.add_argument("--robots", help="path to a saved robots.txt")
    ap.add_argument("--llms", help="path to a saved llms.txt")
    ap.add_argument("--headers", help="path to a `curl -sIL <url>` dump; X-Robots-Tag "
                                      "and the redirect chain live only here")
    ap.add_argument("--sitemap", help="path to a saved sitemap.xml")
    ap.add_argument("--url", help="canonical URL of the page, improves several checks")
    ap.add_argument("--compact", action="store_true",
                    help="omit full parsed JSON-LD data and text sample")
    args = ap.parse_args()

    def read(path):
        if path == "-":
            return sys.stdin.read()
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()

    result = build(
        read(args.html),
        read(args.robots) if args.robots else None,
        read(args.llms) if args.llms else None,
        args.url,
        read(args.headers) if args.headers else None,
        read(args.sitemap) if args.sitemap else None,
    )

    if args.compact:
        for b in result["structured_data"]["blocks"]:
            b.pop("data", None)
        result["content"].pop("text_sample", None)

    json.dump(result, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
