# GHL internal workflow API: protocol reference

Read this when a call fails, when the JSON shape looks new, or when you are adding a mode to `scripts/ghl_workflow_mapper.py`. Every request described here is a GET. The script implements all of it; this file exists so you can debug and extend it without reading 745 lines of Python.

## Contents

- The three hops (list, detail, step graph)
- Triggers are a separate object
- Failure semantics
- Politeness and runtime
- Step vocabulary: where the key facts live
- Resolving field and stage ids to names
- Extending the script

## The three hops (list, detail, step graph)

**Hop 1, list workflows.**

```
GET https://backend.leadconnectorhq.com/workflow/{locationId}/list?parentId=root&limit=500&offset=0
```

Headers as the script sends them: `token-id: <token>`, `channel: APP`, `source: WEB_USER`, `version: 2021-04-15`.

Where the token comes from: in a browser logged into GHL, DevTools, Network tab, any request to `backend.leadconnectorhq.com`. The sub-account's Settings, Custom Fields page reliably fires `GET https://backend.leadconnectorhq.com/locations/<locationId>/customFields/search?parentId=&skip=0&limit=10000&documentType=field&model=all&query=&includeStandards=true`; its Request Headers carry the `token-id` value the script needs. The same value is what the detail hop sends as `authorization: Bearer`.

The response has `rows[]`, each row carrying `type`, `id` and `name`. The root list is mostly **directories**, so a flat read of the root under-counts badly and every later count in your deliverable would be wrong. Recurse into each row with `type == "directory"` (or `"folder"`) using `parentId=<directoryId>` until you have every row with `type == "workflow"`.

**Paging.** The script requests `limit=500&offset=0` per folder and does not page beyond that single page. If a folder returns exactly 500 rows, assume there may be more: record the row count per folder, treat the total as possibly truncated, check that folder in the GHL UI, report it in the deliverable's Gaps section rather than as fact, and ask the script's owner for paging (an `offset` walk) before mapping an account that large.

**Hop 2, workflow detail.**

```
GET https://backend.leadconnectorhq.com/workflow/{locationId}/{workflowId}?includeScheduledPauseInfo=true
```

Headers: `authorization: Bearer <same token>`, `channel: APP`, `source: WEB_USER`, `origin: https://client-app-automation-workflows.leadconnectorhq.com`, `referer: https://client-app-automation-workflows.leadconnectorhq.com/`. The `origin` and `referer` are the GHL automation builder app host, and the script also sends the API `version` header it was written against. If the detail endpoint starts rejecting these, do not guess new header values: open DevTools on a working builder page, read the request headers GHL itself sends now, and report the difference before changing anything.

The list endpoint wants the token in `token-id`; the detail endpoint wants it as `Bearer`. Same value, different header. This is the single most common cause of a 401 on a token that is actually fine.

Response fields you need: `name`, `status` (published or draft), `dataVersion`, `fileUrl` (a signed Firebase Storage URL holding the step graph), and sometimes `triggersFilePath`.

**Hop 3, the step graph.**

```
GET <fileUrl>
```

No auth header: the URL is already signed. The body is JSON with `steps[]`. Save it as `<workflowId>.graph.json` next to `<workflowId>.detail.json`.

## Triggers are a separate object

`triggersFilePath` is the **unencoded** object path in the same Firebase bucket. Build its URL from `fileUrl`: keep everything up to and including `/o/`, append the triggers path percent-encoded as one segment, and reuse `fileUrl`'s query string.

<example>
Given, from the detail response:

    fileUrl           = https://<storage-host>/v0/b/<bucket>/o/<encoded-graph-path>?alt=media&token=<t>
    triggersFilePath  = locations/<locationId>/workflows/<workflowId>/triggers.json

Build:

    https://<storage-host>/v0/b/<bucket>/o/locations%2F<locationId>%2Fworkflows%2F<workflowId>%2Ftriggers.json?alt=media&token=<t>

Keep the prefix through `/o/`, percent-encode the whole triggers path as one segment (every `/` becomes `%2F`), and reuse the query string unchanged.
</example>

Two kinds of miss are normal and should be recorded as gaps rather than retried:

- A workflow with **no** `triggersFilePath` has no trigger of its own. It is only ever entered by another workflow's `add_to_workflow` step. Find its parents by searching the harvested graphs for that `workflow_id`.
- Some trigger objects return **HTTP 400** because Firebase download tokens are per-object, meaning the token on `fileUrl` is scoped to the graph object only.

### What a trigger object holds

A contact-field-change trigger has `type: contact_changed` and `conditions[]` entries with `id` (the custom-field id), `field` (`contact.<fieldId>`), `title`, `operator` (`has-changed`) and the workflow it starts under `actions[].workflow_id`. Other trigger types (`appointment`, `form_submission`, `customer_appointment`, `contact_tag`, `opportunity_status_changed`, `pipeline_stage_updated`, `customer_reply`, `call_status`) carry their filters in the same `conditions[]` shape. The `diagram` mode uses `contact_changed` triggers to draw "workflow A writes field F, F fires workflow B".

## Failure semantics

| Status | Meaning | Action |
|---|---|---|
| 401 | Token expired or invalid (the JWT lasts about an hour) | Ask for a fresh `token-id` and store it. That is almost always the answer; if a fresh token also 401s, stop and check the header form (`token-id` on the list hop, `authorization: Bearer` on the detail hop) |
| 403 | Token is not scoped to that location | Confirm the location id and the user's access |
| 404 on a single workflow id | The workflow was deleted after you listed it | Record it as a gap, do not retry it, carry on with the rest of the harvest |
| 404 on the list or detail endpoint for a location that worked minutes ago, or a changed JSON shape | GHL moved something | Stop the run and report the request path plus what came back instead. Do not retry in a loop |
| 503 | Transient | Note it and move on |

**What counts as a changed JSON shape.** Treat the shape as changed when a field this file says you need is absent: `rows[]` with `type` / `id` / `name` on the list hop, or `name` / `status` / `fileUrl` on the detail hop. A missing `triggersFilePath` or `dataVersion` is normal, and is a gap rather than a shape change.

## Politeness and runtime

Sleep one second between calls, which the script does. These are the endpoints the GHL web app calls under a human's hand, so a burst is both rude and the fastest way to get the pattern noticed and blocked, which would end the method for every account. A full sub-account of about 100 workflows takes a few minutes, so run the harvest in the background, then wait for it to exit and check its counts before running any offline mode.

## Step vocabulary: where the key facts live

Every step has `id`, `type`, `name` (the builder label, often stale), `order`, `parentKey`, `next` and `attributes`. Treat every row below as a hypothesis and verify it with a `schema` pass on every account before trusting it: GHL's step vocabulary drifts, and the names are not the obvious ones (there is no `send_sms`; sends are `sms`, `email` and `internal_notification`). Report any row your `schema` output contradicts.

| Step type | Key attributes |
|---|---|
| `if_else` | `branches[].segments[].conditions[]`, giving `conditionType` (`contact_detail`, tag, and others), `conditionSubType` (the **custom-field id** for contact_detail), `conditionOperator` (`==`, `has_value`, `has-changed`, and others), `conditionValue`. Leaf `branch-yes` nodes carry no conditions: read the parent. |
| `if_else` (membership test) | `conditionType: workflow_contact`, `conditionSubType: workflow_contact`, `conditionOperator` `index-of-true` / `index-of-false`, `conditionValue` = the **workflow id** being tested. This is "is the contact currently inside workflow X?", the edge the `diagram` mode draws in red. |
| `wait` | `startAfter{value,type}`, `appointmentStartAfter`, `window{start,end,days[]}`, `type` (time or link_clicked). **Also nests `condition.branches[]`** in the same shape as if_else. |
| `update_contact_field` | `fields[].field` (custom-field id), `.value`; `actionType` update or clear. |
| `math_operation` | `selectField` (read), `updateField` (**written**). It writes fields too. |
| `add_contact_tag` / `remove_contact_tag` | `tags[]` |
| `add_to_workflow` / `remove_from_workflow` | `workflow_id` (string or array) |
| `create_opportunity` | `pipeline_id`, `pipeline_stage_id`, `opportunity_status`, `monetary_value`. A step **without** `pipeline_stage_id` changes status and value only: it moves nothing. |
| `remove_opportunity` | `pipeline_id` |
| `sms` / `email` / `internal_notification` | `body`, `subject`, `to`. Truncate bodies in every print path. |
| `webhook` | `url`, `method`, `customData[]`, `headers[]`. **Headers carry plaintext secrets: never print them.** |
| `goto` | `targetNodeId`. Node ids survive cloning, so the same id can be compared across accounts. |
| `facebook_conversion_api` | `access_token`. **Never print it.** |

The `schema` mode prints, per type, the step count, the workflow count, and the union of attribute key paths with redacted sample values. That output, not this table, is the authority for the account in front of you.

## Resolving field and stage ids to names

Field and stage ids in a graph are opaque. Resolve them read-only, by any of these routes:

- **Public API v2**, where an ordinary API key or OAuth token is fine: custom fields at `GET https://services.leadconnectorhq.com/locations/{locationId}/customFields`, pipelines and stages at `GET https://services.leadconnectorhq.com/opportunities/pipelines?locationId={locationId}`. Reading them out of the GHL UI works too.
- **A data warehouse that syncs GHL**, joining on the field or stage id there.

Three rules for the join:

1. Resolve with an outer join so **unresolved ids are listed by name** rather than silently dropped.
2. An id that resolves only in a *different* location is a stale clone artefact. Flag it.
3. Trust ids, not labels. A step named "Move to X" can disagree with its real `pipeline_stage_id`, and the same drift produces the mislabelled triggers and stale wait labels in `pitfalls.md`: builder labels are free text nobody updates, and ids are what executes.

Contact custom-field **values**, meaning what a human actually typed into a contact, are not in any definition table. The only values this method can read are the constants the workflows test against and write. Say so in the deliverable's gaps section.

## Extending the script

Run `python3 scripts/ghl_workflow_mapper.py` with no arguments to print the full mode list and flags. That usage text is the authority on modes and flags; where it and a document disagree, follow it and say so in your report.

Extend it by adding a mode, never by adding a write. A new mode must reach the network only through the existing GET helper, which cannot send another method, and must print only through the existing redaction helpers, so URLs collapse to hostnames, free text truncates, and webhook headers and token-like keys blank out. Before you run a new mode on real data, run it once and read its output for anything that looks like a secret, a full URL with a query string, or a message body. The script needs Python 3.8+ and the standard library only: no curl, no packages.
