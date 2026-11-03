"""Shared helpers for the gemini-motion scripts.

Everything here is deliberately small: build a client from GEMINI_API_KEY,
turn local files into Interactions API content blocks, extract a code block
from a model reply, and append a line to a JSONL run log so later turns can
chain on `previous_interaction_id`.
"""

from __future__ import annotations

import base64
import json
import mimetypes
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

MODELS = {
    "video": "gemini-omni-1.1-flash",
    "image": "gemini-nano-banana-2.1",
    "code": "gemini-3.8-flash",
    "code_cheap": "gemini-3.5-flash-lite",
    # Tried in order when "code" is unavailable. A 503 on a Gemini text model is
    # a shared-capacity outage, not a key problem: it hits paid Standard-tier
    # projects too and has run for a day at a time, so backoff alone cannot
    # outlast it. Each entry is a separate capacity pool on the same key.
    "code_fallbacks": ("gemini-3.6-flash", "gemini-3.5-flash-lite"),
    "ping": "gemini-3.5-flash-lite",
}

MAX_CLIP_SECONDS = 10
"""One Omni call tops out here; longer needs --previous-id to extend."""

VIDEO_RATES_USD = {"360p": 0.03, "720p": 0.10, "1080p": 0.15, "4k": 0.30}
"""USD per second of OUTPUT video, by resolution.

Published list prices as of late 2026, kept here rather than in each script so
there is one copy to correct. They do move: check
https://ai.google.dev/gemini-api/docs/pricing before quoting a figure that
matters.
"""


LOG_DIR_NAME = ".gemini-motion"
LOG_FILE_NAME = "runs.jsonl"


def die(msg: str, code: int = 1) -> None:
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(code)


def get_client():
    """Return a google-genai Client, with readable errors for the two common failures."""
    try:
        from google import genai
    except ImportError:
        die(
            "the google-genai package is not installed.\n"
            "  pip install google-genai   (or: pip install --upgrade google-genai)"
        )
    key = os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY")
    if not key:
        die(
            "GEMINI_API_KEY is not set. Create a key at https://aistudio.google.com/apikey\n"
            "  then:  export GEMINI_API_KEY=\"...\"   (see references/setup.md)"
        )
    return genai.Client(api_key=key)


RETRY_STATUSES = (429, 503)
"""Only these are retried.

A 503 (model overloaded) and a 429 (rate limit) both mean the request was
refused before any generation happened, so re-sending cannot double-charge.
Timeouts and connection errors are deliberately NOT retried: the request may
have been accepted and a paid video may already be generating, and a blind
retry would bill for it twice. Those surface to the caller instead.
"""


def create_with_retry(client, attempts: int = 4, base_delay: float = 5.0, **kwargs):
    """client.interactions.create, retried with exponential backoff on 429/503.

    gemini-3.8-flash in particular returns 503 "experiencing high demand" in
    bursts; without this a transient spike ends the run and loses the brief's
    place in the workflow.
    """
    last = None
    for attempt in range(1, attempts + 1):
        try:
            return client.interactions.create(**kwargs)
        except Exception as e:  # noqa: BLE001
            status = getattr(e, "status_code", None)
            if status is None:
                text = str(e)
                status = next((c for c in RETRY_STATUSES if str(c) in text), None)
            if status not in RETRY_STATUSES or attempt == attempts:
                raise
            last = e
            delay = base_delay * (2 ** (attempt - 1))
            print(
                f"  {status} from the API (attempt {attempt}/{attempts}); retrying in {delay:.0f}s",
                file=sys.stderr, flush=True,
            )
            time.sleep(delay)
    raise last  # unreachable


def guess_mime(path: Path, default: str = "application/octet-stream") -> str:
    mime, _ = mimetypes.guess_type(str(path))
    return mime or default


def image_block(path: str | Path) -> dict:
    """Inline image content block (base64). Fine for images up to a few MB."""
    p = Path(path)
    if not p.is_file():
        die(f"image not found: {p}")
    mime = guess_mime(p, "image/png")
    if not mime.startswith("image/"):
        die(f"not an image mime type ({mime}): {p}")
    data = base64.b64encode(p.read_bytes()).decode("ascii")
    return {"type": "image", "data": data, "mime_type": mime}


def upload_file(client, path: str | Path, wait: bool = True):
    """Upload a file through the Files API and wait until it is ACTIVE.

    Videos must go through here (they are too large to inline). Images can
    too, which is useful when the same reference is reused across turns.
    """
    p = Path(path)
    if not p.is_file():
        die(f"file not found: {p}")
    f = client.files.upload(file=str(p))
    if wait:
        while getattr(f.state, "name", f.state) == "PROCESSING":
            time.sleep(5)
            f = client.files.get(name=f.name)
        if getattr(f.state, "name", f.state) == "FAILED":
            die(f"upload failed to process: {p}")
    return f


def video_block_from_upload(uploaded) -> dict:
    return {"type": "video", "uri": uploaded.uri}


def image_block_from_upload(uploaded) -> dict:
    return {"type": "image", "uri": uploaded.uri}


def read_text_arg(value: str | None, file_arg: str | None, what: str) -> str:
    """Accept text either inline or from a file; one of them is required."""
    if file_arg:
        p = Path(file_arg)
        if not p.is_file():
            die(f"{what} file not found: {p}")
        return p.read_text(encoding="utf-8").strip()
    if value:
        return value.strip()
    die(f"provide the {what} as an argument or with --{what}-file")
    return ""  # unreachable


_FENCE_RE = re.compile(r"```([a-zA-Z0-9_+-]*)[ \t]*\n(.*?)```", re.DOTALL)


def extract_code(text: str, prefer: tuple[str, ...] = ()) -> tuple[str, str]:
    """Pull the main code block out of a model reply.

    Returns (code, language). Prefers a fence whose language tag is in
    `prefer`; otherwise takes the longest fence; if there is no fence at all,
    returns the whole text (the model may have obeyed "output only code").
    """
    fences = _FENCE_RE.findall(text)
    if not fences:
        return text.strip(), ""
    for lang, body in fences:
        if lang.lower() in prefer:
            return body.strip("\n"), lang.lower()
    lang, body = max(fences, key=lambda f: len(f[1]))
    return body.strip("\n"), lang.lower()


def log_run(kind: str, **fields) -> Path:
    """Append one JSON line to ./.gemini-motion/runs.jsonl and return its path.

    The log is how a later turn finds the interaction id to chain on, and how
    the user can see what was generated, from which prompt, at what settings.
    """
    log_dir = Path.cwd() / LOG_DIR_NAME
    log_dir.mkdir(exist_ok=True)
    log_path = log_dir / LOG_FILE_NAME
    entry = {"ts": datetime.now(timezone.utc).isoformat(timespec="seconds"), "kind": kind, **fields}
    with log_path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(entry, ensure_ascii=False) + "\n")
    return log_path


def save_b64(data_b64: str, out: str | Path) -> Path:
    p = Path(out)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(base64.b64decode(data_b64))
    return p


def usage_summary(interaction) -> dict | None:
    """Best-effort token usage pulled off the interaction, for the log."""
    usage = getattr(interaction, "usage", None)
    if usage is None:
        return None
    out = {}
    for name in ("total_input_tokens", "total_output_tokens", "input_tokens", "output_tokens"):
        val = getattr(usage, name, None)
        if val is not None:
            out[name] = val
    return out or None
