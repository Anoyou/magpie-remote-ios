# 第三方声明

## magpie

「管理 › 路由」页（实时路由舞台、路由组卡片与编辑页）的布局、状态、配色含义、连线与流动动画，
以及路由方式 / 会话保持 / 失败原因等中文文案，移植自 magpie 网页的「路由」页
（`internal/gui/assets/plugins/routing/client.js`、`routing.css`、`i18n.js`），并按其
`internal/gui/groups.go`、`internal/gui/trace.go`、`internal/gateway/trace.go` 读取数据。
对应代码：`MagpieRemoteApp/RoutesStageView.swift`、`MagpieRemoteApp/ManageGroupsView.swift`、
`MagpieRemoteCore/Sources/MagpieRemoteCore/RouteTrace.swift`、`GroupRouting.swift`。

路由舞台上飞行的喜鹊图形与动作（client.js 的 `FLIER` 路径、routing.css 的 `.rt-flier` / `rtflap` /
`.rt-lift`、飞行路线 `pose()` / `via()`），以及 magpie 的喜鹊标志（`internal/gui/assets/index.html` 的
`#bird` 路径），均取自 magpie 原作，路径数据原样保留，适用下方同一份 MIT 许可。
对应代码：`MagpieRemoteApp/RoutesMagpie.swift`、`MagpieRemoteApp/RoutesStageView.swift`。

App 图标（`MagpieRemoteApp/Assets.xcassets/AppIcon.appiconset`）由 magpie 的 App 图标
（`build/darwin/AppIcon.icon` 的喜鹊图层与浅色 / 深色底色）合成；资源目录 `Brand/` 里的供应商、模型厂商与
Agent 标志取自 magpie 网页的 `internal/gui/assets/icons/`（SVG 去掉了 iOS 不认的根节点属性，少数带 mask /
filter / clipPath 的渲染成 PNG），`Nav/` 里的页面图标取自 `internal/gui/assets/index.html` 的导航栏线条图；
图标名与供应商 / Agent / 模型的对应关系照 `app.js` 的 `icon()`、`internal/agent`、`internal/provider/presets.go`
生成（`scripts/gen-official-icons.py`）。对应代码：`MagpieRemoteCore/Sources/MagpieRemoteCore/OfficialIcon.swift`、
`OfficialIconNames.swift`、`MagpieRemoteApp/OfficialIconViews.swift`。各品牌标志的商标归其所有者，这里只用来
标明对应的服务。

来源：https://github.com/yetone/magpie

```
MIT License

Copyright (c) 2026 yetone

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
