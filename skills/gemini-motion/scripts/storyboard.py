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
from typing import NamedTuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gemini_common import (  # noqa: E402
    ASPECTS,
    DEFAULT_TIMEOUT_S,
    DELIVERY_TIMEOUT_S,
    MAX_CLIP_SECONDS,
    MIN_CLIP_SECONDS,
    MODELS,
    VIDEO_RATES_USD,
    DeliveryFailed,
    check_image,
    die,
    fetch_clip,
    ignored_dir,
    log_run,
    positive_timeout,
    price,
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

    Images are not opened here. pending() checks each selected shot's images
    through check_image, the same rules the render applies, before it reads
    them, so a bad image fails the plan before anything bills instead of at
    the far end.
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
        # An empty path is refused here: it resolves to the plan directory and
        # would otherwise be reported as "image not found: <plan dir>".
        for key in ("first_frame", "last_frame"):
            if key in shot and (not isinstance(shot[key], str) or not shot[key].strip()):
                errs.append(f"{where}: {key} must be a path relative to the plan, and not empty")
        if shot.get("last_frame") and not shot.get("first_frame"):
            errs.append(f"{where}: last_frame needs a first_frame to interpolate from")
        images = shot.get("images", [])
        if not isinstance(images, list) or not all(isinstance(p, str) and p.strip() for p in images):
            errs.append(f"{where}: images must be a list of paths relative to the plan, none empty")
    return errs


def shot_images(shot: dict) -> list[str]:
    """Every image path a shot names, frames first, in the order the render sends them."""
    paths = [shot[k] for k in ("first_frame", "last_frame") if shot.get(k)]
    return paths + list(shot.get("images", []))


def load_plan(path: str) -> tuple[dict, Path]:
    """The plan, validated in shape, and its resolved path; the plan directory is that path's parent.

    Images are not touched here: pending() checks and reads those of the shots
    it prices, and stitch never needs them.
    """
    plan_path = Path(path).resolve()
    try:
        plan = json.loads(plan_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        die(f"cannot read plan {plan_path}: {e}")
    errors = validate(plan)
    if errors:
        for e in errors:
            print(f"plan: {e}", file=sys.stderr)
        sys.exit(1)
    return plan, plan_path


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


def recorded(plan: dict, shot: dict) -> dict:
    """What a manifest entry records about its clip, besides the spec hash and the images.

    stitch judges a clip by these alone, since it never reads images; so an
    entry that lacks any of them, or differs in any, is stale for every
    command -- check and render re-render it, stitch refuses it -- and the
    three cannot disagree about the same clip.
    """
    return {
        "prompt": full_prompt(plan, shot),
        "duration": shot["duration"],
        "resolution": plan["resolution"],
        "aspect_ratio": plan.get("aspect_ratio", ASPECTS[0]),
        "model": MODELS["video"],
    }


def stale_fields(entry: dict, plan: dict, shot: dict) -> tuple[list[str], list[str]]:
    """(changed, missing): recorded fields the entry differs in from the plan now, and ones it lacks."""
    now = recorded(plan, shot)
    changed = [k for k, v in now.items() if k in entry and entry[k] != v]
    missing = [k for k in now if k not in entry]
    return changed, missing


@lru_cache(maxsize=None)
def content_hash(path: Path) -> str:
    """sha256 of a file's bytes, read once per run however many shots name it."""
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError as e:
        die(f"cannot read image {path}: {e.strerror or e}")


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


class Pending(NamedTuple):
    """What a run would bill, computed once and read by every command.

    The price shown and the price checked come from the same `seconds`, and
    the manifest the shots were judged against is the one render updates.
    """
    shots: list[tuple[int, dict, str]]  # (position, shot, spec hash)
    seconds: int
    manifest: dict
    # Shots rendered and billed but never saved: collected by id, free.
    fetch: list[tuple[int, dict, str]] = []


def pending(plan: dict, base: Path, only: set[str]) -> Pending:
    """Every selected shot without a current clip, with the seconds they total.

    A shot whose entry matches but whose clip is missing, and which carries an
    interaction id, was billed and not saved -- the id goes on record before
    the clip is collected -- so it is fetched, not priced again.
    """
    manifest = load_manifest(base)
    todo, fetch = [], []
    for i, shot in enumerate(plan["shots"], 1):
        if only and shot["id"] not in only:
            continue
        # Images are checked by name before they are read, and only for the
        # shots selected here: a reference deleted after an unrelated shot's
        # render must not block --only work on another shot.
        for p in shot_images(shot):
            check_image(base / p)
        h = spec_hash(plan, shot, base)
        entry = manifest["shots"].get(shot["id"], {})
        changed, missing = stale_fields(entry, plan, shot)
        if entry.get("spec") != h or changed or missing:
            todo.append((i, shot, h))
        elif not clip_path(base, shot).is_file():
            (fetch if entry.get("interaction_id") else todo).append((i, shot, h))
    return Pending(todo, sum(s["duration"] for _, s, _ in todo), manifest, fetch)


# --- commands ----------------------------------------------------------------


def style_changed(plan: dict, pend: Pending, only: set[str]) -> bool:
    """Every selected shot is pending, and each was rendered under a different style."""
    chosen = [s for s in plan["shots"] if not only or s["id"] in only]
    if not chosen or len(pend.shots) != len(chosen):
        return False
    entries = [pend.manifest["shots"].get(s["id"]) for s in chosen]
    return all(e is not None and "style" in e and e["style"] != plan.get("style", "") for e in entries)


def report(plan: dict, pend: Pending, only: set[str], plan_path: Path) -> None:
    """What check prints, and what an unapproved render prints before refusing."""
    pending_ids = {s["id"] for _, s, _ in pend.shots}
    fetch_ids = {s["id"] for _, s, _ in pend.fetch}
    res = plan["resolution"]
    print(f"plan: {plan['title']} -- {len(plan['shots'])} shots, "
          f"{sum(s['duration'] for s in plan['shots'])}s at {res}, {plan.get('aspect_ratio', ASPECTS[0])}")
    for i, shot in enumerate(plan["shots"], 1):
        if shot["id"] in pending_ids:
            note = ""
        elif shot["id"] in fetch_ids:
            note = "  billed, not saved: render fetches it, free"
        elif only and shot["id"] not in only:
            note = "  not selected"
        else:
            note = "  rendered"
        print(f"  {i:02d} {shot['id']:<20} {shot['duration']:>2}s{note}")
    if pend.fetch:
        n = len(pend.fetch)
        print(f"to fetch: {n} shot{'s' if n > 1 else ''} already billed, collected free by render")
    if not pend.shots:
        print("to render: nothing -- every selected shot is current"
              if not pend.fetch else "to render: nothing billed; run render to fetch")
        return
    priced = price(pend.seconds, res)
    print(f"to render: {len(pend.shots)} shots, {priced.text}")
    if style_changed(plan, pend, only):
        print("  every selected shot is stale because style changed: style is part of every "
              "prompt, so a style edit re-renders the whole plan")
    # Runnable as printed from any directory: this interpreter, this script and
    # the plan by absolute path (a bare "storyboard.py" typed from the scripts
    # directory is not on PATH, and "plan.json" is in no other directory), and
    # every path and id quoted for the shell -- a plan in "Jim's build/" is the
    # ordinary case.
    cmd = [shlex.quote(sys.executable), shlex.quote(os.path.abspath(sys.argv[0])),
           "render", shlex.quote(str(plan_path))]
    if only:
        cmd += ["--only", *(shlex.quote(i) for i in sorted(only))]
    cmd += ["--approve", priced.token]
    print("approve with: " + " ".join(cmd))


def cmd_check(args) -> int:
    plan, plan_path = load_plan(args.plan)
    only = selected(plan, args.only)
    report(plan, pending(plan, plan_path.parent, only), only, plan_path)
    return 0


def cmd_render(args) -> int:
    plan, plan_path = load_plan(args.plan)
    base = plan_path.parent
    only = selected(plan, args.only)
    pend = pending(plan, base, only)
    if not pend.shots and not pend.fetch:
        print("nothing to render -- every selected shot is current")
        return 0
    if pend.shots and args.approve is None:
        # The gate as generate_video.py has it: price, print the token, refuse.
        # Nothing is written and no client is made.
        report(plan, pend, only, plan_path)
        return 2
    res = plan["resolution"]
    # The token is recomputed from the plan on disk -- the same seconds report()
    # prices -- so a plan edited after the price was shown no longer matches,
    # and the run stops here.
    if pend.shots:
        require_approval(args.approve, price(pend.seconds, res).token)

    ignored_dir(base / OUT_DIR_NAME)
    manifest = pend.manifest
    manifest["title"] = plan["title"]
    manifest_name = f"{OUT_DIR_NAME}/manifest.json"

    for i, shot, _ in pend.fetch:
        entry = manifest["shots"][shot["id"]]
        try:
            fetch_clip(entry["interaction_id"], clip_path(base, shot), timeout=args.delivery_timeout)
        except DeliveryFailed as e:
            die(f"{shot['id']}: {e}\nrun render again to retry. To give up on it and render "
                f"the shot again, which bills again, delete \"{shot['id']}\" from {manifest_name}.")
        log_run("storyboard-fetch", plan=str(plan_path), shot=shot["id"],
                interaction_id=entry["interaction_id"])
        print(f"{i:02d} {shot['id']}: fetched {entry['file']} (already billed)")

    for i, shot, h in pend.shots:
        clip = clip_path(base, shot)
        prompt = full_prompt(plan, shot)
        entry = {
            "spec": h,
            "file": str(clip.relative_to(base)),
            **recorded(plan, shot),
            "style": plan.get("style", ""),
        }

        def billed(interaction, entry=entry, shot=shot, clip=clip):
            # On record before the clip is collected: if that fails, the next
            # render fetches this id instead of billing the shot again. The old
            # clip goes first: once the entry carries the new spec, a clip left
            # at the path would read as the new one, and stitch.
            clip.unlink(missing_ok=True)
            entry["interaction_id"] = interaction.id
            entry["rendered_at"] = int(time.time())
            manifest["shots"][shot["id"]] = entry
            save_manifest(base, manifest)
            log_run("storyboard-billed", plan=str(plan_path), shot=shot["id"],
                    interaction_id=interaction.id,
                    estimate_usd=round(price(shot["duration"], res).usd, 2))

        try:
            interaction, render_seconds = render_clip(
                prompt, clip, resolution=res, timeout=args.timeout,
                aspect=plan.get("aspect_ratio"), duration=shot["duration"],
                images=[base / p for p in shot.get("images", [])],
                first_frame=base / shot["first_frame"] if shot.get("first_frame") else None,
                last_frame=base / shot["last_frame"] if shot.get("last_frame") else None,
                announce=f"{i:02d} {shot['id']}: generating with {MODELS['video']} at {res}, "
                         f"{shot['duration']}s ...",
                delivery_timeout=args.delivery_timeout, on_created=billed,
            )
        except DeliveryFailed as e:
            die(f"{shot['id']}: {e}\nit is in {manifest_name}; run render again to fetch it "
                "without paying again.")
        elapsed = round(render_seconds, 1)
        log_run("storyboard", plan=str(plan_path), shot=shot["id"], **entry,
                estimate_usd=round(price(shot["duration"], res).usd, 2),
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


def not_stitchable(plan: dict, base: Path, manifest: dict) -> list[str]:
    """Shots stitch cannot use, each with its reason, judged from the manifest and the clips alone.

    Images are not consulted: a reference deleted after a successful render
    must not make the stitch impossible. Everything else the entry records
    (see recorded) is held against the plan, and an entry that lacks any of
    it is refused too, so a stale clip is never stitched silently and check,
    render and stitch agree about the same clip; an image edit alone is
    check's and render's job.
    """
    reasons = []
    for shot in plan["shots"]:
        entry = manifest["shots"].get(shot["id"])
        if entry is None or not clip_path(base, shot).is_file():
            reasons.append(f"{shot['id']} (not rendered)")
            continue
        changed, missing = stale_fields(entry, plan, shot)
        why = []
        if changed:
            why.append(f"{', '.join(changed)} changed since it was rendered")
        if missing:
            why.append(f"{', '.join(missing)} not recorded")
        if why:
            reasons.append(f"{shot['id']} ({'; '.join(why)})")
    return reasons


def cmd_stitch(args) -> int:
    plan, plan_path = load_plan(args.plan)
    base = plan_path.parent
    # Staleness first, then the tool: "render first" is the useful answer when
    # the clips are stale, whether or not ffmpeg is installed.
    reasons = not_stitchable(plan, base, load_manifest(base))
    if reasons:
        die("render first; these shots have no current clip: " + ", ".join(reasons))
    if not shutil.which("ffmpeg"):
        die("ffmpeg is not installed; stitch needs it (check and render do not)")
    clips = [clip_path(base, s) for s in plan["shots"]]
    out = ignored_dir(base / OUT_DIR_NAME) / f"{slug(plan['title'])}.mp4"
    # UTF-8 by name: the demuxer reads the listing as UTF-8, and the locale's
    # encoding may not be able to write a non-ASCII clip path at all -- a
    # UnicodeEncodeError here would land after every clip had been paid for.
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False, encoding="utf-8") as fh:
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
    r.add_argument("--delivery-timeout", type=positive_timeout, default=DELIVERY_TIMEOUT_S,
                   help=f"seconds to wait for each rendered clip to be saved (default {DELIVERY_TIMEOUT_S}); "
                        "a shot that runs out is fetched, not re-billed, on the next render")
    r.add_argument("--timeout", type=positive_timeout, default=DEFAULT_TIMEOUT_S["video"],
                   help=f"seconds to wait for each shot before giving up (default {DEFAULT_TIMEOUT_S['video']})")
    s = sub.add_parser("stitch", help="concatenate the rendered shots in plan order")
    s.add_argument("plan")
    args = ap.parse_args()
    return {"check": cmd_check, "render": cmd_render, "stitch": cmd_stitch}[args.cmd](args)


if __name__ == "__main__":
    raise SystemExit(main())
