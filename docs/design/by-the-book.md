# Design: the `by-the-book` skill

## Intent

Review a change against the repository's **own written rules** (`CLAUDE.md` files and `.claude/rules/*.md`),
and hunt correctness bugs, security holes and missing tests in the same pass, at a cost low enough to run on
every branch. The skill returns ranked findings; the developer triages them and picks which ones to fix. It
never fixes anything before that answer.

The native `/code-review` reviews generically. This skill adds what it lacks: it loads only the rules whose
`paths:` globs the diff touches, quotes the violated rule verbatim, and follows the project's written test
policy. It is project-agnostic: everything specific to a project lives in that project's `CLAUDE.md` and
`.claude/rules/`, never in the skill.

## Decisions

| Decision | Choice |
|---|---|
| Name | `by-the-book`. Not `code-review` (collides with the native command) |
| Distribution | Hybrid: plugin agents on the marketplace channel, a `general-purpose` fallback on the others (see Approaches) |
| Agents | Three, read-only, model fixed in each file: `review-rules` (`sonnet`), `review-bugs` (`opus`), `review-security-coverage` (`opus`) |
| Language | Skill, agents, script output and tests in English. The description carries trigger phrases in English and Portuguese. Findings and messages are written in the user's language |
| Range review | `--base A --head B` reviews only the commits `A..B`, reading code from a temporary detached worktree of `B`, with the rules of the current working tree |
| Test policy | The coverage pass follows the project's written test policy; with none written, it keeps the default checklist |
| Versioning | Semantic versions in `.claude-plugin/marketplace.json`, starting at `1.0.0`. Patch = a checklist item or wording; minor = a process change in `SKILL.md` or a new script option; major = a contract change (manifest section names, the agents' output contract, script flags or exit codes) |

## Approaches considered (distribution)

The repository serves three channels: the Claude Code marketplace, `npx skills add`, and a plain copy or zip.
The skill depends on plugin agents, which only exist on the marketplace channel.

| | Approach | Trade-off |
|---|---|---|
| A | Marketplace only | Simplest. `npx skills add` still installs the skill without its agents, so on that channel it can only stop with a message |
| B | Agent prompts inside the skill, always run as `general-purpose` | Works the same everywhere. Every agent carries the default system prompt and the schema of every tool in the session, on every call, and loses the read-only tool lock |
| **C** | **Hybrid, one copy of the prompts (chosen)** | The agent files live inside the skill folder; the marketplace entry declares them as plugin agents. On the marketplace channel nothing changes. Elsewhere the skill falls back to `general-purpose` with the model from its table and says so. Cost: one branch in `SKILL.md` and tests for both paths |

A `general-purpose` subagent starts every call with a much larger fixed prompt than one of these plugin agents
(the default system prompt and the tool list of the whole session), and a review makes dozens of agent calls.
Estimated from the author's own sessions, the fallback costs 20–30% more per review; the same review was not
run both ways, and a session with fewer tools sees a smaller gap.

## Repository layout

```
.claude-plugin/marketplace.json       new plugin entry (below); marketplace description mentions both skills
skills/by-the-book/
  SKILL.md                            the flow: package, agents, fingerprint, report, gate, cleanup
  agents/review-rules.md              plugin agent and fallback prompt
  agents/review-bugs.md
  agents/review-security-coverage.md
  scripts/review-package.sh     the deterministic part: diff, rules, read map, manifest
  tests/run-tests.sh                  script tests and doc-lint
docs/design/by-the-book.md            this document
README.md                             new section, plus the Portuguese paragraph
```

Marketplace entry:

```json
{
  "name": "by-the-book",
  "description": "...",
  "version": "1.0.0",
  "source": "./",
  "strict": false,
  "skills": ["./skills/by-the-book"],
  "agents": [
    "./skills/by-the-book/agents/review-rules.md",
    "./skills/by-the-book/agents/review-bugs.md",
    "./skills/by-the-book/agents/review-security-coverage.md"
  ]
}
```

Facts from the Claude Code docs (plugin marketplace and manifest references, subagents page) that this layout
relies on: in a marketplace entry, `agents` takes a list of `.md` files (directories are not accepted), with
paths resolved from the marketplace root; a plugin agent is called as `<plugin>:<name>`, where `name` is the
frontmatter `name` (keep it equal to the file name); plugin agents ignore `hooks`, `mcpServers`,
`permissionMode` and `initialPrompt`. The agents stay out of a root `agents/` directory because the
`trial-by-fire` entry has no `agents` key and would probably auto-discover that default directory. Claude Code
does not load agents from inside a skill folder, so the fallback copy never doubles as an agent.

## The flow (`SKILL.md`)

1. **Build the package.** One Bash call: `M=$(mktemp ...) && bash <skill-dir>/scripts/review-package.sh
   [args] --out "$M"` (the variable does not survive between Bash calls). The main session reads only the
   summary, never the manifest. Modes:
   - no argument: the working tree against the merge-base with the detected base;
   - a PR number or URL: the PR's diff through `gh`;
   - `--base A --head B`: only the commits `A..B` (see Range review).

   Exit codes: `0` ok, `1` error, `3` nothing to review. The warnings drive the next step:

   | Warning | Action |
   |---|---|
   | tighter base available | Stop, confirm with the user, run again with the suggested `--base` |
   | rule probably dead | Report it as a finding. Do not apply the rule by hand |
   | no applicable rule and no `CLAUDE.md` | Skip `review-rules` and tell the user |

   Above ~2,000 diff lines: warn and suggest narrowing (a closer `--base`, or by directory). No automatic
   partitioning.
2. **Dispatch the three agents in one message.**
   - Plugin path, when the three `by-the-book:review-*` types are in the session's agent list: call them by
     `subagent_type`, without `model` (the file's model is the measured one and the call parameter overrides it).
   - Fallback path, when they are not: `general-purpose` with `model` from the table in `SKILL.md` (which the
     doc-lint keeps equal to each file's frontmatter), and a prompt that tells the agent to read
     `<skill-dir>/agents/<file>`, follow everything after its frontmatter as its instructions, and modify no
     file. The user is told (fallback mode, about 20–30% more cost, no read-only lock; installing from the
     marketplace avoids it) in the same message as the dispatch and again as the report's first line: in an
     end-to-end run the model dispatched without any text, and the report is the text that always reaches
     the user.
   - Every prompt carries only the context block, the same for the three: repo, code root, frozen diff,
     manifest, rules, `CLAUDE.md` files, and "the frozen diff is the source of truth".
   - No refutation phase. An answer outside the output contract gets a `SendMessage` to the same agent asking
     for the reformatting only (load `SendMessage` through `ToolSearch` if it is deferred). A failed agent:
     report what the others found and say which part is missing; do not relaunch on your own.
3. **Check the fingerprint** with the same arguments as step 1 plus `--fingerprint`. A different value means the
   tree moved during the review: say so and offer to run again. Skipped in range mode, where the reviewed
   commits cannot move.
4. **Cleanup.** In range mode, and only when step 1 exited `0` with a worktree, remove it with
   `--cleanup <path>` as soon as the agents are done, before the report: the gate ends the turn, and a user
   who never answers it would leave the worktree behind. Also when an agent failed or the user stopped.
5. **Report** with one `ReportFindings` call: every finding, most severe first (`high`, `medium`, `low`), no
   `verdict` (no verification pass ran), `short_summary` at most 60 characters, the rule quote inside
   `summary`, duplicates merged across agents, one systematic defect in eleven files reported once with the
   eleven files. In range mode, say that line numbers refer to commit `B`. Without a `ReportFindings` tool,
   print the same entries as a numbered list, in the same order.
6. **Gate.** Ask which findings the user wants fixed, finding by finding. False positives reach the user on
   purpose: they triage better, and cheaper, than a verifier per finding.

The red flags of the current skill stay, translated, with one change: "dispatching `general-purpose` instead of
the skill's agents" becomes "on the plugin path, dispatching `general-purpose`; on the fallback path, dispatching
without `model` or without telling the user".

## The script (`review-package.sh`)

Everything it does today stays: local and PR modes; inert text excluded from the diff (`*.lock`, `*-lock.json`,
`*.min.*`, `*.snap`, `vendor/**`, `node_modules/**`, `public/build/**`, `dist/**`, `docs/**`), with the filter
checking both sides of a rename and non-ASCII paths; the read map, total over every changed file, with the
400-line "read whole" threshold; rules matched by their `paths:` globs, with `**/` meaning zero or more
directories; rules without `paths:` as global scope; dead-rule and matches-only-excluded warnings; anchored
test-glob classification taken from every rule of the repository, with a generic fallback; the root
`CLAUDE.md` plus every `CLAUDE.md` in the changed files' directories and their ancestors; the tighter-base
warning, which never switches the base on its own; the fingerprint over the filtered diff plus the untracked
files; `--out`; exit codes `0`, `1`, `3`; bash 3.2 portability (no `sed -i`, no recent git flags).

What changes:

- **English output.** The manifest is a contract read by the agents, so its labels are fixed here:

  | Today | New |
  |---|---|
  | `MODO`, `MANIFESTO`, `ARQUIVOS` | `MODE`, `MANIFEST`, `FILES` |
  | `DIFF: <path> (N linhas)` | `DIFF: <path> (N lines)` |
  | `ARQUIVOS ALTERADOS`, `NAO RASTREADOS`, `EXCLUIDOS` | `CHANGED FILES`, `UNTRACKED`, `EXCLUDED` |
  | `MAPA DE LEITURA` | `READ MAP` |
  | `arquivo pequeno, leia inteiro`, `(deletado)`, `(ausente no disco)`, `(sem hunk: ...)` | `small file, read whole`, `(deleted)`, `(missing on disk)`, `(no hunk: binary, mode or pure rename)` |
  | `REGRAS APLICAVEIS`, `escopo global (sem paths no frontmatter)` | `APPLICABLE RULES`, `global scope (no paths in frontmatter)` |
  | `ESCOPO CODIGO`, `ESCOPO TESTES` | `CODE SCOPE`, `TEST SCOPE` |
  | `AVISOS`, `NADA A REVISAR`, `(nenhum)` | `WARNINGS`, `NOTHING TO REVIEW`, `(none)` |

  New lines: `CODE ROOT: <path>` in every mode (the repository root, or the temporary worktree in range mode),
  so the agents have one instruction for where code lives; `RULES FROM: <repo root> (working tree)` in range
  mode; a `TEST RULES` section (below).
- **Range review: `--head <ref>`.** Requires `--base`; refused in PR mode.
  - The diff is `git diff <merge-base(base, head)> <head>`, the file list the same with `--name-only`. No
    untracked files: the working tree is not part of the review.
  - The code the agents read comes from a detached worktree of `<head>` in a fresh temp directory, created
    with hooks disabled (`git -c core.hooksPath=/dev/null worktree add --detach`) and `GIT_LFS_SKIP_SMUDGE=1`.
    It never touches the project's working tree, index, `HEAD` or branches; the only trace is the worktree
    entry in `.git`, removed by `--cleanup`. If the script fails after creating it, it removes it before exiting,
    also when it is interrupted: `HUP`, `INT` and `TERM` are trapped into exits, because bash 3.2 skips the
    `EXIT` trap on an untrapped signal.
  - The read map counts lines in the worktree. Rules, `CLAUDE.md` files and the dead-rule check come from the
    current working tree: the point is to review past code against today's conventions, and in the end-to-end
    range below the conventions did not exist yet at `B`.
  - The tighter-base warning is skipped (the base is explicit). The fingerprint is `<head short sha>-<diff hash>`.
  - Paths: code paths in the manifest stay relative to `CODE ROOT`; in range mode the rule files and
    `CLAUDE.md` files are printed as absolute paths under `RULES FROM`, since they do not live in the worktree.
    (Builder's call.)
  - `--cleanup <path>` removes a worktree this script created with `git worktree remove --force <path>`, and
    nothing else (no global `git worktree prune`, which would also drop the user's other stale entries). It
    refuses any path that is not in `git worktree list` or does not carry the script's temp-directory prefix.
    (Builder's call.)
- **`TEST RULES` section.** Every rule file whose `paths:` holds a test glob, whether or not it matched this
  diff. Without it, a diff that touches no test file never lists the test rules, and the coverage pass cannot
  find the policy they hold.
- **No remote.** Base detection already falls back from `origin/HEAD`, `origin/main`, `origin/master` to local
  `main` and `master`; this gets tests. With an empty diff (for example on `main` with nothing uncommitted), the
  exit-3 message also points to `--base A --head B` for past commits.
- **The user's git config does not shape the parsed diff:** the diffs the script writes use `--no-color
  --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/` (`color.ui=always`, `diff.noprefix` or an
  external diff driver would otherwise corrupt the read map and let excluded files through).
- **`.claude/CLAUDE.md`** is read like the root `CLAUDE.md`.
- **A rule with an inline `paths:` list** gets a warning (only YAML block lists are read) instead of silently
  becoming global scope.
- Error messages and comments in English, with the reasons behind each guard kept and rewritten without any
  project data.

## The agents

All three: `tools: Read, Grep, Glob`; they modify no file; every path in the manifest is relative to
`CODE ROOT`, and they point `Grep` and `Glob` at it (in range mode a search without a path would look at
today's code); the frozen diff is the source of truth. The shared block (anchoring invariant, what is not a finding,
output contract) is identical in the three, between markers, and the doc-lint checks it. The output contract,
consumed by the main session, not by a person:

```
file: <path relative to the repository root>
line: <line number>
severity: high | medium | low
category: rules | correctness | security | test-coverage
summary: <one sentence stating the defect>
failure_scenario: <concrete inputs or state -> wrong output or exception>
affected_files: <the SAME defect elsewhere, as path:line separated by commas; or "only-this">
quote: <verbatim text of the rule; "n/a" when the finding is not about a rule>
```

With no finding, the answer is the single word `NONE`.

- **`review-rules`** (`sonnet`): owns every violation of a written rule, in tests too. Keeps the `READ BUDGET`
  and `YOUR FILES` (the files listed under each applicable rule; for a global-scope rule, `CODE SCOPE` plus
  `TEST SCOPE`), ranges from the read map widened by ~40 lines, whole file only when the map says so. It
  enumerates every checkable requirement of each rule before looking at the diff, and every finding needs a
  verbatim quote. In a repository without `.claude/rules/`, the `CLAUDE.md` files act as a global-scope rule,
  so the agent still has files to read.
- **`review-bugs`** (`opus`): `FREE READING`. Logic bugs, contracts broken with callers (find them with `Grep`
  before claiming), every consumer of a new or changed value followed to its views and printouts, every path
  that writes a state a new guard protects, and the hot-path performance section. That section is rewritten
  without project data: "the volume of one tenant's production data" instead of a product's own nouns, "the
  screens users work in all day" instead of named screens, and checks for indexes in the migrations **and in
  any schema dump the project keeps**. The front-end (JS, jQuery, Vue) and back-end (PHP, Laravel) items stay
  as concrete examples of each stack, labelled as examples.
- **`review-security-coverage`** (`opus`): `FREE READING`, one exploration and two passes, in order.
  - Security: unchanged, with "tenant scope (company, account, site…)" in place of a product's own scope.
  - Coverage follows the project's **written test policy**. It looks for it in the `CLAUDE.md` files of the
    context block and the files under `TEST RULES` and `APPLICABLE RULES`. When the policy exempts a kind of
    file from automated tests (for example templates, CSS and JS checked on screen), a change there produces
    no "missing test" finding, and the "value rendered in a view" item does not apply to it. When the policy
    demands more (for example, every back-end change ships with a test that fails without it), that is the
    bar. Logic that the policy says must live in testable code but sits in an exempt file is a rules finding,
    owned by `review-rules`. With no written policy, the default checklist stays as it is, rendered-value item
    included.

## Generalization

Nothing in the repository names the company or the product the skill was first written for: not in the skill,
agents, script, comments, tests, this document, the README, commit messages or the branch name. What gets
replaced:

- ticket and PR numbers, client and product names, branch names, file and class names of the product;
- measurements taken on internal data (kept only as qualitative lessons, below);
- the product's own nouns in checklists (screens, documents, store volume) and the scope of its tenant.

Lessons from the measurements that keep their place, without the data: a read budget on the reasoning agents
cut almost nothing and lost real findings, so only `review-rules` has one; a refutation phase dropped real
findings, so there is none and the user triages; two agents (bugs, security and coverage merged) lost
medium-severity findings that followed a new value into the views that print it, so bugs has its own agent;
the three-agent version kept every medium and high finding of the four-agent version with refutation, at a
fraction of the cost; the tree moves during a long fan-out, hence the fingerprint; a wrong base can turn a few
dozen files into more than a thousand, hence the tighter-base warning.

A leak scan blocks every commit and push of the author's clone. It lives outside the repository, with its
lists, because a versioned list would itself name what it forbids; local git hooks (`pre-commit`,
`commit-msg`, `pre-push`, not versioned) call it on the staged files, the message, and every commit about to be
pushed. It checks three things: forbidden words (as whole words: inside a longer word they pass), including absolute
paths of the author's machine; every file path, any window of two or more of its components, and every file
name of the private repositories the skill came from, read from the local clones so the list keeps itself up
to date; and the GitHub owners of those repositories. Generic strings that also exist there (`CLAUDE.md`,
`.claude/rules`, `tests/run-tests.sh`…) pass only through an explicit, reviewed allow-list. For the same
reason the script has a name of its own.

The doc-lint adds a generic guard that names nothing: no ticket ids (`ABC-123`), no `#1234` PR numbers, no
e-mail address, IP or URL other than placeholders in the skill's files.

## Tests (`tests/run-tests.sh`)

- Every existing script test, translated, on fixtures built at run time.
- New script tests:
  - no remote: base `main`; only `master`: base `master`; no base at all: the error;
  - range mode: only `A..B` is in the diff (working-tree changes and untracked files are ignored); the
    worktree is detached at `B` and the read map counts from it; a rule that exists only in the working tree
    applies; the project's `git status --porcelain`, `HEAD`, branches and index are byte-identical before and
    after; hooks do not run; `--head` without `--base` and with a PR fail; the worktree is gone after an error;
    `--cleanup` removes it and refuses a foreign path;
  - `TEST RULES` lists a test rule that does not match the diff; `CODE ROOT` in every mode;
  - the exit-3 message points to `--base A --head B`.
- Doc-lint: agent frontmatter (`name` equal to the file name, `model`, `tools`); the shared block identical in
  the three; `READ BUDGET` and `YOUR FILES` only in `review-rules`, `FREE READING` in the other two; the
  instructions that recovered lost findings kept literally (follow a new value to every consumer, views
  included; follow a guarded state to every path that writes it; read the neighbouring tests before claiming
  a test only asserts the outline); the test-policy instructions; `SKILL.md` names the three
  `by-the-book:review-*` types, and its fallback model table matches each file's frontmatter; the fallback
  instructions; `marketplace.json` lists the three agent files and they exist; the generic leak guard.

## End-to-end acceptance

On a real Laravel project of the author's with no remote (only a local `main`), no `.claude/rules/`, and a
`CLAUDE.md` whose test policy exempts Blade, CSS and JS (checked on screen). Strictly read-only: its working
tree, index, `HEAD`, branches and worktree list are the same before and after.

1. `tests/run-tests.sh` exits 0, and `claude plugin validate` accepts the marketplace.
2. The script alone in local mode detects base `main` without a remote.
3. A full review of a past two-commit range through the **plugin path**, with the plugin loaded
   from the local clone in a way that leaves the user's `~/.claude` settings unchanged. Expected: the
   `CLAUDE.md` files of today's tree are used (they did not exist at the range's head); no coverage finding asks
   for an automated test of Blade, CSS or JS; every finding is anchored on a changed line; the worktree is gone
   at the end.
4. The same range once through the **fallback path** (skill without the plugin agents): the skill warns,
   passes `model`, and returns findings in the contract.
5. The leak scan is clean.

## Non-goals

- PR mode checking out the PR head in a worktree (it keeps reading the local tree, as today).
- Copying the agents to `~/.claude/agents` for the copy channel.
- Agents other than Claude Code (the skill needs a subagent tool).
- Automatic partitioning of large diffs; a refutation phase; `effort` or `maxTurns` in the agents.
- Commenting on the PR, writing a report file, running tests, lint or build, reading PR history or `git blame`.

## Anti-goals

- **Naming the origin.** Any mention of the company or product the skill was first written for, or of their
  internal data, anywhere in the repository or its history.
- **Softening the discipline.** A rule finding without a verbatim quote, a finding on a line the diff did not
  change, a fix applied before the gate, a per-batch yes/no instead of a choice per finding.
- **Touching the project in range mode:** its working tree, index, `HEAD`, branches or hooks.
- On the plugin path, `general-purpose` agents or a `model` parameter on the call.

## Left to the builder

Exact English wording of `SKILL.md` and the agents; the description's trigger phrases (English and Portuguese,
distinct from a generic "review my code" so the native `/code-review` keeps generic requests); test names and
fixtures; how the plugin is loaded from the local clone for the end-to-end run (if no way leaves the user's
settings unchanged, ask); how the work is split into commits (`feat(by-the-book): ...`).
