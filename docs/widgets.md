# 主屏与锁屏小组件

Magpie Remote 带两个小组件：

| 小组件 | 尺寸 | 显示什么 | 点一下打开 |
| --- | --- | --- | --- |
| **额度** | 主屏小 / 中 / 大，锁屏圆形 / 矩形 / 一行文字 | 订阅账号剩余多少（百分比）、多久后重置；小号和锁屏只显示最紧张的那个账号，中号 2 个、大号 4 个 | 主页 › 额度 |
| **今日用量** | 主屏小 / 中，锁屏矩形 / 一行文字 | 今天的花费、词元、请求数、失败率；中号还显示当前并发 | 用量 |

## 怎么添加

1. 先打开一次 Magpie Remote，连上主机（小组件显示的是 App 最近一次读到的数据）。
2. **主屏**：长按桌面空白处 → 左上角「编辑」→「添加小组件」→ 搜索「Magpie Remote」→ 选「额度」或「今日用量」，左右滑动选尺寸 → 「添加小组件」。
3. **锁屏**：锁屏界面长按 →「自定」→ 选锁屏 → 点时间下方的小组件区域 → 找到 Magpie Remote → 选「额度」或「今日用量」。
4. 想换外观：主屏「编辑 › 自定」里选「清透」或「着色」，小组件会跟着变成 Liquid Glass 玻璃效果。

## 数据多久更新一次

- 小组件**自己不联网**，也不碰钥匙串里的密钥。App 每次连上主机、回到前台（2 分钟内不重复）、额度页刷新时，把额度和今日用量写成一份「快照」交给小组件。
- 小组件按这份快照倒计时：重置时间一到，显示「已重置，待刷新」；超过 30 分钟角落显示「x 分钟前更新」；超过 6 小时数字变灰，并提示「数据已过时 · 打开 App 刷新」。
- 想看最新数字：点一下小组件打开 App 就会更新。

## 自签安装要注意（免费 Apple ID）

小组件是 App 里的一个「扩展」，它和 App 之间靠 **App Group**（一个共享文件夹）传数据。免费 Apple ID 可以用 App Group，但要签名工具配合：

- **不要勾选「移除扩展 / Remove app extensions」**（Sideloadly 的高级选项里有这一项）。勾了小组件就没了。
- **App ID 名额**：免费 Apple ID 每 7 天最多注册 10 个 App ID。带小组件后，每次安装 Magpie Remote 占 **2 个**（App 1 个 + 小组件 1 个）。同一周内反复改 Bundle ID 重装容易用完，等 7 天就会恢复。
- **同时安装的 App 数**：免费 Apple ID 最多同时激活 3 个自签 App，有的工具会把扩展也算进去。装不上时先删掉不用的自签 App。
- **App Group 会被改名**：组名在苹果那边全局唯一，自签工具通常会改成带你团队 ID 的名字（AltStore / SideStore 会在后面加 `.团队ID`）。App 和小组件会在运行时自动找到改名后的组，不需要你做任何事。
- **如何确认连通了**：打开 App →「更多 › 关于」，「小组件」一栏显示「已连通」就好了。显示「未连通」说明这次签名没有开通 App Group（或扩展被去掉了），小组件会一直显示「打开 App 刷新」。这时换用 AltStore / SideStore 重新安装，或在 Sideloadly 里确认没有移除扩展后重装一次。
- 7 天到期重新签名后，小组件里的数据会在下次打开 App 时恢复。

## 技术说明（给维护者）

- 快照：`MagpieRemoteCore/WidgetSnapshot.swift`，JSON，只有显示用的文字和数字（账号名、窗口剩余百分比、重置时间、今日花费 / 词元 / 请求 / 失败、并发），**没有任何密钥或主机地址**。版本号 `WidgetSnapshot.currentVersion`，小组件遇到更新版本写的快照当作没有快照。
- App Group 定位：`MagpieRemoteCore/WidgetAppGroup.swift`。候选顺序：描述文件 `embedded.mobileprovision` 授权的组 → Info.plist `ALTAppGroups`（AltStore 改名后写入）→ Info.plist `MagpieAppGroup`（构建时的原名）→ 原名 / `group.<主 App bundle id>`（再加团队 ID）。系统给出目录且能写入的都算可用；App 写进每个可用组，小组件读所有可用组里最新的一份。
- 时间线：`MagpieRemoteCore/WidgetTimeline.swift`。现在、之后 6 小时每整刻钟、每个窗口的重置时刻、快照变旧（30 分钟）/ 过时（6 小时）的时刻；用完后 WidgetKit 再来要；App 写新快照时调用 `WidgetCenter.reloadAllTimelines()`。
- 深链：`magpieremote://widget/quota`、`magpieremote://widget/usage`（`WidgetLink`）。页面在底栏里就切到那个标签，不在就切到「更多」再推入。
- 打包：`scripts/build-unsigned.sh` 检查 `Payload/MagpieRemote.app/PlugIns/MagpieRemoteWidgets.appex` 存在、版本与 App 一致，并对扩展和 App 做一次**临时（ad-hoc）签名**写入 App Group 声明——自签工具（AltStore / SideStore 等）从可执行文件的签名里读声明来开通 App Group。IPA 仍需自签才能安装。`scripts/reuse-unsigned-ipa.py` 改 build 号时扩展一起改。
- 工程：`scripts/sync-xcodeproj.py` 生成 `MagpieRemoteWidgets` 扩展 target（bundle id `com.magpieremote.personal.widgets`），嵌入 App；扩展共用 App 的 `OfficialIconViews.swift` 和 `Assets.xcassets`（官方标志）。
