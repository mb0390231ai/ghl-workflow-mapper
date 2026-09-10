#!/usr/bin/env bash
# Installs the ghl-workflow-mapper skill into the current directory's .claude/skills/
set -euo pipefail
ROOT=".claude/skills/ghl-workflow-mapper"
mkdir -p "$ROOT/reference" "$ROOT/scripts"
cat > "$ROOT/SKILL.md" <<'GHL_MAPPER_EOF'
---
name: ghl-workflow-mapper
description: "Maps the real internals of every GoHighLevel (GHL / LeadConnector) workflow in a sub-account: triggers, branch conditions, waits, custom-field reads and writes, tags, webhooks and pipeline-stage moves, none of which the public API or the GHL MCP server exposes. Read-only, through the same requests the browser makes when the workflow builder is open. First produces a dependency diagram of how the workflows trigger, add to, remove from and gate each other; then answers questions about them and audits for hidden problems on request. Use when an agency needs to see how its GHL automations fit together, know which workflows touch a process before changing or disabling it, find out why a workflow does or does not fire, or check which custom fields and custom values an automation chain depends on."
---

# GoHighLevel workflow mapper

GoHighLevel's public API (v2) and the GHL MCP server return workflow **metadata only**: id, name, status, version. Neither returns the actions inside a workflow, so every real question about an automation (what fires it, what it tests, what it writes, which other workflows it starts or stops) needs the step graph. This skill reads that graph with the same read-only requests the browser makes when the builder is open, draws the dependency map, and then lets you answer questions about the workflows with the definitions in hand.

Two ways to use it, in order:

1. **Map.** Get consent, get the token, download the workflow definitions, draw the diagram. Nothing else. This is the default when someone invokes the skill.
2. **Audit.** Only when the owner asks: answer questions about specific workflows, run the pitfall pass, and if they want a written inventory, build the tables.

Where a step says **ask the owner**, stop and ask. Guessing produces a document that reads as authoritative and is wrong.

## Checkpoints: stop and ask

1. **Before the first network call:** the read-only note and the terms note, read to the owner in plain words and accepted, with a record of who accepted and when (guardrail 2, Map step 1).
2. **Before reading any location the owner did not name:** say which location and why (guardrail 7).
3. **Before any audit work:** the owner has asked for it and named the process or the question. The map step ends with the diagram; do not slide into an audit uninvited.
4. **Before classifying (audit only):** confirm the anchor workflow and the names to pass to `--core-names`.
5. **Before filling any Disposition cell (audit only):** the disposition is the owner's decision, apart from the two pre-fills the audit step names.
6. **Before the diagram or any deliverable lands anywhere shared** (repo, wiki, ticket): show it in the session first. It names live client automations.

Everything else in this file you may do without asking, as long as it is a GET and it is redacted.

## Files in this skill

| File | What it holds | When to open it |
|---|---|---|
| `scripts/ghl_workflow_mapper.py` | The whole tool: harvest, diagram, and every analysis mode. Python 3.8+, standard library only, no curl and no packages. | Run it. Read a named function only when you are adding a mode. |
| `reference/protocol.md` | The three endpoint hops, exact headers, paging, the trigger-object URL rule with a worked example, failure codes, the step-type vocabulary, and how to resolve field and stage ids to names. | A call fails, the JSON shape looks new, or you are extending the script. |
| `reference/pitfalls.md` | The failure patterns to check workflows against during an audit, and how to diff a clone against its template. | Audit mode, before answering "what could be wrong here". |

Run the script; do not paste its source into the conversation. Its output is the thing you reason over. Treat the script's own usage text (`python3 scripts/ghl_workflow_mapper.py` with no arguments) as the authority on modes and flags; if a flag here and a flag there disagree, follow the usage text and say so.

## Guardrails

1. **Send GET and nothing else.** Every network call in the script is an HTTP GET. Route any call you add through the script's existing GET helper, which cannot send another method. A write mutates a live automation in a client's account, and the workflow builder has no undo.
2. **Get consent before the first call.** These are the same requests the GHL web app sends when a person opens the workflow builder, and the tool only ever reads. They are not part of GHL's public API, GHL can change them without notice, and the owner should check that this use is acceptable under their own agreement with GHL. Tell the account owner exactly that, in plain words, and wait for an explicit yes before any call. Write down who accepted and when.
3. **Stop when the endpoint changes.** A 404 on a single workflow id means that workflow was deleted after you listed it: record it as a gap, do not retry it, and carry on. A 404 on the list or detail endpoint for a location that worked minutes ago, or a response missing a field `reference/protocol.md` says you need, means GHL moved the endpoint: report the request path and what came back, and stop the run. Do not retry in a loop; a retry loop against these endpoints is what gets an agency blocked.
4. **Treat the session token as a live credential.** Store it in the operating system secret store and let the script read it from there. The token is agency level: one copy reads every sub-account the login can see, and a shell command carrying it is recorded in shell history and in this transcript. The script also accepts a `GHL_TOKEN_ID` environment variable for runners that inject secrets themselves; in an interactive session prefer the secret store, and if you do use the variable, set it inline for the single command (`GHL_TOKEN_ID="$(secret lookup command)" python3 ...`) and never `export` it. Print only the token length, never its value.
5. **Snapshots are client data and may contain secrets.** Workflow graphs carry webhook URLs with API keys in their headers, Facebook Conversion API tokens, internal phone numbers and email templates. Keep the snapshot folder out of version control: add its name to `.gitignore` in the working directory before the first harvest, and confirm that you did. Every print path must redact URLs to hostnames, truncate free text, and blank webhook headers and token-like keys, as the shipped modes already do.
6. **The same redaction binds what you write.** Quote webhook URLs by hostname only, quote sends by subject line only, and never copy a raw graph excerpt into chat or into a deliverable. When you need one step's detail, use `inspect-raw`, which redacts on the way out. When you need a view the modes do not give you, add a mode (GET only, printing only through the existing redaction helpers) rather than dumping graph JSON into the conversation.
7. **Map only the locations the owner named in this request.** If the work suggests reading another location, stop, say which and why, and get a yes first. The token is agency level and will read accounts nobody asked you to touch, so location scope is yours to enforce.
8. **Keep the calls polite, and harvest only when you need a fresh snapshot.** Do not re-harvest a location you already have a snapshot for in this session; run the offline modes against it. Sleep one second between calls, which the script does. A burst is the fastest way to get the pattern noticed and blocked, which would end the method for every account.

## Map mode (default)

Copy this checklist and check items off as you go:

```
GHL workflow map:
- [ ] Step 1: Owner accepted the read-only / terms note (record who and when)
- [ ] Step 2: Account picked, location id in hand, token stored, snapshot folder gitignored
- [ ] Step 3: probe returns GRAPH REACHED
- [ ] Step 4: harvest + harvest-triggers finished, counts checked, gaps recorded
- [ ] Step 5: diagram produced and shown; isolated workflows listed; stop here
```

### Step 1: Get consent

Guardrail 2, before anything touches the network. Say what the tool does (reads workflow definitions with the same requests the browser makes when the builder is open), what it never does (write anything), and what the owner should check on their side. Wait for the yes. Checkpoint 1.

### Step 2: Pick the account and get credentials

**Pick the account.** If the agency keeps a template sub-account that new clients are cloned from, map that first: it is the source of truth for every clone. Map an individual client sub-account only when the owner named it (guardrail 7, checkpoint 2).

**Get the location id.** Ask the owner to open the sub-account in GHL and read the browser address bar: the URL looks like `https://app.gohighlevel.com/v2/location/<locationId>/...` (agencies on a white-labelled domain see their own domain, then `/v2/location/`). The string between `/location/` and the next `/` is the location id, about 20 letters and digits. Ask them to copy it and paste it into the chat; confirm it back before you use it.

**Get a token.** The owner does this in about two minutes; walk them through it one step at a time. In a browser logged into GHL: open DevTools (F12, or right-click the page and choose Inspect), select the **Network** tab, then open the sub-account's **Settings, Custom Fields** page (or reload any GHL page). Requests to `backend.leadconnectorhq.com` appear in the list; the Custom Fields page reliably fires one named `search?parentId=...` whose full URL is `https://backend.leadconnectorhq.com/locations/<locationId>/customFields/search?...`, and any request to that host works. Click it, open the **Headers** panel, scroll to **Request Headers**, and copy the full value of the `token-id` header (right-click the value, Copy value). It is a long string starting `eyJ`, roughly a thousand characters. It expires in about **one hour**.

Treat a 401 on a call that worked earlier as token expiry first: ask for a fresh one before you debug anything else. If a fresh token also 401s, stop and suspect the header form (the list endpoint wants `token-id`, the detail endpoint wants `authorization: Bearer`, same value, per `reference/protocol.md`).

Store it in the OS secret store, never in a file and never in an exported variable. Have the owner run the store command so the value comes straight from the clipboard:

```bash
# macOS
security add-generic-password -U -a "$USER" -s GHL_TOKEN_ID -w "$(pbpaste)"
# Linux (libsecret)
secret-tool store --label="GHL token-id" service GHL_TOKEN_ID account "$USER"
# Windows (PowerShell, Credential Manager via the CredentialManager module)
# Set-StoredCredential -Target GHL_TOKEN_ID -UserName $env:USERNAME -Password (Get-Clipboard)
```

The script reads `GHL_TOKEN_ID` from the environment first (guardrail 4 governs that path), then the macOS keychain item of that name, then libsecret.

**Set up the snapshot folder.** Run the script from the working directory of the job, not from inside the skill directory: snapshots land in `GHL_SNAPSHOT_DIR`, defaulting to `.ghl-workflow-snapshots/<locationId>/` relative to the current directory. Add that folder name to `.gitignore` there before the first harvest (guardrail 5).

### Step 3: Prove access

```bash
python3 scripts/ghl_workflow_mapper.py probe <locationId>
```

Three calls, list to detail to graph. It ends with `GRAPH REACHED` or a clear reason. Do not continue past a failure; `reference/protocol.md` maps each status code to its meaning.

### Step 4: Harvest

```bash
python3 scripts/ghl_workflow_mapper.py tree <locationId>
python3 scripts/ghl_workflow_mapper.py harvest <locationId>
python3 scripts/ghl_workflow_mapper.py harvest-triggers <locationId>
```

`tree` lists every workflow id and name with folders recursed. `harvest` saves `<wfId>.detail.json` and `<wfId>.graph.json`. `harvest-triggers` saves the separate trigger object and reports counts of saved, no-trigger and failed. Two kinds of miss are expected, not broken: a workflow with no `triggersFilePath` has no trigger of its own and only runs when another workflow adds the contact, and some trigger objects return HTTP 400 because Firebase download tokens are per-object. Record both as gaps; do not retry.

A sub-account of about a hundred workflows is roughly three GETs per workflow at one second apiece, so budget a few minutes. Run the harvest in the background, then **wait for it to exit and check its counts before any offline mode**; the offline modes cannot tell a partial snapshot from a complete one.

The list call requests one page of up to 500 rows per folder and does not page beyond it. If any folder returns exactly 500 rows, say the total may be truncated rather than reporting it as fact.

### Step 5: Draw the map and stop

```bash
python3 scripts/ghl_workflow_mapper.py diagram <locationId> --out workflow-map.html
python3 scripts/ghl_workflow_mapper.py diagram <locationId> --out workflow-map.md
```

`diagram` is offline: it reads the snapshot and writes a Mermaid flowchart. Nodes are workflows (dashed border = draft; the second line shows the trigger type, or "child: no trigger of its own"). Edges are the four relationships that make workflows depend on each other: **adds** the contact to another workflow (solid), **removes** it (dashed), **fires on change** (thick, from a rounded field node that also shows which workflows write that field), and **tests membership** (red dashed, a branch asking whether the contact is currently inside another workflow). Workflows with none of these edges are not drawn; the tool lists them on stderr so you can report the count.

Show the result in the session (checkpoint 6):

- If you have an Artifact tool (Claude Code with artifacts enabled), publish the `.html` output as the artifact. It contains a `<pre class="mermaid">` block that artifacts render natively; do not add a Mermaid library to it.
- Otherwise save the `.md` output next to the job and tell the owner it renders in GitHub, VS Code, Obsidian and Notion.
- Add `--focus "<workflow name>" --hops 1` for the neighbourhood of one workflow when the whole account is too dense to read; `--all` also draws the isolated workflows; `--stages` adds a single pipeline-stages node with an edge from every workflow that moves a stage.

Then say, in two or three sentences, what the map shows: how many workflows, how many are children with no trigger, how many field-change triggers, how many membership tests, and how many isolates. **Stop there.** The map is the deliverable of this mode. Offer, in one line, that the owner can now ask questions about any workflow or ask for an audit. Do not begin an audit until asked (checkpoint 3).

## Audit mode (on request)

When the owner asks a question about a workflow, or asks what could be wrong, work from the snapshot; do not re-harvest (guardrail 8).

**Answering a question about one or a few workflows.**

```bash
python3 scripts/ghl_workflow_mapper.py flow <locationId> <wfId>
python3 scripts/ghl_workflow_mapper.py triggers <locationId> [wfId]
python3 scripts/ghl_workflow_mapper.py inspect-raw <locationId> <wfId> <stepIndex|nodeId>
```

`flow` prints a header (name, id, status, dataVersion, step count, trigger) and one indented line per step as `[i] type | name | key params`, with wait durations and windows, tags, sends (subject or truncated body), field writes, stage targets, and a branch line per `if_else` condition. Quote those lines as printed; never widen them by hand. Ids lead and builder labels follow, and a mismatch between a label and its attribute (a step labelled "5 Minutes After" whose attribute says `after=45 minutes`) is exactly the kind of thing to point out.

**Looking for hidden problems.** Read `reference/pitfalls.md` first, then check the workflows in question against each pattern: field-change triggers masquerading as form triggers, exact-match strings that can never match, membership-in-workflow conditions, flags that are never reset, stale step labels, status written without a stage, children whose parent no longer adds to them, tags nothing inside GHL reads, multiple writers of one field, clone artefacts (stage or location ids from another sub-account), and drafts doing nothing. Run `schema <locationId>` once before you write any rule about step types: GHL's vocabulary drifts and the names are not the obvious ones (sends are `sms`, `email`, `internal_notification`; there is no `send_sms`).

**Comparing values the workflows expect with values a form actually writes** needs the form's option list, which is not in the workflow graph. Get it from the GHL UI or the agency's GHL MCP server, then compare it against the `conditionValue` strings `flow` prints. A value the form never sends is a branch that never fires.

**Building the written inventory** (only if the owner wants a document):

```bash
python3 scripts/ghl_workflow_mapper.py inventory <locationId> --anchor "<workflow name>" \
  [--core-names "A,B"] [--process-regex RE] [--reminder-regex RE] [--followup-regex RE] \
  [--only CLASS,...] [--grep S] [--expect-count N] [--md]
python3 scripts/ghl_workflow_mapper.py fields <locationId> [--md] [--min-wf N] [--section fields|tokens|both]
python3 scripts/ghl_workflow_mapper.py summary <locationId>
```

Confirm the **anchor** (the workflow that visibly does the thing) with the owner first (checkpoint 4); `--anchor` is required and `--core-names` is the owner's override. The classifier seeds itself from the anchor's fields, tags, stages and trigger scope, scores every other workflow by overlap and by name (`CORE`, `REMINDER`, `FOLLOWUP`, `ADJACENT`, `UNRELATED`), and prints its evidence per row so a human can override it. If `CORE` comes out bigger than the owner expected, show the seed lines the mode prints and let the owner cut the seed set. Resolve field and stage ids to names read-only per `reference/protocol.md`, with an outer join so unresolved ids are listed, never dropped.

The document: purpose and scope; how it was produced (commands, snapshot date, who accepted the terms note and when); counts; Table A (every workflow, with a **Disposition** column the owner fills in, pre-filled only as `needs-review` for `CORE` and `ADJACENT` and `keep` for a `FOLLOWUP` whose evidence reads "name; no seed overlap", checkpoint 5); deep dives from `flow` for `CORE` and `ADJACENT`; Table B (custom fields, with two empty reviewer columns: *shared with another process?* and *safe to retire?*) and the custom values the chain depends on; Table C (stages); the dependency map; gaps; refresh instructions. State that contact custom-field values a human typed are not readable by this method.

## Refreshing a snapshot

Snapshots go stale the moment someone edits a workflow. To refresh: fresh token, then `harvest`, `harvest-triggers`, `diagram`; diff the new snapshot folder against the old one to see what changed.

## Starter prompt

> Use the ghl-workflow-mapper skill. Before your first network call, read me the skill's read-only note and terms note in plain words and wait for my explicit yes, then record who accepted and when. I will need to give you two things and I do not know where to find them, so guide me step by step: first the location id of the sub-account (tell me where it sits in the GHL address bar and wait for me to paste it), then the session token (tell me exactly where to click in the browser DevTools and wait for me to confirm it is stored). Read no other location without asking me first. Produce the dependency diagram of the whole account and stop there. I will ask questions or request an audit afterwards.
GHL_MAPPER_EOF
cat > "$ROOT/reference/protocol.md" <<'GHL_MAPPER_EOF'
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
GHL_MAPPER_EOF
cat > "$ROOT/reference/pitfalls.md" <<'GHL_MAPPER_EOF'
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

**Children have no trigger.** Workflows entered only by `add_to_workflow` have no `triggersFilePath`. Find their parents through the parents' `add_to_workflow` steps.

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
GHL_MAPPER_EOF
cat > "$ROOT/scripts/ghl_workflow_mapper.py" <<'GHL_MAPPER_EOF'
#!/usr/bin/env python3
"""ghl_workflow_mapper.py - read-only mapper for GoHighLevel workflow internals.

READ-ONLY BY CONSTRUCTION: every network call is an HTTP GET. Do not add a write.

Sends the same read-only requests the browser makes when the workflow builder is
open. They are not part of GHL's public API and can change without notice; the
account owner must accept that before you run it. Be polite: one call per second,
run rarely, stop on 404 or on a changed JSON shape.

Token: a Firebase session JWT copied from DevTools (request header `token-id`,
~1 h lifetime). Read from the GHL_TOKEN_ID environment variable, else the macOS
keychain item GHL_TOKEN_ID, else libsecret (secret-tool). Never printed.

    python3 ghl_workflow_mapper.py <mode> <locationId> [args]

Network modes (GET only):
    probe            <loc>                  list -> detail -> graph, proves access
    tree             <loc>                  every workflow id + name (folders recursed)
    harvest          <loc> [wfId ...]       save <wfId>.detail.json + .graph.json
    harvest-triggers <loc> [wfId ...]       save <wfId>.triggers.json (second object)
Offline modes (read the saved snapshots only):
    schema           <loc> [stepType]       step-type vocabulary + attribute paths
    inventory        <loc> --anchor "Name" [--md] [--only CLASS,..] [--grep S]
                           [--core-names "A,B"] [--expect-count N]
    fields           <loc> [--md] [--min-wf N] [--section fields|tokens|both]
    flow             <loc> <wfId>           linearized narrative of one workflow
    summary          <loc>                  stage-moving workflows + target stage ids
    triggers         <loc> [wfId]           print harvested triggers
    inspect-raw      <loc> <wfId> <idx|nodeId>   one step's JSON, redacted
    diagram          <loc> [--focus "Name" [--hops N]] [--all] [--stages]
                           [--out FILE.md|FILE.html]
                     Mermaid dependency map of the account: workflows as nodes;
                     edges for add_to_workflow, remove_from_workflow, field-change
                     triggers (who writes the field that fires whom) and
                     membership tests ("is the contact in workflow X?").
                     Workflows with no edges are omitted unless --all.
                     --out .md writes a mermaid fence; .html writes an
                     artifact-ready page (<pre class="mermaid">, no library).

Snapshots land in ./ghl-workflow-snapshots/<loc>/ (override with GHL_SNAPSHOT_DIR).
Keep that folder out of version control: it holds client automation data and
live webhook secrets.
"""
import glob, json, os, re, subprocess, sys, time
from collections import Counter, defaultdict
from urllib.parse import quote, urlparse
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

BASE = "https://backend.leadconnectorhq.com/workflow"
SLEEP = 1.0
OUT_ROOT = os.environ.get("GHL_SNAPSHOT_DIR", ".ghl-workflow-snapshots")
MAX_STR = 60
ID_RE = re.compile(r"^[A-Za-z0-9]{20,24}$")
UUID_RE = re.compile(r"^[0-9a-fA-F-]{36}$")
TOKEN_RE = re.compile(r"\{\{\s*(custom_values|contact|opportunity)\.[^}]+\}\}")
URLISH_RE = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.\-]*://")
SECRET_PATHS = ("headers[].value", "access_token", "token", "apikey", "api_key",
                "secret", "password", "authorization")

# ----------------------------------------------------------------- credentials
def load_token():
    t = os.environ.get("GHL_TOKEN_ID", "").strip()
    if not t:
        for cmd in (["security", "find-generic-password", "-a", os.environ.get("USER", ""),
                     "-s", "GHL_TOKEN_ID", "-w"],
                    ["secret-tool", "lookup", "service", "GHL_TOKEN_ID"]):
            try:
                t = subprocess.run(cmd, capture_output=True, text=True, timeout=10).stdout.strip()
            except Exception:
                t = ""
            if t:
                break
    if not t:
        sys.exit("ERROR: no token. Set GHL_TOKEN_ID or store it in the OS secret store (see header).")
    print(f"token loaded ({len(t)} chars, value not printed)")
    return t

def http_get(url, headers=None):
    """(status, bytes). Never raises on HTTP status; raises only on network failure."""
    req = Request(url, headers=headers or {}, method="GET")
    try:
        with urlopen(req, timeout=60) as r:
            return r.status, r.read()
    except HTTPError as e:
        return e.code, e.read()
    except URLError as e:
        return 0, str(e).encode()

def list_headers(tok):
    return {"token-id": tok, "channel": "APP", "source": "WEB_USER", "version": "2021-04-15"}

def detail_headers(tok):
    return {"authorization": f"Bearer {tok}", "channel": "APP", "source": "WEB_USER",
            "origin": "https://client-app-automation-workflows.leadconnectorhq.com",
            "referer": "https://client-app-automation-workflows.leadconnectorhq.com/"}

def die_on_auth(code):
    if code == 401:
        sys.exit("401: token expired or invalid. Copy a fresh token-id from DevTools and store it.")
    if code == 403:
        sys.exit("403: token is not scoped to this location.")

# ----------------------------------------------------------------- network modes
def walk_tree(loc, tok, parent="root", acc=None):
    acc = acc if acc is not None else []
    code, body = http_get(f"{BASE}/{loc}/list?parentId={parent}&limit=500&offset=0", list_headers(tok))
    die_on_auth(code)
    if code != 200:
        print(f"  list(parentId={parent}) -> HTTP {code}", file=sys.stderr)
        return acc
    for r in json.loads(body).get("rows", []):
        t = str(r.get("type", "")).lower()
        if t in ("directory", "folder"):
            time.sleep(SLEEP)
            walk_tree(loc, tok, r["id"], acc)
        elif t == "workflow":
            acc.append((r["id"], r.get("name", "")))
    return acc

def fetch_detail(loc, tok, wid):
    code, body = http_get(f"{BASE}/{loc}/{wid}?includeScheduledPauseInfo=true", detail_headers(tok))
    die_on_auth(code)
    return code, body

def triggers_url(detail):
    """Compose the triggers object URL from fileUrl + triggersFilePath (see docs)."""
    fu, tp = detail.get("fileUrl") or "", detail.get("triggersFilePath") or ""
    if not tp:
        return None
    if URLISH_RE.match(tp):
        return tp
    if fu and "/o/" in fu:
        prefix = fu.split("/o/", 1)[0] + "/o/"
        q = urlparse(fu).query
        return prefix + quote(tp.lstrip("/"), safe="") + (f"?{q}" if q else "")
    return None

def mode_probe(loc, tok):
    code, body = http_get(f"{BASE}/{loc}/list?limit=25&offset=0", list_headers(tok))
    die_on_auth(code)
    print(f"1. list -> HTTP {code}")
    if code != 200:
        sys.exit("cannot list workflows; stopping.")
    rows = json.loads(body).get("rows", [])
    print(f"   {len(rows)} row(s); types: {dict(Counter(str(r.get('type')) for r in rows))}")
    wfs = walk_tree(loc, tok)
    print(f"2. folder walk -> {len(wfs)} workflow(s)")
    if not wfs:
        sys.exit("no workflows found.")
    wid = wfs[0][0]
    time.sleep(SLEEP)
    code, body = fetch_detail(loc, tok, wid)
    print(f"3. detail -> HTTP {code} ({len(body)} bytes)")
    if code != 200:
        sys.exit("detail endpoint failed; stopping.")
    d = json.loads(body)
    print(f"   keys: {sorted(d)[:14]}")
    if not d.get("fileUrl"):
        sys.exit("no fileUrl in detail; graph may be inline - inspect by hand.")
    time.sleep(SLEEP)
    code, body = http_get(d["fileUrl"])
    print(f"4. graph -> HTTP {code} ({len(body)} bytes)")
    if code == 200:
        steps = steps_of(json.loads(body))
        print(f"   {len(steps)} step(s): {dict(Counter(step_type(s) for s in steps).most_common(6))}")
        print("GRAPH REACHED - full workflow internals are available.")

def mode_tree(loc, tok):
    wfs = walk_tree(loc, tok)
    print(f"{len(wfs)} workflow(s):")
    for wid, name in wfs:
        print(f"  {wid}  {name}")

def mode_harvest(loc, tok, ids):
    dest = os.path.join(OUT_ROOT, loc); os.makedirs(dest, exist_ok=True)
    if not ids:
        ids = [w for w, _ in walk_tree(loc, tok)]
    ok = failed = 0
    for wid in ids:
        time.sleep(SLEEP)
        code, body = fetch_detail(loc, tok, wid)
        if code != 200:
            failed += 1; print(f"  {wid} detail -> HTTP {code}", file=sys.stderr); continue
        with open(os.path.join(dest, f"{wid}.detail.json"), "wb") as fh:
            fh.write(body)
        fu = json.loads(body).get("fileUrl")
        if fu:
            time.sleep(SLEEP)
            gcode, gbody = http_get(fu)
            if gcode == 200:
                with open(os.path.join(dest, f"{wid}.graph.json"), "wb") as fh:
                    fh.write(gbody)
            else:
                print(f"  {wid} graph -> HTTP {gcode}", file=sys.stderr)
        ok += 1
    print(f"done: {ok} saved to {dest}, {failed} failed")

def mode_harvest_triggers(loc, tok, ids):
    dest = os.path.join(OUT_ROOT, loc)
    if not os.path.isdir(dest):
        sys.exit("harvest first.")
    ids = ids or workflow_ids(dest)
    saved = children = failed = 0
    for wid in ids:
        time.sleep(SLEEP)
        code, body = fetch_detail(loc, tok, wid)       # fresh signature
        if code != 200:
            failed += 1; print(f"  {wid} detail -> HTTP {code}", file=sys.stderr); continue
        url = triggers_url(json.loads(body))
        if not url:
            children += 1; continue                     # no trigger of its own
        time.sleep(SLEEP)
        tcode, tbody = http_get(url)
        if tcode == 200:
            with open(os.path.join(dest, f"{wid}.triggers.json"), "wb") as fh:
                fh.write(tbody)
            saved += 1
        else:
            failed += 1; print(f"  {wid} triggers -> HTTP {tcode} (per-object token; not retried)", file=sys.stderr)
    print(f"done: {saved} saved, {children} with no trigger of their own (children), {failed} failed")

# ----------------------------------------------------------------- snapshot access
def load_json(p):
    try:
        with open(p) as fh:
            return json.load(fh)
    except Exception:
        return None

def steps_of(graph):
    if isinstance(graph, list):
        return [s for s in graph if isinstance(s, dict)]
    if not isinstance(graph, dict):
        return []
    steps = graph.get("steps") if isinstance(graph.get("steps"), list) else graph.get("templates")
    return [s for s in (steps or []) if isinstance(s, dict)]

def workflow_ids(base):
    return sorted(os.path.basename(p)[:-len(".graph.json")]
                  for p in glob.glob(os.path.join(base, "*.graph.json")))

def iter_workflows(base):
    rows = []
    for wid in workflow_ids(base):
        d = load_json(os.path.join(base, f"{wid}.detail.json"))
        g = load_json(os.path.join(base, f"{wid}.graph.json"))
        rows.append(((d or {}).get("name", "").lower(), wid, d, steps_of(g) if g is not None else []))
    for _, wid, d, steps in sorted(rows, key=lambda r: (r[0], r[1])):
        yield wid, d, steps

def load_triggers(base, wid):
    return load_json(os.path.join(base, f"{wid}.triggers.json"))

# ----------------------------------------------------------------- traversal / redaction
def deep_iter(obj, path=()):
    if isinstance(obj, dict):
        for k, v in obj.items():
            yield from deep_iter(v, path + (str(k),))
    elif isinstance(obj, (list, tuple)):
        for i, v in enumerate(obj):
            yield from deep_iter(v, path + (i,))
    else:
        yield path, obj

def collapse_path(path):
    out = []
    for seg in path:
        if isinstance(seg, int):
            if out: out[-1] += "[]"
            else: out.append("[]")
        else:
            out.append(seg)
    return ".".join(out)

def is_secret_path(key):
    kl = key.lower()
    return any(p in kl for p in SECRET_PATHS)

def redact(v):
    if not isinstance(v, str):
        return v
    s = v.strip()
    if URLISH_RE.match(s):
        try:
            h = urlparse(s).hostname
        except Exception:
            h = None
        if h:
            return f"<url {h}>"
    s = " ".join(v.split())
    return s if len(s) <= MAX_STR else s[:MAX_STR] + "…"

def redact_deep(obj, path=()):
    if isinstance(obj, dict):
        return {k: ("<redacted>" if is_secret_path(collapse_path(path + (str(k),))) else redact_deep(v, path + (str(k),)))
                for k, v in obj.items()}
    if isinstance(obj, list):
        return [redact_deep(v, path + (0,)) for v in obj]
    return redact(obj)

def jd(v): return json.dumps(v, ensure_ascii=False)
def norm_name(s): return re.sub(r"[^a-z0-9]+", "", (s or "").lower())
def step_type(s): return s.get("type") or s.get("actionType") or "?"
def attrs_of(s):
    a = s.get("attributes")
    if not isinstance(a, dict): a = s.get("config")
    return a if isinstance(a, dict) else {}
def is_id(v): return isinstance(v, str) and bool(ID_RE.match(v) or UUID_RE.match(v))

# ----------------------------------------------------------------- feature extraction
TAG_ADD, TAG_REMOVE = {"add_contact_tag"}, {"remove_contact_tag"}
SEND_TYPES = {"sms", "email", "internal_notification", "sendblue_outbound_message", "slack_message",
              "ivr_connect_call", "manual-call", "manual_sms", "whatsapp", "voicemail", "review_request"}
WAIT_TYPES = {"wait", "wait_for_reply"}
WEBHOOK_TYPES = {"webhook", "custom_webhook"}

def conditions_of(step):
    """Every branch condition on a step (if_else and wait both nest branches[].segments[].conditions[])."""
    out = []
    def walk(obj, bname):
        if isinstance(obj, dict):
            if isinstance(obj.get("segments"), list):
                bname = obj.get("name") or obj.get("id") or bname
            for c in obj.get("conditions") or []:
                if isinstance(c, dict) and ("conditionType" in c or "conditionOperator" in c):
                    out.append({"branch": bname, **{k: c.get(k) for k in
                                ("conditionType", "conditionSubType", "conditionOperator", "conditionValue")}})
            for k, v in obj.items():
                if k != "conditions": walk(v, bname)
        elif isinstance(obj, list):
            for v in obj: walk(v, bname)
    walk(attrs_of(step), "(step)")
    return out

def fmt_condition(c):
    return f"{c.get('conditionType')}:{c.get('conditionSubType')} {c.get('conditionOperator')} {jd(redact(c.get('conditionValue')))}"

def _tags(step):
    t = attrs_of(step).get("tags")
    if isinstance(t, list): return {x for x in t if isinstance(x, str) and x}
    return {t} if isinstance(t, str) and t else set()

def tags_of(steps):
    added, removed = set(), set()
    for s in steps:
        t = step_type(s).lower()
        if t in TAG_ADD: added |= _tags(s)
        elif t in TAG_REMOVE: removed |= _tags(s)
    return added, removed

def field_writes_of(steps):
    out = set()
    for s in steps:
        t, a = step_type(s).lower(), attrs_of(s)
        if t == "update_contact_field":
            out |= {f["field"] for f in a.get("fields") or [] if isinstance(f, dict) and is_id(f.get("field"))}
        elif t == "math_operation" and is_id(a.get("updateField")):
            out.add(a["updateField"])
    return out

def field_reads_of(steps):
    return {attrs_of(s)["selectField"] for s in steps
            if step_type(s).lower() == "math_operation" and is_id(attrs_of(s).get("selectField"))}

def field_titles_of(steps):
    out = {}
    for s in steps:
        if step_type(s).lower() == "update_contact_field":
            for f in attrs_of(s).get("fields") or []:
                if isinstance(f, dict) and is_id(f.get("field")) and f.get("title"):
                    out.setdefault(f["field"], redact(f["title"]))
    return out

def field_conditions_of(steps):
    out = {}
    for s in steps:
        for c in conditions_of(s):
            sub = c.get("conditionSubType")
            if is_id(sub):
                out.setdefault(sub, set()).add(jd(redact(c.get("conditionValue"))))
    return out

def stages_of(steps):
    return {attrs_of(s)["pipeline_stage_id"] for s in steps
            if step_type(s) == "create_opportunity" and is_id(attrs_of(s).get("pipeline_stage_id"))}

def host_of(u):
    if not isinstance(u, str) or not URLISH_RE.match(u.strip()): return None
    try: return urlparse(u.strip()).hostname
    except Exception: return None

def hosts_of(steps):
    out = set()
    for s in steps:
        for path, v in deep_iter(attrs_of(s)):
            if isinstance(v, str) and not is_secret_path(collapse_path(path)):
                h = host_of(v)
                if h: out.add(h)
    return out

def tokens_of(steps):
    out = set()
    for s in steps:
        for path, v in deep_iter(s):
            if isinstance(v, str) and not is_secret_path(collapse_path(path)):
                for m in TOKEN_RE.finditer(v):
                    out.add(" ".join(m.group(0).split()))
    return out

def has_type(steps, types): return any(step_type(s).lower() in types for s in steps)

# ----------------------------------------------------------------- triggers
def trigger_list(doc):
    if isinstance(doc, list): return [t for t in doc if isinstance(t, dict)]
    if isinstance(doc, dict):
        for k in ("triggers", "rows", "data", "items"):
            if isinstance(doc.get(k), list): return [t for t in doc[k] if isinstance(t, dict)]
        if "type" in doc or "eventType" in doc: return [doc]
    return []

def trigger_rows(doc):
    rows = []
    for t in trigger_list(doc):
        ttype = t.get("type") or t.get("eventType") or t.get("key") or "?"
        tname = t.get("name") or t.get("label") or ""
        filters = [(collapse_path(p), redact(v)) for p, v in deep_iter(t)
                   if collapse_path(p) not in ("type", "name", "eventType", "label")
                   and not is_secret_path(collapse_path(p)) and v not in (None, "", [], {})]
        rows.append((str(ttype), str(tname), filters))
    return rows

def trigger_summary(doc, limit=2):
    rows = trigger_rows(doc)
    if not rows: return "—"
    parts = [f"{t}{'/' + n if n else ''}" for t, n, _ in rows[:limit]]
    if len(rows) > limit: parts.append(f"+{len(rows) - limit}")
    return ";".join(parts)

def trigger_scope_ids(doc):
    return {v for _, _, f in trigger_rows(doc) for k, v in f
            if any(h in k.lower() for h in ("form", "survey", "calendar")) and is_id(v)}

# ----------------------------------------------------------------- rendering helpers
def cut(s, n):
    s = "" if s is None else str(s)
    return s if len(s) <= n else s[:max(0, n - 1)] + "…"

def joinset(vals, limit=4, sep=","):
    vals = sorted(str(v) for v in vals)
    if not vals: return "—"
    return sep.join(vals[:limit]) + (f"+{len(vals) - limit}" if len(vals) > limit else "")

def md_table(head, rows):
    esc = lambda c: str("" if c is None else c).replace("|", "\\|").replace("\n", " ")
    return "\n".join(["| " + " | ".join(head) + " |", "|" + "|".join("---" for _ in head) + "|"]
                     + ["| " + " | ".join(esc(c) for c in r) + " |" for r in rows])

def fixed_table(head, rows, widths):
    lines = ["  ".join(h.ljust(w)[:w] for h, w in zip(head, widths)), "  ".join("-" * w for w in widths)]
    lines += ["  ".join(cut(c, w).ljust(w) for c, w in zip(r, widths)) for r in rows]
    return "\n".join(lines)

def arg(args, flag, default=None, cast=str):
    if flag in args:
        i = args.index(flag)
        if i + 1 < len(args): return cast(args[i + 1])
    return default

# ----------------------------------------------------------------- offline modes
def mode_schema(base, only=None):
    step_n, wf_n = Counter(), Counter()
    paths = defaultdict(lambda: defaultdict(list))
    smax = 5 if only else 2
    for wid, d, steps in iter_workflows(base):
        seen = set()
        for s in steps:
            t = step_type(s)
            if only and t != only: continue
            step_n[t] += 1; seen.add(t)
            for p, v in deep_iter(attrs_of(s)):
                key = collapse_path(p)
                b = paths[t][key]
                r = "<redacted>" if is_secret_path(key) else redact(v)
                if r not in b and len(b) < smax: b.append(r)
        for t in seen: wf_n[t] += 1
    print(f"step types across {len(workflow_ids(base))} workflow(s)\n")
    for t, n in step_n.most_common():
        print(f"=== {t}   steps={n}  workflows={wf_n[t]}")
        for key in sorted(paths[t]):
            print(f"    {key}   ::  {cut(', '.join(jd(v) for v in paths[t][key]), 200)}")
        print()

def mode_summary(base):
    movers, targets = [], Counter()
    for wid, d, steps in iter_workflows(base):
        moves = [(s.get("name", ""), attrs_of(s).get("pipeline_stage_id", "?"))
                 for s in steps if step_type(s) == "create_opportunity"]
        for _, sid in moves: targets[sid] += 1
        if moves: movers.append(((d or {}).get("name", wid), moves))
    print(f"{len(movers)} workflow(s) contain create_opportunity.\n")
    for name, moves in movers:
        print(f"* {name}  ({len(moves)} step(s))")
        for label, sid in moves: print(f"    -> {sid}  {redact(label)}")
    print("\ndistinct target stage ids (count = steps targeting it):")
    for sid, n in targets.most_common(): print(f"  {n:>3}  {sid}")

def mode_inventory(base, args):
    anchor = arg(args, "--anchor")
    if not anchor:
        sys.exit("inventory needs --anchor \"<name of the workflow that visibly handles the process>\"")
    as_md = "--md" in args
    only = arg(args, "--only"); only = {x.strip().upper() for x in only.split(",")} if only else None
    grep = (arg(args, "--grep") or "").lower() or None
    expect = arg(args, "--expect-count", None, int)
    core_names = {norm_name(x) for x in (arg(args, "--core-names") or "").split(",") if x.strip()}
    core_names.add(norm_name(anchor))
    proc_re = arg(args, "--process-regex", r"$^")           # names of the process itself (e.g. check ?-?in)
    rem_re = arg(args, "--reminder-regex", r"remind|nudge|unfilled")
    fu_re = arg(args, "--followup-regex", r"follow ?-?up|resched|no.?show|rebook|reactivat")

    rows, broken = [], []
    for wid, d, steps in iter_workflows(base):
        if d is None: broken.append((wid, "detail missing/unparseable"))
        if not steps: broken.append((wid, "graph missing/empty"))
        d = d or {}
        conds = field_conditions_of(steps); trig = load_triggers(base, wid)
        added, removed = tags_of(steps)
        rows.append(dict(wid=wid, name=d.get("name") or "(unknown)", status=d.get("status") or "?",
                         dv=d.get("dataVersion", "?"),
                         trig=trigger_summary(trig) if trig is not None else "—",
                         scope=trigger_scope_ids(trig) if trig is not None else set(),
                         nsteps=len(steps), types=Counter(step_type(s) for s in steps),
                         cond=set(conds), write=field_writes_of(steps) | field_reads_of(steps),
                         added=added, removed=removed, hosts=hosts_of(steps), stages=stages_of(steps),
                         has_wait=has_type(steps, WAIT_TYPES), has_send=has_type(steps, SEND_TYPES),
                         has_opp=has_type(steps, {"create_opportunity"})))

    seed = next((r for r in rows if norm_name(anchor) in norm_name(r["name"])), None)
    if seed:
        SF = seed["cond"] | seed["write"]; ST = seed["added"] | seed["removed"]
        SS = set(seed["stages"]); SO = set(seed["scope"])
    else:
        SF = ST = SS = SO = set()

    def m(name, pat): return bool(re.search(pat, (name or "").lower()) or re.search(pat, norm_name(name)))
    for r in rows:
        f = (r["cond"] | r["write"]) & SF; t = (r["added"] | r["removed"]) & ST
        s = r["stages"] & SS; o = r["scope"] & SO
        ev = [x for x in (f and "field:" + joinset(f, 3), t and "tag:" + joinset(t, 3),
                          s and "stage:" + joinset(s, 2), o and "scope:" + joinset(o, 1)) if x]
        touches = bool(f or t or s or o); nn = norm_name(r["name"])
        if nn in core_names:
            r["cls"], r["ev"] = "CORE", "named; " + ("; ".join(ev) or "no seed overlap")
        elif m(r["name"], proc_re) and touches:
            r["cls"], r["ev"] = "CORE", "name+seed: " + "; ".join(ev)
        elif r["write"] & SF:
            r["cls"], r["ev"] = "CORE", "writes seed field: " + joinset(r["write"] & SF, 3)
        elif m(r["name"], rem_re):
            r["cls"], r["ev"] = "REMINDER", "name; " + ("; ".join(ev) or "no seed overlap")
        elif r["has_wait"] and r["has_send"] and (t or f):
            r["cls"], r["ev"] = "REMINDER", "wait+send+seed: " + "; ".join(ev)
        elif m(r["name"], fu_re):
            r["cls"], r["ev"] = "FOLLOWUP", "name; " + ("; ".join(ev) or "no seed overlap")
        elif touches:
            r["cls"], r["ev"] = "ADJACENT", "; ".join(ev)
        else:
            r["cls"], r["ev"] = "UNRELATED", ""
    ORDER = {"CORE": 0, "ADJACENT": 1, "REMINDER": 2, "FOLLOWUP": 3, "UNRELATED": 4}
    rows.sort(key=lambda r: (ORDER[r["cls"]], r["name"].lower()))

    HEAD = ["id", "name", "status", "dv", "trigger", "steps", "top types", "fields", "tags +/-",
            "hosts", "stages", "class", "evidence"]
    def cells(r, md):
        fl = []
        if r["cond"]: fl.append("cond:" + joinset(r["cond"], 8 if md else 3))
        if r["write"]: fl.append("write:" + joinset(r["write"], 8 if md else 3))
        return [r["wid"] if md else r["wid"][:8], r["name"], r["status"], r["dv"], r["trig"], r["nsteps"],
                ",".join(f"{t}:{n}" for t, n in r["types"].most_common(4)), " ".join(fl) or "—",
                f"+{joinset(r['added'], 6 if md else 2)} / -{joinset(r['removed'], 6 if md else 2)}",
                joinset(r["hosts"], 6 if md else 2), joinset(r["stages"], 6 if md else 1),
                r["cls"], r["ev"] if md else cut(r["ev"], 80)]
    shown = [r for r in rows if (only is None or r["cls"] in only) and (grep is None or grep in r["name"].lower())]
    print(md_table(HEAD, [cells(r, True) for r in shown]) if as_md else
          fixed_table(HEAD, [cells(r, False) for r in shown], [8, 46, 9, 3, 10, 5, 34, 30, 30, 18, 12, 10, 80]))

    dist = Counter(r["cls"] for r in rows)
    print(f"\n{len(rows)} workflow(s).  class distribution: " +
          ", ".join(f"{k}={dist[k]}" for k in sorted(dist, key=ORDER.get)))
    print(f"workflows containing create_opportunity: {sum(1 for r in rows if r['has_opp'])}")
    print(f"triggers on disk: {sum(1 for r in rows if r['trig'] != '—')}/{len(rows)}")
    if seed:
        print(f"\nseed (anchor) workflow: {seed['name']} ({seed['wid']})")
        print("  SEED_FIELDS: " + joinset(SF, 30, ", ")); print("  SEED_TAGS:   " + joinset(ST, 40, ", "))
        print("  SEED_STAGES: " + joinset(SS, 20, ", ")); print("  SEED_SCOPE:  " + joinset(SO, 5, ", "))
    else:
        print(f"\nWARNING: no workflow name contains {anchor!r}; classes are name-only.")
    if broken:
        print("\nunreadable snapshots:"); [print(f"  {w}  {why}") for w, why in broken]
    if expect is not None and len(rows) != expect:
        sys.exit(f"FAIL --expect-count: {len(rows)} != {expect}")

def mode_fields(base, args):
    as_md = "--md" in args; min_wf = arg(args, "--min-wf", 1, int); section = arg(args, "--section", "both")
    roles, wfs, values, titles = defaultdict(set), defaultdict(set), defaultdict(set), {}
    tok_n, tok_wfs = Counter(), defaultdict(set)
    for wid, d, steps in iter_workflows(base):
        name = (d or {}).get("name") or wid
        for fid, vals in field_conditions_of(steps).items():
            roles[fid].add("cond"); wfs[fid].add(name); values[fid] |= vals
        for fid in field_writes_of(steps): roles[fid].add("write"); wfs[fid].add(name)
        for fid in field_reads_of(steps): roles[fid].add("read"); wfs[fid].add(name)
        for fid, t in field_titles_of(steps).items(): titles.setdefault(fid, t)
        for tok in tokens_of(steps): tok_n[tok] += 1; tok_wfs[tok].add(name)
    role = lambda s: "both" if s >= {"cond", "write"} else "/".join(sorted(s))
    ordered = sorted(roles, key=lambda f: (-len(wfs[f]), f))
    rows = [[f, titles.get(f, "—"), role(roles[f]), len(wfs[f]), joinset(wfs[f], 6, "; "), joinset(values[f], 8, " ")]
            for f in ordered if len(wfs[f]) >= min_wf]
    if section in ("both", "fields"):
        H = ["field id", "title (from graph)", "role", "#wf", "workflows", "values tested"]
        print(f"== custom fields ({len(roles)} distinct; {len(rows)} with >= {min_wf} workflow(s)) ==")
        print(md_table(H, rows) if as_md else fixed_table(H, rows, [22, 26, 6, 4, 70, 90]))
        print(f"\n{sum(1 for f in roles if len(wfs[f]) > 1)} field id(s) referenced by more than one workflow.")
    if section in ("both", "tokens"):
        H = ["merge token", "count", "workflows"]
        trows = [[t, n, joinset(tok_wfs[t], 4, "; ")] for t, n in tok_n.most_common()]
        print(f"\n== merge tokens / custom values ({len(trows)} distinct) ==")
        print(md_table(H, trows) if as_md else fixed_table(H, trows, [56, 5, 80]))

def depth_map(steps):
    by_id = {s.get("id"): s for s in steps if s.get("id")}
    owner = {}
    for s in steps:
        for p, v in deep_iter(attrs_of(s)):
            k = collapse_path(p)
            if (k.endswith("branches[].id") or k.endswith("transitions[].id")) and isinstance(v, str):
                owner[v] = s.get("id")
    depths = {}
    def depth(sid, seen=()):
        if sid in depths: return depths[sid]
        if sid in seen or sid not in by_id: return 0
        pk = by_id[sid].get("parentKey")
        d = depth(pk, seen + (sid,)) if pk in by_id else (depth(owner[pk], seen + (sid,)) + 1 if pk in owner else 0)
        depths[sid] = d; return d
    for s in steps:
        if s.get("id"): depth(s["id"])
    return depths

def key_params(step):
    t, a, out = step_type(step).lower(), attrs_of(step), []
    def add(label, val):
        if val not in (None, "", [], {}): out.append(f"{label}={jd(redact(val)) if isinstance(val, str) else val}")
    if t == "wait":
        sa, asa, w = a.get("startAfter") or {}, a.get("appointmentStartAfter") or {}, a.get("window") or {}
        if sa.get("value") is not None: out.append(f"after={sa.get('value')} {sa.get('type')} {sa.get('when') or ''}".strip())
        if asa.get("value") is not None: out.append(f"appt={asa.get('value')} {asa.get('type')} {asa.get('when') or ''}".strip())
        if w.get("start") or w.get("end"): out.append(f"window={w.get('start')}-{w.get('end')} days={w.get('days')}")
        add("waitType", a.get("type"))
        out += ["cond " + fmt_condition(c) for c in conditions_of(step)]
    elif t == "wait_for_reply": out.append(f"timeout={a.get('wait_amount')} {a.get('wait_unit')}")
    elif t in TAG_ADD | TAG_REMOVE: out.append(("removes=" if t in TAG_REMOVE else "adds=") + ",".join(sorted(_tags(step))))
    elif t == "sms": add("body", a.get("body"))
    elif t == "email": add("subject", a.get("subject")); add("from", a.get("from_email"))
    elif t == "internal_notification":
        add("channel", a.get("type")); add("subject", (a.get("email") or {}).get("subject"))
        add("to", (a.get("email") or {}).get("to") or (a.get("sms") or {}).get("to")); add("body", (a.get("sms") or {}).get("body"))
    elif t in WEBHOOK_TYPES:
        out.append(f"{a.get('method') or 'GET'} host={host_of(a.get('url') or '') or '?'}")
        keys = [c.get("key") for c in (a.get("customData") or []) if isinstance(c, dict) and c.get("key")]
        if keys: out.append("customData=" + ",".join(map(str, keys[:8])))
    elif t == "update_contact_field":
        add("actionType", a.get("actionType"))
        out += [f"{f.get('field')} ({redact(f.get('title'))}) := {jd(redact(f.get('value')))}" for f in a.get("fields") or [] if isinstance(f, dict)]
    elif t == "math_operation":
        ops = ",".join(f"{o.get('operator')} {redact(o.get('value'))}" for o in (a.get("operators") or []) if isinstance(o, dict))
        out.append(f"{a.get('selectField')} {ops} -> {a.get('updateField')}")
    elif t == "create_opportunity":
        out.append(f"stage={a.get('pipeline_stage_id')} pipeline={a.get('pipeline_id')}")
        add("status", a.get("opportunity_status")); add("value", a.get("monetary_value"))
    elif t == "remove_opportunity": out.append(f"pipeline={a.get('pipeline_id')}")
    elif t in ("add_to_workflow", "remove_from_workflow"):
        w = a.get("workflow_id"); out.append("workflow=" + (",".join(w) if isinstance(w, list) else str(w)))
    elif t == "goto": out.append(f"target={a.get('targetNodeId')}")
    elif t == "if_else": add("label", a.get("conditionName"))
    elif t == "facebook_conversion_api": out.append(f"event={a.get('event_name')}")
    elif t == "custom_code": add("lang", a.get("language"))
    return "  ".join(out)

def mode_flow(base, wid):
    d = load_json(os.path.join(base, f"{wid}.detail.json")) or {}
    steps = steps_of(load_json(os.path.join(base, f"{wid}.graph.json")))
    if not steps: sys.exit(f"no saved graph for {wid} (harvest first)")
    trig = load_triggers(base, wid)
    print(f"{d.get('name', '?')}  [{wid}]\n  status={d.get('status', '?')}  dataVersion={d.get('dataVersion', '?')}  steps={len(steps)}")
    print(f"  trigger: {trigger_summary(trig, 4) if trig is not None else '— (no triggers file: child, or run harvest-triggers)'}\n")
    depths = depth_map(steps)
    for i, s in enumerate(steps):
        ind = "  " * min(depths.get(s.get("id"), 0), 8); kp = key_params(s)
        print(f"{ind}[{i}] {step_type(s)} | {redact(s.get('name') or '')}" + (f" | {kp}" if kp else ""))
        if step_type(s) == "if_else":
            by = {}
            for c in conditions_of(s): by.setdefault(c["branch"], []).append(c)
            for b, cs in by.items(): print(f"{ind}   └─ branch {b!r}: " + " AND ".join(fmt_condition(c) for c in cs))
            a = attrs_of(s)
            empties = [b.get("name") for b in (a.get("branches") or []) if isinstance(b, dict) and b.get("name") not in by]
            if empties: print(f"{ind}   └─ branches with no conditions: {', '.join(map(str, empties))}")
            if a.get("noneBranchName"): print(f"{ind}   └─ else branch: {a['noneBranchName']!r}")

def mode_triggers(base, only=None):
    found = 0
    for wid, d, _ in iter_workflows(base):
        if only and wid != only: continue
        doc = load_triggers(base, wid)
        if doc is None: continue
        found += 1
        print(f"{(d or {}).get('name', '?')}  [{wid}]")
        for ttype, tname, filters in trigger_rows(doc) or [("(none recognised)", "", [])]:
            print(f"  - {ttype}" + (f"  {tname!r}" if tname else ""))
            for k, v in filters[:20]: print(f"      {k} = {jd(v)}")
        print()
    if not found: print("no triggers.json on disk here. Run harvest-triggers.")

def mode_inspect_raw(base, wid, key):
    steps = steps_of(load_json(os.path.join(base, f"{wid}.graph.json")))
    node = steps[int(key)] if key.isdigit() else next((s for s in steps if s.get("id") == key), None)
    if node is None: sys.exit(f"no step {key}")
    print(json.dumps(redact_deep(node), indent=1, ensure_ascii=False)[:8000])

# ----------------------------------------------------------------- diagram
def _mm_label(s):
    """Escape a string for a quoted Mermaid node label."""
    s = " ".join(str(s or "").split())
    return s.replace('"', "#quot;").replace("<", "#lt;").replace(">", "#gt;").replace("[", "(").replace("]", ")")

def _mm_edge_label(s):
    s = " ".join(str(s or "").split())
    return s.replace('"', "'").replace("|", "/").replace(":", " -")

def _wf_targets(steps, types):
    """workflow ids referenced by add_to_workflow / remove_from_workflow steps."""
    out = set()
    for s in steps:
        if step_type(s).lower() in types:
            w = attrs_of(s).get("workflow_id")
            for v in (w if isinstance(w, list) else [w]):
                if isinstance(v, str) and v:
                    out.add(v)
    return out

def _membership_targets(steps):
    """workflow ids tested by 'is the contact in workflow X' conditions."""
    out = set()
    for s in steps:
        for c in conditions_of(s):
            if str(c.get("conditionType") or "").lower() == "workflow_contact":
                v = c.get("conditionValue")
                for x in (v if isinstance(v, list) else [v]):
                    if isinstance(x, str) and x:
                        out.add(x)
    return out

def _trigger_fields(doc):
    """(type, name, field_id) per trigger; field_id only for contact-field-change triggers."""
    out = []
    for t in trigger_list(doc):
        ttype = str(t.get("type") or t.get("eventType") or "?")
        tname = str(t.get("name") or t.get("label") or "")
        fid = None
        for c in t.get("conditions") or []:
            if not isinstance(c, dict):
                continue
            cand = c.get("id") or str(c.get("field") or "").split(".")[-1]
            if is_id(cand) and "chang" in str(c.get("operator") or "").lower():
                fid = cand
        out.append((ttype, tname, fid))
    return out

def mode_diagram(base, args):
    focus = arg(args, "--focus"); hops = arg(args, "--hops", 1, int)  # 1 hop = direct neighbours
    show_all = "--all" in args; show_stages = "--stages" in args
    out_path = arg(args, "--out")

    wfs, titles = {}, {}
    for wid, d, steps in iter_workflows(base):
        d = d or {}
        trig = load_triggers(base, wid)
        titles.update(field_titles_of(steps))
        wfs[wid] = dict(name=d.get("name") or wid, status=d.get("status") or "?",
                        adds=_wf_targets(steps, {"add_to_workflow"}),
                        removes=_wf_targets(steps, {"remove_from_workflow"}),
                        member=_membership_targets(steps),
                        writes=field_writes_of(steps) | field_reads_of(steps),
                        stages=stages_of(steps),
                        triggers=_trigger_fields(trig) if trig is not None else None)

    # edges: (src, dst, kind, label); field nodes for field-change triggers
    edges, field_nodes = [], {}
    for wid, w in wfs.items():
        for t in w["adds"]:
            if t in wfs: edges.append((wid, t, "add", "adds"))
        for t in w["removes"]:
            if t in wfs: edges.append((wid, t, "rem", "removes"))
        for t in w["member"]:
            if t in wfs: edges.append((wid, t, "mem", "tests membership"))
        for ttype, tname, fid in (w["triggers"] or []):
            if fid:
                field_nodes.setdefault(fid, set()).add(wid)
    for fid, fired in field_nodes.items():
        for wid in fired:
            edges.append((f"f_{fid}", wid, "trig", "fires on change"))
        for wid, w in wfs.items():
            if fid in w["writes"]:
                edges.append((wid, f"f_{fid}", "write", "writes / clears"))
    if show_stages:
        for wid, w in wfs.items():
            if w["stages"]:
                edges.append((wid, "stages", "stage", f"moves stage ({len(w['stages'])})"))

    # optional focus: keep the neighbourhood of one workflow
    keep = None
    if focus:
        seeds = {wid for wid, w in wfs.items() if norm_name(focus) in norm_name(w["name"])}
        if not seeds:
            sys.exit(f"--focus: no workflow name contains {focus!r}")
        keep = set(seeds)
        for _ in range(max(hops, 1)):
            for s, d, *_r in edges:
                if s in keep or d in keep:
                    keep |= {s, d}
        edges = [e for e in edges if e[0] in keep and e[1] in keep]

    connected = {e[0] for e in edges} | {e[1] for e in edges}
    shown = [wid for wid in wfs if (show_all or wid in connected) and (keep is None or wid in keep)]
    isolated = [wfs[w]["name"] for w in wfs if w not in connected and (keep is None or w in keep)]

    def nid(x): return "w_" + re.sub(r"[^A-Za-z0-9]", "", x)[:12] if x in wfs else re.sub(r"[^A-Za-z0-9_]", "", x)
    lines = ["flowchart LR"]
    for wid in shown:
        w = wfs[wid]
        trig_txt = ""
        if w["triggers"] is None:
            trig_txt = "child: no trigger of its own" if not any(e[1] == wid and e[2] == "trig" for e in edges) else ""
        elif w["triggers"]:
            trig_txt = "trigger: " + ", ".join(sorted({t for t, _n, _f in w["triggers"]}))[:60]
        else:
            trig_txt = "no trigger object"
        parts = [_mm_label(w["name"])]
        if w["status"] != "published": parts.append(w["status"])
        if trig_txt: parts.append(_mm_label(trig_txt))
        lines.append(f'  {nid(wid)}["{"<br/>".join(parts)}"]')
        if w["status"] != "published": lines.append(f"  class {nid(wid)} draft")
    for fid in field_nodes:
        if keep is not None and f"f_{fid}" not in keep: continue
        lines.append(f'  {nid("f_" + fid)}(["Field: {_mm_label(titles.get(fid, fid))}<br/>{fid}"])')
        lines.append(f'  class {nid("f_" + fid)} field')
    if show_stages and any(e[1] == "stages" for e in edges):
        lines.append('  stages[("Pipeline stages")]'); lines.append("  class stages field")
    mem_idx = []
    for i, (s, d, kind, label) in enumerate(edges):
        if kind == "rem": arrow = f"-. {_mm_edge_label(label)} .->"
        elif kind == "trig": arrow = f"== {_mm_edge_label(label)} ==>"
        elif kind == "mem": arrow = f"-. {_mm_edge_label(label)} .->"; mem_idx.append(i)
        else: arrow = f"-- {_mm_edge_label(label)} -->"
        lines.append(f"  {nid(s)} {arrow} {nid(d)}")
    lines.append("  classDef draft stroke-dasharray: 5 4,stroke-width:1px;")
    lines.append("  classDef field fill:#e7f0e9,stroke:#2f6b3a,stroke-width:1.5px;")
    for i in mem_idx:
        lines.append(f"  linkStyle {i} stroke:#9b2c3f,stroke-width:1.5px;")
    mermaid = "\n".join(lines)

    legend = ("Legend: solid arrow = adds the contact to the target workflow; dashed = removes; "
              "thick = a custom-field change fires the target (rounded node = the field, with who writes it); "
              "red dashed = a branch that tests whether the contact is inside the target workflow. "
              "Dashed node border = draft. Workflows with no edges are not drawn"
              + ("" if show_all else f" ({len(isolated)} omitted; --all shows them)") + ".")
    title = f"Workflow dependency map: {os.path.basename(base)}" + (f" (focus: {focus}, {hops} hop(s))" if focus else "")
    if out_path and out_path.lower().endswith(".html"):
        html = (f"<title>{_mm_label(title)}</title>\n<style>body{{font:14px/1.5 system-ui,sans-serif;margin:24px;color:#1e1f1a;background:#f5f4f0}}"
                f"pre.mermaid{{background:#fff;border:1px solid #d9d5cb;border-radius:8px;padding:12px;overflow:auto}}"
                f"p{{max-width:80ch;color:#454740}}</style>\n<h1>{_mm_label(title)}</h1>\n<p>{legend}</p>\n"
                f"<pre class=\"mermaid\">\n{mermaid}\n</pre>\n")
        with open(out_path, "w", encoding="utf-8") as fh: fh.write(html)
        print(f"wrote {out_path} ({len(shown)} workflows, {len(edges)} edges, {len(field_nodes)} trigger fields)")
    elif out_path:
        with open(out_path, "w", encoding="utf-8") as fh:
            fh.write(f"# {title}\n\n{legend}\n\n```mermaid\n{mermaid}\n```\n")
        print(f"wrote {out_path} ({len(shown)} workflows, {len(edges)} edges, {len(field_nodes)} trigger fields)")
    else:
        print(mermaid)
        print(f"\n%% {len(shown)} workflows drawn, {len(edges)} edges, {len(field_nodes)} trigger fields, {len(isolated)} isolated omitted")
    if isolated and not show_all:
        print("%% isolated (no edges): " + "; ".join(sorted(isolated))[:1500], file=sys.stderr)

# ----------------------------------------------------------------- main
def main(argv):
    if len(argv) < 3:
        print(__doc__); sys.exit(64)
    mode, loc, rest = argv[1], argv[2], argv[3:]
    base = os.path.join(OUT_ROOT, loc)
    if mode in ("probe", "tree", "harvest", "harvest-triggers"):
        tok = load_token()
        {"probe": lambda: mode_probe(loc, tok), "tree": lambda: mode_tree(loc, tok),
         "harvest": lambda: mode_harvest(loc, tok, rest),
         "harvest-triggers": lambda: mode_harvest_triggers(loc, tok, rest)}[mode]()
        return
    if not os.path.isdir(base):
        sys.exit(f"no snapshots at {base}; run harvest first.")
    if mode == "schema": mode_schema(base, rest[0] if rest else None)
    elif mode == "inventory": mode_inventory(base, rest)
    elif mode == "fields": mode_fields(base, rest)
    elif mode == "flow": mode_flow(base, rest[0])
    elif mode == "summary": mode_summary(base)
    elif mode == "triggers": mode_triggers(base, rest[0] if rest else None)
    elif mode == "inspect-raw": mode_inspect_raw(base, rest[0], rest[1])
    elif mode == "diagram": mode_diagram(base, rest)
    else:
        print(__doc__); sys.exit(64)

if __name__ == "__main__":
    main(sys.argv)
GHL_MAPPER_EOF
chmod +x "$ROOT/scripts/ghl_workflow_mapper.py"
grep -qxF ".ghl-workflow-snapshots/" .gitignore 2>/dev/null || echo ".ghl-workflow-snapshots/" >> .gitignore
echo "installed to $ROOT (and added .ghl-workflow-snapshots/ to .gitignore)"; ls -R "$ROOT"
