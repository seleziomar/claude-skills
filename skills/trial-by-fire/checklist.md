# Trial by fire checklist

Defect classes that QA caught and the developer missed. Phase 1 crosses EVERY class with the delivery:
a class that applies generates test cases; a class that does not apply is declared N/A with the reason.

This is the generic checklist that ships with the skill. A project may also keep its own optional
`docs/trial-by-fire/checklist.md` with classes that only make sense for that project (same format).
Phase 1 crosses both: this one first, then the project's.

Fixed format (`tests/run-tests.sh` fails outside it). The "learn" mode only APPENDS: an example at the end
of the Examples line of the right class, or a new class at the end of the file, before "Method rules".
Never reorder or compact.

`**Front:**` says which front the class is crossed on: `1` (functional), `2` (prototype), or `1 and 2`.
Phase 1 crosses only the classes of the front in progress; a new class declares its own.

## Screen different from the prototype
**Front:** 2
**Applies when:** the delivery has a screen in the spec's `prototype/`.
**How to prove:** screenshot of the system next to the screenshot of the prototype, screen by screen and state by state (empty, error, success); list every difference in text, color, icon, order and spacing. The prototype is a requirement too.
**Examples:** rules modals with cards, bands and stars that were not in the prototype · an order label and help texts that diverged from the prototype · a tour arrow pointing away from its target, a rules modal far wider than designed with titles in the wrong color, modal headers and an out-of-selection row that was not dimmed — the test cases only expected the behavior ("opens", "disables") and passed.

## Control that does not show its own state
**Front:** 1
**Applies when:** the screen has a checkbox, toggle, select or tab whose state decides what happens.
**How to prove:** change the control through the screen and compare ONLY the control (zoomed crop), not the whole screen; check that the visible state is the one that gets submitted.
**Examples:** an export checkbox did not reflect the selection.

## Dynamic screen that does not react to a change
**Front:** 1
**Applies when:** one field hides, shows or changes another (group, type, segment).
**How to prove:** change the parent field in both directions (A→B and B→A) and check what appears and disappears; reload the screen with the value already saved.
**Examples:** choosing a certain group did not hide a grid that only applies to other groups.

## Hidden field that is still submitted
**Front:** 1
**Applies when:** the screen hides a field by rule (product type, segment, permission).
**How to prove:** with the field hidden, save and read the validation and what was stored; read in the code whether the field goes in the request and whether the validation rule requires it.
**Examples:** a field that only applies to one product type was still required when saving another type.

## Default value that contradicts the spec
**Front:** 1
**Applies when:** the spec defines an initial value, a default, or "nothing selected".
**How to prove:** open the new screen (no data) and compare each default with the requirement; read the default in the code (view, JS, migration).
**Examples:** an option came pre-selected although the requirement said nothing should be selected.

## Async flow with no feedback to the user
**Front:** 1
**Applies when:** something runs in a queue, job or polling (import, export, sending).
**How to prove:** process the queue by hand, WAIT, and check without refreshing that the screen shows the result; the result cannot exist only in the log.
**Examples:** a list did not update when the job finished · an undo action required a page refresh · an outcome was written only to the log.

## Election or state rule
**Front:** 1
**Applies when:** a button, action or status depends on "which is the latest", "which is active", or on a state transition.
**How to prove:** build the edge case (a record with no effect, two candidates, an intermediate state such as "Processing") and check which one is elected and what the screen allows.
**Examples:** an import that changed nothing was elected as "the latest" and blocked the Undo button.

## Data integrity on reversal
**Front:** 1
**Applies when:** the delivery undoes, refunds, cancels or reverts something.
**How to prove:** compare the state BEFORE the operation with the state AFTER undoing it, field by field (records, stock, links); include the case where the operation switched on a flag that changes its effect.
**Examples:** a reversal restored only part of the changed fields · stock was not restored when the imported file had switched on a "track stock" flag.

## Special input becomes data
**Front:** 1
**Applies when:** the input accepts a keyword, wildcard or reserved value (`CLEAR`, empty, zero).
**How to prove:** use the keyword in each column where it makes no sense (key, identifier) and check that it does not become a record.
**Examples:** the clear keyword typed in the key column created a record named after it.

## Isolation by direct URL
**Front:** 1
**Applies when:** the screen or export reads data scoped by tenant or account.
**How to prove:** with two tenants, open the other tenant's URL directly in the address bar (change the record id) and check that nothing leaks; read the query scope in the code.
**Examples:** an export returned the data of every tenant in the account instead of only the selected one.

## Server error on the main path
**Front:** 1
**Applies when:** always.
**How to prove:** run the happy path end to end through the screen and read the application log at the end, not only the screen.
**Examples:** an export returned a server error.

## Text that does not match the behavior
**Front:** 1 and 2
**Applies when:** the delivery has help text, a rule description, or a success or error message.
**How to prove:** for each sentence, find in the code the behavior it describes and check that it is the same (including after scope changes).
**Examples:** the help text of a coefficient field described a different calculation · a requirement made stale by a new "Processing" state.

## Language and copy review
**Front:** 2
**Applies when:** the delivery has new user-visible text.
**How to prove:** read each sentence on the screen (not in the code): grammar, agreement, capitalization, consistent final punctuation, wording the product owner approved.
**Examples:** a wrong article in a label · messages reviewed with the product owner.

## Invalid input refused silently
**Front:** 1
**Applies when:** the screen receives a file, date, number or selection that may come wrong.
**How to prove:** submit the wrong input (a file that is not a spreadsheet, empty, wrong format) and check that a clear message appears, with no server error and nothing silently happening.
**Examples:** uploading a file that is not a spreadsheet.

## Stuck navigation
**Front:** 1
**Applies when:** the delivery creates a screen, modal or redirect.
**How to prove:** from each screen, go back (Back button, breadcrumb, browser button) and check that it leaves; look for "feature not available" screens with no exit.
**Examples:** a "feature not available" screen with no way out.

## Spacing and alignment
**Front:** 2
**Applies when:** the delivery touched a view or CSS.
**How to prove:** zoomed crop of neighboring pairs (label × button, icon × text) compared with the prototype; check on mobile too.
**Examples:** controls misaligned against the prototype · a label and its button too close together.

## Lock order in a transaction
**Front:** 1
**Applies when:** the delivery writes to more than one table inside a transaction, or touches stock or balances.
**How to prove:** read the acquisition order in the code: the parent record is locked (`SELECT ... FOR UPDATE`) before writing children that take a lock through the foreign key; two code paths never lock in opposite order.
**Examples:** a refund moved stock before locking the product row.

## Reused component different from its source screen
**Front:** 2
**Applies when:** the delivery brings to a new screen a component that already exists on another (modal, upload, field, grid), or the spec says "same as", "same component", "reuse".
**How to prove:** open the source screen and the new screen side by side and compare the component in EVERY state (open, after choosing or filling, error, success): position, title, colors, buttons, icons and extra elements (QR code, help). The prototype does not replace the source screen. Read in the code whether the new screen loads the same CSS and JS as the source: the styling is often in a file that only the source screen includes.
**Examples:** an upload modal reused on a new screen without the stylesheet the source screen loaded: too tall, title unstyled, Cancel and Submit buttons stuck together.

## Screen cut off or covered by the layout on a wide screen
**Front:** 2
**Applies when:** the delivery has a modal, balloon, tour or any floating or wide element (a large modal class, width in `%`/`vw`).
**How to prove:** open each one at 1,366, 1,600 and 1,920 px and check that it shows in full with nothing from the layout on top (fixed side menu, chat widget): screenshot, and `document.elementFromPoint` at the four corners must land inside it. Read in the code where it is mounted: inside a `position: fixed` container its own `z-index` does not lift it above the menu.
**Examples:** a wide rules modal had its left edge under the fixed side menu; it was mounted inside a `position: fixed` container, so raising its `z-index` did nothing.

## Data written by the delivery and edited on another screen
**Front:** 1
**Applies when:** the delivery writes a field that another screen also creates or edits (a record form, a setting).
**How to prove:** find the screen that owns the field and use it as the user would: create a new record through it, and on an existing record edit and clear the field through it and save. Then run the delivery over those records (write, Undo, a "only where empty" option) and reopen each one on the owning screen, field by field.
**Examples:** a review screen writes a grid, but the record form owns it: unchecking an option and saving did not clear it (an empty multi-select is not sent in the POST), and every new record was born with a hidden radio's default, which flagged it as "Divergent" and left it out of the "only records that have no grid yet" option.

## Method rules
**Front:** 1 and 2
**Applies when:** always — these are the rules of the round itself.
**How to prove:** the report shows each one followed.
**Examples:** one case at a time, never in a block · a scenario without a screenshot did not happen · a dimension that is N/A is declared with the reason · measure async work after waiting · a scenario the user cannot reach does not enter · do not hunt for defects to look useful · pre-existing is proven by reproducing on the base · legacy data last · Front 1 (functional) before Front 2 (prototype), and the verdict needs both · a case that opens a screen or modal also has a visual expectation, not only the behavior.
