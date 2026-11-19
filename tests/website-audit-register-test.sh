#!/usr/bin/env bash
set -euo pipefail

# The findings register of website-audit-package (#69): built from the evidence
# layer by running metadata-audit's inventory.py on the saved inputs, so every
# finding cites the files the tool read, and refused when a pointer does not
# resolve. Nothing here touches the network: the package is a fixture under
# mktemp, and the one measuring tool is a stdlib script.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
REG="$SRC/skills/website-audit-package/scripts/register.py"
INV="$SRC/skills/metadata-audit/scripts/inventory.py"

fail() {
  echo "website-audit-register test failed: $*" >&2
  exit 1
}

command -v python3 >/dev/null || {
  echo "website-audit-register tests: skipped (no python3)"
  exit 0
}
command -v jq >/dev/null || {
  echo "website-audit-register tests: skipped (no jq)"
  exit 0
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/llmctx-register-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
pkg="$tmp/2026-11-19-example.test"
ev="$pkg/evidence/metadata-audit"
mkdir -p "$ev/home" "$ev/about" "$ev/empty-dir"

# home: a page with something closed at every gate the inventory can see. The
# headers say noindex, robots.txt blocks everything, the sitemap omits the URL,
# the head has no title, description, canonical or lang, two images have no alt,
# there is no h1 and no structured data.
cat >"$ev/home/page.html" <<'HTML'
<!doctype html><html><head><meta charset="utf-8"><meta property="og:title" content="Home"></head>
<body><h2>Welcome</h2><img src="a.png"><img src="b.png"><p>short text</p></body></html>
HTML
printf 'https://example.test/\n' >"$ev/home/url"
printf 'HTTP/2 200\r\ncontent-type: text/html\r\nx-robots-tag: noindex\r\n\r\n' >"$ev/home/headers.txt"
printf 'User-agent: *\nDisallow: /\n' >"$ev/home/robots.txt"
printf '<?xml version="1.0"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>https://example.test/about</loc></url></urlset>\n' >"$ev/home/sitemap.xml"

# about: a clean page, with no headers, robots or sitemap saved, so the checks
# that need them are recorded as not run rather than passed.
python3 - "$ev/about/page.html" <<'PY'
import sys
words = " ".join(f"word{i}" for i in range(230))
html = f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><title>About the example</title>
<meta name="description" content="A short description of the example page for the register test.">
<link rel="canonical" href="https://example.test/about">
<meta property="og:title" content="About"><meta property="og:description" content="About the example">
<meta property="og:image" content="https://example.test/og.png">
<script type="application/ld+json">{{"@context":"https://schema.org","@type":"WebPage","@id":"https://example.test/about#page","name":"About"}}</script>
</head><body><header><nav><a href="/">Home</a></nav></header><main><h1>About</h1><p>{words}</p>
<img src="x.png" alt="An example"></main><footer>f</footer></body></html>"""
open(sys.argv[1], "w", encoding="utf-8").write(html)
PY
printf 'https://example.test/about\n' >"$ev/about/url"

build() { python3 "$REG" build "$pkg" "$@"; }
check() { python3 "$REG" check "$pkg"; }
reg="$pkg/register.json"
md="$pkg/register.md"
q() { jq -r "$1" "$reg"; }

# 1. build writes both artifacts and exits 0.
build >"$tmp/build.out" 2>&1 || fail "build failed: $(cat "$tmp/build.out")"
[[ -f "$reg" && -f "$md" ]] || fail "build did not write register.json and register.md"

# 2. Sample size counts the pages measured, and the directory with nothing to
#    measure is named as not measured rather than silently skipped.
[[ "$(q '.limits.sampleSize')" == 2 ]] || fail "sampleSize was not 2: $(q '.limits')"
[[ "$(q '.limits.pagesNotMeasured | join(",")')" == "empty-dir" ]] ||
  fail "the empty page directory was not named as not measured: $(q '.limits.pagesNotMeasured')"

# 3. The closed gates on home are findings, each with the severity the
#    metadata-audit decision tree gives that case.
sev() { q ".findings[] | select(.id == \"$1\") | .severity"; }
[[ "$(sev metadata/home/header_noindex)" == P0 ]] || fail "header noindex was not P0: $(sev metadata/home/header_noindex)"
[[ "$(sev metadata/home/robots_blocks_everything)" == P0 ]] || fail "robots blocking everything was not P0"
[[ "$(sev metadata/home/images_missing_alt)" == P2 ]] || fail "images without alt was not P2"
[[ "$(sev metadata/home/url_absent_from_sitemap)" == P2 ]] || fail "URL absent from sitemap was not P2"
[[ "$(sev metadata/home/description_missing)" == P2 ]] || fail "missing description was not P2"
[[ "$(sev metadata/home/h1_missing)" == P2 ]] || fail "missing h1 was not P2"

# 4. The measured sentence carries the number, not a paraphrase.
grep -q '2 of 2 images' <<<"$(q '.findings[] | select(.id == "metadata/home/images_missing_alt") | .measured')" ||
  fail "the alt finding did not quote 2 of 2 images"

# 5. The clean page yields no finding and still counts in the sample.
[[ "$(q '[.findings[] | select(.page == "about")] | length')" == 0 ]] ||
  fail "the clean page produced findings: $(q '[.findings[] | select(.page == "about") | .id]')"
[[ "$(q '[.pages[] | select(.slug == "about")] | length')" == 1 ]] || fail "the clean page is not in pages"

# 6. Every finding cites evidence that exists, carries a falsifier, a state and
#    a truthful measuredBy; no field is left for a reader to invent.
n="$(q '.findings | length')"
[[ "$n" -ge 8 ]] || fail "expected at least 8 findings on home, got $n"
[[ "$(q '[.findings[] | select((.evidence | length) == 0)] | length')" == 0 ]] || fail "a finding has no evidence"
while IFS= read -r p; do
  [[ -f "$pkg/$p" ]] || fail "evidence pointer does not resolve: $p"
done < <(q '.findings[].evidence[]' | sort -u)
[[ "$(q '[.findings[] | select(.howWeWouldKnowWeAreWrong == null or .howWeWouldKnowWeAreWrong == "")] | length')" == 0 ]] ||
  fail "a finding has no falsifier"
[[ "$(q '[.findings[] | select(.whyItMatters == null or .whyItMatters == "")] | length')" == 0 ]] ||
  fail "a finding has no whyItMatters"
[[ "$(q '[.findings[] | .state] | unique | join(",")')" == "Live" ]] || fail "state is not Live on every finding"
[[ "$(q '[.findings[] | select(.asOf == null)] | length')" == 0 ]] || fail "a finding has no asOf"
[[ "$(q '[.findings[] | select(.gate == null)] | length')" == 0 ]] || fail "a finding has no gate"
want_sha="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$INV")"
[[ "$(q '.measuredBy.sha256')" == "$want_sha" ]] || fail "measuredBy.sha256 is not the hash of inventory.py"
grep -q 'inventory.py' <<<"$(q '.measuredBy.tool')" || fail "measuredBy.tool does not name inventory.py: $(q '.measuredBy.tool')"
[[ "$(q '[.findings[] | select(.measuredBy.ranAt == null)] | length')" == 0 ]] || fail "a finding has no ranAt"
[[ "$(q '[.findings[] | select(.measuredBy.check == null)] | length')" == 0 ]] || fail "a finding does not name its check"

# 7. Inputs that were not saved are recorded, so the limits say what was not
#    measured instead of implying a pass.
grep -q 'headers.txt' <<<"$(q '.pages[] | select(.slug == "about") | .inputsAbsent | join(",")')" ||
  fail "about's absent headers.txt was not recorded"
grep -q 'header_noindex' <<<"$(q '.limits.checksNotRun | tostring')" ||
  fail "limits.checksNotRun does not name the header checks skipped on about"

# 8. The one page renders the sample size, the not-measured directory and every
#    finding by id.
grep -q 'Sample size' "$md" || fail "register.md has no sample size line"
grep -q '2 pages' "$md" || fail "register.md does not state 2 pages"
grep -q 'empty-dir' "$md" || fail "register.md does not name the unmeasured directory"
while IFS= read -r id; do
  grep -qF "$id" "$md" || fail "register.md is missing finding $id"
done < <(q '.findings[].id')
grep -qi 'how we would know we are wrong\|wrong if' "$md" || fail "register.md carries no falsifiers"

# 9. check passes on what build wrote, and a rebuild is stable except for
#    its timestamps, so ids survive to be re-labelled later.
check >"$tmp/check.out" 2>&1 || fail "check failed on a fresh build: $(cat "$tmp/check.out")"
norm() { jq -S 'del(.generatedAt) | del(.findings[].measuredBy.ranAt) | del(.pages[].ranAt)' "$1"; }
norm "$reg" >"$tmp/first.json"
build >/dev/null 2>&1 || fail "second build failed"
norm "$reg" >"$tmp/second.json"
cmp -s "$tmp/first.json" "$tmp/second.json" || fail "two builds of the same evidence differ: $(diff "$tmp/first.json" "$tmp/second.json" | head -5)"

# 10. A pointer that stops resolving is refused by name: delete the robots.txt
#     that backs a finding, and check names the finding and the file.
mv "$ev/home/robots.txt" "$tmp/robots.bak"
if out="$(check 2>&1)"; then fail "check passed with a dangling evidence pointer"; fi
grep -q 'metadata/home/robots_blocks_everything' <<<"$out" || fail "check did not name the finding whose pointer dangles: $out"
grep -q 'robots.txt' <<<"$out" || fail "check did not name the missing file: $out"
mv "$tmp/robots.bak" "$ev/home/robots.txt"
check >/dev/null 2>&1 || fail "check did not pass again once the file was restored"

# 11. A finding written by hand with no evidence cannot pass, and neither can
#     one whose pointer reaches outside the package.
cp "$reg" "$tmp/reg.bak"
jq '.findings += [{"id":"metadata/home/invented","page":"home","gate":4,"severity":"P1","state":"Live","asOf":"2026-01-01T00:00:00Z","measured":"a claim","evidence":[],"whyItMatters":"x","howWeWouldKnowWeAreWrong":"y","measuredBy":{"tool":"hand","check":"none","ranAt":"2026-01-01T00:00:00Z"}}]' "$tmp/reg.bak" >"$reg"
if out="$(check 2>&1)"; then fail "check passed a finding with no evidence"; fi
grep -q 'metadata/home/invented' <<<"$out" || fail "check did not name the unbacked finding: $out"
jq '.findings[0].evidence = ["../outside.txt"]' "$tmp/reg.bak" >"$reg"
printf 'x\n' >"$tmp/outside.txt"
if check >/dev/null 2>&1; then fail "check passed a pointer that escapes the package"; fi
jq '.findings[0].measured = ""' "$tmp/reg.bak" >"$reg"
if check >/dev/null 2>&1; then fail "check passed a finding with an empty measured sentence"; fi
cp "$tmp/reg.bak" "$reg"
check >/dev/null 2>&1 || fail "check did not pass the restored register"

# 12. A check the severity table does not know is refused, not emitted
#     unlabelled, and a refused build leaves no register behind.
cat >"$tmp/fake-inventory.py" <<'PY'
import json
print(json.dumps({"url": None, "checks": {"made_up_check": True}, "content": {}, "head": {}, "structured_data": {}}))
PY
rm -f "$reg" "$md"
if out="$(build --inventory "$tmp/fake-inventory.py" 2>&1)"; then fail "build emitted a finding for an unknown check"; fi
grep -q 'made_up_check' <<<"$out" || fail "build did not name the unknown check: $out"
[[ ! -e "$reg" && ! -e "$md" ]] || fail "a refused build left a register behind"

# 13. A missing tool is a plain error naming the path, not an empty register.
if out="$(build --inventory "$tmp/does-not-exist.py" 2>&1)"; then fail "build succeeded without its measuring tool"; fi
grep -q 'does-not-exist.py' <<<"$out" || fail "build did not name the missing tool: $out"
[[ ! -e "$reg" ]] || fail "build without a tool wrote a register"

# 14. No evidence at all is not a register of zero findings about nothing.
mkdir -p "$tmp/bare/evidence"
if out="$(python3 "$REG" build "$tmp/bare" 2>&1)"; then fail "build succeeded on a package with no metadata evidence"; fi
grep -q 'evidence/metadata-audit' <<<"$out" || fail "build did not say where it looked: $out"

echo "website-audit-register tests: passed"
