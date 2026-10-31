#!/usr/bin/env python3
"""公开仓库隐私检查：不允许提交真实的密钥、IP、Tailscale 主机名或邮箱。

示例与 fixture 一律使用明显的假值：
- 密钥：带 EXAMPLE 字样，例如 sk-magpie-key-EXAMPLE；
- IP：100.64.0.x（CGNAT 段的示例）、文档专用段 192.0.2.x / 198.51.100.x / 203.0.113.x、127.0.0.1、0.0.0.0；
- 主机名：*.example / *.example.com / *.example.org，例如 my-mac.tailnet.example；
- 邮箱：只允许 @example.com / @example.org / @*.example。
扫描 git 跟踪的文本文件（未初始化 git 时扫描整个目录）。
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SKIP_SUFFIXES = {".png", ".jpg", ".jpeg", ".pdf", ".ipa", ".zip"}
ALLOWED_IP = re.compile(r"^(127\.0\.0\.1|0\.0\.0\.0|100\.64\.0\.\d{1,3}|192\.0\.2\.\d{1,3}|198\.51\.100\.\d{1,3}|203\.0\.113\.\d{1,3})$")
IPV4 = re.compile(r"(?<![\d.])((?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3})(?![\d.])")
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)")
ALLOWED_EMAIL_DOMAIN = re.compile(r"(^|\.)(example\.com|example\.org|example)$", re.I)
TAILNET = re.compile(r"\b[\w-]+\.[\w-]+\.ts\.net\b|\b[\w-]+\.ts\.net\b", re.I)
SECRETS = [
    re.compile(r"\bsk-[A-Za-z0-9_-]{12,}"),
    re.compile(r"\btskey-[A-Za-z0-9_-]{8,}"),
    re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
]


def files() -> list[Path]:
    try:
        out = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-co", "--exclude-standard"],
                             check=True, capture_output=True, text=True).stdout
        return [ROOT / line for line in out.splitlines() if line]
    except (subprocess.CalledProcessError, FileNotFoundError):
        return [p for p in ROOT.rglob("*") if p.is_file() and ".git" not in p.parts]


def main() -> int:
    problems: list[str] = []
    for path in files():
        if path.suffix.lower() in SKIP_SUFFIXES or not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        rel = path.relative_to(ROOT)
        for number, line in enumerate(text.splitlines(), 1):
            for match in IPV4.finditer(line):
                if not ALLOWED_IP.match(match.group(1)):
                    problems.append(f"{rel}:{number}: 疑似真实 IP {match.group(1)}（示例请用 100.64.0.1 或 192.0.2.1）")
            for match in EMAIL.finditer(line):
                if not ALLOWED_EMAIL_DOMAIN.search(match.group(1)):
                    problems.append(f"{rel}:{number}: 疑似真实邮箱 {match.group(0)}（示例请用 someone@example.com）")
            for match in TAILNET.finditer(line):
                problems.append(f"{rel}:{number}: 疑似真实 Tailscale 主机名 {match.group(0)}（示例请用 my-mac.tailnet.example）")
            for pattern in SECRETS:
                for match in pattern.finditer(line):
                    if "EXAMPLE" not in match.group(0).upper():
                        problems.append(f"{rel}:{number}: 疑似真实密钥 {match.group(0)[:12]}…（示例请带 EXAMPLE 字样）")
    if problems:
        print("隐私检查未通过（公开仓库，不能提交真实的密钥、地址或邮箱）：", file=sys.stderr)
        for line in problems:
            print(f"  - {line}", file=sys.stderr)
        return 1
    print("隐私检查通过：没有发现真实的密钥、IP、Tailscale 主机名或邮箱。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
