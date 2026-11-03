#!/usr/bin/env python3
"""Verify the Gemini API is usable from this machine before spending time on a brief.

Checks, in order: Python version, google-genai installed, GEMINI_API_KEY set.
With --ping it also makes one tiny, free-tier text call to confirm the key works.
With --video it reminds you that video generation is paid-only and shows the
rough per-second cost so there are no surprises.

Exit code 0 = ready. Non-zero = something to fix; the message says what.
"""

from __future__ import annotations

import argparse
import os
import sys

MIN_PY = (3, 10)

VIDEO_COST_NOTE = """\
Video generation (gemini-omni-1.1-flash) has NO free tier: it bills from the
first clip. Published list prices as of late 2026, per second of output video:
  360p  ~$0.03     720p  ~$0.10     1080p ~$0.15     4K  ~$0.30
A 10s draft at 360p is ~$0.30; the same clip at 720p ~$1.00. Draft at 360p,
finalize once. Prices change: https://ai.google.dev/gemini-api/docs/pricing
Billing must be enabled on the Google AI Studio project that owns the key."""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ping", action="store_true", help="make one tiny text call to confirm the key works")
    ap.add_argument("--video", action="store_true", help="also print the video billing note")
    args = ap.parse_args()

    ok = True

    if sys.version_info < MIN_PY:
        print(f"[x] Python {MIN_PY[0]}.{MIN_PY[1]}+ required, found {sys.version.split()[0]}")
        ok = False
    else:
        print(f"[ok] Python {sys.version.split()[0]}")

    try:
        import google.genai as genai  # noqa: F401
        from google import genai as _g
        print(f"[ok] google-genai {getattr(_g, '__version__', '?')} installed")
        client_cls = _g.Client
        if not hasattr(client_cls, "interactions"):
            print("[x] this google-genai version predates the Interactions API; run: pip install --upgrade google-genai")
            ok = False
    except ImportError:
        print("[x] google-genai not installed. Run: pip install google-genai")
        ok = False

    key = os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY")
    if key:
        print(f"[ok] GEMINI_API_KEY set (ends with ...{key[-4:]})")
    else:
        print("[x] GEMINI_API_KEY not set. Get a key: https://aistudio.google.com/apikey  then export GEMINI_API_KEY=...")
        ok = False

    if args.ping and ok:
        from gemini_common import MODELS, get_client

        try:
            client = get_client()
            r = client.interactions.create(model=MODELS["ping"], input="Reply with the single word: ready")
            text = (r.output_text or "").strip()
            print(f"[ok] API reachable with {MODELS['ping']}: {text[:40]!r}")
        except Exception as e:  # noqa: BLE001
            print(f"[x] API call failed: {type(e).__name__}: {e}")
            ok = False

    if args.video:
        print()
        print(VIDEO_COST_NOTE)

    print()
    print("READY" if ok else "NOT READY (see references/setup.md)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    raise SystemExit(main())
