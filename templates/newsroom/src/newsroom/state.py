"""The state file: idempotency keys and seen stories."""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path
from typing import Any

VERSION = 1


@dataclass
class State:
    path: Path | None
    seen: dict[str, str] = field(default_factory=dict)
    keys: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def load(cls, path: Path | None) -> "State":
        if path is None or not Path(path).is_file():
            return cls(path=Path(path) if path else None)
        data = json.loads(Path(path).read_text(encoding="utf-8"))
        return cls(path=Path(path), seen=dict(data.get("seen", {})), keys=dict(data.get("keys", {})))

    def save(self) -> None:
        if self.path is None:
            return
        self.path.parent.mkdir(parents=True, exist_ok=True)
        payload = {"version": VERSION, "seen": self.seen, "keys": self.keys}
        self.path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    def get(self, key: str) -> Any:
        return self.keys.get(key)

    def set(self, key: str, value: Any) -> None:
        self.keys[key] = value

    def mark_seen(self, ids: list[str], today: date) -> None:
        for i in ids:
            self.seen.setdefault(i, today.isoformat())


def triage_key(persona: str, day: date) -> str:
    return f"triage-{persona}-{day.isoformat()}"


def draft_key(persona: str, story: str, day: date) -> str:
    return f"draft-{persona}-{story}-{day.isoformat()}"


def debate_key(story: str, day: date) -> str:
    return f"debate-{story}-{day.isoformat()}"


def issue_key(story: str, day: date) -> str:
    return f"issue-{story}-{day.isoformat()}"
