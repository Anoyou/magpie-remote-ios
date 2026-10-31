#!/usr/bin/env python3
"""Builds spec/gateway-contract.json: every gateway route Magpie Remote calls and
every JSON field it may read, straight from a magpie source tree.

    build_contract.py <magpie-src> [out.json]

Struct-backed bodies are expanded from the Go structs (gostructs.py), so a
field added, renamed, retyped or made omitempty in a new release changes the
output. map[string]any bodies (models, limit, keys, info, me, errors) are
listed by hand and pinned to the source by "anchors": exact source snippets
that must still exist (a missing anchor is reported in "anchors_missing").

Weekly CI: check out the new magpie tag, run this script, `diff` (or
`jq -S`) against the committed contract. "core": true marks the fields the app
actually displays or branches on; a change there is a breaking change.
"""
import json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "..", "magpie"))
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "..", "gateway-contract.json")

ROOTS = ["usageapi.Usage", "usageapi.Ledger", "provider.Quota", "provider.SubscriptionQuota", "provider.QuotaHistory",
         "budget.Status", "access.Limit", "access.Issued", "gateway.Active", "gateway.Lane"]
schema = json.loads(subprocess.check_output([sys.executable, os.path.join(HERE, "gostructs.py"), SRC] + ROOTS))


def flat(node, prefix):
    """schema node -> [{path,type,required,nullable,go}]"""
    out = []
    if node.get("type") == "object" and "properties" in node:
        for k, v in node["properties"].items():
            p = f"{prefix}.{k}" if prefix else k
            out.append({"path": p, "type": v.get("type"), "required": not (v.get("omitempty") or v.get("omitzero")),
                        "nullable": bool(v.get("nullable")), "go": v.get("go")})
            out += flat(v, p)
    if node.get("items"):
        out += flat(node["items"], prefix + "[]")
    if node.get("values"):
        out += flat(node["values"], prefix + "{}")
    return out


def struct_fields(root, prefix, core):
    fs = flat(schema[root], prefix)
    for f in fs:
        f["core"] = any(f["path"] == c or f["path"].startswith(c + ".") and False for c in core) or f["path"] in core
    return fs


def manual(spec, core=()):
    """spec: list of 'path:type' or 'path:type?' (? = may be absent)."""
    out = []
    for s in spec:
        p, t = s.rsplit(":", 1)
        opt = t.endswith("?")
        out.append({"path": p, "type": t.rstrip("?"), "required": not opt, "nullable": False, "go": None,
                    "core": p in core})
    return out


def prefixed(fs, prefix):
    return [dict(f, path=prefix + f["path"]) for f in fs]


ERR = manual(["error:object", "error.message:string", "error.type:string", "error.code:string|null", "error.param:string|null?"],
             core={"error.message", "error.type", "error.code"})
MODEL = ["id:string", "object:string", "type:string", "created:integer", "created_at:string", "owned_by:string",
         "display_name:string", "reasoning:boolean", "supported_reasoning_levels:array", "supported_reasoning_levels[].effort:string",
         "reasoning_levels:array", "context_window:integer?", "context_length:integer?", "max_input_tokens:integer?",
         "max_output_tokens:integer?", "native_endpoints:array?", "modalities:object?", "modalities.input:array?",
         "modalities.output:array?", "tool_call:boolean", "supported_parameters:array", "service_tiers:array?",
         "pricing:object?", "pricing.prompt:string", "pricing.completion:string", "pricing.input_cache_read:string?",
         "pricing.input_cache_write:string?"]
MODEL_CORE = {"id", "owned_by", "display_name", "reasoning", "reasoning_levels", "context_window", "max_output_tokens",
              "native_endpoints", "modalities.input", "pricing.prompt", "pricing.completion", "magpie_label"}
TOT_CORE = {"calls", "errors", "input", "output", "cache_read", "cache_write", "reasoning", "cost", "unpriced",
            "timed", "ttft_ms", "decode_ms", "decode_out"}


def core_paths(prefixes, names):
    return {p + n for p in prefixes for n in names}


routes = []


def route(method, path, auth, source, anchors, fields, schema_root=None, notes=None, content_type="application/json"):
    path, _, q = path.partition("?")
    r = {"method": method, "path": path, "auth": auth, "source": source, "content_type": content_type}
    if q:
        r["query"] = [k.rstrip("=") for k in q.split("&")]
    if schema_root:
        r["schema"] = schema_root
    if notes:
        r["notes"] = notes
    r["anchors"] = anchors
    r["fields"] = fields
    routes.append(r)


GW = "internal/gateway/"
route("GET", "/v1", "any enabled key (read-only ok)", GW + "gateway.go:925",
      [(GW + "gateway.go", 'out := map[string]any{"name": "magpie", "version": Version, "models": catalogSize.get'),
       (GW + "gateway.go", 'mux.HandleFunc("GET /v1", s.info)')],
      manual(["name:string", "version:string", "models:integer", "window:boolean", "apis:array"],
             core={"name", "version"}), notes="health + version probe; also GET / and /v1/")
route("GET", "/api/hello", "any key except read-only", GW + "gateway.go:802",
      [(GW + "gateway.go", 'writeJSON(w, 200, map[string]any{"name": "magpie", "version": Version})')],
      manual(["name:string", "version:string"], core={"version"}))
route("GET", "/v1/models?format=", "full or held key (read-only 403)", GW + "gateway.go:1246",
      [(GW + "gateway.go", 'm := map[string]any{"id": e.ID, "object": "model", "type": "model", "created": 0,'),
       (GW + "gateway.go", '"owned_by": e.Provider.ID, "display_name": e.PlainName(), "reasoning": e.Thinks(), "supported_reasoning_levels": levels,'),
       (GW + "gateway.go", 'm["context_window"], m["context_length"], m["max_input_tokens"] = e.Context, e.Context, e.Context'),
       (GW + "gateway.go", 'm["max_output_tokens"] = out'), (GW + "gateway.go", 'm["native_endpoints"] = native'),
       (GW + "gateway.go", 'm["modalities"] = mod'), (GW + "gateway.go", 'm["supported_parameters"] = params'),
       (GW + "gateway.go", 'm["magpie_label"] = labels[i]'), (GW + "gateway.go", 'm["pricing"] = catalog.OpenRouterPricing(pr)'),
       (GW + "gateway.go", 'out := map[string]any{"object": "list", "data": data, "has_more": false}'),
       (GW + "gateway.go", 'out["first_id"], out["last_id"] = data[0]["id"], data[len(data)-1]["id"]'),
       ("internal/catalog/openrouter.go", 'out := map[string]string{"prompt": PerToken(pr.Input), "completion": PerToken(pr.Output)}'),
       ("internal/provider/group.go", 'const GroupPrefix = "group/"')],
      manual(["object:string", "data:array", "has_more:boolean", "first_id:string?", "last_id:string?"], core={"data"})
      + prefixed(manual(MODEL + ["magpie_label:string"], core=MODEL_CORE), "data[]."),
      notes="routing groups: id starts 'group/' or 'auto/', no native_endpoints, magpie_label ends '· routing group'")
route("GET", "/v1/models/{id}", "full or held key", GW + "gateway.go:1369",
      [(GW + "gateway.go", 'writeError(w, provider.Chat, 404, "unknown model "+id)')], manual(MODEL, core=MODEL_CORE))
CHAT_USAGE = ["usage.prompt_tokens:integer", "usage.completion_tokens:integer", "usage.total_tokens:integer",
              "usage.prompt_tokens_details.cached_tokens:integer?", "usage.prompt_tokens_details.cache_write_tokens:integer?",
              "usage.completion_tokens_details.reasoning_tokens:integer?"]
route("POST", "/v1/chat/completions", "full or held key", GW + "chat.go:1540",
      [(GW + "chat.go", '"model": e.model, "choices": choices, "usage": usage})'),
       (GW + "chat.go", 'e.chunk(map[string]any{"reasoning_content": ev.Text}, nil, nil)'),
       (GW + "chat.go", 'e.w.event("", "[DONE]")'),
       (GW + "chat.go", 'case "image_url":'),
       (GW + "chat.go", '"prompt_tokens_details":     map[string]any{"cached_tokens": u.CacheRead, "cache_write_tokens": u.CacheWrite},'),
       (GW + "sse.go", 'io.WriteString(s.w, ": "+text+"\\n")')],
      manual(["id:string", "object:string", "created:integer", "model:string", "choices:array", "choices[].index:integer",
              "choices[].delta.role:string?", "choices[].delta.content:string?", "choices[].delta.reasoning_content:string?",
              "choices[].delta.tool_calls:array?", "choices[].delta.tool_calls[].index:integer",
              "choices[].delta.tool_calls[].id:string?", "choices[].delta.tool_calls[].function.name:string?",
              "choices[].delta.tool_calls[].function.arguments:string?", "choices[].finish_reason:string|null",
              "choices[].message.content:string|null", "choices[].message.reasoning_content:string?",
              "choices[].message.tool_calls:array?", "usage:object|null?"] + CHAT_USAGE,
             core={"choices[].delta.content", "choices[].delta.reasoning_content", "choices[].finish_reason",
                   "choices[].message.content", "usage.prompt_tokens", "usage.completion_tokens"}),
      content_type="text/event-stream (stream:true) | application/json",
      notes="SSE: 'data: <json>' events, no event: line; ': keepalive' comments; ends 'data: [DONE]' (or EOF after finish_reason on passthrough); mid-stream error = data:{error:{...}}")
RESP_EVENTS = ["response.created", "response.in_progress", "response.output_item.added", "response.output_item.done",
               "response.content_part.added", "response.content_part.done", "response.output_text.delta",
               "response.output_text.done", "response.reasoning_summary_part.added", "response.reasoning_summary_part.done",
               "response.reasoning_summary_text.delta", "response.reasoning_summary_text.done",
               "response.function_call_arguments.delta", "response.function_call_arguments.done",
               "response.completed", "response.incomplete", "response.failed"]
route("POST", "/v1/responses", "full or held key", GW + "responses.go:2006",
      [(GW + "responses.go", f'e.send("{ev}"') for ev in RESP_EVENTS if ev not in ("response.completed", "response.incomplete", "response.in_progress")]
      + [(GW + "responses.go", 'status, typ := "completed", "response.completed"'),
         (GW + "responses.go", 'status, typ = "incomplete", "response.incomplete"'),
         (GW + "responses.go", 'fields["sequence_number"] = e.seq'),
         (GW + "responses.go", '"input_tokens_details":  map[string]any{"cached_tokens": u.CacheRead, "cache_write_tokens": u.CacheWrite},'),
         (GW + "responses.go", 'case "input_image":')],
      manual(["type:string", "sequence_number:integer", "delta:string?", "text:string?", "item_id:string?", "output_index:integer?",
              "item:object?", "response:object?", "response.id:string", "response.status:string", "response.model:string",
              "response.created_at:integer", "response.output:array", "response.usage.input_tokens:integer?",
              "response.usage.output_tokens:integer?", "response.usage.input_tokens_details.cached_tokens:integer?",
              "response.usage.output_tokens_details.reasoning_tokens:integer?", "response.error.code:string?",
              "response.error.message:string?", "response.incomplete_details.reason:string?"],
             core={"type", "delta", "response.status", "response.usage.input_tokens", "response.usage.output_tokens", "response.error.message"}),
      content_type="text/event-stream", notes="event names: " + ", ".join(RESP_EVENTS) + "; ignore unknown types")
U_CORE = TOT_CORE | {"period", "since", "bucket", "series", "series[].time", "series[].label", "sessionCount"} \
    | core_paths(["agents[].", "models[].", "accounts[].", "callerKeys[]."], {"id", "name", "icon", "sub"} | TOT_CORE)
route("GET", "/v1/magpie/usage?period=", "local or shared+key; held key 403 gateway_key_held", "internal/gateway/usage_api.go:51",
      [("internal/usageapi/usageapi.go", "func PeriodOf(s string) usage.Period {"),
       ("internal/usage/usage.go", 'Today Period = "today"'), ("internal/usage/usage.go", 'Week  Period = "7d"'),
       ("internal/usage/usage.go", 'Month Period = "30d"'), ("internal/usage/usage.go", 'All   Period = "all"'),
       ("internal/usage/period_range.go", 'const rangeSep = ".."'), ("internal/usage/period_range.go", 'const lastSep = "last:"')],
      [dict(f, core=f["path"] in U_CORE) for f in flat(schema["usageapi.Usage"], "")], schema_root="usageapi.Usage",
      notes="period: today|7d|30d|all|YYYY-MM-DD..YYYY-MM-DD|last:<dur>; anything else -> 30d")
L_CORE = TOT_CORE | {"period", "offset", "total", "bucket", "rows"} | core_paths(["rows[]."], {
    "t", "agent", "agentName", "provider", "providerName", "model", "req", "served", "in", "out", "cache_read", "cache_write",
    "reasoning", "ms", "ttft_ms", "status", "err", "ep", "session", "callerKeyId", "callerKeyLabel", "cost", "priced", "route_id"})
route("GET", "/v1/magpie/usage/requests?period=&day=&failed=&retried=&model=&agent=&provider=&callerKey=&account=&purpose=&q=&route=&computer=&via=&offset=&limit=", "local or shared+key; held key gets own rows only", "internal/gateway/usage_api.go:66",
      [("internal/usageapi/usageapi.go", 'return usage.Filter{Day: q.Get("day"), RouteID: id, Model: q.Get("model"), Agent: q.Get("agent"), Provider: q.Get("provider"), Purpose: q.Get("purpose"), Account: q.Get("account"), CallerKey: q.Get("callerKey"), Failed: q.Get("failed") == "1", Retried: q.Get("retried") == "1", Query: q.Get("q"), Computer: q.Get("computer"), Through: viaOf(q.Get("via"))}'),
       ("internal/usage/request_page.go", "limit = min(limit, 500)"), ("internal/usage/request_page.go", "limit = 100"),
       ("internal/gateway/usage_api.go", 'offset, _ := strconv.Atoi(q.Get("offset"))')],
      [dict(f, core=f["path"] in L_CORE) for f in flat(schema["usageapi.Ledger"], "")], schema_root="usageapi.Ledger",
      notes="query: period, day, failed=1, retried=1, model, agent, provider, callerKey, account, purpose, q, route, computer, via, offset, limit(<=500, default 100)")
Q_CORE = {"data", "data[].provider", "data[].name", "data[].kind", "data[].plan", "data[].user", "data[].windows",
          "data[].windows[].name", "data[].windows[].used", "data[].windows[].remaining", "data[].windows[].resetsAt",
          "data[].windows[].display", "data[].windows[].text", "data[].balance", "data[].error", "data[].asOf", "data[].readAt", "data[].alias"}
wrap = manual(["object:string", "data:array|null"], core={"data"})
held_anchor = ("internal/provider/remote_quotas.go", 'const KeyHeldCode = "gateway_key_held"')
route("GET", "/v1/magpie/quotas?kept=", "local or shared+key; held key 403 gateway_key_held (unless Quotas option)", GW + "gateway.go:945",
      [held_anchor, (GW + "gateway.go", 'if r.URL.Query().Get("kept") == "1" {')],
      wrap + [dict(f, core=f["path"] in Q_CORE) for f in flat(schema["provider.Quota"], "data[]")], schema_root="provider.Quota",
      notes="?kept=1 = cached, no vendor asked")
C_CORE = {"data", "data[].provider", "data[].name", "data[].icon", "data[].kind", "data[].plan", "data[].user",
          "data[].windows", "data[].windows[].name", "data[].windows[].used", "data[].windows[].resetsAt",
          "data[].windows[].display", "data[].windows[].text", "data[].balance", "data[].error", "data[].readAt", "data[].alias"}
cards_fields = wrap + [dict(f, core=f["path"] in C_CORE) for f in flat(schema["provider.SubscriptionQuota"], "data[]")]
route("GET", "/v1/magpie/quotas/cards", "as /quotas", GW + "gateway.go:985",
      [held_anchor, ("internal/provider/remote_quotas.go", 'const RemoteCardsPath = "/v1/magpie/quotas/cards"')],
      cards_fields, schema_root="provider.SubscriptionQuota")
route("POST", "/v1/magpie/quotas/refresh?provider=&user=", "as /quotas; read-only 403", GW + "gateway.go:1011",
      [(GW + "gateway.go", "const remoteRefreshGap = 30 * time.Second"),
       ("internal/provider/remote_quotas.go", 'const RemoteRefreshPath = "/v1/magpie/quotas/refresh"'),
       (GW + "gateway.go", 'writeError(w, provider.Chat, http.StatusBadRequest, "this magpie reads only its own cards again")')],
      cards_fields, schema_root="provider.SubscriptionQuota",
      notes="no body; throttled (<30s per provider|user) -> same 200 cached cards, no error")
route("GET", "/v1/magpie/quotas/history?days=&provider=&user=", "as /quotas", GW + "gateway.go:969",
      [("internal/provider/quota_history.go", "quotaHistKept = 45 * 24 * time.Hour"), held_anchor],
      wrap + [dict(f, core=True) for f in flat(schema["provider.QuotaHistory"], "data[]")], schema_root="provider.QuotaHistory",
      notes="days float; <=0, non-number or >45 -> 45")
S_CORE = {"period", "days", "hours", "start", "reset", "calls", "tokens", "cost", "tokenLimit", "costLimit", "tokensLeft", "costLeft", "spent"}
status_f = lambda pre: [dict(f, core=f["path"][len(pre):].lstrip(".") in S_CORE) for f in flat(schema["budget.Status"], pre)]
route("GET", "/v1/magpie/limit", "any key", GW + "key_limit.go:119",
      [(GW + "key_limit.go", 'out := map[string]any{"limited": false, "key": who.KeyName}'),
       (GW + "key_limit.go", 'out["issuerLimits"] = budget.All('), (GW + "key_limit.go", 'out["expires"] = who.Expires'),
       (GW + "key_limit.go", 'out["limited"], out["limit"], out["limits"] = true, budget.Binding(all), all')],
      manual(["limited:boolean", "key:string", "expires:string(RFC3339 date-time)?", "issuerLimits:array?", "limit:object?", "limits:array?"],
             core={"limited", "key", "expires", "limit", "limits"})
      + status_f("limit") + status_f("limits[]") + status_f("issuerLimits[]"), schema_root="budget.Status")
route("GET", "/v1/magpie/me", "any enabled key", GW + "key_page.go:60",
      [(GW + "key_page.go", 'const keyPageData = "/v1/magpie/me"'), (GW + "key_page.go", '"version":   Version,'),
       (GW + "key_page.go", "var keyPageUsage = []usage.Period{usage.Today, usage.Week, usage.Month}")],
      manual(["name:string", "readOnly:boolean", "limits:array", "usage:object", "usage{}.calls:integer", "usage{}.errors:integer",
              "usage{}.input:integer", "usage{}.output:integer", "usage{}.cache_read:integer", "usage{}.cache_write:integer",
              "usage{}.cost:number", "usage{}.unpriced:integer", "topModels:array", "topModels[].id:string", "topModels[].calls:integer",
              "topModels[].cost:number", "models:array", "models[].id:string", "models[].label:string", "version:string"],
             core={"name", "readOnly", "version", "usage{}.calls", "usage{}.cost", "models[].id", "models[].label"}) + status_f("limits[]"))
A_CORE = {"active", "active[].id", "active[].agent", "active[].model", "active[].provider", "active[].started", "active[].ms", "active[].phase"}
route("GET", "/v1/magpie/concurrency", "local or shared+key; held key 403", GW + "concurrency.go:251",
      [(GW + "concurrency.go", 'writeJSON(w, 200, map[string]any{"object": "concurrency", "data": lanes, "requests": b.Requests, "waiting": waiting, "tools": b.Tools, "active": s.Active()})')],
      manual(["object:string", "data:object", "requests:integer", "waiting:integer", "tools:integer", "active:array"],
             core={"requests", "waiting", "tools", "active"})
      + [dict(f, core=True) for f in flat(schema["gateway.Lane"], "data{}")]
      + [dict(f, core=f["path"] in A_CORE) for f in flat(schema["gateway.Active"], "active[]")], schema_root="gateway.Active")
route("POST", "/v1/magpie/keys", "key with issuer flag (not issued, not read-only)", GW + "issue_keys.go:64",
      [(GW + "issue_keys.go", 'const KeysPath = "/v1/magpie/keys"'), (GW + "issue_keys.go", 'TTL      json.RawMessage `json:"ttl"`'),
       (GW + "issue_keys.go", "writeJSON(w, http.StatusCreated, k)"), ("internal/access/issue.go", "MaxTTL = 30 * 24 * time.Hour")],
      [dict(f, core=f["path"] in {"id", "name", "key", "expires", "models"}) for f in flat(schema["access.Issued"], "")],
      schema_root="access.Issued", notes='body {name, ttl:"1h"|seconds, models?, accounts?, tokens?, cost?, readOnly?} -> 201')
route("GET", "/v1/magpie/keys", "issuer key", GW + "issue_keys.go:91",
      [(GW + "issue_keys.go", 'e := map[string]any{"id": k.ID, "name": k.Name, "key": k.Masked, "expires": k.Expires, "expired": !time.Now().Before(k.Expires)}'),
       (GW + "issue_keys.go", 'writeJSON(w, http.StatusOK, map[string]any{"keys": out})')],
      manual(["keys:array", "keys[].id:string", "keys[].name:string", "keys[].key:string", "keys[].expires:string(RFC3339 date-time)",
              "keys[].expired:boolean", "keys[].models:array?", "keys[].accounts:array?", "keys[].limit:object?", "keys[].readOnly:boolean?"],
             core={"keys[].id", "keys[].name", "keys[].expires", "keys[].expired"})
      + [dict(f, core=False) for f in flat(schema["access.Limit"], "keys[].limit")], schema_root="access.Limit")
route("DELETE", "/v1/magpie/keys/{id}", "issuer key", GW + "issue_keys.go:122",
      [(GW + "issue_keys.go", 'writeJSON(w, http.StatusOK, map[string]any{"revoked": r.PathValue("id")})')],
      manual(["revoked:string"], core={"revoked"}))
route("*", "(error envelope)", "-", GW + "gateway.go:8253",
      [(GW + "gateway.go", 'v = map[string]any{"error": map[string]any{"message": msg, "type": typ, "code": code, "param": param}}'),
       (GW + "usage_api.go", 'writeJSON(w, http.StatusForbidden, map[string]any{"error": map[string]any{"message": msg, "type": "permission_error", "code": provider.KeyHeldCode}})'),
       (GW + "readonly.go", 'const ReadOnlyCode = "gateway_key_read_only"'),
       (GW + "lan.go", "http.Error(w, \"magpie isn't shared on the local network\", http.StatusForbidden)"),
       (GW + "lan.go", 'return "no API key was sent: send a magpie gateway key as Authorization: Bearer <key> (or x-api-key)"'),
       (GW + "lan.go", 'return which + " is not an enabled magpie gateway key: it is disabled, removed or mistyped"'),
       (GW + "key_models.go", "return fmt.Sprintf(\"The gateway key %q may not use %s; it may use %s. Change the key's models in magpie's Gateway page, or use a model it has.\",")],
      ERR, notes="codes: gateway_key_held, gateway_key_read_only; not-shared 403 is text/plain")

missing = []
for r in routes:
    ok = []
    for f, snip in r["anchors"]:
        try:
            hit = snip in open(os.path.join(SRC, f), encoding="utf-8").read()
        except FileNotFoundError:
            hit = False
        ok.append({"file": f, "text": snip, "found": hit})
        if not hit:
            missing.append(f"{r['method']} {r['path']}: {f}: {snip}")
    r["anchors"] = ok
try:
    commit = subprocess.check_output(["git", "-C", SRC, "rev-parse", "--short", "HEAD"], text=True).strip()
    describe = subprocess.check_output(["git", "-C", SRC, "describe", "--tags", "--always"], text=True).strip()
except Exception:
    commit = describe = "unknown"
out = {"magpie_commit": commit, "magpie_version": describe, "generated_by": "spec/tools/build_contract.py",
       "conventions": {"time": "RFC3339 with 0-9 fractional digits and the server's offset (Go time.Time)",
                       "money": "USD float (cost*); model pricing = strings, USD per token; quota balance = display string",
                       "percent": "quota used/remaining/left are 0-100 floats", "durations": "*_ms and ms are integer milliseconds",
                       "required": "false = omitempty/omitzero in Go (absent when zero)", "nullable": "Go nil slice/map/pointer may be null"},
       "anchors_missing": missing, "routes": routes}
with open(OUT, "w", encoding="utf-8") as fh:
    json.dump(out, fh, indent=1, ensure_ascii=False)
    fh.write("\n")
print(f"{len(routes)} routes, {sum(len(r['fields']) for r in routes)} fields, {len(missing)} anchors missing -> {os.path.abspath(OUT)}")
for m in missing:
    print("MISSING:", m)
sys.exit(1 if missing else 0)
