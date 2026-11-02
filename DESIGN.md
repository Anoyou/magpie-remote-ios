# 设计说明

## 定位
magpie 的 iPhone 遥控器。用户不是开发者：所有文案用简体中文大白话，错误要说清「怎么了」和「下一步做什么」。

## 信息架构
- 标签页：**额度**（首页）· **用量** · **对话** · **管理**。
- 每页右上角「主机」按钮打开主机设置（多主机、切换、密钥、测试连接）。
- 「配置引导」从空状态、错误状态、主机设置、「更多」都能进入。
- 底栏 5 个标签：前 4 个可在「更多 › 自定义底栏」里选择和排序（默认主页、会话、路由、用量，存本机 UserDefaults；「主页」顶部分页器切换 Agent / 供应商 / 额度，记住上次选的），第 5 个固定是「更多」，列出其余页面；「更多」底部是「关于」（版本、构建号、离线更新日志）。

## 视觉
- iOS 26 Liquid Glass：卡片用 `glassEffect`（`glassCard()`），主要按钮 `.glassProminent`、次要按钮 `.glass`，同屏多块玻璃放在 `GlassEffectContainer` 里。
- 只用部署目标 iOS 26 已有的 API；用到 iOS 27 SDK 才有的 API 时必须 `if #available(iOS 27.0, *)` 兜底。
- 系统「降低透明度」由系统处理玻璃材质，不额外定制。
- 强调色 AccentColor（蓝），危险/警告用系统橙/红。
- 页头统一用 `PageHeader.swift`：页面（底栏页、「更多」里的每一项、固定名字的二级页）用 `.pageHeader(标题, subtitle:)`——iOS 系统标准大标题（`.large`，和「设置」一样），往上滚时由系统收成**居中**的小标题；副标题用系统的 `navigationSubtitle`，内容取自 magpie 网页插件清单 `Sub` 的官方中文，但必须短到 393 pt 宽的 iPhone 上一行放得下（约 12 个字以内，`PageSubtitles`）。名字不固定的详情页和弹出表单用 `.detailHeader`（居中小标题）。页面工具栏按钮放右上角。不要再直接写 `.navigationTitle` / `.navigationBarTitleDisplayMode`，也不要用 `.principal` / 靠左的自定义标题。
- **页面顶部不钉东西**：大标题页面的导航栏下面不放钉住的条（分页器、搜索栏、筛选、`safeAreaInset(edge: .top)` / `safeAreaBar(edge: .top)`、列表上方的固定内容）。钉住的条会和大标题的展开 / 收起抢位置，滚到顶部附近页头会抖。这类内容做成列表的第一行，跟着内容滚：外层用 `.pageTopStrip { … }` 交给页面，页面根列表第一行写 `PageTopStripSection()`（`ScrollView` 页用 `PageTopStripView()`，读取中 / 出错等不能滚的状态用 `PageTopStripStack`），见 `PageTopStrip.swift`。「主页」「用量」的分页器、管理页「读取失败」的提示都这样放。底部的状态行（`safeAreaInset(edge: .bottom)`）不受影响。

## 搜索
- 全 App 只有一种写法：`pageSearchable(text:prompt:)`（`PageHeader.swift`）= 系统 `.searchable` + `.navigationBarDrawer(displayMode: .automatic)`。和 iOS「设置」「邮件」一样，搜索栏在大标题下面，停在顶部时可见，往上滚时和大标题一起由系统收起，往下拉又出来。
- 不用 `.always`（钉在标题下面，和大标题抢位置、顶部会抖）；也不省略位置——iOS 26 在底栏里推入的页面（如「更多 › 插件」）上，系统默认位置会让搜索整个不显示。
- 页面、二级页、弹出的表单（选模型、资源库的「发现」）都一样，不再区分「完整搜索栏 / 收成放大镜」。

## 「更多」
- 照 iOS「设置」的样式：分组圆角列表（`.insetGrouped`），每组有标题：主机（当前主机、magpie 版本）· 页面 · 主机工具 · 在网页中打开 · App（关于、配置引导、自定义底栏）。
- 每一行：彩色圆角方块图标（`SettingsIcon`，30 pt、圆角 7、白色图标）+ 名字 + 可选的值 + 右箭头；图标颜色按页面固定（`AppPage.tint`）。
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
