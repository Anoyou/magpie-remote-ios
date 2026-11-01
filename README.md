# Magpie Remote（iOS）

在 iPhone 上遥控你自己 Mac 上的 [magpie](https://github.com/yetone/magpie)：查看各模型账号的剩余额度、用量统计，直接对话，以及管理网关密钥。

> 非官方项目。App 只连接你自己填写的主机，不经过任何第三方服务器，不收集数据。

## 需要什么

- 一台运行 magpie 的电脑（下文称「主机」，通常是 Mac）。
- iPhone / iPad，系统 iOS 26 或更新。
- 一个免费的 Apple ID（用来自签安装，见下文）。

## 第一步：在主机上做好准备

App 里「管理 › 配置引导」有同样的图文说明。

1. **开启「在局域网共享」**：magpie → 设置 → 网络与共享 → 打开「在局域网共享」。不开的话 iPhone 连不上网关（端口 3425）。
2. **创建网关密钥**：在同一页面为 iPhone 新建一把密钥，复制下来，稍后填到 App 里。
3. **打开 Web 接口**（看用量、做管理时需要，端口 3430）：在主机的终端里运行
   ```
   magpie daemon web on --lan
   ```
   它会生成一个 Web 密钥并保存为 `MAGPIE_WEB_KEY`；也可以先自己设置 `MAGPIE_WEB_KEY`（至少 16 位）。把这个值填到 App 的「Web 密钥」。
4. **外网访问只用 Tailscale 或 WireGuard**：不在家时，iPhone 和主机都打开 Tailscale，用它分配的地址（例如 `100.64.0.1` 或 `my-mac.tailnet.example`）连接。**不要**在路由器上把 3425 / 3430 端口开放到公网。

## 第二步：安装 App（自签未签名 IPA）

本仓库不上架 App Store，CI 会为每次合并到 `main` 的提交生成一个**未签名的 IPA**，需要你用自己的 Apple ID 签名后安装。

1. 打开仓库的 **Actions → 未签名 IPA**，选最新一次成功的运行，在页面底部 **Artifacts** 下载 `MagpieRemote-<版本>-<build>-<提交>-unsigned`，解压得到 `.ipa`。
2. 用自签工具安装，例如电脑上的 [Sideloadly](https://sideloadly.io/) 或 [AltStore](https://altstore.io/)：
   - 选择这个 `.ipa`，登录你的 Apple ID（免费的就可以），连接 iPhone，开始安装；
   - Bundle ID 默认是 `com.magpieremote.personal`，工具提示冲突时可以改成你自己的。
3. 第一次打开时，在 iPhone 的 **设置 › 通用 › VPN 与设备管理** 里信任你的开发者证书；iOS 16 以上还需要在 **设置 › 隐私与安全性** 里打开「开发者模式」。
4. **免费 Apple ID 签的 App 7 天后会失效**，到期前用同一个工具重新签名安装即可（数据和钥匙串里的密钥会保留）。付费开发者账号签名有效期为一年。

## 第三步：连接主机

打开 App → 右上角「主机」→「添加主机」，填主机地址（例如 `100.64.0.1`，端口默认 3425 / 3430）和刚才的密钥，点「测试连接」。看到「连接成功」就可以用了。可以添加多台主机，点一下即可切换。

## 隐私与安全

- 密钥只保存在 iPhone 的钥匙串（仅本机、解锁后可读、不随 iCloud 同步）。
- 主机列表（名称、地址）保存在 App 本地设置里。
- 本仓库是公开的：提交里不能出现真实的密钥、IP、Tailscale 主机名或邮箱，示例一律使用 `sk-magpie-key-EXAMPLE`、`100.64.0.1`、`my-mac.tailnet.example` 这类假值；CI 会运行 `scripts/check-privacy.py` 检查。

## 开发

- 结构：`MagpieRemoteApp/`（SwiftUI App）、`MagpieRemoteCore/`（只依赖 Foundation 的 Swift 包，含模型、主机与钥匙串、网关客户端、错误中文提示、SSE 解析）、`MagpieRemoteUITests/`、`scripts/`、`.github/workflows/`。
- 构建：Xcode 27（iOS 27 SDK），部署目标 iOS 26。
- 单元测试：`swift test --package-path MagpieRemoteCore`（macOS，也能在 Linux 上跑，钥匙串部分只在 Apple 平台编译）。
- UI 测试使用 fixture 模式：启动参数 `--ui-testing`（或环境变量 `MAGPIE_REMOTE_FIXTURE=1`），不需要真实主机；`--fixture-empty` 模拟没有主机，`--fixture-offline` 模拟连不上。
- 工程文件：`project.yml` 是 XcodeGen 定义，同时提交生成后的 `MagpieRemote.xcodeproj`。新增 / 删除源文件后运行 `python3 scripts/sync-xcodeproj.py`（或 `xcodegen generate`）；`python3 scripts/check-xcodeproj-sources.py` 校验。
- 版本：`MARKETING_VERSION` 在 `project.yml` 与工程里同步修改，`CHANGELOG.md` 最新版本段落必须一致；build 号由 CI 用 `MAGPIE_REMOTE_BUILD_NUMBER`（工作流 run_number）注入。
- 接口契约：额度、用量、对话、密钥管理接口的确切 JSON 形状正在整理，代码里以 `TODO(spec)` 标出；`contract.yml` / `magpie-compat.yml` 将用真实 magpie 校验。

## 许可

MIT（与 magpie 相同）。「路由」页移植自 magpie 网页的路由页，见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
