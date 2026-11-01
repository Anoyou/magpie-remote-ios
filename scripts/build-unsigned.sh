#!/bin/bash
# 构建未签名 IPA：Release 配置、不签名，产物 <输出目录>/MagpieRemote-unsigned.ipa。
# 包里含小组件扩展（PlugIns/MagpieRemoteWidgets.appex）；App 与扩展做一次临时（ad-hoc）签名写入 App Group 声明，
# 方便自签工具开通 App Group（见下方说明）。
# 用法：bash scripts/build-unsigned.sh [输出目录，默认 build/]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:-$ROOT/build}"
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"

# build 号（CFBundleVersion）：CI 通过 MAGPIE_REMOTE_BUILD_NUMBER 注入单调递增的正整数（工作流 run_number）；
# 未设置时沿用工程里的本地默认值。MARKETING_VERSION 不在这里覆盖，以工程设置为准。
VERSION_ARGS=()
if [ -n "${MAGPIE_REMOTE_BUILD_NUMBER:-}" ]; then
  if ! [[ "$MAGPIE_REMOTE_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    echo "MAGPIE_REMOTE_BUILD_NUMBER 必须是正整数，当前为：$MAGPIE_REMOTE_BUILD_NUMBER" >&2
    exit 1
  fi
  VERSION_ARGS+=("CURRENT_PROJECT_VERSION=$MAGPIE_REMOTE_BUILD_NUMBER")
  echo "注入 build 号：$MAGPIE_REMOTE_BUILD_NUMBER"
fi

xcodebuild \
  -project "$ROOT/MagpieRemote.xcodeproj" \
  -scheme MagpieRemote \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$OUTPUT/MagpieRemote.xcarchive" \
  -derivedDataPath "$OUTPUT/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  ${VERSION_ARGS[@]+"${VERSION_ARGS[@]}"} \
  archive

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/Payload"
ditto "$OUTPUT/MagpieRemote.xcarchive/Products/Applications/MagpieRemote.app" \
  "$STAGING/Payload/MagpieRemote.app"

# 小组件扩展必须在包里（Payload/MagpieRemote.app/PlugIns/MagpieRemoteWidgets.appex），版本号与 App 一致。
APP="$STAGING/Payload/MagpieRemote.app"
APPEX="$APP/PlugIns/MagpieRemoteWidgets.appex"
if [ ! -d "$APPEX" ]; then
  echo "IPA 里缺少小组件扩展：Payload/MagpieRemote.app/PlugIns/MagpieRemoteWidgets.appex" >&2
  exit 1
fi
for KEY in CFBundleShortVersionString CFBundleVersion; do
  A=$(/usr/libexec/PlistBuddy -c "Print :$KEY" "$APP/Info.plist")
  E=$(/usr/libexec/PlistBuddy -c "Print :$KEY" "$APPEX/Info.plist")
  if [ "$A" != "$E" ]; then
    echo "小组件扩展的 $KEY（$E）与 App（$A）不一致" >&2
    exit 1
  fi
done

# 临时（ad-hoc）签名，只为把「要用 App Group」写进可执行文件：AltStore / SideStore 等自签工具从签名里读
# App 与扩展要哪些能力，再用你的 Apple ID 开通对应的 App Group；完全没签名的包里没有这些信息。
# 这不是 Apple 证书签名，IPA 仍然需要你自签后才能安装。设置 MAGPIE_REMOTE_SKIP_ADHOC=1 可跳过。
if [ "${MAGPIE_REMOTE_SKIP_ADHOC:-}" != "1" ]; then
  GROUP=$(sed -nE 's/^[[:space:]]*MAGPIE_APP_GROUP:[[:space:]]*"?([^"[:space:]#]+).*/\1/p' "$ROOT/project.yml")
  if [ -z "$GROUP" ]; then
    echo "project.yml 缺少 MAGPIE_APP_GROUP" >&2
    exit 1
  fi
  ENTITLEMENTS="$STAGING/adhoc.entitlements"
  cat > "$ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>$GROUP</string>
    </array>
</dict>
</plist>
PLIST
  # 由内向外：嵌入的框架 / 动态库 → 扩展 → App。
  while IFS= read -r -d '' NESTED; do
    codesign --force --sign - --timestamp=none "$NESTED"
  done < <(find "$APP" \( -name '*.framework' -o -name '*.dylib' \) -print0)
  codesign --force --sign - --timestamp=none --entitlements "$ENTITLEMENTS" "$APPEX"
  codesign --force --sign - --timestamp=none --entitlements "$ENTITLEMENTS" "$APP"
  for BUNDLE in "$APPEX" "$APP"; do
    if ! { codesign -d --entitlements - --xml "$BUNDLE" 2>/dev/null || codesign -d --entitlements :- "$BUNDLE" 2>/dev/null; } | grep -q "$GROUP"; then
      echo "临时签名后 $(basename "$BUNDLE") 里没有 App Group $GROUP" >&2
      exit 1
    fi
  done
  echo "已写入 App Group 能力声明（临时签名）：$GROUP"
fi
ditto --norsrc --noextattr -c -k --keepParent \
  "$STAGING/Payload" "$OUTPUT/MagpieRemote-unsigned.ipa"
printf '\n未签名 IPA：%s\n此文件需要你签名后才能安装，不包含证书或描述文件。\n' \
  "$OUTPUT/MagpieRemote-unsigned.ipa"
