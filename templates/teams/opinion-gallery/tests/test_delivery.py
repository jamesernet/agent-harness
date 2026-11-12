from datetime import date

import yaml
from conftest import NOW

from opinion_gallery import delivery
from opinion_gallery.pipeline import Draft, Outcome, Reply


def _fm(text):
    return yaml.safe_load(text.split("---\n")[1])


def test_slugify_and_headline():
    assert delivery.slugify("Regulator proposes NEW rules, for pets!") == "regulator-proposes-new-rules-for-pets"
    assert delivery.split_headline("# Hello\n\nbody", "fb") == ("Hello", "body")
    assert delivery.split_headline("no heading", "fb") == ("fb", "no heading")


def test_render_single(contract, stories):
    story = stories[0]
    out = Outcome("single", (Draft("skeptic", story.id, "SCIENCE", 5, "why", "# Head\n\nBody."),))
    text = delivery.render(contract, story, out, NOW)
    fm = _fm(text)
    assert fm["kind"] == "draft" and fm["persona"] == "skeptic" and fm["status"] == "unreviewed" and fm["stance"] == 5
    assert fm["story_url"] == story.link and fm["story_date"] == "2026-11-03"
    assert "> AI-drafted by The Evidence Desk, an AI persona, on behalf of Example Org." in text
    assert "# Head\n\nBody." in text and text.rstrip().endswith(story.link)


def test_render_two_views_and_merged(contract, stories):
    story = stories[0]
    drafts = [Draft("skeptic", story.id, "SCIENCE", 5, "r", "# A\n\nAA"), Draft("strategist", story.id, "POLICY", 4, "r", "# B\n\nBB")]
    replies = [Reply("skeptic", "stand", "I stand."), Reply("strategist", "stand", "So do I.")]
    text = delivery.render(contract, story, Outcome("two-views", tuple(drafts), tuple(replies)), NOW)
    fm = _fm(text)
    assert fm["kind"] == "two-views" and fm["personas"] == ["skeptic", "strategist"] and fm["stances"] == {"skeptic": 5, "strategist": 4}
    assert "## The Evidence Desk: A" in text and "## The Long View: B" in text and "I stand." in text
    assert "AI-drafted by The Evidence Desk and The Long View" in text
    merged = Outcome("merged", tuple(drafts[:1]), tuple(replies), merged_body="# M\n\nMM", withdrew=("strategist",))
    text = delivery.render(contract, story, merged, NOW)
    fm = _fm(text)
    assert fm["kind"] == "merged" and fm["merged_after_debate_with"] == ["strategist"]
    assert "# M\n\nMM" in text and "Merged after a debate with The Long View" in text


def test_piece_path(stories, tmp_path):
    story = stories[0]
    single = Outcome("single", (Draft("skeptic", story.id, "S", 5, "", ""),))
    p = delivery.piece_path(tmp_path, date(2026, 11, 3), story, single)
    assert p.parent == tmp_path / "2026-11-03"
    assert p.name == f"{story.id}-{delivery.slugify(story.title)}-skeptic.md" and p.name.startswith(f"{story.id}-regulator-proposes")
    assert delivery.piece_path(tmp_path, date(2026, 11, 3), story, Outcome("two-views")).name.endswith("-two-views.md")
    assert delivery.piece_path(tmp_path, date(2026, 11, 3), story, Outcome("merged")).name.endswith("-merged.md")


def test_open_issue_builds_gh_argv_and_parses_url():
    seen = []

    def runner(argv):
        seen.append(argv)
        return "Creating issue in example/repo\nhttps://github.com/example/repo/issues/42\n"

    ref = delivery.open_issue(runner, repo="example/repo", title="t", body="b", labels=["x", "y"], assignees=["z"])
    assert ref.number == 42 and ref.url.endswith("/issues/42")
    argv = seen[0]
    assert argv[:4] == ["gh", "issue", "create", "--repo"] and argv[4] == "example/repo"
    assert argv.count("--label") == 2 and "--assignee" in argv and "--body-file" in argv
    assert len(seen) == 1
