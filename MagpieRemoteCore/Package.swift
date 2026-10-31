// swift-tools-version: 6.0
import PackageDescription

// MagpieRemoteCore：只依赖 Foundation（以及 Apple 平台上的 Security），不引入任何第三方包。
// macOS 上可直接 `swift test --package-path MagpieRemoteCore` 运行单元测试，不需要模拟器。
let package = Package(
    name: "MagpieRemoteCore",
    platforms: [.iOS("26.0"), .macOS(.v14)],
    products: [.library(name: "MagpieRemoteCore", targets: ["MagpieRemoteCore"])],
    targets: [
        .target(name: "MagpieRemoteCore"),
        // Fixtures/live：contract.yml 用真实 magpie 抓取并脱敏的响应（contract/export_fixtures.py 生成）。
        .testTarget(name: "MagpieRemoteCoreTests", dependencies: ["MagpieRemoteCore"], resources: [.copy("Fixtures")]),
    ]
)
