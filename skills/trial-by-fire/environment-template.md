# Trial by fire: project environment

Copy this file to `docs/trial-by-fire/ENVIRONMENT.md` in your project and fill it in. The content may be in any
language; keep the headings below exactly as they are (they are checked). The examples describe a fictional app,
"Acme Orders", at `https://app.localhost`. Replace them with your own facts. Never put a real password here.

## Delivery sources

Say where the delivery is specified and how to find what changed.
- Specs, plans and decisions: path or link.
- Prototypes or mockups: path or link. QA test script, if one exists: path or link.
- Diff base: the merge-base between the delivery branch and the integration target.

Example:
- Specs and plans: `docs/specs/` and `docs/plans/`. Prototypes: `docs/prototypes/`. QA script: `docs/qa/script.md`.
- Diff base: `git merge-base HEAD origin/main`.

## Environment

Say how to start the app and where it answers.
- Start command, URL(s), ports, and anything about https (self-signed certificate, proxy).
- Credential rule: the agent types a password only on a local development host (exactly `localhost`,
  `127.0.0.1`, `*.localhost`, `*.test`) or on a host whose name carries a test marker (`staging.`, `homolog.`,
  `dev.`, `test.`, `qa.`). A production-looking host is logged in by the human, and the agent continues in that
  session. The agent never repeats a password in chat.

Example:
- Start: `docker compose up -d`. URL: `https://app.localhost` (self-signed certificate; accept it once). API on port 8080.
- Allowed hosts for typing credentials: `app.localhost` and `staging.acme-orders.example`.

## Profiles and test users

Say which roles matter and who the test users are.
- One test user per profile that changes behavior (admin, staff, customer, ...).
- Where each credential lives: a seed or fixture file path, or "ask the dev". Never paste a real password.
- Never reuse or change the password of another person's account.

Example:
- Profiles: admin, operator, customer. Users are created by `database/seeders/DemoSeeder.php`; the password is
  in that file. For anything else, ask the dev.

## Test data and rollback

Say how test data is created and removed.
- Default: create data through the UI. Write directly to a local database only if the project or the dev authorizes it.
- Name test data so it is easy to find, for example `TF cycle-N <what>`.
- Every change is undoable; record how in `rollback-inventory.md` inside the cycle folder.

Example:
- UI only. Direct SQL is allowed on the local database only. Naming: `TF cycle-2 order 001`.
- Undo: delete rows whose name starts with `TF cycle-2`; listed in `rollback-inventory.md`.

## Servers

Say which remote servers exist and what is read-only.
- Hosts and what may be done on each (for example logs and SELECT only).
- Write "none" if everything is local.

Example:
- `staging.acme-orders.example`: read-only (logs and SELECT). Production: not touched.

## Queue and e-mail

Say whether background work and mail matter.
- Whether a worker must run, and how to process the queue.
- Where outgoing e-mail lands (mail catcher URL, log file).

Example:
- Worker: `docker compose exec app php artisan queue:work --once` after each action that queues a job.
- E-mail: mail catcher at `http://app.localhost:8025`.

## Test suite

Say how the automated suite runs and how to read it.
- Command, and where it runs.
- Whether it shares the database with the UI. If so, isolate it (separate database or schema) so it cannot wipe test data.
- Baseline: known failures. Attribute a new failure to the delivery by running the same test at the merge-base.

Example:
- Command: `docker compose exec app composer test`. Uses a separate `acme_test` database.
- Baseline: 2 known failures in `ReportExportTest` (also fail at the merge-base).

## Before (baseline) environment

Say how to see the "before": pre-existing behavior and legacy data.
- Use a separate worktree at the merge-base, never the delivery worktree.
- Give the baseline its own environment name, ports and database so it does not collide with the delivery.

Example:
- `git worktree add ../acme-before $(git merge-base HEAD origin/main)`; run it as compose project `acme-before`
  on `https://before.app.localhost`.

## Results folder

Say where each cycle's evidence goes.
- Default: `docs/trial-by-fire/<target>/cycle-N/`.
- Images and HTML reports stay out of git.

Example:
- Default folder. `.gitignore`:
  ```
  docs/trial-by-fire/**/*.png
  docs/trial-by-fire/**/*.html
  ```

## Project dimensions

Add rows to the dimension matrix for things specific to this project.

| Dimension | Applies when | Proof |
|---|---|---|
| Multi-tenant isolation | The change reads or writes tenant data | Log in as a user of tenant B and confirm tenant A data is not visible |

## Gotchas

List environment quirks that cost time, one line each.

Example:
- The first request after `docker compose up` is slow (cache warm-up); wait for `/health` before testing.
- Sessions expire after 15 minutes; log in again before long checks.

## Tracker

Say where the result is posted: an issue, a card, a PR comment, or "none".

Example:
- A comment on the delivery's pull request, with a link to the cycle folder.

## Skills repo clone

Optional. Local path of a writable git clone of the skills repository; the "learn" mode records generic lessons
there. Omit this section if there is none.

Example:
- `~/src/claude-skills`
