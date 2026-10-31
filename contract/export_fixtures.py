#!/usr/bin/env python3
"""把 test_contract.py 抓到的真实响应脱敏后写成 Swift 解码测试用的 fixture。

    python3 contract/export_fixtures.py <capture dir> <fixture.env> [dest]
    dest 默认 MagpieRemoteCore/Tests/MagpieRemoteCoreTests/Fixtures/live

脱敏规则（公开仓库，见 scripts/check-privacy.py）：
- 任何 sk-magpie-key-… → sk-magpie-key-EXAMPLE；其它 sk-… → sk-EXAMPLE；web 密钥 → web-key-EXAMPLE；
- 回环 / 内网等非示例 IPv4 → 100.64.0.1；本机主机名 → my-mac.example；
- fixture 工作目录（隔离的 HOME）→ /Users/example/magpie-fixture；
- 测试用的非默认端口还原成默认端口 3425 / 3430 / 18080。
写完后请运行 python3 scripts/check-privacy.py 确认。
"""
from __future__ import annotations

import os
import re
import shutil
import socket
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ALLOWED_IP = re.compile(r"^(0\.0\.0\.0|100\.64\.0\.\d{1,3}|192\.0\.2\.\d{1,3}|198\.51\.100\.\d{1,3}|203\.0\.113\.\d{1,3})$")
IPV4 = re.compile(r"(?<![\d.])((?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3})(?![\d.])")


def load_env(path):
    env = {}
    for line in open(path, encoding="utf-8"):
        if "=" in line:
            k, v = line.rstrip("\n").split("=", 1)
            env[k] = v
    return env


def redact(text: str, env: dict) -> str:
    text = re.sub(r"sk-magpie-key-[A-Za-z0-9]+", "sk-magpie-key-EXAMPLE", text)
    text = re.sub(r"\bsk-(?![A-Za-z0-9_-]*EXAMPLE)[A-Za-z0-9_-]{12,}", "sk-EXAMPLE", text)
    if env.get("MAGPIE_WEB_KEY"):
        text = text.replace(env["MAGPIE_WEB_KEY"], "web-key-EXAMPLE")
    work = env.get("MAGPIE_FIXTURE_DIR")
    if work:
        text = text.replace(os.path.realpath(work), "/Users/example/magpie-fixture").replace(work, "/Users/example/magpie-fixture")
    for host in {socket.gethostname(), socket.getfqdn()}:
        if host and host not in ("localhost",) and len(host) > 2:
            text = re.sub(r"(?<![\w.-])" + re.escape(host) + r"(?![\w-])", "my-mac.example", text)
    text = IPV4.sub(lambda m: m.group(1) if ALLOWED_IP.match(m.group(1)) else "100.64.0.1", text)
    for k, default in (("MAGPIE_GATEWAY_PORT", "3425"), ("MAGPIE_WEB_PORT", "3430"), ("MOCK_PORT", "18080")):
        p = env.get(k)
        if p and p != default:
            text = re.sub(r"(?<=[:_])" + re.escape(p) + r"(?!\d)", default, text)
    return text


def main() -> int:
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    cap, env = sys.argv[1], load_env(sys.argv[2])
    env.setdefault("MOCK_PORT", os.environ.get("MOCK_PORT", ""))
    dest = sys.argv[3] if len(sys.argv) > 3 else os.path.join(ROOT, "MagpieRemoteCore", "Tests", "MagpieRemoteCoreTests", "Fixtures", "live")
    shutil.rmtree(dest, ignore_errors=True)
    os.makedirs(dest)
    n = 0
    for name in sorted(os.listdir(cap)):
        if name.startswith("report.") or not name.endswith((".json", ".sse", ".txt", ".tsv")):
            continue
        text = open(os.path.join(cap, name), encoding="utf-8", errors="replace").read()
        with open(os.path.join(dest, name), "w", encoding="utf-8") as f:
            f.write(redact(text, env))
        n += 1
    print(f"已写入 {n} 个脱敏 fixture → {dest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
