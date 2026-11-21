#!/usr/bin/env bash
# review-package.sh — builds the review package for the by-the-book skill.
#
# Finds the diff (local or from a PR), matches the changed files against the globs declared in
# the frontmatter of .claude/rules/*.md and prints a manifest. The diff goes to a temporary
# file, not to stdout, so it does not inflate the context.
#
# Portable to macOS (bash 3.2) and Linux. No `sed -i`, no recent git flag.

# `set -f` (noglob) is REQUIRED, not cosmetic: rule patterns hold `**` and `*`, and a
# `set -- $pats` without noglob undergoes pathname expansion — a pattern like
# "resources/views/**/*.blade.php" turned into hundreds of real file names instead of staying
# literal. Matching inside `[[ ]]` is not affected by noglob; the expansion of `$pats` is.
set -uo pipefail
set -f

usage() {
  cat <<'EOF'
Usage: review-package.sh [<pr-number>|<pr-url>] [--base <ref>] [--head <ref>] [--out <file>]
       review-package.sh --cleanup <path>

  (no argument)     reviews the local diff: working tree against the merge-base with the base
  <pr-number|url>   reviews a PR through gh (--base is ignored)
  --base <ref>      forces the base in local mode (default: origin/HEAD)
  --head <ref>      range mode: reviews only the commits <base>..<ref> (needs --base). The code
                    is read from a temporary detached worktree of <ref>; the rules come from the
                    current working tree. The project's working tree, index and HEAD are untouched
  --cleanup <path>  removes a review worktree this script created (the CODE ROOT of range mode)
  --fingerprint     prints ONLY the snapshot fingerprint and exits (to detect whether the
                    tree moved during the review)
  --out <file>      writes the whole manifest to <file> and prints only the summary on stdout
                    (MANIFEST, DIFF, FINGERPRINT, rules, CLAUDE.md, WARNINGS)
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- arguments
PR=""
BASE=""
HEAD_REF=""
CLEANUP=""
FP_ONLY=0
OUT_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)     usage; exit 0 ;;
    --base)        [ $# -ge 2 ] || die "--base requires a ref"; BASE="$2"; shift 2 ;;
    --base=*)      BASE="${1#--base=}"; shift ;;
    --head)        [ $# -ge 2 ] || die "--head requires a ref"; HEAD_REF="$2"; shift 2 ;;
    --head=*)      HEAD_REF="${1#--head=}"; shift ;;
    --cleanup)     [ $# -ge 2 ] || die "--cleanup requires a path"; CLEANUP="$2"; shift 2 ;;
    --fingerprint) FP_ONLY=1; shift ;;
    --out)         [ $# -ge 2 ] || die "--out requires a file path"
                   case "$2" in ""|-*) die "--out requires a file path, got: $2" ;; esac
                   OUT_FILE="$2"; shift 2 ;;
    --out=*)       OUT_FILE="${1#--out=}"; [ -n "$OUT_FILE" ] || die "--out requires a file path"; shift ;;
    -*)            die "unknown option: $1" ;;
    *)             [ -z "$PR" ] || die "extra argument: $1"; PR="$1"; shift ;;
  esac
done

BASE_EXPLICIT=0
[ -n "$BASE" ] && BASE_EXPLICIT=1

if [ -n "$HEAD_REF" ]; then
  [ -z "$PR" ] || die "--head cannot be used with a PR"
  [ -n "$BASE" ] || die "--head requires --base"
fi

MODE=local
if [ -n "$PR" ]; then
  case "$PR" in
    *[!0-9]*)
      case "$PR" in
        *"/pull/"*) PR="${PR##*/pull/}"; PR="${PR%%/*}"; PR="${PR%%\?*}" ;;
        *) die "'$PR' is neither a PR number nor a PR URL" ;;
      esac ;;
  esac
  case "$PR" in
    ''|*[!0-9]*) die "could not extract the PR number from the argument" ;;
  esac
  MODE=pr
fi
[ -n "$HEAD_REF" ] && MODE=range

# ---------------------------------------------------------------- repository and temp
git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository"
REPO_ROOT=$(git rev-parse --show-toplevel) || die "could not find the repository root"
cd "$REPO_ROOT" || die "could not enter $REPO_ROOT"
# Where the agents read code. The repository root, except in range mode.
CODE_ROOT="$REPO_ROOT"

# Every review worktree lives in a temp directory with this prefix. --cleanup refuses anything
# else, so it can never remove a worktree, or a directory, of the user's own.
WT_PREFIX="by-the-book-head."

# --cleanup <path>: removes ONE review worktree, with `git worktree remove`. No global
# `git worktree prune`: it would also drop the user's other stale worktree entries.
if [ -n "$CLEANUP" ]; then
  [ -d "$CLEANUP" ] || die "not a worktree created by this script: $CLEANUP"
  target=$(cd "$CLEANUP" && pwd -P) || die "not a worktree created by this script: $CLEANUP"
  case "$(basename "$target")" in
    "$WT_PREFIX"*) ;;
    *) die "not a worktree created by this script: $CLEANUP" ;;
  esac
  listed=0
  while IFS= read -r wl; do
    case "$wl" in
      "worktree "*)
        w="${wl#worktree }"
        [ -d "$w" ] && w=$(cd "$w" && pwd -P)
        [ "$w" = "$target" ] && listed=1 ;;
    esac
  done <<WTLIST
$(git worktree list --porcelain)
WTLIST
  [ "$listed" -eq 1 ] || die "not a worktree created by this script: $CLEANUP"
  git worktree remove --force "$target" || die "git worktree remove failed for $target"
  printf 'removed: %s\n' "$target"
  exit 0
fi

OUT=$(mktemp -d) || die "mktemp failed"
DIFF="$OUT/review.diff"
FILES="$OUT/files.txt"
UNTRACKED="$OUT/untracked.txt"
WARN="$OUT/warnings.txt"
: > "$WARN"
: > "$UNTRACKED"

warn() { printf '%s\n' "$*" >> "$WARN"; }

# `sort -o` on the same file fails with some old sorts (they do not support identical input
# and output); the fallback through a temporary file covers them. The danger is in `-o`, not in
# `-u` — that is why the helper is generic over the flags and `-u` is just one case of it: it is
# used in several places, and a fix here must not miss any of them.
sort_inplace() {
  local f="$1"; shift
  sort "$@" "$f" -o "$f" 2>/dev/null || { sort "$@" "$f" > "$f.s" && mv "$f.s" "$f"; }
}
sort_u_inplace() { sort_inplace "$1" -u; }

# ---------------------------------------------------------------- pattern matching
# Matches a path against a pattern. Inside `[[ ]]` the `*` already matches `/`, which solves
# the `**` in the middle of a pattern — BUT bash needs the literal slash, so
# `database/migrations/**/*.php` would NOT match the flat files directly under
# `database/migrations/`. The convention everyone uses (minimatch, gitignore, editorconfig) is
# that `**/` means ZERO or more directories, and that is what the rule's author meant. That is
# why the variant with `**/` collapsed is tested too.
match_file() {
  local f="$1" p="$2" alt
  # shellcheck disable=SC2053  # intentional glob
  [[ $f == $p ]] && return 0
  case "$p" in
    *'**/'*)
      alt="${p//\*\*\//}"
      # shellcheck disable=SC2053
      [[ $f == $alt ]] && return 0 ;;
  esac
  return 1
}

# ------------------------------------------------------- inert text (excluded)
# Goes into the repository but is not worth a human review. Editable: one pattern per line, the
# same syntax as rule globs (`**` = zero or more directories, through match_file).
# A binary does NOT need to be here — `git diff` already prints "Binary files differ" and does
# not dump the content. The problem is inert TEXT: lock files and generated data files of
# thousands of lines, read by every agent.
# `docs/**`: in many repositories this directory holds specs and plans (planning markdown),
# not delivered product — in one real pull request about one line in seven was markdown there.
EXCLUDE_PATTERNS='*.lock
*-lock.json
*.min.*
*.snap
vendor/**
node_modules/**
public/build/**
dist/**
docs/**'

# Moves from $2 to $3 everything that matches an exclusion pattern. Does not use git pathspecs
# because PR mode gets the diff ready-made from `gh` and needs the same treatment.
split_excluded() {
  local src="$1" keep="$2" drop="$3"
  local f p hit
  : > "$keep"; : > "$drop"
  # shellcheck disable=SC2086  # we want word splitting of the patterns
  set -- $EXCLUDE_PATTERNS
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    hit=0
    for p in "$@"; do
      if match_file "$f" "$p"; then hit=1; break; fi
    done
    if [ "$hit" -eq 1 ]; then printf '%s\n' "$f" >> "$drop"
    else printf '%s\n' "$f" >> "$keep"; fi
  done < "$src"
}

# Removes from the unified diff the sections of the files listed in $2.
# Checks BOTH sides of the header (`diff --git a/<old> b/<new>`), not only a/: rename detection
# is on by default in `git diff` (no -M needed), and then `--name-only` returns only the
# post-image path (b/). A hashed Vite build under public/build/, renamed on every build, falls
# exactly in that case — checking only a/ let the whole hunk (minified content included)
# survive in the frozen diff while the file was listed in EXCLUDED.
# Known limitation: a path that literally holds " b/" breaks the parsing of the
# `diff --git a/<old> b/<new>` header. It does not happen with real file names.
filter_diff() {
  awk '
    NR == FNR { ex[$0] = 1; next }
    /^diff --git / {
      rest = $0
      sub(/^diff --git a\//, "", rest)
      oldp = rest
      sub(/ b\/.*$/, "", oldp)
      newp = substr(rest, length(oldp) + 4)   # skips "<oldp> b/"
      skip = (oldp in ex) || (newp in ex)
    }
    !skip
  ' "$2" "$1"
}

# ---------------------------------------------------------------------- read map
# Below this, reading the whole file costs less than computing an offset.
SMALL_FILE_LINES=400

# Ranges of the NEW side, from the @@ headers of the unified diff: <path>\t<start>-<end>.
# Uses $DIFF itself (-U3), not a separate -U0: `gh pr diff` does not accept -U0, and the 3
# context lines only widen the range — which the agents widen by 40 anyway.
#   `@@ -a,b +c,d @@` -> starts at c, covers d lines. `+c` without `,d` = 1 line.
#   d == 0 is a pure deletion: anchored at c.
#
# A deleted file (`+++ /dev/null`) has no new side, so it has no range: emits the old path
# (from the `--- a/<path>` that always comes right before, in the same `diff --git` block) with
# range `-`. That `-` is not decoration: it is the only deletion signal that comes from the
# frozen diff, and emit_readmap relies on it — not on the disk — to print "(deleted)". Without
# this line the deleted file vanished from the read map.
#
# The state machine is anchored on `^diff --git ` and that is NOT style: `--- ` and `+++ ` also
# show up as CONTENT. An ADDED line starting with `++ ` comes out in the diff as `+++ ...`;
# without the anchor it became a "header", the current file became a junk path and the next
# ranges of the REAL file went to it. `^diff --git ` cannot be hijacked: every content line of a
# unified diff carries a `+`, `-` or space prefix. Requiring "the previous line is `--- `" would
# NOT solve it — a removed `-- y` followed by an added `++ x` passes that test. The `-- ` side
# was never a live bug (`old` is only used in the `+++ /dev/null` branch), but it is now safe by
# construction.
ranges_of_diff() {
  awk '
    /^diff --git / { inhdr = 1; f = ""; old = ""; next }
    # the first @@ closes this file header: from there on it is content
    /^@@ / { inhdr = 0 }
    inhdr && /^--- / {
      # "--- a/<path>" (6 fixed chars before the path) or "--- /dev/null" (a new file, with no
      # old side) — handled apart because it has no "a/" prefix.
      old = ($0 == "--- /dev/null") ? "/dev/null" : substr($0, 7)
      next
    }
    inhdr && /^\+\+\+ / {
      if ($0 == "+++ /dev/null") {
        if (old != "" && old != "/dev/null") printf "%s\t-\n", old
        f = ""
        next
      }
      f = substr($0, 7)   # drops "+++ b/"
      next
    }
    f != "" && /^@@ / {
      m = $0
      sub(/^@@ -[^ ]+ \+/, "", m)
      sub(/ @@.*$/, "", m)
      n = split(m, a, ",")
      start = a[1] + 0
      # `+0,0` (a deletion from the start of the file) would give range `0-0`, and offset 0
      # does not exist in Read. Today that is masked twice (an emptied file has 0 lines and
      # comes out "read whole"; in PR mode it comes out "(missing on disk)"), but the agents are
      # promised that the offset never goes below 1 — the promise cannot depend on the mask.
      # Clamps BEFORE deriving `end`, otherwise `1-0` would come out inverted.
      if (start < 1) start = 1
      len   = (n > 1 ? a[2] + 0 : 1)
      end   = (len > 0 ? start + len - 1 : start)
      printf "%s\t%d-%d\n", f, start, end
    }
  ' "$1"
}

# One line per file: path | line count | ranges or "read whole".
emit_readmap() {
  # `f` is also used in the untracked loop below, which comes BEFORE the final loop: declared
  # up here so it does not leak to the global scope there.
  local agg="$OUT/readmap_agg.txt" seen="$OUT/readmap_seen.txt" f rng n
  ranges_of_diff "$DIFF" \
    | awk -F'\t' '
        { if ($1 in r) r[$1] = r[$1] ", " $2; else r[$1] = $2 }
        END { for (f in r) printf "%s\t%s\n", f, r[f] }
      ' | sort > "$agg"

  # an untracked file has no @@ header — the range is the whole file
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -f "$f" ]; then
      printf '%s\t1-%s\n' "$f" "$(wc -l < "$f" | tr -d ' ')" >> "$agg"
    fi
  done < "$UNTRACKED"

  # The map must be TOTAL over the CHANGED FILES. The agents treat it as the reading AUTHORITY
  # — a whole-file read is licensed only by its mark —, so a file without a line in the map has
  # no licensed way to be read and no explanation why. Three realistic cases produce no hunk
  # and so do not come out of ranges_of_diff, yet remain in CHANGED FILES and CODE SCOPE: a
  # binary ("Binary files differ"), a mode-only change (chmod +x) and a 100% rename. None of
  # them has a range to read, and that is what the line says.
  cut -f1 "$agg" | sort -u > "$seen"
  # $FILES is already sorted and deduplicated (sort_u_inplace) and $seen was just sorted: comm
  # is safe. $UNTRACKED does not enter here — it was covered by the loop above.
  comm -23 "$FILES" "$seen" | while IFS= read -r f; do
    [ -n "$f" ] || continue
    printf '%s\t(no hunk)\n' "$f"
  done >> "$agg"

  # no -u: each file already appears once in the aggregate (the awk above merges by path, and
  # there is no overlap with $UNTRACKED nor with the complement above), so dedup here would say
  # nothing.
  sort_inplace "$agg"

  # Empty is information: every other list section of the manifest prints (none) when it has
  # no item. Without this the section came out literally blank, and "there was no file" could
  # not be told from "the section failed".
  if [ ! -s "$agg" ]; then printf '(none)\n'; return 0; fi

  while IFS=$(printf '\t') read -r f rng; do
    [ -n "$f" ] || continue
    # What says the file was deleted is the frozen diff (range `-`), not the live tree: in PR
    # mode nobody checks out the PR branch, so the local tree knows nothing about what the PR
    # changed — asking it `[ -f ]` would mark "(deleted)" every file the PR ADDED, exactly the
    # opposite of what happened.
    if [ "$rng" = "-" ]; then
      printf '%-44s %6s | (deleted)\n' "$f" '-'
      continue
    fi
    # No hunk at all in the frozen diff: no range to read and nothing to count. Comes before
    # the disk test on purpose — the diff is what knows there is no hunk, and in PR mode a
    # binary or rename is also missing from the disk; this mark is the useful one.
    if [ "$rng" = "(no hunk)" ]; then
      printf '%-44s %6s | (no hunk: binary, mode or pure rename)\n' "$f" '-'
      continue
    fi
    # It has a real range, so it was not deleted — but it is not on the disk (PR mode, a
    # dangling symlink, a file moved after the snapshot). Without the file the lines cannot be
    # counted: say it is missing, instead of inventing a deletion.
    if [ ! -f "$f" ]; then
      printf '%-44s %6s | (missing on disk)\n' "$f" '-'
      continue
    fi
    # wc -l counts newlines: a file without a final newline counts 1 less. Acceptable.
    n=$(wc -l < "$f" | tr -d ' ')
    if [ "$n" -le "$SMALL_FILE_LINES" ]; then
      printf '%-44s %6s | small file, read whole\n' "$f" "$n"
    else
      printf '%-44s %6s | %s\n' "$f" "$n" "$rng"
    fi
  done < "$agg"
}

# ---------------------------------------------------------------- collect the diff
BASE_LABEL=""
HEAD_LABEL=""
HEAD_SHA=""
if [ "$MODE" = pr ]; then
  command -v gh >/dev/null 2>&1 || die "gh is not on PATH — install the GitHub CLI"
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated — run: gh auth login"
  gh pr diff "$PR" > "$DIFF" 2>"$OUT/gh.err" \
    || die "gh pr diff $PR failed: $(tr '\n' ' ' < "$OUT/gh.err")"
  gh pr view "$PR" --json files --jq '.files[].path' > "$FILES" 2>"$OUT/gh.err" \
    || die "gh pr view $PR failed: $(tr '\n' ' ' < "$OUT/gh.err")"
  BASE_LABEL="PR #$PR"
  [ -n "$BASE" ] && warn "--base was ignored: in PR mode the base is the PR's own"
elif [ "$MODE" = range ]; then
  # Only the commits <base>..<head>: the working tree and untracked files are not part of it.
  git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null 2>&1 || die "base '$BASE' does not exist"
  HEAD_SHA=$(git rev-parse --verify --quiet "$HEAD_REF^{commit}" 2>/dev/null) \
    || die "head '$HEAD_REF' does not exist"
  MB=$(git merge-base "$BASE" "$HEAD_SHA" 2>/dev/null)
  if [ -z "$MB" ]; then
    warn "no merge-base between '$BASE' and '$HEAD_REF' (unrelated histories) — comparing directly with '$BASE'"
    MB="$BASE"
  fi
  git -c core.quotePath=false diff --name-only "$MB" "$HEAD_SHA" > "$FILES" || die "git diff --name-only failed"
  git -c core.quotePath=false diff "$MB" "$HEAD_SHA" > "$DIFF" || die "git diff failed"
  BASE_LABEL="$BASE (merge-base $(git rev-parse --short "$MB"))"
  HEAD_LABEL="$HEAD_REF ($(git rev-parse --short "$HEAD_SHA"))"
else
  if [ -z "$BASE" ]; then
    BASE=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
    if [ -z "$BASE" ]; then
      for cand in origin/main origin/master main master; do
        if git rev-parse --verify --quiet "$cand" >/dev/null 2>&1; then BASE="$cand"; break; fi
      done
    fi
  fi
  [ -n "$BASE" ] || die "could not detect the base — pass --base <ref> explicitly"
  git rev-parse --verify --quiet "$BASE" >/dev/null 2>&1 || die "base '$BASE' does not exist"

  MB=$(git merge-base "$BASE" HEAD 2>/dev/null)
  if [ -z "$MB" ]; then
    warn "no merge-base between '$BASE' and HEAD (unrelated histories) — comparing directly with '$BASE'"
    MB="$BASE"
  fi
  git -c core.quotePath=false diff --name-only "$MB" > "$FILES" || die "git diff --name-only failed"
  # The same flag as the --name-only above: without it, a path with a non-ASCII byte (common in
  # Portuguese file names) comes out quoted and escaped in the header ("a/A\303\247..."), which
  # breaks the path parsing in filter_diff and lets the file escape the exclusion filter.
  git -c core.quotePath=false diff "$MB" > "$DIFF" || die "git diff failed"
  git -c core.quotePath=false ls-files --others --exclude-standard > "$UNTRACKED"
  BASE_LABEL="$BASE (merge-base $(git rev-parse --short "$MB"))"
fi

sort_u_inplace "$FILES"

EXCLUDED="$OUT/excluded.txt"
split_excluded "$FILES" "$OUT/files.keep" "$EXCLUDED"
mv "$OUT/files.keep" "$FILES"

if [ -s "$EXCLUDED" ]; then
  filter_diff "$DIFF" "$EXCLUDED" > "$OUT/review.keep.diff"
  mv "$OUT/review.keep.diff" "$DIFF"
fi

# untracked files go through the same filter
if [ -s "$UNTRACKED" ]; then
  split_excluded "$UNTRACKED" "$OUT/untracked.keep" "$OUT/untracked.drop"
  mv "$OUT/untracked.keep" "$UNTRACKED"
  cat "$OUT/untracked.drop" >> "$EXCLUDED"
  sort_u_inplace "$EXCLUDED"
fi

N_EXCLUDED=$(grep -c . "$EXCLUDED"); N_EXCLUDED=${N_EXCLUDED:-0}

N_FILES=$(grep -c . "$FILES");         N_FILES=${N_FILES:-0}
N_UNTRACKED=$(grep -c . "$UNTRACKED"); N_UNTRACKED=${N_UNTRACKED:-0}
N_DIFF=$(wc -l < "$DIFF" | tr -d ' ')

# ---------------------------------------------------------------------- fingerprint
# The diff is a SNAPSHOT in a file, but the agents also read live files. In a real review of a
# few thousand diff lines the fan-out took over ten minutes, the tree changed in that window,
# and a verifier refuted a VALID finding only because the code had moved. The fingerprint makes
# that drift detectable instead of silent.
hash_stdin() {
  if command -v shasum >/dev/null 2>&1;   then shasum -a 1 | cut -d' ' -f1
  elif command -v sha1sum >/dev/null 2>&1; then sha1sum | cut -d' ' -f1
  else cksum | tr -d ' '
  fi
}
if [ -n "$HEAD_SHA" ]; then
  FP_HEAD=$(git rev-parse --short "$HEAD_SHA")
else
  FP_HEAD=$(git rev-parse --short HEAD 2>/dev/null || printf 'no-head')
fi
FP_BODY=$(cat "$DIFF" "$UNTRACKED" | hash_stdin | cut -c1-12)
FINGERPRINT="$FP_HEAD-$FP_BODY"

if [ "$FP_ONLY" -eq 1 ]; then
  printf '%s\n' "$FINGERPRINT"
  exit 0
fi

# ------------------------------------------------------------- range: review worktree
# The agents follow callers and read neighbouring files, so they need the code AS IT WAS at the
# head commit, not the live tree. A detached worktree gives them that without touching the
# project's working tree, index, HEAD or branches. Hooks are off (a post-checkout hook could
# install dependencies or write files) and LFS smudging is skipped. Created only when there is
# something to review, so an empty range leaves nothing behind; removed by the EXIT trap if the
# script fails after this point.
WT=""
remove_wt_on_error() {
  local st=$?
  if [ "$st" -ne 0 ] && [ "$st" -ne 3 ] && [ -n "$WT" ]; then
    git worktree remove --force "$WT" >/dev/null 2>&1 || true
  fi
}
if [ "$MODE" = range ] && [ "$N_FILES" -gt 0 ]; then
  WT=$(mktemp -d "${TMPDIR:-/tmp}/${WT_PREFIX}XXXXXX") || die "mktemp failed"
  WT=$(cd "$WT" && pwd -P) || die "could not resolve $WT"
  if ! GIT_LFS_SKIP_SMUDGE=1 git -c core.hooksPath=/dev/null worktree add --detach "$WT" "$HEAD_SHA" \
       >/dev/null 2>"$OUT/worktree.err"; then
    rmdir "$WT" 2>/dev/null
    WT=""
    die "could not create the review worktree: $(tr '\n' ' ' < "$OUT/worktree.err")"
  fi
  trap remove_wt_on_error EXIT
  CODE_ROOT="$WT"
fi

# ------------------------------------------------- tighter base (downstream branch)
# A story branch cut from a long integration branch (and not from main) produces a huge,
# useless diff against origin/HEAD. Candidates = branches named in the merge commits of this
# branch that are ANCESTORS of HEAD (so, legitimate bases). Costs ~0.1s; never switches the base
# on its own — it only warns, because switching would review something else.
if [ "$MODE" = local ] && [ "$BASE_EXPLICIT" -eq 0 ]; then
  cur_n=$(git rev-list --count "$MB..HEAD" 2>/dev/null); cur_n=${cur_n:-0}
  best=""; best_n="$cur_n"
  cands=$(git log --merges --format='%s' -n 300 "$MB..HEAD" 2>/dev/null \
            | grep -oE "'[^']+'" | tr -d "'" | sort -u)
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    git rev-parse --verify --quiet "$cand" >/dev/null 2>&1 || continue
    git merge-base --is-ancestor "$cand" HEAD 2>/dev/null || continue
    n=$(git rev-list --count "$cand..HEAD" 2>/dev/null) || continue
    if [ "$n" -lt "$best_n" ]; then best_n="$n"; best="$cand"; fi
  done <<CANDS
$cands
CANDS
  if [ -n "$best" ]; then
    best_mb=$(git merge-base "$best" HEAD 2>/dev/null)
    if [ -n "$best_mb" ]; then
      best_files=$(git -c core.quotePath=false diff --name-only "$best_mb" | grep -c .)
      if [ "${best_files:-0}" -lt "$N_FILES" ]; then
        warn "tighter base available: '$best' gives $best_files files ($best_n commits) against the $N_FILES of '$BASE' ($cur_n commits) — this branch seems to have come from '$best', not from '$BASE'. Confirm with the user and run again with: --base $best"
      fi
    fi
  fi
fi

# files considered when matching rules: changed + untracked
CAND="$OUT/candidates.txt"
cat "$FILES" "$UNTRACKED" | grep . | sort -u > "$CAND"

# ---------------------------------------------------------------------- rules
# Recognizes a rule GLOB as a "test" glob. ANCHORED on a path component or a file-name suffix —
# never a loose substring. A `grep -E 'test|spec'` over the whole pattern classified
# `app/Perspectiva/**/*.php` as a test (Per-SPEC-tiva) and `app/Espectro/**` too
# (E-SPEC-tro): in a Portuguese codebase "perspectiva", "espectro" and "especificacao"
# are common words, and the effect was throwing production code into the test scope and leaving
# bugs and security with an EMPTY scope, with no warning.
# The suffixes stay case-sensitive on purpose: with `-i`, `test\.` would match `latest.php`.
TEST_GLOB_RE='(^|/)([Tt]ests?|[Ss]pecs?|__[Tt]ests__)(/|$)|(Test|Spec|_test|_spec|\.test|\.spec)\.[^/]*$'

# Extracts the `paths:` patterns from the frontmatter. YAML block list only:
#   ---
#   paths:
#     - "app/Services/**"
#   ---
# Strips quotes and the leading slash (git paths never start with /).
rule_patterns() {
  awk '
    NR==1 { if ($0 != "---") exit; next }
    $0 == "---" { exit }
    /^paths:[[:space:]]*$/ { inp=1; next }
    inp && /^[[:space:]]*-[[:space:]]*/ {
      line = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      gsub(/["\047]/, "", line)
      sub(/[[:space:]].*$/, "", line)
      sub(/^\//, "", line)
      if (line != "") print line
      next
    }
    inp && /^[^[:space:]-]/ { inp = 0 }
  ' "$1"
}

# 0 = the frontmatter declares a `paths:` key
has_paths_key() {
  awk '
    NR==1 { if ($0 != "---") exit 1; next }
    $0 == "---" { exit 1 }
    /^paths:/ { exit 0 }
    END { exit 1 }
  ' "$1"
}

# Prints the first pattern (of $2..$n) that matches some line of file $1.
first_match() {
  local list="$1"; shift
  local f p
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    for p in "$@"; do
      if match_file "$f" "$p"; then printf '%s' "$p"; return 0; fi
    done
  done < "$list"
  return 1
}

# Every path of $1 that matches some pattern of $2..$n, one per line.
# SEPARATE from first_match on purpose, and the asymmetry is the point: here the whole list
# matters, because it is the scope the rules agent reads. first_match stops at the first match
# because its other caller runs against `git ls-files` of the WHOLE repository (the dead-rule
# diagnosis, below) — scanning everything there would be expensive and say nothing more.
# Do not merge them: whoever merges them pays the full scan in the diagnosis.
all_matches() {
  local list="$1"; shift
  local f p
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    for p in "$@"; do
      if match_file "$f" "$p"; then printf '%s\n' "$f"; break; fi
    done
  done < "$list"
}

# One line per (rule, file): <rule>\t<rule patterns>\t<matched file>.
# Field 2 repeats on every line of the same rule — the price of keeping the format flat and
# readable by cut/awk without a second index file.
RULES_MATCHED="$OUT/rules_matched.txt"; : > "$RULES_MATCHED"
RULES_GLOBAL="$OUT/rules_global.txt";   : > "$RULES_GLOBAL"
ALL_TRACKED=""   # filled on demand, only for the dead-rule diagnosis

# Every glob declared in .claude/rules/, whether or not the rule matched this diff. It serves the
# classification (what IS a test), which must be a property of the REPOSITORY and not of the
# diff: deriving it from $RULES_MATCHED made a file's scope depend on which OTHER files happened
# to be in the diff. See the "scope per agent" block.
ALL_RULE_PATS="$OUT/rule_pats_all.txt";  : > "$ALL_RULE_PATS"

# Rules that declare a test glob, whether or not they matched this diff: the coverage pass
# reads the project's written test policy there, even when the diff touches no test file.
RULES_TEST="$OUT/rules_test.txt";       : > "$RULES_TEST"

if [ -d .claude/rules ]; then
  RULE_FILES=$(find .claude/rules -type f -name '*.md' | sort)
  [ -n "$RULE_FILES" ] || warn ".claude/rules/ exists but has no .md file"
  while IFS= read -r rf; do
    [ -n "$rf" ] || continue
    pats=$(rule_patterns "$rf")
    if [ -z "$pats" ]; then
      if has_paths_key "$rf"; then
        warn "$rf: has a 'paths:' key but its patterns could not be read (inline list? only YAML block lists are supported) — treated as global scope"
      fi
      printf '%s\n' "$rf" >> "$RULES_GLOBAL"
      continue
    fi

    # Before any matching: the test classification reads ALL the rules, including the ones this
    # diff does not touch. A rule without `paths:` contributes no glob.
    printf '%s\n' "$pats" >> "$ALL_RULE_PATS"
    if printf '%s\n' "$pats" | grep -qE "$TEST_GLOB_RE"; then printf '%s\n' "$rf" >> "$RULES_TEST"; fi

    # `set -f` at the top of the script keeps these patterns from pathname expansion.
    # shellcheck disable=SC2086  # we want word splitting of the patterns
    set -- $pats

    hits="$OUT/hits.txt"
    all_matches "$CAND" "$@" > "$hits"
    if [ -s "$hits" ]; then
      pat_flat=$(printf '%s' "$pats" | tr '\n' ' ')
      while IFS= read -r hf; do
        printf '%s\t%s\t%s\n' "$rf" "$pat_flat" "$hf" >> "$RULES_MATCHED"
      done < "$hits"
    else
      # Matched nothing reviewable — but did it match something the EXCLUSION took out of the
      # review? A rule whose glob points inside an excluded tree (`docs/**` is in
      # EXCLUDE_PATTERNS) died silently: the dead-rule diagnosis below rightly does NOT fire (the
      # glob matches `git ls-files`), and the only signal left was the generic "no applicable
      # rule" warning, which SKILL.md turns into "SKIP the rules agent" for the WHOLE review.
      # This is what makes the broad `docs/**` safe.
      ex_n=$(all_matches "$EXCLUDED" "$@" | grep -c .); ex_n=${ex_n:-0}
      if [ "$ex_n" -gt 0 ]; then
        # `elif` on purpose: the rule is not dead, it matches a file of the repository. Besides
        # being the right message, it avoids paying the whole `git ls-files` for nothing.
        warn "$rf: the rule matches $ex_n file(s) in EXCLUDED and no reviewed file — it does not apply to this review"
      else
        # it did not match the diff: does the pattern match anything in the whole repository?
        if [ -z "$ALL_TRACKED" ]; then
          ALL_TRACKED="$OUT/tracked.txt"
          git -c core.quotePath=false ls-files > "$ALL_TRACKED"
        fi
        if ! first_match "$ALL_TRACKED" "$@" >/dev/null; then
          warn "$rf: pattern '$(printf '%s' "$pats" | tr '\n' ' ')' matches NO file of the repository — rule probably dead, fix the glob"
        fi
      fi
    fi
  done <<EOF
$RULE_FILES
EOF
else
  warn "this repository has no .claude/rules/ — the rules agent will rely on CLAUDE.md only"
fi

# ------------------------------------------------------- scope per agent
# Each agent of the fan-out reads only the files of its scope. The rules agent uses the indented
# list under APPLICABLE RULES; the coverage pass needs to know what IS a test; bugs and security
# take the rest.
#
# Bugs and security share ONE scope on purpose, not out of laziness: "security surface" cannot be
# derived declaratively from anything the repository writes — no glob says "user input comes in
# here". Hard-coding `app/Http/Controllers` here would fit one framework and make the skill
# useless elsewhere: any other repository would get an empty security scope and silently have
# that dimension unreviewed.
SCOPE_TESTS="$OUT/scope_tests.txt"
SCOPE_CODE="$OUT/scope_code.txt"


# The test globs come from ALL the rules of the repository ($ALL_RULE_PATS), not only the ones
# that matched this diff. Reading only the matched ones, a diff that touched no test — the
# common case of a small diff — found no test rule, fell into the fallback, and the fallback
# reclassified production code as tests; a file's scope depended on which OTHER files were in
# the diff, and the same code was routed two ways in two reviews.
TEST_PATS=$(grep -E "$TEST_GLOB_RE" "$ALL_RULE_PATS" | sort -u)

# If the repository declares ANY test rule, it is the authority and there is NO fallback: an
# empty test scope is a legitimate answer (the diff did not touch tests). The fallback exists
# only for a repository that declares tests nowhere — without it, that repository's tests would
# go to the code scope and the coverage pass would have no file.
# It is anchored too: `**/tests/**` matches both `tests/x.php` (through the variant with `**/`
# collapsed in match_file) and `app/tests/x.php`.
if [ -z "$TEST_PATS" ]; then
  TEST_PATS='**/tests/**
**/test/**
**/spec/**
**/specs/**
**/__tests__/**
*Test.*
*Spec.*
*_test.*
*_spec.*
*.test.*
*.spec.*'
fi

# shellcheck disable=SC2086  # we want word splitting of the patterns
set -- $TEST_PATS
# `sort -u` here reads and writes DIFFERENT paths, so it does not need sort_inplace.
all_matches "$CAND" "$@" | sort -u > "$SCOPE_TESTS"
# $CAND is already sorted and deduplicated, and $SCOPE_TESTS is a subset of it in the same
# order — comm is safe.
comm -23 "$CAND" "$SCOPE_TESTS" > "$SCOPE_CODE"

N_SCOPE_TESTS=$(grep -c . "$SCOPE_TESTS"); N_SCOPE_TESTS=${N_SCOPE_TESTS:-0}
N_SCOPE_CODE=$(grep -c . "$SCOPE_CODE");   N_SCOPE_CODE=${N_SCOPE_CODE:-0}

# ---------------------------------------------------------------------- CLAUDE.md
CLAUDE_MDS="$OUT/claude_mds.txt"
{
  [ -f CLAUDE.md ] && printf 'CLAUDE.md\n'
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    d=$(dirname "$f")
    while [ "$d" != "." ] && [ "$d" != "/" ] && [ -n "$d" ]; do
      [ -f "$d/CLAUDE.md" ] && printf '%s/CLAUDE.md\n' "$d"
      d=$(dirname "$d")
    done
  done < "$CAND"
} | sort -u > "$CLAUDE_MDS"

N_CLAUDE=$(grep -c . "$CLAUDE_MDS"); N_CLAUDE=${N_CLAUDE:-0}

# In range mode the rules and CLAUDE.md files come from the working tree, not from CODE ROOT:
# their paths are made absolute so the agents cannot look for them in the review worktree.
if [ "$MODE" = range ]; then
  awk -F'\t' -v root="$REPO_ROOT" 'BEGIN { OFS = "\t" } { $1 = root "/" $1; print }' \
    "$RULES_MATCHED" > "$RULES_MATCHED.abs" && mv "$RULES_MATCHED.abs" "$RULES_MATCHED"
  for lst in "$RULES_GLOBAL" "$RULES_TEST" "$CLAUDE_MDS"; do
    awk -v root="$REPO_ROOT" 'NF { print root "/" $0 }' "$lst" > "$lst.abs" && mv "$lst.abs" "$lst"
  done
fi

# ---------------------------------------------------------------------- manifest
# $RULES_MATCHED has one line per (rule, file), so counting lines would count files. What the
# section announces is RULES, so the count is of distinct rules.
N_RULES=$(cut -f1 "$RULES_MATCHED" | sort -u | grep -c .); N_RULES=${N_RULES:-0}
N_GLOBAL=$(grep -c . "$RULES_GLOBAL");  N_GLOBAL=${N_GLOBAL:-0}
N_TEST_RULES=$(grep -c . "$RULES_TEST"); N_TEST_RULES=${N_TEST_RULES:-0}

# The actionable condition is not "the directory is missing", it is "nothing is left to review
# against" — an empty .claude/rules/ is the same as none.
if [ "$N_CLAUDE" -eq 0 ] && [ "$((N_RULES + N_GLOBAL))" -eq 0 ]; then
  warn "no applicable rule and no CLAUDE.md — SKIP the review-rules agent and tell the user"
fi

N_WARN=$(grep -c . "$WARN");            N_WARN=${N_WARN:-0}

# emit_manifest -> the whole manifest. Without --out it goes to stdout; with --out it goes to
# the file and stdout gets emit_summary.
emit_manifest() {
  printf 'MODE: %s\n' "$MODE"
  printf 'REPO: %s\n' "$REPO_ROOT"
  printf 'CODE ROOT: %s\n' "$CODE_ROOT"
  [ "$MODE" = range ] && printf 'RULES FROM: %s (working tree)\n' "$REPO_ROOT"
  printf 'BASE: %s\n' "$BASE_LABEL"
  [ "$MODE" = range ] && printf 'HEAD: %s\n' "$HEAD_LABEL"
  printf 'DIFF: %s (%s lines)\n' "$DIFF" "$N_DIFF"
  printf 'FINGERPRINT: %s\n' "$FINGERPRINT"

  printf '\nCHANGED FILES (%s)\n' "$N_FILES"
  if [ "$N_FILES" -gt 0 ]; then cat "$FILES"; else printf '(none)\n'; fi

  if [ "$N_UNTRACKED" -gt 0 ]; then
    printf '\nUNTRACKED (%s) — not in the diff, read them with Read\n' "$N_UNTRACKED"
    cat "$UNTRACKED"
  fi

  if [ "$N_EXCLUDED" -gt 0 ]; then
    printf '\nEXCLUDED (%s) — inert text, out of this review\n' "$N_EXCLUDED"
    cat "$EXCLUDED"
  fi

  printf '\nREAD MAP (file | lines | changed ranges)\n'
  ( cd "$CODE_ROOT" && emit_readmap )

  printf '\nAPPLICABLE RULES (%s)\n' "$((N_RULES + N_GLOBAL))"
  if [ "$N_RULES" -gt 0 ]; then
    cut -f1 "$RULES_MATCHED" | sort -u | while IFS= read -r rf; do
      [ -n "$rf" ] || continue
      pat=$(awk -F'\t' -v r="$rf" '$1 == r { print $2; exit }' "$RULES_MATCHED")
      printf '%-34s <- %s\n' "$rf" "$pat"
      awk -F'\t' -v r="$rf" '$1 == r { printf "%36s%s\n", "", $3 }' "$RULES_MATCHED"
    done
  fi
  if [ "$N_GLOBAL" -gt 0 ]; then
    while IFS= read -r rf; do
      [ -n "$rf" ] && printf '%-34s <- global scope (no paths in frontmatter)\n' "$rf"
    done < "$RULES_GLOBAL"
  fi
  [ "$((N_RULES + N_GLOBAL))" -eq 0 ] && printf '(none)\n'

  printf '\nCLAUDE.md (%s)\n' "$N_CLAUDE"
  if [ "$N_CLAUDE" -gt 0 ]; then cat "$CLAUDE_MDS"; else printf '(none)\n'; fi

  printf '\nTEST RULES (%s) — rules that declare a test glob: where the written test policy lives\n' "$N_TEST_RULES"
  if [ "$N_TEST_RULES" -gt 0 ]; then cat "$RULES_TEST"; else printf '(none)\n'; fi

  printf '\nCODE SCOPE (non-test) (%s) — agents review-bugs and review-security-coverage\n' "$N_SCOPE_CODE"
  if [ "$N_SCOPE_CODE" -gt 0 ]; then cat "$SCOPE_CODE"; else printf '(none)\n'; fi

  printf '\nTEST SCOPE (%s) — agent review-security-coverage (coverage)\n' "$N_SCOPE_TESTS"
  if [ "$N_SCOPE_TESTS" -gt 0 ]; then cat "$SCOPE_TESTS"; else printf '(none)\n'; fi

  if [ "$N_WARN" -gt 0 ]; then
    printf '\nWARNINGS (%s)\n' "$N_WARN"
    cat "$WARN"
  fi
}

# emit_summary -> only what the orchestrator uses to decide and to build the agents' prompt.
# Rules: only the path (what goes in the context block), without the list of files per rule.
emit_summary() {
  printf 'MODE: %s\n' "$MODE"
  printf 'REPO: %s\n' "$REPO_ROOT"
  printf 'CODE ROOT: %s\n' "$CODE_ROOT"
  [ "$MODE" = range ] && printf 'RULES FROM: %s (working tree)\n' "$REPO_ROOT"
  printf 'BASE: %s\n' "$BASE_LABEL"
  [ "$MODE" = range ] && printf 'HEAD: %s\n' "$HEAD_LABEL"
  printf 'DIFF: %s (%s lines)\n' "$DIFF" "$N_DIFF"
  printf 'FINGERPRINT: %s\n' "$FINGERPRINT"
  printf 'MANIFEST: %s\n' "$OUT_FILE"
  printf 'FILES: %s changed, %s untracked, %s excluded\n' \
    "$N_FILES" "$N_UNTRACKED" "$N_EXCLUDED"

  printf '\nAPPLICABLE RULES (%s)\n' "$((N_RULES + N_GLOBAL))"
  [ "$N_RULES" -gt 0 ] && cut -f1 "$RULES_MATCHED" | sort -u | grep .
  [ "$N_GLOBAL" -gt 0 ] && grep . "$RULES_GLOBAL"
  [ "$((N_RULES + N_GLOBAL))" -eq 0 ] && printf '(none)\n'

  printf '\nCLAUDE.md (%s)\n' "$N_CLAUDE"
  if [ "$N_CLAUDE" -gt 0 ]; then cat "$CLAUDE_MDS"; else printf '(none)\n'; fi

  if [ "$N_WARN" -gt 0 ]; then
    printf '\nWARNINGS (%s)\n' "$N_WARN"
    cat "$WARN"
  fi
}

if [ -n "$OUT_FILE" ]; then
  emit_manifest > "$OUT_FILE" || die "could not write the manifest to $OUT_FILE"
  emit_summary
else
  emit_manifest
fi

if [ "$N_FILES" -eq 0 ] && [ "$N_UNTRACKED" -eq 0 ]; then
  printf '\nNOTHING TO REVIEW: the diff is empty. To review past commits, use --base <A> --head <B>.\n'
  exit 3
fi
exit 0
