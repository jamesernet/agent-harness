"""One interface over three ways to get text: an OpenAI-compatible endpoint, the
Anthropic SDK, or scripted replies for tests."""

from __future__ import annotations

import json
import re
import time
from dataclasses import dataclass, field
from typing import Any, Callable, Mapping, Protocol

import httpx

from .config import ProviderConfig

MARKER_RE = re.compile(r"<!-- newsroom:task=(?P<task>[\w-]+)(?: persona=(?P<persona>[\w-]+))? -->")


class LLMError(RuntimeError):
    """The provider failed and the step cannot complete."""


class LLMJsonError(LLMError):
    """The model answered, but not with the JSON the step needs."""


class LLM(Protocol):
    def complete(self, system: str, user: str, *, schema: dict | None = None, max_tokens: int = 4096) -> str: ...


@dataclass
class Call:
    system: str
    user: str
    schema: dict | None
    reply: str


class OpenAICompatLLM:
    """POST {base_url}/chat/completions. Covers OpenAI, Ollama, LM Studio, vLLM, OpenRouter, Groq, xAI."""

    def __init__(
        self,
        base_url: str,
        api_key: str,
        model: str,
        *,
        json_mode: bool = False,
        timeout_s: int = 120,
        transport: httpx.BaseTransport | None = None,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.json_mode = json_mode
        self.sleep = sleep
        self.client = httpx.Client(
            timeout=timeout_s,
            headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
            transport=transport,
        )

    def complete(self, system: str, user: str, *, schema: dict | None = None, max_tokens: int = 4096) -> str:
        body: dict[str, Any] = {
            "model": self.model,
            "max_tokens": max_tokens,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
        }
        if schema is not None and self.json_mode:
            body["response_format"] = {"type": "json_object"}
        last = ""
        for attempt in range(3):
            try:
                r = self.client.post(f"{self.base_url}/chat/completions", json=body)
            except httpx.HTTPError as e:
                last = f"connection error: {e}"
            else:
                if r.status_code == 429 or r.status_code >= 500:
                    last = f"HTTP {r.status_code}: {r.text[:200]}"
                elif r.status_code >= 400:
                    raise LLMError(f"HTTP {r.status_code}: {r.text[:200]}")
                else:
                    try:
                        return r.json()["choices"][0]["message"]["content"] or ""
                    except (KeyError, IndexError, TypeError, ValueError) as e:
                        raise LLMError(f"unexpected response shape: {e}") from None
            self.sleep(2.0 * (attempt + 1))
        raise LLMError(f"gave up after 3 attempts: {last}")


class AnthropicLLM:
    """The Anthropic Messages API through the official SDK, imported only when chosen."""

    def __init__(self, api_key: str, model: str, *, base_url: str | None = None, timeout_s: int = 120, client: Any = None) -> None:
        if client is None:
            try:
                import anthropic
            except ImportError:
                raise LLMError("provider.kind is anthropic but the SDK is not installed; run `uv sync --extra anthropic`") from None
            kwargs: dict[str, Any] = {"api_key": api_key, "timeout": timeout_s}
            if base_url:
                kwargs["base_url"] = base_url
            client = anthropic.Anthropic(**kwargs)
        self.client = client
        self.model = model

    def complete(self, system: str, user: str, *, schema: dict | None = None, max_tokens: int = 4096) -> str:
        kwargs: dict[str, Any] = {
            "model": self.model,
            "max_tokens": max_tokens,
            "system": system,
            "messages": [{"role": "user", "content": user}],
        }
        if schema is not None:
            kwargs["output_config"] = {"format": {"type": "json_schema", "schema": schema}}
        try:
            response = self.client.messages.create(**kwargs)
        except Exception as e:  # the SDK's typed errors all end up here; the message carries the status
            raise LLMError(f"anthropic: {type(e).__name__}: {e}") from None
        if getattr(response, "stop_reason", None) == "refusal":
            raise LLMError("anthropic: the model refused this request")
        return "".join(getattr(b, "text", "") for b in response.content if getattr(b, "type", "") == "text")


class FakeLLM:
    """Scripted replies, routed on the task marker prompts.py puts first in every system prompt.

    `replies` maps "task:persona" or "task" to a list of replies. A list is consumed
    front to back; its last entry repeats. Every call is recorded in `calls`.
    """

    def __init__(self, replies: Mapping[str, list[str]] | Callable[[str, str], str]) -> None:
        self.script: dict[str, list[str]] | None = None
        self.fn: Callable[[str, str], str] | None = None
        if callable(replies):
            self.fn = replies
        else:
            self.script = {k: list(v) for k, v in replies.items()}
        self.calls: list[Call] = []

    def complete(self, system: str, user: str, *, schema: dict | None = None, max_tokens: int = 4096) -> str:
        if self.fn is not None:
            reply = self.fn(system, user)
        else:
            m = MARKER_RE.search(system)
            keys = []
            if m:
                if m.group("persona"):
                    keys.append(f"{m.group('task')}:{m.group('persona')}")
                keys.append(m.group("task"))
            assert self.script is not None
            for key in keys:
                queue = self.script.get(key)
                if queue:
                    reply = queue.pop(0) if len(queue) > 1 else queue[0]
                    break
            else:
                raise LLMError(f"FakeLLM has no reply for {keys or ['(no marker)']}")
        self.calls.append(Call(system=system, user=user, schema=schema, reply=reply))
        return reply


def build_llm(provider: ProviderConfig, api_key: str, *, fake_replies: Mapping[str, list[str]] | None = None) -> LLM:
    if provider.kind == "fake":
        return FakeLLM(fake_replies or {})
    if provider.kind == "anthropic":
        return AnthropicLLM(api_key, provider.model, base_url=provider.base_url or None, timeout_s=provider.timeout_s)
    return OpenAICompatLLM(
        provider.base_url or "https://api.openai.com/v1",
        api_key,
        provider.model,
        json_mode=provider.json_mode,
        timeout_s=provider.timeout_s,
    )


# --- JSON out of any model -------------------------------------------------------


def extract_json(text: str) -> Any:
    """The first {...} object in the text, fences and prose stripped."""
    t = text.strip()
    if t.startswith("```"):
        t = re.sub(r"^```[a-zA-Z]*\n?", "", t)
        t = re.sub(r"\n?```$", "", t)
    start, end = t.find("{"), t.rfind("}")
    if start == -1 or end == -1 or end < start:
        raise LLMJsonError("no JSON object in reply")
    try:
        return json.loads(t[start : end + 1])
    except json.JSONDecodeError as e:
        raise LLMJsonError(f"invalid JSON: {e}") from None


_TYPES = {
    "object": dict,
    "array": list,
    "string": str,
    "integer": int,
    "number": (int, float),
    "boolean": bool,
    "null": type(None),
}


def validate(data: Any, schema: Mapping[str, Any], path: str = "$") -> None:
    """Enough of JSON Schema to catch a wrong shape: type, required, properties, items, enum, bounds."""
    t = schema.get("type")
    if isinstance(t, list):
        if not any(isinstance(data, _TYPES[x]) for x in t):
            raise LLMJsonError(f"{path}: expected one of {t}")
    elif t:
        expected = _TYPES[t]
        ok = isinstance(data, expected) and not (t in ("integer", "number") and isinstance(data, bool))
        if not ok:
            raise LLMJsonError(f"{path}: expected {t}")
    if "enum" in schema and data not in schema["enum"]:
        raise LLMJsonError(f"{path}: must be one of {schema['enum']}")
    if isinstance(data, (int, float)) and not isinstance(data, bool):
        if "minimum" in schema and data < schema["minimum"]:
            raise LLMJsonError(f"{path}: below minimum {schema['minimum']}")
        if "maximum" in schema and data > schema["maximum"]:
            raise LLMJsonError(f"{path}: above maximum {schema['maximum']}")
    if isinstance(data, dict):
        for key in schema.get("required", []):
            if key not in data:
                raise LLMJsonError(f"{path}: missing required `{key}`")
        for key, sub in schema.get("properties", {}).items():
            if key in data:
                validate(data[key], sub, f"{path}.{key}")
    if isinstance(data, list) and "items" in schema:
        for i, item in enumerate(data):
            validate(item, schema["items"], f"{path}[{i}]")


def complete_json(llm: LLM, system: str, user: str, schema: dict, *, max_tokens: int) -> dict:
    """Ask for JSON, parse and validate it, retry once with the error, then give up."""
    ask = user + "\n\nReply with only a JSON object matching this schema, no prose and no code fence:\n" + json.dumps(schema)
    try:
        data = extract_json(llm.complete(system, ask, schema=schema, max_tokens=max_tokens))
        validate(data, schema)
        return data
    except LLMJsonError as first:
        retry = ask + f"\n\nYour previous reply was not valid ({first}). Reply with only the JSON object."
        data = extract_json(llm.complete(system, retry, schema=schema, max_tokens=max_tokens))
        validate(data, schema)
        return data
