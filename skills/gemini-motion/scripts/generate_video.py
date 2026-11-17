#!/usr/bin/env python3
"""Generate, edit or extend a short video with Gemini Omni Flash (gemini-omni-1.2-flash).

One script covers every Omni mode; which one runs depends on what you pass:

  text -> video        generate_video.py "prompt"
  image -> video       generate_video.py "prompt" --image sketch.png
  first/last frame     generate_video.py "prompt" --first-frame a.png --last-frame b.png
  subject references   generate_video.py "prompt" --image cat.png --image yarn.png
  edit previous clip   generate_video.py "Make it night. Keep everything else the same." --previous-id v1_abc
  extend previous clip generate_video.py "Extend this video: the camera pans left." --previous-id v1_abc
  edit/extend a file   generate_video.py "Make it anime" --video my_clip.mp4   (<=15s uploads)
  collect a paid clip  generate_video.py --fetch v1_abc --out clip.mp4         (free; no render)

Draft cheaply, then finalize:
  generate_video.py "..." --draft               # 360p, ~1/3 the cost of 720p
  generate_video.py "..." --resolution 1080p    # automatically uses URI delivery

Output is an .mp4 with audio. The interaction id is printed and logged to
./.gemini-motion/runs.jsonl so you can chain edits with --previous-id.
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
    ASPECTS,
    MAX_CLIP_SECONDS,
    MAX_EXTENDED_SECONDS,
    MAX_UNPINNED_SECONDS,
    MIN_CLIP_SECONDS,
    DEFAULT_TIMEOUT_S,
    DELIVERY_TIMEOUT_S,
    MODELS,
    DeliveryFailed,
    die,
    fetch_clip,
    log_run,
    price,
    read_text_arg,
    render_clip,
    require_approval,
    slug,
    usage_summary,
    positive_timeout,
)

RESOLUTIONS = ("360p", "720p", "1080p", "4k")
TASKS = ("text_to_video", "image_to_video", "reference_to_video", "edit", "extend")


def default_out(prompt: str) -> Path:
    stamp = time.strftime("%Y%m%d-%H%M%S")
    return Path("motion") / f"{slug(prompt)}-{stamp}.mp4"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("prompt", nargs="?", help="what to generate / change (or use --prompt-file)")
    ap.add_argument("--prompt-file", help="read the prompt from a file")
    ap.add_argument("--out", help="output .mp4 path (default: motion/<slug>-<timestamp>.mp4)")
    ap.add_argument("--aspect", choices=ASPECTS, default=None, help="16:9 (default) or 9:16")
    ap.add_argument("--resolution", choices=RESOLUTIONS, default=None, help="default 720p")
    ap.add_argument("--draft", action="store_true", help="shorthand for --resolution 360p")
    ap.add_argument("--duration", type=int, choices=range(MIN_CLIP_SECONDS, MAX_CLIP_SECONDS + 1),
                    metavar="SECONDS",
                    help="clip length, 3-10 (default: 10, or a length the prompt names, up to 15). Billed per second.")
    ap.add_argument("--image", action="append", help="reference image (repeatable, up to a handful)")
    ap.add_argument("--first-frame", help="image to start the video on")
    ap.add_argument("--last-frame", help="image to end the video on (needs --first-frame)")
    ap.add_argument("--video", help="your own .mp4 (<=15s) to edit or extend; uploaded via Files API")
    ap.add_argument("--previous-id", help="interaction id of a previous clip to edit or extend")
    ap.add_argument("--task", choices=TASKS, help="force a mode; normally the prompt is enough (edit also prices an edit as one clip)")
    ap.add_argument("--uri", action="store_true", help="force URI delivery (auto for 1080p/4k)")
    ap.add_argument("--no-store", action="store_true", help="faster, but the result cannot be edited later")
    ap.add_argument("--output-seconds", type=int, metavar="SECONDS",
                    help="on an edit or extend, the length of the FINISHED clip, which is\n"
                         "what the rate applies to. Without it the worst case is priced")
    ap.add_argument("--approve", metavar="<N>s@<resolution>",
                    help="the price you agreed to pay, as the exact token this script prints\n"
                         "(for example 6s@360p); it carries BOTH numbers, because seconds\n"
                         "alone approved a figure that --resolution could still multiply")
    ap.add_argument("--timeout", type=positive_timeout, default=DEFAULT_TIMEOUT_S["video"],
                    help="seconds to wait for the render before giving up "
                         f"(default {DEFAULT_TIMEOUT_S['video']}); the SDK sets none, so without this a stall hangs forever")
    ap.add_argument("--delivery-timeout", type=positive_timeout, default=DELIVERY_TIMEOUT_S,
                    help="seconds to wait for a rendered clip to be ready and downloaded "
                         f"(default {DELIVERY_TIMEOUT_S}); the render is billed by then, so "
                         "giving up abandons nothing: --fetch collects it later")
    ap.add_argument("--fetch", metavar="INTERACTION_ID",
                    help="save the clip of a render that was billed but not saved; renders "
                         "nothing and bills nothing")
    ap.add_argument("--json", action="store_true", help="print a JSON summary only")
    args = ap.parse_args()

    if args.fetch:
        out = Path(args.out) if args.out else default_out(args.fetch)
        try:
            fetch_clip(args.fetch, out, timeout=args.delivery_timeout)
        except DeliveryFailed as e:
            die(str(e))
        log_run("video-fetch", interaction_id=args.fetch, out=str(out))
        print(json.dumps({"out": str(out), "interaction_id": args.fetch}) if args.json
              else f"saved {out}")
        return 0

    prompt = read_text_arg(args.prompt, args.prompt_file, "prompt")
    if args.draft and args.resolution:
        die(f"--draft IS --resolution 360p, and you also passed --resolution {args.resolution}; "
            "pass one of them")
    resolution = "360p" if args.draft else (args.resolution or "720p")
    out = Path(args.out) if args.out else default_out(prompt)
    if out.suffix.lower() != ".mp4":
        out = out.with_suffix(".mp4")

    # The approval is a price, so it is priced here and compared by
    # require_approval (see approval_token for why it names the resolution).
    #
    # Without --duration the model picks the length, so the only honest figure
    # to price is the worst case.
    # An extend returns the WHOLE clip, not the increment, and
    # the rate is per second of output -- so on that path the thing being
    # billed is a length this script never sees. --duration is the increment
    # there and bounds nothing, so pricing from it, or from MAX_CLIP_SECONDS,
    # quoted up to a tenth of the real bill on a clip extended to 30s.
    #
    # A clip passed with --video is continued as surely as one named by
    # --previous-id, and without --task the model reads the prompt to decide
    # whether it edits or extends -- so that case is priced as the dearer one.
    # A task that makes a new clip makes the video a reference instead.
    # An edit is one generation, and tops out where a single clip does.
    continuing = (bool(args.previous_id) or args.task in ("edit", "extend")
                  or bool(args.video) and not args.task)
    editing = args.task == "edit"
    ceiling = MAX_UNPINNED_SECONDS if editing else MAX_EXTENDED_SECONDS
    if args.output_seconds is not None:
        if not continuing:
            die("--output-seconds is the finished length of an edit or extend; "
                "pin a new clip with --duration")
        if not 3 <= args.output_seconds <= ceiling:
            die(f"--output-seconds must be 3 to {ceiling}, the most "
                + ("an edit" if editing else "an extended clip") + " can return")
    if continuing:
        billable = args.output_seconds or ceiling
    else:
        billable = args.duration or MAX_UNPINNED_SECONDS
    priced = price(billable, resolution)
    if args.approve is None:
        print(f"this render bills {priced.text}")
        if continuing and not args.output_seconds:
            if editing:
                print(f"  an edit returns one clip, so {MAX_UNPINNED_SECONDS}s is the worst case.")
            else:
                print("  this continues an existing clip, and the rate applies to the WHOLE")
                print(f"  result, not the part added; {MAX_EXTENDED_SECONDS}s is the worst case.")
                if not args.task:
                    print("  without --task the prompt decides whether it edits or extends;")
                    print("  pass --task edit if it is an edit, which is priced as one clip.")
            print("  pass --output-seconds N with the finished length to approve less.")
        elif not continuing and not args.duration:
            print(f"  length is unset, so the model chooses it; {MAX_UNPINNED_SECONDS}s is the worst case.")
            print("  pass --duration 3..10 to pin it and approve a smaller number, unless")
            print("  one uncut take has to run past 10 s (text or reference clips only).")
        print(f"approve with: --approve {priced.token}")
        return 2
    require_approval(args.approve, priced.token)

    announce = None
    if not args.json:
        announce = (f"generating with {MODELS['video']} at {resolution}"
                    + (f", {args.aspect}" if args.aspect else "")
                    + (" (edit/extend of previous clip)" if args.previous_id else "")
                    + " ...")

    def billed(interaction):
        # Logged before the clip is collected: if that fails, this line is
        # where the id of a clip already paid for is found.
        log_run("video-billed", prompt=prompt, interaction_id=interaction.id, out=str(out),
                resolution=resolution, billed_seconds=billable,
                estimate_usd=round(priced.usd, 2))

    try:
        interaction, render_seconds = render_clip(
            prompt, out, resolution=resolution, timeout=args.timeout, aspect=args.aspect,
            duration=args.duration, images=args.image or (), first_frame=args.first_frame,
            last_frame=args.last_frame, video=args.video, previous_id=args.previous_id,
            task=args.task, uri=args.uri, store=not args.no_store, announce=announce,
            delivery_timeout=args.delivery_timeout, on_created=billed,
        )
    except DeliveryFailed as e:
        if args.no_store:
            die(f"{e}\nit was rendered with --no-store, so it cannot be fetched.")
        die(f"{e}\ncollect it without paying again: "
            f"{Path(sys.argv[0]).name} --fetch {e.interaction_id} --out {out}")

    elapsed = round(render_seconds, 1)
    summary = {
        "out": str(out),
        "interaction_id": interaction.id,
        "model": MODELS["video"],
        "resolution": resolution,
        "aspect": args.aspect or "16:9",
        "duration": f"{args.duration}s" if args.duration else None,
        "billed_seconds": billable,
        "priced_as": ("one edited clip" if editing else "whole output (extend)") if continuing else "this clip",
        "estimate_usd": round(priced.usd, 2),
        "previous_id": args.previous_id,
        "seconds": elapsed,
        "usage": usage_summary(interaction),
    }
    log_run("video", prompt=prompt, **summary)

    if args.json:
        print(json.dumps(summary))
    else:
        print(f"saved {out}  ({elapsed}s)")
        print(f"interaction id: {interaction.id}   <- pass as --previous-id to edit or extend")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
