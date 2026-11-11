#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["google-genai>=1.0"]
# ///
"""Render a shot plan into video clips with Veo (Gemini API), then stitch them.

The plan is authored by the agent; this script only executes it. Facts, not
judgment: it validates, renders what is missing, and records what it did.

Usage:
    python3 video.py check  plan.json                  # validate, print what a render would cost
    uv run  video.py render plan.json --approve 24     # render; 24 = seconds the user approved
    uv run  video.py render plan.json --approve 8 --only intro
    python3 video.py stitch plan.json                  # ffmpeg concat into out/<slug>.mp4

`check` and `stitch` are stdlib only. `render` needs google-genai (uv resolves it
from the header above) and GEMINI_API_KEY in the environment.

Outputs live next to the plan: out/shots/NN-<id>.mp4, out/manifest.json, and
out/<slug>.mp4. A shot is skipped when its clip exists and its spec hash matches
the manifest, so an edited shot re-renders and an untouched one never does.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

MODELS = {
    "veo-3.1-generate-preview",
    "veo-3.1-fast-generate-preview",
    "veo-3.1-lite-generate-preview",
}
ASPECTS = {"16:9", "9:16"}
RESOLUTIONS = {"720p", "1080p", "4k"}
DURATIONS = {4, 6, 8}
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
POLL_SECONDS = 10
TIMEOUT_SECONDS = 15 * 60


def die(msg):
    print(f"video: {msg}", file=sys.stderr)
    sys.exit(1)


def load_plan(path):
    path = Path(path).resolve()
    try:
        plan = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as e:
        die(f"cannot read plan {path}: {e}")
    errors = validate(plan, path.parent)
    if errors:
        for e in errors:
            print(f"plan: {e}", file=sys.stderr)
        sys.exit(1)
    return plan, path.parent


def validate(plan, base):
    errs = []
    for key in ("title", "model", "shots"):
        if key not in plan:
            errs.append(f"missing top-level '{key}'")
    if errs:
        return errs
    if plan["model"] not in MODELS:
        errs.append(f"model '{plan['model']}' not in {sorted(MODELS)}")
    if plan.get("aspect_ratio", "16:9") not in ASPECTS:
        errs.append(f"aspect_ratio must be one of {sorted(ASPECTS)}")
    res = plan.get("resolution", "720p")
    if res not in RESOLUTIONS:
        errs.append(f"resolution must be one of {sorted(RESOLUTIONS)}")
    if res == "4k" and "lite" in plan["model"]:
        errs.append("4k is not available on the lite model")
    if not isinstance(plan["shots"], list) or not plan["shots"]:
        errs.append("shots must be a non-empty list")
        return errs
    seen = set()
    for i, shot in enumerate(plan["shots"], 1):
        where = f"shot {i}"
        sid = shot.get("id", "")
        if not ID_RE.match(sid):
            errs.append(f"{where}: id must be lowercase letters, digits and hyphens")
        elif sid in seen:
            errs.append(f"{where}: duplicate id '{sid}'")
        seen.add(sid)
        if not str(shot.get("prompt", "")).strip():
            errs.append(f"{where}: empty prompt")
        dur = shot.get("duration", 8)
        if dur not in DURATIONS:
            errs.append(f"{where}: duration must be one of {sorted(DURATIONS)}")
        # Veo only renders 1080p, 4k and reference images at 8 seconds.
        if dur != 8 and (res != "720p" or shot.get("references")):
            errs.append(f"{where}: {res} or reference images require duration 8")
        refs = shot.get("references", [])
        if len(refs) > 3:
            errs.append(f"{where}: at most 3 reference images")
        for key in ("image", "last_frame"):
            if shot.get(key) and not (base / shot[key]).is_file():
                errs.append(f"{where}: {key} '{shot[key]}' not found")
        for ref in refs:
            if not (base / ref).is_file():
                errs.append(f"{where}: reference '{ref}' not found")
        if shot.get("last_frame") and not shot.get("image"):
            errs.append(f"{where}: last_frame needs a starting image")
    return errs


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-") or "video"


def full_prompt(plan, shot):
    style = plan.get("style", "").strip()
    return f"{shot['prompt'].strip()} {style}".strip()


def spec_hash(plan, shot, base):
    spec = {
        "model": plan["model"],
        "aspect_ratio": plan.get("aspect_ratio", "16:9"),
        "resolution": plan.get("resolution", "720p"),
        "prompt": full_prompt(plan, shot),
        "negative_prompt": shot.get("negative_prompt", plan.get("negative_prompt", "")),
        "duration": shot.get("duration", 8),
    }
    # Hash image contents, not names, so a replaced reference re-renders.
    for key in ("image", "last_frame"):
        if shot.get(key):
            spec[key] = hashlib.sha256((base / shot[key]).read_bytes()).hexdigest()
    spec["references"] = [
        hashlib.sha256((base / r).read_bytes()).hexdigest() for r in shot.get("references", [])
    ]
    return hashlib.sha256(json.dumps(spec, sort_keys=True).encode()).hexdigest()


def clip_path(base, index, shot):
    return base / "out" / "shots" / f"{index:02d}-{shot['id']}.mp4"


def load_manifest(base):
    p = base / "out" / "manifest.json"
    return json.loads(p.read_text()) if p.is_file() else {"shots": {}}


def save_manifest(base, manifest):
    p = base / "out" / "manifest.json"
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(manifest, indent=2) + "\n")


def pending(plan, base, only):
    manifest = load_manifest(base)
    todo = []
    for i, shot in enumerate(plan["shots"], 1):
        if only and shot["id"] not in only:
            continue
        h = spec_hash(plan, shot, base)
        done = manifest["shots"].get(shot["id"], {}).get("spec") == h and clip_path(base, i, shot).is_file()
        if not done:
            todo.append((i, shot, h))
    return todo


def cmd_check(args):
    plan, base = load_plan(args.plan)
    only = set(args.only or [])
    unknown = only - {s["id"] for s in plan["shots"]}
    if unknown:
        die(f"--only names unknown shots: {sorted(unknown)}")
    todo = pending(plan, base, only)
    total = sum(s.get("duration", 8) for _, s, _ in todo)
    print(f"plan: {plan['title']} — {len(plan['shots'])} shots, "
          f"{sum(s.get('duration', 8) for s in plan['shots'])}s total")
    print(f"model: {plan['model']}  {plan.get('aspect_ratio', '16:9')}  {plan.get('resolution', '720p')}")
    if not todo:
        print("to render: nothing — every selected shot is current")
        return
    for i, shot, _ in todo:
        print(f"  {i:02d} {shot['id']:<20} {shot.get('duration', 8)}s")
    print(f"to render: {len(todo)} shots, {total}s of video")
    flag = f" --only {' '.join(sorted(only))}" if only else ""
    print(f"approve with: render {args.plan}{flag} --approve {total}")


def cmd_render(args):
    plan, base = load_plan(args.plan)
    only = set(args.only or [])
    todo = pending(plan, base, only)
    total = sum(s.get("duration", 8) for _, s, _ in todo)
    if not todo:
        print("video: nothing to render")
        return
    # The approval is the seconds the user agreed to pay for. A mismatch means
    # the plan changed after they looked, so stop rather than guess.
    if args.approve != total:
        die(f"this render is {total}s but --approve says {args.approve}s; run check and re-confirm")
    if not os.environ.get("GEMINI_API_KEY"):
        die("GEMINI_API_KEY is not set")

    try:
        from google import genai
        from google.genai import types
    except ImportError:
        die("google-genai is not installed; run with `uv run video.py render ...`")

    client = genai.Client()
    manifest = load_manifest(base)
    manifest["title"] = plan["title"]

    for i, shot, h in todo:
        out = clip_path(base, i, shot)
        out.parent.mkdir(parents=True, exist_ok=True)
        cfg = {
            "aspect_ratio": plan.get("aspect_ratio", "16:9"),
            "resolution": plan.get("resolution", "720p"),
            "duration_seconds": shot.get("duration", 8),
            "number_of_videos": 1,
        }
        neg = shot.get("negative_prompt", plan.get("negative_prompt"))
        if neg:
            cfg["negative_prompt"] = neg
        if shot.get("last_frame"):
            cfg["last_frame"] = types.Image.from_file(location=str(base / shot["last_frame"]))
        if shot.get("references"):
            cfg["reference_images"] = [
                types.VideoGenerationReferenceImage(
                    image=types.Image.from_file(location=str(base / r)), reference_type="asset")
                for r in shot["references"]
            ]
        kwargs = {"model": plan["model"], "prompt": full_prompt(plan, shot),
                  "config": types.GenerateVideosConfig(**cfg)}
        if shot.get("image"):
            kwargs["image"] = types.Image.from_file(location=str(base / shot["image"]))

        print(f"video: {i:02d} {shot['id']} — submitting", flush=True)
        started = time.time()
        op = client.models.generate_videos(**kwargs)
        while not op.done:
            if time.time() - started > TIMEOUT_SECONDS:
                die(f"{shot['id']}: timed out after {TIMEOUT_SECONDS}s (operation {op.name})")
            time.sleep(POLL_SECONDS)
            op = client.operations.get(op)
        if op.error:
            die(f"{shot['id']}: {op.error}")
        videos = (op.response and op.response.generated_videos) or []
        if not videos:
            # Safety-filtered generations come back empty and are not billed.
            die(f"{shot['id']}: no video returned — likely filtered; revise the prompt")
        client.files.download(file=videos[0].video)
        videos[0].video.save(str(out))
        manifest["shots"][shot["id"]] = {
            "spec": h, "file": str(out.relative_to(base)), "model": plan["model"],
            "prompt": full_prompt(plan, shot), "operation": op.name,
            "seconds": shot.get("duration", 8), "rendered_at": int(time.time()),
        }
        # Save after every shot so an interrupted run resumes instead of re-paying.
        save_manifest(base, manifest)
        print(f"video: {i:02d} {shot['id']} — saved {out.relative_to(base)} "
              f"({int(time.time() - started)}s)", flush=True)


def cmd_stitch(args):
    plan, base = load_plan(args.plan)
    if not shutil.which("ffmpeg"):
        die("ffmpeg is not installed")
    clips = [clip_path(base, i, s) for i, s in enumerate(plan["shots"], 1)]
    missing = [c.name for c in clips if not c.is_file()]
    if missing:
        die(f"missing clips, render them first: {missing}")
    out = base / "out" / f"{slug(plan['title'])}.mp4"
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
        for c in clips:
            f.write(f"file '{c}'\n")
        listing = f.name
    try:
        # Re-encode rather than stream-copy: clips from different Veo models
        # can differ in encoder settings, and copy then fails at the seams.
        subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", listing,
             "-c:v", "libx264", "-crf", "18", "-preset", "medium", "-pix_fmt", "yuv420p",
             "-c:a", "aac", "-b:a", "192k", str(out)],
            check=True)
    except subprocess.CalledProcessError as e:
        die(f"ffmpeg failed ({e.returncode})")
    finally:
        os.unlink(listing)
    print(f"video: stitched {len(clips)} clips into {out.relative_to(base)}")


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check", help="validate the plan and show what a render would do")
    c.add_argument("plan")
    c.add_argument("--only", nargs="+", metavar="ID")
    r = sub.add_parser("render", help="render shots that are missing or changed")
    r.add_argument("plan")
    r.add_argument("--only", nargs="+", metavar="ID")
    r.add_argument("--approve", type=int, required=True, metavar="SECONDS",
                   help="seconds of video the user approved; must equal what check reports")
    s = sub.add_parser("stitch", help="concatenate rendered shots in plan order")
    s.add_argument("plan")
    args = p.parse_args()
    {"check": cmd_check, "render": cmd_render, "stitch": cmd_stitch}[args.cmd](args)


if __name__ == "__main__":
    main()
