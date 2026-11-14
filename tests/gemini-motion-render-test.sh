#!/usr/bin/env bash
set -euo pipefail

# The billed call behind the gemini-motion spend gate. The gate test stops
# every case before a client exists, so it cannot see how the call that bills
# is made. This one runs the real scripts against a stub google.genai that
# records each call and never opens a socket: the stub package shadows any
# installed SDK on PYTHONPATH, and the key it is handed is not a key.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
GEN="$SRC/skills/gemini-motion/scripts/generate_video.py"

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
    def __init__(self, retry_options=None):
        self.retry_options = retry_options
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
        self.retries = http_options.retry_options.attempts if http_options else "default"
        self.files = SimpleNamespace(upload=self._upload, get=self._get, download=self._download)
        self.interactions = SimpleNamespace(create=self._create)

    def _upload(self, file):
        _log(call="upload", retries=self.retries)
        time.sleep(float(os.environ.get("STUB_UPLOAD_DELAY", "0")))
        return SimpleNamespace(name="files/up", uri="https://stub/files/up", state="ACTIVE")

    def _get(self, name):
        return SimpleNamespace(name=name, state=SimpleNamespace(name="ACTIVE"))

    def _download(self, file, destination):
        _log(call="download", retries=self.retries)
        open(destination, "wb").write(b"uri-clip")

    def _create(self, timeout, **kw):
        kw.pop("input")
        _log(call="create", retries=self.retries, timeout=timeout, **kw)
        if kw["response_format"].get("delivery") == "uri":
            clip = SimpleNamespace(data=None, uri="https://stub/files/clip:download")
        else:
            clip = SimpleNamespace(data=base64.b64encode(b"inline-clip").decode(), uri=None)
        return SimpleNamespace(id="v1_stub", output_video=clip, usage=None)
PY
printf 'not really an mp4' >"$tmp/in.mp4"

# render <case> <args...>: run one approved render in its own directory.
render() {
  local dir="$tmp/$1"
  shift
  mkdir -p "$dir"
  (cd "$dir" && env -u GOOGLE_API_KEY GEMINI_API_KEY=stub STUB_LOG="$dir/calls" \
    PYTHONPATH="$stub" python3 "$GEN" "$@" --out clip.mp4 >"$dir/out" 2>&1) ||
    fail "$* exited non-zero: $(cat "$dir/out")"
}

# field <case> <call> <python expression over the entry e>
field() {
  python3 - "$tmp/$1/calls" "$2" "$3" <<'PY'
import json, sys
entries = [json.loads(l) for l in open(sys.argv[1]) if json.loads(l)["call"] == sys.argv[2]]
print(eval(sys.argv[3], {}, {"e": entries[0]}) if entries else "<no such call>")
PY
}

# 1. The billed call goes out with the SDK's retries off: a lost response to a
#    completed render is billed once per attempt.
render small "a cat" --duration 6 --draft --approve 6s@360p
[[ "$(field small create 'e["retries"]')" == 1 ]] ||
  fail "the billed create did not go out with retries off: $(cat "$tmp/small/calls")"

# 2. Below 1080p the clip comes back inline.
[[ "$(field small create '"delivery" in e["response_format"]')" == False ]] ||
  fail "a 360p clip asked for URI delivery: $(cat "$tmp/small/calls")"
grep -q 'inline-clip' "$tmp/small/clip.mp4" || fail "the inline clip was not saved"

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

# 5. An uploaded --video goes up on the retrying client, and the time logged
#    for the render is the render's, not the upload's.
STUB_UPLOAD_DELAY=2 render upload "Make it anime" --video "$tmp/in.mp4" --duration 5 --approve 5s@720p
[[ "$(field upload upload 'e["retries"]')" == default ]] ||
  fail "the free upload went out on the billed client: $(cat "$tmp/upload/calls")"
seconds="$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readlines()[-1])["seconds"])' \
  "$tmp/upload/.gemini-motion/runs.jsonl")"
python3 -c "import sys; sys.exit(0 if $seconds < 1.5 else 1)" ||
  fail "the logged render time ($seconds s) includes the 2 s upload"

echo "gemini-motion render tests: passed"
