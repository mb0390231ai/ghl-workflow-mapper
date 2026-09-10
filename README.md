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
| Other coding agents with a shell and Python 3.8+ (Cursor, Codex CLI, and similar) | Should work | Same requirements. The diagram is written as a Markdown file with a Mermaid fence, which renders in GitHub, VS Code, Obsidian and Notion. |

## Install

From the root of the folder you want to work in (a scratch repo is fine):

```bash
curl -fsSL https://raw.githubusercontent.com/mb0390231ai/ghl-workflow-mapper/main/install.sh | bash
```

or copy the four files by hand into `.claude/skills/ghl-workflow-mapper/`:

```
.claude/skills/ghl-workflow-mapper/
├── SKILL.md
├── reference/
│   ├── protocol.md
│   └── pitfalls.md
└── scripts/
    └── ghl_workflow_mapper.py
```

Then add `.ghl-workflow-snapshots/` to that folder's `.gitignore`. The snapshots hold your clients' automation definitions and, inside webhook steps, live API keys.

## Starter prompt

Open Claude Code in that folder and paste:

> Use the ghl-workflow-mapper skill. Before your first network call, read me the skill's read-only note and terms note in plain words and wait for my explicit yes, then record who accepted and when. I will need to give you two things and I do not know where to find them, so guide me step by step: first the location id of the sub-account (tell me where it sits in the GHL address bar and wait for me to paste it), then the session token (tell me exactly where to click in the browser DevTools and wait for me to confirm it is stored). Read no other location without asking me first. Produce the dependency diagram of the whole account and stop there. I will ask questions or request an audit afterwards.

The agent will explain what it is about to do and what it needs from you (the sub-account's location id from the address bar, and about two minutes in your browser's DevTools to copy a session token from a request to backend.leadconnectorhq.com, which expires after an hour), download the workflow definitions, and show you the diagram. After that, ask it anything: "what does the Booking Confirmation workflow actually do", "which workflows would break if I disabled this one", "audit these for hidden problems".

## Before you run it

- The requests are the ones GoHighLevel's own web app sends when you open the builder. They are not part of GHL's public API, GHL can change them without notice, and you should check that this use is acceptable under your own agreement with GoHighLevel. The skill makes the agent stop and ask you before the first call.
- The token is agency-level. One copy reads every sub-account your login can see. The skill stores it in your OS secret store and never prints it; do not paste it into chat.
- One call per second, run rarely. Bursting these endpoints is how an agency gets noticed and blocked.

## What is in the tool

`scripts/ghl_workflow_mapper.py`, Python 3.8+, standard library only. Modes: `probe`, `tree`, `harvest`, `harvest-triggers` (network, GET only) and `diagram`, `schema`, `flow`, `triggers`, `inspect-raw`, `inventory`, `fields`, `summary` (offline, against the saved snapshot). Run it with no arguments for usage.

## Example

An invented but structurally typical result, so you can see what the map and the tables look like before you run anything: see the example page linked from wherever you found this skill.
