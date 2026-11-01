import Foundation
import XCTest
@testable import MagpieRemoteCore

final class OfficialIconTests: XCTestCase {
    func testMarkFollowsWebIconRules() {
        XCTAssertEqual(OfficialIcon.mark(nil), .blank)
        XCTAssertEqual(OfficialIcon.mark(""), .blank)
        XCTAssertEqual(OfficialIcon.mark("generic"), .generic)
        // 彩色：-color 结尾、pngIcons 里的、导入应用的 app-*
        XCTAssertEqual(OfficialIcon.mark("claude-color"), .color(asset: "Brand/claude-color", shrunk: false))
        XCTAssertEqual(OfficialIcon.mark("codex-color"), .color(asset: "Brand/codex-color", shrunk: true))
        XCTAssertEqual(OfficialIcon.mark("crush"), .color(asset: "Brand/crush", shrunk: true))
        XCTAssertEqual(OfficialIcon.mark("app-alma"), .color(asset: "Brand/app-alma", shrunk: false))
        // 单色：其余打包了的
        XCTAssertEqual(OfficialIcon.mark("openai"), .mono(asset: "Brand/openai", shrunk: false))
        XCTAssertEqual(OfficialIcon.mark("magpie"), .mono(asset: "Brand/magpie", shrunk: false))
        XCTAssertEqual(OfficialIcon.mark("qoder"), .mono(asset: "Brand/qoder", shrunk: true))
        // 用户自己的图片、URL、没打包的名字：通用图标
        XCTAssertEqual(OfficialIcon.mark("file:1acced0492a72369.png"), .generic)
        XCTAssertEqual(OfficialIcon.mark("https://example.com/x.png"), .generic)
        XCTAssertEqual(OfficialIcon.mark("claude"), .generic)
    }

    func testBundledHasNoSiteIconsAndCoversTheKnownLists() {
        XCTAssertFalse(OfficialIcon.bundled.contains("apple-touch-icon"))
        XCTAssertFalse(OfficialIcon.bundled.contains("favicon"))
        XCTAssertGreaterThan(OfficialIcon.bundled.count, 150)
        XCTAssertTrue(OfficialIcon.pngIcons.isSubset(of: OfficialIcon.bundled))
        XCTAssertTrue(OfficialIcon.shrunk.isSubset(of: OfficialIcon.bundled))
        for (_, icon) in OfficialIcon.byFamily { XCTAssertTrue(OfficialIcon.bundled.contains(icon), icon) }
        for id in ["claude", "codex", "copilot", "gemini", "antigravity", "kiro", "cursor", "grok", "workbuddy-ai"] {
            XCTAssertTrue(OfficialIcon.bundled.contains(OfficialIcon.account(id)), id)
        }
        for (id, icon) in OfficialIcon.presetIcons {
            XCTAssertTrue(icon == "generic" || OfficialIcon.bundled.contains(icon), "\(id) → \(icon)")
        }
    }

    func testModelFamilyMatchesAgentIconsGo() {
        XCTAssertEqual(OfficialIcon.model("claude-sonnet-4-6"), "claude-color")
        XCTAssertEqual(OfficialIcon.model("openrouter/gpt-5"), "openai")
        XCTAssertEqual(OfficialIcon.model("Qwen3-Coder"), "qwen-color")
        XCTAssertEqual(OfficialIcon.model("glm-5.3"), "zhipu-color")
        XCTAssertEqual(OfficialIcon.model("mock-gpt-1"), "")
    }

    func testAgentProviderAndAppMapping() {
        XCTAssertEqual(OfficialIcon.agent("claude"), "claudecode-color")
        XCTAssertEqual(OfficialIcon.agent("codex"), "codex-color")
        XCTAssertEqual(OfficialIcon.agent("gemini"), "geminicli-color")
        XCTAssertEqual(OfficialIcon.agent("opencode"), "opencode")
        XCTAssertEqual(OfficialIcon.agent("curl"), "curl")
        XCTAssertEqual(OfficialIcon.agent("MagpieRemote"), "")
        XCTAssertEqual(OfficialIcon.provider("anthropic"), "claude-color")
        XCTAssertEqual(OfficialIcon.provider("deepseek"), "deepseek-color")
        XCTAssertEqual(OfficialIcon.provider("codex"), "codex-color")
        XCTAssertEqual(OfficialIcon.provider("relay-one"), "")
        XCTAssertEqual(OfficialIcon.app("claude-code"), "claudecode-color")
        XCTAssertEqual(OfficialIcon.app("cc-switch"), "app-cc-switch")
    }

    func testNavGlyphsByPageRawValue() {
        XCTAssertEqual(OfficialIcon.navGlyph(page: AppPage.home.rawValue), "Nav/nav-agents")
        XCTAssertEqual(OfficialIcon.navGlyph(page: AppPage.sessions.rawValue), "Nav/nav-sessions")
        XCTAssertEqual(OfficialIcon.navGlyph(page: AppPage.routes.rawValue), "Nav/nav-routing")
        XCTAssertEqual(OfficialIcon.navGlyph(page: AppPage.keys.rawValue), "Nav/nav-gateway")
        XCTAssertNil(OfficialIcon.navGlyph(page: AppPage.about.rawValue))
        XCTAssertNil(OfficialIcon.navGlyph(page: "unknown"))
    }

    /// 路由舞台的账号 / Key 行：主机给的 icon 优先，其次 preset，旧版主机都没给时按供应商 id 认（网页 `w.icon || w.preset || "generic"`）。
    func testTraceSeatIconPrefersHostIconThenPreset() throws {
        func seat(_ text: String) throws -> TraceSeat { TraceSeat(try WebJSON.decode(Data(text.utf8))) }
        XCTAssertEqual(try seat(#"{"id":"k1","provider":"my-relay","icon":"openrouter","preset":"deepseek","kind":"key"}"#).officialIcon, "openrouter")
        XCTAssertEqual(try seat(#"{"id":"k1","provider":"my-relay","preset":"deepseek","kind":"key"}"#).officialIcon, OfficialIcon.provider("deepseek").isEmpty ? "deepseek" : OfficialIcon.provider("deepseek"))
        XCTAssertEqual(try seat(#"{"id":"a1","provider":"claude","kind":"account"}"#).officialIcon, "claude-color")
        XCTAssertEqual(try seat(#"{"id":"k1","provider":"my-relay","kind":"key"}"#).officialIcon, "generic")
    }

    /// 真实主机 /api/state 的 clients：每个图标名要么打包了，要么是 generic；和生成的 Agent 对应表一致。
    func testLiveStateClientIconsAreAllBundled() throws {
        let json = try WebJSON.decode(LiveFixture.data("web-state.json"))
        let clients = json["clients"]?.array ?? []
        XCTAssertGreaterThan(clients.count, 30)
        for client in clients {
            let icon = client["icon"]?.string ?? ""
            XCTAssertTrue(icon == "generic" || OfficialIcon.bundled.contains(icon), icon)
            if let id = client["id"]?.string, icon != "generic", OfficialIcon.agentIcons[id] != nil {
                XCTAssertEqual(OfficialIcon.agent(id), icon, id)
            }
        }
        XCTAssertEqual(WebState(json: json).agents.first?.officialIcon, "claudecode-color")
    }

    func testProvidersFallBackToPreset() throws {
        let json = try WebJSON.decode(LiveFixture.data("web-providers.json"))
        let mock = try XCTUnwrap(WebProviders(json: json).providers.first)
        XCTAssertEqual(mock.officialIcon, "")
        XCTAssertEqual(OfficialIcon.mark(mock.officialIcon), .blank)
        let custom = WebProvider(raw: ["id": "my-deepseek", "preset": "deepseek", "icon": ""])
        XCTAssertEqual(custom.officialIcon, "deepseek-color")
    }

    func testUsageBreakdownIcons() throws {
        let summary = try JSONDecoder().decode(UsageSummary.self, from: Data(UsageFixtures.usageSummary.utf8))
        let claude = try XCTUnwrap(summary.breakdown(.agent).first { $0.id == "claude" })
        XCTAssertEqual(summary.officialIcon(for: claude, in: .agent), "claude")  // 主机给的原样用
        let anthropic = try XCTUnwrap(summary.breakdown(.provider).first { $0.id == "anthropic" })
        XCTAssertEqual(summary.officialIcon(for: anthropic, in: .provider), "claude-color")
    }

    func testQuotaAccountIconFallsBackForOldHosts() {
        XCTAssertEqual(QuotaAccount(id: "a", cards: [QuotaCard(provider: "codex", name: "Codex")]).officialIcon, "codex-color")
        XCTAssertEqual(QuotaAccount(id: "b", cards: [QuotaCard(provider: "zai", name: "Z.ai", icon: "zai")]).officialIcon, "zai")
    }
}
