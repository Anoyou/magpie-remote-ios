# magpie 接口契约

Magpie Remote 依赖 magpie 的两组 HTTP 接口：网关（默认 3425）与 `magpie web` 页面 API（默认 3430）。
这里的文件把「App 依赖哪些路由、哪些字段」写成可机器校验的契约，并用真实的 magpie 验证。

| 文件 | 作用 |
|---|---|
| `gateway-contract.json` | 网关路由与字段（类型、是否必有、是否可为 null、`core` = App 直接依赖）。由 `tools/build_contract.py <magpie 源码>` 从 Go 结构体与源码锚点生成。 |
| `web-contract.json` | web 页面 API 的路由、动作与 json 标签。由 `gen_web_contract.py` 生成。 |
| `check_gateway_contract.py <src>` | 静态检查：从给定源码重新生成网关契约并与已提交的比较；锚点缺失或核心字段变化即失败。 |
| `gen_web_contract.py --check <src>` | 静态检查：web 路由 / 动作 / json 标签是否仍在源码中。 |
| `run-magpie-fixture.sh <src> [workdir]` | 从源码构建 magpie（`-tags nogui`，`CGO_ENABLED=0`），隔离 HOME 启动网关与 web，接上 `mock_openai.py`，写入 provider `mock`、路由组 `fast`、普通 / 签发 / 只读三把网关密钥，并开启局域网共享。`MAGPIE_BIN=` 可直接用现成的二进制。 |
| `test_contract.py [fixture.env]` | 实时契约测试（只用标准库），结果与每个响应写到 `CONTRACT_CAPTURE_DIR`。 |
| `export_fixtures.py <captures> <fixture.env> [dest]` | 把抓到的响应脱敏后写到 `MagpieRemoteCore/Tests/MagpieRemoteCoreTests/Fixtures/live/`，供 Swift 解码测试使用。 |

本地运行：

```sh
GATEWAY_PORT=23425 WEB_PORT=23430 MOCK_PORT=28080 contract/run-magpie-fixture.sh ../magpie /tmp/mfix
python3 contract/test_contract.py /tmp/mfix/fixture.env
MOCK_PORT=28080 python3 contract/export_fixtures.py /tmp/magpie-contract-captures /tmp/mfix/fixture.env
python3 scripts/check-privacy.py
kill $(cat /tmp/mfix/pids)
```

CI：`.github/workflows/contract.yml`（每个 PR / main push，测 magpie 最新发布版，解析失败时回退到已验证的提交
80af3b8 = v0.1.2438）与 `.github/workflows/magpie-compat.yml`（每周一 01:00 UTC，不兼容时开 issue）。

## 实测得到的要点（v0.1.2438）

- **回环地址会绕过密钥与共享检查。** 从 127.0.0.1 调网关时不带密钥也能成功；测试必须带任一转发头
  （`X-Forwarded-For`、`Forwarded`、`X-Real-IP` …）才会被当作远程调用。`MAGPIE_TRUST_PROXY=1` 会关掉这一判定。
- **不要用 `MAGPIE_ADDR=127.0.0.1:<端口>` 指定端口**：它把主机钉死在回环上，开启共享后也不会监听局域网。
  端口写在 `settings.json` 的 `{"port":N}` 里。
- 开启共享只能通过 web API：`POST /api/settings/lan {"On":true}`（cookie `magpie_web_<web 端口>=<MAGPIE_WEB_KEY>`）。
  开启时会自动生成一把名为 `Magpie` 的 `lan` 密钥。
- 未共享时远程请求得到 **纯文本** 403，不是 JSON；其余错误都是 OpenAI 形状的 JSON 信封。
- `period` 只认 `today` / `7d` / `30d` / `all`（以及区间、`last:<时长>`）；`day` / `week` / `month` 会静默变成 `30d`。
- 时间字段是 **RFC3339**（如 `2026-10-31T19:40:57.123+08:00`），测试会逐个校验格式。
- **User-Agent 首段决定 usage 里的 `agent`，且按已知 agent 前缀匹配**：以 `magpie` 开头的名字（包括 iOS
  默认的 `MagpieRemote/1 CFNetwork/…`）会被记成 magpie 自己。App 应发送一个不以 magpie 开头的 User-Agent，
  才能在用量里单独筛出自己的调用。
- 只有 API key 型 provider 时，额度相关接口返回空列表；订阅额度卡片的形状无法用 mock 覆盖。
