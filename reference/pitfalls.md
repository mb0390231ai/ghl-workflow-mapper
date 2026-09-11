# Pitfalls, and diffing a clone against its template

Check every workflow in your CORE and ADJACENT set against each pattern below before writing the deliverable. These are the things the workflow builder's own UI hides, and they are the reason reading the step graph is worth the effort.

## Contents

- Pitfalls to check for
- Diffing a clone against its template

## Pitfalls to check for

**Field-change triggers masquerading as form triggers.** A workflow named something like "... Form Submitted" may actually trigger on a contact field *has-changed*. Anything that writes that field fires it, including other workflows that merely *clear* it.

**Exact-match strings that can never match.** Branch `conditionValue`s are compared literally against what the form or integration actually writes. Read both sides. A value the form never sends is a branch that never fires, and it clones identically into every sub-account.

**Membership-in-workflow conditions.** A branch that tests "is the contact currently in workflow X" silently flips when X is disabled or bypassed.

**Flags that are never reset.** A "reminder sent" field set once per contact means every later visit skips the reminder.

**Stale step labels.** "5 Minutes After" with a 45-minute attribute; "Move to Stage A" targeting stage B. Read the attributes, not the label: builder labels are free text nobody updates, and ids are what executes.

**Status is not stage.** `create_opportunity` without `pipeline_stage_id` sets `won` or `open` and a monetary value but moves nothing. Never read `status` as a stage signal.

**Children have no trigger.** Workflows entered only by `add_to_workflow` come back from the trigger endpoint as an empty list. Find their parents through the parents' `add_to_workflow` steps.

**Tags nobody inside GHL reads.** Tags set and removed by workflows but tested by none are being consumed outside GHL: reporting, Zapier, Make, spreadsheets. Find the external readers before recommending that anyone drop them.

**Multiple writers.** The same tag or field written by three workflows is not a reliable single signal.

**Clone artefacts.** Stage ids, pipeline ids or `location_id` values belonging to a *different* sub-account inside a draft. Also whitespace-padded duplicates of the same merge token (`{{ custom_values.x }}` against `{{custom_values.x}}`), which are two distinct strings.

**Drafts.** Count them separately. A draft that is "the only workflow triggered by the form" is doing nothing.

## Diffing a clone against its template

Use this when a process works in one sub-account and not another. This reads more than one location, so ask the owner before you harvest any location they did not name in the request, saying which location and why (checkpoint 2 in `SKILL.md`).

1. Harvest the same workflow from both sub-accounts plus the template sub-account.
2. Print each workflow's branch conditions.
3. Compare. Per-location **field ids differ legitimately**, because custom fields are re-created on clone, but **`conditionValue` strings must be identical**. A difference there is the bug.
4. If the workflows are identical and correct, the difference is outside the automation, and it is usually a human doing by hand what the automation fails to do. Check stage-change timestamps to tell the two apart: automated writes trail their trigger by seconds, while human card moves lag by hours or days in business-hour batches.
