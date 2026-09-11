#!/usr/bin/env bash
# Read GoHighLevel workflow definitions (including action graphs) for one
# sub-account, using the same read-only requests the workflow builder makes.
#
# NOTE
#   The skill runs every network step (probe, tree, harvest, harvest-triggers)
#   through this script. The Python tool `ghl_workflow_mapper.py` in this repo
#   draws the `diagram` and runs the offline analysis from the snapshots saved
#   here.
#
# WHY THIS EXISTS
#   GHL's public API v2 exposes workflow metadata only (id/name/status/version):
#   there is no endpoint for a workflow's actions. You need the actions to audit
#   an automated process across a fleet of sub-accounts, e.g. to find which
#   locations really move an opportunity stage and which silently skip it.
#
#   The endpoints below are the ones GHL's own web app calls. These are the same
#   read-only requests the browser makes when the workflow builder is open. They
#   are not part of GHL's public API and can change without notice. Get the
#   account owner's go-ahead before running it. Keep usage read-only,
#   rate-limited, and infrequent.
#   If a call starts returning 404 or a different JSON shape, assume GHL moved
#   it, and do not escalate retries.
#
# READ-ONLY BY CONSTRUCTION
#   Only GET is issued. There is no code path here that writes to GHL. Do not
#   add one: a bad write would mutate a live automation.
#
# AUTH
#   A Firebase session JWT ("token-id" header), stored in the macOS keychain
#   so it never lands in shell history, a file, or this repo:
#
#     security add-generic-password -U -a "$USER" -s GHL_TOKEN_ID -w "$(pbpaste)"
#
#   On Linux the token is read from libsecret (secret-tool, service GHL_TOKEN_ID);
#   a GHL_TOKEN_ID environment variable, if set, is read first.
#
#   Tokens last ~1 hour. Re-copy from DevTools (Network tab, any
#   backend.leadconnectorhq.com request, Request Headers -> token-id) and re-run
#   that command when calls start returning 401.
#
# USAGE
#   NETWORK MODES (GET only)
#     probe            <locationId>                  # list, detail, graph, triggers
#     tree             <locationId>                  # enumerate workflows only
#     harvest          <locationId> [<workflowId> ...]  # detail + graph -> OUT_DIR
#     harvest-triggers <locationId> [<workflowId> ...]  # builder's trigger list -> <workflowId>.triggers.json
#
#   OFFLINE MODES (read the snapshots already in OUT_DIR)
#     schema      <locationId> [stepType]           # step-type vocabulary + attr paths
#     inventory   <locationId> --anchor "<name>" [--md] [--core-names "A,B"]
#                       [--process-regex RE] [--expect-count N]
#                       [--require-core "A,B,C"] [--only CLASS,..]
#                       [--grep SUBSTR] [--footer-only]
#     fields      <locationId> [--md] [--min-wf N] [--section fields|tokens|both]
#     flow        <locationId> <workflowId>         # linearized narrative
#     inspect     <locationId> <workflowId>         # step list + stage-move targets
#     inspect-full <locationId> <workflowId>        # every branch condition, in full
#     inspect-raw <locationId> <workflowId> <stepIndex|nodeId>  # one step's JSON
#     triggers    <locationId> [<workflowId>]       # harvested trigger definitions
#     summary     <locationId>                      # which workflows move stages
#
#   OUT_DIR (or GHL_SNAPSHOT_DIR) defaults to .ghl-workflow-snapshots/<locationId>/.
#   Snapshots are plain JSON so successive runs can be diffed for workflow
#   drift across the fleet.
#
#   The offline modes share python helpers in wf_lib.py, next to this script.
#   Route analysis THROUGH these modes rather than reading the snapshot files
#   ad hoc: if you need something new, add a mode.
set -euo pipefail

BASE="https://backend.leadconnectorhq.com/workflow"
SLEEP_BETWEEN=1          # seconds; be a polite client, no documented rate limit
OUT_DIR="${OUT_DIR:-${GHL_SNAPSHOT_DIR:-.ghl-workflow-snapshots}}"
# Shared python helpers (wf_lib.py) live next to this script; the analysis modes
# pass this path as argv[1] to their heredocs and import from it.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="${1:-}"
LOC="${2:-}"
WF_OVERRIDE="${3:-}"   # workflow id (inspect*/flow/triggers) or first flag/type arg

if [[ -z "$MODE" || -z "$LOC" ]]; then
  sed -n '2,69p' "$0"
  exit 64
fi

# Token: GHL_TOKEN_ID from the environment, else the macOS keychain, else libsecret.
TOKEN="${GHL_TOKEN_ID:-}"
if [[ -z "$TOKEN" ]]; then
  TOKEN="$(security find-generic-password -a "$USER" -s GHL_TOKEN_ID -w 2>/dev/null || true)"
fi
if [[ -z "$TOKEN" ]]; then
  TOKEN="$(secret-tool lookup service GHL_TOKEN_ID 2>/dev/null || true)"
fi
if [[ -z "$TOKEN" ]]; then
  echo "ERROR: no token. Store it as GHL_TOKEN_ID in the OS secret store (see the AUTH section in this script)." >&2
  exit 3
fi
# Minutes until the token's exp claim, read locally from the JWT (no network call).
MIN_LEFT="$(printf '%s' "$TOKEN" | python3 -c '
import sys, json, base64, time
try:
    seg = sys.stdin.read().split(".")[1]; seg += "=" * (-len(seg) % 4)
    print(int((json.loads(base64.urlsafe_b64decode(seg))["exp"] - time.time()) // 60))
except Exception:
    pass')"
if [[ -z "$MIN_LEFT" ]]; then
  echo "token loaded (${#TOKEN} chars, value not printed; expiry unreadable)"
elif (( MIN_LEFT < 0 )); then
  echo "token loaded (${#TOKEN} chars, value not printed) but it EXPIRED $(( -MIN_LEFT )) min ago: store a fresh token-id before any network mode." >&2
else
  echo "token loaded (${#TOKEN} chars, value not printed; expires in ${MIN_LEFT} min)"
fi

# GET $1 into file $2; echoes the HTTP status. Extra args are passed to curl,
# which is how the probe swaps in a reduced header set.
ghl_get() {
  local url="$1" dest="$2"; shift 2
  curl -sS -o "$dest" -w '%{http_code}' "$url" \
    -H "token-id: ${TOKEN}" \
    "$@"
}

FULL_HEADERS=(-H "channel: APP" -H "source: WEB_USER" -H "version: 2021-04-15" -H "Content-Type: application/json")

# The workflow DETAIL endpoint authenticates with authorization: Bearer (not
# token-id) and is called from the automation-builder origin. GHL_BEARER, if
# present in the keychain, is used here; otherwise the token-id value is tried
# as a Bearer (works only if GHL issues one JWT for both).
BEARER="${GHL_BEARER:-$(security find-generic-password -a "$USER" -s GHL_BEARER -w 2>/dev/null || printf '%s' "$TOKEN")}"
DETAIL_HEADERS=(
  -H "authorization: Bearer ${BEARER}"
  -H "channel: APP"
  -H "source: WEB_USER"
  -H "origin: https://client-app-automation-workflows.leadconnectorhq.com"
  -H "referer: https://client-app-automation-workflows.leadconnectorhq.com/"
)

# Summarize a JSON payload without printing it (these responses are large, and
# they hold account data we do not want spilling into a transcript).
summarize() {
  python3 - "$1" <<'PY'
import json, sys
path = sys.argv[1]
try:
    with open(path) as fh:
        doc = json.load(fh)
except Exception as exc:
    print(f"  not JSON ({exc.__class__.__name__}); first bytes: {open(path,'rb').read(120)!r}")
    raise SystemExit
def keys(obj):
    return sorted(obj)[:14] if isinstance(obj, dict) else type(obj).__name__
print(f"  top-level keys: {keys(doc)}")
if isinstance(doc, dict):
    for field in ("workflows", "rows", "templates", "steps", "actions", "triggers"):
        val = doc.get(field)
        if isinstance(val, list):
            print(f"  {field}: {len(val)} item(s)")
    if doc.get("fileUrl"):
        print("  fileUrl: present (the step graph is a second hop)")
PY
}

# Recursively walk the folder tree from a parentId, emitting "type<TAB>id<TAB>name"
# for every node. GHL's list is one level deep per call: directories hold children
# reached by listing with parentId=<dirId>. Root is listed with parentId=root.
# Populates the global arrays WF_IDS / WF_NAMES with workflows (type=workflow).
WF_IDS=(); WF_NAMES=()
walk_tree() {
  local parent="$1" depth="${2:-0}"
  local lf; lf="$(mktemp)"
  local code
  code="$(ghl_get "${BASE}/${LOC}/list?parentId=${parent}&limit=500&offset=0" "$lf" "${FULL_HEADERS[@]}")"
  if [[ "$code" != "200" ]]; then echo "  list(parentId=${parent}) -> HTTP $code" >&2; return; fi
  while IFS=$'\t' read -r t id name; do
    [[ -z "$id" ]] && continue
    if [[ "$t" == "directory" || "$t" == "folder" ]]; then
      sleep "$SLEEP_BETWEEN"
      walk_tree "$id" $((depth+1))
    elif [[ "$t" == "workflow" ]]; then
      WF_IDS+=("$id"); WF_NAMES+=("$name")
    fi
  done < <(python3 -c '
import json,sys
doc=json.load(open(sys.argv[1]))
for r in (doc.get("rows") or []):
    print("\t".join([str(r.get("type","")), str(r.get("id","")), str(r.get("name","")).replace("\t"," ")]))' "$lf")
}

case "$MODE" in
probe)
  echo
  echo "=== 1. list, full header set ==="
  tmp_full="$(mktemp)"
  code="$(ghl_get "${BASE}/${LOC}/list?limit=25&offset=0" "$tmp_full" "${FULL_HEADERS[@]}")"
  echo "HTTP $code"
  [[ "$code" == "200" ]] && summarize "$tmp_full"
  if [[ "$code" != "200" ]]; then
    echo "Stopping: cannot list workflows for $LOC (401 = stale token, 403 = token not scoped to this location)." >&2
    head -c 300 "$tmp_full" >&2; echo >&2
    exit 4
  fi

  sleep "$SLEEP_BETWEEN"
  echo
  echo "=== 2. list, token-only headers (are the rest actually required?) ==="
  tmp_min="$(mktemp)"
  code_min="$(ghl_get "${BASE}/${LOC}/list?limit=5&offset=0" "$tmp_min")"
  echo "HTTP $code_min $([[ "$code_min" == "200" ]] && echo '(extra headers are optional)' || echo '(extra headers are required)')"

  echo
  echo "=== 3. list row shape (field names only, no values) ==="
  wf_id="$(python3 -c '
import json,sys
from collections import Counter
doc=json.load(open(sys.argv[1]))
rows=doc.get("rows") or doc.get("workflows") or doc.get("data") or []
if rows:
    print("  row fields: " + ", ".join(sorted(rows[0])), file=sys.stderr)
    types=Counter(r.get("type","?") for r in rows)
    print("  type distribution: " + ", ".join(f"{t}={n}" for t,n in types.items()), file=sys.stderr)
# prefer a non-folder row so the detail call resolves
def is_wf(r): return str(r.get("type","")).lower() not in ("folder","directory","")
first_wf=next((r for r in rows if is_wf(r)), None)
print(first_wf.get("id","") if first_wf else (rows[0].get("id","") if rows else ""))' "$tmp_full")"
  [[ -n "$WF_OVERRIDE" ]] && wf_id="$WF_OVERRIDE" && echo "  (using workflow-id override: $wf_id)"
  if [[ -z "$wf_id" ]]; then
    echo "No workflow id found in the list response; inspect $tmp_full by hand."
    exit 5
  fi

  echo
  echo "=== 4. workflow detail (real endpoint: Bearer auth, ?includeScheduledPauseInfo=true) ==="
  # The list endpoint authenticates with the token-id header; the DETAIL endpoint
  # authenticates with authorization: Bearer. We try the same keychain token as a
  # Bearer first: if it 401s, a separate Bearer token is needed (see AUTH notes).
  tmp_wf="$(mktemp)"
  detail_url="${BASE}/${LOC}/${wf_id}?includeScheduledPauseInfo=true"
  code_wf="$(ghl_get "$detail_url" "$tmp_wf" "${DETAIL_HEADERS[@]}")"
  bytes="$(wc -c <"$tmp_wf" | tr -d ' ')"
  echo "  [$code_wf] ${bytes}b  ${detail_url#https://backend.leadconnectorhq.com/workflow/}"
  if [[ "$code_wf" == "200" && "$bytes" -gt 50 ]]; then
    echo "  detail endpoint OK"
    summarize "$tmp_wf"
    echo
    echo "  --- hop 2: fetching the step graph from fileUrl (signed, no auth) ---"
    file_url="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("fileUrl",""))' "$tmp_wf")"
    if [[ -n "$file_url" ]]; then
      sleep "$SLEEP_BETWEEN"
      tmp_graph="$(mktemp)"
      gcode="$(curl -sS -o "$tmp_graph" -w '%{http_code}' "$file_url")"
      gbytes="$(wc -c <"$tmp_graph" | tr -d ' ')"
      echo "  [$gcode] ${gbytes}b  step graph"
      if [[ "$gcode" == "200" ]]; then
        python3 - "$tmp_graph" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
steps = doc.get("steps") or doc.get("templates") or (doc if isinstance(doc, list) else [])
print(f"  step graph: {len(steps)} step(s)")
from collections import Counter
kinds = Counter((s.get("type") or s.get("actionType") or "?") for s in steps if isinstance(s, dict))
for k, n in kinds.most_common():
    print(f"    {k}: {n}")
PY
        echo
        echo "  --- hop 3: this workflow's triggers (the builder's trigger endpoint) ---"
        sleep "$SLEEP_BETWEEN"
        tmp_trig="$(mktemp)"
        tcode="$(ghl_get "${BASE}/${LOC}/trigger?workflowId=${wf_id}" "$tmp_trig" "${DETAIL_HEADERS[@]}")"
        echo "  [$tcode] triggers: $(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from wf_lib import load_json, trigger_list; d = load_json(sys.argv[2]); print("not JSON" if d is None else str(len(trigger_list(d))) + " trigger(s)")' "$SCRIPT_DIR" "$tmp_trig")"
        echo
        echo "  GRAPH REACHED: full workflow internals are available."
        echo "  detail: $tmp_wf   graph: $tmp_graph"
      else
        echo "  fileUrl fetch failed ($gcode); body: $(head -c 160 "$tmp_graph")" >&2
      fi
    else
      echo "  no fileUrl in detail response; graph may be inline, inspect $tmp_wf" >&2
    fi
  elif [[ "$code_wf" == "401" ]]; then
    echo "  401: the token-id value does not work as a Bearer here." >&2
    echo "  The detail endpoint needs the authorization: Bearer token (separate from token-id)." >&2
    echo "  Store it: security add-generic-password -U -a \"\$USER\" -s GHL_BEARER -w \"\$(pbpaste)\"" >&2
    exit 6
  else
    echo "  unexpected status; body: $(head -c 200 "$tmp_wf")" >&2
    exit 6
  fi
  ;;

tree)
  echo "walking folder tree for $LOC (enumerate only, no detail fetches)..."
  walk_tree root 0
  echo "found ${#WF_IDS[@]} workflow(s) across the folder tree:"
  for i in "${!WF_IDS[@]}"; do
    printf '  %s  %s\n' "${WF_IDS[$i]}" "${WF_NAMES[$i]}"
  done
  ;;

harvest)
  dest="${OUT_DIR}/${LOC}"
  mkdir -p "$dest"
  echo "harvesting $LOC -> $dest"
  # Explicit id list via args 3+ fetches exactly those; otherwise walk the whole tree.
  if [[ -n "${3:-}" ]]; then
    WF_IDS=("${@:3}")
    echo "${#WF_IDS[@]} workflow(s) requested by id"
  else
    echo "walking folder tree..."
    walk_tree root 0
    echo "${#WF_IDS[@]} workflow(s) to fetch"
  fi
  ok=0; failed=0
  for i in "${!WF_IDS[@]}"; do
    id="${WF_IDS[$i]}"
    sleep "$SLEEP_BETWEEN"
    # hop 1: detail (Bearer) -> fileUrl
    detail="${dest}/${id}.detail.json"
    c="$(ghl_get "${BASE}/${LOC}/${id}?includeScheduledPauseInfo=true" "$detail" "${DETAIL_HEADERS[@]}")"
    if [[ "$c" != "200" ]]; then failed=$((failed+1)); echo "  $id detail -> HTTP $c" >&2; continue; fi
    # hop 2: step graph from signed fileUrl (no auth)
    furl="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("fileUrl",""))' "$detail")"
    if [[ -n "$furl" ]]; then
      sleep "$SLEEP_BETWEEN"
      gc="$(curl -sS -o "${dest}/${id}.graph.json" -w '%{http_code}' "$furl")"
      [[ "$gc" != "200" ]] && echo "  $id graph -> HTTP $gc" >&2
    fi
    ok=$((ok+1))
  done
  echo "done: $ok workflow(s) saved to $dest, $failed failed"
  ;;

inspect)
  # Read back a saved workflow graph and print its action structure.
  # Workflow automations are logic, not contact PII, so it is safe to display.
  wf="${WF_OVERRIDE:?usage: inspect <locationId> <workflowId>}"
  gfile="${OUT_DIR}/${LOC}/${wf}.graph.json"
  dfile="${OUT_DIR}/${LOC}/${wf}.detail.json"
  [[ -f "$gfile" ]] || { echo "no saved graph at $gfile (harvest it first)" >&2; exit 2; }
  python3 - "$gfile" "$dfile" <<'PY'
import json, sys
graph = json.load(open(sys.argv[1]))
try:
    detail = json.load(open(sys.argv[2]))
    print(f"workflow: {detail.get('name','?')}  (status={detail.get('status','?')}, dataVersion={detail.get('dataVersion','?')})")
except Exception:
    pass
steps = graph.get("steps") or graph.get("templates") or (graph if isinstance(graph, list) else [])
print(f"{len(steps)} step(s):\n")
STAGE_HINT = ("stage", "pipeline", "opportunity", "status")
for i, s in enumerate(steps):
    if not isinstance(s, dict):
        continue
    typ = s.get("type") or s.get("actionType") or "?"
    name = s.get("name") or ""
    print(f"[{i}] {typ}  {name}")
    attrs = s.get("attributes") or s.get("config") or {}
    # branch conditions (if_else etc.)
    conds = attrs.get("conditions") or s.get("conditions")
    if conds:
        blob = json.dumps(conds)
        print(f"      conditions: {blob[:300]}")
    # anything that looks like it sets a pipeline stage
    for k, v in attrs.items():
        if any(h in k.lower() for h in STAGE_HINT):
            print(f"      {k}: {json.dumps(v)[:200]}")
PY
  ;;

inspect-full)
  # Like inspect, but prints COMPLETE if_else conditions and the full attributes of
  # every opportunity-writing step, for diffing one location's copy against the
  # template it was cloned from.
  wf="${WF_OVERRIDE:?usage: inspect-full <locationId> <workflowId>}"
  gfile="${OUT_DIR}/${LOC}/${wf}.graph.json"
  [[ -f "$gfile" ]] || { echo "no saved graph at $gfile (harvest it first)" >&2; exit 2; }
  python3 - "$gfile" <<'PY'
import json, sys
graph = json.load(open(sys.argv[1]))
steps = graph.get("steps") or graph.get("templates") or (graph if isinstance(graph, list) else [])
for i, s in enumerate(steps):
    if not isinstance(s, dict):
        continue
    typ = s.get("type") or s.get("actionType") or "?"
    attrs = s.get("attributes") or s.get("config") or {}
    if typ == "if_else":
        branches = attrs.get("branches") or []
        if not branches:
            continue  # leaf branch-yes node; conditions live on its parent
        print(f"[{i}] if_else  {s.get('name','')}  ({len(branches)} branch(es))")
        for b in branches:
            tests = []
            for seg in b.get("segments") or []:
                for c in seg.get("conditions") or []:
                    tests.append(f"{c.get('conditionType')}:{c.get('conditionSubType')} {c.get('conditionOperator')} {json.dumps(c.get('conditionValue'))}")
            print(f"     - {b.get('name','?')!r}: " + (" AND ".join(tests) if tests else "(no conditions)"))
    elif "opportunity" in typ or typ.startswith("update_"):
        print(f"[{i}] {typ}  {s.get('name','')}")
        print("     " + json.dumps(attrs, sort_keys=True))
PY
  ;;

inspect-raw)
  # Dump the complete JSON of ONE step (by index or node id) so we can see where a
  # step type keeps its config, e.g. where if_else stores its branch conditions.
  # Secret-bearing keys (webhook headers, tokens) are blanked before printing.
  #   inspect-raw <locationId> <workflowId> <stepIndex|nodeId>
  wf="${WF_OVERRIDE:?usage: inspect-raw <locationId> <workflowId> <stepIndex|nodeId>}"
  idx="${4:?stepIndex or nodeId required}"
  gfile="${OUT_DIR}/${LOC}/${wf}.graph.json"
  [[ -f "$gfile" ]] || { echo "no saved graph at $gfile (harvest it first)" >&2; exit 2; }
  python3 - "$SCRIPT_DIR" "$gfile" "$idx" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
from wf_lib import *  # noqa
graph = json.load(open(sys.argv[2])); key = sys.argv[3]
steps = steps_of(graph)
# numeric -> index; otherwise treat as a step id (GHL node ids survive cloning, so
# the same id can be dumped across locations for a like-for-like diff)
if key.isdigit():
    node = steps[int(key)]
else:
    node = next((s for s in steps if s.get("id") == key), None)
    if node is None:
        print(f"no step with id {key}"); raise SystemExit(1)
    print(f"(step index {steps.index(node)})")
print(json.dumps(redact_deep(node), indent=1, sort_keys=True, ensure_ascii=False)[:6000])
PY
  ;;

summary)
  # Scan every harvested graph and report which workflows move pipeline stages
  # (create_opportunity steps) and their target stage ids: the stage-move map.
  base="${OUT_DIR}/${LOC}"
  [[ -d "$base" ]] || { echo "no harvest dir at $base" >&2; exit 2; }
  python3 - "$base" <<'PY'
import json, glob, os, sys
from collections import Counter
base = sys.argv[1]
stage_targets = Counter()
movers = []
for gf in sorted(glob.glob(os.path.join(base, "*.graph.json"))):
    wid = os.path.basename(gf).split(".")[0]
    df = os.path.join(base, f"{wid}.detail.json")
    name = "?"
    try:
        name = json.load(open(df)).get("name", "?")
    except Exception:
        pass
    try:
        graph = json.load(open(gf))
    except Exception:
        continue
    steps = graph.get("steps") or graph.get("templates") or (graph if isinstance(graph, list) else [])
    moves = []
    for s in steps:
        if not isinstance(s, dict):
            continue
        if (s.get("type") or s.get("actionType")) == "create_opportunity":
            attrs = s.get("attributes") or s.get("config") or {}
            sid = attrs.get("pipeline_stage_id", "?")
            stage_targets[sid] += 1
            moves.append((s.get("name", ""), sid))
    if moves:
        movers.append((name, moves))
print(f"{len(movers)} of the harvested workflows move a pipeline stage.\n")
for name, moves in movers:
    print(f"* {name}  ({len(moves)} stage-move step(s))")
    for label, sid in moves:
        print(f"    -> {sid}  {label}")
print("\nDistinct target stage ids (count = times a create_opportunity targets it):")
for sid, n in stage_targets.most_common():
    print(f"  {n:>3}  {sid}")
PY
  ;;

schema)
  # Discover GHL's real step-type vocabulary and where each type stores its
  # config: per type, how many steps / workflows use it and the union of
  # attribute key PATHS with redacted sample values.
  #   schema <locationId> [stepType]
  base="${OUT_DIR}/${LOC}"
  [[ -d "$base" ]] || { echo "no harvest dir at $base" >&2; exit 2; }
  python3 - "$SCRIPT_DIR" "$base" "${WF_OVERRIDE:-}" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from wf_lib import *  # noqa
from collections import Counter, defaultdict

base, only = sys.argv[2], sys.argv[3]
samples_max = 5 if only else 2

step_n = Counter()
wf_n = Counter()
paths = defaultdict(lambda: defaultdict(list))   # type -> path -> samples

for wid, detail, steps in iter_workflows(base):
    seen = set()
    for s in steps:
        t = step_type(s)
        if only and t != only:
            continue
        step_n[t] += 1
        seen.add(t)
        for path, val in deep_iter(attrs_of(s)):
            key = collapse_path(path)
            bucket = paths[t][key]
            r = redact(val)
            if r not in bucket and len(bucket) < samples_max:
                bucket.append(r)
    for t in seen:
        wf_n[t] += 1

print(f"step types across {len(list(workflow_ids(base)))} workflow(s)"
      + (f" (filtered to type '{only}')" if only else "") + "\n")
for t, n in step_n.most_common():
    print(f"=== {t}   steps={n}  workflows={wf_n[t]}")
    for key in sorted(paths[t]):
        vals = ", ".join(json.dumps(v) for v in paths[t][key])
        print(f"    {key}   ::  {cut(vals, 200)}")
    print()
print("type list (type=steps/workflows):")
print("  " + "  ".join(f"{t}={step_n[t]}/{wf_n[t]}" for t, _ in step_n.most_common()))
PY
  ;;

inventory)
  # Full inventory of every harvested workflow, one row each, with a
  # relevance CLASS derived from an ANCHOR workflow: the one workflow you know
  # is part of the process you are auditing. Its custom-field ids, tags, stage
  # ids and trigger form ids become the seed sets that every other workflow is
  # scored against.
  #   inventory <locationId> --anchor "<workflow name>" [--md]
  #                          [--core-names "A,B"] [--process-regex RE]
  #                          [--expect-count N] [--require-core "A,B,C"]
  #                          [--only CLASS,CLASS] [--grep SUBSTR] [--footer-only]
  #   --anchor is required and matches on a normalized substring of the name.
  #   Classification always runs over ALL rows; --only/--grep/--footer-only just
  #   narrow what gets printed (the footer counts stay whole-location).
  base="${OUT_DIR}/${LOC}"
  [[ -d "$base" ]] || { echo "no harvest dir at $base" >&2; exit 2; }
  python3 - "$SCRIPT_DIR" "$base" "${@:3}" <<'PY'
import sys, re
sys.path.insert(0, sys.argv[1])
from wf_lib import *  # noqa

base = sys.argv[2]
args = sys.argv[3:]
as_md = "--md" in args
footer_only = "--footer-only" in args
expect = None
require = []
only = None
grep = None
anchor = None
core_names = []
process_regex = None
i = 0
while i < len(args):
    if args[i] == "--anchor" and i + 1 < len(args):
        anchor = args[i + 1]; i += 2; continue
    if args[i] == "--core-names" and i + 1 < len(args):
        core_names = [x.strip() for x in args[i + 1].split(",") if x.strip()]; i += 2; continue
    if args[i] == "--process-regex" and i + 1 < len(args):
        process_regex = args[i + 1]; i += 2; continue
    if args[i] == "--expect-count" and i + 1 < len(args):
        expect = int(args[i + 1]); i += 2; continue
    if args[i] == "--require-core" and i + 1 < len(args):
        require = [x.strip() for x in args[i + 1].split(",") if x.strip()]; i += 2; continue
    if args[i] == "--only" and i + 1 < len(args):
        only = {x.strip().upper() for x in args[i + 1].split(",") if x.strip()}; i += 2; continue
    if args[i] == "--grep" and i + 1 < len(args):
        grep = args[i + 1].lower(); i += 2; continue
    i += 1

if not anchor:
    print('ERROR: --anchor "<workflow name>" is required.\n'
          "  The anchor is the one workflow you know belongs to the process you\n"
          "  are auditing; its fields, tags, stages and form ids seed the\n"
          "  classifier. Names match on a normalized substring, so a fragment\n"
          "  is enough. List the names you harvested with:  tree <locationId>",
          file=sys.stderr)
    raise SystemExit(64)

if process_regex:
    try:
        re.compile(process_regex)
    except re.error as exc:
        print(f"ERROR: --process-regex is not a valid regex ({exc})", file=sys.stderr)
        raise SystemExit(64)


def match_any(name, pat):
    return bool(re.search(pat, (name or "").lower()) or re.search(pat, norm_name(name)))


# ---- gather features once per workflow -----------------------------------
rows = []
broken = []
for wid, detail, steps in iter_workflows(base):
    if detail is None:
        broken.append((wid, "detail.json missing/unparseable"))
    if not graph_ok(base, wid):
        broken.append((wid, "graph.json missing/unparseable"))
    d = detail or {}
    conds = field_conditions_of(steps)
    trig = load_triggers(base, wid)
    added, removed = tags_of(steps)
    rows.append(dict(
        wid=wid,
        name=d.get("name") or "(unknown)",
        status=d.get("status") or "?",
        dv=d.get("dataVersion", "?"),
        trig=trigger_summary(trig) if trig is not None else "—",
        forms=trigger_form_ids(trig) if trig is not None else set(),
        nsteps=len(steps),
        types=type_counts(steps),
        cond_fields=set(conds),
        cond_values=conds,
        write_fields=field_writes_of(steps) | field_reads_of(steps),
        added=added, removed=removed,
        hosts=hosts_of(steps),
        stages=stages_of(steps),
        has_wait=has_type(steps, WAIT_TYPES),
        has_send=has_type(steps, SEND_TYPES),
        has_opp=has_type(steps, {"create_opportunity"}),
    ))

# ---- pass 1: seeds from the anchor workflow ------------------------------
anchor_key = norm_name(anchor)
seed = next((r for r in rows if anchor_key and anchor_key in norm_name(r["name"])), None)
if seed is None:
    print(f"ERROR: no harvested workflow name contains --anchor {anchor!r}.\n"
          f"  {len(rows)} workflow(s) were read from {base}.\n"
          "  Matching is on a normalized name (lowercase, non-alphanumerics\n"
          "  stripped), so check spelling or pass a shorter fragment.",
          file=sys.stderr)
    raise SystemExit(65)

SEED_FIELDS = set(seed["cond_fields"]) | set(seed["write_fields"])
SEED_TAGS = set(seed["added"]) | set(seed["removed"])
SEED_STAGES = set(seed["stages"])
SEED_FORM = set(seed["forms"])

# The anchor is CORE by definition; --core-names names any others you already
# know belong to the process.
CORE_NAMES = {norm_name(x) for x in core_names} | {norm_name(seed["name"])}

# ---- pass 2: ordered rules, first match wins -----------------------------
for r in rows:
    f_hits = (set(r["cond_fields"]) | set(r["write_fields"])) & SEED_FIELDS
    t_hits = (set(r["added"]) | set(r["removed"])) & SEED_TAGS
    s_hits = set(r["stages"]) & SEED_STAGES
    o_hits = set(r["forms"]) & SEED_FORM
    ev = []
    if f_hits:
        ev.append("field:" + joinset(f_hits, 3))
    if t_hits:
        ev.append("tag:" + joinset(t_hits, 3))
    if s_hits:
        ev.append("stage:" + joinset(s_hits, 2))
    if o_hits:
        ev.append("form:" + joinset(o_hits, 1))
    touches = bool(f_hits or t_hits or s_hits or o_hits)
    writes_seed = bool(set(r["write_fields"]) & SEED_FIELDS)
    nn = norm_name(r["name"])

    if nn in CORE_NAMES:
        r["cls"], r["ev"] = "CORE", "named-core; " + ("; ".join(ev) or "no seed overlap")
    elif process_regex and match_any(r["name"], process_regex) and touches:
        r["cls"], r["ev"] = "CORE", "name+seed: " + "; ".join(ev)
    elif writes_seed:
        r["cls"], r["ev"] = "CORE", "writes seed field: " + joinset(
            set(r["write_fields"]) & SEED_FIELDS, 3)
    elif match_any(r["name"], r"remind|nudge"):
        r["cls"], r["ev"] = "REMINDER", "name; " + ("; ".join(ev) or "no seed overlap")
    elif r["has_wait"] and r["has_send"] and (t_hits or f_hits):
        r["cls"], r["ev"] = "REMINDER", "wait+send+seed: " + "; ".join(ev)
    elif match_any(r["name"],
                   r"follow ?-?up|resched|no.?show|rebook|reactivat"):
        r["cls"], r["ev"] = "FOLLOWUP", "name; " + ("; ".join(ev) or "no seed overlap")
    elif touches:
        r["cls"], r["ev"] = "ADJACENT", "; ".join(ev)
    else:
        r["cls"], r["ev"] = "UNRELATED", ""

ORDER = {"CORE": 0, "REMINDER": 1, "FOLLOWUP": 2, "ADJACENT": 3,
         "UNRELATED": 4}
rows.sort(key=lambda r: (ORDER.get(r["cls"], 9), r["name"].lower()))

HEAD = ["id", "name", "status", "dv", "trigger", "steps", "top types", "fields",
        "tags +/-", "hosts", "stages", "class", "evidence"]


def cells(r, md):
    fields = []
    if r["cond_fields"]:
        fields.append("cond:" + joinset(r["cond_fields"], 8 if md else 3))
    if r["write_fields"]:
        fields.append("write:" + joinset(r["write_fields"], 8 if md else 3))
    tags = "+{} / -{}".format(joinset(r["added"], 6 if md else 2),
                              joinset(r["removed"], 6 if md else 2))
    top = ",".join(f"{t}:{n}" for t, n in r["types"].most_common(4))
    return [r["wid"] if md else r["wid"][:8],
            r["name"], r["status"], r["dv"], r["trig"], r["nsteps"], top,
            " ".join(fields) or "—", tags,
            joinset(r["hosts"], 6 if md else 2),
            joinset(r["stages"], 6 if md else 1),
            r["cls"],
            r["ev"] if md else cut(r["ev"], 80)]


shown = [r for r in rows
         if (only is None or r["cls"] in only)
         and (grep is None or grep in r["name"].lower())]
if footer_only:
    print(f"(table suppressed by --footer-only; {len(shown)} row(s) would print)")
elif as_md:
    print(md_table(HEAD, [cells(r, True) for r in shown]))
else:
    print(fixed_table(HEAD, [cells(r, False) for r in shown],
                      [8, 46, 9, 3, 10, 5, 34, 30, 30, 18, 12, 16, 80]))

# ---- footer --------------------------------------------------------------
from collections import Counter
dist = Counter(r["cls"] for r in rows)
print(f"\n{len(rows)} workflow(s).")
print("class distribution: " + ", ".join(f"{k}={dist[k]}" for k in
      sorted(dist, key=lambda k: ORDER.get(k, 9))))
n_opp = sum(1 for r in rows if r["has_opp"])
print(f"workflows containing create_opportunity: {n_opp}")
print(f"triggers on disk: {sum(1 for r in rows if r['trig'] != '—')}/{len(rows)}"
      "  (run harvest-triggers to populate)")
print(f"\nanchor workflow: {seed['name']} ({seed['wid']})")
print("  SEED_FIELDS: " + joinset(SEED_FIELDS, 30, ", "))
print("  SEED_TAGS:   " + joinset(SEED_TAGS, 40, ", "))
print("  SEED_STAGES: " + joinset(SEED_STAGES, 20, ", "))
print("  SEED_FORM:   " + joinset(SEED_FORM, 5, ", "))
if broken:
    print("\nunreadable snapshots:")
    for wid, why in broken:
        print(f"  {wid}  {why}")

rc = 0
if expect is not None and len(rows) != expect:
    print(f"\nFAIL --expect-count: {len(rows)} != {expect}", file=sys.stderr)
    rc = 2
if require:
    have = {norm_name(r["name"]): r for r in rows}
    for want in require:
        r = have.get(norm_name(want))
        if r is None:
            print(f"FAIL --require-core: no workflow named {want!r}", file=sys.stderr)
            rc = rc or 3
        elif r["cls"] != "CORE":
            print(f"FAIL --require-core: {want!r} classed {r['cls']}", file=sys.stderr)
            rc = rc or 3
raise SystemExit(rc)
PY
  ;;

fields)
  # Every custom-field id the location's workflows touch, plus the merge tokens
  # they interpolate. The field ids are what get remapped on clone, so this is
  # the map you diff another sub-account against.
  #   fields <locationId> [--md] [--min-wf N] [--section fields|tokens|both]
  base="${OUT_DIR}/${LOC}"
  [[ -d "$base" ]] || { echo "no harvest dir at $base" >&2; exit 2; }
  python3 - "$SCRIPT_DIR" "$base" "${@:3}" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from wf_lib import *  # noqa
from collections import Counter, defaultdict

base = sys.argv[2]
args = sys.argv[3:]
as_md = "--md" in args
min_wf = 1
section = "both"
i = 0
while i < len(args):
    if args[i] == "--min-wf" and i + 1 < len(args):
        min_wf = int(args[i + 1]); i += 2; continue
    if args[i] == "--section" and i + 1 < len(args):
        section = args[i + 1]; i += 2; continue
    i += 1

roles = defaultdict(set)          # field id -> {"cond","write","token"}
wfs = defaultdict(set)            # field id -> workflow names
values = defaultdict(set)         # field id -> tested condition values
titles = {}                       # field id -> human title
tok_count = Counter()
tok_wfs = defaultdict(set)

for wid, detail, steps in iter_workflows(base):
    name = (detail or {}).get("name") or wid
    for fid, vals in field_conditions_of(steps).items():
        roles[fid].add("cond"); wfs[fid].add(name); values[fid] |= vals
    for fid in field_writes_of(steps):
        roles[fid].add("write"); wfs[fid].add(name)
    for fid in field_reads_of(steps):
        roles[fid].add("read"); wfs[fid].add(name)
    for fid, t in field_titles_of(steps).items():
        titles.setdefault(fid, t)
    for tok in tokens_of(steps):
        tok_count[tok] += 1
        tok_wfs[tok].add(name)


def role_label(s):
    if s == {"cond", "write"} or s >= {"cond", "write"}:
        return "both"
    return "/".join(sorted(s))


ordered = sorted(roles, key=lambda f: (-len(wfs[f]), f))
rows = [[fid, titles.get(fid, "—"), role_label(roles[fid]), len(wfs[fid]),
         joinset(wfs[fid], 6, "; "), joinset(values[fid], 8, " ")]
        for fid in ordered if len(wfs[fid]) >= min_wf]

HEAD = ["field id", "title", "role", "#wf", "workflows", "values tested"]
if section in ("both", "fields"):
    print(f"== custom fields ({len(roles)} distinct id(s); showing "
          f"{len(rows)} with >= {min_wf} workflow(s)) ==")
    if as_md:
        print(md_table(HEAD, rows))
    else:
        print(fixed_table(HEAD, rows, [22, 26, 6, 4, 70, 90]))
    shared = sum(1 for f in roles if len(wfs[f]) > 1)
    print(f"\n{shared} field id(s) are referenced by more than one workflow.")

if section in ("both", "tokens"):
    THEAD = ["merge token", "count", "workflows"]
    trows = [[t, n, joinset(tok_wfs[t], 4, "; ")] for t, n in tok_count.most_common()]
    print(f"\n== merge tokens ({len(trows)} distinct) ==")
    if as_md:
        print(md_table(THEAD, trows))
    else:
        print(fixed_table(THEAD, trows, [56, 5, 80]))
PY
  ;;

flow)
  # Linearized narrative of ONE workflow: every step with its type-specific key
  # params, indented by parentKey depth, with each if_else branch's conditions.
  #   flow <locationId> <workflowId>
  wf="${WF_OVERRIDE:?usage: flow <locationId> <workflowId>}"
  base="${OUT_DIR}/${LOC}"
  [[ -f "${base}/${wf}.graph.json" ]] || { echo "no saved graph for $wf in $base" >&2; exit 2; }
  python3 - "$SCRIPT_DIR" "$base" "$wf" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from wf_lib import *  # noqa

base, wf = sys.argv[2], sys.argv[3]
detail, steps = load_workflow(base, wf)
d = detail or {}
trig = load_triggers(base, wf)
print(f"{d.get('name','?')}  [{wf}]")
print(f"  status={d.get('status','?')}  dataVersion={d.get('dataVersion','?')}  "
      f"steps={len(steps)}")
print(f"  trigger: {trigger_summary(trig, 4) if trig is not None else '— (run harvest-triggers)'}")
print()

depths = depth_map(steps)
for i, s in enumerate(steps):
    ind = "  " * min(depths.get(s.get("id"), 0), 8)
    typ = step_type(s)
    print(f"{ind}[{i}] {typ} | {redact(s.get('name') or '')}"
          + (f" | {key_params(s)}" if key_params(s) else ""))
    if typ == "if_else":
        by_branch = {}
        for c in conditions_of(s):
            by_branch.setdefault(c["branch"], []).append(c)
        for bname, cs in by_branch.items():
            print(f"{ind}   └─ branch {bname!r}: " + " AND ".join(fmt_condition(c) for c in cs))
        a = attrs_of(s)
        empties = [b.get("name") for b in (a.get("branches") or [])
                   if isinstance(b, dict) and b.get("name") not in by_branch]
        if empties:
            print(f"{ind}   └─ branches with no conditions: " + ", ".join(map(str, empties)))
        if a.get("noneBranchName"):
            print(f"{ind}   └─ else branch: {a['noneBranchName']!r}")
PY
  ;;

triggers)
  # Print harvested triggers for one or all workflows.
  #   triggers <locationId> [<workflowId>]
  base="${OUT_DIR}/${LOC}"
  [[ -d "$base" ]] || { echo "no harvest dir at $base" >&2; exit 2; }
  python3 - "$SCRIPT_DIR" "$base" "${WF_OVERRIDE:-}" <<'PY'
import sys, os
sys.path.insert(0, sys.argv[1])
from wf_lib import *  # noqa

base, only = sys.argv[2], sys.argv[3]
found = 0
for wid, detail, _steps in iter_workflows(base):
    if only and wid != only:
        continue
    doc = load_triggers(base, wid)
    if doc is None:
        continue
    found += 1
    print(f"{(detail or {}).get('name','?')}  [{wid}]")
    rows = trigger_rows(doc)
    if not rows:
        print("  (triggers file present but no recognizable trigger objects)")
    for ttype, tname, filters in rows:
        print(f"  - {ttype}" + (f"  {tname!r}" if tname else ""))
        for key, val in filters[:20]:
            print(f"      {key} = {json.dumps(val)}")
        if len(filters) > 20:
            print(f"      (+{len(filters)-20} more keys)")
    print()
if not found:
    print("no <workflowId>.triggers.json on disk for this location.")
    print("run:  ./harvest_workflows.sh harvest-triggers " + os.path.basename(base))
PY
  ;;

harvest-triggers)
  # One GET per workflow to the endpoint the workflow builder itself reads
  # triggers from, sent with the detail headers:
  #   GET /workflow/{locationId}/trigger?workflowId={workflowId}
  # The body is a JSON list of trigger objects; an empty list means the workflow
  # has no trigger of its own (a child). A 503 is retried once, then recorded.
  #   harvest-triggers <locationId> [<workflowId> ...]
  dest="${OUT_DIR}/${LOC}"
  [[ -d "$dest" ]] || { echo "no harvest dir at $dest (harvest first)" >&2; exit 2; }
  IDS=()
  if [[ -n "${3:-}" ]]; then
    IDS=("${@:3}")
  else
    # bash 3.2 on macOS has no mapfile
    while IFS= read -r line; do
      [[ -n "$line" ]] && IDS+=("$line")
    done < <(python3 - "$SCRIPT_DIR" "$dest" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from wf_lib import *  # noqa
for wid in workflow_ids(sys.argv[2]):
    print(wid)
PY
)
  fi
  echo "fetching triggers for ${#IDS[@]} workflow(s) -> $dest"
  saved=0; children=0; failed=0
  for id in "${IDS[@]}"; do
    sleep "$SLEEP_BETWEEN"
    out="${dest}/${id}.triggers.json"
    tc="$(ghl_get "${BASE}/${LOC}/trigger?workflowId=${id}" "$out" "${DETAIL_HEADERS[@]}")"
    if [[ "$tc" == "503" ]]; then
      sleep 5
      tc="$(ghl_get "${BASE}/${LOC}/trigger?workflowId=${id}" "$out" "${DETAIL_HEADERS[@]}")"
    fi
    if [[ "$tc" == "401" ]]; then
      rm -f "$out"
      echo "401: token expired, refresh GHL_TOKEN_ID (see AUTH)" >&2
      exit 4
    fi
    if [[ "$tc" != "200" ]]; then
      failed=$((failed+1))
      echo "  $id triggers -> HTTP $tc; body: $(head -c 160 "$out" 2>/dev/null | tr '\n' ' ')" >&2
      rm -f "$out"
      continue
    fi
    n="$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from wf_lib import load_json, trigger_list; d = load_json(sys.argv[2]); print(-1 if d is None else len(trigger_list(d)))' "$SCRIPT_DIR" "$out")"
    if [[ "$n" == "-1" ]]; then
      failed=$((failed+1)); echo "  $id triggers -> not JSON" >&2; rm -f "$out"; continue
    fi
    saved=$((saved+1))
    if [[ "$n" == "0" ]]; then children=$((children+1)); fi
  done
  echo "done: $saved saved ($children with no trigger of their own: children), $failed failed"
  ;;

*)
  echo "Unknown mode '$MODE' (expected: probe | tree | harvest | inspect |" \
       "inspect-full | inspect-raw | summary | schema | inventory | fields |" \
       "flow | triggers | harvest-triggers)" >&2
  exit 64
  ;;
esac
