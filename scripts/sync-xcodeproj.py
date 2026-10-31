#!/usr/bin/env python3
"""按 project.yml 的结构重写 MagpieRemote.xcodeproj（project.pbxproj 与共享 scheme），不需要 Xcode / XcodeGen。

仓库同时提交 project.yml（XcodeGen 定义）与生成后的工程。没有 XcodeGen 的环境（例如在 Linux 上改代码）
新增 / 删除源文件后运行本脚本即可；有 XcodeGen 时也可以用 `xcodegen generate`，两者产出的工程结构一致
（对象 ID 不同不影响构建）。对象 ID 由名称确定性生成，重复运行结果不变，便于审查差异。

只支持本仓库用到的结构：一个 App target（MagpieRemoteApp/ 下的源文件与资源 + CHANGELOG.md）、
一个 UI 测试 target（MagpieRemoteUITests/）、一个本地 Swift 包（MagpieRemoteCore）。
用法：python3 scripts/sync-xcodeproj.py [--check]
"""
from __future__ import annotations

import hashlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJ = ROOT / "MagpieRemote.xcodeproj"
PBXPROJ = PROJ / "project.pbxproj"
SCHEME = PROJ / "xcshareddata" / "xcschemes" / "MagpieRemote.xcscheme"
WORKSPACE = PROJ / "project.xcworkspace" / "contents.xcworkspacedata"
APP = "MagpieRemote"
APP_DIR = "MagpieRemoteApp"
UI = "MagpieRemoteUITests"
CORE = "MagpieRemoteCore"
BUNDLE_ID = "com.magpieremote.personal"
EXCLUDED = {"Info.plist", ".DS_Store"}
FILE_TYPES = {
    ".swift": "sourcecode.swift",
    ".xcassets": "folder.assetcatalog",
    ".md": "net.daringfireball.markdown",
    ".plist": "text.plist.xml",
    ".json": "text.json",
}


def oid(*parts: str) -> str:
    return hashlib.md5("/".join(parts).encode()).hexdigest()[:24].upper()


def project_values() -> dict[str, str]:
    text = (ROOT / "project.yml").read_text(encoding="utf-8")
    values = {}
    for key in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION", "SWIFT_VERSION"):
        m = re.search(rf"^\s*{key}:\s*\"?([^\"\s#]+)\"?", text, re.M)
        if not m:
            raise SystemExit(f"project.yml 缺少 {key}")
        values[key] = m.group(1)
    m = re.search(r"iOS:\s*\"?([0-9.]+)\"?", text)
    values["IPHONEOS_DEPLOYMENT_TARGET"] = m.group(1) if m else "26.0"
    return values


def quote(value: str) -> str:
    return value if re.fullmatch(r"[A-Za-z0-9_./$]+", value) and not value.startswith("$(") or value.isidentifier() else f'"{value}"'


def settings_block(settings: dict[str, object], indent: str = "\t\t\t\t") -> str:
    lines = []
    for key in sorted(settings):
        value = settings[key]
        if isinstance(value, list):
            lines.append(f"{indent}{key} = (")
            for item in value:
                lines.append(f'{indent}\t"{item}",')
            lines.append(f"{indent});")
        else:
            lines.append(f"{indent}{key} = {quote(str(value))};")
    return "\n".join(lines)


class Tree:
    """一个目录对应一个 PBXGroup；文件与 .xcassets 是叶子。"""

    def __init__(self, rel: str):
        self.rel = rel
        self.groups: list[Tree] = []
        self.files: list[str] = []  # 相对 ROOT 的路径

    @classmethod
    def scan(cls, rel: str) -> "Tree":
        node = cls(rel)
        for child in sorted((ROOT / rel).iterdir(), key=lambda p: p.name.lower()):
            if child.name in EXCLUDED or child.name.startswith("."):
                continue
            child_rel = f"{rel}/{child.name}"
            if child.is_dir() and child.suffix != ".xcassets":
                node.groups.append(cls.scan(child_rel))
            else:
                node.files.append(child_rel)
        return node

    def all_files(self) -> list[str]:
        out = list(self.files)
        for group in self.groups:
            out += group.all_files()
        return out


def generate() -> tuple[str, str]:
    v = project_values()
    app_tree = Tree.scan(APP_DIR)
    ui_tree = Tree.scan(UI)

    ids = {
        "project": oid("project"), "main": oid("group", "main"), "products": oid("group", "Products"),
        "packages": oid("group", "Packages"), "app_target": oid("target", APP), "ui_target": oid("target", UI),
        "app_product": oid("product", APP), "ui_product": oid("product", UI),
        "app_sources": oid("phase", APP, "Sources"), "app_resources": oid("phase", APP, "Resources"),
        "app_frameworks": oid("phase", APP, "Frameworks"), "ui_sources": oid("phase", UI, "Sources"),
        "proxy": oid("proxy"), "dependency": oid("dependency"),
        "core_ref": oid("file", CORE), "core_pkg": oid("package", CORE), "core_product": oid("productdep", CORE),
        "core_build": oid("build", CORE), "changelog_ref": oid("file", "CHANGELOG.md"),
        "changelog_build": oid("build", "CHANGELOG.md"),
        "cfg_project": oid("cfglist", "project"), "cfg_app": oid("cfglist", APP), "cfg_ui": oid("cfglist", UI),
    }
    for scope in ("project", APP, UI):
        for config in ("Debug", "Release"):
            ids[f"cfg_{scope}_{config}"] = oid("config", scope, config)

    build_files: list[str] = []
    file_refs: list[str] = []
    groups: list[str] = []
    app_sources: list[str] = []
    app_resources: list[str] = []
    ui_sources: list[str] = []

    def file_ref(path: str) -> str:
        name = Path(path).name
        kind = FILE_TYPES.get(Path(path).suffix, "file")
        ref = oid("file", path)
        type_attr = f"lastKnownFileType = {kind}; " if kind != "file" else ""
        if name == "PrivacyInfo.xcprivacy":
            type_attr = "lastKnownFileType = text.xml; "
        file_refs.append(f'\t\t{ref} /* {name} */ = {{isa = PBXFileReference; {type_attr}path = {quote(name)}; sourceTree = "<group>"; }};')
        return ref

    def add_tree(node: Tree, target: str) -> str:
        children = []
        for group in node.groups:
            children.append((Path(group.rel).name, add_tree(group, target)))
        for path in node.files:
            name = Path(path).name
            ref = file_ref(path)
            children.append((name, ref))
            build = oid("build", path)
            if path.endswith(".swift"):
                build_files.append(f"\t\t{build} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};")
                (app_sources if target == APP else ui_sources).append(f"\t\t\t\t{build} /* {name} in Sources */,")
            elif target == APP:
                build_files.append(f"\t\t{build} /* {name} in Resources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};")
                app_resources.append(f"\t\t\t\t{build} /* {name} in Resources */,")
        gid = oid("group", node.rel)
        name = Path(node.rel).name
        child_lines = "\n".join(f"\t\t\t\t{cid} /* {cname} */," for cname, cid in sorted(children, key=lambda c: c[0].lower()))
        groups.append(f'\t\t{gid} /* {name} */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{child_lines}\n\t\t\t);\n\t\t\tpath = {quote(name)};\n\t\t\tsourceTree = "<group>";\n\t\t}};')
        return gid

    app_group = add_tree(app_tree, APP)
    ui_group = add_tree(ui_tree, UI)

    build_files.append(f"\t\t{ids['changelog_build']} /* CHANGELOG.md in Resources */ = {{isa = PBXBuildFile; fileRef = {ids['changelog_ref']} /* CHANGELOG.md */; }};")
    app_resources.insert(0, f"\t\t\t\t{ids['changelog_build']} /* CHANGELOG.md in Resources */,")
    build_files.append(f"\t\t{ids['core_build']} /* {CORE} in Frameworks */ = {{isa = PBXBuildFile; productRef = {ids['core_product']} /* {CORE} */; }};")
    file_refs += [
        f'\t\t{ids["changelog_ref"]} /* CHANGELOG.md */ = {{isa = PBXFileReference; lastKnownFileType = net.daringfireball.markdown; path = CHANGELOG.md; sourceTree = "<group>"; }};',
        f"\t\t{ids['core_ref']} /* {CORE} */ = {{isa = PBXFileReference; lastKnownFileType = folder; name = {CORE}; path = {CORE}; sourceTree = SOURCE_ROOT; }};",
        f"\t\t{ids['app_product']} /* {APP}.app */ = {{isa = PBXFileReference; includeInIndex = 0; lastKnownFileType = wrapper.application; path = {APP}.app; sourceTree = BUILT_PRODUCTS_DIR; }};",
        f"\t\t{ids['ui_product']} /* {UI}.xctest */ = {{isa = PBXFileReference; includeInIndex = 0; lastKnownFileType = wrapper.cfbundle; path = {UI}.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};",
    ]
    groups += [
        f'\t\t{ids["main"]} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{ids["changelog_ref"]} /* CHANGELOG.md */,\n\t\t\t\t{app_group} /* {APP_DIR} */,\n\t\t\t\t{ui_group} /* {UI} */,\n\t\t\t\t{ids["packages"]} /* Packages */,\n\t\t\t\t{ids["products"]} /* Products */,\n\t\t\t);\n\t\t\tsourceTree = "<group>";\n\t\t}};',
        f'\t\t{ids["packages"]} /* Packages */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{ids["core_ref"]} /* {CORE} */,\n\t\t\t);\n\t\t\tname = Packages;\n\t\t\tsourceTree = "<group>";\n\t\t}};',
        f'\t\t{ids["products"]} /* Products */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{ids["app_product"]} /* {APP}.app */,\n\t\t\t\t{ids["ui_product"]} /* {UI}.xctest */,\n\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = "<group>";\n\t\t}};',
    ]

    common = {
        "ALWAYS_SEARCH_USER_PATHS": "NO", "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
        "CLANG_ANALYZER_NONNULL": "YES", "CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION": "YES_AGGRESSIVE",
        "CLANG_CXX_LANGUAGE_STANDARD": "gnu++14", "CLANG_CXX_LIBRARY": "libc++", "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES", "CLANG_ENABLE_OBJC_WEAK": "YES",
        "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING": "YES", "CLANG_WARN_BOOL_CONVERSION": "YES", "CLANG_WARN_COMMA": "YES",
        "CLANG_WARN_CONSTANT_CONVERSION": "YES", "CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS": "YES",
        "CLANG_WARN_DIRECT_OBJC_ISA_USAGE": "YES_ERROR", "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
        "CLANG_WARN_EMPTY_BODY": "YES", "CLANG_WARN_ENUM_CONVERSION": "YES", "CLANG_WARN_INFINITE_RECURSION": "YES",
        "CLANG_WARN_INT_CONVERSION": "YES", "CLANG_WARN_NON_LITERAL_NULL_CONVERSION": "YES",
        "CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF": "YES", "CLANG_WARN_OBJC_LITERAL_CONVERSION": "YES",
        "CLANG_WARN_OBJC_ROOT_CLASS": "YES_ERROR", "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER": "YES",
        "CLANG_WARN_RANGE_LOOP_ANALYSIS": "YES", "CLANG_WARN_STRICT_PROTOTYPES": "YES", "CLANG_WARN_SUSPICIOUS_MOVE": "YES",
        "CLANG_WARN_UNGUARDED_AVAILABILITY": "YES_AGGRESSIVE", "CLANG_WARN_UNREACHABLE_CODE": "YES",
        "CLANG_WARN__DUPLICATE_METHOD_MATCH": "YES", "CODE_SIGN_STYLE": "Automatic", "COPY_PHASE_STRIP": "NO",
        "CURRENT_PROJECT_VERSION": v["CURRENT_PROJECT_VERSION"], "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES", "GCC_C_LANGUAGE_STANDARD": "gnu11", "GCC_NO_COMMON_BLOCKS": "YES",
        "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES", "GCC_WARN_ABOUT_RETURN_TYPE": "YES_ERROR",
        "GCC_WARN_UNDECLARED_SELECTOR": "YES", "GCC_WARN_UNINITIALIZED_AUTOS": "YES_AGGRESSIVE",
        "GCC_WARN_UNUSED_FUNCTION": "YES", "GCC_WARN_UNUSED_VARIABLE": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": v["IPHONEOS_DEPLOYMENT_TARGET"], "MARKETING_VERSION": v["MARKETING_VERSION"],
        "MTL_FAST_MATH": "YES", "PRODUCT_NAME": "$(TARGET_NAME)", "SDKROOT": "iphoneos", "SWIFT_VERSION": v["SWIFT_VERSION"],
    }
    project_debug = dict(common, DEBUG_INFORMATION_FORMAT="dwarf", ENABLE_TESTABILITY="YES", GCC_DYNAMIC_NO_PIC="NO",
                         GCC_OPTIMIZATION_LEVEL="0", GCC_PREPROCESSOR_DEFINITIONS=["$(inherited)", "DEBUG=1"],
                         MTL_ENABLE_DEBUG_INFO="INCLUDE_SOURCE", ONLY_ACTIVE_ARCH="YES",
                         SWIFT_ACTIVE_COMPILATION_CONDITIONS="DEBUG", SWIFT_OPTIMIZATION_LEVEL="-Onone")
    project_release = dict(common, DEBUG_INFORMATION_FORMAT="dwarf-with-dsym", ENABLE_NS_ASSERTIONS="NO",
                           MTL_ENABLE_DEBUG_INFO="NO", SWIFT_COMPILATION_MODE="wholemodule", SWIFT_OPTIMIZATION_LEVEL="-O")
    app_settings = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon", "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_IDENTITY": "iPhone Developer", "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": f"{APP_DIR}/Info.plist", "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID, "PRODUCT_NAME": APP, "SDKROOT": "iphoneos",
        "SUPPORTS_MACCATALYST": "NO", "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO", "TARGETED_DEVICE_FAMILY": "1,2",
    }
    ui_settings = {
        "BUNDLE_LOADER": "$(TEST_HOST)", "GENERATE_INFOPLIST_FILE": "YES",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"],
        "PRODUCT_BUNDLE_IDENTIFIER": f"{BUNDLE_ID}.uitests", "SDKROOT": "iphoneos", "TARGETED_DEVICE_FAMILY": "1,2",
        "TEST_TARGET_NAME": APP,
    }
    configs = []
    for scope, debug, release in (("project", project_debug, project_release), (APP, app_settings, app_settings), (UI, ui_settings, ui_settings)):
        for config, settings in (("Debug", debug), ("Release", release)):
            configs.append(f"\t\t{ids[f'cfg_{scope}_{config}']} /* {config} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{settings_block(settings)}\n\t\t\t}};\n\t\t\tname = {config};\n\t\t}};")

    def config_list(key: str, scope: str, label: str) -> str:
        return (f"\t\t{ids[key]} /* Build configuration list for {label} */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n"
                f"\t\t\t\t{ids[f'cfg_{scope}_Debug']} /* Debug */,\n\t\t\t\t{ids[f'cfg_{scope}_Release']} /* Release */,\n\t\t\t);\n"
                f"\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Debug;\n\t\t}};")

    def phase(pid: str, isa: str, name: str, files: list[str]) -> str:
        body = "\n".join(files)
        return f"\t\t{pid} /* {name} */ = {{\n\t\t\tisa = {isa};\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n{body}\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};"

    def section(name: str, entries: list[str]) -> str:
        return f"/* Begin {name} section */\n" + "\n".join(entries) + f"\n/* End {name} section */\n"

    by_id = lambda lines: sorted(lines, key=lambda l: l.strip())
    out = ["// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 77;\n\tobjects = {\n\n"]
    out.append(section("PBXBuildFile", by_id(build_files)) + "\n")
    out.append(section("PBXContainerItemProxy", [
        f"\t\t{ids['proxy']} /* PBXContainerItemProxy */ = {{\n\t\t\tisa = PBXContainerItemProxy;\n\t\t\tcontainerPortal = {ids['project']} /* Project object */;\n\t\t\tproxyType = 1;\n\t\t\tremoteGlobalIDString = {ids['app_target']};\n\t\t\tremoteInfo = {APP};\n\t\t}};"]) + "\n")
    out.append(section("PBXFileReference", by_id(file_refs)) + "\n")
    out.append(section("PBXFrameworksBuildPhase", [phase(ids["app_frameworks"], "PBXFrameworksBuildPhase", "Frameworks", [f"\t\t\t\t{ids['core_build']} /* {CORE} in Frameworks */,"])]) + "\n")
    out.append(section("PBXGroup", by_id(groups)) + "\n")
    out.append(section("PBXNativeTarget", [
        f"\t\t{ids['app_target']} /* {APP} */ = {{\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = {ids['cfg_app']} /* Build configuration list for PBXNativeTarget \"{APP}\" */;\n\t\t\tbuildPhases = (\n\t\t\t\t{ids['app_sources']} /* Sources */,\n\t\t\t\t{ids['app_resources']} /* Resources */,\n\t\t\t\t{ids['app_frameworks']} /* Frameworks */,\n\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n\t\t\tname = {APP};\n\t\t\tpackageProductDependencies = (\n\t\t\t\t{ids['core_product']} /* {CORE} */,\n\t\t\t);\n\t\t\tproductName = {APP};\n\t\t\tproductReference = {ids['app_product']} /* {APP}.app */;\n\t\t\tproductType = \"com.apple.product-type.application\";\n\t\t}};",
        f"\t\t{ids['ui_target']} /* {UI} */ = {{\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = {ids['cfg_ui']} /* Build configuration list for PBXNativeTarget \"{UI}\" */;\n\t\t\tbuildPhases = (\n\t\t\t\t{ids['ui_sources']} /* Sources */,\n\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t\t{ids['dependency']} /* PBXTargetDependency */,\n\t\t\t);\n\t\t\tname = {UI};\n\t\t\tpackageProductDependencies = (\n\t\t\t);\n\t\t\tproductName = {UI};\n\t\t\tproductReference = {ids['ui_product']} /* {UI}.xctest */;\n\t\t\tproductType = \"com.apple.product-type.bundle.ui-testing\";\n\t\t}};",
    ]) + "\n")
    out.append(section("PBXProject", [
        f"\t\t{ids['project']} /* Project object */ = {{\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {{\n\t\t\t\tBuildIndependentTargetsInParallel = YES;\n\t\t\t\tLastUpgradeCheck = 1430;\n\t\t\t\tTargetAttributes = {{\n\t\t\t\t\t{ids['app_target']} = {{\n\t\t\t\t\t\tProvisioningStyle = Automatic;\n\t\t\t\t\t}};\n\t\t\t\t\t{ids['ui_target']} = {{\n\t\t\t\t\t\tProvisioningStyle = Automatic;\n\t\t\t\t\t\tTestTargetID = {ids['app_target']};\n\t\t\t\t\t}};\n\t\t\t\t}};\n\t\t\t}};\n\t\t\tbuildConfigurationList = {ids['cfg_project']} /* Build configuration list for PBXProject \"{APP}\" */;\n\t\t\tdevelopmentRegion = \"zh-Hans\";\n\t\t\thasScannedForEncodings = 0;\n\t\t\tknownRegions = (\n\t\t\t\tBase,\n\t\t\t\t\"zh-Hans\",\n\t\t\t);\n\t\t\tmainGroup = {ids['main']};\n\t\t\tminimizedProjectReferenceProxies = 1;\n\t\t\tpackageReferences = (\n\t\t\t\t{ids['core_pkg']} /* XCLocalSwiftPackageReference \"{CORE}\" */,\n\t\t\t);\n\t\t\tpreferredProjectObjectVersion = 77;\n\t\t\tproductRefGroup = {ids['products']} /* Products */;\n\t\t\tprojectDirPath = \"\";\n\t\t\tprojectRoot = \"\";\n\t\t\ttargets = (\n\t\t\t\t{ids['app_target']} /* {APP} */,\n\t\t\t\t{ids['ui_target']} /* {UI} */,\n\t\t\t);\n\t\t}};"]) + "\n")
    out.append(section("PBXResourcesBuildPhase", [phase(ids["app_resources"], "PBXResourcesBuildPhase", "Resources", app_resources)]) + "\n")
    out.append(section("PBXSourcesBuildPhase", by_id([
        phase(ids["app_sources"], "PBXSourcesBuildPhase", "Sources", sorted(app_sources, key=lambda l: l.split("/* ")[1].lower())),
        phase(ids["ui_sources"], "PBXSourcesBuildPhase", "Sources", sorted(ui_sources, key=lambda l: l.split("/* ")[1].lower())),
    ])) + "\n")
    out.append(section("PBXTargetDependency", [
        f"\t\t{ids['dependency']} /* PBXTargetDependency */ = {{\n\t\t\tisa = PBXTargetDependency;\n\t\t\ttarget = {ids['app_target']} /* {APP} */;\n\t\t\ttargetProxy = {ids['proxy']} /* PBXContainerItemProxy */;\n\t\t}};"]) + "\n")
    out.append(section("XCBuildConfiguration", by_id(configs)) + "\n")
    out.append(section("XCConfigurationList", by_id([
        config_list("cfg_project", "project", f'PBXProject "{APP}"'),
        config_list("cfg_app", APP, f'PBXNativeTarget "{APP}"'),
        config_list("cfg_ui", UI, f'PBXNativeTarget "{UI}"'),
    ])) + "\n")
    out.append(section("XCLocalSwiftPackageReference", [
        f"\t\t{ids['core_pkg']} /* XCLocalSwiftPackageReference \"{CORE}\" */ = {{\n\t\t\tisa = XCLocalSwiftPackageReference;\n\t\t\trelativePath = {CORE};\n\t\t}};"]) + "\n")
    out.append(section("XCSwiftPackageProductDependency", [
        f"\t\t{ids['core_product']} /* {CORE} */ = {{\n\t\t\tisa = XCSwiftPackageProductDependency;\n\t\t\tproductName = {CORE};\n\t\t}};"]))
    out.append(f"\t}};\n\trootObject = {ids['project']} /* Project object */;\n}}\n")
    pbx = "".join(out)

    def ref(target_id: str, product: str, name: str) -> str:
        return (f'            <BuildableReference\n               BuildableIdentifier = "primary"\n               BlueprintIdentifier = "{target_id}"\n'
                f'               BuildableName = "{product}"\n               BlueprintName = "{name}"\n               ReferencedContainer = "container:{APP}.xcodeproj">\n            </BuildableReference>')
    app_ref = ref(ids["app_target"], f"{APP}.app", APP)
    ui_ref = ref(ids["ui_target"], f"{UI}.xctest", UI)
    indent = lambda text, n: "\n".join((" " * n + line[12:]) if line.startswith(" " * 12) else line for line in text.split("\n"))
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1430"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES"
      runPostActionsOnFailure = "NO">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
{app_ref}
         </BuildActionEntry>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "NO"
            buildForProfiling = "NO"
            buildForArchiving = "NO"
            buildForAnalyzing = "NO">
{ui_ref}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES"
      onlyGenerateCoverageForSpecifiedTargets = "NO">
      <MacroExpansion>
{indent(app_ref, 12)}
      </MacroExpansion>
      <Testables>
         <TestableReference
            skipped = "NO"
            parallelizable = "NO">
{indent(ui_ref, 15)}
         </TestableReference>
      </Testables>
      <CommandLineArguments>
      </CommandLineArguments>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
{indent(app_ref, 12)}
      </BuildableProductRunnable>
      <CommandLineArguments>
      </CommandLineArguments>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
{indent(app_ref, 12)}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
'''
    return pbx, scheme


WORKSPACE_XML = '<?xml version="1.0" encoding="UTF-8"?>\n<Workspace\n   version = "1.0">\n   <FileRef\n      location = "self:">\n   </FileRef>\n</Workspace>\n'


def main() -> int:
    pbx, scheme = generate()
    wanted = {PBXPROJ: pbx, SCHEME: scheme, WORKSPACE: WORKSPACE_XML}
    if "--check" in sys.argv:
        stale = [p for p, text in wanted.items() if not p.exists() or p.read_text(encoding="utf-8") != text]
        if stale:
            print("MagpieRemote.xcodeproj 不是 scripts/sync-xcodeproj.py 的最新输出（运行它后提交）：", file=sys.stderr)
            for p in stale:
                print(f"  - {p.relative_to(ROOT)}", file=sys.stderr)
            return 1
        print("MagpieRemote.xcodeproj 与 sync-xcodeproj.py 输出一致。")
        return 0
    for path, text in wanted.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    print(f"已写入 {PBXPROJ.relative_to(ROOT)} 与共享 scheme。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
