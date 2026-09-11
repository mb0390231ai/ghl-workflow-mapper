"""Shared helpers for the GHL workflow harvester's analysis modes.

Imported by the inline python3 heredocs inside harvest_workflows.sh. The bash
side passes the script directory as argv[1]:

    python3 - "$(cd "$(dirname "$0")" && pwd)" "<args>" <<'PY'
    import sys; sys.path.insert(0, sys.argv[1]); from wf_lib import *
    PY

READ-ONLY: nothing here writes to GHL. It only reads the harvested snapshots
under .ghl-workflow-snapshots/<locationId>/.

Redaction policy (a transcript is not a safe place for account data):
automation logic (step names, tag names, custom-field ids, condition values,
stage ids) is safe to print; free text is truncated to ~60 chars and URLs are
reduced to their hostname.
"""

import glob
import json
import os
import re
from urllib.parse import urlparse

MAX_STR = 60

ID_RE = re.compile(r"^[A-Za-z0-9]{20,24}$")
UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)
TOKEN_RE = re.compile(r"\{\{\s*(custom_values|contact|opportunity)\.[^}]+\}\}")
URLISH_RE = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.\-]*://")


# --------------------------------------------------------------------------
# loading
# --------------------------------------------------------------------------

def steps_of(graph):
    """The step array of a graph doc, whatever shape GHL used."""
    if isinstance(graph, list):
        return [s for s in graph if isinstance(s, dict)]
    if not isinstance(graph, dict):
        return []
    steps = graph.get("steps")
    if not isinstance(steps, list):
        steps = graph.get("templates")
    if not isinstance(steps, list):
        steps = []
    return [s for s in steps if isinstance(s, dict)]


def load_json(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except Exception:
        return None


def load_workflow(base, wid):
    """(detail_dict_or_None, steps) for one workflow id under `base`."""
    detail = load_json(os.path.join(base, f"{wid}.detail.json"))
    graph = load_json(os.path.join(base, f"{wid}.graph.json"))
    return detail, steps_of(graph) if graph is not None else []


def workflow_ids(base):
    ids = []
    for gf in glob.glob(os.path.join(base, "*.graph.json")):
        ids.append(os.path.basename(gf)[: -len(".graph.json")])
    return sorted(ids)


def iter_workflows(base):
    """Yield (wid, detail_or_None, steps) sorted by workflow name."""
    rows = []
    for wid in workflow_ids(base):
        detail, steps = load_workflow(base, wid)
        name = (detail or {}).get("name") or ""
        rows.append((name.lower(), wid, detail, steps))
    rows.sort(key=lambda r: (r[0], r[1]))
    for _, wid, detail, steps in rows:
        yield wid, detail, steps


def graph_ok(base, wid):
    """False when the graph file is missing or unparseable."""
    p = os.path.join(base, f"{wid}.graph.json")
    return os.path.exists(p) and load_json(p) is not None


def load_triggers(base, wid):
    return load_json(os.path.join(base, f"{wid}.triggers.json"))


# --------------------------------------------------------------------------
# traversal / redaction
# --------------------------------------------------------------------------

def deep_iter(obj, path=()):
    """Yield (path_tuple, leaf_value) for every scalar leaf in obj.

    List indices appear in the path as the integer index; use collapse_path()
    to render them as '[]'.
    """
    if isinstance(obj, dict):
        for k, v in obj.items():
            yield from deep_iter(v, path + (str(k),))
    elif isinstance(obj, (list, tuple)):
        for i, v in enumerate(obj):
            yield from deep_iter(v, path + (i,))
    else:
        yield path, obj


def collapse_path(path):
    """('branches', 0, 'name') -> 'branches[].name'"""
    out = []
    for seg in path:
        if isinstance(seg, int):
            if out:
                out[-1] = out[-1] + "[]"
            else:
                out.append("[]")
        else:
            out.append(seg)
    return ".".join(out)


def redact(value):
    """Truncate long strings; reduce URLs to a hostname. Non-strings pass."""
    if not isinstance(value, str):
        return value
    s = value.strip()
    if URLISH_RE.match(s):
        try:
            host = urlparse(s).hostname
        except Exception:
            host = None
        if host:
            return f"<url {host}>"
    s = " ".join(value.split())
    if len(s) > MAX_STR:
        return s[:MAX_STR] + "…"
    return s


def redact_deep(obj, path=()):
    """Copy of obj with secret-bearing keys blanked and every string redacted.

    Used by inspect-raw so a full step dump never carries a webhook header
    value, an access token or a full URL into a transcript.
    """
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            p = path + (str(k),)
            out[k] = "<redacted>" if is_secret_path(collapse_path(p)) else redact_deep(v, p)
        return out
    if isinstance(obj, list):
        return [redact_deep(v, path + (0,)) for v in obj]
    return redact(obj)


def norm_name(s):
    return re.sub(r"[^a-z0-9]+", "", (s or "").lower())


def step_type(step):
    return step.get("type") or step.get("actionType") or "?"


def attrs_of(step):
    a = step.get("attributes")
    if not isinstance(a, dict):
        a = step.get("config")
    return a if isinstance(a, dict) else {}


# --------------------------------------------------------------------------
# conditions
# --------------------------------------------------------------------------

def conditions_of(step):
    """Flat list of every branch condition on a step.

    Grounded in `schema`: if_else keeps them at
    attributes.branches[].segments[].conditions[]; a `wait` step with a
    condition keeps the same shape one level deeper, under
    attributes.condition.branches[]. So we recurse for any object carrying a
    `segments` list (a branch) and collect every `conditions` list found.
    """
    out = []

    def walk(obj, bname):
        if isinstance(obj, dict):
            if isinstance(obj.get("segments"), list):
                bname = obj.get("name") or obj.get("id") or bname
            conds = obj.get("conditions")
            if isinstance(conds, list):
                for c in conds:
                    if isinstance(c, dict) and (
                        "conditionType" in c or "conditionOperator" in c
                    ):
                        out.append(_cond_row(bname, c))
            for k, v in obj.items():
                if k == "conditions":
                    continue
                walk(v, bname)
        elif isinstance(obj, list):
            for v in obj:
                walk(v, bname)

    walk(attrs_of(step), "(step)")
    return out


def _cond_row(branch, c):
    return {
        "branch": branch,
        "conditionType": c.get("conditionType"),
        "conditionSubType": c.get("conditionSubType"),
        "conditionOperator": c.get("conditionOperator"),
        "conditionValue": c.get("conditionValue"),
    }


def jd(v):
    return json.dumps(v, ensure_ascii=False)


def fmt_condition(c):
    return "{}:{} {} {}".format(
        c.get("conditionType"),
        c.get("conditionSubType"),
        c.get("conditionOperator"),
        jd(redact(c.get("conditionValue"))),
    )


# --------------------------------------------------------------------------
# feature extraction
#
# Every type name and attribute path below was read off `schema` output from a
# real account rather than guessed; re-verify with `schema` on yours. The extra
# names in each set are forward-compat only.
# --------------------------------------------------------------------------

TAG_ADD_TYPES = {"add_contact_tag"}
TAG_REMOVE_TYPES = {"remove_contact_tag"}
TAG_TYPES = TAG_ADD_TYPES | TAG_REMOVE_TYPES
# a "send" is anything that emits a message to a human
SEND_TYPES = {"sms", "email", "internal_notification", "sendblue_outbound_message",
              "slack_message", "ivr_connect_call", "manual-call", "manual_sms",
              "whatsapp", "voicemail", "gmb_messaging", "review_request"}
WAIT_TYPES = {"wait", "wait_for_reply"}
TASK_TYPES = {"create_task", "add_task", "task"}
WEBHOOK_TYPES = {"webhook", "custom_webhook", "inbound_webhook"}
FIELD_WRITE_TYPES = {"update_contact_field", "math_operation"}
OPP_TYPES = {"create_opportunity", "remove_opportunity"}
STAGE_TYPES = {"create_opportunity"}
# attributes.headers[].value on a webhook step holds an API key: never print it
SECRET_PATHS = ("headers[].value", "access_token", "token", "apikey", "api_key",
                "secret", "password")


def has_type(steps, types):
    types = {t.lower() for t in types}
    return any(step_type(s).lower() in types for s in steps)


def steps_of_type(steps, types):
    types = {t.lower() for t in types}
    return [s for s in steps if step_type(s).lower() in types]


def _string_leaves(obj):
    for path, v in deep_iter(obj):
        if isinstance(v, str) and v:
            yield collapse_path(path), v


def is_secret_path(key):
    kl = key.lower()
    return any(p in kl for p in SECRET_PATHS)


def _tag_list(step):
    tags = attrs_of(step).get("tags")
    if isinstance(tags, list):
        return {t for t in tags if isinstance(t, str) and t}
    if isinstance(tags, str) and tags:
        return {tags}
    return set()


def tags_of(steps):
    """(tags_added, tags_removed), from add/remove_contact_tag attributes.tags[]."""
    added, removed = set(), set()
    for s in steps:
        t = step_type(s).lower()
        if t in TAG_ADD_TYPES:
            added |= _tag_list(s)
        elif t in TAG_REMOVE_TYPES:
            removed |= _tag_list(s)
    return added, removed


def _is_field_id(v):
    return isinstance(v, str) and bool(ID_RE.match(v) or UUID_RE.match(v))


def field_writes_of(steps):
    """Custom-field ids a workflow WRITES.

    update_contact_field -> attributes.fields[].field
    math_operation       -> attributes.updateField
    """
    out = set()
    for s in steps:
        t = step_type(s).lower()
        a = attrs_of(s)
        if t == "update_contact_field":
            for f in a.get("fields") or []:
                if isinstance(f, dict) and _is_field_id(f.get("field")):
                    out.add(f["field"])
        elif t == "math_operation":
            if _is_field_id(a.get("updateField")):
                out.add(a["updateField"])
    return out


def field_titles_of(steps):
    """{field_id: human title}, from update_contact_field fields[].title."""
    out = {}
    for s in steps:
        if step_type(s).lower() != "update_contact_field":
            continue
        for f in attrs_of(s).get("fields") or []:
            if isinstance(f, dict) and _is_field_id(f.get("field")) and f.get("title"):
                out.setdefault(f["field"], redact(f["title"]))
    return out


def field_write_values_of(steps):
    """{field_id: set(redacted values written)}."""
    out = {}
    for s in steps:
        if step_type(s).lower() != "update_contact_field":
            continue
        for f in attrs_of(s).get("fields") or []:
            if isinstance(f, dict) and _is_field_id(f.get("field")):
                out.setdefault(f["field"], set()).add(
                    json.dumps(redact(f.get("value")))
                )
    return out


def field_reads_of(steps):
    """math_operation.selectField, a field read as the arithmetic source."""
    out = set()
    for s in steps:
        if step_type(s).lower() == "math_operation":
            v = attrs_of(s).get("selectField")
            if _is_field_id(v):
                out.add(v)
    return out


def field_conditions_of(steps):
    """{field_id: set(conditionValues)} for contact_detail/custom-field tests."""
    out = {}
    for s in steps:
        for c in conditions_of(s):
            ctype = str(c.get("conditionType") or "")
            sub = c.get("conditionSubType")
            if not isinstance(sub, str):
                continue
            is_field = ("contact_detail" in ctype or "custom" in ctype.lower()) or \
                       bool(ID_RE.match(sub) or UUID_RE.match(sub))
            if not is_field:
                continue
            if not (ID_RE.match(sub) or UUID_RE.match(sub)):
                continue
            out.setdefault(sub, set()).add(json.dumps(redact(c.get("conditionValue"))))
    return out


def stages_of(steps):
    """pipeline_stage_ids targeted by create_opportunity steps."""
    out = set()
    for s in steps:
        if step_type(s).lower() not in STAGE_TYPES:
            continue
        v = attrs_of(s).get("pipeline_stage_id")
        if _is_field_id(v):
            out.add(v)
    return out


def host_of(url):
    if not isinstance(url, str) or not URLISH_RE.match(url.strip()):
        return None
    try:
        return urlparse(url.strip()).hostname
    except Exception:
        return None


def hosts_of(steps):
    """Hostnames of webhook/HTTP targets (attributes.url on a webhook step)."""
    out = set()
    for s in steps:
        for key, v in _string_leaves(attrs_of(s)):
            if is_secret_path(key):
                continue
            h = host_of(v)
            if h:
                out.add(h)
    return out


def type_counts(steps):
    from collections import Counter
    return Counter(step_type(s) for s in steps)


def tokens_of(steps):
    """Merge tokens ({{contact.x}} etc.) found in any string leaf of a step."""
    out = set()
    for s in steps:
        for key, v in _string_leaves(s):
            if is_secret_path(key):
                continue
            for m in TOKEN_RE.finditer(v):
                out.add(" ".join(m.group(0).split()))
    return out


# --------------------------------------------------------------------------
# graph structure: steps carry id / name / type / order / parentKey / next
# --------------------------------------------------------------------------

def depth_map(steps):
    """{step_id: depth}. parentKey points at a step id, or at a branch id
    nested inside an if_else/wait step's branches[]; resolve both."""
    by_id = {s.get("id"): s for s in steps if s.get("id")}
    branch_owner = {}
    for s in steps:
        sid = s.get("id")
        for path, v in deep_iter(attrs_of(s)):
            key = collapse_path(path)
            if key.endswith("branches[].id") or key.endswith("transitions[].id") \
               or key.endswith("__branchKey__"):
                if isinstance(v, str) and v:
                    branch_owner[v] = sid

    depths = {}

    def depth(sid, seen=()):
        if sid in depths:
            return depths[sid]
        if sid in seen or sid not in by_id:
            return 0
        pk = by_id[sid].get("parentKey")
        if pk in by_id:
            # plain sequential next-step link, same nesting level
            d = depth(pk, seen + (sid,))
        elif pk in branch_owner:
            # first step inside a branch, one level deeper than the if_else
            d = depth(branch_owner[pk], seen + (sid,)) + 1
        else:
            d = 0
        depths[sid] = d
        return d

    for s in steps:
        if s.get("id"):
            depth(s["id"])
    return depths


def key_params(step):
    """Type-specific 'what this step actually does', grounded in `schema`."""
    t = step_type(step).lower()
    a = attrs_of(step)
    out = []

    def add(label, val):
        if val in (None, "", [], {}):
            return
        out.append(f"{label}={jd(redact(val)) if isinstance(val, str) else val}")

    if t == "wait":
        sa = a.get("startAfter") or {}
        if sa.get("value") is not None:
            out.append(f"after={sa.get('value')} {sa.get('type')} {sa.get('when') or ''}".strip())
        asa = a.get("appointmentStartAfter") or {}
        if asa.get("value") is not None:
            out.append(f"appt={asa.get('value')} {asa.get('type')} "
                       f"{asa.get('when') or ''}".strip())
        w = a.get("window") or {}
        if w.get("start") or w.get("end"):
            out.append(f"window={w.get('start')}-{w.get('end')} days={w.get('days')}")
        add("waitType", a.get("type"))
        for c in conditions_of(step):
            out.append("cond " + fmt_condition(c))
    elif t == "wait_for_reply":
        out.append(f"timeout={a.get('wait_amount')} {a.get('wait_unit')}")
    elif t in TAG_TYPES:
        verb = "removes" if t in TAG_REMOVE_TYPES else "adds"
        out.append(f"{verb}=" + ",".join(sorted(_tag_list(step))))
    elif t == "sms":
        add("body", a.get("body"))
    elif t == "sendblue_outbound_message":
        add("content", a.get("content"))
    elif t == "email":
        add("subject", a.get("subject"))
        add("from", a.get("from_email"))
    elif t == "internal_notification":
        add("channel", a.get("type"))
        add("subject", ((a.get("email") or {}).get("subject")))
        add("to", ((a.get("email") or {}).get("to")))
        add("body", ((a.get("sms") or {}).get("body")))
        add("to", ((a.get("sms") or {}).get("to")))
    elif t == "slack_message":
        add("channel", ((a.get("channel") or {}).get("name")))
        add("text", a.get("text"))
    elif t in TASK_TYPES:
        add("title", a.get("title") or a.get("name"))
    elif t in WEBHOOK_TYPES:
        h = host_of(a.get("url") or "")
        out.append(f"{a.get('method') or 'GET'} host={h or '?'}")
        keys = [c.get("key") for c in (a.get("customData") or [])
                if isinstance(c, dict) and c.get("key")]
        if keys:
            out.append("customData=" + ",".join(map(str, keys[:8])))
    elif t == "update_contact_field":
        add("actionType", a.get("actionType"))
        for f in a.get("fields") or []:
            if isinstance(f, dict):
                out.append(f"{f.get('field')} ({redact(f.get('title'))}) := "
                           f"{jd(redact(f.get('value')))}")
    elif t == "math_operation":
        ops = ",".join(f"{o.get('operator')} {redact(o.get('value'))}"
                       for o in (a.get("operators") or []) if isinstance(o, dict))
        out.append(f"{a.get('selectField')} {ops} -> {a.get('updateField')}")
    elif t == "create_opportunity":
        out.append(f"stage={a.get('pipeline_stage_id')} pipeline={a.get('pipeline_id')}")
        add("status", a.get("opportunity_status"))
        add("value", a.get("monetary_value"))
    elif t == "remove_opportunity":
        out.append(f"pipeline={a.get('pipeline_id')} which={a.get('opportunity_to_be_found')}")
    elif t in ("add_to_workflow", "remove_from_workflow"):
        wid = a.get("workflow_id")
        out.append("workflow=" + (",".join(wid) if isinstance(wid, list) else str(wid)))
    elif t == "goto":
        out.append(f"target={a.get('targetNodeId')}")
    elif t == "update_appointment_status":
        out.append(f"status={a.get('status_type')}")
    elif t == "update_conversation_ai_status":
        out.append(f"ai={a.get('status')}")
    elif t == "event_start_date":
        add("value", a.get("value"))
    elif t == "custom_code":
        add("lang", a.get("language"))
        add("code", a.get("code"))
    elif t == "datetime_formatter":
        out.append(f"{a.get('format', {}).get('fromFormat')} -> "
                   f"{a.get('format', {}).get('toFormat')}")
    elif t == "dnd_contact":
        out.append(f"dnd={a.get('dnd_contact')} channels={a.get('specific_channels')}")
    elif t == "facebook_conversion_api":
        out.append(f"event={a.get('event_name')}")
    elif t == "if_else":
        add("label", a.get("conditionName"))
    elif t == "ivr_connect_call":
        out.append("outbound call")
    return "  ".join(out)


# --------------------------------------------------------------------------
# triggers (only present once `harvest-triggers` has run)
# --------------------------------------------------------------------------

def trigger_list(doc):
    """Normalize whatever shape the triggers file has into a list of dicts."""
    if isinstance(doc, list):
        return [t for t in doc if isinstance(t, dict)]
    if isinstance(doc, dict):
        for k in ("triggers", "rows", "data", "items"):
            v = doc.get(k)
            if isinstance(v, list):
                return [t for t in v if isinstance(t, dict)]
        if "type" in doc or "eventType" in doc:
            return [doc]
    return []


def trigger_rows(doc):
    """[(type, name, [(key, redacted_value), ...])] for one triggers doc."""
    rows = []
    for t in trigger_list(doc):
        ttype = t.get("type") or t.get("eventType") or t.get("key") or "?"
        tname = t.get("name") or t.get("label") or ""
        filters = []
        for path, v in deep_iter(t):
            key = collapse_path(path)
            if key in ("type", "name", "eventType", "label"):
                continue
            if is_secret_path(key):
                continue
            if v in (None, "", [], {}):
                continue
            filters.append((key, redact(v)))
        rows.append((str(ttype), str(tname), filters))
    return rows


def trigger_summary(doc, limit=2):
    rows = trigger_rows(doc)
    if not rows:
        return "—"
    parts = [f"{t}{'/' + n if n else ''}" for t, n, _ in rows[:limit]]
    if len(rows) > limit:
        parts.append(f"+{len(rows)-limit}")
    return ";".join(parts)


def trigger_form_ids(doc):
    """Form/survey/calendar ids a trigger is scoped to."""
    out = set()
    for _t, _n, filters in trigger_rows(doc):
        for key, v in filters:
            kl = key.lower()
            if any(h in kl for h in ("form", "survey", "calendar")) and _is_field_id(v):
                out.add(v)
    return out


# --------------------------------------------------------------------------
# rendering
# --------------------------------------------------------------------------

def cut(s, n):
    s = "" if s is None else str(s)
    return s if len(s) <= n else s[: max(0, n - 1)] + "…"


def md_cell(s):
    return str("" if s is None else s).replace("|", "\\|").replace("\n", " ")


def fixed_table(headers, rows, widths):
    lines = []
    lines.append("  ".join(h.ljust(w)[:w] for h, w in zip(headers, widths)))
    lines.append("  ".join("-" * w for w in widths))
    for r in rows:
        lines.append("  ".join(cut(c, w).ljust(w) for c, w in zip(r, widths)))
    return "\n".join(lines)


def md_table(headers, rows):
    lines = ["| " + " | ".join(headers) + " |",
             "|" + "|".join("---" for _ in headers) + "|"]
    for r in rows:
        lines.append("| " + " | ".join(md_cell(c) for c in r) + " |")
    return "\n".join(lines)


def joinset(vals, limit=4, sep=","):
    vals = sorted(str(v) for v in vals)
    if not vals:
        return "—"
    if len(vals) <= limit:
        return sep.join(vals)
    return sep.join(vals[:limit]) + f"+{len(vals)-limit}"
