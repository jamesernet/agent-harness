import json
import re
import shutil
from datetime import datetime, timezone
from pathlib import Path

import pytest

from newsroom import feeds
from newsroom.config import FeedSource
from newsroom.contract import load_contract
from newsroom.llm import FakeLLM

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "fixtures"
STARTER = ROOT / "contracts" / "starter"
NOW = datetime(2026, 11, 3, 6, 0, tzinfo=timezone.utc)
FEED_FILES = {
    "https://example.org/wire.xml": FIXTURES / "feed-rss.xml",
    "https://example.net/daily.atom": FIXTURES / "feed-atom.xml",
}
SOURCES = [FeedSource("https://example.org/wire.xml", "Example Wire"), FeedSource("https://example.net/daily.atom", "Example Daily")]


def file_fetch(url: str) -> bytes:
    return FEED_FILES[url].read_bytes()


def fill(text: str) -> str:
    """Replace every `<< blank >>` with a plain value so a persona file is usable."""
    return re.sub(r"<<\s*(.*?)\s*>>", lambda m: m.group(1).replace("/", "-"), text)


def write_contract(root: Path, *, personas=("skeptic", "strategist", "operator"), overrides: dict | None = None) -> Path:
    c = root / "contract"
    (c / "personas").mkdir(parents=True)
    shutil.copy(STARTER / "guardrails.md", c / "guardrails.md")
    (c / "shared.md").write_text("# Example Org\n\n## What the org does\n\nSells things to people.\n\n## Who reviews\n\nreviewer-one.\n")
    for name in personas:
        src = STARTER / "personas" / name / "persona.md"
        dst = c / "personas" / name
        dst.mkdir()
        (dst / "persona.md").write_text(fill(src.read_text()))
    cfg = {
        "org": {"name": "Example Org", "site": "https://example.org"},
        "feed": {"sources": [{"url": s.url, "name": s.name} for s in SOURCES], "sections": ["BUSINESS", "TECHNOLOGY", "POLICY", "SCIENCE", "CULTURE", "LOCAL"], "lookback_hours": 36, "max_stories": 40, "skip_seen_days": 3, "summary_chars": 600},
        "provider": {"kind": "fake", "model": "fake", "api_key_env": ""},
        "personas": {"enabled": list(personas), "draft_threshold": 4, "max_drafts_per_persona": 2},
        "debate": {"enabled": True, "max_participants": 3, "outcome": "auto", "max_words_per_reply": 250},
        "output": {
            "drafts_dir": str(root / "drafts"),
            "disclosure": "AI-drafted by {display_name}, an AI persona, on behalf of {org}. Unreviewed.",
            "github": {"repo": "example/repo", "labels": ["newsroom"], "assignees": ["reviewer-one"]},
        },
        "review": {"reviewers": ["reviewer-one"]},
        "guardrails": {"file": "guardrails.md", "modified": False},
        "run": {"state_file": str(root / "state.json"), "timezone": "UTC"},
    }
    for k, v in (overrides or {}).items():
        cfg[k].update(v)
    import yaml

    (c / "config.yml").write_text(yaml.safe_dump(cfg, sort_keys=False))
    return c


@pytest.fixture
def contract_dir(tmp_path):
    return write_contract(tmp_path)


@pytest.fixture
def contract(contract_dir):
    return load_contract(contract_dir)


@pytest.fixture
def fake_replies():
    return json.loads((FIXTURES / "fake_replies.json").read_text())


@pytest.fixture
def llm(fake_replies):
    return FakeLLM(fake_replies)


@pytest.fixture
def stories():
    out, errors = feeds.fetch_all(SOURCES, fetch=file_fetch)
    assert not errors
    return out


def by_title(stories, prefix: str):
    return next(s for s in stories if s.title.startswith(prefix))
