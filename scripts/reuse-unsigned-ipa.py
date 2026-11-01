#!/usr/bin/env python3
"""「未签名 IPA」复用：把 PR 上已全绿、同一文件树构建的未签名 IPA 改写 build 号后发布。

只做两件事，其余字节原样保留：
1. 核对 IPA 里 MagpieRemote.app/Info.plist 的 CFBundleShortVersionString 等于 project.yml 的 MARKETING_VERSION；
2. 把 CFBundleVersion 改写为本次工作流的 build 号（MAGPIE_REMOTE_BUILD_NUMBER = run_number，严格递增），
   App 与 PlugIns/ 下每个扩展（小组件）都改——扩展的版本号必须与 App 相同；ZIP 内其它条目（含权限位、时间戳）逐条复制。
包里的临时（ad-hoc）签名只是为了让自签工具读到 App Group 声明，改 Info.plist 后它的封印失效没有关系：
安装前自签工具会整个重新签名，而 App Group 声明在可执行文件里，不受影响。

用法：reuse-unsigned-ipa.py <输入 ipa> <输出 ipa> <build 号> <期望版本>
输出一行 JSON：{"version": ..., "build": ..., "original_build": ...}
"""
from __future__ import annotations

import json
import plistlib
import re
import sys
import zipfile

PLIST = re.compile(r"^Payload/[^/]+\.app/Info\.plist$")
EXTENSION_PLIST = re.compile(r"^Payload/[^/]+\.app/PlugIns/[^/]+\.appex/Info\.plist$")


def load(raw: bytes) -> tuple[dict, int]:
    return plistlib.loads(raw), (plistlib.FMT_BINARY if raw.startswith(b"bplist") else plistlib.FMT_XML)


def main() -> None:
    source, target, build, expected_version = sys.argv[1:5]
    if not re.fullmatch(r"[1-9][0-9]*", build):
        raise SystemExit(f"build 号必须是正整数：{build}")
    with zipfile.ZipFile(source) as zin:
        names = [info.filename for info in zin.infolist() if PLIST.match(info.filename)]
        if len(names) != 1:
            raise SystemExit(f"IPA 里应恰好有一个 Payload/*.app/Info.plist，实际 {names}")
        plist_name = names[0]
        info, fmt = load(zin.read(plist_name))
        version = info.get("CFBundleShortVersionString")
        if version != expected_version:
            raise SystemExit(f"IPA 版本 {version} 与工程 MARKETING_VERSION {expected_version} 不一致")
        original_build = info.get("CFBundleVersion")
        info["CFBundleVersion"] = build
        patched = {plist_name: plistlib.dumps(info, fmt=fmt, sort_keys=False)}
        extensions = [i.filename for i in zin.infolist() if EXTENSION_PLIST.match(i.filename)]
        if not any(n.endswith("/PlugIns/MagpieRemoteWidgets.appex/Info.plist") for n in extensions):
            raise SystemExit("IPA 里缺少小组件扩展 Payload/MagpieRemote.app/PlugIns/MagpieRemoteWidgets.appex")
        for name in extensions:
            ext, ext_fmt = load(zin.read(name))
            if ext.get("CFBundleShortVersionString") != version:
                raise SystemExit(f"扩展 {name} 的版本 {ext.get('CFBundleShortVersionString')} 与 App {version} 不一致")
            ext["CFBundleVersion"] = build
            patched[name] = plistlib.dumps(ext, fmt=ext_fmt, sort_keys=False)
        with zipfile.ZipFile(target, "w") as zout:
            for item in zin.infolist():
                data = patched.get(item.filename)
                if data is None:
                    data = zin.read(item.filename)
                zout.writestr(item, data, compress_type=item.compress_type)
    with zipfile.ZipFile(target) as check:
        if check.testzip() is not None:
            raise SystemExit("改写后的 IPA 校验失败")
        for name in [plist_name, *extensions]:
            info = plistlib.loads(check.read(name))
            if info.get("CFBundleVersion") != build or info.get("CFBundleShortVersionString") != expected_version:
                raise SystemExit(f"改写后的 {name} 不符合预期")
    print(json.dumps({"version": version, "build": build, "original_build": original_build,
                      "extensions": len(extensions)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
