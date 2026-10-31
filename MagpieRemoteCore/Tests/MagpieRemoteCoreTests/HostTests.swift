import XCTest
@testable import MagpieRemoteCore

final class HostProfileTests: XCTestCase {
    func testAddressGetsDefaultPorts() throws {
        let host = try XCTUnwrap(HostProfile(name: "示例 Mac", address: "100.64.0.1"))
        XCTAssertEqual(host.gatewayURL.absoluteString, "http://100.64.0.1:3425")
        XCTAssertEqual(host.webURL.absoluteString, "http://100.64.0.1:3430")
        XCTAssertEqual(host.hostLabel, "100.64.0.1")
    }

    func testNormalizedURLKeepsSchemePortAndTrimsSlash() {
        XCTAssertEqual(HostProfile.normalizedURL(" https://my-mac.tailnet.example:9000/ ", defaultPort: 3425)?.absoluteString,
                       "https://my-mac.tailnet.example:9000")
        XCTAssertEqual(HostProfile.normalizedURL("my-mac.tailnet.example", defaultPort: 3430)?.absoluteString,
                       "http://my-mac.tailnet.example:3430")
        XCTAssertNil(HostProfile.normalizedURL("", defaultPort: 3425))
        XCTAssertNil(HostProfile.normalizedURL("ftp://100.64.0.1", defaultPort: 3425))
    }

    func testSemanticVersion() {
        XCTAssertEqual(SemanticVersion("v1.2.3-beta.1"), SemanticVersion(1, 2, 3))
        XCTAssertEqual(SemanticVersion("2.0"), SemanticVersion(2, 0, 0))
        XCTAssertNil(SemanticVersion("abc"))
        XCTAssertLessThan(SemanticVersion(0, 9, 9), SemanticVersion(0, 10, 0))
        XCTAssertNil(MagpieCompatibility.check(hostVersion: nil))
    }
}

final class HostStoreTests: XCTestCase {
    private func makeStore() -> (HostStore, InMemoryKeychainStore) {
        let keychain = InMemoryKeychainStore()
        return (HostStore(persistence: InMemoryHostListPersistence(), keychain: keychain), keychain)
    }

    func testFirstHostBecomesActiveAndSwitching() throws {
        let (store, _) = makeStore()
        let a = try XCTUnwrap(HostProfile(name: "A", address: "100.64.0.1"))
        let b = try XCTUnwrap(HostProfile(name: "B", address: "my-mac.tailnet.example"))
        try store.save(a)
        var list = try store.save(b)
        XCTAssertEqual(list.active?.id, a.id)
        list = store.activate(b.id)
        XCTAssertEqual(list.active?.id, b.id)
        XCTAssertEqual(store.load().active?.id, b.id)
        var copy = list
        XCTAssertFalse(copy.activate(UUID()))
    }

    func testSecretsAreSavedPerHostAndRemovedWithHost() throws {
        let (store, keychain) = makeStore()
        let a = try XCTUnwrap(HostProfile(name: "A", address: "100.64.0.1"))
        let b = try XCTUnwrap(HostProfile(name: "B", address: "100.64.0.2"))
        try store.save(a, secrets: [.gatewayKey: "sk-magpie-key-EXAMPLE", .webKey: "web-key-EXAMPLE"])
        try store.save(b, secrets: [.gatewayKey: "sk-magpie-key-EXAMPLE-2"])
        XCTAssertEqual(store.secret(.gatewayKey, host: a.id), "sk-magpie-key-EXAMPLE")
        XCTAssertEqual(store.secret(.gatewayKey, host: b.id), "sk-magpie-key-EXAMPLE-2")
        XCTAssertTrue(keychain.hasSecret(.webKey, host: a.id))
        XCTAssertFalse(keychain.hasSecret(.issuerKey, host: a.id))

        // 传空字符串 = 清除
        try store.save(a, secrets: [.webKey: ""])
        XCTAssertFalse(keychain.hasSecret(.webKey, host: a.id))

        let list = try store.remove(a.id)
        XCTAssertEqual(list.hosts.map(\.id), [b.id])
        XCTAssertEqual(list.active?.id, b.id)
        XCTAssertNil(store.secret(.gatewayKey, host: a.id))
        XCTAssertNotNil(store.secret(.gatewayKey, host: b.id))
    }

    func testUpdateKeepsOrderAndMove() throws {
        var list = HostList()
        let hosts = (1...3).compactMap { HostProfile(name: "H\($0)", address: "100.64.0.\($0)") }
        hosts.forEach { list.upsert($0) }
        var renamed = hosts[1]
        renamed.name = "改名"
        list.upsert(renamed)
        XCTAssertEqual(list.hosts.map(\.name), ["H1", "改名", "H3"])
        list.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(list.hosts.map(\.name), ["H3", "H1", "改名"])
    }

    func testUserDefaultsPersistenceRoundTrip() throws {
        let suite = "MagpieRemoteCoreTests.\(UUID().uuidString)"
        let persistence = UserDefaultsHostListPersistence(suiteName: suite)
        var list = HostList()
        list.upsert(try XCTUnwrap(HostProfile(name: "A", address: "100.64.0.1")))
        persistence.save(list)
        XCTAssertEqual(persistence.load(), list)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}

final class ChangelogTests: XCTestCase {
    func testParsesReleasesGroupsAndNotes() {
        let text = """
        # 更新日志

        ## [Unreleased]

        ## [0.2.0] - 2026-12-01 · minor（次版本） · 对话
        > 需要 magpie 新版本
        ### 新增
        - 对话页
        - 流式输出
        ### 修复
        - 小问题

        ## [0.1.0] - 2026-11-01 · minor（次版本） · 首个版本
        - 没有分组的条目
        """
        let releases = Changelog.parse(text)
        XCTAssertEqual(releases.map(\.version), ["0.2.0", "0.1.0"])
        XCTAssertEqual(releases[0].date, "2026-12-01")
        XCTAssertEqual(releases[0].level, "minor（次版本）")
        XCTAssertEqual(releases[0].theme, "对话")
        XCTAssertEqual(releases[0].note, "需要 magpie 新版本")
        XCTAssertEqual(releases[0].groups.map(\.title), ["新增", "修复"])
        XCTAssertEqual(releases[0].groups[0].items, ["对话页", "流式输出"])
        XCTAssertEqual(releases[1].groups.first?.items, ["没有分组的条目"])
    }
}
