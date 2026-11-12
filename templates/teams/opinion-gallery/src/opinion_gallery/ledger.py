"""Produce once per key, ever, and know which repeats are safe.

A step that only spends tokens may be repeated: the gallery pays again and gets
another answer of the same kind. An effect the world can see may not, because
filing a second issue is not a repeat to anyone but us. That difference is
recorded next to each result, so forgetting work never depends on how a key
happens to be spelled.

Callers hand over a key and a thunk. They do not build keys, decide what a
rerun forgets, encode records, or decide what a failure does.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date
from typing import Any, Callable, Iterable, TypeVar

from .llm import LLMError
from .state import State

RECORD_VERSION = 1

T = TypeVar("T")


@dataclass
class Ledger:
    """One record per key. `writable` false previews without remembering anything."""

    state: State
    day: date
    failures: list[str] = field(default_factory=list)
    writable: bool = True

    def key(self, kind: str, *parts: str) -> str:
        return "-".join([kind, *parts, self.day.isoformat()])

    def forget_redoable(self) -> None:
        """What a forced rerun forgets: today's work that only cost tokens.

        Reads the record rather than the key, so a key's spelling cannot decide
        whether an outward effect is repeated.
        """
        today = self.day.isoformat()
        self.state.keys = {
            key: record
            for key, record in self.state.keys.items()
            if not (self._readable(record) and record["day"] == today and not record["external"])
        }

    def once(
        self,
        kind: str,
        *parts: str,
        produce: Callable[[], T],
        decode: Callable[[Any], T] | None = None,
        encode: Callable[[T], Any] | None = None,
        external: bool = False,
        catching: Iterable[type[BaseException]] = (LLMError,),
    ) -> T | None:
        """The recorded result for this key, else produce it and record it.

        Returns None when producing failed; the reason lands in `failures` and the
        caller carries on with the rest of the run. A record this version cannot
        read is treated as absent, so an older state file costs a repeat rather
        than the whole run.
        """
        key = self.key(kind, *parts)
        record = self.state.get(key)
        if self._readable(record):
            try:
                return decode(record["value"]) if decode else record["value"]
            except (TypeError, KeyError, ValueError):
                pass  # written by a shape this version does not know; produce it again

        try:
            value = produce()
        except tuple(catching) as e:
            self.failures.append(f"{' '.join([kind, *parts])}: {e}")
            return None

        if self.writable:
            self.state.set(
                key,
                {
                    "v": RECORD_VERSION,
                    "day": self.day.isoformat(),
                    "external": external,
                    "value": encode(value) if encode else value,
                },
            )
            self.state.save()
        return value

    @staticmethod
    def _readable(record: Any) -> bool:
        return (
            isinstance(record, dict)
            and record.get("v") == RECORD_VERSION
            and isinstance(record.get("day"), str)
            and isinstance(record.get("external"), bool)
            and "value" in record
        )
