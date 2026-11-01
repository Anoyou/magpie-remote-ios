#!/usr/bin/env python3
"""检查提交的 MagpieRemote.xcodeproj 是否收录了 App 与 UI 测试目录下的全部 Swift 源文件。

project.yml 是 XcodeGen 定义，但仓库同时提交生成后的 .xcodeproj（CI 不跑 XcodeGen）；新增文件时
容易漏掉 PBXFileReference / PBXBuildFile。这里只按文件名比对，不要求安装 XcodeGen。
修复：`python3 scripts/sync-xcodeproj.py`（或 `xcodegen generate`）后提交。
另外核对资源目录：Core 里登记的官方标志（OfficialIconNames.swift）、导航图标、App 图标的图片文件都在
（由 `scripts/gen-official-icons.py` 生成）。
还核对小组件扩展：扩展嵌入 App、共用的源文件 / 资源目录也在扩展里，以及 App Group 名在 project.yml、
两个 .entitlements、Core 的 `WidgetAppGroup.baseIdentifier` 里一致。
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PBXPROJ = ROOT / "MagpieRemote.xcodeproj" / "project.pbxproj"
SOURCE_DIRS = ("MagpieRemoteApp", "MagpieRemoteUITests", "MagpieRemoteWidgets")
ENTITLEMENTS = ("MagpieRemoteApp/MagpieRemote.entitlements", "MagpieRemoteWidgets/MagpieRemoteWidgets.entitlements")
WIDGET_SHARED = ("OfficialIconViews.swift in Sources", "Assets.xcassets in Resources")
APP_GROUP_SWIFT = ROOT / "MagpieRemoteCore" / "Sources" / "MagpieRemoteCore" / "WidgetAppGroup.swift"
RESOURCES = ("CHANGELOG.md", "Assets.xcassets", "PrivacyInfo.xcprivacy")
ASSETS = ROOT / "MagpieRemoteApp" / "Assets.xcassets"
ICON_SWIFT = ROOT / "MagpieRemoteCore" / "Sources" / "MagpieRemoteCore" / "OfficialIcon.swift"
ICON_NAMES = ROOT / "MagpieRemoteCore" / "Sources" / "MagpieRemoteCore" / "OfficialIconNames.swift"


def imageset_problems(folder: Path, name: str) -> list[str]:
    """资源目录里的一个图片集：Contents.json 里写的文件都要在。"""
    d = folder / f"{name}.imageset"
    contents = d / "Contents.json"
    if not contents.is_file():
        return [f"资源目录缺少图片：{d.relative_to(ROOT)}"]
    images = json.loads(contents.read_text(encoding="utf-8")).get("images", [])
    missing = [i["filename"] for i in images if "filename" in i and not (d / i["filename"]).is_file()]
    if not images or missing:
        return [f"图片集缺文件：{d.relative_to(ROOT)} {missing}"]
    return []


def asset_problems() -> list[str]:
    """Core 里写到的官方标志 / 导航图标 / App 图标，资源目录里都要有。"""
    problems: list[str] = []
    bundled = re.search(r"static let bundled: Set<String> = \[(.*?)\]", ICON_NAMES.read_text(encoding="utf-8"), re.S)
    names = re.findall(r'"([^"]+)"', bundled.group(1)) if bundled else []
    if not names:
        problems.append("OfficialIconNames.swift 里没有 bundled 列表")
    for name in names:
        problems += imageset_problems(ASSETS / "Brand", name)
    on_disk = {p.name[: -len(".imageset")] for p in (ASSETS / "Brand").glob("*.imageset")}
    for extra in sorted(on_disk - set(names)):
        problems.append(f"资源目录有未登记的标志：Brand/{extra}（重新运行 scripts/gen-official-icons.py）")
    for glyph in re.findall(r'"Nav/([^"]+)"', ICON_SWIFT.read_text(encoding="utf-8")):
        problems += imageset_problems(ASSETS / "Nav", glyph)
    appicon = ASSETS / "AppIcon.appiconset"
    for image in json.loads((appicon / "Contents.json").read_text(encoding="utf-8"))["images"]:
        if not (appicon / image["filename"]).is_file():
            problems.append(f"App 图标缺文件：{image['filename']}")
    return problems


def widget_problems(text: str) -> list[str]:
    """小组件扩展：嵌入 App、共用文件、App Group 名一致。"""
    problems: list[str] = []
    if "/* MagpieRemoteWidgets.appex in Embed Foundation Extensions */ = {isa = PBXBuildFile;" not in text:
        problems.append("小组件扩展没有嵌入 App（Embed Foundation Extensions）")
    if 'productType = "com.apple.product-type.app-extension";' not in text:
        problems.append("工程里没有小组件扩展 target")
    for item in WIDGET_SHARED:
        if text.count(f"/* {item} */ = {{isa = PBXBuildFile;") != 2:
            problems.append(f"{item.split(' in ')[0]} 应同时在 App 与小组件扩展里")
    m = re.search(r"^\s*MAGPIE_APP_GROUP:\s*\"?([^\"\s#]+)", (ROOT / "project.yml").read_text(encoding="utf-8"), re.M)
    group = m.group(1) if m else None
    if not group:
        return problems + ["project.yml 缺少 MAGPIE_APP_GROUP"]
    if f"MAGPIE_APP_GROUP = {group};" not in text:
        problems.append(f"工程里的 MAGPIE_APP_GROUP 不是 {group}")
    for rel in ENTITLEMENTS:
        if f"<string>{group}</string>" not in (ROOT / rel).read_text(encoding="utf-8"):
            problems.append(f"{rel} 里的 App Group 不是 {group}")
    if f'baseIdentifier = "{group}"' not in APP_GROUP_SWIFT.read_text(encoding="utf-8"):
        problems.append(f"WidgetAppGroup.baseIdentifier 不是 {group}")
    return problems


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

    problems += asset_problems()
    problems += widget_problems(text)

    if problems:
        print("MagpieRemote.xcodeproj 与源文件不同步（执行 `python3 scripts/sync-xcodeproj.py` 或 `xcodegen generate`）：", file=sys.stderr)
        for line in problems:
            print(f"  - {line}", file=sys.stderr)
        return 1
    brand = len(list((ASSETS / "Brand").glob("*.imageset")))
    print(f"MagpieRemote.xcodeproj 已收录全部 {len(on_disk)} 个 Swift 源文件与 {len(RESOURCES)} 项资源"
          f"（资源目录含 {brand} 个官方标志）。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
