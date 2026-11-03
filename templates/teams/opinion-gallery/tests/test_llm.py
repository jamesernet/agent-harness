import json

import httpx
import pytest

from opinion_gallery import llm as llm_mod
from opinion_gallery.llm import AnthropicLLM, FakeLLM, LLMError, LLMJsonError, OpenAICompatLLM, complete_json, extract_json, validate

SCHEMA = {"type": "object", "required": ["a"], "properties": {"a": {"type": "integer", "minimum": 0}}}


@pytest.mark.parametrize(
    "text",
    ['{"a": 1}', 'Sure, here you go:\n{"a": 1}\nHope that helps', '```json\n{"a": 1}\n```', '```\n{"a": 1}\n```'],
)
def test_extract_json_tolerates_prose_and_fences(text):
    assert extract_json(text) == {"a": 1}


def test_extract_json_fails_on_nothing():
    with pytest.raises(LLMJsonError):
        extract_json("no object here")
    with pytest.raises(LLMJsonError):
        extract_json("{not json}")


def test_validate_catches_shape_errors():
    validate({"a": 2}, SCHEMA)
    for bad in ({}, {"a": "x"}, {"a": -1}, {"a": True}):
        with pytest.raises(LLMJsonError):
            validate(bad, SCHEMA)
    with pytest.raises(LLMJsonError, match="one of"):
        validate({"d": "maybe"}, {"type": "object", "properties": {"d": {"enum": ["stand", "withdraw"]}}})
    validate({"r": None}, {"type": "object", "properties": {"r": {"type": ["string", "null"]}}})


def test_complete_json_retries_once_then_gives_up():
    fake = FakeLLM({"t": ["garbage", '{"a": 3}']})
    assert complete_json(fake, "<!-- opinion_gallery:task=t -->", "q", SCHEMA, max_tokens=10) == {"a": 3}
    assert len(fake.calls) == 2 and "was not valid" in fake.calls[1].user
    fake2 = FakeLLM({"t": ["garbage"]})
    with pytest.raises(LLMJsonError):
        complete_json(fake2, "<!-- opinion_gallery:task=t -->", "q", SCHEMA, max_tokens=10)
    assert len(fake2.calls) == 2


def test_fake_routes_on_marker_and_repeats_last():
    fake = FakeLLM({"triage:skeptic": ["one", "two"], "triage": ["generic"]})
    s = "<!-- opinion_gallery:task=triage persona=skeptic -->"
    assert [fake.complete(s, "u") for _ in range(3)] == ["one", "two", "two"]
    assert fake.complete("<!-- opinion_gallery:task=triage persona=other -->", "u") == "generic"
    with pytest.raises(LLMError):
        fake.complete("<!-- opinion_gallery:task=draft persona=other -->", "u")


def _openai(handler, **kw):
    return OpenAICompatLLM("http://llm.test/v1", "key", "m", transport=httpx.MockTransport(handler), sleep=lambda s: None, **kw)


def test_openai_compat_request_shape_and_json_mode():
    seen = []

    def handler(request):
        seen.append(json.loads(request.content))
        return httpx.Response(200, json={"choices": [{"message": {"content": "hi"}}]})

    assert _openai(handler).complete("sys", "usr", schema=SCHEMA) == "hi"
    assert _openai(handler, json_mode=True).complete("sys", "usr", schema=SCHEMA) == "hi"
    assert seen[0]["messages"] == [{"role": "system", "content": "sys"}, {"role": "user", "content": "usr"}]
    assert "response_format" not in seen[0] and seen[1]["response_format"] == {"type": "json_object"}
    assert seen[0]["model"] == "m"


def test_openai_compat_retries_429_and_fails_on_5xx():
    n = {"calls": 0}

    def flaky(request):
        n["calls"] += 1
        return httpx.Response(429) if n["calls"] == 1 else httpx.Response(200, json={"choices": [{"message": {"content": "ok"}}]})

    assert _openai(flaky).complete("s", "u") == "ok" and n["calls"] == 2
    with pytest.raises(LLMError, match="gave up"):
        _openai(lambda r: httpx.Response(500, text="down")).complete("s", "u")
    with pytest.raises(LLMError, match="HTTP 401"):
        _openai(lambda r: httpx.Response(401, text="bad key")).complete("s", "u")


class _Block:
    def __init__(self, type_, text=""):
        self.type, self.text = type_, text


class _Response:
    def __init__(self, blocks, stop_reason="end_turn"):
        self.content, self.stop_reason = blocks, stop_reason


class _StubClient:
    def __init__(self, response):
        self.kwargs = None
        self.messages = self

    def create(self, **kwargs):
        self.kwargs = kwargs
        return self._response

    @property
    def _response(self):
        return self.__dict__["resp"]


def _anthropic(response):
    stub = _StubClient(response)
    stub.__dict__["resp"] = response
    return AnthropicLLM("k", "claude-opus-5", client=stub), stub


def test_anthropic_passes_system_and_structured_output_only_with_schema():
    a, stub = _anthropic(_Response([_Block("thinking"), _Block("text", "a"), _Block("text", "b")]))
    assert a.complete("sys", "usr", schema=SCHEMA, max_tokens=5) == "ab"
    assert stub.kwargs["system"] == "sys" and stub.kwargs["messages"] == [{"role": "user", "content": "usr"}]
    assert stub.kwargs["output_config"] == {"format": {"type": "json_schema", "schema": SCHEMA}}
    a.complete("sys", "usr")
    assert "output_config" not in stub.kwargs


def test_anthropic_refusal_is_an_error():
    a, _ = _anthropic(_Response([_Block("text", "")], stop_reason="refusal"))
    with pytest.raises(LLMError, match="refused"):
        a.complete("s", "u")


def test_build_llm_picks_adapter():
    from opinion_gallery.config import ProviderConfig

    assert isinstance(llm_mod.build_llm(ProviderConfig(kind="fake"), ""), FakeLLM)
    assert isinstance(llm_mod.build_llm(ProviderConfig(kind="openai", model="m"), "k"), OpenAICompatLLM)


def test_openai_compat_sends_no_auth_header_without_a_key():
    seen = []

    def handler(request):
        seen.append({k.lower(): v for k, v in request.headers.items()})
        return httpx.Response(200, json={"choices": [{"message": {"content": "ok"}}]})

    _openai(handler).complete("s", "u")
    assert "authorization" in seen[0] and seen[0]["authorization"] == "Bearer key"
    OpenAICompatLLM("http://local.test/v1", "", "m", transport=httpx.MockTransport(handler), sleep=lambda s: None).complete("s", "u")
    assert "authorization" not in seen[1]


def test_anthropic_omits_api_key_so_the_sdk_resolves_its_own(monkeypatch):
    anthropic = pytest.importorskip("anthropic")
    seen = {}

    class Stub:
        def __init__(self, **kwargs):
            seen.clear()
            seen.update(kwargs)
            self.messages = self

        def create(self, **kwargs):
            return _Response([_Block("text", "x")])

    monkeypatch.setattr(anthropic, "Anthropic", Stub)
    AnthropicLLM("", "claude-opus-5")
    assert "api_key" not in seen and seen["timeout"] == 120
    AnthropicLLM("k", "claude-opus-5", base_url="https://proxy.test")
    assert seen["api_key"] == "k" and seen["base_url"] == "https://proxy.test"
