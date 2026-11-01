#!/usr/bin/env python3
"""从 magpie 源码生成 App 用的官方图标（MIT，见 THIRD_PARTY_NOTICES.md）。

    pip install resvg-py pillow        # 只在重新生成时需要
    python3 scripts/gen-official-icons.py ../magpie

生成：
- MagpieRemoteApp/Assets.xcassets/AppIcon.appiconset：magpie 的 App 图标（build/darwin/AppIcon.icon 的
  喜鹊图层 + 它的浅色 / 深色底色），1024×1024 无透明通道；另出深色与着色（tinted）两版。
- MagpieRemoteApp/Assets.xcassets/Brand/：internal/gui/assets/icons 里的供应商 / Agent 标志。
  名字以 -color 结尾或在网页 pngIcons 里的是彩色图（原样显示），其余是单色图（template，跟随文字颜色），
  与网页 app.js 的 icon() 一致。SVG 保留矢量（preserves-vector-representation）；带 mask / filter /
  clipPath 或没有 viewBox 的 SVG 渲染成 PNG，免得 iOS 的 SVG 渲染不支持。
- MagpieRemoteApp/Assets.xcassets/Nav/：internal/gui/assets/index.html 导航栏的线条图标。
- MagpieRemoteCore/Sources/MagpieRemoteCore/OfficialIconNames.swift：打包了哪些标志（Core 据此判断
  主机给的图标名有没有对应图片，没有就和网页一样画通用图标）。
"""
from __future__ import annotations

import io
import json
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "MagpieRemoteApp" / "Assets.xcassets"
NAMES_SWIFT = ROOT / "MagpieRemoteCore" / "Sources" / "MagpieRemoteCore" / "OfficialIconNames.swift"
SKIP = {"apple-touch-icon", "icon-512", "favicon"}  # 网站自己的图标，不是标志
RISKY = re.compile(r"<mask|<filter|clip-path|clipPath|<image|<style|<use")
RASTER = 96  # 栅格化标志的边长（像素）：最大 28pt @3x
# 网页 index.html 导航按钮 data-view → 资源名。
NAV = {"agents": "nav-agents", "sessions": "nav-sessions", "providers": "nav-providers", "routing": "nav-routing",
       "gateway": "nav-gateway", "usage": "nav-usage", "plugins": "nav-plugins"}


def contents(images: list[dict], props: dict | None = None) -> str:
    data: dict = {"images": images, "info": {"author": "xcode", "version": 1}}
    if props:
        data["properties"] = props
    return json.dumps(data, indent=2, ensure_ascii=False) + "\n"


def png_icons(app_js: str) -> set[str]:
    m = re.search(r"const pngIcons = new Set\(\[([^\]]*)\]\)", app_js)
    if not m:
        sys.exit("app.js 里找不到 pngIcons")
    return set(re.findall(r'"([^"]+)"', m.group(1)))


def clean_svg(text: str) -> str | None:
    """去掉 iOS 渲染不认的根节点属性（1em 宽高、style），宽高换成 viewBox 的数值；没有 viewBox 返回 None。"""
    text = re.sub(r"<\?xml[^>]*\?>", "", text)
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    text = re.sub(r"<title>.*?</title>", "", text, flags=re.S)
    m = re.search(r"<svg\b[^>]*>", text)
    if not m:
        return None
    tag = m.group(0)
    vb = re.search(r'viewBox="([^"]+)"', tag)
    if not vb:
        return None
    nums = [float(x) for x in re.split(r"[\s,]+", vb.group(1).strip())]
    w, h = nums[2], nums[3]
    new = re.sub(r'\s(width|height|style|role|aria-label)="[^"]*"', "", tag)
    new = new.replace("<svg", f'<svg width="{w:g}" height="{h:g}"', 1)
    return (text[: m.start()] + new + text[m.end():]).strip() + "\n"


def raster(svg_path: Path, side: int) -> bytes:
    import resvg_py  # noqa: PLC0415
    from PIL import Image  # noqa: PLC0415

    png = bytes(resvg_py.svg_to_bytes(svg_path=str(svg_path), width=side * 2))
    im = Image.open(io.BytesIO(png)).convert("RGBA")
    im.thumbnail((side, side), Image.LANCZOS)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(im, ((side - im.width) // 2, (side - im.height) // 2))
    out = io.BytesIO()
    canvas.save(out, "PNG", optimize=True)
    return out.getvalue()


def imageset(folder: Path, name: str, filename: str, data: bytes, template: bool, vector: bool) -> None:
    d = folder / f"{name}.imageset"
    d.mkdir(parents=True, exist_ok=True)
    (d / filename).write_bytes(data)
    props: dict = {"template-rendering-intent": "template" if template else "original"}
    if vector:
        props["preserves-vector-representation"] = True
    (d / "Contents.json").write_text(contents([{"filename": filename, "idiom": "universal"}], props))


def brand(magpie: Path) -> tuple[list[str], list[str]]:
    src = magpie / "internal" / "gui" / "assets" / "icons"
    pngs = png_icons((magpie / "internal" / "gui" / "assets" / "app.js").read_text())
    out = ASSETS / "Brand"
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    (out / "Contents.json").write_text(contents([], {"provides-namespace": True}).replace('"images": [],\n  ', ""))
    names, rasterized = [], []
    for f in sorted(src.iterdir()):
        name, ext = f.stem, f.suffix.lower()
        if name in SKIP or ext not in (".svg", ".png"):
            continue
        colored = name.endswith("-color") or name in pngs or name.startswith("app-")
        if ext == ".png":
            imageset(out, name, f"{name}.png", f.read_bytes(), template=False, vector=False)
        else:
            text = f.read_text(encoding="utf-8")
            cleaned = None if RISKY.search(text) else clean_svg(text)
            if cleaned is None:
                imageset(out, name, f"{name}.png", raster(f, RASTER), template=not colored, vector=False)
                rasterized.append(name)
            else:
                imageset(out, name, f"{name}.svg", cleaned.encode(), template=not colored, vector=True)
        names.append(name)
    return names, rasterized


def nav(magpie: Path) -> None:
    html = (magpie / "internal" / "gui" / "assets" / "index.html").read_text()
    out = ASSETS / "Nav"
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    (out / "Contents.json").write_text(contents([], {"provides-namespace": True}).replace('"images": [],\n  ', ""))
    for view, name in NAV.items():
        m = re.search(rf'data-view="{view}"[^>]*>(<svg.*?</svg>)', html, flags=re.S)
        if not m:
            sys.exit(f"index.html 里找不到导航 {view}")
        svg = m.group(1)
        root = re.match(r"<svg\b[^>]*>", svg).group(0)
        # 底栏图标按 24pt 画（网页是 16px）；线条颜色写死黑色，template 渲染时只看形状。
        tag = re.sub(r'\s(class|aria-hidden|width|height)="[^"]*"', "", root)
        tag = tag.replace("<svg", '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"', 1)
        svg = tag + svg[len(root):]
        svg = svg.replace("currentColor", "#000000")
        imageset(out, name, f"{name}.svg", (svg + "\n").encode(), template=True, vector=True)


def app_icon(magpie: Path) -> None:
    from PIL import Image  # noqa: PLC0415

    icon = magpie / "build" / "darwin" / "AppIcon.icon"
    spec = json.loads((icon / "icon.json").read_text())
    bird = Image.open(icon / "Assets" / "magpie.png").convert("RGBA")
    side = bird.width

    def color(s: str) -> tuple[int, int, int]:
        r, g, b, _ = (float(x) for x in s.split(":")[1].split(","))
        return round(r * 255), round(g * 255), round(b * 255)

    def fill(appearance: str | None, specs: list[dict]) -> dict:
        return next(x["value"] for x in specs if x.get("appearance") == appearance)

    def tile(bg_top, bg_bottom, ink) -> Image.Image:
        bg = Image.new("RGB", (side, side))
        px = bg.load()
        for y in range(side):
            t = y / (side - 1)
            c = tuple(round(a + (b - a) * t) for a, b in zip(bg_top, bg_bottom))
            for x in range(side):
                px[x, y] = c
        layer = Image.new("RGB", (side, side), ink)
        bg.paste(layer, (0, 0), bird.getchannel("A"))
        return bg

    bg_specs = spec["fill-specializations"]
    ink_specs = spec["groups"][0]["layers"][0]["fill-specializations"]
    out = ASSETS / "AppIcon.appiconset"
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    light = [color(c) for c in fill(None, bg_specs)["linear-gradient"]]
    dark = [color(c) for c in fill("dark", bg_specs)["linear-gradient"]]
    tile(light[0], light[1], color(fill(None, ink_specs)["solid"])).save(out / "AppIcon.png", optimize=True)
    tile(dark[0], dark[1], color(fill("dark", ink_specs)["solid"])).save(out / "AppIcon-Dark.png", optimize=True)
    # 着色版：系统按亮度上色，白色喜鹊放在黑底上。
    tile((0, 0, 0), (0, 0, 0), (255, 255, 255)).convert("L").save(out / "AppIcon-Tinted.png", optimize=True)
    base = {"idiom": "universal", "platform": "ios", "size": "1024x1024"}
    (out / "Contents.json").write_text(contents([
        {"filename": "AppIcon.png", **base},
        {"appearances": [{"appearance": "luminosity", "value": "dark"}], "filename": "AppIcon-Dark.png", **base},
        {"appearances": [{"appearance": "luminosity", "value": "tinted"}], "filename": "AppIcon-Tinted.png", **base},
    ]))


def shrunk_icons(app_css: str) -> list[str]:
    """app.css 里画小一圈（82%）的标志：本身贴满方框的图。"""
    m = re.search(r"\.ic:is\(([^)]*)\)\s*>\s*\*\s*\{\s*width:\s*82%", app_css)
    if not m:
        sys.exit("app.css 里找不到 82% 的标志列表")
    return sorted(set(re.findall(r'data-icon="([^"]+)"', m.group(1))))


def agent_icons(magpie: Path, bundled: set[str]) -> dict[str, str]:
    """internal/agent 里每个 Agent 定义的 ID → Icon（网页画 Agent 时用它）。同一 ID 有多处时取打包了图片的那个。"""
    pairs: dict[str, str] = {}
    pat = re.compile(r'ID:\s*"([a-z0-9-]+)",\s*Name:\s*"[^"]*",\s*Icon:\s*"([a-z0-9-]+)"')
    like = re.compile(r'openCodeLike\([a-z()]+,\s*"([a-z0-9-]+)",\s*"[^"]*",\s*"([a-z0-9-]+)"')
    for f in sorted((magpie / "internal" / "agent").glob("*.go")):
        if f.name.endswith("_test.go"):
            continue
        text = f.read_text(encoding="utf-8")
        for agent, icon in pat.findall(text) + like.findall(text):
            if agent not in pairs or (pairs[agent] not in bundled and icon in bundled):
                pairs[agent] = icon
    if not pairs:
        sys.exit("internal/agent 里找不到 Agent 定义")
    return dict(sorted(pairs.items()))


def preset_icons(magpie: Path) -> dict[str, str]:
    """internal/provider/presets.go 里每个供应商预设的 ID → Icon（KnownFace 按它给已删除 / 未设置的供应商配标志）。"""
    text = (magpie / "internal" / "provider" / "presets.go").read_text(encoding="utf-8")
    pat = re.compile(r'\{ID:\s*"([a-z0-9.-]+)",\s*Name:\s*"[^"]*",(?:\s*Short:\s*"[^"]*",)?\s*Icon:\s*"([a-z0-9-]+)"')
    pairs = dict(pat.findall(text))
    if not pairs:
        sys.exit("presets.go 里找不到供应商预设")
    return dict(sorted(pairs.items()))


def swift_set(items) -> str:
    return ",\n".join(f'        "{n}"' for n in sorted(items))


def swift_map(pairs: dict[str, str]) -> str:
    return ",\n".join(f'        "{k}": "{v}"' for k, v in pairs.items())


def names_swift(names: list[str], magpie: Path) -> None:
    assets = magpie / "internal" / "gui" / "assets"
    pngs = png_icons((assets / "app.js").read_text())
    shrunk = shrunk_icons((assets / "app.css").read_text())
    agents = agent_icons(magpie, set(names))
    presets = preset_icons(magpie)
    NAMES_SWIFT.write_text(f"""// 由 scripts/gen-official-icons.py 生成，不要手改。
// App 资源目录 Brand/ 里打包的 magpie 官方标志（internal/gui/assets/icons，MIT），以及官方源码里的对应关系。

public extension OfficialIcon {{
    /// 打包了图片的标志名（与 magpie 网页 icons/ 下的文件名相同，不含扩展名）。
    static let bundled: Set<String> = [
{swift_set(names)},
    ]

    /// 网页 app.js 的 `pngIcons`：这些是 PNG 彩色图（其余不带 -color 的是单色图）。
    static let pngIcons: Set<String> = [
{swift_set(pngs)},
    ]

    /// 网页 app.css 里画成 82% 大小的标志（图本身贴满方框）。
    static let shrunk: Set<String> = [
{swift_set(shrunk)},
    ]

    /// magpie `internal/agent` 里各 Agent 定义的图标（Agent id → 图标名）。
    static let agentIcons: [String: String] = [
{swift_map(agents)},
    ]

    /// magpie `internal/provider/presets.go` 里各供应商预设的图标（预设 id → 图标名）。
    static let presetIcons: [String: String] = [
{swift_map(presets)},
    ]
}}
""")


def main() -> int:
    magpie = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT.parent / "magpie").resolve()
    if not (magpie / "internal" / "gui" / "assets" / "icons").is_dir():
        sys.exit(f"不是 magpie 源码目录：{magpie}")
    app_icon(magpie)
    names, rasterized = brand(magpie)
    nav(magpie)
    names_swift(names, magpie)
    print(f"App 图标 3 张；标志 {len(names)} 个（栅格化 {len(rasterized)} 个：{', '.join(rasterized)}）；导航图标 {len(NAV)} 个。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
