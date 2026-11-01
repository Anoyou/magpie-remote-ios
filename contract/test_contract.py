#!/usr/bin/env python3
"""magpie 接口契约测试（只用 Python 标准库）。

对一台由 run-magpie-fixture.sh 启动的真实 magpie（网关 + `magpie web`）逐条调用 Magpie Remote
依赖的接口，按 gateway-contract.json / web-contract.json 校验状态码、Content-Type 与字段（存在性、类型、
时间格式）。网关调用一律走 127.0.0.1 并带 X-Forwarded-For，让 magpie 把它当作「另一台机器」，
从而真正经过共享开关与密钥校验（回环地址会绕过这两项，见 NOTES 的 loopback 坑）。

用法：
    python3 contract/test_contract.py [fixture.env]
环境变量（未给 fixture.env 时从环境读取，即 run-magpie-fixture.sh 写进 $GITHUB_ENV 的那些）：
    MAGPIE_GATEWAY_PORT MAGPIE_WEB_PORT MAGPIE_GATEWAY_KEY MAGPIE_ISSUER_KEY MAGPIE_READONLY_KEY
    MAGPIE_WEB_KEY MAGPIE_VERSION
    CONTRACT_CAPTURE_DIR  每个响应原样写到这里（默认 $RUNNER_TEMP 或 /tmp 下的 magpie-contract-captures）
退出码：0 全部通过；1 有失败。失败明细同时写入 <capture dir>/report.json 与 report.md（中文）。
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
import traceback
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REMOTE_IP = "192.0.2.10"  # 文档专用地址，只用来触发「远程调用」判定
UA = "MagpieRemote/contract (CI)"
RFC3339 = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$")


# ---------------------------------------------------------------- env
def load_env() -> dict:
    env = dict(os.environ)
    if len(sys.argv) > 1:
        with open(sys.argv[1], encoding="utf-8") as f:
            for line in f:
                if "=" in line:
                    k, v = line.rstrip("\n").split("=", 1)
                    env[k] = v
    for k in ("MAGPIE_GATEWAY_KEY", "MAGPIE_ISSUER_KEY", "MAGPIE_READONLY_KEY", "MAGPIE_WEB_KEY"):
        if not env.get(k):
            sys.exit(f"缺少 {k}：先运行 contract/run-magpie-fixture.sh")
    if not env.get("MAGPIE_GATEWAY_PORT"):
        env["MAGPIE_GATEWAY_PORT"] = env.get("MAGPIE_GATEWAY_URL", ":3425").rsplit(":", 1)[-1]
    if not env.get("MAGPIE_WEB_PORT"):
        env["MAGPIE_WEB_PORT"] = env.get("MAGPIE_WEB_URL", ":3430").rsplit(":", 1)[-1]
    return env


ENV = load_env()
GW = f"http://127.0.0.1:{ENV['MAGPIE_GATEWAY_PORT']}"
WEB = f"http://127.0.0.1:{ENV['MAGPIE_WEB_PORT']}"
KEY, ISSUER, RO = ENV["MAGPIE_GATEWAY_KEY"], ENV["MAGPIE_ISSUER_KEY"], ENV["MAGPIE_READONLY_KEY"]
COOKIE = f"magpie_web_{ENV['MAGPIE_WEB_PORT']}={ENV['MAGPIE_WEB_KEY']}"
CAP = ENV.get("CONTRACT_CAPTURE_DIR") or os.path.join(ENV.get("RUNNER_TEMP") or "/tmp", "magpie-contract-captures")
os.makedirs(CAP, exist_ok=True)
GWC = json.load(open(os.path.join(HERE, "gateway-contract.json"), encoding="utf-8"))
WEBC = json.load(open(os.path.join(HERE, "web-contract.json"), encoding="utf-8"))
GW_ROUTES = {(r["method"], r["path"]): r for r in GWC["routes"]}
WEB_ROUTES = {(r["method"], r["path"]): r for r in WEBC["routes"]}
INDEX: list[str] = []
# 直连本机，不走环境里的 HTTP(S)_PROXY
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


# ---------------------------------------------------------------- http
class Resp:
    def __init__(self, status, headers, body):
        self.status, self.headers, self.body = status, headers, body
        self.ctype = headers.get("Content-Type", "")
        self.text = body.decode("utf-8", "replace")
        self.json = None
        if "json" in self.ctype:
            try:
                self.json = json.loads(self.text)
            except ValueError:
                pass

    def sse(self) -> list:
        out = []
        for block in self.text.split("\n\n"):
            data = [l[5:].strip() for l in block.splitlines() if l.startswith("data:")]
            if data and data[0] != "[DONE]":
                out.append(json.loads("\n".join(data)))
        return out


def call(name, method, url, key=None, remote=True, body=None, cookie=None, headers=None) -> Resp:
    h = {"User-Agent": UA}
    if remote:
        h["X-Forwarded-For"] = REMOTE_IP
    if key:
        h["Authorization"] = f"Bearer {key}"
    if cookie:
        h["Cookie"] = cookie
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        h["Content-Type"] = "application/json"
    h.update(headers or {})
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        with OPENER.open(req, timeout=30) as r:
            resp = Resp(r.status, r.headers, r.read())
    except urllib.error.HTTPError as e:
        resp = Resp(e.code, e.headers, e.read())
    ext = ".sse" if "event-stream" in resp.ctype else ".json" if "json" in resp.ctype else ".txt"
    with open(os.path.join(CAP, name + ext), "wb") as f:
        f.write(resp.body)
    INDEX.append(f"{name}{ext}\t{resp.status}\t{resp.ctype}\t{method} {url.replace(ENV['MAGPIE_WEB_KEY'], '<WEBKEY>')}")
    return resp


# ---------------------------------------------------------------- field checks
def _type_ok(t: str, v) -> bool:
    if v is None:
        return "null" in t
    base = t.split("|")
    for b in base:
        b0 = b.split("(")[0]
        if b0 == "string" and isinstance(v, str):
            if "RFC3339" in b and not RFC3339.match(v):
                return False
            return True
        if b0 == "integer" and isinstance(v, int) and not isinstance(v, bool):
            return True
        if b0 == "number" and isinstance(v, (int, float)) and not isinstance(v, bool):
            return True
        if b0 == "boolean" and isinstance(v, bool):
            return True
        if b0 == "array" and isinstance(v, list):
            return True
        if b0 == "object" and isinstance(v, dict):
            return True
    return False


def _parents(obj, tokens):
    """沿路径前缀取出所有父容器（dict）。中间缺失 = 父字段可选且不在，跳过。"""
    cur = [obj]
    for tok in tokens:
        name, kind = re.match(r"^(.*?)(\[\]|\{\})?$", tok).groups()
        nxt = []
        for c in cur:
            if not isinstance(c, dict) or name not in c or c[name] is None:
                continue
            v = c[name]
            if kind == "[]":
                nxt += v if isinstance(v, list) else []
            elif kind == "{}":
                nxt += list(v.values()) if isinstance(v, dict) else []
            else:
                nxt.append(v)
        cur = nxt
    return [c for c in cur if isinstance(c, dict)]


def check_gateway_fields(route_key, obj, where) -> list[str]:
    errs = []
    for f in GW_ROUTES[route_key]["fields"]:
        toks = f["path"].split(".")
        leaf = toks[-1]
        lname, lkind = re.match(r"^(.*?)(\[\]|\{\})?$", leaf).groups()
        for parent in _parents(obj, toks[:-1]):
            if lname not in parent:
                if f["required"]:
                    errs.append(f"{where}: 缺少必有字段 {f['path']}" + ("（核心字段）" if f.get("core") else ""))
                continue
            v = parent[lname]
            if v is None and f.get("nullable"):
                continue
            if not _type_ok(f["type"], v):
                errs.append(f"{where}: 字段 {f['path']} 应为 {f['type']}，实际 {type(v).__name__} {json.dumps(v)[:60]}")
    return errs


def check_web_fields(route_key, obj, where) -> list[str]:
    errs = []
    for spec in WEB_ROUTES[route_key]["fields"]["response"]:
        if not re.fullmatch(r"[A-Za-z0-9_\[\]\?.]+", spec):
            continue  # 占位说明，如 <stateJSON>、"key (action key)"
        toks = spec.split(".")
        parsed = [re.match(r"^(\w+)(\[\])?(\?)?$", t).groups() for t in toks]
        cur = [obj]
        for i, (name, arr, opt) in enumerate(parsed):
            last = i == len(parsed) - 1
            nxt = []
            for c in cur:
                if not isinstance(c, dict):
                    continue
                if name not in c:
                    if not opt:
                        errs.append(f"{where}: 缺少字段 {'.'.join(toks[:i+1])}（契约 {spec}）")
                    continue
                v = c[name]
                if arr:
                    if v is None and opt:
                        continue
                    if not isinstance(v, list):
                        errs.append(f"{where}: {'.'.join(toks[:i+1])} 应为数组，实际 {type(v).__name__}")
                        continue
                    nxt += v
                elif v is not None:
                    nxt.append(v)
            cur = nxt
            if last:
                break
    return sorted(set(errs))


# ---------------------------------------------------------------- tests
FAILS: list[dict] = []
PASSED: list[str] = []


def expect(cond, msg, errs):
    if not cond:
        errs.append(msg)


def status_is(r: Resp, code, ctype, errs, where):
    expect(r.status == code, f"{where}: 状态码应为 {code}，实际 {r.status}：{r.text[:200]}", errs)
    if ctype:
        expect(ctype in r.ctype, f"{where}: Content-Type 应含 {ctype}，实际 {r.ctype!r}", errs)


def error_envelope(r: Resp, code, typ, errs, where, err_code=None):
    status_is(r, code, "application/json", errs, where)
    if r.json is None:
        errs.append(f"{where}: 错误响应不是 JSON")
        return
    errs += check_gateway_fields(("*", "(error envelope)"), r.json, where)
    e = r.json.get("error") or {}
    expect(e.get("type") == typ, f"{where}: error.type 应为 {typ}，实际 {e.get('type')!r}", errs)
    if err_code is not None:
        expect(e.get("code") == err_code, f"{where}: error.code 应为 {err_code}，实际 {e.get('code')!r}", errs)


def t_info(errs):
    r = call("gw-v1", "GET", GW + "/v1", KEY)
    status_is(r, 200, "application/json", errs, "GET /v1")
    errs += check_gateway_fields(("GET", "/v1"), r.json or {}, "GET /v1")
    expect((r.json or {}).get("name") == "magpie", "GET /v1: name 应为 magpie", errs)
    want = ENV.get("MAGPIE_VERSION", "")
    if want.startswith("v"):
        expect((r.json or {}).get("version") == want, f"GET /v1: version 应为 {want}，实际 {(r.json or {}).get('version')!r}", errs)
    r = call("gw-api-hello", "GET", GW + "/api/hello", KEY)
    status_is(r, 200, "application/json", errs, "GET /api/hello")
    errs += check_gateway_fields(("GET", "/api/hello"), r.json or {}, "GET /api/hello")
    r = call("gw-v1-readonly", "GET", GW + "/v1", RO)
    status_is(r, 200, "application/json", errs, "GET /v1（只读密钥）")


def t_auth(errs):
    r = call("err-no-key", "GET", GW + "/v1/models")
    error_envelope(r, 401, "authentication_error", errs, "远程无密钥 GET /v1/models")
    r = call("err-wrong-key", "GET", GW + "/v1/models", "sk-magpie-key-" + "0" * 48)
    error_envelope(r, 401, "authentication_error", errs, "远程错误密钥 GET /v1/models")
    r = call("loopback-no-key-models", "GET", GW + "/v1/models", remote=False)
    status_is(r, 200, "application/json", errs, "本机无密钥 GET /v1/models（回环放行）")
    for hdr in ("X-Real-IP", "Forwarded"):
        val = REMOTE_IP if hdr != "Forwarded" else f"for={REMOTE_IP}"
        r = call(f"err-no-key-{hdr.lower()}", "GET", GW + "/v1/models", remote=False, headers={hdr: val})
        expect(r.status == 401, f"带 {hdr} 的本机请求应被当作远程（401），实际 {r.status}", errs)


def t_models(errs):
    r = call("gw-v1-models", "GET", GW + "/v1/models", KEY)
    status_is(r, 200, "application/json", errs, "GET /v1/models")
    errs += check_gateway_fields(("GET", "/v1/models"), r.json or {}, "GET /v1/models")
    ids = [m.get("id") for m in (r.json or {}).get("data", [])]
    for want in ("mock/mock-gpt-1", "mock/mock-gpt-mini", "group/fast"):
        expect(want in ids, f"GET /v1/models: 应列出 {want}，实际 {ids}", errs)
    r = call("gw-v1-models-one", "GET", GW + "/v1/models/mock/mock-gpt-1", KEY)
    status_is(r, 200, "application/json", errs, "GET /v1/models/{id}")
    errs += check_gateway_fields(("GET", "/v1/models/{id}"), r.json or {}, "GET /v1/models/{id}")
    r = call("err-model-unknown", "GET", GW + "/v1/models/nosuch/model", KEY)
    error_envelope(r, 404, "not_found_error", errs, "GET /v1/models/{未知}")
    r = call("err-readonly-models", "GET", GW + "/v1/models", RO)
    error_envelope(r, 403, "permission_error", errs, "只读密钥 GET /v1/models", "gateway_key_read_only")


def t_chat(errs):
    key = ("POST", "/v1/chat/completions")
    msgs = [{"role": "user", "content": "contract"}]
    r = call("gw-chat", "POST", GW + "/v1/chat/completions", KEY, body={"model": "mock/mock-gpt-mini", "messages": msgs})
    status_is(r, 200, "application/json", errs, "POST /v1/chat/completions")
    errs += check_gateway_fields(key, r.json or {}, "chat（非流式）")
    for model, name in (("mock/mock-gpt-1", "gw-chat-stream"), ("group/fast", "gw-chat-group-stream")):
        r = call(name, "POST", GW + "/v1/chat/completions", KEY, headers={"X-Magpie-Session": "contract"},
                 body={"model": model, "stream": True, "stream_options": {"include_usage": True}, "messages": msgs})
        status_is(r, 200, "text/event-stream", errs, f"POST /v1/chat/completions stream {model}")
        chunks = r.sse()
        expect(len(chunks) >= 2, f"{model} 流式：至少应有 2 个事件", errs)
        expect("data: [DONE]" in r.text, f"{model} 流式：应以 data: [DONE] 结束", errs)
        expect(any(c.get("choices") and c["choices"][0].get("finish_reason") for c in chunks),
               f"{model} 流式：应有带 finish_reason 的事件", errs)
        expect(any(c.get("usage") for c in chunks), f"{model} 流式：应有 usage 事件", errs)
        for i, c in enumerate(chunks):
            errs += check_gateway_fields(key, c, f"chat 流式 {model} 事件#{i}")
        if model.startswith("group/"):
            expect(r.headers.get("X-Magpie-Model", "").startswith("mock/"),
                   f"group 流式：应带 X-Magpie-Model 响应头指明实际模型，实际 {r.headers.get('X-Magpie-Model')!r}", errs)
    r = call("err-readonly-chat", "POST", GW + "/v1/chat/completions", RO, body={"model": "mock/mock-gpt-1", "messages": msgs})
    error_envelope(r, 403, "permission_error", errs, "只读密钥 chat", "gateway_key_read_only")


def t_responses(errs):
    r = call("gw-responses-stream", "POST", GW + "/v1/responses", KEY,
             body={"model": "mock/mock-gpt-1", "stream": True, "input": "contract"})
    status_is(r, 200, "text/event-stream", errs, "POST /v1/responses stream")
    events = r.sse()
    expect(any(e.get("type") == "response.completed" for e in events), "responses 流式：应有 response.completed 事件", errs)
    for i, e in enumerate(events):
        errs += check_gateway_fields(("POST", "/v1/responses"), e, f"responses 事件#{i}")


def t_usage(errs):
    key = ("GET", "/v1/magpie/usage")
    for period in ("today", "7d", "30d", "all"):
        r = call(f"gw-usage-{period}", "GET", GW + f"/v1/magpie/usage?period={period}", KEY)
        status_is(r, 200, "application/json", errs, f"GET /v1/magpie/usage?period={period}")
        errs += check_gateway_fields(key, r.json or {}, f"usage {period}")
        expect((r.json or {}).get("period") == period, f"usage {period}: period 应回显 {period}", errs)
    expect(((r.json or {}).get("calls") or 0) >= 1, "usage all: 种子调用后 calls 应 ≥ 1", errs)
    r = call("gw-usage-week", "GET", GW + "/v1/magpie/usage?period=week", KEY)
    expect((r.json or {}).get("period") == "30d", f"usage period=week 应回退为 30d（App 只应发送 today/7d/30d/all），实际 {(r.json or {}).get('period')!r}", errs)
    r = call("gw-usage-readonly", "GET", GW + "/v1/magpie/usage?period=today", RO)
    status_is(r, 200, "application/json", errs, "只读密钥 GET /v1/magpie/usage")
    rk = ("GET", "/v1/magpie/usage/requests")
    r = call("gw-usage-requests", "GET", GW + "/v1/magpie/usage/requests?period=all", KEY)
    status_is(r, 200, "application/json", errs, "GET /v1/magpie/usage/requests")
    errs += check_gateway_fields(rk, r.json or {}, "usage/requests")
    expect(len((r.json or {}).get("rows") or []) >= 1, "usage/requests: 应至少有一行", errs)
    r = call("gw-usage-requests-limit1", "GET", GW + "/v1/magpie/usage/requests?period=all&limit=1&offset=0", KEY)
    expect(len((r.json or {}).get("rows") or []) == 1, "usage/requests limit=1: 应恰好返回 1 行", errs)
    expect(((r.json or {}).get("total") or 0) >= 2, "usage/requests: total 应 ≥ 2（分页依赖它）", errs)
    # User-Agent 的首段（第一个 / 或空格之前）成为 rows[].agent，可用 ?agent= 筛选。
    # 注意：以 magpie 开头的名字（如 iOS 默认的 "MagpieRemote/1 CFNetwork/…"）会被前缀匹配成 magpie 自己，
    # 所以这里用一个不以 magpie 开头的名字。
    call("gw-chat-ua", "POST", GW + "/v1/chat/completions", KEY, headers={"User-Agent": "RemoteContract/1.0 (iOS)"},
         body={"model": "mock/mock-gpt-mini", "messages": [{"role": "user", "content": "ua"}]})
    r = call("gw-usage-requests-agent", "GET", GW + "/v1/magpie/usage/requests?period=all&agent=RemoteContract", KEY)
    rows = (r.json or {}).get("rows") or []
    expect(rows and all(x.get("agent") == "RemoteContract" for x in rows),
           f"usage/requests agent=RemoteContract: User-Agent 首段应成为 agent 并可按它筛选，实际 {[x.get('agent') for x in rows]}", errs)


def t_quotas_limit(errs):
    for name, path in (("gw-quotas", "/v1/magpie/quotas"), ("gw-quotas-kept", "/v1/magpie/quotas?kept=1"),
                       ("gw-quotas-cards", "/v1/magpie/quotas/cards"), ("gw-quotas-history", "/v1/magpie/quotas/history?days=7")):
        r = call(name, "GET", GW + path, KEY)
        status_is(r, 200, "application/json", errs, f"GET {path}")
        errs += check_gateway_fields(("GET", path.split("?")[0]), r.json or {}, path)
        expect((r.json or {}).get("object") == "list", f"{path}: object 应为 list", errs)
    r = call("gw-limit", "GET", GW + "/v1/magpie/limit", KEY)
    status_is(r, 200, "application/json", errs, "GET /v1/magpie/limit")
    errs += check_gateway_fields(("GET", "/v1/magpie/limit"), r.json or {}, "limit")
    expect((r.json or {}).get("limited") is False, "limit: 无限额密钥 limited 应为 false", errs)
    r = call("gw-concurrency", "GET", GW + "/v1/magpie/concurrency", KEY)
    status_is(r, 200, "application/json", errs, "GET /v1/magpie/concurrency")
    errs += check_gateway_fields(("GET", "/v1/magpie/concurrency"), r.json or {}, "concurrency")
    r = call("gw-me", "GET", GW + "/v1/magpie/me", KEY)
    status_is(r, 200, "application/json", errs, "GET /v1/magpie/me")
    errs += check_gateway_fields(("GET", "/v1/magpie/me"), r.json or {}, "me")


def t_keys(errs):
    r = call("err-keys-nonissuer", "GET", GW + "/v1/magpie/keys", KEY)
    error_envelope(r, 403, "permission_error", errs, "非签发密钥 GET /v1/magpie/keys")
    r = call("gw-keys-post", "POST", GW + "/v1/magpie/keys", ISSUER,
             body={"name": "contract-temp", "ttl": "1h", "models": ["mock/mock-gpt-1"], "tokens": 10000})
    status_is(r, 201, "application/json", errs, "POST /v1/magpie/keys")
    errs += check_gateway_fields(("POST", "/v1/magpie/keys"), r.json or {}, "keys POST")
    issued = (r.json or {}).get("key", "")
    kid = (r.json or {}).get("id", "")
    r = call("gw-keys-get", "GET", GW + "/v1/magpie/keys", ISSUER)
    status_is(r, 200, "application/json", errs, "GET /v1/magpie/keys")
    errs += check_gateway_fields(("GET", "/v1/magpie/keys"), r.json or {}, "keys GET")
    expect(any(k.get("id") == kid for k in (r.json or {}).get("keys") or []), "keys GET: 应列出刚签发的密钥", errs)
    if not issued:
        errs.append("keys POST 没有返回 key，跳过受限密钥用例")
        return
    # 受限（held）密钥
    r = call("held-models", "GET", GW + "/v1/models", issued)
    ids = [m.get("id") for m in (r.json or {}).get("data", [])]
    expect(ids == ["mock/mock-gpt-1"], f"受限密钥 /v1/models 只应列出允许的模型，实际 {ids}", errs)
    r = call("held-limit", "GET", GW + "/v1/magpie/limit", issued)
    status_is(r, 200, "application/json", errs, "受限密钥 GET /v1/magpie/limit")
    errs += check_gateway_fields(("GET", "/v1/magpie/limit"), r.json or {}, "held limit")
    expect((r.json or {}).get("limited") is True, "受限密钥 limit.limited 应为 true", errs)
    r = call("held-me", "GET", GW + "/v1/magpie/me", issued)
    errs += check_gateway_fields(("GET", "/v1/magpie/me"), r.json or {}, "held me")
    for name, path in (("err-held-usage", "/v1/magpie/usage"), ("err-held-quotas", "/v1/magpie/quotas"),
                       ("err-held-concurrency", "/v1/magpie/concurrency")):
        r = call(name, "GET", GW + path, issued)
        error_envelope(r, 403, "permission_error", errs, f"受限密钥 GET {path}", "gateway_key_held")
    r = call("held-usage-requests", "GET", GW + "/v1/magpie/usage/requests?period=today", issued)
    status_is(r, 200, "application/json", errs, "受限密钥 GET /v1/magpie/usage/requests")
    r = call("err-held-model", "POST", GW + "/v1/chat/completions", issued,
             body={"model": "mock/mock-gpt-mini", "messages": [{"role": "user", "content": "x"}]})
    error_envelope(r, 403, "permission_error", errs, "受限密钥用未授权模型 chat")
    r = call("gw-keys-delete", "DELETE", GW + f"/v1/magpie/keys/{kid}", ISSUER)
    status_is(r, 200, "application/json", errs, "DELETE /v1/magpie/keys/{id}")
    errs += check_gateway_fields(("DELETE", "/v1/magpie/keys/{id}"), r.json or {}, "keys DELETE")
    r = call("err-revoked-key", "GET", GW + "/v1/magpie/limit", issued)
    expect(r.status == 401, f"吊销后的密钥应得 401，实际 {r.status}", errs)


WEB_GETS = [("web-settings", "/api/settings", "/api/settings"), ("web-state", "/api/state", "/api/state"),
            ("web-agent-models-codex", "/api/agent-models/codex", "/api/agent-models/{id}"),
            ("web-providers", "/api/providers", "/api/providers"), ("web-groups", "/api/groups", "/api/groups"),
            ("web-caller-keys", "/api/caller-keys", "/api/caller-keys"),
            ("web-caller-keys-models", "/api/caller-keys/models", "/api/caller-keys/models"),
            # 主机工具：更新状态（不带 fresh，不访问发布源）、自动调优、本地脱敏模型
            ("web-update", "/api/update?lang=zh", "/api/update"), ("web-tune", "/api/tune?days=7", "/api/tune"),
            ("web-privacy-model", "/api/privacy-model", "/api/privacy-model")]


def t_web(errs):
    for name, path, route in WEB_GETS:
        r = call(name, "GET", WEB + path, remote=False, cookie=COOKIE)
        status_is(r, 200, "application/json", errs, f"web GET {path}")
        errs += check_web_fields(("GET", route), r.json or {}, f"web GET {path}")
        if path == "/api/settings":
            want = ENV.get("MAGPIE_VERSION", "")
            if want.startswith("v"):
                expect((r.json or {}).get("version") == want, f"web /api/settings: version 应为 {want}", errs)
            expect((r.json or {}).get("lan") is True, "web /api/settings: 共享已开启，lan 应为 true", errs)
        if path == "/api/state":
            ids = [a.get("id") for a in (r.json or {}).get("agents") or []]
            expect("codex" in ids and "claude" in ids, f"web /api/state: 应检测到 codex 与 claude，实际 {ids}", errs)
        if route == "/api/update":
            states = ["", "checking", "latest", "found", "downloading", "ready", "available", "source", "error", "blocked"]
            expect((r.json or {}).get("state") in states, f"web /api/update: 未知 state {(r.json or {}).get('state')!r}", errs)
        if route == "/api/tune":
            expect((r.json or {}).get("days") == 7, f"web /api/tune?days=7: days 应为 7，实际 {(r.json or {}).get('days')}", errs)
        if route == "/api/privacy-model":
            ids = [m.get("model") for m in (r.json or {}).get("models") or []]
            expect(set(ids) <= {"privacy-filter", "astrlink-guard"} and ids, f"web /api/privacy-model: 模型 id 应为 privacy-filter / astrlink-guard，实际 {ids}", errs)
        if path == "/api/caller-keys":
            names = [k.get("name") for k in (r.json or {}).get("keys") or []]
            expect("Magpie" in names, f"web /api/caller-keys: 开启共享后应有名为 Magpie 的 lan 密钥，实际 {names}", errs)
            expect(not any(k.get("secret") for k in (r.json or {}).get("keys") or []), "web /api/caller-keys: 不应返回完整密钥", errs)
    r = call("err-web-no-cookie", "GET", WEB + "/api/providers", remote=False)
    status_is(r, 401, "text/plain", errs, "web 无 cookie")
    r = call("err-web-wrong-cookie", "GET", WEB + "/api/providers", remote=False,
             cookie=f"magpie_web_{ENV['MAGPIE_WEB_PORT']}=wrongwrongwrongwrong")
    status_is(r, 401, "text/plain", errs, "web 错误 cookie")
    r = call("err-web-unknown-agent", "GET", WEB + "/api/agent-models/nosuchagent", remote=False, cookie=COOKIE)
    expect(r.status == 400, f"web 未知 agent 应得 400，实际 {r.status}", errs)


# Agent 会话记录：在隔离的 HOME 里放两个 Claude Code 会话文件（形状同 ~/.claude/projects/<目录>/<id>.jsonl）
SESSION_IDS = ("aaaaaaaa-1111-4222-8333-000000000001", "aaaaaaaa-1111-4222-8333-000000000002")


def _seed_claude_sessions() -> None:
    home = os.path.join(ENV.get("MAGPIE_FIXTURE_DIR") or "/tmp/magpie-fixture", "home")
    folder = os.path.join(home, ".claude", "projects", "-Users-example-demo")
    os.makedirs(folder, exist_ok=True)
    old = time.time() - 3 * 3600  # 最近一分钟写过的会话 magpie 拒绝删除
    for n, sid in enumerate(SESSION_IDS):
        lines = [
            {"type": "user", "message": {"role": "user", "content": f"Contract demo {n + 1}: fix the login button"},
             "uuid": f"u{n}", "parentUuid": None, "timestamp": f"2026-10-30T10:0{n}:00.000Z", "cwd": "/Users/example/demo", "sessionId": sid},
            {"type": "assistant", "message": {"model": "claude-sonnet-4-5", "id": f"msg_{n}", "type": "message", "role": "assistant",
             "content": [{"type": "text", "text": "Done: the button now uses the accent color."}],
             "usage": {"input_tokens": 120, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0, "output_tokens": 30}},
             "uuid": f"a{n}", "parentUuid": f"u{n}", "timestamp": f"2026-10-30T10:0{n}:05.000Z", "cwd": "/Users/example/demo", "sessionId": sid},
        ]
        path = os.path.join(folder, sid + ".jsonl")
        with open(path, "w", encoding="utf-8") as f:
            # 紧凑写法：magpie 按字节找 "type":"user"（不带空格），和 Claude Code 自己写的一样
            f.write("\n".join(json.dumps(l, ensure_ascii=False, separators=(",", ":")) for l in lines) + "\n")
        os.utime(path, (old, old))


def t_sessions(errs):
    """web Agent 会话记录：列表、对话、搜索、Markdown、导出、删除"""
    _seed_claude_sessions()
    q = lambda sid: f"agent=claude&id={sid}"
    r = call("web-sessions-reads", "POST", WEB + "/api/sessions/reads", remote=False, cookie=COOKIE, body={"all": True})
    status_is(r, 200, "application/json", errs, "web POST /api/sessions/reads")
    errs += check_web_fields(("POST", "/api/sessions/reads"), r.json or {}, "web POST /api/sessions/reads")
    expect((r.json or {}).get("asked") is True, "web /api/sessions/reads: 选过之后 asked 应为 true", errs)

    ids: list = []
    for _ in range(30):  # 第一次读会话文件可能要一会儿
        r = call("web-sessions-manage", "GET", WEB + "/api/sessions/manage?agent=claude", remote=False, cookie=COOKIE)
        ids = [s.get("id") for s in (r.json or {}).get("sessions") or []]
        pending = any(s.get("pending") for s in (r.json or {}).get("sessions") or [])
        if all(i in ids for i in SESSION_IDS) and not pending:
            break
        time.sleep(0.5)
    status_is(r, 200, "application/json", errs, "web GET /api/sessions/manage")
    errs += check_web_fields(("GET", "/api/sessions/manage"), r.json or {}, "web GET /api/sessions/manage")
    expect(all(i in ids for i in SESSION_IDS), f"web /api/sessions/manage: 应列出放进去的两个 Claude Code 会话，实际 {ids}", errs)
    expect((r.json or {}).get("agent") == "claude", f"web /api/sessions/manage: agent 应为 claude，实际 {(r.json or {}).get('agent')!r}", errs)
    claude = next((a for a in (r.json or {}).get("agents") or [] if a.get("agent") == "claude"), {})
    expect(claude.get("deletable") is True and (claude.get("count") or 0) >= 2, f"web /api/sessions/manage: claude 应可删除且至少 2 个会话，实际 {claude}", errs)
    for s in (r.json or {}).get("sessions") or []:
        for k in ("start", "last"):
            v = s.get(k)
            if isinstance(v, str) and not RFC3339.match(v):
                errs.append(f"web /api/sessions/manage: sessions[].{k} 不是 RFC3339：{v!r}")

    r = call("web-sessions", "GET", WEB + "/api/sessions", remote=False, cookie=COOKIE)
    status_is(r, 200, "application/json", errs, "web GET /api/sessions")
    errs += check_web_fields(("GET", "/api/sessions"), r.json or {}, "web GET /api/sessions")

    r = call("web-sessions-transcript", "GET", WEB + "/api/sessions/transcript?" + q(SESSION_IDS[0]), remote=False, cookie=COOKIE)
    status_is(r, 200, "application/json", errs, "web GET /api/sessions/transcript")
    errs += check_web_fields(("GET", "/api/sessions/transcript"), r.json or {}, "web GET /api/sessions/transcript")
    texts = [p.get("text", "") for p in (r.json or {}).get("parts") or []]
    expect(any("Contract demo 1" in t for t in texts), f"web /api/sessions/transcript: 应含用户的第一句话，实际 {texts[:3]}", errs)
    r = call("err-web-sessions-transcript-unknown", "GET", WEB + "/api/sessions/transcript?agent=claude&id=nosuchsession", remote=False, cookie=COOKIE)
    status_is(r, 400, "application/json", errs, "web GET /api/sessions/transcript 未知会话")
    expect(bool((r.json or {}).get("error")), "web /api/sessions/transcript 未知会话: 应有 error", errs)

    r = call("web-sessions-search", "GET", WEB + "/api/sessions/search?agent=claude&q=login%20button", remote=False, cookie=COOKIE)
    status_is(r, 200, "application/json", errs, "web GET /api/sessions/search")
    errs += check_web_fields(("GET", "/api/sessions/search"), r.json or {}, "web GET /api/sessions/search")
    hits = [h.get("id") for h in (r.json or {}).get("hits") or []]
    expect(SESSION_IDS[0] in hits, f"web /api/sessions/search: 应命中 {SESSION_IDS[0]}，实际 {hits}", errs)

    r = call("web-sessions-markdown", "GET", WEB + "/api/sessions/markdown?" + q(SESSION_IDS[0]), remote=False, cookie=COOKIE)
    status_is(r, 200, "text/markdown", errs, "web GET /api/sessions/markdown")
    expect("filename=" in (r.headers.get("Content-Disposition") or ""), f"web /api/sessions/markdown: 应有 Content-Disposition 文件名，实际 {r.headers.get('Content-Disposition')!r}", errs)
    expect("Contract demo 1" in r.text, "web /api/sessions/markdown: 正文应含对话", errs)

    r = call("web-sessions-export", "POST", WEB + "/api/sessions/export?" + q(SESSION_IDS[0]), remote=False, cookie=COOKIE)
    status_is(r, 200, "application/json", errs, "web POST /api/sessions/export")
    expect(str((r.json or {}).get("path", "")).endswith(".md"), f"web /api/sessions/export: path 应为 .md 文件，实际 {(r.json or {}).get('path')!r}", errs)

    r = call("web-sessions-delete", "POST", WEB + "/api/sessions/delete", remote=False, cookie=COOKIE, body={"agent": "claude", "ids": [SESSION_IDS[1]]})
    status_is(r, 200, "application/json", errs, "web POST /api/sessions/delete")
    errs += check_web_fields(("POST", "/api/sessions/delete"), r.json or {}, "web POST /api/sessions/delete")
    expect(SESSION_IDS[1] in ((r.json or {}).get("deleted") or []), f"web /api/sessions/delete: 应删除 {SESSION_IDS[1]}，实际 {r.json}", errs)
    r = call("web-sessions-delete-unknown", "POST", WEB + "/api/sessions/delete", remote=False, cookie=COOKIE, body={"agent": "claude", "ids": ["nosuchsession"]})
    status_is(r, 200, "application/json", errs, "web POST /api/sessions/delete 未知会话")
    expect(len((r.json or {}).get("refused") or []) == 1, f"web /api/sessions/delete 未知会话: 应在 refused 里，实际 {r.json}", errs)
    r = call("web-sessions-manage-after-delete", "GET", WEB + "/api/sessions/manage?agent=claude", remote=False, cookie=COOKIE)
    ids = [s.get("id") for s in (r.json or {}).get("sessions") or []]
    expect(SESSION_IDS[1] not in ids and SESSION_IDS[0] in ids, f"web /api/sessions/manage 删除后: 应只剩 {SESSION_IDS[0]}，实际 {ids}", errs)
    expect(any(t.get("id") == SESSION_IDS[1] for t in (r.json or {}).get("trash") or []), "web /api/sessions/manage 删除后: 回收站里应有删掉的会话", errs)


def t_plugins(errs):
    """「管理 › 插件」依赖的 web 接口：列表、内置插件开关与设置、检查更新、页面 / 面板、市场、插件供应商开关。不安装任何插件。"""
    def web(name, method, path, body=None):
        return call(name, method, WEB + path, remote=False, cookie=COOKIE, body=body)

    r = web("web-plugins", "GET", "/api/plugins")
    status_is(r, 200, "application/json", errs, "web GET /api/plugins")
    errs += check_web_fields(("GET", "/api/plugins"), r.json or {}, "web GET /api/plugins")
    expect(isinstance((r.json or {}).get("plugins"), list), "web /api/plugins: plugins 应为数组", errs)
    expect(isinstance((r.json or {}).get("bun"), bool), "web /api/plugins: bun 应为布尔", errs)

    r = web("web-plugins-builtin", "GET", "/api/plugins/builtin")
    status_is(r, 200, "application/json", errs, "web GET /api/plugins/builtin")
    builtins = r.json if isinstance(r.json, list) else []
    expect(bool(builtins), f"web /api/plugins/builtin: 应为非空数组，实际 {r.text[:120]}", errs)
    for b in builtins:
        for k, typ in (("id", str), ("name", str), ("on", bool), ("chosen", bool), ("state", str), ("inUse", int)):
            expect(isinstance(b.get(k), typ), f"web /api/plugins/builtin: {b.get('id')} 的 {k} 应为 {typ.__name__}", errs)
        if b.get("schema") is not None:
            expect(isinstance(b["schema"].get("properties"), dict), f"web /api/plugins/builtin: {b.get('id')} 的 schema.properties 应为对象", errs)
    expect("usage" in [b.get("id") for b in builtins], "web /api/plugins/builtin: 应有内置插件 usage", errs)

    # 开关一个没在使用的内置插件，再恢复原状
    # 只动只影响窗口的插件（会话、资源库、预热与签到），不碰网关路径上的
    free = next((b for b in builtins if b.get("id") in ("sessions", "library", "warmups") and not b.get("inUse") and not b.get("broken")), None)
    if free:
        was = bool(free.get("chosen"))
        r = web("web-plugins-builtin-switch", "POST", "/api/plugins/builtin", {"id": free["id"], "on": not was})
        status_is(r, 200, "application/json", errs, f"web POST /api/plugins/builtin 切换 {free['id']}")
        now = next((b for b in (r.json or []) if isinstance(b, dict) and b.get("id") == free["id"]), {})
        expect(now.get("chosen") == (not was), f"web /api/plugins/builtin: {free['id']} 的 chosen 应变为 {not was}", errs)
        r = web("web-plugins-builtin-restore", "POST", "/api/plugins/builtin", {"id": free["id"], "on": was})
        status_is(r, 200, "application/json", errs, f"web POST /api/plugins/builtin 恢复 {free['id']}")
    used = next((b for b in builtins if b.get("inUse")), None)
    if used:
        r = web("err-web-plugins-builtin-in-use", "POST", "/api/plugins/builtin", {"id": used["id"], "on": False})
        expect(r.status == 400 and "error" in (r.json or {}), f"web /api/plugins/builtin: 关闭正在使用的 {used['id']} 应得 400 JSON，实际 {r.status}", errs)
    withschema = next((b for b in builtins if b.get("schema")), None)
    if withschema:
        r = web("web-plugins-builtin-config", "POST", "/api/plugins/builtin", {"id": withschema["id"], "config": {}})
        status_is(r, 200, "application/json", errs, f"web POST /api/plugins/builtin config {withschema['id']}")
        r = web("err-web-plugins-builtin-config", "POST", "/api/plugins/builtin", {"id": withschema["id"], "config": {"no-such-setting": 1}})
        expect(r.status == 400, f"web /api/plugins/builtin: 不存在的设置应得 400，实际 {r.status}", errs)

    r = web("web-plugins-check", "POST", "/api/plugins/check", {})
    status_is(r, 200, "application/json", errs, "web POST /api/plugins/check")
    errs += check_web_fields(("POST", "/api/plugins/check"), r.json or {}, "web POST /api/plugins/check")
    expect(isinstance(((r.json or {}).get("state") or {}).get("plugins"), list), "web /api/plugins/check: state.plugins 应为数组", errs)

    for name, path in (("web-plugin-pages", "/api/plugin-pages"), ("web-plugin-panels", "/api/plugin-panels")):
        r = web(name, "GET", path)
        status_is(r, 200, "application/json", errs, f"web GET {path}")
        expect(isinstance(r.json, list), f"web {path}: 应为数组，实际 {r.text[:80]}", errs)
        for e in r.json if isinstance(r.json, list) else []:
            expect(isinstance(e.get("key"), str) and isinstance(e.get("url"), str), f"web {path}: 每项应有 key 与 url", errs)

    # 市场是第三方的列表（包名、作者、链接），只校验形状，不留抓取文件
    r = web("web-plugins-listings", "GET", "/api/plugins/listings")
    status_is(r, 200, "application/json", errs, "web GET /api/plugins/listings")
    ls = (r.json or {}).get("listings")
    expect(isinstance(ls, list), "web /api/plugins/listings: listings 应为数组", errs)
    for l in ls if isinstance(ls, list) else []:
        expect(isinstance(l.get("package"), str) and isinstance(l.get("name"), str), "web /api/plugins/listings: 每项应有 package 与 name", errs)
    r2 = web("web-plugins-agents", "GET", "/api/plugins/agents")
    status_is(r2, 200, "application/json", errs, "web GET /api/plugins/agents")
    expect(isinstance(r2.json, list) and all(isinstance(x, str) for x in r2.json), "web /api/plugins/agents: 应为字符串数组", errs)
    for name in ("web-plugins-listings", "web-plugins-agents"):
        try:
            os.remove(os.path.join(CAP, name + ".json"))
        except OSError:
            pass

    # 不存在的插件：操作被拒，400 JSON
    for op, body in (("off", {"spec": "example-no-such-plugin", "off": True}), ("options", {"spec": "example-no-such-plugin", "options": {"a": 1}}),
                     ("remove", {"spec": "example-no-such-plugin"})):
        r = web(f"err-web-plugins-{op}", "POST", f"/api/plugins/{op}", body)
        expect(r.status == 400 and "no plugin" in str((r.json or {}).get("error", "")),
               f"web /api/plugins/{op}: 不存在的插件应得 400 JSON「no plugin…」，实际 {r.status} {r.text[:120]}", errs)

    r = web("web-providers-plugins", "GET", "/api/providers")
    expect(isinstance((r.json or {}).get("plugins"), list), "web /api/providers: plugins（插件供应商）应为数组", errs)
    r = web("web-plugin-option", "POST", "/api/settings/plugin-option", {"provider": "example", "key": "fast-mode", "on": True})
    status_is(r, 200, "application/json", errs, "web POST /api/settings/plugin-option")
    errs += check_web_fields(("GET", "/api/settings"), r.json or {}, "web POST /api/settings/plugin-option")
    r = web("err-web-plugin-option", "POST", "/api/settings/plugin-option", {"provider": "example", "key": "Not A Key!"})
    expect(r.status == 400, f"web /api/settings/plugin-option: 不合法的 key 应得 400，实际 {r.status}", errs)


def t_sharing_off(errs):
    """最后执行：通过 web API 关掉共享，确认远程请求得到纯文本 403，再打开。"""
    r = call("web-lan-off", "POST", WEB + "/api/settings/lan", remote=False, cookie=COOKIE, body={"On": False})
    status_is(r, 200, "application/json", errs, "web POST /api/settings/lan 关闭")
    errs += check_web_fields(("GET", "/api/settings"), r.json or {}, "web POST /api/settings/lan 关闭")
    time.sleep(0.5)
    r = call("err-not-shared-proxied", "GET", GW + "/v1/models", KEY)
    status_is(r, 403, "text/plain", errs, "未共享时的远程请求")
    r = call("web-lan-on", "POST", WEB + "/api/settings/lan", remote=False, cookie=COOKIE, body={"On": True})
    status_is(r, 200, "application/json", errs, "web POST /api/settings/lan 打开")
    time.sleep(0.5)
    r = call("gw-after-reshare", "GET", GW + "/v1", KEY)
    status_is(r, 200, "application/json", errs, "重新共享后 GET /v1")


TESTS = [t_info, t_auth, t_models, t_chat, t_responses, t_usage, t_quotas_limit, t_keys, t_web, t_sessions, t_plugins, t_sharing_off]


def main() -> int:
    for t in TESTS:
        errs: list[str] = []
        try:
            t(errs)
        except Exception:
            errs.append("异常：" + traceback.format_exc(limit=3))
        name = (t.__doc__ or t.__name__).strip().splitlines()[0] if t.__doc__ else t.__name__
        if errs:
            FAILS.append({"test": t.__name__, "errors": errs})
            print(f"✗ {name}")
            for e in errs:
                print(f"    - {e}")
        else:
            PASSED.append(t.__name__)
            print(f"✓ {name}")
    with open(os.path.join(CAP, "INDEX.tsv"), "w", encoding="utf-8") as f:
        f.write("file\tstatus\tcontent_type\trequest\n" + "\n".join(INDEX) + "\n")
    report = {"magpie_version": ENV.get("MAGPIE_VERSION"), "passed": PASSED, "failed": FAILS}
    json.dump(report, open(os.path.join(CAP, "report.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    md = [f"### 实时契约测试（magpie {ENV.get('MAGPIE_VERSION', '?')}）", "",
          f"通过 {len(PASSED)} 组，失败 {len(FAILS)} 组。", ""]
    for fl in FAILS:
        md.append(f"- **{fl['test']}**")
        md += [f"  - {e}" for e in fl["errors"][:40]]
        if len(fl["errors"]) > 40:
            md.append(f"  - …另有 {len(fl['errors']) - 40} 条")
    open(os.path.join(CAP, "report.md"), "w", encoding="utf-8").write("\n".join(md) + "\n")
    print(f"\n通过 {len(PASSED)}，失败 {len(FAILS)}；响应保存在 {CAP}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    raise SystemExit(main())
