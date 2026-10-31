#!/usr/bin/env python3
"""检查提交的 MagpieRemote.xcodeproj 是否收录了 App 与 UI 测试目录下的全部 Swift 源文件。

project.yml 是 XcodeGen 定义，但仓库同时提交生成后的 .xcodeproj（CI 不跑 XcodeGen）；新增文件时
容易漏掉 PBXFileReference / PBXBuildFile。这里只按文件名比对，不要求安装 XcodeGen。
修复：`python3 scripts/sync-xcodeproj.py`（或 `xcodegen generate`）后提交。
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PBXPROJ = ROOT / "MagpieRemote.xcodeproj" / "project.pbxproj"
SOURCE_DIRS = ("MagpieRemoteApp", "MagpieRemoteUITests")
RESOURCES = ("CHANGELOG.md", "Assets.xcassets", "PrivacyInfo.xcprivacy")


def main() -> int:
    text = PBXPROJ.read_text(encoding="utf-8")
    file_refs = set(re.findall(r"/\* ([^*/]+\.swift) \*/ = \{isa = PBXFileReference;", text))
    build_files = set(re.findall(r"/\* ([^*/]+\.swift) in Sources \*/ = \{isa = PBXBuildFile;", text))
    on_disk: dict[str, Path] = {}
    problems: list[str] = []
    for directory in SOURCE_DIRS:
        for path in (ROOT / directory).rglob("*.swift"):
            if path.name in on_disk:
                problems.append(f"文件名重复（工程按文件名比对）：{path.relative_to(ROOT)}")
            on_disk[path.name] = path

    for name, path in sorted(on_disk.items()):
        rel = path.relative_to(ROOT)
        if name not in file_refs:
            problems.append(f"缺少文件引用：{rel}")
        if name not in build_files:
            problems.append(f"未加入编译阶段：{rel}")
    for name in sorted(file_refs - set(on_disk)):
        problems.append(f"工程引用了不存在的文件：{name}")
    for name in RESOURCES:
        if f"/* {name} in Resources */ = {{isa = PBXBuildFile;" not in text:
            problems.append(f"资源未加入 App：{name}")

    if problems:
        print("MagpieRemote.xcodeproj 与源文件不同步（执行 `python3 scripts/sync-xcodeproj.py` 或 `xcodegen generate`）：", file=sys.stderr)
        for line in problems:
            print(f"  - {line}", file=sys.stderr)
        return 1
    print(f"MagpieRemote.xcodeproj 已收录全部 {len(on_disk)} 个 Swift 源文件与 {len(RESOURCES)} 项资源。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
