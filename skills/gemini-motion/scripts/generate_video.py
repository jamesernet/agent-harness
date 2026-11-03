#!/usr/bin/env python3
"""Generate, edit or extend a short video with Gemini Omni Flash (gemini-omni-1.1-flash).

One script covers every Omni mode; which one runs depends on what you pass:

  text -> video        generate_video.py "prompt"
  image -> video       generate_video.py "prompt" --image sketch.png
  first/last frame     generate_video.py "prompt" --first-frame a.png --last-frame b.png
  subject references   generate_video.py "prompt" --image cat.png --image yarn.png
  edit previous clip   generate_video.py "Make it night. Keep everything else the same." --previous-id v1_abc
  extend previous clip generate_video.py "Extend this video: the camera pans left." --previous-id v1_abc
  edit/extend a file   generate_video.py "Make it anime" --video my_clip.mp4   (<=10s uploads)

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
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gemini_common import (  # noqa: E402
    MAX_CLIP_SECONDS,
    MODELS,
    VIDEO_RATES_USD,
    die,
    create_with_retry,
    get_client,
    image_block,
    log_run,
    read_text_arg,
    save_b64,
    upload_file,
    usage_summary,
    video_block_from_upload,
)

RESOLUTIONS = ("360p", "720p", "1080p", "4k")
ASPECTS = ("16:9", "9:16")
TASKS = ("text_to_video", "image_to_video", "reference_to_video", "edit", "extend", "upscale")
BIG_RESOLUTIONS = ("1080p", "4k")  # payloads > 4 MB need URI delivery


def slug(text: str, n: int = 40) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return s[:n].rstrip("-") or "video"


def default_out(prompt: str) -> Path:
    stamp = time.strftime("%Y%m%d-%H%M%S")
    return Path("motion") / f"{slug(prompt)}-{stamp}.mp4"


def build_input(args, client, prompt: str) -> list | str:
    """Assemble the Interactions `input`: media blocks first, then the text."""
    blocks: list[dict] = []
    tags: list[str] = []

    if args.first_frame:
        blocks.append(image_block(args.first_frame))
        if "<FIRST_FRAME>" not in prompt:
            tags.append("<FIRST_FRAME>")
    if args.last_frame:
        if not args.first_frame:
            die("--last-frame requires --first-frame")
        blocks.append(image_block(args.last_frame))
        if "<LAST_FRAME>" not in prompt:
            tags.append("<LAST_FRAME>")
    for p in args.image or []:
        blocks.append(image_block(p))
    if args.video:
        uploaded = upload_file(client, args.video)
        blocks.insert(0, video_block_from_upload(uploaded))

    text = (" ".join(tags) + " " + prompt).strip() if tags else prompt
    if not blocks:
        return text
    blocks.append({"type": "text", "text": text})
    return blocks


def wait_for_uri(client, uri: str, timeout_s: int = 900) -> None:
    """Poll the Files API until a URI-delivered video is ACTIVE."""
    name = "files/" + uri.split("/files/")[-1].split(":")[0].split("?")[0]
    start = time.time()
    while True:
        info = client.files.get(name=name)
        state = getattr(info.state, "name", str(info.state))
        if state == "ACTIVE":
            return
        if state == "FAILED":
            die("video generation failed while processing the file")
        if time.time() - start > timeout_s:
            die(f"timed out waiting for {name}")
        time.sleep(5)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("prompt", nargs="?", help="what to generate / change (or use --prompt-file)")
    ap.add_argument("--prompt-file", help="read the prompt from a file")
    ap.add_argument("--out", help="output .mp4 path (default: motion/<slug>-<timestamp>.mp4)")
    ap.add_argument("--aspect", choices=ASPECTS, default=None, help="16:9 (default) or 9:16")
    ap.add_argument("--resolution", choices=RESOLUTIONS, default=None, help="default 720p")
    ap.add_argument("--draft", action="store_true", help="shorthand for --resolution 360p")
    ap.add_argument("--duration", type=int, choices=range(3, 11), metavar="SECONDS",
                    help="clip length, 3-10 (default: model decides from the prompt). Billed per second.")
    ap.add_argument("--image", action="append", help="reference image (repeatable, up to a handful)")
    ap.add_argument("--first-frame", help="image to start the video on")
    ap.add_argument("--last-frame", help="image to end the video on (needs --first-frame)")
    ap.add_argument("--video", help="your own .mp4 (<=10s) to edit or extend; uploaded via Files API")
    ap.add_argument("--previous-id", help="interaction id of a previous clip to edit or extend")
    ap.add_argument("--task", choices=TASKS, help="force a mode; normally the prompt is enough")
    ap.add_argument("--uri", action="store_true", help="force URI delivery (auto for 1080p/4k)")
    ap.add_argument("--no-store", action="store_true", help="faster, but the result cannot be edited later")
    ap.add_argument("--approve", type=int, metavar="SECONDS",
                    help="the seconds of video you agreed to pay for; must equal what this\nrender will bill, so a plan that changed since you looked stops here")
    ap.add_argument("--json", action="store_true", help="print a JSON summary only")
    args = ap.parse_args()

    prompt = read_text_arg(args.prompt, args.prompt_file, "prompt")
    resolution = "360p" if args.draft else (args.resolution or "720p")
    out = Path(args.out) if args.out else default_out(prompt)
    if out.suffix.lower() != ".mp4":
        out = out.with_suffix(".mp4")

    # The approval is the seconds the user agreed to pay for. Without --duration
    # the model picks the length, so the only honest number to approve against is
    # the worst case. A mismatch means something changed after they looked.
    billable = args.duration or MAX_CLIP_SECONDS
    estimate = billable * VIDEO_RATES_USD[resolution]
    if args.approve is None:
        print(f"this render bills {billable}s at {resolution}, about ${estimate:.2f}")
        if not args.duration:
            print(f"  length is unset, so the model chooses it; {MAX_CLIP_SECONDS}s is the worst case.")
            print("  pass --duration 3..10 to pin it and approve a smaller number.")
        print(f"approve with: --approve {billable}")
        return 2
    if args.approve != billable:
        die(f"this render bills {billable}s but --approve says {args.approve}s; "
            "re-check the settings and confirm again")

    client = get_client()
    inp = build_input(args, client, prompt)

    response_format: dict = {"type": "video", "resolution": resolution}
    if args.aspect:
        response_format["aspect_ratio"] = args.aspect
    if args.duration:
        response_format["duration"] = f"{args.duration}s"
    use_uri = args.uri or resolution in BIG_RESOLUTIONS
    if use_uri:
        response_format["delivery"] = "uri"

    kwargs: dict = {"model": MODELS["video"], "input": inp, "response_format": response_format}
    if args.previous_id:
        kwargs["previous_interaction_id"] = args.previous_id
    if args.task:
        kwargs["generation_config"] = {"video_config": {"task": args.task}}
    if args.no_store:
        kwargs["store"] = False

    if not args.json:
        print(f"generating with {MODELS['video']} at {resolution}"
              + (f", {args.aspect}" if args.aspect else "")
              + (" (edit/extend of previous clip)" if args.previous_id else "")
              + " ...", flush=True)

    t0 = time.time()
    try:
        interaction = create_with_retry(client, **kwargs)
    except Exception as e:  # noqa: BLE001
        die(f"{type(e).__name__}: {e}")

    video = getattr(interaction, "output_video", None)
    if video is None:
        status = getattr(interaction, "status", "?")
        text = (getattr(interaction, "output_text", "") or "")[:500]
        die(f"no video in response (status={status}). Model said: {text!r}\n"
            "Prompts that trip the safety filter return no video; rephrase and retry.")

    if getattr(video, "data", None):
        save_b64(video.data, out)
    elif getattr(video, "uri", None):
        wait_for_uri(client, video.uri)
        out.parent.mkdir(parents=True, exist_ok=True)
        client.files.download(file=video.uri, destination=str(out))
    else:
        die("video block had neither inline data nor a uri")

    elapsed = round(time.time() - t0, 1)
    summary = {
        "out": str(out),
        "interaction_id": interaction.id,
        "model": MODELS["video"],
        "resolution": resolution,
        "aspect": args.aspect or "16:9",
        "duration": f"{args.duration}s" if args.duration else None,
        "billed_seconds": billable,
        "estimate_usd": round(estimate, 2),
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
