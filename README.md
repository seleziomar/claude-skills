# claude-skills

Open-source skills for AI coding agents. One repository, three ways to install: a Claude Code marketplace,
the open Agent Skills layout (`npx skills`), or a plain copy of the folder.

It ships two skills: **trial-by-fire** and **by-the-book**.

## trial-by-fire

A rigorous pre-QA process: test YOUR OWN delivery (a ticket, card, milestone or pull request) the way QA or
the client would, before you hand it over. The skill produces **findings and a report**. You decide what to
fix, and the fix follows your normal flow. It does not replace QA and it does not review other people's code.

How a round works:

- **Phase 0, survey:** reads the spec, the prototype, the diff and the project's `ENVIRONMENT.md`, and builds a
  dimension matrix (item by item, profiles, tenant isolation, legacy data, responsive, queue and e-mail, ...).
  A dimension that does not apply is written down with its reason, never omitted.
- **Phase 1, test cases, then a CHECKPOINT:** cases cross the generic checklist and the project's optional
  one. The skill writes `matrix-and-cases.md`, shows it, and **stops until you approve**. No click happens
  before that.
- **Two fronts, in order.** Front 1 (functional) covers what corrupts data, blocks the user or leaks. Front 2
  (polish) compares every screen and state with the prototype at 1,366, 1,600 and 1,920 px of CSS viewport
  and on mobile. Front 2 starts only when Front 1 is closed: no Bug or Correction open. A finding is fixed
  only when its case ran again on the new commit, with a new screenshot.
- **Execution through the browser, as the user:** one case at a time, with a screenshot per case. A scenario
  without a screenshot did not happen.
- **Phase 4, the full test suite,** isolated from the screen's data when the project allows it, with failures
  attributed against a baseline. The run that counts is the one on the final commit.
- **Phase 5, the report:** `matrix-and-cases.md`, `report.md`, a closed `rollback-inventory.md` and a
  self-contained HTML report. The verdict is "ready" only with both fronts closed, the suite run on the final
  commit and the rollback inventory closed.
- **Learn mode:** turns QA or client adjustments into new checklist examples or classes, so the next round
  checks them. Call it `/trial-by-fire learn <file or text>` when the skill is installed directly, or
  `/trial-by-fire:trial-by-fire learn <file or text>` when it is installed as a plugin.

The skill text is in English with trigger phrases in English and Portuguese. The matrix, report and messages
come out in the language you use.

### Requirements

- A shell (bash) and git.
- A browser automation tool the agent can drive (Claude in Chrome, or another one). Without one, the round
  stops before execution and the verdict is "not ready".
- The app under test, running somewhere the agent can start it and reach it (your machine or a test host).

### Install

Pick one.

1. **Claude Code marketplace**

   ```
   /plugin marketplace add seleziomar/claude-skills
   /plugin install trial-by-fire@seleziomar-skills
   ```

2. **Agent Skills CLI**

   ```
   npx skills add seleziomar/claude-skills
   ```

3. **Copy the folder:** copy `skills/trial-by-fire` to `~/.claude/skills/`.
4. **Claude.ai:** zip the `skills/trial-by-fire` folder and upload the zip in Claude.ai. Claude.ai cannot
   reach an app on your machine or control your browser, so it cannot run the round's execution there.

Installed copies are caches or snapshots. Never edit them. If you want the learn mode to record generic
lessons, keep a writable git clone of this repository and give its path under `## Skills repo clone` in your
project's `ENVIRONMENT.md`: that is how the skill finds the clone (without it, the skill asks).

### Quick start

1. In your project, create `docs/trial-by-fire/ENVIRONMENT.md` from the skill's `environment-template.md`
   (`skills/trial-by-fire/environment-template.md` in this repository). Keep its 12 headings exactly as they
   are (delivery sources, environment, profiles and test users, test data and rollback, servers, queue and
   e-mail, test suite, before (baseline) environment, results folder, project dimensions, gotchas, tracker).
   Never put a real password in it. Without the file, the skill drafts one from your repository and asks
   before writing it.
2. Optionally add `docs/trial-by-fire/checklist.md` with defect classes that only make sense for your project
   (same format as the skill's `checklist.md`).
3. Check them: your agent runs this check in Phase 0. From a clone of this repository:
   `bash skills/trial-by-fire/tests/run-tests.sh --project <your project root>`. With a marketplace install
   the script lives in the plugin cache; with the other installs, in the `tests/` folder of the installed skill.
4. Ask your agent for a "trial by fire" of your delivery, or say "test it before QA".

Results go to `docs/trial-by-fire/<target>/cycle-N/` by default. Keep screenshots and the HTML report out of git.

### Running the tests

From a clone of this repository:

```
bash skills/trial-by-fire/tests/run-tests.sh                        # the skill itself
bash skills/trial-by-fire/tests/run-tests.sh --project <root>       # a project's ENVIRONMENT.md and checklist
bash skills/trial-by-fire/tests/check-report.sh <report.html>       # a generated HTML report
```

They lock the format of `SKILL.md`, `checklist.md`, the environment template and the report contract. The
first one also fails when the skill's `checklist.md` carries an e-mail address, an IP or a URL, and runs the
regression checks of `check-report.sh`.

### Contributing a new checklist class

1. Open `skills/trial-by-fire/checklist.md` and add the class **before** `## Method rules`. Never reorder or
   compact existing classes.
2. Use the fixed format: a `## <class name>` heading, then the lines `**Front:**` (`1`, `2` or `1 and 2`),
   `**Applies when:**`, `**How to prove:**` and `**Examples:**`.
3. Keep it generic: no project, client, company, product or person names, no hosts, URLs, IPs, ids, e-mail
   addresses or credentials. A lesson that only makes sense for one project belongs in that project's own
   checklist.
4. Run `bash skills/trial-by-fire/tests/run-tests.sh` (it must exit 0), bump the plugin's patch version in
   `.claude-plugin/marketplace.json`, and open a pull request.

For the intent and the contracts behind all this, see [docs/design/trial-by-fire.md](docs/design/trial-by-fire.md).

## by-the-book

A code review of YOUR change against the repository's **own written rules**: the `CLAUDE.md` files and the
`.claude/rules/*.md` whose `paths:` globs the change touches. In the same run it hunts correctness bugs,
security holes and missing tests. Every rule finding quotes the rule verbatim. The skill returns ranked
findings, and you pick, finding by finding, which ones to fix. The native `/code-review` reviews generically;
this one holds the change to what your project wrote down, including its test policy (for example, "templates
are checked on screen, not by automated tests").

How a review works:

- **The package:** a script finds the diff (the working tree, a GitHub pull request, or a range of past
  commits), matches the changed files against the rules' globs, and writes a manifest with a read map, so the
  agents read the changed ranges of large files instead of whole files. It warns about a broken rule glob, a
  tighter base, or a project with no written rule at all.
- **Three read-only agents, in parallel:** `review-rules` (sonnet, with a read budget) checks every
  requirement of every applicable rule; `review-bugs` (opus) follows callers, consumers and the paths that
  write a guarded state; `review-security-coverage` (opus) looks for abuse vectors, then for missing tests
  under the project's written test policy.
- **The report:** findings ranked by severity, duplicates merged, a defect repeated across files reported
  once. Nothing is fixed before you choose.
- **Past commits:** `--base <A> --head <B>` reviews only `A..B` from a temporary worktree, against today's
  rules, without touching your working tree.

### Requirements

- bash and git; `gh`, authenticated, for pull-request mode.
- Claude Code: the skill dispatches subagents.
- Rules in the repository: `CLAUDE.md` files, `.claude/rules/*.md` with a `paths:` list in the frontmatter,
  or both. Without any, only bugs, security and coverage are reviewed.

### Install

1. **Claude Code marketplace (recommended).** The only channel that installs the three agents.

   ```
   /plugin marketplace add seleziomar/claude-skills
   /plugin install by-the-book@seleziomar-skills
   ```

   On Claude Code 2.1.275 or later, one step: `/plugin install by-the-book --marketplace seleziomar/claude-skills`.
2. **Agent Skills CLI or a copy of the folder** (`npx skills add seleziomar/claude-skills`, or copy
   `skills/by-the-book` to `~/.claude/skills/`): the skill runs in fallback mode, on `general-purpose` agents
   that read the same agent files. A review costs about 20–30% more and the agents lose their read-only tool
   lock; the skill tells you when it happens.
3. **Claude.ai:** not supported. It cannot reach your repository.

### Quick start

In a repository with rules, ask your agent to "review my diff by the book", or call `/by-the-book:by-the-book`
(marketplace install) or `/by-the-book` (other installs). A pull request: "review PR 123 by the book". Past
commits: "review the commits `<A>..<B>` by the book".

### Running the tests

```
bash skills/by-the-book/tests/run-tests.sh
```

They build fixture repositories at run time and check the script (diff, exclusions, read map, rules, scopes,
range mode, cleanup), and they lock the words of `SKILL.md` and the agents that other parts depend on: the
output contract, the model table of the fallback path, and the absence of project data.

For the intent and the decisions behind it, see [docs/design/by-the-book.md](docs/design/by-the-book.md).

## Em português

**trial-by-fire** ("teste de fogo") é uma skill para testar a sua própria entrega antes de mandá-la à QA ou ao
cliente: ela confere a tela ao lado do protótipo, o código e a suíte completa, e entrega achados e um
relatório. A matriz de testes é mostrada e aprovada por você antes de qualquer clique. Instale com
`/plugin marketplace add seleziomar/claude-skills` e `/plugin install trial-by-fire@seleziomar-skills`, ou com
`npx skills add seleziomar/claude-skills`. Para começar, crie `docs/trial-by-fire/ENVIRONMENT.md` no seu projeto
a partir de `skills/trial-by-fire/environment-template.md` e peça um "teste de fogo" da sua entrega. O relatório
sai no idioma que você usa.

**by-the-book** ("conforme o livro") revisa a sua mudança contra as regras escritas do próprio repositório
(`CLAUDE.md` e `.claude/rules/`) e, na mesma rodada, procura bugs, falhas de segurança e falta de teste,
seguindo a política de testes escrita no projeto. Cada achado de regra cita a regra literalmente, e você
escolhe, achado por achado, o que corrigir. Revisa o diff local, um PR do GitHub ou um intervalo de commits
antigos (`--base <A> --head <B>`). Instale com `/plugin marketplace add seleziomar/claude-skills` e
`/plugin install by-the-book@seleziomar-skills`; pelo `npx skills` ou por cópia da pasta, ela roda em modo de
fallback, cerca de 20–30% mais cara. Peça "revisa meu diff pelas regras" ou chame `/by-the-book:by-the-book`.

## License

MIT, see [LICENSE](LICENSE).
