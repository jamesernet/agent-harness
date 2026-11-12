"""Shared helpers for the gemini-motion scripts.

Everything here is deliberately small: build a client from GEMINI_API_KEY,
turn local files into Interactions API content blocks, extract a code block
from a model reply, and append a line to a JSONL run log so later turns can
chain on `previous_interaction_id`.
"""

from __future__ import annotations

import argparse
import base64
import json
import mimetypes
import os
import re
import signal
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

DEFAULT_TIMEOUT_S = {"text": 180, "image": 300, "video": 1800}
"""Per-call request timeouts, seconds.

The SDK sets none by default, so a stalled request waits forever: observed
here as a 26-minute hang on a text call that never errored and never
returned. An agent workflow that hangs is worse than one that fails, because
nothing surfaces to act on.

Video is generous on purpose. A client-side timeout does not cancel work the
server already accepted, so cutting a paid render short risks being billed
for a clip that is never collected.
"""

MIN_ATTEMPT_S = 20
"""Below this there is no point starting another model: generation of a real
brief has not been observed finishing faster, so a shorter slice just burns
the remaining budget and reports the same failure later."""

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


def get_client(retries: bool = True):
    """Return a google-genai Client, with readable errors for the two common failures.

    `retries=False` turns the SDK's own retry loop off for this client. Use it
    for a BILLED call: the SDK retries 5XX by default, and a generation the
    server completed but whose response was lost would be charged once per
    attempt. Measured against google-genai 3.2.0, where
    HttpRetryOptions.attempts documents "If 0 or 1, it means no retries".
    Uploads and downloads keep the retries, because repeating those costs
    nothing.
    """
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
    if retries:
        return genai.Client(api_key=key)
    from google.genai import types

    return genai.Client(
        api_key=key,
        http_options=types.HttpOptions(retry_options=types.HttpRetryOptions(attempts=1)),
    )


RETRY_STATUSES = (429, 503)
"""Statuses worth trying a DIFFERENT MODEL for. Not a retry list.

google-genai already retries transient failures itself: its default config is
max_retries=4 over ["408", "409", "429", "5XX"] with exponential backoff
capped at 30s elapsed. Adding a second retry loop here multiplied that — four
outer attempts over five inner requests is twenty calls for one generation,
with two layers of backoff stacked. Worse than useless when 503s are reported
to consume the free daily allowance.

So the SDK owns retrying. What it cannot do is give up on a model and try
another one, which is the only thing left worth doing when a capacity outage
outlasts its backoff. That is what these statuses gate, in the caller.
"""


class Timeout(Exception):
    """A call exceeded its wall-clock deadline and was abandoned locally."""


def positive_timeout(value: str) -> float:
    """argparse type for --timeout: a deadline has to be a positive number.

    `--timeout 0` read as "do not wait" and did the opposite: setitimer(0)
    DISABLES the timer, so the one value a user would reach for to fail fast
    removed the only deadline the call had. Zero and negatives are refused by
    name instead.
    """
    try:
        seconds = float(value)
    except ValueError:
        raise argparse.ArgumentTypeError(f"not a number: {value!r}") from None
    if seconds <= 0:
        raise argparse.ArgumentTypeError(
            f"a deadline must be positive; {value} would remove the deadline, not shorten it"
        )
    return seconds


def create(client, timeout: float, **kwargs):
    """client.interactions.create under a hard local deadline.

    The SDK accepts a `timeout` and documents it as a wall-clock budget for
    the whole call. Measured here, it is not one: a create() passed timeout=5
    against an overloaded model raised after 677 seconds, and another after
    1572. Nothing in the skill should depend on it, so the deadline is
    enforced locally with SIGALRM, which interrupts the blocking call
    whatever the SDK is doing underneath. The SDK value is still passed, so a
    future fix there only helps.

    Abandoning a call does NOT cancel work the server accepted. For video that
    means a render may still complete and bill; the interaction is stored, so
    recover it from the dashboard rather than assuming it never happened.

    SIGALRM is Unix-only and must run on the main thread, which is how these
    scripts run. Elsewhere this degrades to the SDK's own behaviour.
    """
    if timeout <= 0:
        raise ValueError(f"create() needs a positive deadline, got {timeout}")

    def _fire(signum, frame):
        raise Timeout(
            f"no response after {timeout:.0f}s; abandoned locally because the SDK's "
            "own timeout does not reliably bound the call. Work the server already "
            "accepted may still complete and, for video, still bill."
        )

    try:
        previous = signal.signal(signal.SIGALRM, _fire)
    except (AttributeError, ValueError):
        return client.interactions.create(timeout=timeout, **kwargs)

    signal.setitimer(signal.ITIMER_REAL, timeout)
    try:
        return client.interactions.create(timeout=timeout, **kwargs)
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


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
    if p.stat().st_size == 0:
        # An empty file passes is_file(), encodes to "", and comes back from the
        # API as "Unable to process input image" with nothing pointing at the
        # cause. A failed download leaves exactly this.
        die(f"image file is empty: {p}")
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
