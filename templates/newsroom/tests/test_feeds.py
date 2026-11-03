from datetime import timedelta

from conftest import FIXTURES, NOW, SOURCES, by_title, file_fetch

from newsroom import feeds
from newsroom.config import FeedSource


def test_canonical_link_strips_tracking_fragment_and_slash():
    a = feeds.canonical_link("https://Example.org/news/x/?utm_source=rss&b=2&a=1#top")
    b = feeds.canonical_link("https://example.org/news/x?a=1&fbclid=zzz&b=2")
    assert a == b == "https://example.org/news/x?a=1&b=2"


def test_same_story_from_two_feeds_is_one_story(stories):
    titles = [s.title for s in stories]
    assert "Supplement labelling rules proposed by regulator" not in titles  # the Atom copy collapsed into the RSS one
    assert len({s.id for s in stories}) == len(stories) == 7


def test_no_link_story_has_a_stable_id(stories):
    note = by_title(stories, "Note to readers")
    assert note.link == "" and len(note.id) == 12
    again, _ = feeds.fetch_all(SOURCES, fetch=file_fetch)
    assert by_title(again, "Note to readers").id == note.id


def test_html_is_stripped_and_summary_truncated():
    parsed = feeds.parse_feed((FIXTURES / "feed-rss.xml").read_bytes(), feed_url="x", summary_chars=50)
    council = next(s for s in parsed if s.title.startswith("City council"))
    assert "<" not in council.summary and council.summary.startswith("Example City's council voted 7 to 2")
    assert len(council.summary) == 50


def test_atom_content_and_source_title(stories):
    fees = by_title(stories, "Payment processor")
    assert fees.source == "Example Daily" and "blog post" in fees.summary and "<a" not in fees.summary


def test_select_drops_old_and_seen_and_caps(stories):
    picked = feeds.select(stories, now=NOW, lookback_hours=36, seen={}, skip_seen_days=3, max_stories=40)
    assert [s.title[:20] for s in picked][0] == "Regulator proposes n"  # newest first
    assert not any(s.title.startswith("Last month") for s in picked)
    assert len(picked) == 6
    seen = {picked[0].id: (NOW.date() - timedelta(days=1)).isoformat()}
    assert len(feeds.select(stories, now=NOW, lookback_hours=36, seen=seen, skip_seen_days=3, max_stories=40)) == 5
    old_seen = {picked[0].id: (NOW.date() - timedelta(days=10)).isoformat()}
    assert len(feeds.select(stories, now=NOW, lookback_hours=36, seen=old_seen, skip_seen_days=3, max_stories=2)) == 2


def test_dead_feed_is_reported_not_raised():
    def fetch(url):
        if "wire" in url:
            raise OSError("boom")
        return file_fetch(url)

    out, errors = feeds.fetch_all(SOURCES + [FeedSource("https://nowhere.example/x")], fetch=fetch)
    assert len(errors) == 2 and any("wire" in e for e in errors)
    assert len(out) == 2


def test_round_trip_dict(stories):
    s = stories[0]
    assert feeds.from_dict(feeds.to_dict(s)) == s
