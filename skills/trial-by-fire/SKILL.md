---
name: trial-by-fire
description: >-
  Use when the developer is about to hand their own delivery (a ticket, card, milestone or pull request)
  to QA or to the client and wants it tested first, the way QA or the client would: through the screen next
  to the prototype, the code and the full test suite. Triggers: "trial by fire", "test it before QA",
  "test it like the client", "check it against the prototype", "what will QA catch here?", "teste de fogo",
  "roda o teste de fogo", "testa antes de mandar pra QA", "testa como o cliente", "confere com o protótipo",
  "o que a QA vai pegar aqui?". Also use when QA or client adjustments arrive and the developer wants those
  defects checked in future rounds ("/trial-by-fire learn", "aprende"). Do not use to review someone else's
  code or to implement a fix.
---

# Trial by fire

Tests YOUR delivery from every side QA looks at — the screen next to the prototype, the code, the suite —
before it reaches QA. Delivers **findings + a report**. The developer decides what to fix, and the fix follows
the normal flow (plan + TDD), outside this skill. It does not replace QA.

Below, "QA" means whoever receives the delivery next: a QA team or the client.

**Violating the letter of these phases is violating the spirit.** Skipping a phase "because this delivery is
simple" is exactly what let through what QA caught.

**Language:** write the matrix, report and messages in the user's language. File names, the `ENVIRONMENT.md`
headings and the report's section ids stay in English: they are checked.

## Two fronts

The round has two fronts, in this order. Kept apart, the visual detail does not compete for attention with
the serious bug, and the serious bug does not hide the visual detail.

- **Front 1 — brute (functional):** what corrupts data, blocks the user or leaks: writes, integrity,
  isolation, permission, server errors, async work, legacy data and the suite. The expected result is the
  behavior.
- **Front 2 — polish (prototype):** starts when Front 1 closes with no Bug or serious Correction open (fixed,
  or accepted by the developer). Every screen and every modal on the screen map, state by state (empty,
  loading, with a selection, error, success), next to the prototype, at 1,366, 1,600 and 1,920 px and on
  mobile: width, header, colors, typography, icons, arrows and balloons, dimmed or disabled rows, and nothing
  from the layout (fixed menu, floating widget) on top. Start by comparing the prototype's CSS with the
  components' CSS (this can go to an agent); the screenshot confirms.
- Front 2 is not "an improvement for later": a case that only expects "opens" or "becomes disabled" passes
  with the screen off the prototype, and QA is the one who catches it (a tour arrow pointing away from its
  target, a wide modal under the fixed menu, modal headers, an out-of-selection row that was not dimmed).
- A front is closed when every one of its cases ran, or when the matrix declares it N/A with a fact from the
  code (for example, the delivery has no screen). "There is no prototype" does not close Front 2: the screen
  is still compared with the product's existing screens (the source screen of a reused component), at the
  widths above, and its copy is reviewed.

## Where things are

- `<skill>` = the folder of this file. `checklist.md`, `environment-template.md`, `report-template.html` and
  `tests/` are in it. An installed copy lives in a cache folder and is overwritten on update: never edit it,
  and never write its path into a project file.
- **The project:** the repository where the session runs. Main clone:
  `dirname "$(git rev-parse --path-format=absolute --git-common-dir)"`.
- **`docs/trial-by-fire/ENVIRONMENT.md`** in the project: everything specific to the project — delivery
  sources, how to start the app, profiles and where the test credentials live, the test-data policy, servers,
  queue and e-mail, the suite command and its baseline, how to build the "before", the results folder, the
  project dimensions, gotchas, the tracker, and optionally the skills repo clone. Every environment-specific
  step below comes from it. Never invent a command it does not give.
- **`docs/trial-by-fire/checklist.md`** in the project: optional. Defect classes that only make sense for this
  project, in the same format as `<skill>/checklist.md`.
- **Results (the cycle folder):** the folder from `## Results folder` (default
  `docs/trial-by-fire/<target>/cycle-N/`, where `<target>` names the delivery — ticket, card, milestone or
  PR — and `N` = the next free number).

## Phase 0 — Survey

1. **Read the project's environment:** `docs/trial-by-fire/ENVIRONMENT.md`, its `## Gotchas`, and the
   optional project checklist `docs/trial-by-fire/checklist.md` if it exists. Check both with
   `bash <skill>/tests/run-tests.sh --project <project root>` (exit 0).
   - **No ENVIRONMENT.md** (or a heading or fact this round needs is missing): build a draft from
     `<skill>/environment-template.md` (same headings, same order) and from what the repository shows
     (README, compose or container files, Makefile, package and composer scripts, CI config, seeders,
     `.env.example`). What the repository does not answer goes into the single round of questions (item 5).
     Then show the draft and **ask before writing it**: write it only with the developer's OK, run the check
     above, and ask again before committing it.
   - **No project checklist:** Phase 1 runs with `<skill>/checklist.md` only. Do not create one just to have it.
2. **Derive without asking:**
   - the target of the round (ticket, card, milestone, PR);
   - the WHOLE spec from `## Delivery sources` (requirements, contracts, the product owner's or the client's
     decisions — when they diverge, the most recent wins), and what is pending or awaiting the client (that
     is not a defect);
   - the prototype and the QA test script, if they exist;
   - the diff from `git merge-base` with the integration target (never the target branch directly),
     separating **new file** from **file that already existed** (the second is regression risk).
3. **Dimension matrix.** For each dimension, give the proposed verdict and the reason. **An N/A dimension is
   written with its reason, never omitted.** The reason is a fact from the code, checked — not someone's word.

   | Dimension | Applies when | Proof |
   |---|---|---|
   | Item by item | creates or changes more than one configurable item | one scenario and one screenshot per item |
   | Combined | the row above applies | half switched on = the sum of the parts |
   | Profiles | lives behind a permission or role | one screenshot per profile, **including the denial or the absence** for whoever must not see it; users created through the screen (a superuser bypasses permissions) |
   | Isolation (tenant) | writes per tenant or reads data of another tenant or account | two tenants, including by direct URL |
   | Legacy data | changes how an existing record is read or written | a record created with the old code, opened with the new one |
   | Responsive | touched a view, CSS or JS | mobile screenshot of the changed screens and, in Front 2, wide screens (1,366, 1,600 and 1,920 px): modal and balloon whole, nothing from the layout on top |
   | Queue / e-mail | the action dispatches a job, a scheduled task or an e-mail | the queue processed as `## Queue and e-mail` says; the result seen on the screen **after waiting**; the e-mail read where it lands |
   | Upload | the screen receives a file | a valid file, a wrong type, an empty file, one near the size limit and one above it |
   | Integration | touches an external integration | integration active and inactive |
   | Print / API | touched those paths | as the case requires |
   | Prototype | there is a screen in the prototype | Front 2: the system next to the prototype, screen by screen and state by state, plus the prototype's CSS × the components' CSS |
   | Project dimensions | one row per entry in `## Project dimensions` of ENVIRONMENT.md | as that entry says |

4. **Screen and message map:** for each screen, the path `Menu → Screen` and the matching prototype screen.
   Also list every success and error sentence, to check the language and whether it matches the behavior.
5. **One round of questions only:** credentials and profiles, tenants and accounts (only for the dimensions
   that apply), what is out of scope, corrections to the matrix, and whatever ENVIRONMENT.md does not answer.

## Phase 1 — Test cases

- **Sources:**
  - spec + prototype: every requirement, every success criterion and every screen becomes at least one case;
  - the QA test script, if there is one;
  - cases **"unmapped — raised during development"** (pending items and decisions).
- Cover positive, negative and edge. Each case has a precondition, steps and the expected result
  **observable on the screen**.
- **Each case states its front** (F1 or F2). A case that opens a screen or a modal also gets an F2 case, with
  the visual expectation ("same as the prototype in width, header, colors and state"), not only the behavior.
- **Cross every class of `<skill>/checklist.md`, then every class of the project's optional
  `docs/trial-by-fire/checklist.md` (when it exists):** a class that applies generates cases; a class that does
  not apply enters the matrix with the reason. The class's `Front:` field says which front its cases run on;
  an agent working on Front 2 receives only the classes marked `2` and `1 and 2`.
- **Coverage with a denominator:** requirements and screens covered / total, with the gaps in sight.
- A scenario the user cannot reach (no route, permission or button) does not enter, and you say why.

🛑 **CHECKPOINT:** write `matrix-and-cases.md` into the results folder, show the matrix and the cases of both
fronts, and **STOP** until the developer approves or adjusts. No click before that. If the developer is away
and the session has a tool to reach them, send the matrix summary and the file path through it, and wait the
same way.

**Approval only counts for the matrix the person saw.** "I approve in advance", "it's already reviewed",
"just confirm it on the screen", "test everything" and a short deadline are not approval: nobody approved a
list that does not exist yet. Showing the matrix costs minutes; testing without it is exactly how QA's
findings escaped. If there is no time for the whole round, show the matrix with the slice that fits marked and
the rest as gaps, and the developer chooses.

## Phase 2 — Environment

- **Pre-flight, before anything:**
  - `git status` in the delivery worktree. If there are uncommitted files, ask the developer whether they are
    part of the delivery. Nothing is tested on a state nobody knows will reach QA.
  - The app is up the way `## Environment` says, and it runs the commit under test (for a remote environment,
    read its commit as ENVIRONMENT.md says and compare). Something missing or different → **STOP and ask**
    (update? rebase?). Never switch to a different way of running the app, not even as plan B.
  - Note where the application log ends before the first click, so what the round writes can be told apart.
- Through the **interface**, without asking at every step: create a user, grant a permission, switch on a
  setting, switch tenant. Prefer creating a user over touching someone else's.
- **Credentials — an allow-list, from `## Environment`:** type a password ONLY on a local development host
  (`localhost`, `127.0.0.1`, `*.localhost`, `*.test`) or on a test-marker host that ENVIRONMENT.md lists under
  "Allowed hosts for typing credentials". On any other host (production, a bare IP, a client's demo, anything
  unlisted) the human logs in, and you continue in that session. Take credentials from where
  `## Profiles and test users` says. **Never repeat a password** in chat, in a file or in the report.
- **Never change the password of an account you did not create.** Need another user → create it through the
  screen. Only if ENVIRONMENT.md explicitly allows resetting a test user: save every credential column first,
  change it through the screen, restore ALL of them at the end, never write the hash anywhere (file, report,
  chat), and record it in the inventory.
- **Test data**, per `## Test data and rollback`: through the screen by default. Writing directly to a
  database only on a local one, and only if the project or the developer authorized it. When the screen
  cannot produce an input (a spreadsheet to import, a file to upload), generate it with a throwaway script
  outside the repository, deleted at the end. Name the data so it is easy to find (`TF cycle-N …`).
- **Servers**, per `## Servers`: what is read-only stays read-only — no SQL that writes, no console that writes,
  no edited file. Diagnostic reads (SELECT, logs) are fine. The only write exception is what the developer
  authorizes in Phase 0, and it goes in the inventory. A server not listed is not touched.
- **Rollback inventory** (`rollback-inventory.md`) from the first minute: everything created or changed goes in
  right away, with how to undo it (or "stays until …", with the reason).
- **Queue**, per `## Queue and e-mail`:
  - before starting, check for old jobs stuck in the queue (they run together with yours);
  - process the queue the way ENVIRONMENT.md says, and declare that in the report.

## Phase 3 — Execution, case by case

- **The screen through a browser, as the user.** Prefer Claude in Chrome; if it is not available, use another
  browser automation tool with the same rules. Never the QA's automation suite.
  - Click as the user: no internal route and no state set by script. The only exception is an isolation case,
    where typing another tenant's URL in the address bar **is** the test.
  - The click that proves a case is by **coordinate**, on the visible point of the control; refs and
    JavaScript find the element even when it is covered. A control that does not respond:
    `document.elementFromPoint(x, y)` at the same point says what is on top of it.
  - Files through the automation's file-upload action on the file field (never the native file picker). Test
    files live outside the repository.
  - **One profile at a time:** log in and out through the screen; to switch profile, log out and log in again
    (tabs share the session).
  - **One case at a time. A scenario without a screenshot did not happen.** Every screenshot is saved to
    `images/` in the results folder.
  - **Front 1 first**, until it closes; **Front 2** comes after, on the already-fixed code.
  - In Front 1, compare **only the control** (a zoomed crop), next to the prototype's screenshot. In Front 2,
    compare the **whole screen** and the container (modal, balloon, row), not only the control: width, header
    and dimmed state vanish in a crop of the control.
  - **"Before", pre-existing behavior and legacy data come from a separate worktree at the merge-base,**
    built as `## Before (baseline) environment` says (its own environment name, ports and database). Never
    swap files in the delivery worktree: the screen runs from it, and the developer's uncommitted work can be
    lost.
    - **Legacy data:** when the baseline has its own database, the record does not cross over to the
      delivery. Create it through the baseline's screen, then move THE BASELINE's code to the delivery commit
      (`git -C <baseline> checkout --detach <delivery commit>`, then migrations and assets there, as
      ENVIRONMENT.md says) and open the same record. The baseline worktree is disposable; the delivery's
      stays untouched.
    - At the end, remove the baseline worktree, its environment and its branch, and add a line to the
      inventory. Validate by absence (the directory and the database are gone).
  - Measure async work **after waiting**.
  - Legacy data last.
- **Code:** read the checklist classes that only show by reading (integrity, isolation, defaults, hidden field
  still submitted, text × behavior, lock order). In a large delivery this can go to an agent, and you verify
  every serious finding personally.
- **Finding:**
  - classify it as QA does: **Bug / Correction / Requirement divergence** (the product owner or the client
    decides) **/ Improvement**;
  - include the steps, expected × actual, the screenshot and `file:line`;
  - **pre-existing is proven** by reproducing it on the baseline;
  - a decision already taken, or an item awaiting the client, is not a finding unless the behavior
    contradicts it;
  - do not hunt for defects to look useful.

## Phase 4 — Suite

- The delivery's tests run on any machine: no fixed seed ids and **no skip**.
- Start the full suite at the **start of Phase 3**, in the background, with the command from `## Test suite`,
  on the delivery commit, so it runs while you test the screen.
  - Isolate it from the UI's data when the project allows (its own database or schema, or its own worktree, as
    ENVIRONMENT.md says). A suite that shares the database with the screen produces false failures on both
    sides: a lock timeout on the screen, a false server error, a test broken because the screen switched the
    active tenant.
  - Never two suite runs on the same database at the same time (spurious deadlocks and failures).
  - A worktree or database made for the suite is removed at the end, with its line in the inventory.
  - A CI run counts only when `## Test suite` says the suite runs there and the run is of the exact commit
    under test; write down which run.
- **Attribution:**
  - compare the run with the baseline (the known failures in `## Test suite`, or a run from before the
    delivery);
  - what fails now and did not fail before: run it again on the parent (the merge-base);
  - whatever is left answers three questions: does it pass in isolation? does it touch the delivery's code?
    is it flaky without any change?
- Without the suite, the verdict is "not ready".

## Phase 5 — Report and artifact

Write into the cycle folder:
- `matrix-and-cases.md`;
- `report.md`: findings by severity and by front; the verdict is **"ready"** only with both fronts closed and the suite run, otherwise **"not ready"**; pending decisions; the suite with its attribution;
- `rollback-inventory.md`, **closed** (what was undone, and what stays and why);
- `trial-by-fire-<target>-cycle-N.html`, from `<skill>/report-template.html`, with the images **embedded** as
  data URIs (only in `src`, with no `<a>` around them). Keep its `<meta name="report" content="trial-by-fire">`
  and its section ids; the title and the text follow the user's language. Before showing it, run
  `bash <skill>/tests/check-report.sh <html>`: exit 0, otherwise fix it;
- `images/*.jpg`.

Show what you wrote and **ask before any commit and push** (images and the HTML stay out of git, as
`## Results folder` says). Publish the HTML as a private artifact if an artifact or page-publishing tool exists,
and hand over the link; otherwise hand over the local path. If `## Tracker` names a place, comment the result
there (verdict, counts, where the report is).

## Phase 6 — `/trial-by-fire learn <file or text>`

1. Read the adjustments QA or the client sent. For each finding, decide: an **example** in a class that
   already exists, or a **new class**. Then decide where it belongs: **generic** (it could happen in any
   project) or **project-only** (it depends on a rule, screen or term of this project).
2. **Append only**, in either checklist: an example at the end of the `**Examples:**` line (separated by
   ` · `); a new class before `## Method rules`, in the file's format, with the `**Front:**` line (`1`, `2` or
   `1 and 2`). Never reorder or compact.
3. **Generic lesson** → `skills/trial-by-fire/checklist.md` in a **writable git clone of the skills
   repository**. The installed copy is overwritten on the next update and reaches nobody.
   - The clone's path comes from `## Skills repo clone` in ENVIRONMENT.md; not there → ask. Never guess.
   - `git pull` before editing.
   - Bump the **patch** version of the plugin in `<clone>/.claude-plugin/marketplace.json`: without it, the
     installed copies do not receive the lesson.
   - Run `bash <clone>/skills/trial-by-fire/tests/run-tests.sh`. It must exit 0.
   - Show the diff and **ask before the commit and the push** (or before opening a pull request, when the
     person does not own the repository).
4. **No clone** (only the read-only installed copy) → write the lesson into the project's
   `docs/trial-by-fire/checklist.md` and suggest opening an issue or a pull request at
   https://github.com/seleziomar/claude-skills with it.
5. **Project-only lesson** → the project's `docs/trial-by-fire/checklist.md`.
   - A new project checklist copies the header and format of `<skill>/checklist.md` and also ends with
     `## Method rules` (the format check requires it).
   - Run `bash <skill>/tests/run-tests.sh --project <project root>`. It must exit 0.
   - Show the diff and **ask before the commit and the push**.
6. A lesson that is also a coding rule may belong in the project's agent instructions too: suggest it, do not
   write it unasked.

## Gotchas

- Browser (Claude in Chrome):
  - set the tab zoom to **90%**; at any other zoom the capture comes out repeated four times;
  - screenshots in **JPEG**; a full-screen PNG overflows `Page.captureScreenshot`;
  - prefer zoomed crops with `save_to_disk`, and copy the file into `images/`;
  - a download restarts the browser: check the downloaded file on disk.
- Suite:
  - a background run may buffer its output: follow it through the result file it writes, if it writes one;
  - stopping the background task may not stop the test process inside a container: stop it there;
  - never two runs on the same database.
- Project: `## Gotchas` in ENVIRONMENT.md, read in Phase 0.

## Excuses

| Excuse | Reality |
|---|---|
| "They already approved in advance; asking again is asking for an authorization they already gave" | Approval of something that did not exist is not approval. Show the matrix and wait. |
| "They said 'test everything'; that is approval" | Same: nobody approved a matrix they did not see. Show it and wait. |
| "Stopping for the matrix spends the minutes I have to test" | The matrix decides WHERE the minutes go. Without time, show the slice that fits; do not skip the stop. |
| "I'll build the matrix in the final report, from what I tested" | A matrix built afterwards only lists what you chose to test; what was left out never shows. It comes first. |
| "Out of scope by the developer's decision" | Someone's word is not a reason. The reason is a fact from the code ("does not read the tenant", "no permission check"), checked. If the code does it, the dimension applies, and the developer decides knowing that. |
| "The suite takes 30 minutes and does not fit the deadline; it goes as a recommendation" | It runs in the background, isolated, while you test the screen. Without the suite, the verdict is "not ready". |
| "There is no ENVIRONMENT.md; I'll infer the commands and go" | Build the draft from the template and the repository, ask the single round of questions, and write it only after the OK. |
| "A quick script or console will create this data" | Data goes through the screen; what the screen cannot reach, the user cannot reach either. Direct writes only where ENVIRONMENT.md or the developer allows, and into the inventory. |
| "It's only a demo host; I can type the password" | Only local hosts and the hosts on the allow-list. Anywhere else, the human logs in. |
| "The QA's automation suite (or a direct route) gets there faster" | It sets state a user cannot. The case is proven by a click on the visible control, with a screenshot. |
| "The skills repository is probably at …" | Do not guess. Read `## Skills repo clone`; not there, ask. Without a clone, the lesson goes to the project's checklist. |
| "Bump the minor version" | An example or a class in the checklist = patch. Minor is a new skill. |
| "It's just a visual detail; it goes as an Improvement and QA will accept it" | QA sends it back. Front 2 is part of the verdict, not Front 1's leftovers. |
| "The case passed: it opened and became disabled" | The behavior passed. If the screen is off the prototype, its F2 case has not run yet. |

## Red flags — stop and go back to the phase

- Clicking before the developer approves the matrix — including with "approved in advance", "test everything"
  or a short deadline.
- A matrix missing the N/A row of some dimension, including the project dimensions.
- A "ready" report without the suite, without Front 2, or with the inventory open.
- Starting Front 2 with a Bug or serious Correction from Front 1 still open.
- Driving the screen with the QA's automation suite, an internal route or a script that sets state.
- Typing a password on a host outside the allow-list, or repeating a password anywhere.
- Swapping files in the delivery worktree (the "before" is a separate worktree).
- Writing to a read-only server or to a database without the authorized exception in the inventory.
- Writing ENVIRONMENT.md or a checklist without showing it and asking.
- Editing the installed copy of the skill instead of a clone.
- Publishing the report without `check-report.sh` exiting 0.
