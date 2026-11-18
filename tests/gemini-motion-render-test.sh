#!/usr/bin/env bash
set -euo pipefail

# The billed call behind the gemini-motion spend gate. The gate test stops
# every case before a client exists, so it cannot see how the call that bills
# is made. This one runs the real scripts against a stub google.genai that
# records each call and never opens a socket. The stub shadows an installed
# SDK through PYTHONPATH, which a .pth file that imports `google` first can
# defeat -- so the test checks which package it got before any case runs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
GEN="$SRC/skills/gemini-motion/scripts/generate_video.py"
SB="$SRC/skills/gemini-motion/scripts/storyboard.py"
EXAMPLE="$SRC/skills/gemini-motion/references/storyboard-example.json"

fail() {
  echo "gemini-motion render test failed: $*" >&2
  exit 1
}

command -v python3 >/dev/null || {
  echo "gemini-motion render tests: skipped (no python3)"
  exit 0
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/llmctx-gm-render.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
stub="$tmp/stub"
mkdir -p "$stub/google/genai"
: >"$stub/google/__init__.py"
cat >"$stub/google/genai/types.py" <<'PY'
class HttpRetryOptions:
    def __init__(self, attempts=None):
        self.attempts = attempts
class HttpOptions:
    def __init__(self, retry_options=None, api_version=None):
        self.retry_options = retry_options
        self.api_version = api_version
PY
cat >"$stub/google/genai/__init__.py" <<'PY'
import base64, json, os, time
from types import SimpleNamespace
from . import types

def _log(**entry):
    with open(os.environ["STUB_LOG"], "a") as fh:
        fh.write(json.dumps(entry, sort_keys=True) + "\n")

class Client:
    def __init__(self, api_key=None, http_options=None):
        # "default" is the SDK's own retry policy; 1 is retries off.
        retry = http_options.retry_options if http_options else None
        self.retries = retry.attempts if retry else "default"
        # "default" is the SDK's v1, where no Omni model is served.
        self.api_version = (http_options.api_version if http_options else None) or "default"
        self.files = SimpleNamespace(upload=self._upload, get=self._get, download=self._download)
        self.interactions = SimpleNamespace(create=self._create, get=self._get_interaction)

    def _upload(self, file):
        _log(call="upload", retries=self.retries)
        time.sleep(float(os.environ.get("STUB_UPLOAD_DELAY", "0")))
        return SimpleNamespace(name="files/up", uri="https://stub/files/up", state="ACTIVE")

    def _get(self, name):
        state = os.environ.get("STUB_FILE_STATE", "ACTIVE")
        return SimpleNamespace(name=name, state=SimpleNamespace(name=state))

    def _download(self, file, destination):
        _log(call="download", retries=self.retries, destination=os.path.basename(destination))
        if os.environ.get("STUB_DOWNLOAD_FAIL"):
            open(destination, "wb").write(b"partial")
            raise ConnectionResetError("stub: connection reset mid-download")
        open(destination, "wb").write(b"uri-clip")

    def _get_interaction(self, id, **kw):
        _log(call="get", retries=self.retries, api_version=self.api_version, id=id)
        time.sleep(float(os.environ.get("STUB_GET_DELAY", "0")))
        if os.environ.get("STUB_GET_NOVIDEO"):
            return SimpleNamespace(id=id, status="completed", output_video=None, output_text="", usage=None)
        clip = SimpleNamespace(data=base64.b64encode(b"fetched-clip").decode(), uri=None)
        return SimpleNamespace(id=id, status="completed", output_video=clip, usage=None)

    def _create(self, timeout, **kw):
        inp = kw.pop("input")
        if isinstance(inp, str):
            inp = [{"type": "text", "text": inp}]
        kw["blocks"] = [b["type"] for b in inp]
        kw["text"] = inp[-1]["text"]
        _log(call="create", retries=self.retries, api_version=self.api_version, timeout=timeout, **kw)
        if kw["response_format"].get("delivery") == "uri":
            clip = SimpleNamespace(data=None, uri="https://stub/files/clip:download")
        else:
            clip = SimpleNamespace(data=base64.b64encode(b"inline-clip").decode(), uri=None)
        return SimpleNamespace(id="v1_stub", output_video=clip, usage=None)
PY
printf 'not really an mp4' >"$tmp/in.mp4"

got="$(PYTHONPATH="$stub" python3 -c 'import os, google.genai; print(os.path.realpath(google.genai.__file__))')"
[[ "$got" == "$(cd "$stub" && pwd -P)/google/genai/__init__.py" ]] ||
  fail "google.genai resolves to $got, not the stub; these renders would reach the real SDK"

# render <case> <args...>: run one approved render in its own directory.
render() {
  local dir="$tmp/$1"
  shift
  mkdir -p "$dir"
  (cd "$dir" && env -u GOOGLE_API_KEY GEMINI_API_KEY=stub STUB_LOG="$dir/calls" \
    PYTHONPATH="$stub" python3 "$GEN" "$@" --out clip.mp4 >"$dir/out" 2>&1) ||
    fail "$* exited non-zero: $(cat "$dir/out")"
}

# render_fails <case> <args...>: the same, for a run that must exit non-zero.
render_fails() {
  local dir="$tmp/$1"
  shift
  mkdir -p "$dir"
  ! (cd "$dir" && env -u GOOGLE_API_KEY GEMINI_API_KEY=stub STUB_LOG="$dir/calls" \
    PYTHONPATH="$stub" python3 "$GEN" "$@" --out clip.mp4 >"$dir/out" 2>&1) ||
    fail "$* exited 0, but should have failed: $(cat "$dir/out")"
}

# field <case> <call> <python expression over the entry e>
field() {
  python3 - "$tmp/$1/calls" "$2" "$3" <<'PY'
import json, sys
entries = [json.loads(l) for l in open(sys.argv[1]) if json.loads(l)["call"] == sys.argv[2]]
try:
    print(eval(sys.argv[3], {}, {"e": entries[0]}) if entries else "<no such call>")
except KeyError as err:
    print(f"<no {err} in the {sys.argv[2]} call>")
PY
}

# 1. The billed call goes out with the SDK's retries off: a lost response to a
#    completed render is billed once per attempt.
render small "a cat" --duration 6 --draft --approve 6s@360p
[[ "$(field small create 'e["retries"]')" == 1 ]] ||
  fail "the billed create did not go out with retries off: $(cat "$tmp/small/calls")"
# VIDEO_RATES_USD and the clip limits are one model's, so a change of model
# fails here until they are re-read against it.
[[ "$(field small create 'e["model"]')" == gemini-omni-1.2-flash ]] ||
  fail "the billed create went to a model the rate table was not read for: $(cat "$tmp/small/calls")"

# 2. Below 1080p the clip comes back inline, unless --uri asks otherwise. The
#    store setting is left to the API unless --no-store turns it off.
[[ "$(field small create '"delivery" in e["response_format"]')" == False ]] ||
  fail "a 360p clip asked for URI delivery: $(cat "$tmp/small/calls")"
grep -q 'inline-clip' "$tmp/small/clip.mp4" || fail "the inline clip was not saved"
[[ "$(field small create '"store" in e')" == False ]] ||
  fail "a render without --no-store set store: $(cat "$tmp/small/calls")"
render forced "a cat" --duration 3 --draft --uri --approve 3s@360p
[[ "$(field forced create 'e["response_format"].get("delivery")')" == uri ]] ||
  fail "--uri at 360p did not ask for URI delivery: $(cat "$tmp/forced/calls")"

# 3. At 1080p and 4k the payload outgrows inline delivery, so it must be a URI,
#    collected on the client that keeps its retries -- a download costs nothing.
render big "a cat" --duration 3 --resolution 4k --approve 3s@4k
[[ "$(field big create 'e["response_format"].get("delivery")')" == uri ]] ||
  fail "a 4k clip did not ask for URI delivery: $(cat "$tmp/big/calls")"
[[ "$(field big download 'e["retries"]')" == default ]] ||
  fail "the URI clip was not downloaded on the retrying client: $(cat "$tmp/big/calls")"
grep -q 'uri-clip' "$tmp/big/clip.mp4" || fail "the URI clip was not saved"

# 4. Every setting that was priced reaches the call that bills.
render flags "Extend this" --previous-id v1_abc --output-seconds 24 --aspect 9:16 \
  --duration 5 --task extend --no-store --timeout 77 --approve 24s@720p
got="$(field flags create '[e["previous_interaction_id"], e["response_format"], e["generation_config"], e["store"], e["timeout"]]')"
want="['v1_abc', {'aspect_ratio': '9:16', 'duration': '5s', 'resolution': '720p', 'type': 'video'}, {'video_config': {'task': 'extend'}}, False, 77.0]"
[[ "$got" == "$want" ]] || fail "the billed call did not carry the flags: $got"

# 5. First and last frames go in as images ahead of the text, and the text is
#    the prompt as written: Omni 1.2 deprecates the <FIRST_FRAME>-style control
#    tags the script used to prepend, and says to describe the roles in prose.
printf 'not really a png' >"$tmp/a.png"
printf 'not really a png' >"$tmp/b.png"
render frames "Dawn turns to night" --first-frame "$tmp/a.png" --last-frame "$tmp/b.png" \
  --duration 5 --approve 5s@720p
got="$(field frames create '[e["blocks"], e["text"]]')"
[[ "$got" == "[['image', 'image', 'text'], 'Dawn turns to night']" ]] ||
  fail "the frames did not go in as images ahead of the prompt as written: $got"

# 6. An uploaded --video goes up on the retrying client, and the time logged
#    for the render is the render's, not the upload's.
STUB_UPLOAD_DELAY=2 render upload "Make it anime" --video "$tmp/in.mp4" --task edit \
  --duration 5 --approve 15s@720p
[[ "$(field upload upload 'e["retries"]')" == default ]] ||
  fail "the free upload went out on the billed client: $(cat "$tmp/upload/calls")"
seconds="$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readlines()[-1])["seconds"])' \
  "$tmp/upload/.gemini-motion/runs.jsonl")"
python3 -c "import sys; sys.exit(0 if $seconds < 1.5 else 1)" ||
  fail "the logged render time ($seconds s) includes the 2 s upload"

# 7. storyboard.py renders a plan through the same billed call: one create per
#    pending shot, each with its own duration at the plan's resolution and with
#    retries off; the interaction id lands in the manifest and the run log; and
#    a second render bills nothing. This is the case that sees render_clip's
#    return shape -- the gate test stops before any client exists.
sbdir="$tmp/storyboard"
mkdir -p "$sbdir"
cp "$EXAMPLE" "$sbdir/plan.json"
storyboard() {
  (cd "$sbdir" && env -u GOOGLE_API_KEY GEMINI_API_KEY=stub STUB_LOG="$sbdir/calls" \
    PYTHONPATH="$stub" python3 "$SB" "$@" >"$sbdir/log" 2>&1) ||
    fail "storyboard $* exited non-zero: $(cat "$sbdir/log")"
}
storyboard render plan.json --approve 18s@720p
got="$(
  python3 - "$sbdir/calls" <<'PY'
import json, sys
print([(e["response_format"]["duration"], e["response_format"]["resolution"], e["retries"])
       for e in map(json.loads, open(sys.argv[1])) if e["call"] == "create"])
PY
)"
[[ "$got" == "[('8s', '720p', 1), ('4s', '720p', 1), ('6s', '720p', 1)]" ]] ||
  fail "the storyboard's billed calls did not carry each shot's duration at the plan's resolution with retries off: $got"
for id in desk coffee window; do
  grep -q 'inline-clip' "$sbdir/out/shots/$id.mp4" || fail "clip $id was not saved"
done
ids="$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(sorted({e["interaction_id"] for e in m["shots"].values()}), len(m["shots"]))' \
  "$sbdir/out/manifest.json")"
[[ "$ids" == "['v1_stub'] 3" ]] ||
  fail "the manifest did not record the interaction id of every shot: $(cat "$sbdir/out/manifest.json")"
[[ "$(grep -c '"kind": "storyboard"' "$sbdir/.gemini-motion/runs.jsonl")" == 3 ]] ||
  fail "the run log did not get one storyboard line per shot: $(cat "$sbdir/.gemini-motion/runs.jsonl")"
storyboard render plan.json
grep -q 'nothing to render' "$sbdir/log" || fail "a second render was not a no-op: $(cat "$sbdir/log")"
[[ "$(grep -c '"call": "create"' "$sbdir/calls")" == 3 ]] ||
  fail "a second render billed again: $(cat "$sbdir/calls")"

# 8. A billed clip whose download fails keeps its interaction id, and the
#    clip it would have replaced. The id used to exist only inside the failed
#    process, so the clip that was paid for could not be fetched, and a
#    storyboard billed the shot again; and the download wrote straight to the
#    final path, so a reset mid-file replaced a good clip with a partial one.
mkdir -p "$tmp/dlfail"
printf 'old-clip' >"$tmp/dlfail/clip.mp4"
STUB_DOWNLOAD_FAIL=1 render_fails dlfail "a cat" --uri --duration 3 --draft --approve 3s@360p
[[ "$(cat "$tmp/dlfail/clip.mp4")" == old-clip ]] ||
  fail "a failed download replaced the clip at --out: $(cat "$tmp/dlfail/clip.mp4")"
[[ "$(cd "$tmp/dlfail" && ls -A | sort | tr '\n' ' ')" == ".gemini-motion calls clip.mp4 out " ]] ||
  fail "a failed download left a file behind: $(ls -A "$tmp/dlfail")"
grep -q -- '--fetch v1_stub' "$tmp/dlfail/out" ||
  fail "a failed download did not say how to fetch the clip that was paid for: $(cat "$tmp/dlfail/out")"
grep -q '"interaction_id": "v1_stub"' "$tmp/dlfail/.gemini-motion/runs.jsonl" ||
  fail "a failed download did not log the interaction id: $(cat "$tmp/dlfail/.gemini-motion/runs.jsonl")"

# 9. --fetch collects a clip that was already billed: no create, no approval.
render dlfail --fetch v1_stub
[[ "$(cat "$tmp/dlfail/clip.mp4")" == fetched-clip ]] ||
  fail "--fetch did not save the clip: $(cat "$tmp/dlfail/out")"
[[ "$(grep -c '"call": "create"' "$tmp/dlfail/calls")" == 1 ]] ||
  fail "--fetch billed a render: $(cat "$tmp/dlfail/calls")"
[[ "$(field dlfail get 'e["id"]')" == v1_stub ]] ||
  fail "--fetch did not get the interaction by id: $(cat "$tmp/dlfail/calls")"

# 10. --delivery-timeout bounds the wait for a URI clip. --timeout bounds the
#     billed call only, and the wait after it used to be a fixed 900 s.
start=$SECONDS
STUB_FILE_STATE=PROCESSING render_fails slowuri "a cat" --uri --duration 3 --draft \
  --approve 3s@360p --delivery-timeout 1
((SECONDS - start < 5)) || fail "--delivery-timeout 1 waited $((SECONDS - start)) s"
grep -q 'delivery' "$tmp/slowuri/out" && grep -q -- '--fetch v1_stub' "$tmp/slowuri/out" ||
  fail "a delivery timeout did not say so and how to fetch the clip: $(cat "$tmp/slowuri/out")"

# 11. A storyboard shot whose delivery failed is fetched on the next render,
#     not billed again: its id is in the manifest before the download starts.
sb2="$tmp/storyboard-fail"
mkdir -p "$sb2"
python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); p["resolution"]="1080p"; json.dump(p, open(sys.argv[2],"w"))' \
  "$EXAMPLE" "$sb2/plan.json"
! (cd "$sb2" && env -u GOOGLE_API_KEY GEMINI_API_KEY=stub STUB_LOG="$sb2/calls" STUB_DOWNLOAD_FAIL=1 \
  PYTHONPATH="$stub" python3 "$SB" render plan.json --approve 18s@1080p >"$sb2/log" 2>&1) ||
  fail "a storyboard render whose download failed exited 0: $(cat "$sb2/log")"
[[ ! -e "$sb2/out/shots/desk.mp4" ]] || fail "a failed download left a clip at its final path"
(cd "$sb2" && env -u GEMINI_API_KEY -u GOOGLE_API_KEY python3 "$SB" check plan.json >"$sb2/check" 2>&1) ||
  fail "check after a failed download exited non-zero: $(cat "$sb2/check")"
grep -q 'approve 10s@1080p' "$sb2/check" ||
  fail "check priced the shot that was already billed: $(cat "$sb2/check")"
(cd "$sb2" && env -u GOOGLE_API_KEY GEMINI_API_KEY=stub STUB_LOG="$sb2/calls" \
  PYTHONPATH="$stub" python3 "$SB" render plan.json --approve 10s@1080p >"$sb2/log" 2>&1) ||
  fail "the resumed storyboard render exited non-zero: $(cat "$sb2/log")"
[[ "$(cat "$sb2/out/shots/desk.mp4")" == fetched-clip ]] ||
  fail "the billed shot was not fetched: $(cat "$sb2/log")"
[[ "$(grep -c '"call": "create"' "$sb2/calls")" == 3 ]] ||
  fail "the shot whose download failed was billed again: $(cat "$sb2/calls")"
# With nothing to bill, render needs no approval: a fetch costs nothing.
rm "$sb2/out/shots/desk.mp4"
(cd "$sb2" && env -u GOOGLE_API_KEY GEMINI_API_KEY=stub STUB_LOG="$sb2/calls" \
  PYTHONPATH="$stub" python3 "$SB" render plan.json >"$sb2/log" 2>&1) ||
  fail "render of an already-billed shot asked for approval: $(cat "$sb2/log")"
[[ "$(cat "$sb2/out/shots/desk.mp4")" == fetched-clip ]] && [[ "$(grep -c '"call": "create"' "$sb2/calls")" == 3 ]] ||
  fail "a missing clip with an id on record was not fetched free: $(cat "$sb2/log")"
grep -q '"kind": "storyboard-billed"' "$sb2/.gemini-motion/runs.jsonl" ||
  fail "the run log has no line for the shot billed but not saved: $(cat "$sb2/.gemini-motion/runs.jsonl")"

# 12. A re-render whose download fails does not leave the old clip passing as
#     the new one. The manifest takes the new spec and id before the download,
#     so an old clip still at the path read as current, and stitched.
(cd "$sb2" && python3 -c 'import json; p=json.load(open("plan.json")); p["shots"][1]["prompt"]+=" Slower."; json.dump(p, open("plan.json","w"))')
! (cd "$sb2" && env -u GOOGLE_API_KEY GEMINI_API_KEY=stub STUB_LOG="$sb2/calls" STUB_DOWNLOAD_FAIL=1 \
  PYTHONPATH="$stub" python3 "$SB" render plan.json --approve 4s@1080p >"$sb2/log" 2>&1) ||
  fail "a re-render whose download failed exited 0: $(cat "$sb2/log")"
(cd "$sb2" && env -u GEMINI_API_KEY -u GOOGLE_API_KEY python3 "$SB" check plan.json >"$sb2/check" 2>&1)
grep -q 'coffee.*billed, not saved' "$sb2/check" ||
  fail "the old clip of a re-rendered shot passed as current: $(cat "$sb2/check")"
(cd "$sb2" && env -u GOOGLE_API_KEY GEMINI_API_KEY=stub STUB_LOG="$sb2/calls" \
  PYTHONPATH="$stub" python3 "$SB" render plan.json >"$sb2/log" 2>&1) ||
  fail "the billed re-render was not fetched: $(cat "$sb2/log")"
[[ "$(cat "$sb2/out/shots/coffee.mp4")" == fetched-clip ]] && [[ "$(grep -c '"call": "create"' "$sb2/calls")" == 4 ]] ||
  fail "the billed re-render was billed again or not saved: $(cat "$sb2/calls")"

# 13. A stored interaction that comes back without a video is a failed fetch,
#     with the way out, not a safety-filter refusal telling the user to rephrase
#     a shot that was already paid for.
STUB_GET_NOVIDEO=1 render_fails novideo --fetch v1_gone
grep -q 'billed as v1_gone, but not saved' "$tmp/novideo/out" && ! grep -q rephrase "$tmp/novideo/out" ||
  fail "a fetch with no video was not reported as one: $(cat "$tmp/novideo/out")"
rm "$sb2/out/shots/coffee.mp4"
! (cd "$sb2" && env -u GOOGLE_API_KEY GEMINI_API_KEY=stub STUB_LOG="$sb2/calls" STUB_GET_NOVIDEO=1 \
  PYTHONPATH="$stub" python3 "$SB" render plan.json >"$sb2/log" 2>&1) ||
  fail "a storyboard fetch with no video exited 0: $(cat "$sb2/log")"
grep -q 'delete "coffee" from out/manifest.json' "$sb2/log" ||
  fail "a storyboard fetch with no video did not say how to give the shot up: $(cat "$sb2/log")"

# 14. --delivery-timeout bounds reading the interaction back, not only the download.
start=$SECONDS
STUB_GET_DELAY=4 render_fails slowget --fetch v1_stub --delivery-timeout 1
((SECONDS - start < 4)) || fail "--delivery-timeout 1 let a fetch wait $((SECONDS - start)) s"

# 15. The render and the fetch go out on v1beta. google-genai defaults to v1,
#     which serves no Omni model: a live create there is a 404.
[[ "$(field small create 'e["api_version"]')" == v1beta ]] ||
  fail "the billed create did not go out on v1beta: $(cat "$tmp/small/calls")"
[[ "$(field dlfail get 'e["api_version"]')" == v1beta ]] ||
  fail "--fetch did not read the interaction on v1beta: $(cat "$tmp/dlfail/calls")"

echo "gemini-motion render tests: passed"
