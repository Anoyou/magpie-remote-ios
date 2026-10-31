#!/usr/bin/env python3
"""把 .xcresult 里失败用例的断言信息清楚地打印出来（CI 用）。

用法：python3 scripts/print-xcresult-failures.py <path.xcresult> [...]

- 每条失败输出为 GitHub Actions `::error::` 注解，并写入 $GITHUB_STEP_SUMMARY；
- 优先用 `xcresulttool get test-results summary`（Xcode 16+），失败时回退到 `tests` 树；
- 本脚本只负责报告，永远以 0 退出，测试结论以 xcodebuild 为准。
"""
import json
import os
import subprocess
import sys


def run(args):
    try:
        out = subprocess.run(args, capture_output=True, text=True, timeout=120)
    except Exception as exc:  # noqa: BLE001
        return None, str(exc)
    if out.returncode != 0:
        return None, out.stderr.strip()
    try:
        return json.loads(out.stdout), None
    except json.JSONDecodeError as exc:
        return None, str(exc)


def from_summary(path):
    data, err = run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", path])
    if data is None:
        return None, err
    failures = []
    for item in data.get("testFailures", []) or []:
        name = item.get("testIdentifierString") or item.get("testName") or "?"
        failures.append((name, item.get("failureText") or "（无断言信息）"))
    counts = {k: data.get(k) for k in ("totalTestCount", "passedTests", "failedTests", "skippedTests")}
    return (failures, counts), None


def from_tests(path):
    data, err = run(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", path])
    if data is None:
        return None, err
    failures = []

    def walk(node, case=None):
        kind = node.get("nodeType")
        if kind == "Test Case":
            case = node.get("nodeIdentifier") or node.get("name")
        if kind == "Failure Message":
            failures.append((case or "?", node.get("name") or "（无断言信息）"))
        for child in node.get("children", []) or []:
            walk(child, case)

    for node in data.get("testNodes", []) or []:
        walk(node)
    return (failures, {}), None


def main():
    summary_lines = []
    for path in sys.argv[1:]:
        if not os.path.exists(path):
            print(f"跳过：找不到 {path}")
            continue
        result, err = from_summary(path)
        if result is None:
            print(f"summary 读取失败（{err}），改读 tests 树")
            result, err = from_tests(path)
        if result is None:
            print(f"::warning::无法解析 {path}：{err}")
            continue
        failures, counts = result
        # 同一用例重跑多次会重复出现，去重但保留顺序。
        seen, unique = set(), []
        for item in failures:
            if item not in seen:
                seen.add(item)
                unique.append(item)
        name = os.path.basename(path)
        stats = "，".join(f"{k}={v}" for k, v in counts.items() if v is not None)
        print(f"== {name}：{len(unique)} 条失败 {stats}")
        summary_lines.append(f"### {name}：{len(unique)} 条失败" + (f"（{stats}）" if stats else ""))
        for case, text in unique:
            one_line = " ".join(text.split())
            print(f"::error title=UI 测试失败 {case}::{one_line}")
            summary_lines.append(f"- `{case}`：{one_line}")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary and summary_lines:
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write("\n".join(summary_lines) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
