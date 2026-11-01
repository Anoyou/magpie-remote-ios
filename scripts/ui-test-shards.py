#!/usr/bin/env python3
"""把 MagpieRemoteUITests 的用例按预计耗时均分到 N 个并行分片（「iOS」工作流用）。

用法：
  python3 scripts/ui-test-shards.py --shards 2 --summary          # 打印每个分片的用例与预计耗时
  python3 scripts/ui-test-shards.py --shards 2 --index 0 --list   # 第 0 片的用例，每行 Class/testName
  python3 scripts/ui-test-shards.py --shards 2 --index 0 --warmup # 第 0 片中预计最短的用例（预热用）

- 用例直接从 MagpieRemoteUITests/*.swift 解析（`class X: XCTestCase` 下的 `func testXxx()`），
  新增的用例不用改任何配置就会自动分到某一片；
- 耗时取自下面 DURATIONS（CI 实测秒数，2026-11 xcode-27 runner），没有记录的用例按 DEFAULT_SECONDS 估计；
- 「分片」现在是同一台 runner 上并行的几台模拟器（scripts/ci-ui-tests.sh），不再是多个 job；
- 用「最长处理时间优先」的贪心法分配：按耗时从大到小，每个用例放进当前预计总耗时最少的分片；
- `--extra 0=60` 给某一片预先加上额外耗时（第 0 片还要打未签名 IPA，约 1 分钟），让各片结束时间接近；
- 结果是确定的：同一份源码、同样参数，每次分法都一样。
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TEST_DIR = ROOT / "MagpieRemoteUITests"
TARGET = "MagpieRemoteUITests"
DEFAULT_SECONDS = 35.0

# CI 实测耗时（秒，run 41286600774，单台模拟器串行时）。只用来均衡分配：各用例之间的相对快慢比绝对值重要，
# 用例改名或耗时明显变化时可以顺手更新，不更新也只是分得没那么均匀。
DURATIONS = {
    "AgentSessionsUITests/testDeleteSessionAsksForConfirmation": 33,
    "AgentSessionsUITests/testListShowsFixtureSessionsAndOpensTranscript": 21,
    "AgentSessionsUITests/testSwitchAgentShowsItsSessions": 24,
    "DockUITests/testCustomizeDockAndRestoreDefault": 99,
    "DockUITests/testDockedPageOpensFromTabAndLeavesMore": 73,
    "HomeUITests/testAgentsNotSetUpAndHiddenStartFolded": 29,
    "HomeUITests/testSegmentsSwitchBetweenAgentsProvidersAndQuota": 52,
    "HostToolsUITests/testHostUpdateDownloadAndRestart": 46,
    "HostToolsUITests/testPrivacyModelTurnOnAndPick": 51,
    "HostToolsUITests/testTuneApplyAllThenUndo": 46,
    "MagpieRemoteUITests/testAboutShowsVersionAndChangelog": 79,
    "MagpieRemoteUITests/testChatCreateAndDeleteSession": 81,
    "MagpieRemoteUITests/testChatSendsMessageAndStreamsReply": 50,
    "MagpieRemoteUITests/testDefaultDockTabs": 26,
    "MagpieRemoteUITests/testFixtureHostConnectsAndShowsQuota": 21,
    "MagpieRemoteUITests/testHostSheetOpensAndAddForm": 20,
    "MagpieRemoteUITests/testOfflineHostShowsChineseError": 21,
    "MagpieRemoteUITests/testSetupGuideOpensFromEmptyState": 17,
    "MagpieRemoteUITests/testUsageFilterToFailed": 87,
    "MagpieRemoteUITests/testUsageHeldKeyShowsOwnRequestsOnly": 60,
    "MagpieRemoteUITests/testUsageOpenRequestDetail": 73,
    "MagpieRemoteUITests/testUsagePeriodSwitch": 29,
    "ManageUITests/testCreateGatewayKeyShowsSecretOnce": 36,
    "ManageUITests/testDeleteProviderAsksForConfirmation": 37,
    "ManageUITests/testProvidersListShowsFixtureProviders": 20,
    "OfficialIconsUITests/testDockTabsKeepTheirTitles": 14,
    "OfficialIconsUITests/testProviderRowsShowNameNotIconAsset": 24,
    "PluginsUITests/testAddPluginFromSpecAsksForConfirmation": 55,
    "PluginsUITests/testDiscoverShowsCommunitySectionsGitHubAndSearch": 78,
    "PluginsUITests/testListShowsInstalledAndBuiltinPlugins": 47,
    "PluginsUITests/testRemovePluginAsksForConfirmationAndTogglesWork": 55,
    "ProviderDetailUITests/testAddAnotherKey": 30,
    "ProviderDetailUITests/testSavedBaseURLAndKeyRevealToggle": 32,
    "QuotaUITests/testAccountsStartCollapsedWithSummary": 19,
    "QuotaUITests/testEmptyStateWhenNoSubscriptionAccounts": 16,
    "QuotaUITests/testExpandedStateKeptAcrossTabs": 28,
    "QuotaUITests/testHeldKeyShowsOwnLimit": 16,
    "QuotaUITests/testHistoryPickerSwitches": 28,
    "QuotaUITests/testTapExpandsAndCollapsesAccount": 21,
    "RoutesUITests/testChangeRoutingFromGroupCard": 29,
    "RoutesUITests/testEditorShowsMemberSpeedsAndRouting": 35,
    "RoutesUITests/testLiveStageShowsRouteThroughGroup": 24,
    "RoutesUITests/testMagpieFliesWithTheRequest": 26,
    "RoutesUITests/testMaskHidesAccounts": 20,
    "RoutesUITests/testRequestListFoldsToTen": 24,
    "UsageTabsUITests/testRequestDetailReadsContent": 65,
    "UsageTabsUITests/testTabsShowRequestsSessionsAndContext": 67,
}

CLASS_RE = re.compile(r"^\s*(?:@\w+\s+)*(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase\b")
FUNC_RE = re.compile(r"^\s*(?:@\w+\s+)*func\s+(test\w*)\s*\(\s*\)")


def discover() -> list[str]:
    tests: list[str] = []
    for path in sorted(TEST_DIR.glob("*.swift")):
        current = None
        for line in path.read_text(encoding="utf-8").splitlines():
            m = CLASS_RE.match(line)
            if m:
                current = m.group(1)
                continue
            m = FUNC_RE.match(line)
            if m and current:
                tests.append(f"{current}/{m.group(1)}")
    return sorted(set(tests))


def split(tests: list[str], shards: int, extra: dict[int, float]) -> list[list[str]]:
    loads = [float(extra.get(i, 0.0)) for i in range(shards)]
    buckets: list[list[str]] = [[] for _ in range(shards)]
    order = sorted(tests, key=lambda t: (-DURATIONS.get(t, DEFAULT_SECONDS), t))
    for test in order:
        i = min(range(shards), key=lambda k: (loads[k], k))
        buckets[i].append(test)
        loads[i] += DURATIONS.get(test, DEFAULT_SECONDS)
    return [sorted(b) for b in buckets]


def parse_extra(values: list[str]) -> dict[int, float]:
    out: dict[int, float] = {}
    for v in values:
        k, _, s = v.partition("=")
        out[int(k)] = float(s)
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--shards", type=int, required=True)
    ap.add_argument("--index", type=int)
    ap.add_argument("--extra", action="append", default=[], help="分片=额外秒数，例如 0=60")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--list", action="store_true")
    g.add_argument("--warmup", action="store_true")
    g.add_argument("--summary", action="store_true")
    args = ap.parse_args()

    tests = discover()
    if not tests:
        print("没有在 MagpieRemoteUITests/*.swift 里找到任何 UI 用例", file=sys.stderr)
        return 1
    buckets = split(tests, args.shards, parse_extra(args.extra))

    if args.summary:
        extra = parse_extra(args.extra)
        for i, b in enumerate(buckets):
            est = sum(DURATIONS.get(t, DEFAULT_SECONDS) for t in b)
            print(f"分片 {i + 1}/{args.shards}：{len(b)} 个用例，预计 {est:.0f} 秒" + (f"（另加 {extra[i]:.0f} 秒）" if i in extra else ""))
            for t in b:
                mark = "" if t in DURATIONS else "（新用例，按 %.0f 秒估计）" % DEFAULT_SECONDS
                print(f"  {t}{mark}")
        return 0

    if args.index is None or not 0 <= args.index < args.shards:
        print("--list / --warmup 需要有效的 --index", file=sys.stderr)
        return 2
    bucket = buckets[args.index]
    if args.warmup:
        if bucket:
            print(min(bucket, key=lambda t: (DURATIONS.get(t, DEFAULT_SECONDS), t)))
        return 0
    for t in bucket:
        print(t)
    return 0


if __name__ == "__main__":
    sys.exit(main())
