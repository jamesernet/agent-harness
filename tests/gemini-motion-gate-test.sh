#!/usr/bin/env bash
set -euo pipefail

# The spend gate on the one skill in this repository that bills a third-party
# API per run, at both of its entry points: generate_video.py renders one clip,
# storyboard.py renders a plan of them. Nothing here touches the network: every
# case stops at or before the gate, and the key is removed from the environment
# so a case that got past the gate fails on a missing key instead of spending
# money.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
GEN="$SRC/skills/gemini-motion/scripts/generate_video.py"
SB="$SRC/skills/gemini-motion/scripts/storyboard.py"
EXAMPLE="$SRC/skills/gemini-motion/references/storyboard-example.json"

fail() {
  echo "gemini-motion gate test failed: $*" >&2
  exit 1
}

command -v python3 >/dev/null || {
  echo "gemini-motion gate tests: skipped (no python3)"
  exit 0
}

# Both spellings of the key, because the script accepts either.
gate() {
  env -u GEMINI_API_KEY -u GOOGLE_API_KEY python3 "$GEN" "$@" 2>&1 || true
}

# 1. No approval: the gate prices the render, prints the token to approve with,
#    and renders nothing.
out="$(gate "a cat" --duration 6 --draft)"
grep -q 'bills 6s at 360p, about \$0.14' <<<"$out" ||
  fail "the unapproved run did not price the render: $out"
grep -q 'approve with: --approve 6s@360p' <<<"$out" ||
  fail "the unapproved run did not print the approval token: $out"

# 2. The approval has to carry the resolution. Seconds alone priced one render
#    and licensed another: at 6s, 360p bills $0.14 and 4k bills $1.25, and
#    --approve 6 satisfied both.
out="$(gate "a cat" --duration 6 --resolution 4k --approve 6)"
grep -q 'not seconds alone' <<<"$out" ||
  fail "an approval of seconds alone was not refused: $out"

# 3. The token approved must be the token priced. This is the case the old gate
#    passed: approve the cheap draft, render at 4k, bill nine times as much.
out="$(gate "a cat" --duration 6 --resolution 4k --approve 6s@360p)"
grep -q 'bills 6s@4k but --approve says' <<<"$out" ||
  fail "an approval for a cheaper resolution was accepted: $out"

# 4. Changing the LENGTH after the approval is refused the same way.
out="$(gate "a cat" --duration 10 --draft --approve 6s@360p)"
grep -q 'bills 10s@360p but --approve says' <<<"$out" ||
  fail "an approval for a shorter clip was accepted: $out"

# 5. The matching token gets past the gate -- proven by the next failure being
#    the missing key rather than the gate, which is as far as this test goes.
out="$(gate "a cat" --duration 6 --draft --approve 6s@360p)"
grep -qE 'GEMINI_API_KEY is not set|google-genai package is not installed' <<<"$out" ||
  fail "the matching token did not get past the gate: $out"

# 6. With no --duration the model chooses the length, so the price quoted is the
#    worst case rather than a guess. Omni 1.2 defaults to 10 s but follows a
#    length the prompt names, up to 15, so the worst case is 15, not the
#    --duration cap.
out="$(gate "a cat" --draft)"
grep -q 'bills 15s at 360p' <<<"$out" ||
  fail "an unpinned length was not priced at the worst case: $out"

# 7. An extend returns the whole clip, and the rate is per second of OUTPUT, so
#    the price of a continuation is not the increment. Pricing it from the
#    10-second single-clip ceiling understated a 30-second result by 3x.
out="$(gate "extend this" --previous-id v1_abc)"
grep -q 'bills 30s at 720p, about \$2.10' <<<"$out" ||
  fail "an extend was not priced by the whole output: $out"
grep -q 'the rate applies to the WHOLE' <<<"$out" ||
  fail "an extend did not say what it is pricing: $out"

# 8. --output-seconds pins the finished length, so a user who knows it approves
#    less than the ceiling.
out="$(gate "extend this" --previous-id v1_abc --output-seconds 24)"
grep -q 'bills 24s at 720p, about \$1.68' <<<"$out" ||
  fail "--output-seconds did not pin the price: $out"

# 9. --task extend takes the same path with no --previous-id.
out="$(gate "extend this" --task extend)"
grep -q 'bills 30s at 720p' <<<"$out" ||
  fail "--task extend was priced as a fresh clip: $out"

# 10. Two flags that set the resolution to different values are refused rather
#     than silently ranked: --draft won, and the user was told nothing.
out="$(gate "a cat" --draft --resolution 4k --duration 6)"
grep -q 'pass one of them' <<<"$out" ||
  fail "--draft silently overrode an explicit --resolution: $out"

# 11. Omni 1.2 has no upscale task, so the gate does not offer one to price.
out="$(gate "upscale this" --previous-id v1_abc --task upscale)"
grep -q "invalid choice: 'upscale'" <<<"$out" ||
  fail "--task upscale was accepted, though Omni 1.2 has no such task: $out"

# 12. A clip passed with --video is continued as surely as one named by
#     --previous-id, and without --task the prompt alone decides that it is an
#     extend. Pricing it from --duration quoted 3s for an 18s result.
out="$(gate "Extend this video: pans left" --video clip.mp4 --duration 3)"
grep -q 'bills 30s at 720p' <<<"$out" ||
  fail "a --video continuation was priced from --duration: $out"
grep -q 'pass --task edit' <<<"$out" ||
  fail "an unspecified continuation did not say how to price it as an edit: $out"

# 13. An edit is one generation, so --task edit prices it at the one-clip
#     ceiling, not the extend ceiling: an over-large quote is how a gate gets
#     switched off.
out="$(gate "Make it night" --previous-id v1_abc --task edit)"
grep -q 'bills 15s at 720p' <<<"$out" ||
  fail "an edit was not priced as one clip: $out"

# 14. --output-seconds is a length the user reports, so it is held to what the
#     mode can return: below 3, above the mode's ceiling, or on a fresh clip
#     it is refused rather than priced.
for bad in "--previous-id v1_abc --output-seconds -5" \
  "--previous-id v1_abc --output-seconds 0" \
  "--previous-id v1_abc --output-seconds 1" \
  "--previous-id v1_abc --output-seconds 2" \
  "--previous-id v1_abc --output-seconds 31" \
  "--previous-id v1_abc --task edit --output-seconds 16" \
  "--duration 5 --output-seconds 5"; do
  # shellcheck disable=SC2086 # the flags are meant to split
  out="$(gate "a cat" $bad)"
  grep -q 'output-seconds' <<<"$out" && ! grep -q 'this render bills' <<<"$out" ||
    fail "--output-seconds was priced from $bad: $out"
done

# 15. Every row of the rate table is priced, not just the two the cases above
#     use: a typo in either upscaled row would otherwise underquote silently.
out="$(gate "a cat" --duration 10 --resolution 1080p)"
grep -q 'bills 10s at 1080p, about \$1.04' <<<"$out" ||
  fail "1080p was not priced at the 1.2 rate: $out"
out="$(gate "a cat" --duration 10 --resolution 4k)"
grep -q 'bills 10s at 4k, about \$2.09' <<<"$out" ||
  fail "4k was not priced at the 1.2 rate: $out"

# 16. A pinned length stops at 10: first/last-frame clips and extend turns
#     refuse more, and the storyboard caps its shots with the same number.
out="$(gate "a cat" --duration 11)"
grep -qE "invalid choice: '?11" <<<"$out" ||
  fail "--duration 11 was accepted: $out"

# 17. A task that makes a new clip makes --video a reference, not a clip to
#     continue, so it is priced from --duration like any new clip.
out="$(gate "a cat in this style" --video clip.mp4 --task reference_to_video --duration 6 --draft)"
grep -q 'bills 6s at 360p, about \$0.14' <<<"$out" && ! grep -q 'continues' <<<"$out" ||
  fail "--video as a reference was priced as a continuation: $out"

# --- storyboard.py: the same gate over a plan of shots -----------------------
#
# The plan lives in a temp directory because the cases below edit it between
# check and render, which is the defect the token exists to catch.

tmp="$(mktemp -d "${TMPDIR:-/tmp}/llmctx-storyboard-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
plan="$tmp/plan.json"

# reset_plan starts a case from the example plan with no out/ beside it.
reset_plan() {
  rm -rf "$(dirname "$plan")/out"
  cp "$EXAMPLE" "$plan"
}

# set_plan KEY VALUE edits a top-level field; set_shot N KEY VALUE edits shot N
# (1-based). VALUE is JSON, so a string needs its own quotes; a VALUE of -
# removes the field.
set_plan() {
  python3 - "$plan" "$1" "$2" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
if sys.argv[3] == "-":
    p.pop(sys.argv[2], None)
else:
    p[sys.argv[2]] = json.loads(sys.argv[3])
json.dump(p, open(sys.argv[1], "w"))
PY
}
set_shot() {
  python3 - "$plan" "$1" "$2" "$3" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
shot = p["shots"][int(sys.argv[2]) - 1]
if sys.argv[4] == "-":
    shot.pop(sys.argv[3], None)
else:
    shot[sys.argv[3]] = json.loads(sys.argv[4])
json.dump(p, open(sys.argv[1], "w"))
PY
}
reverse_shots() {
  python3 - "$plan" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
p["shots"].reverse()
json.dump(p, open(sys.argv[1], "w"))
PY
}

# seed_rendered leaves out/ the way a finished render does, without rendering:
# a clip file per shot and a manifest entry carrying what a render records --
# the spec hash the script itself computes, and the fields check and stitch
# read back. The clips are empty files unless --real is passed, which
# synthesizes them with ffmpeg at the plan's durations for a case that stitches.
seed_rendered() {
  python3 - "$SB" "$plan" "${1:-}" <<'PY'
import subprocess, sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]).parent))
import storyboard as sb
plan, plan_path = sb.load_plan(sys.argv[2])
base = plan_path.parent
manifest = {"title": plan["title"], "shots": {}}
for shot in plan["shots"]:
    clip = sb.clip_path(base, shot)
    clip.parent.mkdir(parents=True, exist_ok=True)
    if sys.argv[3] == "--real":
        d = shot["duration"]
        subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", f"color=c=blue:s=160x90:d={d}",
             "-f", "lavfi", "-i", f"sine=frequency=440:duration={d}", "-c:v", "libx264",
             "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", str(clip)], check=True)
    else:
        clip.touch()
    manifest["shots"][shot["id"]] = {
        "spec": sb.spec_hash(plan, shot, base), "file": str(clip.relative_to(base)),
        **sb.recorded(plan, shot), "style": plan.get("style", "")}
sb.save_manifest(base, manifest)
PY
}

# sb runs storyboard.py with no key and leaves its output in $out and its exit
# status in $rc, so a case asserts BOTH the message and the refusal: a run that
# prints "refused" and exits 0 would otherwise pass every case below.
sb() {
  rc=0
  out="$(env -u GEMINI_API_KEY -u GOOGLE_API_KEY python3 "$SB" "$@" 2>&1)" || rc=$?
}
refused() {
  [ "$rc" -ne 0 ] || fail "$1 printed a refusal but exited 0: $out"
}
# sb_rel runs the script by its bare name from its own directory, the way a
# user who has cd'd into the skill does. The line it prints has to run from
# anywhere else, so it cannot echo that bare name back.
sb_rel() {
  rc=0
  out="$(cd "$(dirname "$SB")" && env -u GEMINI_API_KEY -u GOOGLE_API_KEY python3 storyboard.py "$@" 2>&1)" || rc=$?
}
# sb_here names the plan relative to its own directory, the way a user who has
# cd'd to the plan does. The printed line has to run from anywhere else, so it
# cannot echo that relative name back either.
sb_here() {
  rc=0
  out="$(cd "$(dirname "$plan")" && env -u GEMINI_API_KEY -u GOOGLE_API_KEY python3 "$SB" "$@" 2>&1)" || rc=$?
}
# approve_line runs the command the last sb call printed after "approve with:",
# exactly as printed, with no key and from a directory that is neither the
# plan's nor the script's, into $out and $rc. It proves the line is runnable
# as shown (interpreter, script path and quoting included) and that its token
# is the one render recomputes, by getting past the gate.
mkdir -p "$tmp/elsewhere"
approve_line() {
  local cmd
  cmd="$(sed -n 's/^approve with: //p' <<<"$out")"
  [ -n "$cmd" ] || fail "no approve-with line to run in: $out"
  rc=0
  out="$(cd "$tmp/elsewhere" && env -u GEMINI_API_KEY -u GOOGLE_API_KEY bash -c "$cmd" 2>&1)" || rc=$?
}

# 18. No approval: check prices every pending shot, the total, the dollar
#     estimate and the token to approve with, renders nothing, and exits 0.
#     The example plan is 8 + 4 + 6 seconds at 720p.
reset_plan
sb check "$plan"
[ "$rc" -eq 0 ] || fail "check on a valid plan exited $rc: $out"
grep -qE '01 +desk +8s' <<<"$out" ||
  fail "check did not print a per-shot line: $out"
grep -q 'to render: 3 shots, 18s at 720p, about \$1.26' <<<"$out" ||
  fail "check did not price the plan: $out"
grep -q -- 'approve with: .*--approve 18s@720p' <<<"$out" ||
  fail "check did not print the approval token: $out"
[ ! -e "$tmp/out" ] ||
  fail "check wrote an out/ directory; pricing must not leave files behind"
approve_line
grep -qE 'GEMINI_API_KEY is not set|google-genai package is not installed' <<<"$out" ||
  fail "the approve-with line was not runnable as printed: $out"
# The same when the script was invoked by its bare name from its own directory:
# the printed line used to echo "storyboard.py", which no other directory runs.
sb_rel check "$plan"
[ "$rc" -eq 0 ] || fail "check invoked by a bare script name exited $rc: $out"
approve_line
grep -qE 'GEMINI_API_KEY is not set|google-genai package is not installed' <<<"$out" ||
  fail "the approve-with line from a bare-name invocation was not runnable elsewhere: $out"
# And when the plan was named relative to its own directory: the printed line
# used to echo "plan.json", which fails anywhere else with "cannot read plan".
sb_here check plan.json
[ "$rc" -eq 0 ] || fail "check with a relative plan path exited $rc: $out"
approve_line
grep -qE 'GEMINI_API_KEY is not set|google-genai package is not installed' <<<"$out" ||
  fail "the approve-with line from a relative plan path was not runnable elsewhere: $out"

# 19. Seconds alone are refused by name. They used to BE the approval, and the
#     plan's resolution could change under them.
sb render "$plan" --approve 18
refused "seconds alone"
grep -q 'not seconds alone' <<<"$out" ||
  fail "an approval of seconds alone was not refused: $out"
grep -q '18s@720p' <<<"$out" ||
  fail "the refusal did not name the token to use instead: $out"

# 20. The defect this gate exists for: approve at 720p, edit the plan to 4k,
#     render. Same seconds, three times the bill. The token is recomputed from
#     the plan on disk, so the old one no longer matches.
set_plan resolution '"4k"'
sb render "$plan" --approve 18s@720p
refused "an approval for a cheaper resolution"
grep -q 'bills 18s@4k but --approve says' <<<"$out" ||
  fail "a plan edited to a higher resolution was rendered on the old approval: $out"

# 21. The matching token gets past the gate -- proven by the next failure being
#     the missing key, which is as far as this test goes. By then out/ exists
#     and already ignores itself: the protection arrives with the directory.
sb render "$plan" --approve 18s@4k
grep -qE 'GEMINI_API_KEY is not set|google-genai package is not installed' <<<"$out" ||
  fail "the matching token did not get past the gate: $out"
[ "$(tail -1 "$tmp/out/.gitignore" 2>/dev/null)" = "*" ] ||
  fail "out/ was created without a .gitignore that ignores it"

# 22. Omni's limits are checked before anything is priced, each refusal naming
#     the limit: a shot longer than one call renders, a resolution the rate
#     table does not price, an id that would not survive as a filename, and an
#     image the model would reject -- an empty file (what a failed download
#     leaves) and an SVG -- through the same check the render makes, so the
#     plan fails here and not at the API.
reset_plan
set_shot 2 duration 12
sb check "$plan"
refused "a 12-second shot"
grep -q 'shot 2 (coffee): duration must be a whole number of seconds from 3 to 10' <<<"$out" ||
  fail "a 12-second shot was not refused by name: $out"

reset_plan
set_plan resolution '"480p"'
sb check "$plan"
refused "an unpriced resolution"
grep -q "resolution '480p' is not one of 360p, 720p, 1080p, 4k" <<<"$out" ||
  fail "an unpriced resolution was not refused by name: $out"

reset_plan
set_plan resolution '["720p"]'
sb check "$plan"
refused "a resolution that is not text"
grep -q "is not one of 360p, 720p, 1080p, 4k" <<<"$out" ||
  fail "a list for a resolution was a TypeError, not a refusal: $out"

reset_plan
set_shot 1 id '"desk\n"'
sb check "$plan"
refused "an id ending in a newline"
grep -q 'shot 1: id must be lowercase letters, digits and hyphens' <<<"$out" ||
  fail "an id ending in a newline was accepted into a filename: $out"

reset_plan
: >"$tmp/empty.png"
set_shot 1 first_frame '"empty.png"'
sb check "$plan"
refused "an empty image"
grep -q 'image file is empty' <<<"$out" ||
  fail "an empty image file was not refused before pricing: $out"

reset_plan
echo '<svg xmlns="http://www.w3.org/2000/svg"/>' >"$tmp/logo.svg"
set_shot 1 images '["logo.svg"]'
sb check "$plan"
refused "an SVG reference"
grep -q 'does not accept image/svg+xml' <<<"$out" ||
  fail "an SVG reference was not refused before pricing: $out"

# An image that exists but cannot be read passes the stat-only checks and was
# an OSError traceback out of pricing. Root reads anything, so the check is
# reported as skipped there rather than passed.
if [ "$(id -u)" -ne 0 ]; then
  reset_plan
  printf 'x' >"$tmp/locked.png"
  chmod 000 "$tmp/locked.png"
  set_shot 1 first_frame '"locked.png"'
  sb check "$plan"
  chmod 644 "$tmp/locked.png"
  refused "an unreadable image"
  grep -q 'cannot read image' <<<"$out" ||
    fail "an unreadable image was a traceback, not a refusal: $out"
else
  echo "gemini-motion gate tests: the unreadable-image check skipped (running as root)"
fi

# 23. A field of the wrong type is refused by name, not by traceback: a numeric
#     prompt crashed in full_prompt, a null style crashed on .strip(), and a
#     list for a title passed check and render and then crashed stitch -- after
#     the clips were paid for.
reset_plan
set_shot 1 prompt 42
sb check "$plan"
refused "a numeric prompt"
grep -q 'shot 1 (desk): prompt must be text' <<<"$out" ||
  fail "a numeric prompt was not refused by name: $out"

reset_plan
set_plan style null
sb check "$plan"
refused "a null style"
grep -q 'style must be text' <<<"$out" ||
  fail "a null style was not refused by name: $out"

reset_plan
set_plan title '["x"]'
sb check "$plan"
refused "a list for a title"
grep -q 'title must be text' <<<"$out" ||
  fail "a non-text title was not refused by name: $out"

# An empty path resolved to the plan directory and was refused as "image not
# found: <plan dir>", which names neither the shot nor the field.
reset_plan
set_shot 1 first_frame '""'
sb check "$plan"
refused "an empty first_frame"
grep -q 'shot 1 (desk): first_frame must be a path relative to the plan, and not empty' <<<"$out" ||
  fail "an empty first_frame was not refused by name: $out"

reset_plan
set_shot 1 images '[""]'
sb check "$plan"
refused "an empty images entry"
grep -q 'shot 1 (desk): images must be a list of paths relative to the plan, none empty' <<<"$out" ||
  fail "an empty images entry was not refused by name: $out"

# 24. Reordering shots after a render re-bills nothing. Clips were addressed by
#     plan position while the manifest keyed on id, so moving a shot made its
#     own clip look missing and every shot whose position changed was rendered
#     -- and paid for -- again.
reset_plan
seed_rendered
sb check "$plan"
[ "$rc" -eq 0 ] || fail "check on a rendered plan exited $rc: $out"
grep -q 'to render: nothing' <<<"$out" ||
  fail "a freshly rendered plan was priced again: $out"
reverse_shots
sb check "$plan"
[ "$rc" -eq 0 ] || fail "check on a reordered plan exited $rc: $out"
grep -q 'to render: nothing' <<<"$out" ||
  fail "reordering the shots re-priced unchanged clips: $out"
[ "$(grep -c 'rendered' <<<"$out")" -eq 3 ] ||
  fail "a reordered plan did not show every shot as rendered: $out"

# 25. The spec hash tells the roles apart: the same image moved from the first
#     frame to a reference changes what the shot renders, so the old clip is
#     stale and the shot is pending again. A flat list of image hashes called
#     them equal and kept the wrong clip.
reset_plan
printf 'not really a png, but non-empty' >"$tmp/a.png"
set_shot 1 first_frame '"a.png"'
seed_rendered
set_shot 1 first_frame -
set_shot 1 images '["a.png"]'
sb check "$plan"
[ "$rc" -eq 0 ] || fail "check after moving an image between roles exited $rc: $out"
grep -q 'to render: 1 shots, 8s at 720p' <<<"$out" ||
  fail "moving an image from first_frame to images kept the stale clip: $out"

# 26. A manifest that is not one -- a truncated write, or {} -- is refused
#     naming the file, rather than a KeyError from inside pending().
reset_plan
mkdir -p "$tmp/out"
echo '{}' >"$tmp/out/manifest.json"
sb check "$plan"
refused "a malformed manifest"
grep -q 'manifest.json is not a storyboard manifest' <<<"$out" ||
  fail "a malformed manifest was not refused by name: $out"

reset_plan
mkdir -p "$tmp/out"
echo '{"shots": {"desk": "x"}}' >"$tmp/out/manifest.json"
sb check "$plan"
refused "a manifest entry that is not one"
grep -q 'manifest.json is not a storyboard manifest' <<<"$out" ||
  fail "a malformed manifest entry was an AttributeError, not a refusal: $out"

# 27. A plan in a directory with an apostrophe, a space and a non-ASCII letter,
#     checked by a bare-name invocation. The approve-with line printed the bare
#     path and the bare script name, so it was not runnable for exactly the
#     plans a user keeps in "Jim's build/"; it names the interpreter and the
#     script's absolute path and quotes the rest now, and running it as printed
#     from elsewhere gets past the gate.
plan="$tmp/jim's büild/plan.json"
mkdir -p "$(dirname "$plan")"
reset_plan
set_shot 1 duration 3
set_shot 2 duration 3
set_shot 3 duration 3
sb_rel check "$plan"
[ "$rc" -eq 0 ] || fail "check on a plan in a quoted path exited $rc: $out"
approve_line
grep -qE 'GEMINI_API_KEY is not set|google-genai package is not installed' <<<"$out" ||
  fail "the approve-with line was not runnable with an apostrophe, a space and a non-ASCII letter in the path: $out"

# 28. The concat listing survives the same directory name: the apostrophe
#     (bare single quotes ended the path early) and the non-ASCII letter (the
#     listing is written as UTF-8, which the demuxer reads, whatever the
#     locale). Either broke stitch after every clip had been paid for. Needs
#     ffmpeg for real clips; without it the case is reported as skipped, not
#     passed.
if command -v ffmpeg >/dev/null; then
  seed_rendered --real
  sb stitch "$plan"
  [ "$rc" -eq 0 ] || fail "stitch in a directory with an apostrophe and a non-ASCII letter exited $rc: $out"
  [ -s "$tmp/jim's büild/out/morning-build.mp4" ] ||
    fail "stitch in a directory with an apostrophe and a non-ASCII letter wrote no file: $out"
else
  echo "gemini-motion gate tests: case 28 (stitch with an apostrophe in the path) skipped, no ffmpeg"
fi
plan="$tmp/plan.json"

# 29. render without --approve is the gate as generate_video.py has it: it
#     prices what is pending, prints the token, refuses, and writes nothing. A
#     user can go straight to render and still sees the price first.
reset_plan
sb render "$plan"
refused "an unapproved render"
grep -q 'to render: 3 shots, 18s at 720p, about \$1.26' <<<"$out" ||
  fail "an unapproved render did not price the plan: $out"
grep -q -- 'approve with: .*--approve 18s@720p' <<<"$out" ||
  fail "an unapproved render did not print the approval token: $out"
[ ! -e "$tmp/out" ] ||
  fail "an unapproved render wrote out/: $out"

# 30. render with nothing pending is a no-op that exits 0, token or not: it is
#     the natural resume command after an interrupted run, and it used to fail
#     in argparse because --approve was required.
reset_plan
seed_rendered
sb render "$plan"
[ "$rc" -eq 0 ] || fail "render with nothing pending exited $rc: $out"
grep -q 'nothing to render -- every selected shot is current' <<<"$out" ||
  fail "render with nothing pending did not say so: $out"
sb render "$plan" --approve 18s@720p
[ "$rc" -eq 0 ] || fail "render with nothing pending and a token exited $rc: $out"

# 31. stitch works from the manifest and the clips, not the images: a reference
#     deleted after a successful render used to make stitching impossible
#     without re-rendering. check still refuses the same plan, because check
#     and render do send the image. What the manifest records is still held
#     against the plan, so an edited prompt refuses rather than stitching a
#     stale clip. Needs ffmpeg; reported as skipped without it.
if command -v ffmpeg >/dev/null; then
  reset_plan
  printf 'not really a png, but non-empty' >"$tmp/frame.png"
  set_shot 1 first_frame '"frame.png"'
  set_shot 1 duration 3
  set_shot 2 duration 3
  set_shot 3 duration 3
  seed_rendered --real
  rm "$tmp/frame.png"
  sb stitch "$plan"
  [ "$rc" -eq 0 ] || fail "stitch after deleting a reference image exited $rc: $out"
  [ -s "$tmp/out/morning-build.mp4" ] || fail "stitch after deleting a reference image wrote no file"
  sb check "$plan"
  refused "check with a deleted reference image"
  grep -q 'image not found' <<<"$out" || fail "check did not refuse the deleted image by name: $out"
  set_shot 2 prompt '"Something else entirely."'
  sb stitch "$plan"
  refused "stitch with an edited prompt"
  grep -q 'coffee (prompt changed since it was rendered)' <<<"$out" ||
    fail "stitch did not refuse a shot whose prompt changed: $out"
else
  echo "gemini-motion gate tests: case 31 (stitch without the images) skipped, no ffmpeg"
fi

# 32. style is part of every prompt, so a style edit makes every shot stale and
#     re-bills the whole plan. check says that is why, rather than leaving the
#     user to work out what changed.
reset_plan
seed_rendered
set_plan style '"Grainy 16mm, desaturated."'
sb check "$plan"
[ "$rc" -eq 0 ] || fail "check after a style edit exited $rc: $out"
grep -q 'to render: 3 shots, 18s at 720p' <<<"$out" ||
  fail "a style edit did not re-price every shot: $out"
grep -q 'stale because style changed' <<<"$out" ||
  fail "check did not name style as the reason every shot is stale: $out"

# 33. The aspect ratio is recorded and held against the plan: rendered at 16:9
#     and edited to 9:16, stitch refuses naming every shot, where it used to
#     concatenate the 16:9 clips while check said every shot was pending.
reset_plan
seed_rendered
set_plan aspect_ratio '"9:16"'
sb stitch "$plan"
refused "stitch after an aspect_ratio edit"
for id in desk coffee window; do
  grep -q "$id (aspect_ratio changed since it was rendered)" <<<"$out" ||
    fail "stitch did not name $id as stale after the aspect_ratio edit: $out"
done

# 34. A manifest entry carrying only the spec -- the shape load_manifest
#     accepts, and what a hand repair produces -- records nothing stitch can
#     judge by, so stitch refuses it and check re-prices it: the two commands
#     agree, where stitch used to pass a clip check called stale.
reset_plan
seed_rendered
python3 - "$tmp/out/manifest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
m["shots"] = {k: {"spec": v["spec"]} for k, v in m["shots"].items()}
json.dump(m, open(sys.argv[1], "w"))
PY
sb stitch "$plan"
refused "stitch on spec-only manifest entries"
grep -q 'desk (prompt, duration, resolution, aspect_ratio, model not recorded)' <<<"$out" ||
  fail "stitch did not refuse a spec-only entry by name: $out"
sb check "$plan"
[ "$rc" -eq 0 ] || fail "check on spec-only manifest entries exited $rc: $out"
grep -q 'to render: 3 shots, 18s at 720p' <<<"$out" ||
  fail "check did not re-price the spec-only entries that stitch refuses: $out"

# 35. Images are checked only for the shots a command would read. A reference
#     deleted after an unrelated shot's render used to block --only work on the
#     other shot with "image not found"; the shot that lost its reference is
#     still refused by name whenever it is selected.
reset_plan
printf 'not really a png, but non-empty' >"$tmp/ref.png"
set_shot 2 images '["ref.png"]'
seed_rendered
rm "$tmp/ref.png"
sb check "$plan" --only desk
[ "$rc" -eq 0 ] || fail "check --only desk was blocked by another shot's missing reference: $out"
grep -q 'to render: nothing' <<<"$out" ||
  fail "check --only desk did not find desk current: $out"
sb render "$plan" --only desk
[ "$rc" -eq 0 ] || fail "render --only desk was blocked by another shot's missing reference: $out"
sb check "$plan"
refused "check with a deleted reference on a selected shot"
grep -q 'image not found' <<<"$out" ||
  fail "check did not refuse the deleted reference by name: $out"

echo "gemini-motion gate tests: passed"
