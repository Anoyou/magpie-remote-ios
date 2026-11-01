# 设计说明

## 定位
magpie 的 iPhone 遥控器。用户不是开发者：所有文案用简体中文大白话，错误要说清「怎么了」和「下一步做什么」。

## 信息架构
- 标签页：**额度**（首页）· **用量** · **对话** · **管理**。
- 每页右上角「主机」按钮打开主机设置（多主机、切换、密钥、测试连接）。
- 「配置引导」从空状态、错误状态、主机设置、「更多」都能进入。
- 底栏 5 个标签：前 4 个可在「更多 › 自定义底栏」里选择和排序（默认 Agent、会话、供应商、路由，存本机 UserDefaults），第 5 个固定是「更多」，列出其余页面；「更多」底部是「关于」（版本、构建号、离线更新日志）。

## 视觉
- iOS 26 Liquid Glass：卡片用 `glassEffect`（`glassCard()`），主要按钮 `.glassProminent`、次要按钮 `.glass`，同屏多块玻璃放在 `GlassEffectContainer` 里。
- 只用部署目标 iOS 26 已有的 API；用到 iOS 27 SDK 才有的 API 时必须 `if #available(iOS 27.0, *)` 兜底。
- 系统「降低透明度」由系统处理玻璃材质，不额外定制。
- 强调色 AccentColor（蓝），危险/警告用系统橙/红。

## 状态
每个依赖主机的页面都经过 `ConnectedContent`：没有主机 → 引导添加；连接中 → 进度；失败 → `MagpieError` 的中文标题、说明、提示 + 重试 / 配置引导。

## 数据与安全
- `MagpieRemoteCore` 只依赖 Foundation（Apple 平台加 Security），可以 `swift test`。
- 密钥按主机分三种（网关 / 签发 / Web），存钥匙串 `MagpieRemote.HostSecrets`，`WhenUnlockedThisDeviceOnly`，不同步。
- 网关（3425）用 `Authorization: Bearer <网关密钥>`。Web 接口（3430）**不接受 Bearer**：要用 `?k=<Web 密钥>` 换取 Cookie（见 spec/web-api.md），接入时在 Core 里单独实现。
- 外网只推荐 Tailscale / WireGuard，文案里明确不要开放公网端口。

## 测试
- fixture 模式（`--ui-testing`）注入内存钥匙串 + 固定示例数据，UI 测试不需要主机。
- 契约测试（contract.yml）与 magpie 兼容性（magpie-compat.yml，每周）由其它工作流负责。
