#!/usr/bin/env python3
"""「iOS」工作流的改动判定：这次改动需要跑哪些 job（结果写入 $GITHUB_OUTPUT）。

输出：
  ios=true|false    需要 macOS（编译 + UI 测试 + 未签名 IPA）
  core=true|false   需要 Ubuntu 上的 MagpieRemoteCore 单元测试
  changes=<说明>    一行中文说明

改动文件来源（只用 GitHub API，不需要完整 Git 历史）：
  pull_request → PR 的文件列表；push → before...after 的对比；其他事件（workflow_dispatch 等）→ 全部执行。
任何一步拿不到文件列表（API 失败、文件过多、新分支）都按「全部执行」处理，宁可多跑不可漏跑。

规则（每个文件按第一条匹配的规则归类；没有匹配的文件 = 两者都要跑）：
  - 文档、契约（contract/ 与契约工作流）：都不需要；
  - MagpieRemoteCore/Tests/**：只要 Core 单元测试；
  - MagpieRemoteCore 其他文件（源码、Package.swift）：两者都要；
  - App、UI 测试、工程、CHANGELOG.md（随 App 打包，「关于」页 UI 测试会检查）、只给 iOS 用的脚本：只要 macOS。

本地调试：python3 scripts/ci-changes.py --files a.swift b.md
"""
from __future__ import annotations

import fnmatch
import json
import os
import sys
import urllib.request

NONE, CORE, IOS, BOTH = (False, False), (False, True), (True, False), (True, True)

# (模式, (ios, core))；按顺序匹配，先匹配先生效。
RULES: list[tuple[str, tuple[bool, bool]]] = [
    ("CHANGELOG.md", IOS),
    ("README.md", NONE),
    ("DESIGN.md", NONE),
    ("LICENSE", NONE),
    ("docs/*", NONE),
    ("contract/*", NONE),
    (".github/workflows/contract.yml", NONE),
    (".github/workflows/magpie-compat.yml", NONE),
    ("MagpieRemoteCore/Tests/*", CORE),
    ("MagpieRemoteCore/*", BOTH),
    ("MagpieRemoteApp/*", IOS),
    ("MagpieRemoteUITests/*", IOS),
    ("MagpieRemoteWidgets/*", IOS),
    ("MagpieRemote.xcodeproj/*", IOS),
    ("project.yml", IOS),
    (".github/workflows/ios-ipa.yml", IOS),
    ("scripts/build-unsigned.sh", IOS),
    ("scripts/reuse-unsigned-ipa.py", IOS),
    ("scripts/check-ios-version.py", IOS),
    ("scripts/check-xcodeproj-sources.py", IOS),
    ("scripts/sync-xcodeproj.py", IOS),
    ("scripts/ci-select-simulator.py", IOS),
    ("scripts/print-xcresult-failures.py", IOS),
    ("scripts/ui-test-shards.py", IOS),
    ("scripts/ci-sim-dyld-cache.sh", IOS),
    (".github/workflows/sim-cache.yml", IOS),
    # 其他 Markdown（不在 App 包里）：都不需要
    ("*.md", NONE),
]


def classify(path: str) -> tuple[bool, bool]:
    for pattern, result in RULES:
        if fnmatch.fnmatchcase(path, pattern):
            return result
    return BOTH


def api(path: str):
    url = f"{os.environ.get('GITHUB_API_URL', 'https://api.github.com')}/repos/{os.environ['REPO']}/{path}"
    req = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {os.environ['GH_TOKEN']}",
        "Accept": "application/vnd.github+json",
    })
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def changed_files() -> tuple[list[str] | None, str]:
    event = os.environ.get("EVENT", "")
    if event == "pull_request":
        number = os.environ.get("PR_NUMBER", "")
        files: list[str] = []
        for page in range(1, 31):  # API 最多返回 3000 个文件
            batch = api(f"pulls/{number}/files?per_page=100&page={page}")
            for f in batch:
                files.append(f["filename"])
                if f.get("previous_filename"):
                    files.append(f["previous_filename"])
            if len(batch) < 100:
                return files, f"PR #{number}"
        return None, "PR 改动文件过多"
    if event == "push":
        before, after = os.environ.get("BEFORE", ""), os.environ.get("SHA", "")
        if not before or set(before) == {"0"}:
            return None, "新分支，没有可对比的提交"
        data = api(f"compare/{before}...{after}")
        files = data.get("files") or []
        if len(files) >= 300:  # 对比接口最多列出 300 个文件
            return None, "改动文件过多"
        if data.get("status") not in ("ahead", "identical"):
            return None, f"before 与 after 不是线性关系（{data.get('status')}）"
        out = []
        for f in files:
            out.append(f["filename"])
            if f.get("previous_filename"):
                out.append(f["previous_filename"])
        return out, f"{before[:8]}...{after[:8]}"
    return None, f"{event or '未知'} 事件"


def main() -> int:
    if len(sys.argv) > 2 and sys.argv[1] == "--files":
        files, where = sys.argv[2:], "命令行"
    else:
        try:
            files, where = changed_files()
        except Exception as exc:  # noqa: BLE001
            files, where = None, f"读取改动文件失败（{exc}）"

    if files is None:
        ios = core = True
        note = f"{where}：全部执行"
    else:
        ios = any(classify(f)[0] for f in files)
        core = any(classify(f)[1] for f in files)
        parts = []
        parts.append("macOS 编译与 UI 测试" if ios else "跳过 macOS（没有 App 相关改动）")
        parts.append("Core 单元测试" if core else "跳过 Core 单元测试（没有 Core 相关改动）")
        note = f"{where}，{len(files)} 个文件：" + "；".join(parts)
        for f in sorted(set(files))[:50]:
            i, c = classify(f)
            print(f"  {f} → {'iOS ' if i else ''}{'Core' if c else ''}{'无' if not (i or c) else ''}")

    print(note)
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(f"ios={'true' if ios else 'false'}\n")
            fh.write(f"core={'true' if core else 'false'}\n")
            fh.write(f"changes={note}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
