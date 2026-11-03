#!/usr/bin/env python3
"""Generate or edit a still image with Nano Banana (gemini-nano-banana-2.1).

In this skill it is the asset step: keyframes for a video (a first/last frame
to hand to generate_video.py), or a sprite, icon or background that a code
animation will move. Keep prompts descriptive: subject, style, lighting,
background, and say "plain white background" / "transparent-looking flat
background" when the asset will be composited.

  generate_image.py "flat vector rocket, teal and coral, white background" --out rocket.png
  generate_image.py "same rocket, exhaust flame extended" --previous-id v1_abc --out rocket_flame.png
  generate_image.py "photoreal mug on a wooden desk, morning light" --aspect 16:9 --size 2K --out first.png
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gemini_common import (  # noqa: E402
    MODELS,
    die,
    get_client,
    image_block,
    log_run,
    read_text_arg,
    save_b64,
    usage_summary,
)

ASPECTS = ("1:1", "16:9", "9:16", "4:3", "3:4", "3:2", "2:3", "5:4", "4:5", "21:9", "1:4", "4:1")
SIZES = ("1K", "2K", "4K")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("prompt", nargs="?", help="what to draw (or use --prompt-file)")
    ap.add_argument("--prompt-file")
    ap.add_argument("--out", help="output path (.png default)")
    ap.add_argument("--aspect", choices=ASPECTS)
    ap.add_argument("--size", choices=SIZES, help="1K (default), 2K or 4K")
    ap.add_argument("--ref", action="append", help="reference image to edit or keep consistent (repeatable)")
    ap.add_argument("--previous-id", help="edit the image from an earlier call")
    ap.add_argument("--model", default=MODELS["image"])
    ap.add_argument("--thinking", choices=("minimal", "medium", "high"))
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    prompt = read_text_arg(args.prompt, args.prompt_file, "prompt")
    out = Path(args.out) if args.out else Path("motion") / f"image-{time.strftime('%Y%m%d-%H%M%S')}.png"

    inp: list[dict] | str = prompt
    if args.ref:
        inp = [{"type": "text", "text": prompt}] + [image_block(r) for r in args.ref]

    response_format: dict = {"type": "image"}
    if args.aspect:
        response_format["aspect_ratio"] = args.aspect
    if args.size:
        response_format["image_size"] = args.size
    if out.suffix.lower() in (".jpg", ".jpeg"):
        response_format["mime_type"] = "image/jpeg"

    kwargs: dict = {"model": args.model, "input": inp, "response_format": response_format}
    if args.previous_id:
        kwargs["previous_interaction_id"] = args.previous_id
    if args.thinking:
        kwargs["generation_config"] = {"thinking_level": args.thinking}

    client = get_client()
    if not args.json:
        print(f"generating image with {args.model} ...", flush=True)
    t0 = time.time()
    try:
        interaction = client.interactions.create(**kwargs)
    except Exception as e:  # noqa: BLE001
        die(f"{type(e).__name__}: {e}")

    img = getattr(interaction, "output_image", None)
    if img is None or not getattr(img, "data", None):
        text = (interaction.output_text or "")[:300]
        die(f"no image returned (status={getattr(interaction, 'status', '?')}). Model said: {text!r}")

    save_b64(img.data, out)
    elapsed = round(time.time() - t0, 1)
    summary = {
        "out": str(out),
        "interaction_id": interaction.id,
        "model": args.model,
        "aspect": args.aspect,
        "size": args.size or "1K",
        "previous_id": args.previous_id,
        "seconds": elapsed,
        "usage": usage_summary(interaction),
    }
    log_run("image", prompt=prompt, **summary)
    if args.json:
        print(json.dumps(summary))
    else:
        print(f"saved {out}  ({elapsed}s)")
        print(f"interaction id: {interaction.id}   <- pass as --previous-id to edit")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
