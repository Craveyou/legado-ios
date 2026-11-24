#!/bin/zsh
# 小浣熊阅读 — 快速增量出包（推荐日常改代码用这个）
# 与 build_local.sh 的区别：用 xcodebuild build + 固定 DerivedData，真正复用增量缓存。
# 实测（本机 Xcode 26.5）：首次建缓存 453 秒；之后改一行业务代码 191 秒（依赖不再重编，仅主 App 慢）。
# 对比：build_local.sh 用 archive 模式，每次都全量重编依赖，实测恒为 ~430 秒。日常优先用本脚本。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
DERIVED="$ROOT/.derived"
IPA="$ROOT/Legado-unsigned.ipa"

echo "==> 编译（增量；缓存目录 $DERIVED）"
xcodebuild \
  -project Legado.xcodeproj \
  -scheme Legado \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -sdk iphoneos \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE="" \
  COMPILER_INDEX_STORE_ENABLE=NO \
  IPHONEOS_DEPLOYMENT_TARGET=15.0 \
  build

echo "==> 打包 IPA"
APP="$DERIVED/Build/Products/Release-iphoneos/Legado.app"
[ -d "$APP" ] || { echo "找不到 $APP"; exit 1; }
BIN="$APP/Legado"
file "$BIN" | grep -q arm64 || { echo "主二进制不是 arm64"; exit 1; }
rm -rf "$ROOT/.ipa_tmp"
mkdir -p "$ROOT/.ipa_tmp/Payload"
ditto "$APP" "$ROOT/.ipa_tmp/Payload/Legado.app"
# 先删旧 IPA：zip 是增量更新，不删会把上一次的旧文件（如已删的 httpTTS.json）残留进新包
[ -f "$IPA" ] && rm -f "$IPA"
(cd "$ROOT/.ipa_tmp" && zip -q -r "$IPA" Payload)
rm -rf "$ROOT/.ipa_tmp"
echo "✅ 完成：$IPA（$(du -h "$IPA" | awk '{print $1}')）"
