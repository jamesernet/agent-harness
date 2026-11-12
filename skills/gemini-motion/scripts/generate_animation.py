#!/usr/bin/env python3
"""Ask Gemini to write a small code-based animation from a motion brief.

Output is ONE self-contained file: an .html (CSS/JS animation, the default),
a standalone .svg, or a Lottie .json. Nothing external is loaded, so the file
can be opened directly, dropped into a page, or handed to someone else.

  generate_animation.py --brief-file brief.md --out hero.html
  generate_animation.py "a 3s looping pulse on a circle, teal on white" --format svg --out pulse.svg
  generate_animation.py "slow the fade to 1.5s" --previous-id v1_abc --out hero.html   # iterate

Images the animation should use go in with --asset; they are inlined as data
URIs so the result stays a single file. The interaction id is printed and
logged to ./.gemini-motion/runs.jsonl for follow-up turns.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gemini_common import (  # noqa: E402
    DEFAULT_TIMEOUT_S,
    MIN_ATTEMPT_S,
    MODELS,
    RETRY_STATUSES,
    Timeout,
    create,
    die,
    extract_code,
    get_client,
    guess_mime,
    log_run,
    read_text_arg,
    usage_summary,
    positive_timeout,
    VISION_IMAGE_MIMES,
)

FORMATS = {
    "html": {"ext": ".html", "fences": ("html",), "label": "a single HTML document"},
    "svg": {"ext": ".svg", "fences": ("svg", "xml"), "label": "a standalone SVG document"},
    "lottie": {"ext": ".json", "fences": ("json",), "label": "a Lottie animation JSON (bodymovin schema)"},
}

SYSTEM_INSTRUCTION = """\
You are a motion designer who writes production-quality animation code.
You will receive a motion brief. Produce exactly one deliverable: {label}.

Hard requirements (they make the output usable without further work):
- Self-contained: no external scripts, stylesheets, fonts, images or network calls.
  Any asset the brief lists is referenced by its exact filename; nothing else.
- Deterministic: no randomness unless the brief asks for it (then seed it).
- Honour the brief's canvas size, duration, loop behaviour and easing. If the
  brief omits one, choose a sensible value and keep it in one obvious place.
- Expose tunables (colours, duration, sizes) as named constants at the top
  (CSS custom properties on :root for HTML/SVG; a comment block for Lottie)
  so a human can adjust without reading the whole file.
- HTML/SVG: respect prefers-reduced-motion by reducing or pausing motion.
- HTML: a transparent body background unless a background is requested;
  the animation starts on load; sized with CSS so it scales to its container.
- Keep it small and readable: prefer CSS keyframes or SVG animation over
  JavaScript, and JavaScript over libraries. No frameworks.
- Lottie: valid JSON only, schema version 5.x, 24 fps unless told otherwise.

Reply with ONLY the code in one fenced code block tagged ```{fence}```.
No explanation before or after the block.
"""


def inline_assets(code: str, assets: list[Path]) -> str:
    """Replace references to each asset's basename with a data URI."""
    for p in assets:
        mime = guess_mime(p, "application/octet-stream")
        data = base64.b64encode(p.read_bytes()).decode("ascii")
        uri = f"data:{mime};base64,{data}"
        # match src="name", url(name), href="name", xlink:href="name", with or without ./
        pattern = re.compile(r"(?<=[\"'(])(?:\./)?" + re.escape(p.name) + r"(?=[\"')])")
        code = pattern.sub(uri, code)
    return code


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("brief", nargs="?", help="the motion brief (or use --brief-file)")
    ap.add_argument("--brief-file", help="read the brief from a file (see references/animation-brief.md)")
    ap.add_argument("--out", help="output path; extension follows --format if omitted")
    ap.add_argument("--format", choices=FORMATS, default="html")
    ap.add_argument("--asset", action="append", help="image file the animation should use (repeatable)")
    ap.add_argument("--no-inline", action="store_true", help="keep asset references as filenames")
    ap.add_argument("--model", help=f"default {MODELS['code']}; an explicit choice disables fallback")
    ap.add_argument("--no-fallback", action="store_true",
                    help="fail instead of trying the fallback models on a 503")
    ap.add_argument("--thinking", choices=("low", "medium", "high"), default="medium")
    ap.add_argument("--previous-id", help="iterate on an earlier result (keeps Gemini's context)")
    ap.add_argument("--timeout", type=positive_timeout, default=DEFAULT_TIMEOUT_S["text"],
                    help="total seconds to wait across every model tried, not per model "
                         f"(default {DEFAULT_TIMEOUT_S['text']}); the SDK sets none, so without this a stall hangs forever")
    ap.add_argument("--json", action="store_true", help="print a JSON summary only")
    args = ap.parse_args()

    brief = read_text_arg(args.brief, args.brief_file, "brief")
    # An explicit --model is taken literally; the default fans out to the
    # fallback pools, because a 503 here is a capacity outage, not a bad request.
    if args.previous_id and not args.model:
        # A thread belongs to the model that started it, so there is nothing to
        # fall back to — reusing the id against a second model sends one
        # conversation to a model that never had it. Which model owns this
        # thread is in .gemini-motion/runs.jsonl; the caller has to say.
        die("--previous-id needs --model: a thread belongs to the model that "
            "started it, and this cannot guess which. The model is recorded "
            "beside the interaction id in .gemini-motion/runs.jsonl.")
    if args.model:
        chain = [args.model]
    elif args.no_fallback:
        chain = [MODELS["code"]]
    else:
        chain = [MODELS["code"], *MODELS["code_fallbacks"]]
    fmt = FORMATS[args.format]
    out = Path(args.out) if args.out else Path("motion") / f"animation-{time.strftime('%Y%m%d-%H%M%S')}{fmt['ext']}"
    if out.suffix.lower() != fmt["ext"]:
        out = out.with_suffix(fmt["ext"])

    assets = [Path(a) for a in (args.asset or [])]
    for a in assets:
        if not a.is_file():
            die(f"asset not found: {a}")
        if a.stat().st_size == 0:
            die(f"asset is empty: {a} (a failed download looks exactly like this)")

    user_text = brief
    if assets:
        names = ", ".join(a.name for a in assets)
        user_text += f"\n\nAssets available (reference by exact filename): {names}"

    # Send the asset images too, so Gemini can see what it is animating -- but
    # only the types it accepts. An SVG or a GIF is an image by any local test
    # and is rejected by the API, which used to fail the whole call over an
    # asset that only needed inlining. Those are still listed by name above and
    # still inlined into the result below.
    unshown = [a.name for a in assets if guess_mime(a, "image/png") not in VISION_IMAGE_MIMES]
    if unshown:
        user_text += ("\n\nNot shown to you (the API does not accept the format), so animate "
                      "them as opaque rectangles of the right aspect and leave the reference "
                      f"by filename: {', '.join(unshown)}")
    inp: list[dict] | str = user_text
    if assets:
        blocks = []
        for a in assets:
            mime = guess_mime(a, "image/png")
            if mime in VISION_IMAGE_MIMES:
                blocks.append({"type": "image", "data": base64.b64encode(a.read_bytes()).decode("ascii"), "mime_type": mime})
        blocks.append({"type": "text", "text": user_text})
        inp = blocks

    client = get_client()
    kwargs: dict = {
        "input": inp,
        "system_instruction": SYSTEM_INSTRUCTION.format(label=fmt["label"], fence=fmt["fences"][0]),
        "generation_config": {"thinking_level": args.thinking},
    }
    if args.previous_id:
        kwargs["previous_interaction_id"] = args.previous_id

    t0 = time.time()
    # The timeout is a budget for the whole call, not per model. Per-model it
    # multiplies: a three-model chain on a bad day burns three full timeouts
    # before it reports, which is not what anyone means by "give up after 90s".
    deadline = t0 + args.timeout
    interaction = None
    for i, model in enumerate(chain):
        remaining = deadline - time.time()
        # Fair-share, not first-come. A total budget alone lets a model that
        # hangs consume all of it and the chain never gets tried — observed:
        # a dead first model ate a 100s budget whole and the two behind it
        # never ran. Each attempt gets at most its share of what is left.
        share = remaining / (len(chain) - i)
        if remaining < MIN_ATTEMPT_S:
            die(f"out of time after {time.time() - t0:.0f}s; tried {', '.join(chain[:i]) or 'nothing'}. "
                f"Raise --timeout or pass --model to pick one directly.")
        if not args.json:
            note = "" if i == 0 else f"  (falling back from {chain[i - 1]})"
            print(f"asking {model} for {fmt['label']} ...{note}", flush=True)
        try:
            interaction = create(client, share, model=model, **kwargs)
            break
        except Exception as e:  # noqa: BLE001
            status = getattr(e, "status_code", None)
            if status is None:
                status = next((c for c in RETRY_STATUSES if str(c) in str(e)), None)
            # Only a capacity failure is worth trying a different model for; a bad
            # request will fail identically everywhere. A local timeout counts:
            # a model too loaded to answer is as unavailable as one returning 503.
            capacity = status in RETRY_STATUSES or isinstance(e, Timeout)
            if not capacity or i == len(chain) - 1:
                die(f"{type(e).__name__}: {e}")
            print(f"  {model} unavailable; trying {chain[i + 1]}", file=sys.stderr, flush=True)
    model_used = model

    raw = interaction.output_text or ""
    if not raw.strip():
        die(f"empty reply (status={getattr(interaction, 'status', '?')})")

    code, lang = extract_code(raw, prefer=fmt["fences"])
    if args.format == "lottie":
        try:
            json.loads(code)
        except json.JSONDecodeError as e:
            die(f"Lottie output is not valid JSON ({e}); raw reply saved to .gemini-motion/last_raw.txt")
    if assets and not args.no_inline:
        code = inline_assets(code, assets)

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(code, encoding="utf-8")
    raw_path = Path(".gemini-motion") / "last_raw.txt"
    raw_path.parent.mkdir(exist_ok=True)
    raw_path.write_text(raw, encoding="utf-8")

    elapsed = round(time.time() - t0, 1)
    summary = {
        "out": str(out),
        "format": args.format,
        "model": model_used,
        "interaction_id": interaction.id,
        "previous_id": args.previous_id,
        "bytes": len(code.encode("utf-8")),
        "seconds": elapsed,
        "usage": usage_summary(interaction),
    }
    log_run("animation", brief=brief[:2000], **summary)

    if args.json:
        print(json.dumps(summary))
    else:
        print(f"saved {out}  ({summary['bytes']} bytes, {elapsed}s)")
        print(f"interaction id: {interaction.id}   <- pass as --previous-id to revise")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
