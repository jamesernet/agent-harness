#!/usr/bin/env python3
"""Capture frames of an HTML/SVG animation as PNGs so you can look at it, and
optionally stitch them into an .mp4 or .gif.

This is the QA step for code animations: open the file headlessly, seek to a
few timestamps, screenshot each. Look at the PNGs (the Read tool renders
images) before declaring the animation done.

  snapshot_animation.py hero.html                       # 5 frames across 3s -> motion/frames/
  snapshot_animation.py hero.html --duration 4 --frames 8 --width 800 --height 450
  snapshot_animation.py hero.html --duration 4 --fps 24 --mp4 hero.mp4   # render to video

Seeking uses the Web Animations API (document.getAnimations) so CSS/SVG/WAAPI
animations land on exact times; JS requestAnimationFrame loops can't be
seeked, so pass --realtime to wait wall-clock instead.

Needs Playwright:  pip install playwright && playwright install chromium
Video/GIF export also needs ffmpeg on PATH.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


def need_playwright():
    try:
        from playwright.sync_api import sync_playwright  # noqa: F401
        return sync_playwright
    except ImportError:
        print("error: playwright not installed.\n  pip install playwright && playwright install chromium", file=sys.stderr)
        sys.exit(1)


SEEK_JS = """
(t) => {
  const anims = document.getAnimations ? document.getAnimations() : [];
  for (const a of anims) { try { a.pause(); a.currentTime = t; } catch (e) {} }
  // SVG SMIL
  for (const svg of document.querySelectorAll('svg')) {
    try { svg.pauseAnimations(); svg.setCurrentTime(t / 1000); } catch (e) {}
  }
  return anims.length;
}
"""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file", help=".html or .svg to capture")
    ap.add_argument("--duration", type=float, default=3.0, help="seconds to cover (default 3)")
    ap.add_argument("--frames", type=int, default=5, help="number of stills (ignored with --fps)")
    ap.add_argument("--fps", type=int, help="capture at this frame rate instead (for --mp4/--gif)")
    ap.add_argument("--width", type=int, default=640)
    ap.add_argument("--height", type=int, default=360)
    ap.add_argument("--out-dir", default="motion/frames")
    ap.add_argument("--realtime", action="store_true", help="wait wall-clock instead of seeking (JS rAF animations)")
    ap.add_argument("--mp4", help="stitch frames into this .mp4 (needs ffmpeg)")
    ap.add_argument("--gif", help="stitch frames into this .gif (needs ffmpeg)")
    ap.add_argument("--background", default="white", help="page background colour for capture (CSS colour)")
    args = ap.parse_args()

    src = Path(args.file).resolve()
    if not src.is_file():
        print(f"error: not found: {src}", file=sys.stderr)
        return 1

    sync_playwright = need_playwright()
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    for old in out_dir.glob("frame_*.png"):
        old.unlink()

    total_ms = int(args.duration * 1000)
    if args.fps:
        n = max(1, int(args.duration * args.fps))
        times = [int(i * 1000 / args.fps) for i in range(n)]
    else:
        n = max(1, args.frames)
        times = [int(i * total_ms / max(1, n - 1)) for i in range(n)] if n > 1 else [0]

    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(viewport={"width": args.width, "height": args.height})
        page.goto(src.as_uri())
        page.add_style_tag(content=f"html{{background:{args.background}}}")
        page.wait_for_timeout(100)
        seekable = 0
        if not args.realtime:
            seekable = page.evaluate(SEEK_JS, 0)
            if seekable == 0:
                print("note: no seekable animations found (JS-driven?); falling back to --realtime", file=sys.stderr)
                args.realtime = True
        last = 0
        for i, t in enumerate(times):
            if args.realtime:
                page.wait_for_timeout(t - last)
                last = t
            else:
                page.evaluate(SEEK_JS, t)
                page.wait_for_timeout(16)
            page.screenshot(path=str(out_dir / f"frame_{i:04d}.png"))
        browser.close()

    print(f"captured {len(times)} frames to {out_dir}/ (t = {times[0]}..{times[-1]} ms)")

    if args.mp4 or args.gif:
        if not shutil.which("ffmpeg"):
            print("error: ffmpeg not on PATH; frames are saved but not stitched", file=sys.stderr)
            return 1
        fps = args.fps or max(1, round(len(times) / args.duration))
        pattern = str(out_dir / "frame_%04d.png")
        if args.mp4:
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(fps), "-i", pattern,
                            "-pix_fmt", "yuv420p", "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", args.mp4], check=True)
            print(f"wrote {args.mp4}")
        if args.gif:
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(fps), "-i", pattern,
                            "-vf", "split[a][b];[a]palettegen[p];[b][p]paletteuse", "-loop", "0", args.gif], check=True)
            print(f"wrote {args.gif}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
