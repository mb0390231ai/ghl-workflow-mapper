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
