# Design: the `trial-by-fire` skill

## Intent

A project-agnostic, rigorous "test your own delivery" process to run before QA or the client sees the work.
The developer hands over a ticket, card, milestone or pull request; the skill tests it from every side QA
looks at (the screen next to the prototype, the code, the full test suite) and returns findings and a report.
The developer decides what to fix, through their normal flow. The skill does not replace QA, does not review
other people's code and does not implement fixes.

The process lives in the skill. Everything that is specific to a project lives in a file inside that project.

## Decisions

| Decision | Choice |
|---|---|
| Distribution | One repository serving three channels: the Claude Code marketplace, the open Agent Skills layout (`npx skills add`), and a plain copy or zip upload |
| Language | Skill text in English. The description carries trigger phrases in English and Portuguese. Matrix, report and messages are written in the user's language |
| Process vs environment | Process in the skill. Environment in each project's `docs/trial-by-fire/ENVIRONMENT.md` |
| Checklists | A generic checklist ships with the skill. A project may add its own optional `docs/trial-by-fire/checklist.md` in the same format. Phase 1 crosses both, generic first |
| Learning | A `learn` mode turns QA or client adjustments into checklist examples or classes. Generic lessons go to a writable clone of this repository; project-only lessons go to the project checklist |
| Tools | Generic. Browser: Claude in Chrome preferred, otherwise another automation with the same rules. Report: published as a private page only if a publishing tool exists, otherwise a local HTML file |
| Versioning | Semantic versions in `.claude-plugin/marketplace.json`. A checklist example or class is a patch bump |

Alternatives rejected: keeping one skill copy per project (copies diverge); keeping the skill only in a
personal skills folder (no history, no sharing); a bilingual skill text (maintenance cost).

## Repository layout

```
.claude-plugin/marketplace.json    one plugin "trial-by-fire", source "./", skills ["./skills/trial-by-fire"]
skills/trial-by-fire/
  SKILL.md                         the process: phases 0 to 6, fronts, excuses, red flags
  checklist.md                     generic defect classes (fixed format)
  environment-template.md          template of a project's ENVIRONMENT.md
  report-template.html             template of the HTML report
  tests/run-tests.sh               format checks
  tests/check-report.sh            contract of the generated HTML report
docs/design/trial-by-fire.md       this document
README.md, LICENSE (MIT)
```

The plugin namespaces the skill (`trial-by-fire:trial-by-fire`); with `npx skills` it has no prefix.

## The process

- **Two fronts, in order.** Front 1 (brute, functional): what corrupts data, blocks the user or leaks. Front 2
  (polish, prototype): every screen and state next to the prototype at 1,366, 1,600 and 1,920 px and on
  mobile. Front 2 starts when Front 1 has no open Bug or serious Correction.
- **Phase 0, survey:** read the environment file, derive the target, spec and diff (from the merge-base), and
  build the dimension matrix. An N/A dimension is written with a reason that is a fact from the code.
- **Phase 1, cases and CHECKPOINT:** cases cross both checklists, each with a front, a precondition, steps and
  an expected result observable on the screen. `matrix-and-cases.md` is shown and the skill stops until the
  developer approves.
- **Phase 2, environment:** pre-flight, test data per policy, a rollback inventory from the first minute,
  credential allow-list.
- **Phase 3, execution:** through a browser as the user, one profile and one case at a time, a screenshot per
  case; the "before" comes from a separate worktree at the merge-base.
- **Phase 4, suite:** full suite, isolated from the screen's data when possible, with attribution against a
  baseline.
- **Phase 5, report:** `matrix-and-cases.md`, `report.md`, a closed `rollback-inventory.md`, a self-contained
  HTML report and `images/`.
- **Phase 6, learn:** append-only changes to a checklist.

## File contracts

### Checklist format

Each class is a `## <name>` section with exactly these fields: `**Front:**` (`1`, `2` or `1 and 2`),
`**Applies when:**`, `**How to prove:**`, `**Examples:**`. The last class is `## Method rules`. The learn mode
only appends (an example at the end of `**Examples:**`, separated by ` · `, or a new class before
`## Method rules`); it never reorders or compacts.

### ENVIRONMENT.md headings

Twelve headings, in this order, kept in English even when the content is not:

1. `## Delivery sources`
2. `## Environment`
3. `## Profiles and test users`
4. `## Test data and rollback`
5. `## Servers`
6. `## Queue and e-mail`
7. `## Test suite`
8. `## Before (baseline) environment`
9. `## Results folder`
10. `## Project dimensions`
11. `## Gotchas`
12. `## Tracker`

An optional `## Skills repo clone` may follow, naming a writable clone for the learn mode.

### Report contract

The HTML report keeps `<meta name="report" content="trial-by-fire">` and the template's section ids, so the
title and text can be translated. Images are embedded as data URIs. `tests/check-report.sh <html>` must exit 0
before the report is shown.

### run-tests.sh modes

- No argument: checks `SKILL.md` (frontmatter, required terms, a verdict that needs both fronts),
  `checklist.md`, `environment-template.md` and that `report-template.html` passes `check-report.sh`.
- `--project <root>`: checks `<root>/docs/trial-by-fire/ENVIRONMENT.md` and, when it exists,
  `<root>/docs/trial-by-fire/checklist.md`.

## Non-goals

- Reviewing other people's code, or implementing fixes.
- Replacing QA.
- Shipping other skills now (the layout is ready for more).

## Anti-goals

- **No project data in the skill:** no project, client or company names, hosts, addresses, credentials or
  e-mail addresses. Anything project-specific belongs in that project's `ENVIRONMENT.md` or checklist. A leak
  scan runs before every push.
- **Never soften the discipline.** The CHECKPOINT, a screenshot per case, Front 2 as part of the verdict and
  the full suite stay mandatory. Without the suite, or with a front open, the verdict is "not ready".
- Credentials are typed only on local development hosts, or on test-marked hosts that the project lists
  explicitly. The agent never repeats a password.
