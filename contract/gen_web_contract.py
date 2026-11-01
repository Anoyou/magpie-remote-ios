#!/usr/bin/env python3
"""Writes spec/web-contract.json (the routes/fields Magpie Remote relies on in magpie's web-page API)
and, with --check <magpie checkout>, verifies every anchor/action/json tag still exists there.
Exit 1 on drift. Used for the weekly CI diff against new magpie releases."""
import json, os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
G = "internal/gui/"

def R(method, path, file, actions=None, req=None, res=None, tags=None, note=None, contains=None):
    d = {"method": method, "path": path, "source": file,
         "anchor": f'mux.HandleFunc("{method} {path}"', "actions": actions or [],
         "fields": {"request": req or [], "response": res or []}}
    if tags: d["goTags"] = tags          # [{file, tags[]}] json tags that must exist
    if note: d["note"] = note
    if contains: d["contains"] = contains  # source snippets the App relies on (values that aren't `case "x"`)
    return d

PROVIDER_RES = ["providers[].id","providers[].name","providers[].icon","providers[].preset","providers[].host","providers[].chat","providers[].responses","providers[].anthropic","providers[].gemini?","providers[].baseAPI?","providers[].headers?","providers[].proxy","providers[].key.set","providers[].key.masked","providers[].key.optional","providers[].ready","providers[].off","providers[].chosen","providers[].fallback","providers[].routing","providers[].affinity","providers[].models[].id","providers[].models[].name","providers[].models[].on","providers[].models[].context?","providers[].models[].efforts?","providers[].models[].images","providers[].exposed","providers[].noModels","providers[].bestInFamily","providers[].fetched?","providers[].listError?","providers[].agents[].id","providers[].agents[].current","providers[].agents[].model?","providers[].keyList[].id","providers[].keyList[].name?","providers[].keyList[].masked","providers[].keyList[].active","providers[].keyList[].on","providers[].account?.agent","providers[].account?.user","providers[].account?.plan?","providers[].account?.agentName","presets[].id","gateway.url","gateway.lan","gateway.lanURLs?","gateway.running","gateway.version?","gateway.models","moved?","added?","had?","removed?","plugins[].pid","plugins[].name","plugins[].spec","plugins[].options[]?.key","plugins[].options[]?.label","plugins[].options[]?.on"]
PROVIDER_TAGS = [
 {"file": G+"plugins.go", "tags": ["id","pid","name","icon","spec","methods","signedIn","models","options","on"]},
 {"file": "internal/plugin/providers.go", "tags": ["key","label","description","default","confirm"]},
 {"file": G+"providers.go", "tags": ["providers","presets","excluded","gateway","moved","added","had","removed","id","name","icon","preset","host","chat","responses","anthropic","gemini","baseAPI","headers","proxy","key","set","masked","optional","ready","off","chosen","fallback","routing","affinity","models","on","context","efforts","images","exposed","noModels","bestInFamily","fetched","listError","agents","current","model","keyList","account","agentName","url","lan","lanURLs","running","version"]},
 {"file": "internal/provider/keys.go", "tags": ["id","name","masked","active","on","protocol","weight","plan","rest"]},
 {"file": "internal/provider/account.go", "tags": ["agent","user","plan"]},
 {"file": "internal/provider/provider.go", "tags": ["id","name","preset","key","chat","responses","anthropic","gemini","baseAPI","fallback","routing","affinity","headers","models","noModels","bestInFamily","off","proxy","keepLogin","keepLoginAs"]},
]
PROV_ACTIONS = ["show","move","adopt","moveback","quiet","tuck","untuck","forget","keychain-retry","save","key","name","efforts","images","arrange","accountmodels","accountcap","accountname","windowcap","accountconcurrency","accountweight","route","off","on","keeplogin","switchonly","capstop","capcareful","affinity","sink","delete","teststop","test","detect","balance","unfetch","list","models"]
PROV_REQ_TAGS = ["proxy","insecureTLS","limitRestOff","maxConcurrency","queueLimit","queueWait","maxRPM","limit","rateWindows","priceRate","accountOrder","new","clearBalanceToken","accessKeyID","clearAccessKey","from","copyOf","model","modelName","efforts","images","modelPrefs","outputs","compacts","routing","affinity","sink","nativeCompaction","authHeader","test","as","run","detectModels","picked","account","allow","cap","window","weight","alias","typed","base","noModels","bestInFamily"]
GROUP_ACTIONS = ["found","skip","save","delete","show","copy","share","import","template","switch","arrange","pick"]
KEYS_ACTIONS = ["add","import","protocol","weight","plan","use","remove","remove-many","rename","replace","on","off"]
CK_ACTIONS = ["add-key","rotate-key","rename-key","limit-key","reset-limit-key","models-key","accounts-key","quotas-key","issuer-key","access-key","on-key","off-key","remove-key","move-key","copy-key"]
AGENT_ACTIONS = ["reapply","keep","connect","disconnect"]
# a sessions.Session as /api/sessions and /api/sessions/manage list it (internal/sessions/sessions.go)
SESSION_ROW = lambda p: [p+x for x in ["agent","id","cwd","title","nickname?","start","last","models","input","output","cache_read","cache_write","cost","unpriced","path","transcript?","subagents?","gateway?","model_effort?","via?"]]
SESSION_TAGS = [{"file":"internal/sessions/sessions.go","tags":["read_only","gateway","agent","id","cwd","title","nickname","start","last","role","model_effort","models","cost","unpriced","resume","path","transcript","subagents","input","output","cache_read","cache_write","model","effort","priced"]},
 {"file":"internal/sessions/subagents.go","tags":["id","title","kind","last"]},
 {"file":"internal/usage/usage.go","tags":["provider","model","calls","tokens"]}]

UPDATE_STATES = ["checking","latest","found","downloading","ready","available","source","error","blocked"]
UPDATE_RES = ["state","current","latest?","notes?","url?","stuck?","stuckDir?","packaged?.manager","packaged?.command?","retry?","mirror?","network?","error?","done?","total?","size?","blocked?.version","blocked?.error","busy?.requests","busy?.tools","waiting?","gaveUp?","handover?"]
UPDATE_TAGS = [{"file":G+"update.go","tags":["state","current","latest","notes","url","stuck","stuckDir","packaged","retry","mirror","network","error","done","blocked","total","size","busy","waiting","gaveUp","handover","manager","package","command"]},
 {"file":"internal/update/blocked.go","tags":["version","error","policy"]},{"file":"internal/gateway/busy.go","tags":["requests","tools"]}]
TUNE_TAGS = [{"file":G+"tune.go","tags":["knob","model","setting","compact","ttl","own","async","percent","value","window","held","days","agents","agent","calls","advice"]},
 {"file":"internal/agent/tune.go","tags":["value","source","locked","ours"]},
 {"file":"internal/tune/tune.go","tags":["model","current","window","best","cost","low","curve","facts","wait","wait_best","cheapest","wait_cheapest","short","hour","calls","streams","compacts","peak","after","growth","rework","long","quick","pause","away","sessions","took","timed"]},
 {"file":"internal/agent/codex_async.go","tags":["kind","version"]}]
PM_RES = ["on","chosen?","model","supported","installed","size","downloading?","done?","total?","error?","running?","device?","via?","gpu?","gpuError?","failed?","minScore","defaultScore","models[].model","models[].supported","models[].installed","models[].size"]
PM_TAGS = [{"file":G+"privacymodel.go","tags":["on","chosen","minScore","defaultScore","models"]},
 {"file":"internal/pii/pii.go","tags":["model","supported","installed","size","downloading","done","total","error","running","device","via","gpu","loadMs","gpuError","failed","loading","waiting"]}]

PLUGIN_OPS = ["add","remove","update","upgrade","off","options","prefer"]
PLUGINS_RES = ["plugins[].spec","plugins[].off?","plugins[].options?","plugins[].error?","plugins[].providers","plugins[].version?","plugins[].latest?","plugins[].icon?","plugins[].package?","plugins[].ownName?","plugins[].commit?","plugins[].head?","plugins[].optionsExample?","plugins[].isMiddleware?","plugins[].isGateway?","plugins[].isAgent?","plugins[].page?.title?","plugins[].page?.reads","plugins[].panels[]?.slot","plugins[].tools[]?.name","bun","bunVersion","error?","mirror"]
PLUGINS_TAGS = [
 {"file": G+"plugins.go", "tags": ["plugins","bun","bunVersion","error","mirror","providers","version","latest","icon","package","ownName","commit","head","optionsExample","isMiddleware","isGateway","isAgent","page","panels","tools","title","reads","slot","name","listings","npm"]},
 {"file": "internal/plugin/store.go", "tags": ["spec","off","options"]},
]

routes = [
 R("GET","/api/settings",G+"api.go", res=["version","gateway","lan?","port?","lanURLs?","lanPublic?","publicURL?","onNetwork?","addrEnv?","allowIPs?","lanKeyId?","disabledModels?","web?","gatewayOn?","dir"],
   tags=[{"file":G+"api.go","tags":["version","dir","gateway","lanURLs","lanPublic","publicURL","onNetwork","addrEnv","web","gatewayOn"]},{"file":"internal/settings/settings.go","tags":["lan","port","allowIPs","lanKeyId","disabledModels","corsOrigins"]}]),
 R("GET","/api/update",G+"update.go", res=UPDATE_RES, tags=UPDATE_TAGS, note="?fresh=1 asks the feed again when stale; ?lang=zh for Chinese notes",
   contains=['r.URL.Query().Get("fresh") == "1"', 'updates.jsonIn(askedLang(r))'] + ['"%s"' % s for s in UPDATE_STATES]),
 R("POST","/api/update/check",G+"update.go", res=["<updateJSON>"], contains=["updates.check()"]),
 R("GET","/api/update/notes",G+"update.go", res=["latest?","releases[].version","releases[].notes","releases[].url?","releases[].pending?","error?"],
   tags=[{"file":G+"update.go","tags":["latest","releases","error"]},{"file":"internal/update/notes.go","tags":["version","notes","url","pending"]}]),
 R("POST","/api/update/install",G+"update.go", req=["when?"], res=["<updateJSON>","204 = restarting"],
   tags=[{"file":G+"update.go","tags":["view","when"]}],
   contains=['in.When == "cancel"', 'in.When != "now"', 'rw.WriteHeader(http.StatusNoContent)', 'j.State == "error" && j.Retry, j.State == "found"', 'j.State == "available" && j.URL != ""'],
   note="found/error+retry: starts the download; ready: 204 then the host restarts (busy: waits unless when=now); available: opens the release page on the Mac only, so the App never sends it"),
 R("GET","/api/tune",G+"tune.go", res=["days","agents[].agent","agents[].calls","agents[].advice[].knob","agents[].advice[].model?","agents[].advice[].setting.value?","agents[].advice[].setting.source?","agents[].advice[].setting.locked?","agents[].advice[].setting.ours?","agents[].advice[].compact?.current","agents[].advice[].compact?.window","agents[].advice[].compact?.best","agents[].advice[].compact?.cost","agents[].advice[].compact?.low","agents[].advice[].compact?.curve","agents[].advice[].compact?.facts","agents[].advice[].ttl?.current","agents[].advice[].ttl?.best","agents[].advice[].ttl?.cost","agents[].advice[].ttl?.low","agents[].advice[].own?.model","agents[].advice[].async?.percent"],
   tags=TUNE_TAGS, contains=['days <= 0 || days > 30', 'for _, name := range []string{"claude", "codex"}'], note="?days=1..30 (else 7)"),
 R("POST","/api/tune/apply",G+"tune.go", req=["agent","knob","model","value"], res=["<agent.TuneSetting>"], tags=[{"file":"internal/agent/tune.go","tags":["value","source","locked","ours"]}],
   contains=["Agent, Knob, Model, Value string"], note="untagged struct; knob compact|cache_ttl|subagent_cache_ttl|async_compact"),
 R("POST","/api/tune/undo",G+"tune.go", req=["agent","knob","model"], res=["<agent.TuneSetting>"], contains=["agent.TuneUndo(\"\", in.Agent, in.Knob, in.Model)"]),
 R("GET","/api/privacy-model",G+"privacymodel.go", res=PM_RES, tags=PM_TAGS),
 R("POST","/api/privacy-model",G+"privacymodel.go", actions=["pick","score","on","off","cancel","remove"], req=["do","model?","score?"], res=["<privacyModelJSON>"],
   tags=[{"file":G+"privacymodel.go","tags":["do","model","score"]}],
   contains=['in.Model != pii.PrivacyFilter && in.Model != pii.AstrLinkGuard', 'in.Score >= pii.Floor && in.Score < 1',
             {"file": "internal/pii/pii.go", "contains": ['PrivacyFilter = "privacy-filter"', 'AstrLinkGuard = "astrlink-guard"', 'const Floor = guard.Floor']},
             {"file": "internal/pii/guard/guard.go", "contains": ["const Floor = 0.5"]}], note="model must be privacy-filter or astrlink-guard; score 0 = model default"),
 R("GET","/api/state",G+"api.go", res=["agents[].id","agents[].name","agents[].icon","agents[].path","agents[].fields[].key","agents[].fields[].label","agents[].fields[].value","agents[].fields[].options[].value","agents[].fields[].options[].label?","agents[].fields[].options[].note","agents[].fields[].options[].group?","agents[].fields[].options[].ref?","agents[].fields[].options[].context?","agents[].wired?","agents[].models?.shown","agents[].models?.listed","agents[].drift?","agents[].cliMissing?","clients[].id","settings","served","notice?","connected?.how"],
   tags=[{"file":G+"api.go","tags":["agents","clients","profiles","settings","served","notice","connected","fields","key","label","value","options","wired","drift","cliMissing","path"]},{"file":"internal/agent/agent.go","tags":["value","label","note","icon","icons","group","ref","context"]},{"file":G+"agent_models.go","tags":["shown","listed","by","names"]},{"file":"internal/agent/applied.go","tags":["how","field","value"]}]),
 R("POST","/api/set",G+"api.go", req=["agent","field","value"], res=["<stateJSON>","notice?"], note="untagged struct{ Agent, Field, Value string }; this is how an agent's model is switched"),
 R("POST","/api/agents/rescan",G+"api.go", res=["<stateJSON>"]),
 R("POST","/api/agents/{action}/{id}",G+"api.go", actions=AGENT_ACTIONS, res=["<stateJSON>","notice?","connected?"]),
 R("GET","/api/agent-models/{id}",G+"agent_models.go", res=["models[].id","models[].name","models[].group","models[].icon?","models[].icons?","models[].logo?","models[].context?","models[].hidden?","models[].inUse?","models[].own?","ordered","only","ownHidden"],
   tags=[{"file":G+"agent_models.go","tags":["id","name","group","icon","icons","logo","context","hidden","inUse","own","shown","listed","by","names","n"]}]),
 R("POST","/api/agent-models/{id}",G+"agent_models.go", req=["hidden?","shown?","order?","only?","ownHidden?"], res=["models[]","count?","only?","ordered?","ownHidden?"], note="untagged struct; send exactly one of the fields"),
 R("GET","/api/providers",G+"providers.go", res=PROVIDER_RES, tags=PROVIDER_TAGS, note="query ?wait, ?last=1"),
 R("POST","/api/provider/{action}",G+"providers.go", actions=PROV_ACTIONS, req=["id","<provider.Provider fields>"]+PROV_REQ_TAGS, res=["<providersJSON>","key (action key)","results (test/detect)","provider (test/models)","count (models)","dropped? (models)","models[].id (list)","ok,amount,error? (balance)"],
   tags=[{"file":G+"providers.go","tags":PROV_REQ_TAGS+["results","provider","count","dropped"]}]),
 R("POST","/api/providers/arrange",G+"providers.go", req=["order"], res=["<providersJSON>"]),
 R("POST","/api/keys/{action}",G+"providers.go", actions=KEYS_ACTIONS, req=["id","key","name","ref","refs","protocol","weight","plan"], res=["<providersJSON>","moved?","added?","had?","removed?"], note="untagged struct"),
 R("POST","/api/settings/disabled-models",G+"api.go", req=["models"], res=["<settingsJSON>"]),
 R("GET","/api/groups",G+"groups.go", res=["groups[].id","groups[].name","groups[].members","groups[].routing?","groups[].affinity?","groups[].pick?","groups[].disabled?","groups[].hidden?","groups[].ready","groups[].memberInfo[].id","groups[].memberInfo[].ready","groups[].memberInfo[].provider?","groups[].memberInfo[].name?","groups[].memberInfo[].model?","groups[].memberInfo[].on","groups[].picked?","groups[].ref","groups[].sink?","groups[].firstToken?","groups[].patience?","groups[].off?","groups[].weights?","groups[].fast?","groups[].match?","groups[].matched?","groups[].unlists?","groups[].rules?","groups[].classifier?","groups[].patterns[].pattern","groups[].patterns[].models","groups[].memberInfo[].of?","groups[].memberInfo[].effort?","groups[].memberInfo[].group?","groups[].memberInfo[].providerOff?","groups[].memberInfo[].canFast?","groups[].memberInfo[].context?","groups[].memberInfo[].images?","groups[].memberInfo[].imagesUnknown?","pools[].provider","pools[].name","pools[].kind","pools[].who","pools[].routing","pools[].affinity","models[].id","models[].name","models[].provider","models[].providerName","found","skip","templates[].kind","moved?","shared?","imported?"],
   tags=[{"file":G+"groups.go","tags":["groups","models","pools","deciders","found","skip","skippable","moved","templates","clock","shared","imported","ready","memberInfo","holds","offers","picked","patterns","ref","provider","providerName","on","from","order","ids","kind","text","who","sink","protocol","group","providerOff","of","effort","canFast","context","images","imagesUnknown","classifierFailed"]},{"file":"internal/provider/group.go","tags":["id","name","members","routing","affinity","pick","disabled","hidden","off","weights","sink","firstToken","patience","fast","match","matched","placed","unlists","rules","classifier","auto"]},{"file":"internal/provider/groupmatch.go","tags":["pattern","models"]}]),
 R("POST","/api/groups/{action}",G+"groups.go", actions=GROUP_ACTIONS, req=["id","name","members","placed?","routing?","affinity?","sink?","off?","weights?","fast?","firstToken?","patience?","unlists?","pick?","from?","on?","skip?","order?","ids?","kind?","text?"], res=["<groupsJSON>"]),
 R("GET","/api/model-speeds",G+"speeds.go", res=[], tags=[{"file":G+"speeds.go","tags":["ttft","tps","n"]}],
   note="map provider/model → {ttft ms?, tps?, n}; the Routing page shows each group member's speed"),
 R("GET","/api/gateway/trace",G+"trace.go", res=["seq","routes[].id","routes[].seq","routes[].agent","routes[].model","routes[].provider","routes[].order[].id","routes[].order[].provider","routes[].order[].name","routes[].order[].kind","routes[].order[].model","routes[].order[].routing","routes[].order[].used","routes[].tries[].id","routes[].tries[].start","routes[].tries[].done","routes[].done","routes[].cost","routes[].priced","totals.requests","totals.rerouted","totals.errors","mine","now"],
   tags=[{"file":"internal/gateway/trace.go","tags":["seq","id","time","agent","model","provider","group","order","tries","done","status","error","ms","ttft","tokens","out","kind","name","routing","members","who","plan","fixed","fast","fallback","known","used","balance","unit","free","rest","unlisted","window","credits","usedRenews","renews","start","fail","again","routes","totals","ids","requests","rerouted","errors"]},
         {"file":G+"trace.go","tags":["mine","now","routes","sessionTitle","cost","priced"]},{"file":"internal/gateway/routing.go","tags":["why","status","until"]}],
   note="query ?after=<seq>[&wait=1] (long poll ≤25 s); the live Routing stage. Gateway /v1/magpie/trace is loopback-only"),
 R("GET","/api/caller-keys",G+"caller_keys.go", res=["keys[].id","keys[].name","keys[].off?","keys[].lan?","keys[].masked?","keys[].limit?.period","keys[].limit?.cost?","keys[].limit?.tokens?","keys[].moreLimits?","keys[].models?","keys[].accounts?","keys[].readOnly?","keys[].expires?","keys[].used?.reset","keys[].used?.costLeft","keys[].used?.tokensLeft","keys[].used?.spent","keys[].usedAll?","accountNames"],
   tags=[{"file":"internal/access/access.go","tags":["id","name","off","lan","secret","masked","limit","moreLimits","models","accounts","quotas","readOnly","expires","issuer","issues","key","index"]},{"file":"internal/access/limit.go","tags":["period","days","hours","tokens","cost","cacheReads","since"]},{"file":"internal/budget/budget.go","tags":["period","start","reset","calls","tokens","cost","tokenLimit","costLimit","tokensLeft","costLeft","spent"]},{"file":G+"caller_keys.go","tags":["used","usedAll"]}]),
 R("GET","/api/caller-keys/models",G+"caller_keys.go", res=["models[].id","models[].name","models[].provider?","models[].providerName?","models[].group?","accounts[].id","accounts[].account?","accounts[].key?","accounts[].plan?"], tags=[{"file":G+"caller_keys.go","tags":["id","name","provider","providerName","group","account","key","plan"]}]),
 R("POST","/api/caller-keys/{action}",G+"caller_keys.go", actions=CK_ACTIONS, req=["key","name","limit?","index?","models?","accounts?","quotas?","readOnly?","issues?","secret?"], res=["keys","accountNames","secret"], note="actions are cases in internal/access/access.go Update()"),
 R("POST","/api/settings/lan",G+"api.go", req=["on","newKey"], res=["<settingsJSON>","rekeyed?"], note="untagged struct{ On, NewKey bool }"),
 R("POST","/api/settings/port",G+"api.go", req=["port"], res=["settings","port.port","port.moved?","port.error?"], tags=[{"file":G+"port.go","tags":["port","moved","error"]}]),
 R("POST","/api/signin",G+"providers.go", req=["agent","site?","proxy?","user?"], res=["id","agent","url","code?","state","pasteCallback?","user?","error?","openError?","linkOnly?"], tags=[{"file":"internal/provider/signin.go","tags":["id","agent","url","code","state","pasteCallback","user","error"]}], note="WKWebView flow; listed for reference"),
 R("GET","/api/signin/{id}",G+"providers.go", res=["<SignInState>"]),
 R("POST","/api/backup/import",G+"backup.go", req=["data","pass","agents","library?"], note="WKWebView flow; listed for reference"),
 R("GET","/api/usage/quotas",G+"usage.go", note="duplicates gateway /v1/magpie/*; reference only"),
 # ---- Agent 会话记录（管理 → Agent 会话记录）
 R("GET","/api/sessions",G+"sessions.go", res=SESSION_ROW("sessions[].")+["sessions[].name","sessions[].icon","terminal","dirs"],
   tags=SESSION_TAGS, note="every agent's sessions merged, newest first; reference only (the app lists per agent via /api/sessions/manage)"),
 R("GET","/api/sessions/manage",G+"sessions_manage.go",
   res=["agents[].agent","agents[].count","agents[].deletable","agents[].name","agents[].icon","agent"]+SESSION_ROW("sessions[].")+["sessions[].size","sessions[].messages","sessions[].files","sessions[].deletable","sessions[].pending?","trash","trashDir","recording","recorded","reads.asked","reads.all","reads.found[].agent","reads.found[].name","reads.found[].on"],
   tags=SESSION_TAGS+[{"file":G+"sessions_manage.go","tags":["agents","agent","sessions","terminal","trash","trashDir","home","recording","recorded","reads"]},{"file":"internal/sessions/manage.go","tags":["agent","count","deletable","size","messages","files","pending","key","deleted"]},{"file":G+"sessions_reads.go","tags":["asked","all","found","agent","name","on"]}],
   note="?agent= picks the agent listed (else the one with the most sessions); fresh installs read no agent until POST /api/sessions/reads"),
 R("GET","/api/sessions/transcript",G+"sessions.go", req=["?agent","?id","?sub"], res=["parts[].role","parts[].kind","parts[].text","parts[].name?","parts[].cut?","parts[].model?","cut?"],
   tags=[{"file":"internal/sessions/transcript.go","tags":["parts","cut"]},{"file":"internal/sessions/content.go","tags":["role","kind","name","text","cut","model"]}], note="400 {error} for an unknown session or an agent whose conversations can't be read"),
 R("GET","/api/sessions/search",G+"sessions_manage.go", req=["?agent","?q (>=2 runes)"], res=["hits[].id","hits[].role","hits[].kind","hits[].before","hits[].match","hits[].after","searched","total","cut?","unread?"],
   tags=[{"file":G+"sessions_manage.go","tags":["hits","searched","total","cut","unread","id"]},{"file":"internal/sessions/search.go","tags":["role","kind","before","match","after"]}]),
 R("GET","/api/sessions/markdown",G+"sessions.go", req=["?agent","?id"], res=["<text/markdown body; Content-Disposition attachment filename>"], note="the app shares this file through the iOS share sheet"),
 R("POST","/api/sessions/export",G+"sessions.go", req=["?agent","?id"], res=["path"], note="saves the same Markdown into the host's Downloads folder; untagged map {path}"),
 R("POST","/api/sessions/delete",G+"sessions_manage.go", req=["agent","ids"], res=["deleted","refused[].id","refused[].error","refused[].active"],
   tags=[{"file":G+"sessions_manage.go","tags":["agent","ids","deleted","refused","id","error","active"]}], note="moves into magpie's trash; a session written to in the last minute is refused with active=true"),
 R("POST","/api/sessions/reads",G+"sessions_reads.go", req=["all?","agents"], res=["asked","all","found[].agent","found[].name","found[].on"],
   tags=[{"file":G+"sessions_reads.go","tags":["all","agents","asked","found","on"]}]),

 # 「管理 › 插件」（PR feat/plugins）
 R("GET","/api/plugins",G+"plugins.go", res=PLUGINS_RES, tags=PLUGINS_TAGS),
 R("POST","/api/plugins/{op}",G+"plugins.go", actions=PLUGIN_OPS, req=["spec","off?","options?","provider?"], res=["<pluginsJSON>"],
   note="untagged struct{ Spec string; Off bool; Options map[string]any; Provider string }; options replaces the whole map; add/update/upgrade may take minutes (Bun download, npm install)"),
 R("POST","/api/plugins/check",G+"plugins.go", res=["at","plugins[].spec","plugins[].package","plugins[].version","plugins[].status","plugins[].latest?","plugins[].why?","plugins[].error?","state"],
   tags=[{"file":"internal/plugin/updates.go","tags":["at","plugins","spec","package","version","latest","status","commit","head","why","error","limited","auto"]}], note="asks npm now; installs nothing"),
 R("GET","/api/plugins/builtin",G+"builtins.go", res=["<[]builtinJSON>"],
   tags=[{"file":G+"builtins.go","tags":["id","name","sub","on","chosen","source","state","why","inUse","use","parts","schema","config","broken"]},{"file":"internal/pluginrt/schema.go","tags":["type","properties","x-order","title","description","enum","minimum","maximum","default"]}],
   note="a JSON array; each: id, name (English), sub, on, chosen, state (off|pending|active|failed|disposed), inUse, schema?, config?"),
 R("POST","/api/plugins/builtin",G+"builtins.go", req=["id","on?","config?"], res=["<[]builtinJSON>"], note="exactly one of on / config; config is merged after schema validation; one in use is refused off"),
 R("GET","/api/plugins/listings",G+"plugins.go", res=["listings[].package","listings[].name","listings[].kind?","listings[].summary?","listings[].npm?"],
   tags=[{"file":"internal/plugin/market.go","tags":["package","name","icon","providers","community","replaces","kind","summary","version","description","weekly"]}]),
 R("GET","/api/plugins/agents",G+"plugins.go", res=["<[]string>"], note="names of agent plugins in the market that are not installed"),
 R("GET","/api/plugin-pages",G+"pluginpage.go", res=["<[]pluginPage>"],
   tags=[{"file":G+"pluginpage.go","tags":["spec","name","key","title","titles","url","icon","replaces","reads","slot"]}],
   note="a JSON array; open a page in the web shell as /?view=<key> (the page file itself expects the window's bridge)"),
 R("GET","/api/plugin-panels",G+"pluginpage.go", res=["<[]pluginPanel>"]),
 R("POST","/api/settings/plugin-option",G+"api.go", req=["provider","key","on"], res=["<settingsJSON>"], note="untagged struct{ Provider, Key string; On bool }; provider = the plugin's own provider id (pid)"),
]
contract = {
 "magpieCommit": "80af3b86",
 "doc": "spec/web-api.md",
 "auth": {"query": "k", "cookie": "magpie_web_<listenPort>", "cookieAnchors": [
     {"file": G+"web.go", "contains": ['q.Has("k")', 'webGuard("magpie_web_"+port', 'SameSite: http.SameSiteLaxMode', 'webSignInPath = "/_magpie/sign-in"', 'http.StatusSeeOther']},
     {"file": G+"api.go", "contains": ['func fail(rw http.ResponseWriter, err error)', 'out := map[string]string{"error": err.Error()}', 'Version string `json:"version"`', 'return noFramedAPI(held(mux))']}],
   "defaultWebAddr": {"file": "internal/cli/web_cli.go", "contains": ['const webAddr = "127.0.0.1:3430"']},
   "defaultGatewayAddr": {"file": "internal/gateway/gateway.go", "contains": ['const DefaultAddr = "127.0.0.1:3425"']}},
 "routes": routes,
}
if __name__ == "__main__":
    out = os.path.join(HERE, "web-contract.json")
    if "--check" not in sys.argv:
        json.dump(contract, open(out, "w"), indent=1); print("wrote", out, len(routes), "routes")
    root = sys.argv[sys.argv.index("--check")+1] if "--check" in sys.argv else None
    if root:
        c = json.load(open(out)); bad = []
        rd = lambda f: open(os.path.join(root, f), encoding="utf-8").read()
        for a in c["auth"]["cookieAnchors"] + [c["auth"]["defaultWebAddr"], c["auth"]["defaultGatewayAddr"]]:
            s = rd(a["file"])
            bad += [f'{a["file"]}: missing {x!r}' for x in a["contains"] if x not in s]
        for r in c["routes"]:
            s = rd(r["source"])
            if r["anchor"] not in s: bad.append(f'{r["source"]}: route gone {r["anchor"]}')
            src = s + (rd("internal/access/access.go") if r["path"] == "/api/caller-keys/{action}" else "")
            for a in r["actions"]:
                if not re.search(r'(case [^\n]*|== )"%s"' % re.escape(a), src): bad.append(f'{r["path"]}: action gone {a}')
            for snippet in r.get("contains", []):
                if isinstance(snippet, dict):
                    other = rd(snippet["file"])
                    bad += [f'{snippet["file"]}: {r["path"]} relies on {x!r}, gone' for x in snippet["contains"] if x not in other]
                elif snippet not in s: bad.append(f'{r["source"]}: {r["path"]} relies on {snippet!r}, gone')
            for t in r.get("goTags", []):
                s2 = rd(t["file"])
                for tag in t["tags"]:
                    if not re.search(r'json:"%s[,"]' % re.escape(tag), s2): bad.append(f'{t["file"]}: json tag gone {tag} ({r["path"]})')
        print("\n".join(bad) if bad else "contract OK"); sys.exit(1 if bad else 0)
