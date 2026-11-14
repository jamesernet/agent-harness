#!/usr/bin/env python3
"""Render a storyboard -- a plan of independent shots -- with Gemini Omni Flash, then stitch it.

The plan is authored by the agent; this script only executes it. It validates
the plan against Omni's limits, prices what is missing, renders after the exact
approval, and records what it did.

  python3 storyboard.py check  plan.json                      # validate, price, print the token
  python3 storyboard.py render plan.json                      # the same lines, then refuse to render
  python3 storyboard.py render plan.json --approve 18s@720p   # the token the line above printed
  python3 storyboard.py render plan.json --approve 8s@720p --only desk
  python3 storyboard.py stitch plan.json                      # ffmpeg concat into out/<slug>.mp4

Each shot is one billed Omni call with a pinned duration (3-10 s), made through
gemini_common.render_clip after one gemini_common.require_approval for the whole
run. Shots are independent clips stitched afterwards; nothing here chains on an
earlier interaction, because an extend bills the whole output every time.
Continuity comes from `style`, reference images and first/last frames.

Outputs live next to the plan: out/shots/<id>.mp4, out/manifest.json and
out/<slug>.mp4. out/ ignores itself. A shot is skipped when its clip exists and
its spec hash matches the manifest, so an edited shot re-renders and an
untouched one is never re-billed -- whatever position it moved to.

`check` and `stitch` are stdlib only. `render` needs google-genai and
GEMINI_API_KEY in the environment. See references/storyboard-plan.md.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from functools import lru_cache
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gemini_common import (  # noqa: E402
    ASPECTS,
    DEFAULT_TIMEOUT_S,
    MAX_CLIP_SECONDS,
    MIN_CLIP_SECONDS,
    MODELS,
    VIDEO_RATES_USD,
    approval_token,
    check_image,
    die,
    ignored_dir,
    log_run,
    positive_timeout,
    render_clip,
    require_approval,
    slug,
    usage_summary,
)

PLAN_FIELDS = ("title", "resolution", "aspect_ratio", "style", "shots")
SHOT_FIELDS = ("id", "prompt", "duration", "first_frame", "last_frame", "images")
ID_RE = re.compile(r"[a-z0-9][a-z0-9-]*")
OUT_DIR_NAME = "out"


# --- the plan ---------------------------------------------------------------


def validate(plan) -> list[str]:
    """Everything wrong with a plan, as messages that name the limit crossed.

    Fields a plan does not take are refused rather than ignored: a `model` or
    `negative_prompt` carried over from another format would otherwise be
    silently dropped from a render that costs money. Types are checked too,
    because a value of the wrong type that passes here surfaces as a traceback
    later -- in stitch, after every clip has been paid for.

    Images are not opened here. check_images() does that through check_image,
    the same rules the render applies, so a bad image fails the plan before
    anything bills instead of at the far end.
    """
    if not isinstance(plan, dict):
        return ["the plan must be a JSON object"]
    errs = [f"missing top-level '{k}'" for k in ("title", "resolution", "shots") if k not in plan]
    errs += [f"unknown top-level field '{k}'; a plan takes {', '.join(PLAN_FIELDS)}"
             for k in plan if k not in PLAN_FIELDS]
    if errs:
        return errs
    if not isinstance(plan["title"], str) or not plan["title"].strip():
        errs.append("title must be text; it names the stitched file")
    if "style" in plan and not isinstance(plan["style"], str):
        errs.append("style must be text; it is appended to every shot prompt")
    res = plan["resolution"]
    if not isinstance(res, str) or res not in VIDEO_RATES_USD:
        errs.append(f"resolution {res!r} is not one of {', '.join(VIDEO_RATES_USD)}; "
                    "one per plan, and it sets the per-second rate")
    if plan.get("aspect_ratio", ASPECTS[0]) not in ASPECTS:
        errs.append(f"aspect_ratio must be one of {', '.join(ASPECTS)}; one per plan, "
                    "mixed ratios do not stitch")
    if not isinstance(plan["shots"], list) or not plan["shots"]:
        errs.append("shots must be a non-empty list")
        return errs
    seen: set[str] = set()
    for i, shot in enumerate(plan["shots"], 1):
        where = f"shot {i}"
        if not isinstance(shot, dict):
            errs.append(f"{where}: must be a JSON object")
            continue
        sid = shot.get("id")
        # fullmatch, not match: `$` lets a trailing newline through, and the id
        # becomes a filename and a line in the concat listing.
        if isinstance(sid, str) and ID_RE.fullmatch(sid):
            where = f"shot {i} ({sid})"
            if sid in seen:
                errs.append(f"{where}: duplicate id; the manifest and the clip file key on it")
            seen.add(sid)
        else:
            errs.append(f"{where}: id must be lowercase letters, digits and hyphens")
        errs += [f"{where}: unknown field '{k}'; a shot takes {', '.join(SHOT_FIELDS)}"
                 for k in shot if k not in SHOT_FIELDS]
        prompt = shot.get("prompt")
        if not isinstance(prompt, str) or not prompt.strip():
            errs.append(f"{where}: prompt must be text, and not empty")
        dur = shot.get("duration")
        if dur is None:
            errs.append(f"{where}: duration is required, {MIN_CLIP_SECONDS} to {MAX_CLIP_SECONDS} "
                        "seconds; Omni bills per second, so every shot pins its length")
        elif isinstance(dur, bool) or not isinstance(dur, int) or \
                not MIN_CLIP_SECONDS <= dur <= MAX_CLIP_SECONDS:
            errs.append(f"{where}: duration must be a whole number of seconds from "
                        f"{MIN_CLIP_SECONDS} to {MAX_CLIP_SECONDS}, what one Omni call renders; "
                        f"got {dur!r}")
        for key in ("first_frame", "last_frame"):
            if key in shot and not isinstance(shot[key], str):
                errs.append(f"{where}: {key} must be a path relative to the plan")
        if shot.get("last_frame") and not shot.get("first_frame"):
            errs.append(f"{where}: last_frame needs a first_frame to interpolate from")
        images = shot.get("images", [])
        if not isinstance(images, list) or not all(isinstance(p, str) for p in images):
            errs.append(f"{where}: images must be a list of paths relative to the plan")
    return errs


def shot_images(shot: dict) -> list[str]:
    """Every image path a shot names, frames first, in the order the render sends them."""
    paths = [shot[k] for k in ("first_frame", "last_frame") if shot.get(k)]
    return paths + list(shot.get("images", []))


def check_images(plan: dict, base: Path) -> None:
    """Apply the render's own image rules to every image; check_image dies on the first bad one.

    That is where an SVG, a GIF, a missing file or an empty one is refused,
    with the type the model accepts named, before any shot is priced. These
    checks are a stat() each; the contents are read once, by content_hash,
    when the shots are priced against the manifest.
    """
    for shot in plan["shots"]:
        for p in shot_images(shot):
            check_image(base / p)


def load_plan(path: str) -> tuple[dict, Path]:
    plan_path = Path(path).resolve()
    try:
        plan = json.loads(plan_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        die(f"cannot read plan {plan_path}: {e}")
    base = plan_path.parent
    errors = validate(plan)
    if errors:
        for e in errors:
            print(f"plan: {e}", file=sys.stderr)
        sys.exit(1)
    check_images(plan, base)
    return plan, base


def selected(plan: dict, only) -> set[str]:
    """The ids --only names, refused if any is not in the plan."""
    chosen = set(only or [])
    unknown = chosen - {s["id"] for s in plan["shots"]}
    if unknown:
        die(f"--only names shots not in the plan: {', '.join(sorted(unknown))}")
    return chosen


# --- what has been rendered -------------------------------------------------


def full_prompt(plan: dict, shot: dict) -> str:
    return f"{shot['prompt'].strip()} {plan.get('style', '').strip()}".strip()


@lru_cache(maxsize=None)
def content_hash(path: Path) -> str:
    """sha256 of a file's bytes, read once per run however many shots name it."""
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError as e:
        die(f"cannot read image {path}: {e.strerror or e}")
        return ""  # unreachable: die() exits


def spec_hash(plan: dict, shot: dict, base: Path) -> str:
    """What a clip was rendered from; a change to any of it re-renders the shot.

    Image CONTENTS are hashed, not names, so a replaced frame re-renders too;
    and each image is hashed under its ROLE, because the same file as a first
    frame and as a reference are different renders.
    """
    def h(p: str | None) -> str | None:
        return content_hash(base / p) if p else None

    spec = {
        "model": MODELS["video"],
        "resolution": plan["resolution"],
        "aspect_ratio": plan.get("aspect_ratio", ASPECTS[0]),
        "prompt": full_prompt(plan, shot),
        "duration": shot["duration"],
        "first_frame": h(shot.get("first_frame")),
        "last_frame": h(shot.get("last_frame")),
        "images": [h(p) for p in shot.get("images", [])],
    }
    return hashlib.sha256(json.dumps(spec, sort_keys=True).encode()).hexdigest()


def clip_path(base: Path, shot: dict) -> Path:
    # Keyed on the id alone, like the manifest, so a shot keeps its clip when
    # it moves in the plan; a position in the name made every move a re-bill.
    return base / OUT_DIR_NAME / "shots" / f"{shot['id']}.mp4"


def load_manifest(base: Path) -> dict:
    p = base / OUT_DIR_NAME / "manifest.json"
    if not p.is_file():
        return {"shots": {}}
    try:
        manifest = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        manifest = None
    shots = manifest.get("shots") if isinstance(manifest, dict) else None
    if not isinstance(shots, dict) or not all(
            isinstance(e, dict) and isinstance(e.get("spec"), str) for e in shots.values()):
        die(f"{p} is not a storyboard manifest (a JSON object with a 'shots' table whose "
            "entries carry a 'spec' hash); repair it or move it aside before rendering -- "
            "without it every shot is priced again")
    return manifest


def save_manifest(base: Path, manifest: dict) -> None:
    # Through ignored_dir, so out/ cannot exist without the .gitignore that
    # keeps billed clips and whole prompts out of the repository. Written to a
    # sibling and renamed, so an interrupted write cannot leave a half-manifest
    # that would price every finished clip again.
    d = ignored_dir(base / OUT_DIR_NAME)
    tmp = d / "manifest.json.tmp"
    tmp.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, d / "manifest.json")


def pending(plan: dict, base: Path, only: set[str]) -> list[tuple[int, dict, str]]:
    """(position, shot, spec hash) for every selected shot without a current clip."""
    manifest = load_manifest(base)
    todo = []
    for i, shot in enumerate(plan["shots"], 1):
        if only and shot["id"] not in only:
            continue
        h = spec_hash(plan, shot, base)
        recorded = manifest["shots"].get(shot["id"], {}).get("spec")
        if recorded != h or not clip_path(base, shot).is_file():
            todo.append((i, shot, h))
    return todo


# --- commands ----------------------------------------------------------------


def report(plan: dict, todo: list, only: set[str], plan_arg: str) -> None:
    """What check prints, and what an unapproved render prints before refusing."""
    pending_ids = {s["id"] for _, s, _ in todo}
    res = plan["resolution"]
    print(f"plan: {plan['title']} -- {len(plan['shots'])} shots, "
          f"{sum(s['duration'] for s in plan['shots'])}s at {res}, {plan.get('aspect_ratio', ASPECTS[0])}")
    for i, shot in enumerate(plan["shots"], 1):
        if shot["id"] in pending_ids:
            note = ""
        elif only and shot["id"] not in only:
            note = "  not selected"
        else:
            note = "  rendered"
        print(f"  {i:02d} {shot['id']:<20} {shot['duration']:>2}s{note}")
    if not todo:
        print("to render: nothing -- every selected shot is current")
        return
    total = sum(s["duration"] for _, s, _ in todo)
    print(f"to render: {len(todo)} shots, {total}s at {res}, about ${total * VIDEO_RATES_USD[res]:.2f}")
    # Runnable as printed: the script as it was invoked, and every path and id
    # quoted for the shell -- a plan in "Jim's build/" is the ordinary case.
    cmd = [shlex.quote(sys.argv[0]), "render", shlex.quote(plan_arg)]
    if only:
        cmd += ["--only", *(shlex.quote(i) for i in sorted(only))]
    cmd += ["--approve", approval_token(total, res)]
    print("approve with: " + " ".join(cmd))


def cmd_check(args) -> int:
    plan, base = load_plan(args.plan)
    only = selected(plan, args.only)
    report(plan, pending(plan, base, only), only, args.plan)
    return 0


def cmd_render(args) -> int:
    plan, base = load_plan(args.plan)
    only = selected(plan, args.only)
    todo = pending(plan, base, only)
    if not todo:
        print("nothing to render -- every selected shot is current")
        return 0
    if args.approve is None:
        # The gate as generate_video.py has it: price, print the token, refuse.
        # Nothing is written and no client is made.
        report(plan, todo, only, args.plan)
        return 2
    res = plan["resolution"]
    total = sum(s["duration"] for _, s, _ in todo)
    # The token is recomputed from the plan on disk, so a plan edited after
    # the price was shown no longer matches, and the run stops here.
    require_approval(args.approve, approval_token(total, res))

    ignored_dir(base / OUT_DIR_NAME)
    manifest = load_manifest(base)
    manifest["title"] = plan["title"]
    for i, shot, h in todo:
        clip = clip_path(base, shot)
        prompt = full_prompt(plan, shot)
        t0 = time.time()
        interaction = render_clip(
            prompt, clip, resolution=res, timeout=args.timeout,
            aspect=plan.get("aspect_ratio"), duration=shot["duration"],
            images=[base / p for p in shot.get("images", [])],
            first_frame=base / shot["first_frame"] if shot.get("first_frame") else None,
            last_frame=base / shot["last_frame"] if shot.get("last_frame") else None,
            announce=f"{i:02d} {shot['id']}: generating with {MODELS['video']} at {res}, "
                     f"{shot['duration']}s ...",
        )
        elapsed = round(time.time() - t0, 1)
        entry = {
            "spec": h,
            "file": str(clip.relative_to(base)),
            "model": MODELS["video"],
            "resolution": res,
            "duration": shot["duration"],
            "prompt": prompt,
            "interaction_id": interaction.id,
            "rendered_at": int(time.time()),
        }
        manifest["shots"][shot["id"]] = entry
        # Saved after every shot, so an interrupted run resumes instead of re-paying.
        save_manifest(base, manifest)
        log_run("storyboard", plan=str(Path(args.plan).resolve()), shot=shot["id"], **entry,
                estimate_usd=round(shot["duration"] * VIDEO_RATES_USD[res], 2),
                seconds=elapsed, usage=usage_summary(interaction))
        print(f"{i:02d} {shot['id']}: saved {entry['file']}  ({elapsed}s)")
    return 0


def concat_listing(clips: list[Path]) -> str:
    """The ffmpeg concat demuxer's file list: one quoted path per line.

    Inside its single quotes a quote is written '\\'' (close, escaped quote,
    reopen), the demuxer's own rule; a bare quote in a directory name such as
    "Jim's build" ended the path early and failed the stitch after every clip
    had been paid for.
    """
    return "".join("file '" + str(c).replace("'", r"'\''") + "'\n" for c in clips)


def cmd_stitch(args) -> int:
    plan, base = load_plan(args.plan)
    if not shutil.which("ffmpeg"):
        die("ffmpeg is not installed; stitch needs it (check and render do not)")
    stale = pending(plan, base, set())
    if stale:
        die("render first; these shots have no current clip: "
            + ", ".join(s["id"] for _, s, _ in stale))
    clips = [clip_path(base, s) for s in plan["shots"]]
    out = ignored_dir(base / OUT_DIR_NAME) / f"{slug(plan['title'])}.mp4"
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as fh:
        fh.write(concat_listing(clips))
        listing = fh.name
    try:
        # Re-encode rather than stream-copy: clips rendered on different days
        # can differ in encoder settings, and a copy then fails at the seams.
        subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", listing,
             "-c:v", "libx264", "-crf", "18", "-preset", "medium", "-pix_fmt", "yuv420p",
             "-c:a", "aac", "-b:a", "192k", str(out)],
            check=True)
    except subprocess.CalledProcessError as e:
        die(f"ffmpeg failed ({e.returncode})")
    finally:
        os.unlink(listing)
    print(f"stitched {len(clips)} clips into {out.relative_to(base)}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check", help="validate the plan and print what a render would bill")
    c.add_argument("plan")
    c.add_argument("--only", nargs="+", metavar="ID", help="price only these shots")
    r = sub.add_parser("render", help="render the shots that are missing or changed")
    r.add_argument("plan")
    r.add_argument("--only", nargs="+", metavar="ID", help="render only these shots")
    r.add_argument("--approve", metavar="<N>s@<resolution>",
                   help="the price you agreed to pay, as the exact token this script prints; it\n"
                        "carries the resolution too, because that sets the per-second rate.\n"
                        "Without it, render prices what is pending and refuses")
    r.add_argument("--timeout", type=positive_timeout, default=DEFAULT_TIMEOUT_S["video"],
                   help=f"seconds to wait for each shot before giving up (default {DEFAULT_TIMEOUT_S['video']})")
    s = sub.add_parser("stitch", help="concatenate the rendered shots in plan order")
    s.add_argument("plan")
    args = ap.parse_args()
    return {"check": cmd_check, "render": cmd_render, "stitch": cmd_stitch}[args.cmd](args)


if __name__ == "__main__":
    raise SystemExit(main())
