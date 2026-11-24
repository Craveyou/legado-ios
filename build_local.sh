#!/bin/zsh
# 小浣熊阅读（legado-ios）本地出包脚本 — 替代 GitHub CI
# 用法：在 Mac 终端执行  zsh build_local.sh
# 产物：./Legado-unsigned.ipa（未签名，供 Sideloadly / AltStore 重签安装）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
# 全程输出同步落盘，便于排查
exec > >(tee "$ROOT/build_run.log") 2>&1
ARCHIVE="$ROOT/build/Legado.xcarchive"
IPA="$ROOT/Legado-unsigned.ipa"

echo "==> 1/3 编译 unsigned archive（Xcode $(xcodebuild -version | head -1 | awk '{print $2}')）"
# 默认增量编译（快）；传 --clean 参数则全量清理重编
BUILD_ACTION=(archive)
[[ "${1:-}" == "--clean" ]] && BUILD_ACTION=(clean archive)
xcodebuild \
  -project Legado.xcodeproj \
  -scheme Legado \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -sdk iphoneos \
  -archivePath "$ARCHIVE" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE="" \
  COMPILER_INDEX_STORE_ENABLE=NO \
  IPHONEOS_DEPLOYMENT_TARGET=15.0 \
  "${BUILD_ACTION[@]}"

echo "==> 2/3 定位 .app 并校验 arm64"
APP="$(find "$ARCHIVE/Products/Applications" -mindepth 1 -maxdepth 1 -name '*.app' | head -1)"
[ -n "$APP" ] || { echo "archive 里没有 .app"; exit 1; }
BIN="$APP/$(basename "${APP%.app}")"
file "$BIN" | grep -q arm64 || { echo "主二进制不是 arm64"; exit 1; }

echo "==> 3/3 打包成 unsigned IPA"
rm -rf "$ROOT/.ipa_tmp"
mkdir -p "$ROOT/.ipa_tmp/Payload"
ditto "$APP" "$ROOT/.ipa_tmp/Payload/$(basename "$APP")"
(cd "$ROOT/.ipa_tmp" && zip -q -r "$IPA" Payload)
rm -rf "$ROOT/.ipa_tmp"

echo "✅ 完成：$IPA（$(du -h "$IPA" | awk '{print $1}')）"
echo "   用 Sideloadly / AltStore 重签后安装到 iPhone"
