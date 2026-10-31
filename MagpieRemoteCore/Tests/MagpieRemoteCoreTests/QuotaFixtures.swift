// 额度模型解码测试用的 fixture（全部为假值：@example.com、13800000000 等）。
// - gateway*：按 magpie 源码（internal/provider/quotas.go、subscription_usage.go、quota_history.go、internal/budget）的字段写的示例，时间为 RFC 3339；
// - live*：contract.yml 对真实 magpie v0.1.2438 抓到并脱敏的响应（Fixtures/live 同名文件）。
// 内嵌为字符串，避免改动测试 target 的资源配置。

enum QuotaFixtures {
    static let gatewayCards = #"""
{
  "object": "list",
  "data": [
    {
      "provider": "claude",
      "name": "Claude",
      "icon": "claude",
      "plan": "Max 5x",
      "user": "me@example.com",
      "windows": [
        {
          "name": "5 hours",
          "used": 37,
          "resetsAt": "2026-11-01T05:00:00+08:00"
        },
        {
          "name": "Week",
          "used": 61.5,
          "resetsAt": "2026-11-04T09:00:00+08:00"
        }
      ],
      "readAt": "2026-11-01T02:41:07.551203+08:00",
      "kind": "subscription",
      "lastServedAt": "2026-11-01T02:40:07.551203+08:00",
      "alias": "Work Claude"
    },
    {
      "provider": "workbuddy",
      "name": "WorkBuddy",
      "icon": "workbuddy",
      "user": "13800000000",
      "windows": [
        {
          "name": "Credits",
          "used": 25,
          "amount": 250,
          "limit": 1000,
          "unit": "credits",
          "runsOutAt": "2026-11-20T00:00:00+08:00",
          "runsOut": 300
        }
      ],
      "kind": "subscription",
      "checkins": true
    },
    {
      "provider": "deepseek",
      "name": "DeepSeek",
      "icon": "deepseek",
      "windows": [],
      "balance": "¥ 23.71",
      "readAt": "2026-11-01T02:41:07.551203+08:00",
      "kind": "balance"
    }
  ]
}
"""#

    static let gatewayRefresh = #"""
{
  "object": "list",
  "data": [
    {
      "provider": "claude",
      "name": "Claude",
      "icon": "claude",
      "plan": "Max 5x",
      "user": "me@example.com",
      "windows": [
        {
          "name": "5 hours",
          "used": 37,
          "resetsAt": "2026-11-01T05:00:00+08:00"
        },
        {
          "name": "Week",
          "used": 61.5,
          "resetsAt": "2026-11-04T09:00:00+08:00"
        }
      ],
      "readAt": "2026-11-01T02:41:07.551203+08:00",
      "kind": "subscription",
      "lastServedAt": "2026-11-01T02:40:07.551203+08:00",
      "alias": "Work Claude"
    },
    {
      "provider": "workbuddy",
      "name": "WorkBuddy",
      "icon": "workbuddy",
      "user": "13800000000",
      "windows": [
        {
          "name": "Credits",
          "used": 25,
          "amount": 250,
          "limit": 1000,
          "unit": "credits",
          "runsOutAt": "2026-11-20T00:00:00+08:00",
          "runsOut": 300
        }
      ],
      "kind": "subscription",
      "checkins": true
    },
    {
      "provider": "deepseek",
      "name": "DeepSeek",
      "icon": "deepseek",
      "windows": [],
      "balance": "¥ 23.71",
      "readAt": "2026-11-01T02:41:07.551203+08:00",
      "kind": "balance"
    }
  ]
}
"""#

    static let gatewayQuotas = #"""
{
  "object": "list",
  "data": [
    {
      "provider": "claude",
      "name": "Claude",
      "kind": "subscription",
      "plan": "Max 5x",
      "user": "me@example.com",
      "windows": [
        {
          "name": "5 hours",
          "used": 37,
          "remaining": 63,
          "resetsAt": "2026-11-01T05:00:00+08:00"
        },
        {
          "name": "Week",
          "used": 61.5,
          "remaining": 38.5,
          "resetsAt": "2026-11-04T09:00:00+08:00"
        }
      ],
      "readAt": "2026-11-01T02:41:07.551203+08:00",
      "lastServedAt": "2026-11-01T02:40:07.551203+08:00",
      "last": true,
      "alias": "Work Claude"
    },
    {
      "provider": "codex",
      "name": "Codex",
      "kind": "subscription",
      "plan": "Plus",
      "user": "me@example.com",
      "windows": [
        {
          "name": "5 hours",
          "used": 100,
          "remaining": 0,
          "resetsAt": "2026-11-01T03:12:00+08:00"
        },
        {
          "name": "Week",
          "used": 44,
          "remaining": 56,
          "resetsAt": "2026-11-06T11:00:00+08:00"
        }
      ],
      "asOf": "2026-11-01T02:20:07.551203+08:00",
      "error": "couldn't read the allowance: 429 Too Many Requests",
      "resets": {
        "count": 1,
        "until": "2026-11-30T08:00:00+08:00"
      }
    },
    {
      "provider": "zai",
      "name": "Z.ai Coding Plan",
      "kind": "plan",
      "plan": "Pro",
      "windows": [
        {
          "name": "5 hours",
          "used": 12.4,
          "remaining": 87.6,
          "resetsAt": "2026-11-01T06:00:00+08:00",
          "display": "248 / 2000"
        }
      ],
      "until": "2026-12-15T00:00:00+08:00",
      "renew": "auto"
    },
    {
      "provider": "deepseek",
      "name": "DeepSeek",
      "kind": "balance",
      "windows": [],
      "balance": "¥ 23.71",
      "balanceSplit": [
        {
          "label": "granted",
          "text": "¥ 10.00"
        },
        {
          "label": "topped up",
          "text": "¥ 13.71"
        }
      ],
      "readAt": "2026-11-01T02:41:07.551203+08:00"
    }
  ]
}
"""#

    static let gatewayHistory = #"""
{
  "object": "list",
  "data": [
    {
      "provider": "claude",
      "user": "me@example.com",
      "lines": [
        {
          "name": "5 hours",
          "points": [
            {
              "at": "2026-11-01T00:05:12.5+08:00",
              "left": 100,
              "start": "2026-11-01T00:00:00+08:00",
              "resetsAt": "2026-11-01T05:00:00+08:00"
            },
            {
              "at": "2026-11-01T01:30:12.5+08:00",
              "left": 81,
              "start": "2026-11-01T00:00:00+08:00",
              "resetsAt": "2026-11-01T05:00:00+08:00"
            },
            {
              "at": "2026-11-01T02:41:07+08:00",
              "left": 63,
              "start": "2026-11-01T00:00:00+08:00",
              "resetsAt": "2026-11-01T05:00:00+08:00"
            }
          ]
        },
        {
          "name": "Week",
          "points": [
            {
              "at": "2026-10-28T17:10:07.551203+08:00",
              "left": 100,
              "resetsAt": "2026-11-04T09:00:00+08:00"
            },
            {
              "at": "2026-11-01T02:41:07.551203+08:00",
              "left": 38.5,
              "resetsAt": "2026-11-04T09:00:00+08:00"
            }
          ]
        }
      ]
    }
  ]
}
"""#

    static let gatewayCardsEmpty = #"""
{
  "object": "list",
  "data": []
}
"""#

    static let gatewayLimitLimited = #"""
{
  "limited": true,
  "key": "iPhone",
  "limit": {
    "period": "hours",
    "hours": 5,
    "start": "2026-11-01T00:00:00+08:00",
    "reset": "2026-11-01T05:00:00+08:00",
    "calls": 17,
    "tokens": 44532,
    "cost": 0.5172,
    "unpriced": 1,
    "tokenLimit": 50000,
    "tokensLeft": 5468,
    "costLeft": 0,
    "spent": false
  },
  "limits": [
    {
      "period": "day",
      "start": "2026-11-01T00:00:00+08:00",
      "reset": "2026-11-02T00:00:00+08:00",
      "calls": 17,
      "tokens": 44532,
      "cost": 0.5172,
      "unpriced": 1,
      "inFlight": 1,
      "reserved": 2048,
      "tokenLimit": 200000,
      "costLimit": 5,
      "tokensLeft": 155468,
      "costLeft": 4.4828,
      "spent": false
    },
    {
      "period": "hours",
      "hours": 5,
      "start": "2026-11-01T00:00:00+08:00",
      "reset": "2026-11-01T05:00:00+08:00",
      "calls": 17,
      "tokens": 44532,
      "cost": 0.5172,
      "unpriced": 1,
      "tokenLimit": 50000,
      "tokensLeft": 5468,
      "costLeft": 0,
      "spent": false
    }
  ]
}
"""#

    static let gatewayLimitIssued = #"""
{
  "limited": true,
  "key": "ios-temp",
  "expires": "2026-11-01T03:40:07.551203+08:00",
  "issuerLimits": [
    {
      "period": "day",
      "start": "2026-11-01T00:00:00+08:00",
      "reset": "2026-11-02T00:00:00+08:00",
      "calls": 17,
      "tokens": 44532,
      "cost": 0.5172,
      "unpriced": 1,
      "inFlight": 1,
      "reserved": 2048,
      "tokenLimit": 200000,
      "costLimit": 5,
      "tokensLeft": 155468,
      "costLeft": 4.4828,
      "spent": false
    }
  ],
  "limit": {
    "period": "days",
    "days": 30,
    "start": "2026-11-01T02:40:07.551203+08:00",
    "reset": "2026-12-01T02:40:07.551203+08:00",
    "calls": 1,
    "tokens": 19,
    "cost": 0,
    "unpriced": 1,
    "tokenLimit": 10000,
    "tokensLeft": 9981,
    "costLeft": 0,
    "spent": false
  },
  "limits": [
    {
      "period": "days",
      "days": 30,
      "start": "2026-11-01T02:40:07.551203+08:00",
      "reset": "2026-12-01T02:40:07.551203+08:00",
      "calls": 1,
      "tokens": 19,
      "cost": 0,
      "unpriced": 1,
      "tokenLimit": 10000,
      "tokensLeft": 9981,
      "costLeft": 0,
      "spent": false
    }
  ]
}
"""#

    static let gatewayLimitUnlimited = #"""
{
  "limited": false,
  "key": "iPhone"
}
"""#

    static let gatewayQuotasNotShared = #"""
{
  "error": {
    "message": "magpie's quotas are told to another machine only when magpie is shared on the local network (Settings → Network and sharing → Share on local network) and the request carries its API key (Authorization: Bearer <key> or x-api-key: <key>)",
    "type": "permission_error",
    "code": null,
    "param": null
  }
}
"""#

    static let gatewayRefreshRemoteCard = #"""
{
  "error": {
    "message": "this magpie reads only its own cards again",
    "type": "invalid_request_error",
    "code": null,
    "param": null
  }
}
"""#

    /// live: gw-quotas-cards.json
    static let liveCards = #"""
{"data":[],"object":"list"}
"""#

    /// live: gw-quotas-history.json
    static let liveHistory7 = #"""
{"data":[],"object":"list"}
"""#

    /// live: gw-quotas.json
    static let liveQuotas = #"""
{"data":[],"object":"list"}
"""#

    /// live: gw-quotas-kept.json
    static let liveQuotasKept = #"""
{"data":[],"object":"list"}
"""#

    /// live: gw-limit.json
    static let liveLimit = #"""
{"key":"Contract client","limited":false}
"""#

    /// live: held-limit.json
    static let liveHeldLimit = #"""
{"expires":"2026-10-31T20:06:06.961524073Z","key":"contract-temp","limit":{"period":"hours","hours":1,"start":"2026-10-31T19:06:06.961524073Z","reset":"2026-10-31T20:06:06.961524073Z","calls":0,"tokens":0,"cost":0,"tokenLimit":10000,"tokensLeft":10000,"costLeft":0,"spent":false},"limited":true,"limits":[{"period":"hours","hours":1,"start":"2026-10-31T19:06:06.961524073Z","reset":"2026-10-31T20:06:06.961524073Z","calls":0,"tokens":0,"cost":0,"tokenLimit":10000,"tokensLeft":10000,"costLeft":0,"spent":false}]}
"""#

    /// live: err-held-quotas.json
    static let liveHeldQuotas = #"""
{"error":{"code":"gateway_key_held","message":"this gateway key is held to a budget, models or accounts, so it is told nothing of this magpie's accounts: GET /v1/magpie/limit tells it its own limit","type":"permission_error"}}
"""#

    /// live: err-readonly-models.json
    static let liveReadOnly = #"""
{"error":{"code":"gateway_key_read_only","message":"this gateway key is read-only: it may read magpie's quotas and usage (GET /v1/magpie/quotas, /v1/magpie/quotas/history, /v1/magpie/usage, /v1/magpie/usage/requests, /v1/magpie/limit) and use no model, MCP server or write. Use a key with full access for that (Gateway → Gateway keys, or magpie gateway-key access <id> full)","type":"permission_error"}}
"""#

}
