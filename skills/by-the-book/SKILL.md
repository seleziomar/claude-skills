---
name: by-the-book
description: >-
  Use when the developer wants their own change reviewed against the repository's written rules
  (CLAUDE.md files and .claude/rules/*.md), together with correctness bugs, security holes and
  missing tests: a local diff, a branch before the pull request, a GitHub pull request, or a range
  of past commits. Triggers: "review it by the book", "review my diff by the book", "does this
  follow our rules?", "does this follow CLAUDE.md?", "is a test missing here?", "review the commits
  A..B", "revisa meu diff", "revisa pelas regras do projeto", "isso segue nossos padrões?",
  "faltou teste aqui?", "revisa os commits A..B", "revisa o PR 123 pelas regras". For a generic
  review of a project with no written rules, the native /code-review fits better. Never fixes
  anything before the developer picks the findings.
---

# by-the-book

Review against the repository's **written rules**, not against generic good practice. Each
`.claude/rules/*.md` declares in its frontmatter the globs it applies to; the skill loads only the
rules the diff touches, plus the `CLAUDE.md` files above the changed files. The deterministic part
(finding the diff, matching rules, diagnosing broken globs) lives in the script; the judgment, in
three agents. Replace `<skill-dir>` with this skill's directory. Write the report and every message
in the user's language.

## 1. Build the review package

```bash
M=$(mktemp "${TMPDIR:-/tmp}/by-the-book-manifest.XXXXXX") && bash "<skill-dir>/scripts/review-package.sh" --out "$M"
```

No argument: the local diff (working tree against the merge-base). Variants, always with
`--out "$M"`, with `mktemp` and the script in the SAME Bash call (the Bash tool does not keep
variables between calls, so `M=$(mktemp ...)` in one call and `--out "$M"` in another arrives
empty; the same holds when running again with the `--base` a warning suggests):

```bash
M=$(mktemp "${TMPDIR:-/tmp}/by-the-book-manifest.XXXXXX") && bash "<skill-dir>/scripts/review-package.sh" --base <ref> --out "$M"
M=$(mktemp "${TMPDIR:-/tmp}/by-the-book-manifest.XXXXXX") && bash "<skill-dir>/scripts/review-package.sh" 123 --out "$M"
M=$(mktemp "${TMPDIR:-/tmp}/by-the-book-manifest.XXXXXX") && bash "<skill-dir>/scripts/review-package.sh" "https://github.com/<owner>/<repo>/pull/123" --out "$M"
M=$(mktemp "${TMPDIR:-/tmp}/by-the-book-manifest.XXXXXX") && bash "<skill-dir>/scripts/review-package.sh" --base <A> --head <B> --out "$M"
```

**Range mode** (`--base <A> --head <B>`) reviews only the commits `A..B`, for example work already
merged. The code is read from a temporary, detached worktree of `B` (the `CODE ROOT` of the
summary); the rules and `CLAUDE.md` files come from the current working tree, so past code is
checked against today's conventions. The project's working tree, index, `HEAD` and branches are
not touched. Step 4 removes the worktree as soon as the agents are done.

Exit codes: `0` ok, `1` error (on stderr), `3` nothing to review. Stdout is a **summary**: `MODE`,
`REPO`, `CODE ROOT`, `BASE`, `DIFF`, `FINGERPRINT`, `MANIFEST`, `FILES`, the rules that matched,
the `CLAUDE.md` files and the `WARNINGS` (range mode adds `RULES FROM` and `HEAD`). Do not open the
manifest: it is for the agents. Everything you decide with is in the summary.

**The `WARNINGS` change what you do:**

| Warning | Action |
|---|---|
| tighter base available | **Stop. Confirm with the user** and run again with the suggested `--base`. |
| rule probably dead | Report it as a finding. Do not apply the rule by hand. |
| no applicable rule and no CLAUDE.md | **Skip `review-rules`** and tell the user. |

Above ~2,000 diff lines, warn the user and suggest narrowing (a closer `--base`, or by directory).
There is no automatic partitioning.

## 2. Dispatch the three agents

| Agent (`subagent_type`) | Model | Covers | Reading | Agent file |
|---|---|---|---|---|
| `by-the-book:review-rules` | `sonnet` | Rules | read budget | `agents/review-rules.md` |
| `by-the-book:review-bugs` | `opus` | Bugs | free | `agents/review-bugs.md` |
| `by-the-book:review-security-coverage` | `opus` | Security, Coverage | free | `agents/review-security-coverage.md` |

Dispatch the three in one message (skip `review-rules` when the warnings say so). The checklists,
the read budget and the output contract are already in the agents; each prompt carries only the
context block, the same for the three, filled from the summary:

```
Repo:          <REPO>
Code root:     <CODE ROOT>
Frozen diff:   <DIFF> (<N> lines)
Manifest:      <MANIFEST>
Rules:         <paths under APPLICABLE RULES, or "none">
CLAUDE.md:     <paths, or "none">

The frozen diff is the source of truth about what changed; if the live code differs from it, the
diff wins.
```

**Plugin path:** when the three `by-the-book:review-*` types are among the agent types the Agent
tool lists, dispatch them by `subagent_type`. Do not pass `model`: the agent file's model is the
measured one, and the call parameter overrides it.

**Fallback path:** when they are not listed (the skill was installed with `npx skills`, copied or
unzipped, without the plugin), or a call fails with "agent type not found". The user must know,
because it costs more: write this fallback line as text in the same message as the `Agent` calls,
and repeat it in the report (step 5): *the plugin agents are not installed, so this review runs on
`general-purpose` agents, at about 20–30% more cost and without their read-only lock; installing
the plugin from the marketplace avoids it.* Then dispatch three `general-purpose` agents, pass
`model` from the table, and start each prompt with these lines, followed by the context block:

```
Read <skill-dir>/agents/<agent file>. Everything after its frontmatter is your instructions for
this task: follow them exactly. Do not modify, create or delete any file, and run no command that
changes anything.
```

There is no refutation phase: what the three find goes to the report and the user triages.

**An answer outside the contract** (prose instead of `file:` blocks or `NONE`): `SendMessage` to
the same agent asking only for the reformatting into its output contract. If `SendMessage` shows up
as a deferred tool, load it with `ToolSearch` before calling it; do not relaunch the agent just
because the tool was not loaded. The context is already there; relaunching redoes the whole
exploration.

An agent failed or ran out of room: report what the others found and tell the user which part is
missing. Do not relaunch on your own.

## 3. Check the fingerprint

```bash
bash "<skill-dir>/scripts/review-package.sh" <the same arguments as step 1, without --out> --fingerprint
```

A value different from the summary's `FINGERPRINT` means the tree moved during the review. Say so
and offer to run again: the findings may be talking about code that no longer exists. Do not hide
it in a footnote. Skipped in range mode: the reviewed commits cannot move.

## 4. Clean up

Range mode only, and only when step 1 exited `0` with a `CODE ROOT` different from `REPO`: remove
the worktree as soon as the agents are done (after any `SendMessage` reformat), before the report.
The gate ends the turn, and a user who never answers it would otherwise leave the worktree behind.
Do it also when an agent failed or the user stopped the review.

```bash
bash "<skill-dir>/scripts/review-package.sh" --cleanup <CODE ROOT>
```

It removes only the worktree the script created, and refuses any other path.

## 5. Report

Then **one** `ReportFindings` call:

- **every finding**, one per entry, most severe first: the blocks' `severity` orders the array,
  `high`, then `medium`, then `low`;
- **leave `verdict` out.** The field's contract is "set when a verify pass ran"; none ran, so omit
  it. Do not invent a value;
- `short_summary` at most **60 characters**: a longer one rejects the whole call;
- the rule quote goes inside `summary`;
- merge duplicates across the agents and group what is systematic: eleven files with the same
  defect are **one** finding listing the eleven;
- in range mode, say once that line numbers refer to commit `B` (the `HEAD` of the summary), not to
  today's files;
- on the fallback path, the report opens with the fallback line of step 2;
- do not repeat the findings as prose afterwards.

Without a `ReportFindings` tool, print the same entries as a numbered list, in the same order, each
with `file:line`, severity, summary and failure scenario.

No agent found anything: one sentence, saying which agents ran and which were skipped.

## 6. Gate

Only after reporting, ask **which of these findings the user wants you to fix**: the choice is
finding by finding, not a yes or no for the whole batch. False positives reach the user on
purpose: they triage better, and cheaper, than a verifier per finding. In range mode a fix goes into
today's code: check that the finding still holds there first.

## Red flags — stop and go back a step

- Going to step 2 with a *tighter base* warning without asking the user.
- Dispatching the three agents in separate messages (it serializes what was parallel).
- On the plugin path, dispatching `general-purpose` instead of the skill's agents (it brings back the
  default system prompt and the schema of every tool in the session, on every call).
- On the plugin path, passing `model` on the `Agent` call (it overrides the measured tier).
- On the fallback path, dispatching without `model`, or without telling the user.
- Running `review-rules` when the summary said there is no applicable rule.
- Opening the manifest in the main session (the summary is enough; the manifest is the agents').
- Pasting a checklist, the read budget or `YOUR FILES` into the prompt (they are in the agents).
- Relaunching an agent to fix its format instead of `SendMessage`.
- Reporting without checking the fingerprint again (outside range mode).
- Applying a fix before the user answers the gate.
- Reporting N identical findings in N files instead of one grouped finding.
- Filling `verdict` in `ReportFindings` (no verification backs it).
- Keeping a finding to yourself because it might be a false positive: the user triages.
- Leaving the range-mode worktree behind.

## Gotchas

**A branch may not come from `main`.** A story branch cut from a long integration branch, reviewed
against `main`, turns a few dozen files into more than a thousand. The script finds candidates in
the branch's own merge commits (`merge-base --is-ancestor`, ~0.1s) and **warns without switching**:
switching would review something else without the user knowing.

**A broken glob is silent.** A rule pointing to `app/models/**` while the models live loose in
`app/` never applies, and a change to a model is reviewed with no model rule. The script warns;
fixing the glob is the human's job.

**Untracked files are not in `git diff`.** The manifest lists them in their own section and the
agents read them with `Read`. The script does not use `git add -N`: it never touches the index.

**No remote.** A project that lives only on the developer's machine has no `origin`: the base is
the local `main` or `master`.

**Scale.** The cost does not come from the diff. It comes from the live files (a legacy codebase
can have route or model files of thousands of lines) and from the exploration the agents do
following callers. That is why there are the `READ MAP`, the read budget in `review-rules`, free
reading in the other two, and the model tiering. A long fan-out takes minutes and the tree moves in
that window: that is why the fingerprint exists.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `could not detect the base` | No `origin/HEAD` and no `main`/`master`. Pass `--base <ref>`. |
| `base 'X' does not exist` | `git fetch origin` and try again. |
| exit `3`, `NOTHING TO REVIEW` | Empty diff. Check the branch; for past commits use `--base <A> --head <B>`. |
| `could not write the manifest` | The `--out` directory does not exist or is not writable. Redo the `mktemp`. |
| `gh is not on PATH` / `is not authenticated` | Install `gh` or run `gh auth login`; or review locally. |
| `--base was ignored` | Expected: in PR mode the base is the PR's own. |
| `--head requires --base` / `--head cannot be used with a PR` | Range mode needs both ends and works on local commits only. |
| `not a worktree created by this script` | `--cleanup` removes only the `CODE ROOT` of a range review. |
| An expected rule did not show up | See the `WARNINGS`: its glob probably matches nothing. A bug of the rule, not of the skill. |
| `Agent type 'by-the-book:...' not found` | The plugin is not enabled in this session. Use the fallback path and tell the user; `/plugin` installs it. |
| An agent answered in prose | `SendMessage` to the same agent asking for its output contract. |

## Out of scope

It does not comment on the pull request, write a report file, run tests, lint or build (CI does),
or read pull request history or `git blame`. In PR mode it does not check out the pull request:
the agents read the local tree, so a file the pull request adds shows as `(missing on disk)` in the
read map.
