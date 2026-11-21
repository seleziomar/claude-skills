#!/usr/bin/env bash
# run-tests.sh — tests of review-package.sh, plus the doc-lint of SKILL.md and the agents.
#
# Every test builds its own fixture repository with mktemp -d. Script tests pass an explicit
# `--base main`: with an explicit base the script skips the tighter-base detection, which keeps
# the manifest deterministic.
set -uo pipefail
set -f

SKILL_DIR=$(cd "$(dirname "$0")/.." && pwd)
BUILD="$SKILL_DIR/scripts/review-package.sh"

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

# assert_contains <needle> <haystack> <test name>
assert_contains() {
  if printf '%s' "$2" | grep -qF -- "$1"; then ok
  else fail "$3 — expected to contain: $1"; fi
}

# assert_not_contains <needle> <haystack> <test name>
assert_not_contains() {
  if printf '%s' "$2" | grep -qF -- "$1"; then fail "$3 — must not contain: $1"
  else ok; fi
}

# mkfixture -> prints the path of a new git repository with one commit on main
mkfixture() {
  local d
  d=$(mktemp -d)
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name  't'
  printf 'initial\n' > "$d/README.md"
  git -C "$d" add README.md
  git -C "$d" commit -qm initial
  printf '%s' "$d"
}

# run_build <repo> [args...] -> echoes the manifest (stdout and stderr together)
run_build() {
  local repo="$1"; shift
  ( cd "$repo" && bash "$BUILD" "$@" 2>&1 )
}

# run_build_status <repo> [args...] -> echoes the exit code (the output goes to /dev/null)
run_build_status() {
  local repo="$1"; shift
  ( cd "$repo" && bash "$BUILD" "$@" >/dev/null 2>&1 ); printf '%s' "$?"
}

# section_of <header> <manifest> -> prints that section's block, up to the first blank line.
# Asserts scoped to one section: a loose needle can show up in another section by accident
# and hide a bug.
section_of() {
  printf '%s' "$2" | awk -v hdr="^$1" '$0 ~ hdr,/^$/'
}

# ---------------------------------------------------------------- inert text excluded
test_excludes_lockfile() {
  local r out
  r=$(mkfixture)
  mkdir -p "$r/app"
  printf '{ "packages": [] }\n' > "$r/composer.lock"
  printf '<?php class Foo {}\n'  > "$r/app/Foo.php"
  git -C "$r" add -A && git -C "$r" commit -qm base
  git -C "$r" checkout -qb feat
  printf '{ "packages": ["new"] }\n' > "$r/composer.lock"
  printf '<?php class Foo { public function bar() {} }\n' > "$r/app/Foo.php"

  out=$(run_build "$r" --base main)

  local changed excluded diffpath diffbody
  changed=$(section_of 'CHANGED FILES' "$out")
  excluded=$(section_of 'EXCLUDED' "$out")
  diffpath=$(printf '%s' "$out" | awk '/^DIFF: /{print $2}')
  diffbody=$(cat "$diffpath")

  # the code file shows up in the right section (not a loose assert on the whole manifest:
  # "composer.lock" also appears elsewhere)
  assert_contains 'app/Foo.php' "$changed" 'exclude: code file listed in CHANGED FILES'
  assert_contains 'EXCLUDED'   "$out" 'exclude: manifest has an EXCLUDED section'
  assert_contains 'composer.lock' "$excluded" 'exclude: lock file listed in EXCLUDED'

  # the lock file must not be in CHANGED FILES
  assert_not_contains 'composer.lock' "$changed" 'exclude: lock file out of CHANGED FILES'

  # nor in the diff...
  assert_not_contains 'composer.lock' "$diffbody" 'exclude: lock file out of the frozen diff'
  # ...but the kept file's hunk must survive (a filter that drops everything, or an
  # EXCLUDE_PATTERNS that excludes everything, would also pass the assert above)
  assert_contains 'public function bar' "$diffbody" 'exclude: hunk of app/Foo.php survives in the frozen diff'

  rm -rf "$r"
}

test_excludes_lockfile

# ------------------------------------------------------------ a rename escapes the filter
# Regression: `git diff` detects renames by default, even without `-M`. Then `--name-only`
# returns only the post-image path (b/), but the unified diff header has BOTH sides:
# `diff --git a/<pre> b/<post>`. A filter that only looks at a/ lets the whole hunk of a file
# renamed INTO an excluded pattern escape — exactly the case of hashed builds (Vite and the
# like) under public/build/, renamed on every build.
test_rename_into_excluded_pattern_is_filtered() {
  local r out i
  r=$(mkfixture)
  mkdir -p "$r/public/build"
  {
    for i in $(seq 1 20); do printf 'console.log("minified line %s")\n' "$i"; done
  } > "$r/public/build/app.min.js"
  git -C "$r" add -A && git -C "$r" commit -qm base
  git -C "$r" checkout -qb feat
  git -C "$r" mv public/build/app.min.js public/build/app2.min.js
  {
    for i in $(seq 1 20); do printf 'console.log("minified line %s")\n' "$i"; done
    printf 'console.log("new minified line")\n'
  } > "$r/public/build/app2.min.js"

  out=$(run_build "$r" --base main)

  local excluded diffpath diffbody
  excluded=$(section_of 'EXCLUDED' "$out")
  diffpath=$(printf '%s' "$out" | awk '/^DIFF: /{print $2}')
  diffbody=$(cat "$diffpath")

  assert_contains 'app2.min.js' "$excluded" 'rename: renamed file listed in EXCLUDED'
  assert_not_contains 'diff --git' "$diffbody" 'rename: the rename header does not survive in the frozen diff'
  assert_not_contains 'minified'   "$diffbody" 'rename: the hunk content does not survive in the frozen diff'

  rm -rf "$r"
}

test_rename_into_excluded_pattern_is_filtered

# ------------------------------------------------------- a non-ASCII name escapes the filter
# Regression: `--name-only` runs with `-c core.quotePath=false` and returns the path as plain
# UTF-8, but the `git diff` that writes the diff file did not have that flag. Without it, a
# non-ASCII byte in the file name comes out quoted and escaped in the header
# (`diff --git "a/A\303\247..."`), which breaks the path parsing of the filter: the file shows
# up in EXCLUDED but its content survives in the frozen diff.
test_non_ascii_name_is_filtered() {
  local r out
  r=$(mkfixture)
  mkdir -p "$r/vendor"
  printf '{ "packages": [] }\n' > "$r/vendor/Ação.lock"
  git -C "$r" add -A && git -C "$r" commit -qm base
  git -C "$r" checkout -qb feat
  printf '{ "packages": ["new"] }\n' > "$r/vendor/Ação.lock"

  out=$(run_build "$r" --base main)

  local excluded diffpath diffbody
  excluded=$(section_of 'EXCLUDED' "$out")
  diffpath=$(printf '%s' "$out" | awk '/^DIFF: /{print $2}')
  diffbody=$(cat "$diffpath")

  assert_contains 'vendor/A' "$excluded" 'non-ascii: file with a non-ASCII name listed in EXCLUDED'
  assert_not_contains 'packages' "$diffbody" 'non-ascii: content of the non-ASCII lock file does not survive in the frozen diff'

  rm -rf "$r"
}

test_non_ascii_name_is_filtered

# ------------------------------------------------------------- docs/** excluded
# Regression: in a real pull request, about one line in seven was planning markdown under
# docs/ (a plan and a spec), read by every review agent for nothing.
test_excludes_docs() {
  local r out
  r=$(mkfixture)
  mkdir -p "$r/docs/notes" "$r/app"
  printf '# plan\n'              > "$r/docs/notes/some-plan.md"
  printf '<?php class Foo {}\n' > "$r/app/Foo.php"
  git -C "$r" add -A && git -C "$r" commit -qm base
  git -C "$r" checkout -qb feat
  printf '# plan\none more line\n' > "$r/docs/notes/some-plan.md"
  printf '<?php class Foo { public function bar() {} }\n' > "$r/app/Foo.php"

  out=$(run_build "$r" --base main)

  local changed excluded diffpath diffbody
  changed=$(section_of 'CHANGED FILES' "$out")
  excluded=$(section_of 'EXCLUDED' "$out")
  diffpath=$(printf '%s' "$out" | awk '/^DIFF: /{print $2}')
  diffbody=$(cat "$diffpath")

  assert_contains 'docs/notes/some-plan.md' "$excluded" \
    'docs: the plan under docs/ is listed in EXCLUDED'
  assert_not_contains 'docs/notes/some-plan.md' "$changed" \
    'docs: the plan under docs/ is out of CHANGED FILES'
  assert_not_contains 'docs/notes/some-plan.md' "$diffbody" \
    'docs: the plan under docs/ is out of the frozen diff'

  # the code file outside docs/ must survive untouched (otherwise an EXCLUDE_PATTERNS or a
  # filter that empties the whole diff would pass)
  assert_contains 'app/Foo.php' "$changed" 'docs: app/Foo.php stays in CHANGED FILES'
  assert_contains 'public function bar' "$diffbody" \
    'docs: hunk of app/Foo.php survives in the frozen diff'

  rm -rf "$r"
}

test_excludes_docs

# ---------------------------------------------------------------------- read map
test_read_map_large_file() {
  local r out map
  r=$(mkfixture)
  mkdir -p "$r/app"
  # 600 lines: above the 400 threshold
  awk 'BEGIN { print "<?php"; for (i = 2; i <= 600; i++) print "// line " i }' > "$r/app/Big.php"
  git -C "$r" add -A && git -C "$r" commit -qm base
  git -C "$r" checkout -qb feat
  # changes line 300 only
  awk 'NR == 300 { print "// TOUCHED"; next } { print }' "$r/app/Big.php" > "$r/tmp" \
    && mv "$r/tmp" "$r/app/Big.php"

  out=$(run_build "$r" --base main)
  map=$(section_of 'READ MAP' "$out")

  assert_contains 'READ MAP' "$out"  'map: manifest has a READ MAP'
  assert_contains 'app/Big.php'  "$map" 'map: large file in the map'
  assert_contains '600'          "$map" 'map: line count of the large file'
  assert_not_contains 'read whole' "$map" 'map: large file not marked as small'
  # the range must surround line 300 (the -U3 diff gives 297-303 or close)
  if printf '%s' "$map" | grep -qE '29[0-9]-30[0-9]'; then ok
  else fail 'map: the range does not surround the changed line'; fi

  rm -rf "$r"
}

test_read_map_small_file() {
  local r out map
  r=$(mkfixture)
  mkdir -p "$r/app"
  printf '<?php\nclass P {}\n' > "$r/app/Small.php"
  git -C "$r" add -A && git -C "$r" commit -qm base
  git -C "$r" checkout -qb feat
  printf '<?php\nclass P { public $x; }\n' > "$r/app/Small.php"

  out=$(run_build "$r" --base main)
  map=$(section_of 'READ MAP' "$out")

  assert_contains 'small file, read whole' "$map" 'map: small file marked read whole'
  rm -rf "$r"
}

test_read_map_untracked() {
  local r out map
  r=$(mkfixture)
  git -C "$r" checkout -qb feat
  mkdir -p "$r/app"
  awk 'BEGIN { print "<?php"; for (i = 2; i <= 500; i++) print "// line " i }' > "$r/app/New.php"

  out=$(run_build "$r" --base main)
  map=$(section_of 'READ MAP' "$out")

  assert_contains 'app/New.php' "$map" 'map: untracked file enters the map'
  assert_contains '1-500'       "$map" 'map: untracked file gets the whole-file range'
  assert_not_contains 'read whole' "$map" 'map: a large untracked file respects the threshold'
  rm -rf "$r"
}

test_read_map_deleted_file() {
  local r out map line
  r=$(mkfixture)
  mkdir -p "$r/app"
  printf '<?php\nclass D {}\n' > "$r/app/Deleted.php"
  git -C "$r" add -A && git -C "$r" commit -qm base
  git -C "$r" checkout -qb feat
  git -C "$r" rm -q app/Deleted.php

  out=$(run_build "$r" --base main)
  map=$(section_of 'READ MAP' "$out")

  assert_contains 'app/Deleted.php' "$map" 'map: deleted file shows up in the read map'
  assert_contains '(deleted)'       "$map" 'map: the read map marks the deleted file'
  # the mark must be ON THE SAME LINE as the file, not just somewhere in the section
  line=$(printf '%s' "$map" | grep -F 'app/Deleted.php')
  assert_contains '(deleted)' "$line" 'map: (deleted) sits on the file own line'

  rm -rf "$r"
}

# Regression: the "deleted" verdict must come from the frozen diff, not from probing the live
# tree. In PR mode nobody checks out the branch, so EVERY file the PR adds is missing from the
# disk — with `[ ! -f ]` deciding, it came out as "(deleted)", the opposite of the truth. PR
# mode cannot be built in a fixture (it needs gh), but the invariant is the same and local
# mode reaches it with a dangling symlink: a real range in the diff (`+/does/not/exist`) that
# fails `[ -f ]`.
test_read_map_real_range_missing_on_disk() {
  local r out map line
  r=$(mkfixture)
  git -C "$r" checkout -qb feat
  mkdir -p "$r/app"
  ln -s /does/not/exist "$r/app/Link.php"
  git -C "$r" add -A && git -C "$r" commit -qm 'dangling symlink'

  out=$(run_build "$r" --base main)
  map=$(section_of 'READ MAP' "$out")

  assert_contains 'app/Link.php' "$map" 'map: a path with a real range but missing on disk enters the map'
  line=$(printf '%s' "$map" | grep -F 'app/Link.php')
  assert_not_contains '(deleted)' "$line" 'map: a path with a real range in the diff cannot come out as (deleted)'
  assert_contains '(missing on disk)' "$line" 'map: a path missing on disk has its own mark'

  rm -rf "$r"
}

# The map promises "rangeS", plural, and no fixture had TWO hunks in the SAME file: reducing
# the `", "` join of emit_readmap to last-range-wins passed every test. Without this fixture the
# per-file aggregation — what sets the map apart from a list of hunks — has no guard, and the
# `++ ` bug (next test) would be invisible too.
test_read_map_multi_hunk() {
  local r out map line
  r=$(mkfixture)
  mkdir -p "$r/app"
  awk 'BEGIN { print "<?php"; for (i = 2; i <= 900; i++) print "// line " i }' > "$r/app/Big.php"
  git -C "$r" add -A && git -C "$r" commit -qm base
  git -C "$r" checkout -qb feat
  # two hunks far apart (600 lines: -U3 does not merge them)
  awk 'NR == 200 { print "// TOUCHED 200"; next } NR == 800 { print "// TOUCHED 800"; next } { print }' \
    "$r/app/Big.php" > "$r/tmp" && mv "$r/tmp" "$r/app/Big.php"

  out=$(run_build "$r" --base main)
  map=$(section_of 'READ MAP' "$out")
  line=$(printf '%s' "$map" | grep -F 'app/Big.php')

  # BOTH ranges, on the SAME line, joined by ", " — not the first, not the last
  assert_contains '197-203, 797-803' "$line" \
    'map-multihunk: both ranges of the file show up joined by ", " on its line'
  rm -rf "$r"
}

# Regression: `ranges_of_diff` treated ANY line starting with `+++ ` as a file header. An
# ADDED content line starting with `++ ` comes out in the diff as `+++ ...` and hijacked the
# state machine: the current file became a junk path, and the next ranges of the REAL file
# went to it. The file had 900 lines (so not "read whole"), and the agent was told to read by
# range with one range missing. The fix anchors the header on `^diff --git `, which cannot be
# hijacked: every content line of a unified diff carries a `+`, `-` or space prefix.
test_read_map_content_line_looks_like_header() {
  local r out map line
  r=$(mkfixture)
  mkdir -p "$r/app"
  awk 'BEGIN { print "<?php"; for (i = 2; i <= 900; i++) print "// line " i }' > "$r/app/Big.php"
  git -C "$r" add -A && git -C "$r" commit -qm base
  git -C "$r" checkout -qb feat
  awk 'NR == 200 { print "++ content that looks like a header"; next }
       NR == 800 { print "// TOUCHED 800"; next } { print }' \
    "$r/app/Big.php" > "$r/tmp" && mv "$r/tmp" "$r/app/Big.php"

  out=$(run_build "$r" --base main)
  map=$(section_of 'READ MAP' "$out")
  line=$(printf '%s' "$map" | grep -F 'app/Big.php')

  assert_contains '197-203' "$line" 'map-pseudoheader: 1st range of the real file survives'
  assert_contains '797-803' "$line" \
    'map-pseudoheader: 2nd range of the real file survives (it did not go to the hijacked path)'
  assert_not_contains 'ontent that looks like a header' "$map" \
    'map-pseudoheader: no junk path enters the map'
  # ONE line in the map: the real file. A junk path would also inflate the count.
  if [ "$(printf '%s' "$map" | tail -n +2 | grep -c .)" = 1 ]; then ok
  else fail 'map-pseudoheader: the map should have exactly 1 line (app/Big.php only)'; fi
  rm -rf "$r"
}

# Regression: the map was not TOTAL over CHANGED FILES. A binary, a mode-only change (chmod +x)
# and a 100% rename produce no hunk, so they were missing from the map — while still in CHANGED
# FILES and CODE SCOPE. The agents treat the map as the AUTHORITY for reading (a whole-file read
# is licensed only by its mark), so those files had no licensed way to be read and no
# explanation why.
test_read_map_covers_every_changed_file() {
  local r out map n_map
  r=$(mkfixture)
  mkdir -p "$r/app"
  printf '<?php class Normal {}\n'      > "$r/app/Normal.php"
  printf 'AB\000CD\n'                   > "$r/app/bin.dat"
  printf '#!/bin/sh\necho hi\n'         > "$r/app/script.sh"
  printf 'stable content\nline 2\n'     > "$r/app/old.txt"
  git -C "$r" add -A && git -C "$r" commit -qm base
  git -C "$r" checkout -qb feat
  printf '<?php class Normal { public function x() {} }\n' > "$r/app/Normal.php"
  printf 'AB\000XY\n' > "$r/app/bin.dat"   # binary: git prints "Binary files differ"
  chmod +x "$r/app/script.sh"              # mode only: no hunk
  git -C "$r" mv app/old.txt app/new.txt   # 100% rename: no hunk

  out=$(run_build "$r" --base main)
  map=$(section_of 'READ MAP' "$out")

  assert_contains 'CHANGED FILES (4)' "$out" 'map-total: the 4 files are in CHANGED FILES'
  assert_contains 'app/Normal.php' "$map" 'map-total: file with a hunk in the map'
  assert_contains 'app/bin.dat'    "$map" 'map-total: binary in the map'
  assert_contains 'app/script.sh'  "$map" 'map-total: mode-only change in the map'
  assert_contains 'app/new.txt'    "$map" 'map-total: pure rename in the map'
  assert_contains '(no hunk: binary, mode or pure rename)' "$map" \
    'map-total: a file without a hunk has a mark explaining why it has no range'
  # totality: one map line per changed file, no more and no less
  n_map=$(printf '%s' "$map" | tail -n +2 | grep -c .)
  if [ "$n_map" = 4 ]; then ok
  else fail "map-total: the map has $n_map lines for 4 changed files"; fi
  rm -rf "$r"
}

# Every other list section of the manifest prints `(none)` when empty; the map came out
# literally blank, which does not tell "there was no file" from "the section failed".
test_read_map_empty_says_none() {
  local r out map
  r=$(mkfixture)
  git -C "$r" checkout -qb feat

  out=$(run_build "$r" --base main)
  map=$(section_of 'READ MAP' "$out")

  assert_contains '(none)' "$map" 'map-empty: an empty map says (none) instead of coming out blank'
  rm -rf "$r"
}

# Regression: SMALL_FILE_LINES=400 was BRACKETED (fixtures of 2, 500 and 600 lines), not
# PINNED — mutating it to 401 survived, and so did any value in [3,499]. The agents state the
# literal 400, so drift between the constant and the prose was invisible. Two fixtures at
# EXACTLY 400 and 401 lines close the threshold on both sides.
test_read_map_exact_threshold() {
  local r out map l400 l401
  r=$(mkfixture)
  mkdir -p "$r/app"
  awk 'BEGIN { for (i = 1; i <= 400; i++) print "// line " i }' > "$r/app/Q400.php"
  awk 'BEGIN { for (i = 1; i <= 401; i++) print "// line " i }' > "$r/app/Q401.php"
  git -C "$r" add -A && git -C "$r" commit -qm base
  git -C "$r" checkout -qb feat
  awk 'NR == 200 { print "// TOUCHED"; next } { print }' "$r/app/Q400.php" > "$r/t" \
    && mv "$r/t" "$r/app/Q400.php"
  awk 'NR == 200 { print "// TOUCHED"; next } { print }' "$r/app/Q401.php" > "$r/t" \
    && mv "$r/t" "$r/app/Q401.php"

  out=$(run_build "$r" --base main)
  map=$(section_of 'READ MAP' "$out")
  l400=$(printf '%s' "$map" | grep -F 'app/Q400.php')
  l401=$(printf '%s' "$map" | grep -F 'app/Q401.php')

  # the threshold is inclusive: 400 is still small (closes a mutation to 399 and below)
  assert_contains '400 | small file, read whole' "$l400" \
    'map-threshold: 400 lines, the inclusive threshold, is still a small file'
  # 401 is not (closes a mutation to 401 and above)
  assert_contains '401 | 197-203' "$l401" \
    'map-threshold: 401 lines get a range instead of read whole'
  assert_not_contains 'small file' "$l401" \
    'map-threshold: 401 lines are not marked as a small file'
  rm -rf "$r"
}

test_read_map_large_file
test_read_map_small_file
test_read_map_untracked
test_read_map_deleted_file
test_read_map_real_range_missing_on_disk
test_read_map_exact_threshold
test_read_map_multi_hunk
test_read_map_content_line_looks_like_header
test_read_map_covers_every_changed_file
test_read_map_empty_says_none

# ------------------------------------------------- files per rule and scope per agent
test_rule_lists_files() {
  local r out
  r=$(mkfixture)
  mkdir -p "$r/.claude/rules" "$r/app/Http/Controllers" "$r/tests"
  cat > "$r/.claude/rules/http.md" <<'RULE'
---
paths:
  - "app/Http/Controllers/**/*.php"
---
A controller holds no business rule.
RULE
  cat > "$r/.claude/rules/testing.md" <<'RULE'
---
paths:
  - "tests/**/*.php"
---
setUp() declares a : void return type.
RULE
  # TWO files matching the SAME rule: that is what sets `all_matches` apart from
  # `first_match`. With one file per rule, all_matches degrading into first_match (which the
  # guard comment in the script forbids) is invisible in the manifest.
  printf '<?php class FooController {}\n' > "$r/app/Http/Controllers/FooController.php"
  printf '<?php class BarController {}\n' > "$r/app/Http/Controllers/BarController.php"
  printf '<?php class FooTest {}\n'       > "$r/tests/FooTest.php"
  git -C "$r" add -A && git -C "$r" commit -qm base
  git -C "$r" checkout -qb feat
  printf '<?php class FooController { public function x() {} }\n' > "$r/app/Http/Controllers/FooController.php"
  printf '<?php class BarController { public function y() {} }\n' > "$r/app/Http/Controllers/BarController.php"
  printf '<?php class FooTest { public function setUp() {} }\n'   > "$r/tests/FooTest.php"

  out=$(run_build "$r" --base main)

  local rules under_http under_tests
  rules=$(section_of 'APPLICABLE RULES' "$out")
  assert_contains 'APPLICABLE RULES (2)' "$rules" 'rules: counts distinct rules, not lines'
  assert_contains 'http.md' "$rules" 'rules: the controller rule matched'
  # The pattern on the rule line comes from an `awk` that may return empty; without this
  # assert the line would degrade to `http.md    <- ` and everything else would pass.
  assert_contains '<- app/Http/Controllers/**/*.php' "$rules" \
    'rules: the rule line shows the pattern, not only the file name'

  # The files must sit on their own INDENTED lines under their rule. Without that scoping,
  # the assert would pass on the rule line's pattern alone, which also holds the
  # `app/Http/Controllers/` prefix.
  under_http=$(printf '%s' "$rules" | awk '/http\.md/ {f=1; next} /^[^ ]/ {f=0} f')
  under_tests=$(printf '%s' "$rules" | awk '/testing\.md/ {f=1; next} /^[^ ]/ {f=0} f')
  assert_contains 'app/Http/Controllers/BarController.php' "$under_http" \
    'rules: 1st file indented under its own rule'
  assert_contains 'app/Http/Controllers/FooController.php' "$under_http" \
    'rules: 2nd file of the SAME rule shows up too (all_matches, not first_match)'
  assert_not_contains 'tests/FooTest.php' "$under_http" \
    'rules: a file of another rule does not leak into http.md'
  assert_contains 'tests/FooTest.php' "$under_tests" 'rules: the test rule lists the test'

  local code tst
  code=$(section_of 'CODE SCOPE' "$out")
  tst=$(section_of 'TEST SCOPE' "$out")
  # The header counts are what keeps the assert_not_contains below from passing for free on
  # an empty section.
  assert_contains 'CODE SCOPE (non-test) (2)' "$out" 'rules: code scope counts 2'
  assert_contains 'TEST SCOPE (1)'            "$out" 'rules: test scope counts 1'
  assert_contains 'app/Http/Controllers/FooController.php' "$code" 'rules: code in the code scope'
  assert_contains 'app/Http/Controllers/BarController.php' "$code" 'rules: 2nd code file in the code scope'
  assert_not_contains 'tests/FooTest.php' "$code" 'rules: test out of the code scope'
  assert_contains 'tests/FooTest.php' "$tst" 'rules: test in the test scope'
  assert_not_contains 'Controller.php' "$tst" 'rules: code out of the test scope'

  rm -rf "$r"
}

test_scope_without_test_rule() {
  # With NO rule in the repository, the generic fallback applies. And it must be anchored:
  # `app/latest/Thing.php` and `app/Espectro/Chart.php` are production code, and a
  # fallback on loose substrings (`*test*`, `*spec*`) classified them as tests —
  # "la-TEST-", "E-SPEC-tro" (a common Portuguese word).
  local r out code tst
  r=$(mkfixture)
  mkdir -p "$r/tests" "$r/app/latest" "$r/app/Espectro"
  printf '<?php class BarTest {}\n' > "$r/tests/BarTest.php"
  printf '<?php class Thing {}\n'   > "$r/app/latest/Thing.php"
  printf '<?php class Chart {}\n'   > "$r/app/Espectro/Chart.php"
  git -C "$r" add -A && git -C "$r" commit -qm base
  git -C "$r" checkout -qb feat
  printf '<?php class BarTest { public function t() {} }\n' > "$r/tests/BarTest.php"
  printf '<?php class Thing { public function t() {} }\n'   > "$r/app/latest/Thing.php"
  printf '<?php class Chart { public function t() {} }\n'   > "$r/app/Espectro/Chart.php"

  out=$(run_build "$r" --base main)
  tst=$(section_of 'TEST SCOPE' "$out")
  code=$(section_of 'CODE SCOPE' "$out")
  assert_contains 'TEST SCOPE (1)'            "$out" 'scope: the fallback classifies exactly 1 test'
  assert_contains 'CODE SCOPE (non-test) (2)' "$out" 'scope: the fallback leaves the 2 production files in code'
  assert_contains 'tests/BarTest.php' "$tst" 'scope: the generic fallback picks the test file'
  assert_not_contains 'tests/BarTest.php' "$code" 'scope: the fallback takes the test out of the code scope'
  assert_contains 'app/latest/Thing.php' "$code" \
    'scope: the anchored fallback does not mistake "latest" for a test'
  assert_contains 'app/Espectro/Chart.php' "$code" \
    'scope: the anchored fallback does not mistake "Espectro" for a spec'
  assert_not_contains 'app/latest/Thing.php' "$tst" 'scope: "latest" out of the test scope'
  assert_not_contains 'app/Espectro/Chart.php' "$tst" 'scope: "Espectro" out of the test scope'
  rm -rf "$r"
}

# Regression: the test-glob recognizer was `grep -E 'test|spec'` on the whole pattern, and
# `app/Perspectiva/**/*.php` holds "spec" (Per-SPEC-tiva). Result: `CODE SCOPE (0) — (none)` with
# production code in the diff, and the bugs and security agents reviewing NOTHING, with no
# warning. In a Portuguese codebase "perspectiva", "espectro" and "especificacao" are common
# words. This is the PREFERRED path (the repository's own rule), not the fallback.
test_glob_with_spec_in_common_word() {
  local r out code tst
  r=$(mkfixture)
  mkdir -p "$r/.claude/rules" "$r/app/Perspectiva" "$r/tests"
  cat > "$r/.claude/rules/testing.md" <<'RULE'
---
paths:
  - "tests/**/*.php"
---
setUp() declares a : void return type.
RULE
  cat > "$r/.claude/rules/perspective.md" <<'RULE'
---
paths:
  - "app/Perspectiva/**/*.php"
---
A chart does not change the data it shows.
RULE
  printf '<?php class Chart {}\n'   > "$r/app/Perspectiva/Chart.php"
  printf '<?php class FooTest {}\n' > "$r/tests/FooTest.php"
  git -C "$r" add -A && git -C "$r" commit -qm base
  git -C "$r" checkout -qb feat
  printf '<?php class Chart { public function x() {} }\n'       > "$r/app/Perspectiva/Chart.php"
  printf '<?php class FooTest { public function setUp() {} }\n' > "$r/tests/FooTest.php"

  out=$(run_build "$r" --base main)
  code=$(section_of 'CODE SCOPE' "$out")
  tst=$(section_of 'TEST SCOPE' "$out")

  assert_contains 'CODE SCOPE (non-test) (1)' "$out" \
    'spec-word: a glob with "spec" inside a common word does not empty the code scope'
  assert_contains 'TEST SCOPE (1)' "$out" 'spec-word: only the real test in the test scope'
  assert_contains 'app/Perspectiva/Chart.php' "$code" 'spec-word: Perspectiva is production code'
  assert_not_contains 'app/Perspectiva/Chart.php' "$tst" 'spec-word: Perspectiva is not a test'
  assert_contains 'tests/FooTest.php' "$tst" 'spec-word: the real test is recognized'
  rm -rf "$r"
}

# Regression: the test globs came from the rules that matched THIS diff only. A diff without
# any test file (the common case of a small diff) found no test rule, fell into the fallback,
# and the fallback reclassified production code as tests — a file's scope depended on which
# OTHER files were in the diff, and the same code was routed two ways in two reviews. Here the
# test rule (`spec/**/*.php`) does NOT match the diff: it must still be the authority, and an
# empty test scope is a legitimate answer — no fallback.
# `tests/legacy/Old.php` is the decoy that makes the preferred path and the fallback
# OBSERVABLY different: the generic fallback would classify it as a test; the repo's rule
# does not.
test_test_rule_applies_without_tests_in_diff() {
  local r out code tst
  r=$(mkfixture)
  mkdir -p "$r/.claude/rules" "$r/spec" "$r/app" "$r/tests/legacy"
  cat > "$r/.claude/rules/spec.md" <<'RULE'
---
paths:
  - "spec/**/*.php"
---
A spec describes observable behavior.
RULE
  cat > "$r/.claude/rules/code.md" <<'RULE'
---
paths:
  - "app/**/*.php"
---
Production code does not call dd().
RULE
  printf '<?php class FooSpec {}\n' > "$r/spec/FooSpec.php"
  printf '<?php class Foo {}\n'     > "$r/app/Foo.php"
  printf '<?php class Old {}\n'     > "$r/tests/legacy/Old.php"
  git -C "$r" add -A && git -C "$r" commit -qm base
  git -C "$r" checkout -qb feat
  # on purpose does NOT touch spec/FooSpec.php: the diff has no test file at all
  printf '<?php class Foo { public function x() {} }\n' > "$r/app/Foo.php"
  printf '<?php class Old { public function y() {} }\n' > "$r/tests/legacy/Old.php"

  out=$(run_build "$r" --base main)
  code=$(section_of 'CODE SCOPE' "$out")
  tst=$(section_of 'TEST SCOPE' "$out")

  assert_contains 'TEST SCOPE (0)' "$out" \
    'preferred: an empty test scope is legitimate when the repository declares a test rule'
  assert_contains 'CODE SCOPE (non-test) (2)' "$out" \
    'preferred: the 2 files of the diff stay in the code scope'
  assert_contains 'app/Foo.php' "$code" 'preferred: production code in the code scope'
  assert_contains 'tests/legacy/Old.php' "$code" \
    'preferred: the repository rule (spec/) wins over the generic fallback (tests/)'
  assert_not_contains 'tests/legacy/Old.php' "$tst" 'preferred: without falling into the fallback'
  rm -rf "$r"
}

# The same case with the Portuguese names that broke it: a test rule declared but not matched
# by the diff, plus a fallback on loose substrings, turned `LatestController` and
# `EspectroController` into "tests" and took them out of the security scope. The
# LatestController had a raw `$_GET` — exactly what the security agent exists to catch.
test_pt_br_production_is_not_test() {
  local r out code tst
  r=$(mkfixture)
  mkdir -p "$r/.claude/rules" "$r/app/Http/Controllers" "$r/tests"
  cat > "$r/.claude/rules/testing.md" <<'RULE'
---
paths:
  - "tests/**/*.php"
---
setUp() declares a : void return type.
RULE
  cat > "$r/.claude/rules/http.md" <<'RULE'
---
paths:
  - "app/Http/Controllers/**/*.php"
---
A controller holds no business rule.
RULE
  printf '<?php class FooTest {}\n'                > "$r/tests/FooTest.php"
  printf '<?php class LatestController {}\n'       > "$r/app/Http/Controllers/LatestController.php"
  printf '<?php class EspectroController {}\n' > "$r/app/Http/Controllers/EspectroController.php"
  git -C "$r" add -A && git -C "$r" commit -qm base
  git -C "$r" checkout -qb feat
  # production only in the diff — no test
  printf '<?php class LatestController { public function q() { return $_GET["id"]; } }\n' \
    > "$r/app/Http/Controllers/LatestController.php"
  printf '<?php class EspectroController { public function q() {} }\n' \
    > "$r/app/Http/Controllers/EspectroController.php"

  out=$(run_build "$r" --base main)
  code=$(section_of 'CODE SCOPE' "$out")
  tst=$(section_of 'TEST SCOPE' "$out")

  assert_contains 'CODE SCOPE (non-test) (2)' "$out" \
    'pt-br: the bugs and security agents do not get an empty scope'
  assert_contains 'TEST SCOPE (0)' "$out" 'pt-br: no test in the diff, none in the scope'
  assert_contains 'app/Http/Controllers/LatestController.php' "$code" \
    'pt-br: LatestController stays in the code scope'
  assert_contains 'app/Http/Controllers/EspectroController.php' "$code" \
    'pt-br: EspectroController stays in the code scope'
  assert_not_contains 'LatestController' "$tst" 'pt-br: LatestController is not a test'
  assert_not_contains 'EspectroController' "$tst" 'pt-br: EspectroController is not a test'
  rm -rf "$r"
}

# Reading EVERY rule of .claude/rules/ to derive the test globs touches the same loop as the
# dead-rule diagnosis, so the diagnosis is covered here.
test_dead_rule_warns() {
  local r out warnings
  r=$(mkfixture)
  mkdir -p "$r/.claude/rules" "$r/app"
  # broken glob (a leading slash, as found in a real rule): matches nothing
  cat > "$r/.claude/rules/entities.md" <<'RULE'
---
paths:
  - "/app/models/**/*.php"
---
A model holds no raw query.
RULE
  cat > "$r/.claude/rules/alive.md" <<'RULE'
---
paths:
  - "app/**/*.php"
---
A live rule, it matches the diff.
RULE
  printf '<?php class Foo {}\n' > "$r/app/Foo.php"
  git -C "$r" add -A && git -C "$r" commit -qm base
  git -C "$r" checkout -qb feat
  printf '<?php class Foo { public function x() {} }\n' > "$r/app/Foo.php"

  out=$(run_build "$r" --base main)
  warnings=$(section_of 'WARNINGS' "$out")

  assert_contains 'WARNINGS (1)' "$out" 'dead-rule: exactly one warning'
  assert_contains 'rule probably dead' "$warnings" 'dead-rule: the dead-rule warning fires'
  assert_contains 'entities.md' "$warnings" 'dead-rule: the warning names the broken rule'
  assert_not_contains 'alive.md' "$warnings" 'dead-rule: a rule that matches the diff is not accused'
  rm -rf "$r"
}

# Regression: a rule whose glob points inside an EXCLUDED tree died silently. The dead-rule
# diagnosis (rightly) does not fire — the glob matches `git ls-files` — and the only signal
# left was the generic "no applicable rule" warning, which SKILL.md turns into "SKIP the rules
# agent" for the WHOLE review. With `docs/**` in EXCLUDE_PATTERNS, this is the realistic case.
test_rule_matching_only_excluded_warns() {
  local r out warnings
  r=$(mkfixture)
  mkdir -p "$r/.claude/rules" "$r/app" "$r/docs/guides"
  cat > "$r/.claude/rules/docs.md" <<'RULE'
---
paths:
  - "docs/**/*.md"
---
A technical document names the module in its title.
RULE
  printf '<?php class A {}\n' > "$r/app/A.php"
  printf '# module\n'         > "$r/docs/guides/module.md"
  git -C "$r" add -A && git -C "$r" commit -qm base
  git -C "$r" checkout -qb feat
  printf '<?php class A { public function x() {} }\n' > "$r/app/A.php"
  printf '# module\none more line\n' > "$r/docs/guides/module.md"

  out=$(run_build "$r" --base main)
  warnings=$(section_of 'WARNINGS' "$out")

  assert_contains 'EXCLUDED (1)' "$out" 'excluded-rule: the doc went to EXCLUDED'
  assert_contains '.claude/rules/docs.md' "$warnings" \
    'excluded-rule: the warning names the rule that died in the exclusion'
  assert_contains 'in EXCLUDED' "$warnings" \
    'excluded-rule: the warning says the rule matched an excluded file, not a generic warning'
  # it must not be mistaken for a dead rule: its glob matches a file of the repository
  assert_not_contains 'rule probably dead' "$warnings" \
    'excluded-rule: a rule matching an excluded file is not accused of being dead'
  rm -rf "$r"
}

# A rule matching an excluded file AND a reviewed file is NOT the case above: it applies to this
# review. The warning there exists for total silence; here it would be noise, and worse, it
# would say "does not apply to this review" about a rule that does.
test_rule_matching_excluded_and_reviewed_does_not_warn() {
  local r out warnings rules
  r=$(mkfixture)
  mkdir -p "$r/.claude/rules" "$r/app" "$r/docs"
  cat > "$r/.claude/rules/md.md" <<'RULE'
---
paths:
  - "**/*.md"
  - "app/**/*.php"
---
Every markdown file has a first-level title.
RULE
  printf '<?php class A {}\n' > "$r/app/A.php"
  printf '# doc\n'            > "$r/docs/guide.md"
  git -C "$r" add -A && git -C "$r" commit -qm base
  git -C "$r" checkout -qb feat
  printf '<?php class A { public function x() {} }\n' > "$r/app/A.php"
  printf '# doc\none more line\n' > "$r/docs/guide.md"

  out=$(run_build "$r" --base main)
  warnings=$(section_of 'WARNINGS' "$out")
  rules=$(section_of 'APPLICABLE RULES' "$out")

  assert_contains 'app/A.php' "$rules" 'excluded-rule-2: the rule still lists the reviewed file'
  assert_not_contains 'in EXCLUDED' "$warnings" \
    'excluded-rule-2: a rule that also matches a reviewed file does not get the exclusion warning'
  rm -rf "$r"
}

test_rule_lists_files
test_scope_without_test_rule
test_glob_with_spec_in_common_word
test_test_rule_applies_without_tests_in_diff
test_pt_br_production_is_not_test
test_dead_rule_warns
test_rule_matching_only_excluded_warns
test_rule_matching_excluded_and_reviewed_does_not_warn

# ------------------------------------------- the fingerprint covers the FILTERED diff
# The FINGERPRINT covers what was REVIEWED, not what was ignored. Moving the computation before
# the exclusion kept every other test green, and the regression is visible to the user: the
# fingerprint would move on every composer.lock change, and the fingerprint step of SKILL.md
# would announce "the tree moved during the review" with nothing reviewable changed — eroding
# the very mechanism that guards against moving code.
test_fingerprint_ignores_excluded_file() {
  local r out fp1 fp2 fp3 excluded
  r=$(mkfixture)
  mkdir -p "$r/app"
  printf '{ "packages": [] }\n' > "$r/composer.lock"
  printf '<?php class Foo {}\n'  > "$r/app/Foo.php"
  git -C "$r" add -A && git -C "$r" commit -qm base
  git -C "$r" checkout -qb feat
  printf '<?php class Foo { public function bar() {} }\n' > "$r/app/Foo.php"

  fp1=$(printf '%s' "$(run_build "$r" --base main)" | awk '/^FINGERPRINT: /{print $2}')

  # touches ONLY the excluded file
  printf '{ "packages": ["new"] }\n' > "$r/composer.lock"
  out=$(run_build "$r" --base main)
  fp2=$(printf '%s' "$out" | awk '/^FINGERPRINT: /{print $2}')
  excluded=$(section_of 'EXCLUDED' "$out")

  # without this assert the test would pass for free if the lock never entered the raw diff
  assert_contains 'composer.lock' "$excluded" \
    'fingerprint: the lock really changed and was excluded in this run'
  if [ -n "$fp1" ] && [ "$fp1" = "$fp2" ]; then ok
  else fail "fingerprint: moved because of an EXCLUDED file ($fp1 -> $fp2)"; fi

  # mandatory counterpart: touching what IS reviewed MUST move the fingerprint. Without it, a
  # constant fingerprint would pass the assert above.
  printf '<?php class Foo { public function baz() {} }\n' > "$r/app/Foo.php"
  fp3=$(printf '%s' "$(run_build "$r" --base main)" | awk '/^FINGERPRINT: /{print $2}')
  if [ -n "$fp3" ] && [ "$fp3" != "$fp1" ]; then ok
  else fail "fingerprint: did NOT move when the reviewed file changed ($fp1)"; fi

  rm -rf "$r"
}

test_fingerprint_ignores_excluded_file

# ------------------------------------------------ script output contract: exit codes, --fingerprint
# `run_build` uses command substitution and never looked at `$?`: the three exit codes that
# SKILL.md documents — and that the orchestrator branches on — had no exercise. Same for
# `--fingerprint`, which the fingerprint step depends on to detect a moved tree: it only works
# if it reproduces the value the manifest printed.
test_exit_codes() {
  local r st
  r=$(mkfixture)
  git -C "$r" checkout -qb feat

  st=$(run_build_status "$r" --base main)
  if [ "$st" = 3 ]; then ok
  else fail "exit: an empty diff should exit 3 (NOTHING TO REVIEW), got $st"; fi

  st=$(run_build_status "$r" --option-that-does-not-exist)
  if [ "$st" = 1 ]; then ok
  else fail "exit: an unknown option should exit 1, got $st"; fi

  # and the 0 of the normal path, otherwise an unconditional `exit 3` would pass the first assert
  mkdir -p "$r/app"
  printf '<?php class Foo {}\n' > "$r/app/Foo.php"
  git -C "$r" add -A && git -C "$r" commit -qm base
  printf '<?php class Foo { public function bar() {} }\n' > "$r/app/Foo.php"
  st=$(run_build_status "$r" --base main)
  if [ "$st" = 0 ]; then ok
  else fail "exit: a diff with content should exit 0, got $st"; fi

  rm -rf "$r"
}

test_fingerprint_flag_reproduces_the_manifest() {
  local r out fp_manifest fp_flag
  r=$(mkfixture)
  mkdir -p "$r/app"
  printf '<?php class Foo {}\n' > "$r/app/Foo.php"
  git -C "$r" add -A && git -C "$r" commit -qm base
  git -C "$r" checkout -qb feat
  printf '<?php class Foo { public function bar() {} }\n' > "$r/app/Foo.php"
  printf 'untracked\n' > "$r/app/New.txt"

  out=$(run_build "$r" --base main)
  fp_manifest=$(printf '%s' "$out" | awk '/^FINGERPRINT: /{print $2}')
  fp_flag=$(run_build "$r" --fingerprint --base main)

  if [ -n "$fp_manifest" ] && [ "$fp_flag" = "$fp_manifest" ]; then ok
  else fail "exit: --fingerprint ($fp_flag) does not reproduce the manifest's ($fp_manifest)"; fi
  # --fingerprint prints ONLY the fingerprint: no manifest section leaks
  assert_not_contains 'CHANGED FILES' "$fp_flag" \
    'exit: --fingerprint prints only the fingerprint, not the manifest'
  rm -rf "$r"
}

test_exit_codes
test_fingerprint_flag_reproduces_the_manifest

# ------------------------------------------------------------------------- --out
# The whole manifest on stdout entered the main session's context on every review — map,
# scopes, dozens of paths only the agents use. With --out the manifest goes to a file and
# stdout carries only what the orchestrator decides with.

# fixture_with_rule -> repository with a rule matching app/Http/Controllers and a changed
# controller (no CLAUDE.md, so the "no applicable rule..." warning does NOT show: there is a rule).
fixture_with_rule() {
  local r
  r=$(mkfixture)
  mkdir -p "$r/.claude/rules" "$r/app/Http/Controllers"
  cat > "$r/.claude/rules/http.md" <<'RULE'
---
paths:
  - "app/Http/Controllers/**/*.php"
---
A controller holds no business rule.
RULE
  printf '<?php class FooController {}\n' > "$r/app/Http/Controllers/FooController.php"
  git -C "$r" add -A && git -C "$r" commit -qm base
  git -C "$r" checkout -qb feat
  printf '<?php class FooController { public function bar() {} }\n' \
    > "$r/app/Http/Controllers/FooController.php"
  printf '%s' "$r"
}

test_out_writes_manifest_and_summarizes_stdout() {
  local r m out man
  r=$(fixture_with_rule)
  m="$r.manifest"

  out=$(run_build "$r" --base main --out "$m")
  man=$(cat "$m" 2>/dev/null)

  # the file holds the whole manifest
  assert_contains 'CHANGED FILES' "$man" 'out: the file has CHANGED FILES'
  assert_contains 'READ MAP'      "$man" 'out: the file has READ MAP'
  assert_contains 'CODE SCOPE'    "$man" 'out: the file has CODE SCOPE'
  assert_contains 'TEST SCOPE'    "$man" 'out: the file has TEST SCOPE'

  # stdout does NOT have the heavy sections
  assert_not_contains 'CHANGED FILES' "$out" 'out: stdout without CHANGED FILES'
  assert_not_contains 'READ MAP'      "$out" 'out: stdout without READ MAP'
  assert_not_contains 'CODE SCOPE'    "$out" 'out: stdout without CODE SCOPE'
  assert_not_contains 'TEST SCOPE'    "$out" 'out: stdout without TEST SCOPE'
  # nor the list of files per rule (indented under the rule): only the rule's path
  assert_not_contains 'FooController.php'  "$out" 'out: stdout does not list files'

  # stdout has what the orchestrator needs
  assert_contains "MANIFEST: $m" "$out" 'out: stdout points to the manifest file'
  assert_contains 'FILES: 1 changed, 0 untracked, 0 excluded' "$out" \
    'out: stdout has the counts'
  assert_contains 'http.md' "$(section_of 'APPLICABLE RULES' "$out")" \
    'out: stdout lists the rule that matched'

  # the summary's FINGERPRINT and DIFF are the file's (one snapshot, not two)
  local fp_out fp_man diff_out diff_man
  fp_out=$(printf '%s' "$out" | awk '/^FINGERPRINT: /{print $2}')
  fp_man=$(printf '%s' "$man" | awk '/^FINGERPRINT: /{print $2}')
  diff_out=$(printf '%s' "$out" | awk '/^DIFF: /{print $2}')
  diff_man=$(printf '%s' "$man" | awk '/^DIFF: /{print $2}')
  if [ -n "$fp_out" ] && [ "$fp_out" = "$fp_man" ]; then ok
  else fail "out: summary FINGERPRINT ($fp_out) != the file's ($fp_man)"; fi
  if [ -n "$diff_out" ] && [ "$diff_out" = "$diff_man" ] && [ -s "$diff_out" ]; then ok
  else fail "out: summary DIFF ($diff_out) != the file's ($diff_man), or empty"; fi

  rm -rf "$r" "$m"
}

test_out_warnings_reach_the_summary() {
  local r m out
  r=$(mkfixture)          # no rule and no CLAUDE.md -> the "SKIP the rules agent" warning
  m="$r.manifest"
  mkdir -p "$r/app"
  printf '<?php class Foo {}\n' > "$r/app/Foo.php"
  git -C "$r" add -A && git -C "$r" commit -qm base
  git -C "$r" checkout -qb feat
  printf '<?php class Foo { public function bar() {} }\n' > "$r/app/Foo.php"

  out=$(run_build "$r" --base main --out "$m")
  assert_contains 'no applicable rule and no CLAUDE.md' \
    "$(section_of 'WARNINGS' "$out")" 'out: the warning reaches the summary, in WARNINGS'
  assert_contains 'APPLICABLE RULES (0)' "$out" 'out: the summary declares zero rules'
  rm -rf "$r" "$m"
}

test_without_out_stdout_is_the_manifest() {
  local r m without with
  r=$(fixture_with_rule)
  m="$r.manifest"
  # DIFF: is a new mktemp on every run; everything else must be identical
  without=$(run_build "$r" --base main | grep -v '^DIFF: ')
  run_build "$r" --base main --out "$m" >/dev/null
  with=$(grep -v '^DIFF: ' "$m")
  if [ -n "$without" ] && [ "$without" = "$with" ]; then ok
  else fail 'out: without --out, stdout should be the same manifest that --out writes'; fi
  rm -rf "$r" "$m"
}

test_out_empty_diff() {
  local r m st out
  r=$(mkfixture)
  m="$r.manifest"
  git -C "$r" checkout -qb feat
  st=$(run_build_status "$r" --base main --out "$m")
  if [ "$st" = 3 ]; then ok
  else fail "out: an empty diff with --out should exit 3, got $st"; fi
  out=$(run_build "$r" --base main --out "$m")
  assert_contains 'NOTHING TO REVIEW' "$out" 'out: NOTHING TO REVIEW reaches stdout with --out'
  rm -rf "$r" "$m"
}

test_out_invalid_destination() {
  local r st out
  r=$(fixture_with_rule)

  st=$(run_build_status "$r" --base main --out "$r/does/not/exist/manifest")
  if [ "$st" = 1 ]; then ok
  else fail "out: a destination in a missing directory should exit 1, got $st"; fi
  out=$(run_build "$r" --base main --out "$r/does/not/exist/manifest")
  assert_contains 'could not write the manifest' "$out" 'out: the error says it did not write'
  assert_not_contains 'FINGERPRINT:' "$out" 'out: the error prints no summary that looks valid'

  st=$(run_build_status "$r" --base main --out)
  if [ "$st" = 1 ]; then ok
  else fail "out: --out without a value should exit 1, got $st"; fi
  # --out followed by another flag does not swallow the flag as a path
  st=$(run_build_status "$r" --out --base main)
  if [ "$st" = 1 ]; then ok
  else fail "out: --out followed by a flag should exit 1, got $st"; fi

  # Regression: the Bash tool of Claude Code does not keep variables between calls —
  # `M=$(mktemp ...)` in one call and `--out "$M"` in another makes `$M` arrive empty.
  # `--out ""` silently fell back to the no --out mode (whole manifest on stdout, exit 0)
  # instead of reporting the error.
  st=$(run_build_status "$r" --base main --out "")
  if [ "$st" = 1 ]; then ok
  else fail "out: --out with an empty value should exit 1, got $st"; fi

  rm -rf "$r"
}

test_out_writes_manifest_and_summarizes_stdout
test_out_warnings_reach_the_summary
test_without_out_stdout_is_the_manifest
test_out_empty_diff
test_out_invalid_destination

# ------------------------------------------------------------- code root and test rules
# The agents need one instruction for where code lives in every mode, so CODE ROOT is printed
# in local and PR mode too (the repository root there).
test_code_root_in_every_output() {
  local r m out man root
  r=$(fixture_with_rule)
  m="$r.manifest"
  root=$(cd "$r" && pwd -P)
  out=$(run_build "$r" --base main --out "$m")
  man=$(cat "$m" 2>/dev/null)
  assert_contains "CODE ROOT: $root" "$out" 'code-root: the summary names the code root'
  assert_contains "CODE ROOT: $root" "$man" 'code-root: the manifest names the code root'
  rm -rf "$r" "$m"
}

# The coverage pass looks for the project's written test policy. A diff that touches no test
# file never lists the test rules under APPLICABLE RULES, so TEST RULES lists them anyway.
test_test_rules_lists_unmatched_test_rule() {
  local r out tr ar
  r=$(mkfixture)
  mkdir -p "$r/.claude/rules" "$r/app" "$r/tests"
  cat > "$r/.claude/rules/testing.md" <<'RULE'
---
paths:
  - "tests/**/*.php"
---
Every back-end change ships with a test that fails without it.
RULE
  printf '<?php class Foo {}\n'     > "$r/app/Foo.php"
  printf '<?php class FooTest {}\n' > "$r/tests/FooTest.php"
  git -C "$r" add -A && git -C "$r" commit -qm base
  git -C "$r" checkout -qb feat
  printf '<?php class Foo { public function x() {} }\n' > "$r/app/Foo.php"

  out=$(run_build "$r" --base main)
  tr=$(section_of 'TEST RULES' "$out")
  ar=$(section_of 'APPLICABLE RULES' "$out")
  assert_contains 'TEST RULES (1)' "$tr" 'test-rules: counts the test rule'
  assert_contains '.claude/rules/testing.md' "$tr" 'test-rules: lists a test rule the diff does not match'
  assert_not_contains 'testing.md' "$ar" 'test-rules: the rule is still not an applicable rule'
  rm -rf "$r"
}

test_test_rules_none() {
  local r out
  r=$(fixture_with_rule)
  out=$(run_build "$r" --base main)
  assert_contains '(none)' "$(section_of 'TEST RULES' "$out")" 'test-rules: an empty section says (none)'
  rm -rf "$r"
}

# ------------------------------------------------------------- bases without a remote
# A project that lives only on the developer's machine has no origin at all: the base falls
# back to the local main or master.
test_base_without_remote_is_main() {
  local r out
  r=$(fixture_with_rule)
  out=$(run_build "$r")
  assert_contains 'BASE: main (merge-base' "$out" 'no-remote: the base is the local main'
  rm -rf "$r"
}

test_base_without_remote_is_master() {
  local r out
  r=$(mktemp -d)
  git -C "$r" init -q -b master
  git -C "$r" config user.email t@example.com
  git -C "$r" config user.name t
  printf 'initial\n' > "$r/README.md"
  git -C "$r" add -A && git -C "$r" commit -qm initial
  git -C "$r" checkout -qb feat
  printf 'changed\n' > "$r/README.md"
  out=$(run_build "$r")
  assert_contains 'BASE: master (merge-base' "$out" 'no-remote: the base is the local master'
  rm -rf "$r"
}

test_no_base_at_all_fails() {
  local r st out
  r=$(mktemp -d)
  git -C "$r" init -q -b trunk
  git -C "$r" config user.email t@example.com
  git -C "$r" config user.name t
  printf 'initial\n' > "$r/README.md"
  git -C "$r" add -A && git -C "$r" commit -qm initial
  printf 'changed\n' > "$r/README.md"
  st=$(run_build_status "$r")
  if [ "$st" = 1 ]; then ok
  else fail "no-remote: without main, master or origin the script should exit 1, got $st"; fi
  out=$(run_build "$r")
  assert_contains '--base' "$out" 'no-remote: the error tells to pass --base'
  rm -rf "$r"
}

# On main with nothing uncommitted there is nothing to review locally; the user who wanted past
# commits learns how to ask for them.
test_empty_diff_hints_range_mode() {
  local r st out
  r=$(mkfixture)
  st=$(run_build_status "$r")
  if [ "$st" = 3 ]; then ok
  else fail "hint: an empty diff on main should exit 3, got $st"; fi
  out=$(run_build "$r")
  assert_contains '--base <A> --head <B>' "$out" 'hint: the empty-diff message points to range mode'
  rm -rf "$r"
}

# Regression: has_paths_key always returned 1 (awk's END overrode the `exit 0`), so a rule with an
# inline list (`paths: ["app/**"]`) silently became a global-scope rule, applied to every changed
# file, with no warning saying why.
test_inline_paths_list_warns() {
  local r out
  r=$(mkfixture)
  mkdir -p "$r/.claude/rules" "$r/app"
  printf -- '---\npaths: ["app/**"]\n---\nAn inline list.\n' > "$r/.claude/rules/inline.md"
  printf '<?php class Foo {}\n' > "$r/app/Foo.php"
  git -C "$r" add -A && git -C "$r" commit -qm base
  git -C "$r" checkout -qb feat
  printf '<?php class Foo { public function x() {} }\n' > "$r/app/Foo.php"
  out=$(run_build "$r" --base main)
  assert_contains 'only YAML block lists are supported' "$(section_of 'WARNINGS' "$out")" \
    'inline-paths: an inline paths list is reported instead of silently going global'
  rm -rf "$r"
}

# Regression: the user's git config reached the diff the script parses. `color.ui=always` filled
# it with escape codes (every file came out "no hunk"), `diff.noprefix` cut two characters off
# every path and let excluded files leak into the frozen diff.
test_user_diff_config_is_ignored() {
  local r out map diffbody x y root
  r=$(mkfixture)
  mkdir -p "$r/app"
  printf '{ "packages": [] }\n' > "$r/composer.lock"
  awk 'BEGIN { print "<?php"; for (i = 2; i <= 600; i++) print "// line " i }' > "$r/app/Big.php"
  git -C "$r" add -A && git -C "$r" commit -qm base
  x=$(git -C "$r" rev-parse HEAD)
  git -C "$r" config color.ui always
  git -C "$r" config color.diff always
  git -C "$r" config diff.noprefix true
  git -C "$r" config diff.mnemonicPrefix true
  git -C "$r" checkout -qb feat
  printf '{ "packages": ["new"] }\n' > "$r/composer.lock"
  awk 'NR == 300 { print "// TOUCHED"; next } { print }' "$r/app/Big.php" > "$r/t" && mv "$r/t" "$r/app/Big.php"

  out=$(run_build "$r" --base main)
  map=$(section_of 'READ MAP' "$out" | grep -F 'app/Big.php')
  diffbody=$(cat "$(printf '%s' "$out" | awk '/^DIFF: /{print $2}')")
  if printf '%s' "$map" | grep -qE '600 \| 29[0-9]-30[0-9]'; then ok
  else fail "diff-config: the read map lost the range of app/Big.php under the user's diff config: $map"; fi
  assert_not_contains 'packages' "$diffbody" "diff-config: an excluded file leaks into the frozen diff under the user's diff config"

  git -C "$r" add -A && git -C "$r" commit -qm change
  y=$(git -C "$r" rev-parse HEAD)
  out=$(run_build "$r" --base "$x" --head "$y")
  root=$(code_root_of "$out")
  map=$(section_of 'READ MAP' "$out" | grep -F 'app/Big.php')
  if printf '%s' "$map" | grep -qE '600 \| 29[0-9]-30[0-9]'; then ok
  else fail "diff-config: the range-mode read map lost the range under the user's diff config: $map"; fi
  run_build "$r" --cleanup "$root" >/dev/null
  rm -rf "$r"
}

# .claude/CLAUDE.md is a documented place for project instructions. A repository that keeps its
# conventions only there got "no applicable rule and no CLAUDE.md" and lost the rules agent.
test_dot_claude_claude_md_is_found() {
  local r out
  r=$(mkfixture)
  mkdir -p "$r/.claude" "$r/app"
  printf '# Conventions\n' > "$r/.claude/CLAUDE.md"
  printf '<?php class Foo {}\n' > "$r/app/Foo.php"
  git -C "$r" add -A && git -C "$r" commit -qm base
  git -C "$r" checkout -qb feat
  printf '<?php class Foo { public function x() {} }\n' > "$r/app/Foo.php"
  out=$(run_build "$r" --base main)
  assert_contains '.claude/CLAUDE.md' "$(section_of 'CLAUDE.md' "$out")" 'dot-claude: .claude/CLAUDE.md is listed'
  assert_not_contains 'no applicable rule and no CLAUDE.md' "$out" 'dot-claude: the rules agent is not skipped'
  rm -rf "$r"
}

test_inline_paths_list_warns
test_user_diff_config_is_ignored
test_dot_claude_claude_md_is_found

test_code_root_in_every_output
test_test_rules_lists_unmatched_test_rule
test_test_rules_none
test_base_without_remote_is_main
test_base_without_remote_is_master
test_no_base_at_all_fails
test_empty_diff_hints_range_mode

# ------------------------------------------------------------- range mode (--head)
# Reviews only the commits A..B of the past, reading code from a temporary detached worktree of
# B, with the rules of the current working tree. The project's working tree, index, HEAD and
# branches must never change.

# snapshot <repo> -> the state range mode must never change
snapshot() {
  git -C "$1" status --porcelain=v1 -uall
  git -C "$1" rev-parse HEAD
  git -C "$1" for-each-ref
  git -C "$1" stash list
  git -C "$1" ls-files -s
}

# code_root_of <output> -> the CODE ROOT value
code_root_of() {
  printf '%s' "$1" | awk '/^CODE ROOT: /{ sub(/^CODE ROOT: /, ""); print; exit }'
}

# worktree_count <repo> -> how many worktrees git knows about
worktree_count() {
  git -C "$1" worktree list --porcelain | grep -c '^worktree '
}

# fixture_range -> a repository on main with commit X (app/A.php grows to 500 lines) and commit
# Y (adds app/B.php), then a dirty working tree: app/A.php back to 10 lines, app/C.php changed,
# app/D.php untracked. Prints "<repo> <X> <Y>".
fixture_range() {
  local r x y
  r=$(mkfixture)
  mkdir -p "$r/app"
  awk 'BEGIN { for (i = 1; i <= 10; i++) print "// line " i }' > "$r/app/A.php"
  printf '<?php class C {}\n' > "$r/app/C.php"
  git -C "$r" add -A && git -C "$r" commit -qm base
  awk 'BEGIN { for (i = 1; i <= 500; i++) print "// line " i }' > "$r/app/A.php"
  git -C "$r" add -A && git -C "$r" commit -qm X
  x=$(git -C "$r" rev-parse HEAD)
  printf '<?php class B {}\n' > "$r/app/B.php"
  git -C "$r" add -A && git -C "$r" commit -qm Y
  y=$(git -C "$r" rev-parse HEAD)
  awk 'BEGIN { for (i = 1; i <= 10; i++) print "// line " i }' > "$r/app/A.php"
  printf '<?php class C { public function x() {} }\n' > "$r/app/C.php"
  printf '<?php class D {}\n' > "$r/app/D.php"
  printf '%s %s %s' "$r" "$x" "$y"
}

test_range_reviews_only_the_commits() {
  local r x y m out man changed
  set -- $(fixture_range); r=$1; x=$2; y=$3
  m="$r.manifest"
  out=$(run_build "$r" --base "$x~1" --head "$y" --out "$m")
  man=$(cat "$m" 2>/dev/null)
  changed=$(section_of 'CHANGED FILES' "$man")
  assert_contains 'MODE: range' "$out" 'range: the summary says MODE: range'
  assert_contains 'app/A.php' "$changed" 'range: a file of commit X is in the review'
  assert_contains 'app/B.php' "$changed" 'range: a file of commit Y is in the review'
  assert_not_contains 'app/C.php' "$changed" 'range: an uncommitted change is not in the review'
  assert_not_contains 'app/D.php' "$man" 'range: an untracked file is not in the review'
  assert_not_contains 'UNTRACKED (' "$man" 'range: no UNTRACKED section'
  assert_contains 'FILES: 2 changed, 0 untracked, 0 excluded' "$out" 'range: the counts cover the commits only'
  run_build "$r" --cleanup "$(code_root_of "$out")" >/dev/null
  rm -rf "$r" "$m"
}

test_range_worktree_is_detached_at_head() {
  local r x y out root
  set -- $(fixture_range); r=$1; x=$2; y=$3
  out=$(run_build "$r" --base "$x~1" --head "$y")
  root=$(code_root_of "$out")
  if [ -n "$root" ] && [ "$root" != "$(cd "$r" && pwd -P)" ] && [ -d "$root" ]; then ok
  else fail "range: CODE ROOT should be a separate directory, got '$root'"; fi
  if [ "$(git -C "$root" rev-parse HEAD 2>/dev/null)" = "$y" ]; then ok
  else fail 'range: the review worktree is not at the head commit'; fi
  if git -C "$root" symbolic-ref -q HEAD >/dev/null 2>&1; then
    fail 'range: the review worktree should be detached, it is on a branch'
  else ok; fi
  run_build "$r" --cleanup "$root" >/dev/null
  rm -rf "$r"
}

test_range_read_map_counts_from_head() {
  local r x y out line
  set -- $(fixture_range); r=$1; x=$2; y=$3
  out=$(run_build "$r" --base "$x~1" --head "$y")
  line=$(section_of 'READ MAP' "$out" | grep -F 'app/A.php')
  assert_contains '500' "$line" 'range: the read map counts the lines of the head commit (500), not the working tree (10)'
  assert_not_contains 'small file' "$line" 'range: the 500-line file of the head commit is not a small file'
  run_build "$r" --cleanup "$(code_root_of "$out")" >/dev/null
  rm -rf "$r"
}

test_range_rules_come_from_working_tree() {
  local r x y out root real
  set -- $(fixture_range); r=$1; x=$2; y=$3
  real=$(cd "$r" && pwd -P)
  mkdir -p "$r/.claude/rules"
  cat > "$r/.claude/rules/app.md" <<'RULE'
---
paths:
  - "app/**"
---
A rule written after the reviewed commits.
RULE
  printf '# Conventions written today\n' > "$r/CLAUDE.md"
  out=$(run_build "$r" --base "$x~1" --head "$y")
  root=$(code_root_of "$out")
  assert_contains "RULES FROM: $real (working tree)" "$out" 'range: the manifest says where the rules come from'
  assert_contains "$real/.claude/rules/app.md" "$(section_of 'APPLICABLE RULES' "$out")" \
    'range: a rule that exists only in the working tree applies, with an absolute path'
  assert_contains "$real/CLAUDE.md" "$(section_of 'CLAUDE.md' "$out")" \
    'range: the CLAUDE.md of the working tree is listed with an absolute path'
  assert_contains "HEAD: $y (" "$out" 'range: the manifest names the head'
  run_build "$r" --cleanup "$root" >/dev/null
  rm -rf "$r"
}

test_range_leaves_project_untouched() {
  local r x y out before after
  set -- $(fixture_range); r=$1; x=$2; y=$3
  before=$(snapshot "$r")
  out=$(run_build "$r" --base "$x~1" --head "$y")
  run_build "$r" --cleanup "$(code_root_of "$out")" >/dev/null
  after=$(snapshot "$r")
  if [ -n "$before" ] && [ "$before" = "$after" ]; then ok
  else fail 'range: the project status, HEAD, refs, stash or index changed'; fi
  if [ "$(worktree_count "$r")" = 1 ]; then ok
  else fail 'range: a worktree was left behind after --cleanup'; fi
  rm -rf "$r"
}

test_range_does_not_run_hooks() {
  local r x y out root
  set -- $(fixture_range); r=$1; x=$2; y=$3
  printf '#!/bin/sh\ntouch "%s/HOOK_RAN"\n' "$r" > "$r/.git/hooks/post-checkout"
  chmod +x "$r/.git/hooks/post-checkout"
  out=$(run_build "$r" --base "$x~1" --head "$y")
  root=$(code_root_of "$out")
  if [ ! -e "$r/HOOK_RAN" ]; then ok
  else fail 'range: creating the review worktree ran the project hooks'; fi
  run_build "$r" --cleanup "$root" >/dev/null
  rm -rf "$r"
}

test_range_cleanup_removes_worktree() {
  local r x y out root st
  set -- $(fixture_range); r=$1; x=$2; y=$3
  out=$(run_build "$r" --base "$x~1" --head "$y")
  root=$(code_root_of "$out")
  st=$(run_build_status "$r" --cleanup "$root")
  if [ "$st" = 0 ]; then ok
  else fail "cleanup: removing the review worktree should exit 0, got $st"; fi
  if [ -n "$root" ] && [ ! -e "$root" ]; then ok
  else fail "cleanup: the worktree directory still exists: $root"; fi
  assert_not_contains "$root" "$(git -C "$r" worktree list)" 'cleanup: git no longer lists the worktree'
  rm -rf "$r"
}

test_cleanup_refuses_foreign_path() {
  local r st out other stray
  r=$(mkfixture)
  other="$r.other"
  git -C "$r" worktree add -q "$other" -b other
  stray=$(mktemp -d)

  st=$(run_build_status "$r" --cleanup "$r")
  if [ "$st" = 1 ]; then ok
  else fail "cleanup: the repository itself must be refused, got exit $st"; fi
  out=$(run_build "$r" --cleanup "$other")
  assert_contains 'not a worktree created by this script' "$out" 'cleanup: a worktree of the user is refused'
  if [ -d "$other" ] && [ "$(worktree_count "$r")" = 2 ]; then ok
  else fail "cleanup: the user's own worktree was removed"; fi
  st=$(run_build_status "$r" --cleanup "$stray")
  if [ "$st" = 1 ] && [ -d "$stray" ]; then ok
  else fail "cleanup: a directory that is not a worktree must be refused and kept, got exit $st"; fi

  git -C "$r" worktree remove --force "$other"
  rm -rf "$r" "$stray"
}

test_range_errors() {
  local r x y st out
  set -- $(fixture_range); r=$1; x=$2; y=$3
  st=$(run_build_status "$r" --head "$y")
  out=$(run_build "$r" --head "$y")
  if [ "$st" = 1 ]; then ok; else fail "range-errors: --head without --base should exit 1, got $st"; fi
  assert_contains '--head requires --base' "$out" 'range-errors: says --head requires --base'

  st=$(run_build_status "$r" 123 --base main --head "$y")
  out=$(run_build "$r" 123 --base main --head "$y")
  if [ "$st" = 1 ]; then ok; else fail "range-errors: --head with a PR should exit 1, got $st"; fi
  assert_contains '--head cannot be used with a PR' "$out" 'range-errors: says --head cannot be used with a PR'

  st=$(run_build_status "$r" --base main --head no-such-ref)
  out=$(run_build "$r" --base main --head no-such-ref)
  if [ "$st" = 1 ]; then ok; else fail "range-errors: an unknown head should exit 1, got $st"; fi
  assert_contains "head 'no-such-ref' does not exist" "$out" 'range-errors: names the unknown head'

  if [ "$(worktree_count "$r")" = 1 ]; then ok
  else fail 'range-errors: an error left a worktree behind'; fi
  rm -rf "$r"
}

test_range_worktree_removed_on_error() {
  local r x y st
  set -- $(fixture_range); r=$1; x=$2; y=$3
  # the manifest is written after the worktree exists: a missing directory fails there
  st=$(run_build_status "$r" --base "$x~1" --head "$y" --out "$r/does/not/exist/manifest")
  if [ "$st" = 1 ]; then ok; else fail "range-error: should exit 1, got $st"; fi
  if [ "$(worktree_count "$r")" = 1 ]; then ok
  else fail 'range-error: the review worktree was not removed after the error'; fi
  rm -rf "$r"
}

test_range_fingerprint_flag_matches() {
  local r x y out fp_summary fp_flag
  set -- $(fixture_range); r=$1; x=$2; y=$3
  out=$(run_build "$r" --base "$x~1" --head "$y")
  fp_summary=$(printf '%s' "$out" | awk '/^FINGERPRINT: /{print $2}')
  fp_flag=$(run_build "$r" --fingerprint --base "$x~1" --head "$y")
  if [ -n "$fp_summary" ] && [ "$fp_flag" = "$fp_summary" ]; then ok
  else fail "range-fp: --fingerprint ($fp_flag) does not reproduce the summary's ($fp_summary)"; fi
  assert_contains "$(git -C "$r" rev-parse --short "$y")-" "$fp_flag" 'range-fp: starts with the head commit'
  if [ "$(worktree_count "$r")" = 2 ]; then ok
  else fail 'range-fp: --fingerprint should not create a worktree'; fi
  run_build "$r" --cleanup "$(code_root_of "$out")" >/dev/null
  rm -rf "$r"
}

# -- inputs the spec implies but does not name
test_range_empty_exits_3_without_worktree() {
  local r x y st out
  set -- $(fixture_range); r=$1; x=$2; y=$3
  st=$(run_build_status "$r" --base "$y" --head "$y")
  out=$(run_build "$r" --base "$y" --head "$y")
  if [ "$st" = 3 ]; then ok; else fail "range-empty: an empty range should exit 3, got $st"; fi
  assert_contains '--base <A> --head <B>' "$out" 'range-empty: the hint is printed'
  if [ "$(worktree_count "$r")" = 1 ]; then ok
  else fail 'range-empty: an empty range left a worktree behind'; fi
  rm -rf "$r"
}

test_range_from_linked_worktree() {
  local r x y lw out root st before after
  set -- $(fixture_range); r=$1; x=$2; y=$3
  lw="$r.lw"
  git -C "$r" worktree add -q "$lw" -b lw "$y"
  before=$(snapshot "$lw")
  out=$(run_build "$lw" --base "$x~1" --head "$y")
  root=$(code_root_of "$out")
  if [ -n "$root" ] && [ -d "$root" ]; then ok
  else fail 'range-linked: no review worktree from inside a linked worktree'; fi
  st=$(run_build_status "$lw" --cleanup "$root")
  if [ "$st" = 0 ] && [ ! -e "$root" ]; then ok
  else fail "range-linked: --cleanup from a linked worktree should remove it, got exit $st"; fi
  after=$(snapshot "$lw")
  if [ "$before" = "$after" ] && [ -d "$lw" ]; then ok
  else fail 'range-linked: the linked worktree changed'; fi
  git -C "$r" worktree remove --force "$lw"
  rm -rf "$r"
}

test_range_head_is_checked_out_branch() {
  local r st out
  r=$(fixture_with_rule)
  git -C "$r" add -A && git -C "$r" commit -qm 'controller change'
  st=$(run_build_status "$r" --base feat~1 --head feat)
  if [ "$st" = 0 ]; then ok
  else fail "range-checked-out: --head naming the current branch should work, got exit $st"; fi
  out=$(run_build "$r" --base feat~1 --head feat)
  run_build "$r" --cleanup "$(code_root_of "$out")" >/dev/null
  # the first run's worktree too
  git -C "$r" worktree list --porcelain | awk '/^worktree /{print $2}' | grep 'by-the-book-head\.' \
    | while IFS= read -r w; do git -C "$r" worktree remove --force "$w"; done
  rm -rf "$r"
}

test_range_two_runs_do_not_collide() {
  local r x y out1 out2 root1 root2
  set -- $(fixture_range); r=$1; x=$2; y=$3
  out1=$(run_build "$r" --base "$x~1" --head "$y")
  out2=$(run_build "$r" --base "$x~1" --head "$y")
  root1=$(code_root_of "$out1"); root2=$(code_root_of "$out2")
  if [ -n "$root1" ] && [ -n "$root2" ] && [ "$root1" != "$root2" ]; then ok
  else fail 'range-two-runs: two runs share a review worktree'; fi
  run_build "$r" --cleanup "$root1" >/dev/null
  if [ -d "$root2" ] && [ "$(worktree_count "$r")" = 2 ]; then ok
  else fail 'range-two-runs: removing the first worktree touched the second'; fi
  run_build "$r" --cleanup "$root2" >/dev/null
  rm -rf "$r"
}

test_range_non_ascii_file_counted() {
  local r a b out line
  r=$(mkfixture)
  a=$(git -C "$r" rev-parse HEAD)
  mkdir -p "$r/app"
  awk 'BEGIN { for (i = 1; i <= 500; i++) print "// line " i }' > "$r/app/Ação.php"
  git -C "$r" add -A && git -C "$r" commit -qm 'non-ascii'
  b=$(git -C "$r" rev-parse HEAD)
  out=$(run_build "$r" --base "$a" --head "$b")
  line=$(section_of 'READ MAP' "$out" | grep -F 'Ação.php')
  assert_contains '500' "$line" 'range-non-ascii: the read map counts the non-ASCII file in the worktree'
  assert_not_contains '(missing on disk)' "$line" 'range-non-ascii: the non-ASCII file is found on disk'
  run_build "$r" --cleanup "$(code_root_of "$out")" >/dev/null
  rm -rf "$r"
}

# Regression: bash 3.2 does not run the EXIT trap when the script dies from an untrapped signal.
# An interrupted run (Esc, a Bash-tool timeout) left its worktree registered, and the session
# never learned the path because the summary had not been printed yet.
test_range_interrupted_run_removes_worktree() {
  local r x y shim real_find pid i
  set -- $(fixture_range); r=$1; x=$2; y=$3
  mkdir -p "$r/.claude/rules"
  printf -- '---\npaths:\n  - "app/**"\n---\nA rule.\n' > "$r/.claude/rules/app.md"
  # `find` runs after the worktree exists: a slow find leaves time to interrupt the script there
  shim=$(mktemp -d)
  real_find=$(command -v find)
  printf '#!/bin/sh\nsleep 3\nexec "%s" "$@"\n' "$real_find" > "$shim/find"
  chmod +x "$shim/find"
  ( cd "$r" && PATH="$shim:$PATH" exec bash "$BUILD" --base "$x~1" --head "$y" ) >/dev/null 2>&1 &
  pid=$!
  i=0
  while [ "$(worktree_count "$r")" -lt 2 ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  if [ "$(worktree_count "$r")" = 2 ]; then ok
  else fail 'range-interrupted: the review worktree was never created (test setup)'; fi
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  if [ "$(worktree_count "$r")" = 1 ]; then ok
  else fail 'range-interrupted: a SIGTERM after the worktree was created left it behind'; fi
  rm -rf "$r" "$shim"
}

test_range_reviews_only_the_commits
test_range_worktree_is_detached_at_head
test_range_read_map_counts_from_head
test_range_rules_come_from_working_tree
test_range_leaves_project_untouched
test_range_does_not_run_hooks
test_range_cleanup_removes_worktree
test_cleanup_refuses_foreign_path
test_range_errors
test_range_worktree_removed_on_error
test_range_fingerprint_flag_matches
test_range_empty_exits_3_without_worktree
test_range_from_linked_worktree
test_range_head_is_checked_out_branch
test_range_two_runs_do_not_collide
test_range_non_ascii_file_counted
test_range_interrupted_run_removes_worktree

# ===================================================================== doc-lint
# The agents and SKILL.md are prompts, but other parts depend on their exact words: the main
# session parses the agents' output contract, and the fallback path reads the agents' model from
# a table in SKILL.md. These checks keep them from drifting apart.
AGENTS_DIR="$SKILL_DIR/agents"
RULES_AGENT="$AGENTS_DIR/review-rules.md"
BUGS_AGENT="$AGENTS_DIR/review-bugs.md"
SECCOV_AGENT="$AGENTS_DIR/review-security-coverage.md"

# frontmatter_of <file> -> the lines between the first pair of '---'
frontmatter_of() {
  awk 'NR == 1 && /^---$/ { f = 1; next } f && /^---$/ { exit } f' "$1"
}

# model_of <file> -> the model value of the frontmatter
model_of() {
  frontmatter_of "$1" | awk -F': *' '$1 == "model" { print $2; exit }'
}

# shared_block_of <file> -> the text between the markers, markers included
shared_block_of() {
  awk '/<!-- shared:start -->/,/<!-- shared:end -->/' "$1"
}

# lint_no_project_data <file>... -> fails on data that identifies a project. The skill ships in a
# public repository: no ticket ids, PR numbers, e-mail addresses, IPs or real URLs. A URL is
# allowed only as a placeholder (it carries a <...> part).
lint_no_project_data() {
  local f bad
  for f in "$@"; do
    [ -f "$f" ] || { fail "project-data: $f does not exist"; continue; }
    bad=$( {
      grep -oE '\b[A-Z][A-Z0-9]+-[0-9]+\b' "$f" | grep -vxE 'UTF-8|SHA-1|SHA-256|ISO-8601'
      grep -oE '#[0-9]{3,}' "$f"
      grep -oE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$f"
      grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' "$f" | grep -vx '127.0.0.1'
      grep -oE 'https?://[^ )`"'"'"'>]+' "$f" | grep -v '<'
    } | sort -u | tr '\n' ' ')
    if [ -z "$bad" ]; then ok
    else fail "project-data: $(basename "$f") carries project data: $bad"; fi
  done
}

test_doclint_agent_frontmatter() {
  local f name fm want
  for f in "$RULES_AGENT" "$BUGS_AGENT" "$SECCOV_AGENT"; do
    if [ -f "$f" ]; then ok; else fail "agent: $f does not exist"; continue; fi
    name=$(basename "$f" .md)
    fm=$(frontmatter_of "$f")
    assert_contains "name: $name" "$fm" "agent $name: name equals the file name"
    assert_contains 'tools: Read, Grep, Glob' "$fm" "agent $name: read-only tools"
    assert_contains 'description: ' "$fm" "agent $name: has a description"
    case "$name" in review-rules) want=sonnet ;; *) want=opus ;; esac
    if [ "$(model_of "$f")" = "$want" ]; then ok
    else fail "agent $name: model should be $want, got '$(model_of "$f")'"; fi
  done
}

# The output contract is parsed the same way for the three agents: one diverging breaks the
# parse of a third of the review without anyone noticing. Byte for byte, markers included.
test_doclint_shared_block_identical() {
  local a b c
  a=$(shared_block_of "$RULES_AGENT" 2>/dev/null)
  b=$(shared_block_of "$BUGS_AGENT" 2>/dev/null)
  c=$(shared_block_of "$SECCOV_AGENT" 2>/dev/null)
  if [ -n "$a" ] && [ "$a" = "$b" ] && [ "$b" = "$c" ]; then ok
  else fail 'agent: the shared block (invariant, not a finding, output contract) differs between the three agents'; fi
}

test_doclint_shared_block_contract() {
  local s n
  s=$(shared_block_of "$RULES_AGENT" 2>/dev/null)
  for n in 'file: ' 'line: ' 'severity: high | medium | low' \
           'category: rules | correctness | security | test-coverage' 'summary: ' \
           'failure_scenario: ' 'affected_files: ' '"only-this"' 'quote: ' '"n/a"' '`NONE`' \
           'anchored on a line the diff changed'; do
    assert_contains "$n" "$s" 'agent: the output contract has its field'
  done
}

test_doclint_review_rules() {
  local c
  c=$(cat "$RULES_AGENT" 2>/dev/null)
  assert_contains 'READ BUDGET' "$c" 'review-rules: has the read budget'
  assert_contains 'YOUR FILES' "$c" 'review-rules: names its files'
  assert_contains 'Before looking at the diff, enumerate' "$c" 'review-rules: enumerates the requirements first'
  assert_contains 'verbatim' "$c" 'review-rules: every finding quotes the rule verbatim'
  # a repository with CLAUDE.md files and no .claude/rules/ left the agent with no file to read
  assert_contains 'the `CLAUDE.md` files act as a global-scope rule' "$c" 'review-rules: has files to read in a CLAUDE.md-only repository'
  assert_contains '400' "$c" 'review-rules: the whole-file threshold matches the script'
  assert_not_contains 'FREE READING' "$c" 'review-rules: no free reading'
}

test_doclint_review_bugs() {
  local c
  c=$(cat "$BUGS_AGENT" 2>/dev/null)
  assert_contains 'FREE READING' "$c" 'review-bugs: free reading'
  assert_contains 'every consumer' "$c" 'review-bugs: follows a new value to every consumer'
  assert_contains 'views' "$c" 'review-bugs: consumers include views'
  assert_contains 'every path that writes' "$c" 'review-bugs: follows a guarded state to every writer'
  assert_contains 'Hot path' "$c" 'review-bugs: has the hot-path section'
  assert_contains 'schema dump' "$c" 'review-bugs: checks indexes in a schema dump too'
  assert_contains "one tenant's production data" "$c" 'review-bugs: scale is a tenant, not a product noun'
  assert_not_contains 'READ BUDGET' "$c" 'review-bugs: no read budget'
}

test_doclint_review_security_coverage() {
  local c
  c=$(cat "$SECCOV_AGENT" 2>/dev/null)
  assert_contains 'FREE READING' "$c" 'review-security-coverage: free reading'
  assert_contains 'Pass 1 — Security' "$c" 'review-security-coverage: pass 1'
  assert_contains 'Pass 2 — Coverage' "$c" 'review-security-coverage: pass 2'
  assert_contains 'tenant scope (company, account, site' "$c" 'review-security-coverage: generic tenant scope'
  assert_contains 'read the other tests in the file' "$c" 'review-security-coverage: reads neighbouring tests first'
  assert_contains 'written test policy' "$c" 'review-security-coverage: follows the written test policy'
  assert_contains 'TEST RULES' "$c" 'review-security-coverage: looks for the policy under TEST RULES'
  assert_contains 'no written test policy' "$c" 'review-security-coverage: default when no policy is written'
  assert_not_contains 'READ BUDGET' "$c" 'review-security-coverage: no read budget'
}

test_doclint_agents_use_code_root() {
  local f
  for f in "$RULES_AGENT" "$BUGS_AGENT" "$SECCOV_AGENT"; do
    assert_contains 'relative to `Code root`' "$(cat "$f" 2>/dev/null)" "agent $(basename "$f"): resolves paths against Code root"
    # in range mode a Grep without a path searches today's tree, not the reviewed commit
    assert_contains 'point `Grep` and `Glob` at `Code root`' "$(cat "$f" 2>/dev/null)" "agent $(basename "$f"): searches the reviewed code"
  done
}

test_doclint_agents_no_project_data() {
  lint_no_project_data "$RULES_AGENT" "$BUGS_AGENT" "$SECCOV_AGENT"
}

test_doclint_agent_frontmatter
test_doclint_shared_block_identical
test_doclint_shared_block_contract
test_doclint_review_rules
test_doclint_review_bugs
test_doclint_review_security_coverage
test_doclint_agents_use_code_root
test_doclint_agents_no_project_data

# ------------------------------------------------------------------- doc-lint: SKILL.md
SKILLMD="$SKILL_DIR/SKILL.md"

test_doclint_skill_frontmatter() {
  local fm n
  if [ -f "$SKILLMD" ]; then ok; else fail "skill: $SKILLMD does not exist"; return; fi
  fm=$(frontmatter_of "$SKILLMD")
  assert_contains 'name: by-the-book' "$fm" 'skill: name'
  for n in 'by the book' 'review my diff' 'revisa meu diff' 'commits' '.claude/rules' 'CLAUDE.md'; do
    assert_contains "$n" "$fm" 'skill: the description carries its trigger'
  done
}

test_doclint_skill_steps() {
  local c h
  c=$(cat "$SKILLMD" 2>/dev/null)
  for h in '## 1. Build the review package' '## 2. Dispatch the three agents' \
           '## 3. Check the fingerprint' '## 4. Clean up' '## 5. Report' '## 6. Gate'; do
    assert_contains "$h" "$c" 'skill: has its step'
  done
  # Regression: the cleanup came after the gate, and the gate ends the turn: a user who never
  # answered it left the range worktree behind. It runs as soon as the agents are done.
  assert_contains 'before the report' "$c" 'skill: the range worktree is removed before the report'
  assert_contains 'only when step 1 exited `0`' "$c" 'skill: no cleanup call when step 1 failed or found nothing'
}

# The fallback path passes the model from this table; the plugin path takes it from the agent
# file. The two must agree, so the row is built from the agent's own frontmatter.
test_doclint_skill_agent_table() {
  local c f name
  c=$(cat "$SKILLMD" 2>/dev/null)
  for f in "$RULES_AGENT" "$BUGS_AGENT" "$SECCOV_AGENT"; do
    name=$(basename "$f" .md)
    assert_contains "| \`by-the-book:$name\` | \`$(model_of "$f")\` |" "$c" \
      "skill: the table row of $name carries the model of its agent file"
    assert_contains "\`agents/$name.md\`" "$c" "skill: the table names the file of $name"
  done
}

test_doclint_skill_fallback() {
  local c n
  c=$(cat "$SKILLMD" 2>/dev/null)
  for n in 'Fallback path' '`general-purpose`' 'pass `model`' '20–30%' \
           'in the same message as the `Agent` calls' \
           'Everything after its frontmatter is your instructions'; do
    assert_contains "$n" "$c" 'skill: fallback path'
  done
  # Regression: in an end-to-end run the orchestrator dispatched the fallback agents without a
  # word of text, so the user never learned the review cost more and had no read-only lock. The
  # report always has text: the warning is repeated there.
  assert_contains 'on the fallback path, the report opens with the fallback line' "$c" \
    'skill: the report repeats the fallback warning'
}

test_doclint_skill_plugin_path() {
  local c
  c=$(cat "$SKILLMD" 2>/dev/null)
  assert_contains 'Plugin path' "$c" 'skill: plugin path'
  assert_contains 'Do not pass `model`' "$c" 'skill: no model on the plugin path'
  assert_contains 'On the plugin path, dispatching `general-purpose`' "$c" 'skill: red flag for general-purpose on the plugin path'
  assert_contains 'in one message' "$c" 'skill: the three agents go in one message'
}

test_doclint_skill_range() {
  local c
  c=$(cat "$SKILLMD" 2>/dev/null)
  assert_contains '--base <A> --head <B>' "$c" 'skill: range mode'
  assert_contains '--cleanup' "$c" 'skill: range cleanup'
  assert_contains 'line numbers refer to commit' "$c" 'skill: the report says which commit the lines refer to'
  assert_contains 'Skipped in range mode' "$c" 'skill: no fingerprint check in range mode'
}

test_doclint_skill_report() {
  local c
  c=$(cat "$SKILLMD" 2>/dev/null)
  assert_contains '`verdict`' "$c" 'skill: verdict is addressed'
  assert_contains 'Filling `verdict`' "$c" 'skill: red flag for verdict'
  assert_contains '60 characters' "$c" 'skill: short_summary limit'
  assert_contains '`high`, then `medium`, then `low`' "$c" 'skill: severity order'
  assert_contains 'numbered list' "$c" 'skill: report without ReportFindings'
  assert_contains 'finding by finding' "$c" 'skill: the gate is per finding'
  assert_contains "user's language" "$c" 'skill: messages in the user language'
}

test_doclint_skill_script_name() {
  local c
  c=$(cat "$SKILLMD" 2>/dev/null)
  assert_contains 'scripts/review-package.sh' "$c" 'skill: calls the script by its name'
}

test_doclint_skill_no_project_data() {
  lint_no_project_data "$SKILLMD" "$SKILL_DIR/scripts/review-package.sh"
}

test_doclint_skill_frontmatter
test_doclint_skill_steps
test_doclint_skill_agent_table
test_doclint_skill_fallback
test_doclint_skill_plugin_path
test_doclint_skill_range
test_doclint_skill_report
test_doclint_skill_script_name
test_doclint_skill_no_project_data

# ------------------------------------------------------------------- marketplace entry
# The plugin is what turns the three agent files into `by-the-book:review-*`. The trial-by-fire
# entry shares the source "./" and has no `agents` key: it must stay that way, or it would load
# these agents too.
MARKETPLACE="$SKILL_DIR/../../.claude-plugin/marketplace.json"

# entry_of <plugin name> -> that plugin's block in marketplace.json (up to its closing brace)
entry_of() {
  awk -v n="\"name\": \"$1\"" 'index($0, n) { f = 1 } f { print } f && /^    }/ { exit }' "$MARKETPLACE"
}

test_marketplace_declares_the_plugin() {
  local e t name
  e=$(entry_of by-the-book)
  assert_contains '"name": "by-the-book"' "$e" 'marketplace: by-the-book entry exists'
  assert_contains '"version": "1.0.0"' "$e" 'marketplace: by-the-book starts at 1.0.0'
  assert_contains '"source": "./"' "$e" 'marketplace: by-the-book source'
  assert_contains '"strict": false' "$e" 'marketplace: by-the-book is not strict'
  assert_contains '"skills": ["./skills/by-the-book"]' "$e" 'marketplace: by-the-book lists only its skill'
  for name in review-rules review-bugs review-security-coverage; do
    assert_contains "\"./skills/by-the-book/agents/$name.md\"" "$e" "marketplace: declares the agent $name"
    if [ -f "$SKILL_DIR/agents/$name.md" ]; then ok
    else fail "marketplace: the declared agent file $name.md does not exist"; fi
  done
  t=$(entry_of trial-by-fire)
  assert_contains '"skills": ["./skills/trial-by-fire"]' "$t" 'marketplace: trial-by-fire keeps its skill list'
  assert_not_contains '"agents"' "$t" 'marketplace: trial-by-fire declares no agents'
}

test_marketplace_declares_the_plugin

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
