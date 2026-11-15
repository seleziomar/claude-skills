#!/usr/bin/env bash
# check-report.sh <file.html> — checks the trial-by-fire report contract.
#
# Runs on the template (via run-tests.sh) and on the GENERATED HTML from Phase 5: the generated
# file is what reaches QA, and that is where linked images, a missing dark mode or sideways
# scrolling show up. Comments are ignored: a rule that only lives inside a comment does not count.
# CSS comments exist only inside <style>: elsewhere "/*" is the report's own text (a glob such as
# app/*.php, a path such as */cycle-*/images/), and stripping it would cut sections or hide images.
set -uo pipefail

HTML=${1:-}
[ -n "$HTML" ] && [ -f "$HTML" ] || { printf 'usage: check-report.sh <file.html>\n' >&2; exit 2; }

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s: %s\n' "$HTML" "$*" >&2; FAIL=$((FAIL + 1)); }

size=$(wc -c < "$HTML" | tr -d ' ')
[ "$size" -le 16777216 ] && ok || fail "larger than 16 MB ($size bytes)"

# Content without HTML comments (anywhere) and CSS comments (only inside <style>...</style>; the
# rest is copied unchanged).
clean=$(awk '{ s = s $0 "\n" }
  END {
    while ((i = index(s, "<!--")) > 0) { j = index(substr(s, i), "-->"); if (!j) { s = substr(s, 1, i - 1); break } s = substr(s, 1, i - 1) substr(s, i + j + 2) }
    out = ""
    while ((i = index(tolower(s), "<style")) > 0) {
      out = out substr(s, 1, i - 1); s = substr(s, i)
      j = index(tolower(s), "</style")
      if (j) { css = substr(s, 1, j - 1); s = substr(s, j) } else { css = s; s = "" }
      # "/*" up to the next "*/"; an unclosed one runs to the end of the style block, never past it.
      while ((k = index(css, "/*")) > 0) { m = index(substr(css, k + 2), "*/"); if (!m) { css = substr(css, 1, k - 1); break } css = substr(css, 1, k - 1) substr(css, k + m + 3) }
      out = out css
      if (j) { out = out substr(s, 1, 8); s = substr(s, 9) }
    }
    printf "%s", out s
  }' "$HTML")

# grep -q reads from a here-string, not a pipe: with pipefail, `printf | grep -q` exits 141 (SIGPIPE)
# when grep matches early in a large HTML (embedded image), and the match turns into a failure.
has() { grep -q -- "$1" <<< "$clean"; }
has '<meta name="report" content="trial-by-fire">' && ok || fail "missing <meta name=\"report\" content=\"trial-by-fire\">"
has ':root {'                             && ok || fail "missing color tokens in :root"
has 'prefers-color-scheme: dark'          && ok || fail "missing dark mode via prefers-color-scheme"
has ':root\[data-theme="dark"\]'          && ok || fail "missing :root[data-theme=\"dark\"]"
has 'body { background: var(--bg)'        && ok || fail "body needs an explicit background"
has 'overflow-wrap: anywhere'             && ok || fail "long code/paths need overflow-wrap: anywhere (sideways scroll at 375px)"
for sec in verdict matrix cases scenarios unmapped suite findings inventory; do
  has "id=\"$sec\"" && ok || fail "missing section id=\"$sec\""
done

# Every reference is embedded (data:), an anchor (#) or a Google Fonts file (host followed by '/').
# Checked on the content with newlines collapsed, so a tag split across lines is still seen.
flat=$(printf '%s' "$clean" | tr '\n\r\t' '   ')
allowed='^(data:|#|https://fonts\.googleapis\.com/|https://fonts\.gstatic\.com/)'
# src/href (quoted or unquoted) and CSS url(...) / @import "..." targets.
external=$({
  printf '%s' "$flat" | grep -Eio "(src|href)[[:space:]]*=[[:space:]]*(\"[^\"]*\"|'[^']*'|[^[:space:]>\"']+)" \
    | sed -E "s/^[^=]*=[[:space:]]*//; s/^[\"']//; s/[\"']$//"
  printf '%s' "$flat" | grep -Eio "url\([[:space:]]*[\"']?[^)\"']*" | sed -E "s/^url\([[:space:]]*[\"']?//"
  printf '%s' "$flat" | grep -Eio "@import[[:space:]]*[\"'][^\"']*" | sed -E "s/^@import[[:space:]]*[\"']//"
} | grep -Ev "$allowed" || true)
# srcset: a data: value passes only if no further candidate follows that is not data:/#/Google Fonts.
srcset=$(printf '%s' "$flat" | grep -Eio "srcset[[:space:]]*=[[:space:]]*(\"[^\"]*\"|'[^']*'|[^[:space:]>\"']+)" \
  | sed -E "s/^[^=]*=[[:space:]]*//; s/^[\"']//; s/[\"']$//" \
  | awk '{ if ($0 !~ /^data:/) { print; next } if ($0 ~ /,[ ]*(https?:|\/|\.|[A-Za-z0-9_-]+\.[a-z]+)/ && $0 !~ /,[ ]*data:/) print }' || true)
[ -z "$external$srcset" ] && ok || fail "src/href/srcset/url() outside data:, # or Google Fonts: $(printf '%s %s' "$external" "$srcset" | tr '\n' ' ')"

# A link to the same embedded image doubles the size, and Chrome blocks navigating to data:.
grep -Eiq "<a[^>]+href[[:space:]]*=[[:space:]]*[\"']?data:" <<< "$flat" && fail "<a href=\"data:...\"> duplicates the image" || ok

[ "$FAIL" -eq 0 ] && printf 'OK: %s (%d checks)\n' "$HTML" "$PASS"
[ "$FAIL" -eq 0 ]
