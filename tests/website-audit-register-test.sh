#!/usr/bin/env bash
set -euo pipefail

# The findings register of website-audit-package (#69): built from the evidence
# layer by running audit-metadata's inventory.py on the saved inputs, so every
# finding cites the files the tool read, and refused when a pointer does not
# resolve. Nothing here touches the network: the package is a fixture under
# mktemp, and the one measuring tool is a stdlib script.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
REG="$SRC/skills/website-audit-package/scripts/register.py"
INV="$SRC/skills/audit-metadata/scripts/inventory.py"

fail() {
  echo "website-audit-register test failed: $*" >&2
  exit 1
}

command -v python3 >/dev/null || {
  echo "website-audit-register tests: skipped (no python3)"
  exit 0
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/llmctx-register-test.XXXXXX")"
trap 'chmod -R u+rwX "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
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
printf 'HTTP/1.1 301\r\ndate: Wed, 19 Nov 2026 04:00:00 GMT\r\nlocation: https://example.test/\r\n\r\nHTTP/2 200\r\ndate: Wed, 19 Nov 2026 05:00:00 GMT\r\ncontent-type: text/html\r\nx-robots-tag: noindex\r\n\r\n' >"$ev/home/headers.txt"
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
printf '2026-11-18T12:00:00Z\n' >"$ev/about/captured"

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
#    audit-metadata decision tree gives that case.
sev() { q ".findings[] | select(.id == \"$1\") | .severity"; }
[[ "$(sev metadata/home/header_noindex)" == P0 ]] || fail "header noindex was not P0: $(sev metadata/home/header_noindex)"
[[ "$(sev metadata/home/robots_blocks_everything)" == P0 ]] || fail "robots blocking everything was not P0"
[[ "$(sev metadata/home/images_missing_alt)" == P2 ]] || fail "images without alt was not P2"
[[ "$(sev metadata/home/url_absent_from_sitemap)" == P2 ]] || fail "URL absent from sitemap was not P2"
[[ "$(sev metadata/home/description_missing)" == P2 ]] || fail "missing description was not P2"
[[ "$(sev metadata/home/h1_missing)" == P2 ]] || fail "missing h1 was not P2"
[[ "$(q '[.findings[] | select(.id == "metadata/home/robots_blocks_this_path")] | length')" == 0 ]] ||
  fail "robots_blocks_this_path fired beside robots_blocks_everything on the same page"
[[ "$(q '[.findings[] | select(.id == "metadata/home/redirect_chain")] | length')" == 0 ]] ||
  fail "a single redirect hop was reported as a chain"

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
[[ "$(q '.limits.checksNotRun.about.header_noindex')" == "headers.txt was not saved" ]] ||
  fail "a skipped header check does not carry its reason: $(q '.limits.checksNotRun.about.header_noindex')"
grep -q '`header_noindex`.*because headers.txt was not saved' "$md" || fail "register.md does not say why the header checks were skipped"

# 8. The one page renders the sample size, the not-measured directory and every
#    finding by id.
grep -q 'Sample size' "$md" || fail "register.md has no sample size line"
grep -q '2 pages' "$md" || fail "register.md does not state 2 pages"
grep -q 'empty-dir' "$md" || fail "register.md does not name the unmeasured directory"
while IFS= read -r id; do
  grep -qF "$id" "$md" || fail "register.md is missing finding $id"
done < <(q '.findings[].id')
grep -qi 'how we would know we are wrong\|wrong if' "$md" || fail "register.md carries no falsifiers"
grep -q 'from the headers.txt Date header' "$md" || fail "register.md does not say where a date came from"

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

# 14. No evidence at all is not a register of zero findings about nothing, and an
#     unusable package is exit 2, distinct from a refused register's 1.
mkdir -p "$tmp/bare/evidence"
rc=0
out="$(python3 "$REG" build "$tmp/bare" 2>&1)" || rc=$?
[[ "$rc" == 2 ]] || fail "a package with no metadata evidence exited $rc, not 2: $out"
grep -q 'evidence/metadata-audit' <<<"$out" || fail "build did not say where it looked: $out"
mkdir -p "$tmp/hollow/evidence/metadata-audit/p1"
rc=0
out="$(python3 "$REG" build "$tmp/hollow" 2>&1)" || rc=$?
[[ "$rc" == 2 ]] || fail "a package with no page.html anywhere exited $rc, not 2: $out"
grep -q 'p1' <<<"$out" || fail "build did not name the directory it saw: $out"
rc=0
out="$(build --inventory "$tmp/does-not-exist.py" 2>&1)" || rc=$?
[[ "$rc" == 2 ]] || fail "a missing tool exited $rc, not 2"
rc=0
out="$(build --inventory "$tmp/fake-inventory.py" 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "an unknown check exited $rc, not 1"

# 15. A check that needs the page URL is recorded as not run when no url file was
#     saved, never as a pass: the inventory reports both as False without a URL.
mkdir -p "$ev/nourl"
cp "$ev/home/page.html" "$ev/nourl/page.html"
cp "$ev/home/robots.txt" "$ev/nourl/robots.txt"
cp "$ev/home/sitemap.xml" "$ev/nourl/sitemap.xml"
build >/dev/null 2>&1 || fail "build with the nourl page failed"
nr="$(q '.limits.checksNotRun.nourl | keys | join(",")')"
grep -q 'url_absent_from_sitemap' <<<"$nr" || fail "url_absent_from_sitemap was not recorded as not run without a url: $nr"
grep -q 'robots_blocks_this_path' <<<"$nr" || fail "robots_blocks_this_path was not recorded as not run without a url: $nr"
grep -q 'url_absent_from_sitemap\|robots_blocks_this_path' <<<"$(q '.pages[] | select(.slug == "nourl") | .checksRun | join(",")')" &&
  fail "a url-dependent check was listed as run on a page with no url"
[[ "$(q '[.findings[] | select(.page == "nourl" and (.measuredBy.check == "url_absent_from_sitemap" or .measuredBy.check == "robots_blocks_this_path"))] | length')" == 0 ]] ||
  fail "a url-dependent finding was emitted without a url"
[[ "$(sev metadata/nourl/robots_blocks_everything)" == P0 ]] || fail "robots blocking everything still fires without a url"
rm -rf "$ev/nourl"

# 16. asOf is the capture time, not whatever last touched the file: the captured
#     file first, then the Date header, then the mtime, and each says which.
build >/dev/null 2>&1 || fail "rebuild after nourl failed"
[[ "$(q '.pages[] | select(.slug == "about") | .asOf')" == "2026-11-18T12:00:00Z" ]] ||
  fail "about's asOf did not come from its captured file: $(q '.pages[] | select(.slug == "about") | .asOf')"
grep -q 'captured' <<<"$(q '.pages[] | select(.slug == "about") | .asOfSource')" || fail "about's asOfSource does not name the captured file"
[[ "$(q '.findings[] | select(.id == "metadata/home/title_missing") | .asOf')" == "2026-11-19T05:00:00Z" ]] ||
  fail "home's asOf did not come from the Date header: $(q '.findings[] | select(.id == "metadata/home/title_missing") | .asOf')"
grep -q 'headers.txt' <<<"$(q '.findings[] | select(.id == "metadata/home/title_missing") | .evidence | join(",")')" ||
  fail "a finding dated from headers.txt does not cite headers.txt"
mkdir -p "$ev/mtime" && cp "$ev/home/page.html" "$ev/mtime/page.html"
build >/dev/null 2>&1 || fail "build with the mtime page failed"
grep -q 'mtime' <<<"$(q '.pages[] | select(.slug == "mtime") | .asOfSource')" || fail "a page with no capture record did not say its asOf is an mtime"
rm -rf "$ev/mtime"
printf 'yesterday\n' >"$ev/about/captured"
rc=0
out="$(build 2>&1)" || rc=$?
[[ "$rc" == 2 ]] || fail "a malformed captured file exited $rc, not 2: $out"
grep -q 'captured' <<<"$out" || fail "the malformed captured file was not named: $out"
printf '2026-11-18T12:00:00Z\n' >"$ev/about/captured"

# 17. check verifies provenance against the table, not just that the fields are
#     filled: a severity, gate or id that is not what the check's row gives is refused.
build >/dev/null 2>&1 || fail "rebuild before the provenance cases failed"
cp "$reg" "$tmp/reg.bak"
jq '(.findings[] | select(.id == "metadata/home/images_missing_alt") | .severity) = "P0"' "$tmp/reg.bak" >"$reg"
if out="$(check 2>&1)"; then fail "check passed a severity the table does not give"; fi
grep -q 'metadata/home/images_missing_alt' <<<"$out" || fail "the inflated finding was not named: $out"
jq '(.findings[] | select(.id == "metadata/home/images_missing_alt") | .measuredBy.check) = "none"' "$tmp/reg.bak" >"$reg"
if check >/dev/null 2>&1; then fail "check passed a measuredBy.check the table does not know"; fi
jq '(.findings[] | select(.id == "metadata/home/images_missing_alt") | .id) = "metadata/home/renamed"' "$tmp/reg.bak" >"$reg"
if check >/dev/null 2>&1; then fail "check passed an id that does not name its check"; fi
jq '.limits.pagesMeasured = ["home"]' "$tmp/reg.bak" >"$reg"
if check >/dev/null 2>&1; then fail "check passed limits.pagesMeasured that disagrees with pages"; fi
jq '.pages[0].evidence = ["evidence/metadata-audit/home/gone.html"]' "$tmp/reg.bak" >"$reg"
if check >/dev/null 2>&1; then fail "check passed a page evidence pointer that does not resolve"; fi
cp "$tmp/reg.bak" "$reg"
check >/dev/null 2>&1 || fail "check did not pass the restored register after the provenance cases"

# 18. A measuring tool that fails is reported plainly, exit 2, with no traceback
#     and no register left behind.
cat >"$tmp/failing-inventory.py" <<'PY2'
import sys
sys.stderr.write("inventory: cannot parse the header dump\n")
sys.exit(3)
PY2
rm -f "$reg" "$md"
rc=0
out="$(build --inventory "$tmp/failing-inventory.py" 2>&1)" || rc=$?
[[ "$rc" == 2 ]] || fail "a failing tool exited $rc, not 2: $out"
grep -q 'Traceback' <<<"$out" && fail "a failing tool produced a traceback: $out"
grep -q 'failing-inventory.py' <<<"$out" || fail "the failing tool was not named: $out"
grep -q 'cannot parse the header dump' <<<"$out" || fail "the tool's own error was not relayed: $out"
[[ ! -e "$reg" && ! -e "$md" ]] || fail "a failed tool run left a register behind"

# 19. Near-zero text in a large HTML shell is one finding, not two: the thin-text
#     check is a superset of the JS-rendered one and is suppressed when it fires.
mkdir -p "$ev/shell"
python3 - "$ev/shell/page.html" <<'PY3'
import sys
html = "<!doctype html><html lang=\"en\"><head><title>Shell</title></head><body><main><h1>Hi</h1>" + "<div class=\"c\"></div>" * 1200 + "</main></body></html>"
open(sys.argv[1], "w", encoding="utf-8").write(html)
PY3
build >/dev/null 2>&1 || fail "build with the shell page failed"
[[ "$(sev metadata/shell/likely_js_rendered)" == P1 ]] || fail "the JS shell page did not fire likely_js_rendered"
[[ "$(q '[.findings[] | select(.id == "metadata/shell/thin_raw_text")] | length')" == 0 ]] ||
  fail "thin_raw_text fired beside likely_js_rendered for the same fact"
rm -rf "$ev/shell"
build >/dev/null 2>&1 || fail "rebuild after the shell page failed"
check >/dev/null 2>&1 || fail "check after the shell page failed"

# 20. A url file that is blank is an absent input: the inventory ran without a
#     URL, so the url-dependent checks are not run, not passed.
mkdir -p "$ev/blankurl"
cp "$ev/home/page.html" "$ev/home/robots.txt" "$ev/home/sitemap.xml" "$ev/blankurl/"
printf '\n' >"$ev/blankurl/url"
build >/dev/null 2>&1 || fail "build with the blank url page failed"
grep -q 'url' <<<"$(q '.pages[] | select(.slug == "blankurl") | .inputsAbsent | join(",")')" ||
  fail "a blank url file was not recorded as an absent input"
nr="$(q '.limits.checksNotRun.blankurl | keys | join(",")')"
grep -q 'url_absent_from_sitemap' <<<"$nr" || fail "url_absent_from_sitemap ran against a blank url: $nr"
grep -q 'robots_blocks_this_path' <<<"$nr" || fail "robots_blocks_this_path ran against a blank url: $nr"
grep -q 'url_absent_from_sitemap\|robots_blocks_this_path' <<<"$(q '.pages[] | select(.slug == "blankurl") | .checksRun | join(",")')" &&
  fail "a url-dependent check was listed as run against a blank url"
rm -rf "$ev/blankurl"

# 21. A refused or failed build removes the register an earlier build left, so a
#     stale register never stands beside evidence it no longer describes.
build >/dev/null 2>&1 || fail "rebuild before the stale-register cases failed"
[[ -f "$reg" && -f "$md" ]] || fail "no register to go stale"
rc=0
out="$(build --inventory "$tmp/fake-inventory.py" 2>&1)" || rc=$?
[[ "$rc" == 1 ]] || fail "the refused rebuild exited $rc, not 1"
[[ ! -e "$reg" && ! -e "$md" ]] || fail "a refused rebuild left the earlier register standing"
grep -q 'removed register.json and register.md' <<<"$out" || fail "the refused rebuild did not say it removed the earlier register: $out"
build >/dev/null 2>&1 || fail "rebuild after the refused one failed"
rc=0
out="$(build --inventory "$tmp/failing-inventory.py" 2>&1)" || rc=$?
[[ "$rc" == 2 && ! -e "$reg" && ! -e "$md" ]] || fail "a failed tool run left the earlier register standing (exit $rc)"
mkdir -p "$tmp/noev" && printf '{}' >"$tmp/noev/register.json"
rc=0
python3 "$REG" build "$tmp/noev" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 2 && -f "$tmp/noev/register.json" ]] || fail "a build that found no evidence directory touched the register there"

# 22. Evidence that changed since it was measured is refused by hash: check does
#     not re-measure, build does.
build >/dev/null 2>&1 || fail "rebuild before the hash case failed"
cp "$ev/about/page.html" "$tmp/about.bak"
printf '<!-- edited after measurement -->\n' >>"$ev/about/page.html"
if out="$(check 2>&1)"; then fail "check passed evidence that changed since it was measured"; fi
grep -q 'changed since it was measured' <<<"$out" || fail "check did not say the evidence changed: $out"
grep -q 'about/page.html' <<<"$out" || fail "check did not name the changed file: $out"
cp "$tmp/about.bak" "$ev/about/page.html"
check >/dev/null 2>&1 || fail "check did not pass once the evidence was restored"
cp "$reg" "$tmp/reg.bak"
jq 'del(.evidenceHashes)' "$tmp/reg.bak" >"$reg"
if check >/dev/null 2>&1; then fail "check passed a register with no evidence hashes"; fi

# 23. A pointer that resolves but is not what the check was measured from is
#     refused: the register citing itself, another page's file, or a finding that
#     dropped the input its row needs.
jq '(.findings[] | select(.id == "metadata/home/header_noindex") | .evidence) = ["register.json"]' "$tmp/reg.bak" >"$reg"
if out="$(check 2>&1)"; then fail "check passed a finding citing the register itself"; fi
grep -q 'not under evidence/metadata-audit/home/' <<<"$out" || fail "the self-citation was not named: $out"
jq '(.findings[] | select(.id == "metadata/home/header_noindex") | .evidence) = ["evidence/metadata-audit/about/page.html"]' "$tmp/reg.bak" >"$reg"
if check >/dev/null 2>&1; then fail "check passed a finding citing another page's file"; fi
jq '(.findings[] | select(.id == "metadata/home/header_noindex") | .evidence) = ["evidence/metadata-audit/home/page.html"]' "$tmp/reg.bak" >"$reg"
if out="$(check 2>&1)"; then fail "check passed a header finding that does not cite headers.txt"; fi
grep -q 'does not cite evidence/metadata-audit/home/headers.txt' <<<"$out" || fail "the missing input was not named: $out"

# 24. The remaining provenance fields are each checked, not just severity.
jq '(.findings[] | select(.id == "metadata/home/images_missing_alt") | .gate) = 1' "$tmp/reg.bak" >"$reg"
if check >/dev/null 2>&1; then fail "check passed a gate the table does not give"; fi
jq '(.findings[] | select(.id == "metadata/home/images_missing_alt") | .severitySource) = "a blog post"' "$tmp/reg.bak" >"$reg"
if check >/dev/null 2>&1; then fail "check passed a severitySource the table does not give"; fi
# A register built while the skill was still called metadata-audit carries that
# name in every place the build writes it: the decision-tree path each finding
# cites, the tool path at the top and on each finding, and the falsifier text. A
# delivered package must not start failing because a directory in this
# repository was renamed; any other spelling of the cited path still fails.
jq 'walk(if type == "string" then gsub("audit-metadata"; "metadata-audit") else . end)' "$tmp/reg.bak" >"$reg"
jq -e '[.findings[].severitySource | startswith("metadata-audit/references/decision-tree.md:")] | all and length > 0' \
  "$reg" >/dev/null || fail "the pre-rename fixture does not cite the old decision-tree path"
jq -e '.measuredBy.tool == "metadata-audit/scripts/inventory.py"
       and ([.findings[].measuredBy.tool == "metadata-audit/scripts/inventory.py"] | all)' \
  "$reg" >/dev/null || fail "the pre-rename fixture does not name the old tool path"
if grep -q 'audit-metadata' "$reg"; then fail "the pre-rename fixture still carries the new skill name"; fi
out="$(check 2>&1)" || fail "check rejected a register built before the skill was renamed: $out"
jq '(.findings[].severitySource) |= sub("^audit-metadata/"; "metadata-audits/")' "$tmp/reg.bak" >"$reg"
if check >/dev/null 2>&1; then fail "check passed a decision-tree path that was never the skill's"; fi
jq '.findings += [.findings[0]]' "$tmp/reg.bak" >"$reg"
if out="$(check 2>&1)"; then fail "check passed two findings with one id"; fi
grep -q 'duplicate id' <<<"$out" || fail "the duplicate id was not named: $out"
jq '.limits.sampleSize = 99' "$tmp/reg.bak" >"$reg"
if check >/dev/null 2>&1; then fail "check passed a sampleSize that disagrees with pages"; fi
# A finding for a check the same register says was not run is a contradiction,
# and so is a finding whose check the page does not list as run.
jq '.limits.checksNotRun.home.images_missing_alt = "hand-added"' "$tmp/reg.bak" >"$reg"
if out="$(check 2>&1)"; then fail "check passed a finding for a check listed as not run"; fi
grep -q 'was not run on this page, yet here is a finding' <<<"$out" || fail "the contradiction was not named: $out"
jq '(.pages[] | select(.slug == "home") | .checksRun) -= ["images_missing_alt"]' "$tmp/reg.bak" >"$reg"
if check >/dev/null 2>&1; then fail "check passed a finding whose check the page does not list as run"; fi
jq '(.pages[] | select(.slug == "about") | .checksRun) += ["header_noindex"]' "$tmp/reg.bak" >"$reg"
if check >/dev/null 2>&1; then fail "check passed a check listed both as run and as not run"; fi
cp "$tmp/reg.bak" "$reg"
check >/dev/null 2>&1 || fail "check did not pass the restored register after the provenance cases"

# 25. A named group for the general crawler outranks the * group, so "* disallows
#     everything" is not a P0 when Googlebot is let through by its own group.
mkdir -p "$ev/named"
cp "$ev/home/page.html" "$ev/named/page.html"
printf 'https://example.test/\n' >"$ev/named/url"
printf 'User-agent: *\nDisallow: /\n\nUser-agent: Googlebot\nAllow: /\n' >"$ev/named/robots.txt"
build >/dev/null 2>&1 || fail "build with the named-group page failed"
[[ "$(q '[.findings[] | select(.page == "named" and (.measuredBy.check | startswith("robots_blocks")))] | length')" == 0 ]] ||
  fail "a robots block fired although the general crawler is allowed by its own group: $(q '[.findings[] | select(.page == "named") | .id]')"
rm -rf "$ev/named"

# 26. A sitemap that did not parse is its own P1 and says nothing about the URL.
mkdir -p "$ev/badmap"
cp "$ev/home/page.html" "$ev/badmap/page.html"
printf 'https://example.test/\n' >"$ev/badmap/url"
printf '<!doctype html><html><head><title>Not found</title></head><body>404</body></html>\n' >"$ev/badmap/sitemap.xml"
build >/dev/null 2>&1 || fail "build with the HTML sitemap failed"
[[ "$(sev metadata/badmap/sitemap_invalid)" == P1 ]] || fail "an HTML sitemap was not a P1 sitemap_invalid"
[[ "$(q '[.findings[] | select(.id == "metadata/badmap/url_absent_from_sitemap")] | length')" == 0 ]] ||
  fail "url_absent_from_sitemap fired against a sitemap that did not parse"
rm -rf "$ev/badmap"

# 27. A captured time without a timezone is refused, not assumed to be UTC.
printf '2026-11-18T12:00:00\n' >"$ev/about/captured"
rc=0
out="$(build 2>&1)" || rc=$?
[[ "$rc" == 2 ]] || fail "a zone-less captured time exited $rc, not 2: $out"
grep -q 'timezone' <<<"$out" || fail "the zone-less captured time was not explained: $out"
printf '2026-11-18\n' >"$ev/about/captured"
rc=0
build >/dev/null 2>&1 || rc=$?
[[ "$rc" == 2 ]] || fail "a date-only captured value exited $rc, not 2"
printf '2026-11-18T12:00:00Z\n' >"$ev/about/captured"

# 28. Evidence has to live inside the package: a page.html that is a symlink to a
#     file outside it is an unusable input, exit 2, naming the path.
mkdir -p "$ev/linked"
printf '<!doctype html><html lang="en"><head><title>Outside</title></head><body><main><h1>x</h1></main></body></html>\n' >"$tmp/outside-page.html"
ln -s "$tmp/outside-page.html" "$ev/linked/page.html"
rc=0
out="$(build 2>&1)" || rc=$?
[[ "$rc" == 2 ]] || fail "a symlinked page.html outside the package exited $rc, not 2: $out"
grep -q 'linked/page.html' <<<"$out" || fail "the escaping input was not named: $out"
grep -q 'outside the package' <<<"$out" || fail "the escaping input was not explained: $out"
rm -rf "$ev/linked"

# 29. A build that dies on an unreadable input is an unusable package, exit 2, with
#     no traceback, and it removes the earlier register like every other failure.
build >/dev/null 2>&1 || fail "rebuild before the crash case failed"
printf '\xff\n' >"$ev/about/captured"
rc=0
out="$(build 2>&1)" || rc=$?
[[ "$rc" == 2 ]] || fail "a build that hit undecodable input exited $rc, not 2: $out"
grep -q 'Traceback' <<<"$out" && fail "undecodable input produced a traceback: $out"
grep -q 'build failed' <<<"$out" || fail "the crash was not reported plainly: $out"
[[ ! -e "$reg" && ! -e "$md" ]] || fail "a crashed build left the earlier register standing"
printf '2026-11-18T12:00:00Z\n' >"$ev/about/captured"
build >/dev/null 2>&1 || fail "rebuild before the unreadable-directory case failed"
mkdir -p "$ev/locked" && cp "$ev/home/page.html" "$ev/locked/page.html" && chmod 000 "$ev/locked"
rc=0
out="$(build 2>&1)" || rc=$?
chmod 755 "$ev/locked"
[[ "$rc" == 2 ]] || fail "an unreadable page directory exited $rc, not 2: $out"
grep -q 'Traceback' <<<"$out" && fail "an unreadable page directory produced a traceback: $out"
grep -q 'locked' <<<"$out" || fail "the unreadable directory was not named: $out"
[[ ! -e "$reg" && ! -e "$md" && ! -e "$reg.tmp" && ! -e "$pkg/register.md.tmp" ]] || fail "a build that could not read a page directory left a register or a temporary behind"
rm -rf "$ev/locked"

# 30. The * group binds the general crawler only when it has no group of its own.
#     With a Googlebot group present, its own rules decide path by path.
mkdir -p "$ev/owngroup"
cp "$ev/home/page.html" "$ev/owngroup/page.html"
printf 'User-agent: *\nDisallow: /\n\nUser-agent: Googlebot\nDisallow: /private\n' >"$ev/owngroup/robots.txt"
printf 'https://example.test/private/x\n' >"$ev/owngroup/url"
build >/dev/null 2>&1 || fail "build with the own-group page failed"
[[ "$(sev metadata/owngroup/robots_blocks_this_path)" == P0 ]] || fail "a path the general crawler's own group disallows was not robots_blocks_this_path"
[[ "$(q '[.findings[] | select(.id == "metadata/owngroup/robots_blocks_everything")] | length')" == 0 ]] ||
  fail "robots_blocks_everything fired although the general crawler has its own group"
rm -f "$ev/owngroup/url"
build >/dev/null 2>&1 || fail "build with the own-group page and no url failed"
[[ "$(q '[.findings[] | select(.page == "owngroup" and (.measuredBy.check | startswith("robots_blocks")))] | length')" == 0 ]] ||
  fail "a robots block fired with no url although the general crawler has its own group"
grep -q 'robots_blocks_everything' <<<"$(q '.limits.checksNotRun.owngroup | keys | join(",")')" ||
  fail "whether the general crawler's own group blocks everything was not listed as not run"
# The own group blocks everything too: the inventory cannot say so as a whole, so
# without a url the question is not run, never silently passed, and with a url the
# path is judged by that group.
printf 'User-agent: *\nDisallow: /\n\nUser-agent: Googlebot\nDisallow: /\n' >"$ev/owngroup/robots.txt"
build >/dev/null 2>&1 || fail "build with the own-group-blocks-all page failed"
grep -q 'robots_blocks_everything' <<<"$(q '.limits.checksNotRun.owngroup | keys | join(",")')" ||
  fail "an own group that blocks everything was silently passed as not blocking everything"
grep -q 'robots_blocks_everything' <<<"$(q '.pages[] | select(.slug == "owngroup") | .checksRun | join(",")')" &&
  fail "robots_blocks_everything was listed as run for a general crawler with its own group"
grep -q 'group of its own' <<<"$(q '.limits.checksNotRun.owngroup.robots_blocks_everything')" ||
  fail "the own-group skip does not carry its reason: $(q '.limits.checksNotRun.owngroup')"
grep -q 'robots_blocks_everything` because the general crawler has a robots.txt group of its own' "$md" ||
  fail "register.md does not give the own-group reason beside the skipped check"
grep -q 'robots_blocks_everything.*were not saved\|were not saved.*robots_blocks_everything' "$md" &&
  fail "register.md files the own-group skip under an input that was not saved"
printf 'https://example.test/\n' >"$ev/owngroup/url"
build >/dev/null 2>&1 || fail "build with the own-group-blocks-all page and a url failed"
[[ "$(sev metadata/owngroup/robots_blocks_this_path)" == P0 ]] || fail "a path blocked by the general crawler's own group was not P0"
rm -rf "$ev/owngroup"

# 31. A sitemap that parses but is not a sitemap is sitemap_invalid, not a sitemap
#     of zero URLs.
mkdir -p "$ev/wrongroot"
cp "$ev/home/page.html" "$ev/wrongroot/page.html"
printf 'https://example.test/\n' >"$ev/wrongroot/url"
printf '<html><body>hello</body></html>\n' >"$ev/wrongroot/sitemap.xml"
build >/dev/null 2>&1 || fail "build with the wrong-root sitemap failed"
[[ "$(sev metadata/wrongroot/sitemap_invalid)" == P1 ]] || fail "a well-formed non-sitemap was not sitemap_invalid"
grep -q 'root is <html>' <<<"$(q '.findings[] | select(.id == "metadata/wrongroot/sitemap_invalid") | .measured')" ||
  fail "the wrong root was not named in the measured sentence"
[[ "$(q '[.findings[] | select(.id == "metadata/wrongroot/url_absent_from_sitemap")] | length')" == 0 ]] ||
  fail "url_absent_from_sitemap fired against a file that is not a sitemap"
rm -rf "$ev/wrongroot"

# 32. A finding may cite only files the tool read for its page: a stray file in the
#     page directory, even one with a recorded hash, is refused.
build >/dev/null 2>&1 || fail "rebuild before the stray-file case failed"
printf 'analyst note\n' >"$ev/home/notes.txt"
cp "$reg" "$tmp/reg.bak"
sha="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$ev/home/notes.txt")"
jq --arg s "$sha" '.evidenceHashes["evidence/metadata-audit/home/notes.txt"] = $s | (.findings[] | select(.id == "metadata/home/h1_missing") | .evidence) += ["evidence/metadata-audit/home/notes.txt"]' "$tmp/reg.bak" >"$reg"
if out="$(check 2>&1)"; then fail "check passed a finding citing a file the tool never read"; fi
grep -q 'not a file the tool read for this page' <<<"$out" || fail "the stray pointer was not explained: $out"
rm -f "$ev/home/notes.txt"
cp "$tmp/reg.bak" "$reg"
check >/dev/null 2>&1 || fail "check did not pass the restored register after the stray-file case"
grep -q 'does not re-measure' "$md" || fail "register.md does not state the hash limitation"
build >/dev/null 2>&1 || fail "final rebuild failed"
check >/dev/null 2>&1 || fail "final check failed"

echo "website-audit-register tests: passed"
