# ghl-workflow-mapper

An Agent Skill that gives an AI coding agent the one thing GoHighLevel never hands it: the actual definitions of your workflows. With those in hand the agent draws a dependency map of how your automations trigger, add to, remove from and gate each other, and can then answer questions about them or audit them for hidden problems.

GoHighLevel's public API and the GHL MCP server expose workflow names and status only, never the steps. This skill reads the steps with the same read-only requests your browser makes when the workflow builder is open.

## What you get

1. **A diagram.** Every workflow in a sub-account as a node; edges for "adds the contact to", "removes from", "this field changing fires that workflow" and "branches on whether the contact is inside that workflow". Drafts are dashed. Workflows with no relationships are listed, not drawn.
2. **Answers.** Ask about any workflow and the agent reads its steps back to you: waits, windows, tags, field writes, stage moves, branch conditions, exactly as configured rather than as labelled.
3. **An audit, if you ask for one.** A pass over the known failure patterns (field-change triggers hiding behind form-looking names, exact-match strings that can never match, membership tests, flags that never reset, stale labels, clone artefacts), and optionally a full written inventory of workflows, custom fields, custom values and stages.

Read-only by construction: every network call the tool makes is an HTTP GET. It never writes to GoHighLevel.

## Supported environments

| Environment | Status | Why |
|---|---|---|
| **Claude Code** (CLI, or the Code tab in the Claude desktop app) | Supported | Local shell and Python, macOS keychain for the token, local snapshot files, diagram published as an artifact. If you have the Bash sandbox enabled, allowlist `backend.leadconnectorhq.com` and `firebasestorage.googleapis.com` and exclude the `security` command. |
| Other coding agents with a shell, Python 3.8+ and curl (Cursor, Codex CLI, and similar) | Should work | Same requirements. The diagram is written as a Markdown file with a Mermaid fence, which renders in GitHub, VS Code, Obsidian and Notion. |

## Install

From the root of the folder you want to work in (a scratch repo is fine):

```bash
curl -fsSL https://raw.githubusercontent.com/mb0390231ai/ghl-workflow-mapper/main/install.sh | bash
```

or copy all six files by hand into `.claude/skills/ghl-workflow-mapper/`. The skill uses both scripts: the bash harvester downloads, and the Python tool draws and analyses (see "What is in the tool" below).

```
.claude/skills/ghl-workflow-mapper/
├── SKILL.md
├── reference/
│   ├── protocol.md
│   └── pitfalls.md
└── scripts/
    ├── ghl_workflow_mapper.py
    └── bash/
        ├── harvest_workflows.sh
        └── wf_lib.py
```

Then add `.ghl-workflow-snapshots/` to that folder's `.gitignore`. The snapshots hold your clients' automation definitions and, inside webhook steps, live API keys.

### Let Claude Code run the script

Claude Code's permission system can block the script even after you say yes to the agent, because the script sends your session token over the network, and the agent cannot give itself permission. Right after you say yes, the agent gives you this command to run in your own terminal. It is here for reference; run it from the same folder:

```bash
python3 - <<'PY'
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

The rules cover only these two scripts in this folder. To remove them later, delete the two lines containing `ghl-workflow-mapper` from `.claude/settings.local.json`.

## Starter prompt

Open Claude Code in that folder and paste:

> Use the ghl-workflow-mapper skill. Before your first network call, give me a short overview of what you need my permission to do, wait for my yes, then give me the terminal command that lets you run the script. I will need to give you two things and I do not know where to find them, so guide me step by step: first the location id of the sub-account (tell me where it sits in the GHL address bar and wait for me to paste it), then the session token (tell me exactly where to click in the browser DevTools and wait for me to confirm it is stored). Read no other location without asking me first. Produce the dependency diagram of the whole account and stop there. I will ask questions or request an audit afterwards.

The agent will explain what it is about to do and what it needs from you (the sub-account's location id from the address bar, and about two minutes in your browser's DevTools to copy a session token from a request to backend.leadconnectorhq.com, which expires after an hour), download the workflow definitions, and show you the diagram. After that, ask it anything: "what does the Booking Confirmation workflow actually do", "which workflows would break if I disabled this one", "audit these for hidden problems".

## Before you run it

- The requests are the ones GoHighLevel's own web app sends when you open the builder. They are not part of GHL's public API, and GHL can change them without notice. Before the first call, the agent tells you what it needs permission to do and waits for your go-ahead.
- The token is agency-level. One copy reads every sub-account your login can see. The skill stores it in your OS secret store and never prints it; do not paste it into chat.
- One call per second, run rarely. Bursting these endpoints is how an agency gets noticed and blocked.

## What is in the tool

`scripts/bash/harvest_workflows.sh` with `scripts/bash/wf_lib.py` is the harvester: every network step the skill runs goes through it (`probe`, `tree`, `harvest`, `harvest-triggers`; GET only, through curl; bash 3.2 compatible, with inline Python helpers). It also has offline modes, including `inspect` and `inspect-full` for diffing one location's copy of a workflow against the template it was cloned from.

`scripts/ghl_workflow_mapper.py` (Python 3.8+, no packages) reads the snapshot the harvester saves and draws the `diagram`, plus `schema`, `flow`, `triggers`, `inspect-raw`, `inventory`, `fields` and `summary`. It has network modes of its own, but the skill does not use them.

Run either script with no arguments for usage.

## Example

An invented but structurally typical result, so you can see what the map and the tables look like before you run anything: see the example page linked from wherever you found this skill.
