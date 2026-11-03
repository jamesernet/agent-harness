"""Feed fetching, story identity, and selection."""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from html.parser import HTMLParser
from typing import Callable, Mapping
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

import feedparser
import httpx

Fetcher = Callable[[str], bytes]

TRACKING_PARAMS = {"fbclid", "gclid", "ref", "mc_cid", "mc_eid"}
USER_AGENT = "newsroom/0.1 (+https://github.com/jamesernet/agent-harness)"


@dataclass(frozen=True)
class Story:
    id: str
    title: str
    link: str
    canonical_link: str
    summary: str
    published: datetime | None
    source: str


class _Text(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.parts: list[str] = []

    def handle_data(self, data: str) -> None:
        self.parts.append(data)


def strip_html(text: str) -> str:
    p = _Text()
    p.feed(text or "")
    return re.sub(r"\s+", " ", " ".join(p.parts)).strip()


def canonical_link(url: str) -> str:
    """One shape for the same page however it was linked."""
    parts = urlsplit(url.strip())
    query = [
        (k, v)
        for k, v in parse_qsl(parts.query, keep_blank_values=True)
        if not k.lower().startswith("utm_") and k.lower() not in TRACKING_PARAMS
    ]
    query.sort()
    path = parts.path.rstrip("/") or "/"
    return urlunsplit((parts.scheme.lower(), parts.netloc.lower(), path, urlencode(query), ""))


def story_id(canonical: str, fallback: str) -> str:
    return hashlib.sha256((canonical or fallback).encode("utf-8")).hexdigest()[:12]


def http_fetch(url: str) -> bytes:
    with httpx.Client(timeout=30, follow_redirects=True, headers={"User-Agent": USER_AGENT}) as client:
        r = client.get(url)
        r.raise_for_status()
        return r.content


def _published(entry: Mapping) -> datetime | None:
    for key in ("published_parsed", "updated_parsed"):
        t = entry.get(key)
        if t:
            return datetime(*t[:6], tzinfo=timezone.utc)
    return None


def parse_feed(raw: bytes, *, feed_url: str, source_name: str = "", summary_chars: int = 600) -> list[Story]:
    parsed = feedparser.parse(raw)
    source = source_name or strip_html(parsed.feed.get("title", "")) or feed_url
    stories: list[Story] = []
    for e in parsed.entries:
        link = str(e.get("link", "") or "")
        canonical = canonical_link(link) if link else ""
        fallback = f"{feed_url}|{e.get('id') or e.get('title', '')}"
        content = e.get("content")
        body = content[0].get("value", "") if content else e.get("summary", "")
        summary = strip_html(body)[:summary_chars]
        stories.append(
            Story(
                id=story_id(canonical, fallback),
                title=strip_html(e.get("title", "")) or "(untitled)",
                link=link,
                canonical_link=canonical,
                summary=summary,
                published=_published(e),
                source=source,
            )
        )
    return stories


def fetch_all(sources, *, fetch: Fetcher = http_fetch, summary_chars: int = 600) -> tuple[list[Story], list[str]]:
    """Every story from every source, first-seen wins on id. Failures are returned, not raised."""
    seen: dict[str, Story] = {}
    errors: list[str] = []
    for src in sources:
        try:
            raw = fetch(src.url)
        except Exception as e:  # a dead feed must not kill the run
            errors.append(f"{src.url}: {e}")
            continue
        for s in parse_feed(raw, feed_url=src.url, source_name=src.name, summary_chars=summary_chars):
            seen.setdefault(s.id, s)
    return list(seen.values()), errors


def select(
    stories: list[Story],
    *,
    now: datetime,
    lookback_hours: int,
    seen: Mapping[str, str],
    skip_seen_days: int,
    max_stories: int,
) -> list[Story]:
    """Recent, not recently seen, newest first, capped."""
    cutoff = now - timedelta(hours=lookback_hours)
    today = now.date()
    out = []
    for s in stories:
        if s.published is not None and s.published < cutoff:
            continue
        first = seen.get(s.id)
        if first and 0 < (today - date.fromisoformat(first)).days < skip_seen_days:
            continue  # seen on an earlier day; a story first seen today stays, so a same-day rerun repeats itself
        out.append(s)
    out.sort(key=lambda s: (s.published or datetime.min.replace(tzinfo=timezone.utc)), reverse=True)
    return out[:max_stories]


def to_dict(story: Story) -> dict:
    return {
        "id": story.id,
        "title": story.title,
        "link": story.link,
        "canonical_link": story.canonical_link,
        "summary": story.summary,
        "published": story.published.isoformat() if story.published else None,
        "source": story.source,
    }


def from_dict(d: Mapping) -> Story:
    published = datetime.fromisoformat(d["published"]) if d.get("published") else None
    return Story(
        id=d["id"],
        title=d["title"],
        link=d.get("link", ""),
        canonical_link=d.get("canonical_link", ""),
        summary=d.get("summary", ""),
        published=published,
        source=d.get("source", ""),
    )
