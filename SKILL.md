---
name: ghl-workflow-mapper
description: "Maps the real internals of every GoHighLevel (GHL / LeadConnector) workflow in a sub-account: triggers, branch conditions, waits, custom-field reads and writes, tags, webhooks and pipeline-stage moves, none of which the public API or the GHL MCP server exposes. Read-only, through the same requests the browser makes when the workflow builder is open. First produces a dependency diagram of how the workflows trigger, add to, remove from and gate each other; then answers questions about them and audits for hidden problems on request. Use when an agency needs to see how its GHL automations fit together, know which workflows touch a process before changing or disabling it, find out why a workflow does or does not fire, or check which custom fields and custom values an automation chain depends on."
---

# GoHighLevel workflow mapper

GoHighLevel's public API (v2) and the GHL MCP server return workflow **metadata only**: id, name, status, version. Neither returns the actions inside a workflow, so every real question about an automation (what fires it, what it tests, what it writes, which other workflows it starts or stops) needs the step graph. This skill reads that graph with the same read-only requests the browser makes when the builder is open, draws the dependency map, and then lets you answer questions about the workflows with the definitions in hand.

Two ways to use it, in order:

1. **Map.** Get the go-ahead, get the token, download the workflow definitions, draw the diagram. Nothing else. This is the default when someone invokes the skill.
2. **Audit.** Only when the owner asks: answer questions about specific workflows, run the pitfall pass, and if they want a written inventory, build the tables.

Where a step says **ask the owner**, stop and ask. Guessing produces a document that reads as authoritative and is wrong.

## Checkpoints: stop and ask

1. **Before the first network call:** the permission overview, given to the owner in plain words, and their yes (guardrail 2, Map step 1).
2. **Before reading any location the owner did not name:** say which location and why (guardrail 7).
3. **Before any audit work:** the owner has asked for it and named the process or the question. The map step ends with the diagram; do not slide into an audit uninvited.
4. **Before classifying (audit only):** confirm the anchor workflow and the names to pass to `--core-names`.
5. **Before filling any Disposition cell (audit only):** the disposition is the owner's decision, apart from the two pre-fills the audit step names.
6. **Before the diagram or any deliverable lands anywhere shared** (repo, wiki, ticket): show it in the session first. It names live client automations.

Everything else in this file you may do without asking, as long as it is a GET and it is redacted.

## Files in this skill

| File | What it holds | When to open it |
|---|---|---|
| `scripts/bash/harvest_workflows.sh` (with `wf_lib.py`) | The harvester: every network step, `probe`, `tree`, `harvest` and `harvest-triggers`. GET only, through `curl`. | Run it for anything that talks to GHL. |
| `scripts/ghl_workflow_mapper.py` | The offline tool: `diagram` and every analysis mode, reading the snapshot the harvester saved. Python 3.8+, no packages. It has network modes of its own; this skill does not use them. | Run it for everything after the harvest. Read a named function only when you are adding a mode. |
| `reference/protocol.md` | The three endpoint hops, exact headers, paging, the trigger endpoint, failure codes, the step-type vocabulary, and how to resolve field and stage ids to names. | A call fails, the JSON shape looks new, or you are extending the script. |
| `reference/pitfalls.md` | The failure patterns to check workflows against during an audit, and how to diff a clone against its template. | Audit mode, before answering "what could be wrong here". |

Run the scripts; do not paste their source into the conversation. Their output is the thing you reason over. Each script's own usage text (run it with no arguments) is the authority on its modes and flags; if a flag here and a flag there disagree, follow the usage text and say so.

## Guardrails

1. **Send GET and nothing else.** Every network call in the script is an HTTP GET. Route any call you add through the script's existing GET helper, which cannot send another method. A write mutates a live automation in a client's account, and the workflow builder has no undo.
2. **Get the go-ahead before the first call.** Give the owner a short, plain-words overview of what you need permission to do, then wait for a yes before any network call. Cover four things: you will read the workflow definitions in the sub-account they name, using the same requests the GHL web app sends when a person opens the workflow builder; every request is a GET, sent one per second, so nothing in GHL changes; you need them to copy a session token from the browser and store it in the OS secret store, never in the chat; and the definitions are saved to a local folder kept out of version control. Add, as information, that these requests are not part of GHL's public API and GHL can change them without notice, in which case the tool stops rather than retrying. This is a permission request, not an agreement: do not ask the owner to accept terms, and do not record who said yes.
3. **Stop when the endpoint changes.** A 404 on a single workflow id means that workflow was deleted after you listed it: record it as a gap, do not retry it, and carry on. A 404 on the list or detail endpoint for a location that worked minutes ago, or a response missing a field `reference/protocol.md` says you need, means GHL moved the endpoint: report the request path and what came back, and stop the run. Do not retry in a loop; a retry loop against these endpoints is what gets an agency blocked.
4. **Treat the session token as a live credential.** Store it in the operating system secret store and let the script read it from there. The token is agency level: one copy reads every sub-account the login can see, and a shell command carrying it is recorded in shell history and in this transcript. Both scripts also accept a `GHL_TOKEN_ID` environment variable for runners that inject secrets themselves; in an interactive session prefer the secret store, and if you do use the variable, set it inline for the single command (`GHL_TOKEN_ID="$(secret lookup command)" bash ...`) and never `export` it. Print only the token length, never its value.
5. **Snapshots are client data and may contain secrets.** Workflow graphs carry webhook URLs with API keys in their headers, Facebook Conversion API tokens, internal phone numbers and email templates. Keep the snapshot folder out of version control: add its name to `.gitignore` in the working directory before the first harvest, and confirm that you did. Every print path must redact URLs to hostnames, truncate free text, and blank webhook headers and token-like keys, as the shipped modes already do.
6. **The same redaction binds what you write.** Quote webhook URLs by hostname only, quote sends by subject line only, and never copy a raw graph excerpt into chat or into a deliverable. When you need one step's detail, use `inspect-raw`, which redacts on the way out. When you need a view the modes do not give you, add a mode (GET only, printing only through the existing redaction helpers) rather than dumping graph JSON into the conversation.
7. **Map only the locations the owner named in this request.** If the work suggests reading another location, stop, say which and why, and get a yes first. The token is agency level and will read accounts nobody asked you to touch, so location scope is yours to enforce.
8. **Keep the calls polite, and harvest only when you need a fresh snapshot.** Do not re-harvest a location you already have a snapshot for in this session; run the offline modes against it. Sleep one second between calls, which the script does. A burst is the fastest way to get the pattern noticed and blocked, which would end the method for every account.

## Map mode (default)

Copy this checklist and check items off as you go:

```
GHL workflow map:
- [ ] Step 1: Permission overview given, owner said yes, owner ran the allow command
- [ ] Step 2: Account picked, location id in hand, token stored, snapshot folder gitignored
- [ ] Step 3: probe returns GRAPH REACHED
- [ ] Step 4: harvest + harvest-triggers finished, counts checked, gaps recorded
- [ ] Step 5: diagram produced and shown; isolated workflows listed; stop here
```

### Step 1: Get the go-ahead and the allow rule

Guardrail 2, before anything touches the network. Give the permission overview as a short list, in plain words, and wait for the yes. Checkpoint 1.

Then, straight away, give the owner this command to run in their own terminal, with `<working folder>` replaced by the absolute path of the working folder, and wait for them to confirm. Claude Code's permission system can block the script even after the owner has said yes, because it sends a credential over the network, and you cannot grant yourself permission: only the owner can add the rule.

```bash
cd "<working folder>" && python3 - <<'PY'
import json, os
p = ".claude/settings.local.json"
s = json.load(open(p)) if os.path.exists(p) else {}
allow = s.setdefault("permissions", {}).setdefault("allow", [])
for r in ("Bash(python3 .claude/skills/ghl-workflow-mapper/scripts/ghl_workflow_mapper.py:*)",
          "Bash(bash .claude/skills/ghl-workflow-mapper/scripts/bash/harvest_workflows.sh:*)"):
    if r not in allow:
        allow.append(r)
os.makedirs(".claude", exist_ok=True)
with open(p, "w") as f:
    json.dump(s, f, indent=2)
print("allowed the ghl-workflow-mapper scripts in", p)
PY
```

The rules cover only these two scripts in this folder; to remove them later, the owner deletes the two lines containing `ghl-workflow-mapper` from `.claude/settings.local.json`. From here on, run every network step (`probe`, `tree`, `harvest`, `harvest-triggers`) as `bash .claude/skills/ghl-workflow-mapper/scripts/bash/harvest_workflows.sh <mode> ...` and every offline step as `python3 .claude/skills/ghl-workflow-mapper/scripts/ghl_workflow_mapper.py <mode> ...`, from the working folder and never by absolute path, so they match the rules. If a call is still blocked, do not work around it: do not send the same requests another way, and do not edit settings files yourself. Stop and tell the owner.

### Step 2: Pick the account and get credentials

**Pick the account.** If the agency keeps a template sub-account that new clients are cloned from, map that first: it is the source of truth for every clone. Map an individual client sub-account only when the owner named it (guardrail 7, checkpoint 2).

**Get the location id.** Ask the owner to open the sub-account in GHL and read the browser address bar: the URL looks like `https://app.gohighlevel.com/v2/location/<locationId>/...` (agencies on a white-labelled domain see their own domain, then `/v2/location/`). The string between `/location/` and the next `/` is the location id, about 20 letters and digits. Ask them to copy it and paste it into the chat; confirm it back before you use it.

**Get a token.** The owner does this in about two minutes; walk them through it one step at a time. In a browser logged into GHL: open DevTools (F12, or right-click the page and choose Inspect), select the **Network** tab, then open the sub-account's **Settings, Custom Fields** page (or reload any GHL page). Requests to `backend.leadconnectorhq.com` appear in the list; the Custom Fields page reliably fires one named `search?parentId=...` whose full URL is `https://backend.leadconnectorhq.com/locations/<locationId>/customFields/search?...`, and any request to that host works. Click it, open the **Headers** panel, scroll to **Request Headers**, and copy the full value of the `token-id` header (right-click the value, Copy value). It is a long string starting `eyJ`, roughly a thousand characters. It expires in about **one hour**. The script reads the expiry from the token itself (no network call) and prints the minutes left each time it loads it; quote that number rather than estimating, and ask for a fresh token when it says expired.

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

Both scripts read `GHL_TOKEN_ID` from the environment first (guardrail 4 governs that path), then the macOS keychain item of that name, then libsecret.

**Set up the snapshot folder.** Run the scripts from the working directory of the job, not from inside the skill directory: snapshots land in `GHL_SNAPSHOT_DIR`, defaulting to `.ghl-workflow-snapshots/<locationId>/` relative to the current directory. Add that folder name to `.gitignore` there before the first harvest (guardrail 5).

### Step 3: Prove access

```bash
bash .claude/skills/ghl-workflow-mapper/scripts/bash/harvest_workflows.sh probe <locationId>
```

The harvester lists the workflows, opens one, reads its step graph and its triggers, and prints `GRAPH REACHED` or a clear reason. Use the harvester for every network step, always, without asking: the Python tool's own network modes are not part of this skill. Do not continue past a failure; `reference/protocol.md` maps each status code to its meaning.

### Step 4: Harvest

```bash
bash .claude/skills/ghl-workflow-mapper/scripts/bash/harvest_workflows.sh tree <locationId>
bash .claude/skills/ghl-workflow-mapper/scripts/bash/harvest_workflows.sh harvest <locationId>
bash .claude/skills/ghl-workflow-mapper/scripts/bash/harvest_workflows.sh harvest-triggers <locationId>
```

`tree` lists every workflow id and name with folders recursed. `harvest` saves `<wfId>.detail.json` and `<wfId>.graph.json`. `harvest-triggers` saves each workflow's trigger list from the endpoint the builder itself reads, and reports counts of saved, children and failed. An empty list is expected, not broken: that workflow has no trigger of its own and only runs when another workflow adds the contact, so count it as a child. The harvester retries a 503 once by itself; record anything still failed as a gap and do not retry again.

A sub-account of about a hundred workflows is roughly three GETs per workflow at one second apiece, so budget a few minutes. Run the harvest in the background, then **wait for it to exit and check its counts before any offline mode**; the offline modes cannot tell a partial snapshot from a complete one.

The list call requests one page of up to 500 rows per folder and does not page beyond it. If any folder returns exactly 500 rows, say the total may be truncated rather than reporting it as fact.

### Step 5: Draw the map and stop

```bash
python3 .claude/skills/ghl-workflow-mapper/scripts/ghl_workflow_mapper.py diagram <locationId> --out workflow-map.html
python3 .claude/skills/ghl-workflow-mapper/scripts/ghl_workflow_mapper.py diagram <locationId> --out workflow-map.md
```

`diagram` is offline: it reads the snapshot the harvester saved and writes a Mermaid flowchart. Nodes are workflows (dashed border = draft; the second line shows the trigger type, or "child: no trigger of its own"). Edges are the four relationships that make workflows depend on each other: **adds** the contact to another workflow (solid), **removes** it (dashed), **fires on change** (thick, from a rounded field node that also shows which workflows write that field), and **tests membership** (red dashed, a branch asking whether the contact is currently inside another workflow). Workflows with none of these edges are not drawn; the tool lists them on stderr so you can report the count.

Show the result in the session (checkpoint 6):

- If you have an Artifact tool (Claude Code with artifacts enabled), publish the `.html` output as the artifact. It contains a `<pre class="mermaid">` block that artifacts render natively; do not add a Mermaid library to it.
- Otherwise save the `.md` output next to the job and tell the owner it renders in GitHub, VS Code, Obsidian and Notion.
- Add `--focus "<workflow name>" --hops 1` for the neighbourhood of one workflow when the whole account is too dense to read; `--all` also draws the isolated workflows; `--stages` adds a single pipeline-stages node with an edge from every workflow that moves a stage.

Then say, in two or three sentences, what the map shows: how many workflows, how many are children with no trigger, how many field-change triggers, how many membership tests, and how many isolates. **Stop there.** The map is the deliverable of this mode. Offer, in one line, that the owner can now ask questions about any workflow or ask for an audit. Do not begin an audit until asked (checkpoint 3).

## Audit mode (on request)

When the owner asks a question about a workflow, or asks what could be wrong, work from the snapshot; do not re-harvest (guardrail 8).

**Answering a question about one or a few workflows.**

```bash
python3 .claude/skills/ghl-workflow-mapper/scripts/ghl_workflow_mapper.py flow <locationId> <wfId>
python3 .claude/skills/ghl-workflow-mapper/scripts/ghl_workflow_mapper.py triggers <locationId> [wfId]
python3 .claude/skills/ghl-workflow-mapper/scripts/ghl_workflow_mapper.py inspect-raw <locationId> <wfId> <stepIndex|nodeId>
```

`flow` prints a header (name, id, status, dataVersion, step count, trigger) and one indented line per step as `[i] type | name | key params`, with wait durations and windows, tags, sends (subject or truncated body), field writes, stage targets, and a branch line per `if_else` condition. Quote those lines as printed; never widen them by hand. Ids lead and builder labels follow, and a mismatch between a label and its attribute (a step labelled "5 Minutes After" whose attribute says `after=45 minutes`) is exactly the kind of thing to point out.

**Looking for hidden problems.** Read `reference/pitfalls.md` first, then check the workflows in question against each pattern: field-change triggers masquerading as form triggers, exact-match strings that can never match, membership-in-workflow conditions, flags that are never reset, stale step labels, status written without a stage, children whose parent no longer adds to them, tags nothing inside GHL reads, multiple writers of one field, clone artefacts (stage or location ids from another sub-account), and drafts doing nothing. Run `schema <locationId>` once before you write any rule about step types: GHL's vocabulary drifts and the names are not the obvious ones (sends are `sms`, `email`, `internal_notification`; there is no `send_sms`).

**Comparing values the workflows expect with values a form actually writes** needs the form's option list, which is not in the workflow graph. Get it from the GHL UI or the agency's GHL MCP server, then compare it against the `conditionValue` strings `flow` prints. A value the form never sends is a branch that never fires.

**Building the written inventory** (only if the owner wants a document):

```bash
python3 .claude/skills/ghl-workflow-mapper/scripts/ghl_workflow_mapper.py inventory <locationId> --anchor "<workflow name>" \
  [--core-names "A,B"] [--process-regex RE] [--reminder-regex RE] [--followup-regex RE] \
  [--only CLASS,...] [--grep S] [--expect-count N] [--md]
python3 .claude/skills/ghl-workflow-mapper/scripts/ghl_workflow_mapper.py fields <locationId> [--md] [--min-wf N] [--section fields|tokens|both]
python3 .claude/skills/ghl-workflow-mapper/scripts/ghl_workflow_mapper.py summary <locationId>
```

Confirm the **anchor** (the workflow that visibly does the thing) with the owner first (checkpoint 4); `--anchor` is required and `--core-names` is the owner's override. The classifier seeds itself from the anchor's fields, tags, stages and trigger scope, scores every other workflow by overlap and by name (`CORE`, `REMINDER`, `FOLLOWUP`, `ADJACENT`, `UNRELATED`), and prints its evidence per row so a human can override it. If `CORE` comes out bigger than the owner expected, show the seed lines the mode prints and let the owner cut the seed set. Resolve field and stage ids to names read-only per `reference/protocol.md`, with an outer join so unresolved ids are listed, never dropped.

The document: purpose and scope; how it was produced (commands and snapshot date); counts; Table A (every workflow, with a **Disposition** column the owner fills in, pre-filled only as `needs-review` for `CORE` and `ADJACENT` and `keep` for a `FOLLOWUP` whose evidence reads "name; no seed overlap", checkpoint 5); deep dives from `flow` for `CORE` and `ADJACENT`; Table B (custom fields, with two empty reviewer columns: *shared with another process?* and *safe to retire?*) and the custom values the chain depends on; Table C (stages); the dependency map; gaps; refresh instructions. State that contact custom-field values a human typed are not readable by this method.

## Refreshing a snapshot

Snapshots go stale the moment someone edits a workflow. To refresh: fresh token, then the harvester's `harvest` and `harvest-triggers`, then `diagram`; diff the new snapshot folder against the old one to see what changed.

## Starter prompt

> Use the ghl-workflow-mapper skill. Before your first network call, give me a short overview of what you need my permission to do, wait for my yes, then give me the terminal command that lets you run the script. I will need to give you two things and I do not know where to find them, so guide me step by step: first the location id of the sub-account (tell me where it sits in the GHL address bar and wait for me to paste it), then the session token (tell me exactly where to click in the browser DevTools and wait for me to confirm it is stored). Read no other location without asking me first. Produce the dependency diagram of the whole account and stop there. I will ask questions or request an audit afterwards.
