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
