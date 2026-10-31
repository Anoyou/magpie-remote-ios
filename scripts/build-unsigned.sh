#!/bin/bash
# 构建未签名 IPA：Release 配置、不签名，产物 <输出目录>/MagpieRemote-unsigned.ipa。
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
ditto --norsrc --noextattr -c -k --keepParent \
  "$STAGING/Payload" "$OUTPUT/MagpieRemote-unsigned.ipa"
printf '\n未签名 IPA：%s\n此文件需要你签名后才能安装，不包含证书或描述文件。\n' \
  "$OUTPUT/MagpieRemote-unsigned.ipa"
