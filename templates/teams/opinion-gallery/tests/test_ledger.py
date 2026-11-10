"""The ledger's own interface, tested without a cycle around it."""

from datetime import date

import pytest

from opinion_gallery.ledger import RECORD_VERSION, Ledger
from opinion_gallery.llm import LLMError
from opinion_gallery.state import State

DAY = date(2026, 11, 3)


def _ledger(**kw):
    return Ledger(state=State(path=None), day=DAY, failures=[], **kw)


def test_produces_once_then_reuses():
    led = _ledger()
    calls = []
    produce = lambda: (calls.append(1), "value")[1]  # noqa: E731
    assert led.once("draft", "skeptic", "abc", produce=produce) == "value"
    assert led.once("draft", "skeptic", "abc", produce=produce) == "value"
    assert len(calls) == 1


def test_a_failure_is_recorded_and_returns_none():
    led = _ledger()

    def boom():
        raise LLMError("the model declined")

    assert led.once("triage", "skeptic", produce=boom) is None
    assert led.failures == ["triage skeptic: the model declined"]


def test_only_the_named_exceptions_are_caught():
    led = _ledger()

    def boom():
        raise ZeroDivisionError("a bug, not a model failure")

    with pytest.raises(ZeroDivisionError):
        led.once("draft", "x", produce=boom)
    assert led.failures == []
    assert led.once("issue", "x", produce=boom, catching=(Exception,)) is None


def test_encode_and_decode_round_trip_through_the_record():
    led = _ledger()
    led.once("draft", "a", produce=lambda: {"body": "hi"}, encode=lambda v: v)
    record = led.state.get(led.key("draft", "a"))
    assert record == {"v": RECORD_VERSION, "day": "2026-11-03", "external": False, "value": {"body": "hi"}}
    assert led.once("draft", "a", produce=lambda: None, decode=lambda v: v["body"]) == "hi"


def test_an_unreadable_record_is_produced_again():
    led = _ledger()
    key = led.key("triage", "skeptic")
    for junk in ({"written_by": "an older shape"}, {"v": 99, "day": "2026-11-03", "external": False, "value": 1}, "nonsense"):
        led.state.set(key, junk)
        assert led.once("triage", "skeptic", produce=lambda: "fresh") == "fresh"


def test_a_decode_that_cannot_read_the_value_produces_again():
    led = _ledger()
    led.once("draft", "a", produce=lambda: {"wrong": "shape"})
    assert led.once("draft", "a", produce=lambda: "fresh", decode=lambda v: v["expected"]) == "fresh"


def test_force_forgets_todays_token_work_and_keeps_outward_effects():
    led = _ledger()
    led.once("draft", "a", produce=lambda: "draft")
    led.once("issue", "a", produce=lambda: "issue", external=True)
    yesterday = Ledger(state=led.state, day=date(2026, 11, 2), failures=[])
    yesterday.once("draft", "b", produce=lambda: "older draft")

    led.forget_redoable()

    assert led.state.get(led.key("draft", "a")) is None
    assert led.state.get(led.key("issue", "a")) is not None, "an issue already filed must not be filed twice"
    assert led.state.get(yesterday.key("draft", "b")) is not None, "only today's work is forgotten"


def test_a_preview_remembers_nothing():
    led = _ledger(writable=False)
    calls = []
    produce = lambda: (calls.append(1), "value")[1]  # noqa: E731
    assert led.once("draft", "a", produce=produce) == "value"
    assert led.once("draft", "a", produce=produce) == "value"
    assert len(calls) == 2 and led.state.keys == {}


def test_a_state_file_this_version_cannot_read_is_treated_as_absent(tmp_path):
    path = tmp_path / "state.json"
    for junk in ('{"version": 99, "seen": {"a": "2026-11-03"}}', "not json at all", '["a list"]'):
        path.write_text(junk)
        st = State.load(path)
        assert st.seen == {} and st.keys == {} and st.path == path
