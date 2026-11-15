#!/usr/bin/env bash
# run-tests.sh — locks the format of what the trial-by-fire skill ships.
#
#   run-tests.sh                      checks the skill itself (SKILL.md, checklist.md,
#                                     environment-template.md, report-template.html)
#   run-tests.sh --project <root>     checks <root>/docs/trial-by-fire/ENVIRONMENT.md and, if it
#                                     exists, <root>/docs/trial-by-fire/checklist.md
#
# checklist.md is a living file (the learn mode adds classes): if a class loses a field, Phase 1
# cannot cross it with the delivery and it silently disappears. That is why the format is checked here.
set -uo pipefail

SKILL_DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

HEADINGS=(
  '## Delivery sources'
  '## Environment'
  '## Profiles and test users'
  '## Test data and rollback'
  '## Servers'
  '## Queue and e-mail'
  '## Test suite'
  '## Before (baseline) environment'
  '## Results folder'
  '## Project dimensions'
  '## Gotchas'
  '## Tracker'
)

# check_headings <file> <label>: the 12 required headings exist, in this order.
check_headings() {
  local file=$1 label=$2 h line last=0
  for h in "${HEADINGS[@]}"; do
    line=$(grep -nxF -- "$h" "$file" | head -1 | cut -d: -f1)
    if [ -z "$line" ]; then
      fail "$label: missing heading '$h'"
    elif [ "$line" -lt "$last" ]; then
      fail "$label: heading '$h' is out of order"
    else
      ok
      last=$line
    fi
  done
}

# check_checklist <file> <label>: every class has the four fields; Method rules is the last class.
check_checklist() {
  local file=$1 label=$2 bad last
  bad=$(awk '
    function check(){ if(name!="" && !(fr&&a&&c&&e)) print name }
    /^## /{ check(); name=$0; fr=0; a=0; c=0; e=0; next }
    /^\*\*Front:\*\* (1|2|1 and 2)$/{fr=1} /^\*\*Applies when:\*\*/{a=1} /^\*\*How to prove:\*\*/{c=1} /^\*\*Examples:\*\*/{e=1}
    END{ check() }' "$file")
  [ -z "$bad" ] && ok || fail "$label: classes missing Front/Applies when/How to prove/Examples: $bad"
  grep -q '^## Method rules' "$file" && ok || fail "$label: 'Method rules' must exist"
  last=$(grep '^## ' "$file" | tail -1)
  [ "$last" = "## Method rules" ] && ok || fail "$label: 'Method rules' must be the last class"
}

finish() {
  printf '%d ok, %d fail(s)\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}

if [ "${1:-}" = "--project" ]; then
  ROOT=${2:-}
  [ -n "$ROOT" ] && [ -d "$ROOT" ] || { printf 'usage: run-tests.sh [--project <project-root>]\n' >&2; exit 2; }
  DIR="$ROOT/docs/trial-by-fire"
  if [ -f "$DIR/ENVIRONMENT.md" ]; then
    check_headings "$DIR/ENVIRONMENT.md" "ENVIRONMENT.md"
  else
    fail "ENVIRONMENT.md missing ($DIR/ENVIRONMENT.md)"
  fi
  [ -f "$DIR/checklist.md" ] && check_checklist "$DIR/checklist.md" "project checklist.md"
  finish
  exit $?
fi

SKILL="$SKILL_DIR/SKILL.md"
if [ -f "$SKILL" ]; then
  fm=$(awk 'NR==1 && $0=="---"{f=1; next} f && $0=="---"{exit} f' "$SKILL")
  printf '%s\n' "$fm" | grep -qx 'name: trial-by-fire' && ok || fail "SKILL.md: name must be trial-by-fire"
  desc=$(printf '%s\n' "$fm" | awk '/^description:/{f=1; sub(/^description:[ ]*/, ""); print; next} f && /^[a-z_-]+:/{f=0} f' | tr -s ' \n' ' ')
  printf '%s' "$desc" | grep -q '^ *Use when' && ok || fail "SKILL.md: description must start with 'Use when'"
  printf '%s' "$desc" | grep -q 'teste de fogo' && ok || fail "SKILL.md: description must contain 'teste de fogo'"
  [ "${#desc}" -le 1024 ] && ok || fail "SKILL.md: description is over 1024 chars (${#desc})"
  for t in 'Phase 0' 'Phase 1' 'Phase 2' 'Phase 3' 'Phase 4' 'Phase 5' 'Phase 6' 'CHECKPOINT' 'Front 1' 'Front 2' '1,920' 'check-report.sh' 'ENVIRONMENT.md' 'environment-template.md'; do
    grep -q -- "$t" "$SKILL" && ok || fail "SKILL.md: missing '$t'"
  done
  grep -Eq 'ready.*only with both fronts' "$SKILL" && ok || fail "SKILL.md: 'ready' must require both fronts ('ready ... only with both fronts')"
else
  fail "SKILL.md missing"
fi

CHK="$SKILL_DIR/checklist.md"
if [ -f "$CHK" ]; then
  check_checklist "$CHK" "checklist.md"
else
  fail "checklist.md missing"
fi

TPL="$SKILL_DIR/environment-template.md"
if [ -f "$TPL" ]; then
  check_headings "$TPL" "environment-template.md"
else
  fail "environment-template.md missing"
fi

REPORT="$SKILL_DIR/report-template.html"
if [ -f "$REPORT" ]; then
  bash "$SKILL_DIR/tests/check-report.sh" "$REPORT" >/dev/null && ok || fail "report-template.html does not pass check-report.sh"
else
  fail "report-template.html missing"
fi

finish
