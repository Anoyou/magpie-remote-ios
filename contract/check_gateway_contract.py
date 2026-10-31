#!/usr/bin/env python3
"""网关接口的静态契约检查（只用 Python 标准库），与 gen_web_contract.py --check 对应。

    python3 contract/check_gateway_contract.py <magpie 源码目录> [--report report.md]

1. 用 tools/build_contract.py 从给定的 magpie 源码重新生成网关契约（Go 结构体展开 + 源码锚点）；
2. 与已提交的 contract/gateway-contract.json 逐路由、逐字段比较。

判定：
- 失败（退出码 1）：源码锚点缺失、路由消失、核心字段（core: true）被删除 / 改类型 / 由必有变为可选；
- 提示（不失败）：新增字段、非核心字段的变化。App 的解码对新增与非核心字段是宽容的。
差异以中文写到 stdout，并可写入 --report 指定的 Markdown 文件（每周兼容性检查用它开 issue）。
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def key(r):
    return f"{r['method']} {r['path']}"


def main() -> int:
    args = [a for a in sys.argv[1:]]
    report = None
    if "--report" in args:
        i = args.index("--report")
        report = args[i + 1]
        del args[i:i + 2]
    if not args:
        sys.exit(__doc__)
    src = os.path.abspath(args[0])
    committed = json.load(open(os.path.join(HERE, "gateway-contract.json"), encoding="utf-8"))
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "gateway-contract.json")
        gen = subprocess.run([sys.executable, os.path.join(HERE, "tools", "build_contract.py"), src, out],
                             capture_output=True, text=True)
        if not os.path.exists(out):
            print(gen.stdout + gen.stderr)
            print("无法从源码生成网关契约（build_contract.py 失败）")
            return 1
        fresh = json.load(open(out, encoding="utf-8"))

    fails: list[str] = []
    notes: list[str] = []
    for m in fresh.get("anchors_missing") or []:
        fails.append(f"源码锚点缺失：{m}")
    old = {key(r): r for r in committed["routes"]}
    new = {key(r): r for r in fresh["routes"]}
    for k in old:
        if k not in new:
            fails.append(f"路由不再存在于契约生成结果中：{k}")
    for k in new:
        if k not in old:
            notes.append(f"新增路由：{k}")
    for k, r in old.items():
        if k not in new:
            continue
        of = {f["path"]: f for f in r["fields"]}
        nf = {f["path"]: f for f in new[k]["fields"]}
        for p, f in of.items():
            core = f.get("core")
            bucket = fails if core else notes
            tag = "核心字段" if core else "字段"
            g = nf.get(p)
            if g is None:
                bucket.append(f"{k}：{tag} `{p}` 被删除")
                continue
            if g["type"] != f["type"]:
                bucket.append(f"{k}：{tag} `{p}` 类型 {f['type']} → {g['type']}")
            if f["required"] and not g["required"]:
                bucket.append(f"{k}：{tag} `{p}` 由必有变为可选（omitempty）")
            if g.get("nullable") and not f.get("nullable"):
                bucket.append(f"{k}：{tag} `{p}` 现在可能为 null")
            if not f["required"] and g["required"]:
                notes.append(f"{k}：字段 `{p}` 由可选变为必有")
        for p in nf:
            if p not in of:
                notes.append(f"{k}：新增字段 `{p}`（{nf[p]['type']}）")

    ver = fresh.get("magpie_version") or fresh.get("magpie_commit")
    lines = [f"### 网关静态契约检查（magpie {ver}，契约基于 {committed.get('magpie_version')} / {committed.get('magpie_commit')}）", ""]
    if fails:
        lines.append(f"**不兼容变化 {len(fails)} 处：**")
        lines += [f"- {x}" for x in fails]
        lines.append("")
    if notes:
        lines.append(f"兼容的变化 / 提示 {len(notes)} 处：")
        lines += [f"- {x}" for x in notes[:200]]
        if len(notes) > 200:
            lines.append(f"- …另有 {len(notes) - 200} 处")
        lines.append("")
    if not fails and not notes:
        lines.append("与已提交的契约完全一致。")
    text = "\n".join(lines) + "\n"
    print(text)
    if report:
        open(report, "w", encoding="utf-8").write(text)
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
