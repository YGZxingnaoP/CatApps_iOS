#!/bin/bash
#
# 构建 CatCam App（target CatCam）并打成未签名 IPA，交给 iloader 重签安装。
#
# 与 build-unsigned-ipa.sh 的区别：
#   - 编的是独立 App target（不是 XCTRunner），产物只有 1 个 Mach-O（主二进制）；
#   - 没有扩展，所以不需要 REID 改写扩展 bundle id；
#   - 没有 Asset Catalog，不触发 actool（不依赖 CoreSimulator 权限/模拟器运行时）。
#
# 用法：
#   Scripts/build-catcam-ipa.sh
#   DERIVED=/path/to/dd Scripts/build-catcam-ipa.sh
#   STRIP=0 Scripts/build-catcam-ipa.sh        # 跳过剥离，仅排查用（产物装不上）
#
# 产物：
#   dist/catcam-<版本号>.ipa
#   dist/catcam-latest.ipa
#   dist/catcam-build.log
#   dist/catcam-summary.txt     # 名字/字节/SHA-256/Mach-O 校验/bundle id（ASCII）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJ="$ROOT/CatCam/CatCam.xcodeproj"
DERIVED="${DERIVED:-$ROOT/CatCam/build/dd}"
BUILD_PRODUCTS="$DERIVED/Release-iphoneos"
APP_SRC="$BUILD_PRODUCTS/CatCam.app"
OUT="$ROOT/dist"
LOG="$OUT/catcam-build.log"
SUMMARY="$OUT/catcam-summary.txt"

mkdir -p "$OUT"
rm -f "$SUMMARY"

# push.cmd 走 tar，Windows 侧没有可执行位，解包后 Scripts/*.sh 会变 644
chmod +x "$ROOT/Scripts/"*.sh 2>/dev/null || true

echo "==> 1/4 构建 CatCam target（Release / iphoneos）"
set +e
xcodebuild -project "$PROJ" \
  -target CatCam \
  -configuration Release \
  -sdk iphoneos \
  CONFIGURATION_BUILD_DIR="$BUILD_PRODUCTS" \
  OBJROOT="$DERIVED/Intermediates" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  build > "$LOG" 2>&1
rc=$?
set -e
if [ $rc -ne 0 ]; then
  echo "构建失败，错误如下（完整日志: $LOG）：" >&2
  grep -n "error:" "$LOG" | head -30 >&2
  exit $rc
fi
if [ ! -d "$APP_SRC" ]; then
  echo "没有找到 $APP_SRC" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_SRC/Info.plist")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_SRC/Info.plist")"
DISPLAY_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP_SRC/Info.plist" 2>/dev/null || echo '?')"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$APP_SRC/Info.plist" 2>/dev/null || echo '?')"
IPA_NAME="catcam-${VERSION}.ipa"
IPA="$OUT/$IPA_NAME"
LATEST="$OUT/catcam-latest.ipa"

echo "==> 2/4 组装 Payload"
rm -rf "$OUT/Payload" "$IPA" "$LATEST"
mkdir -p "$OUT/Payload"
ditto "$APP_SRC" "$OUT/Payload/CatCam.app"
find "$OUT/Payload" -name '.DS_Store' -delete
find "$OUT/Payload" -name '*.dSYM' -maxdepth 3 -type d -prune -exec rm -rf {} + 2>/dev/null || true

echo "==> 3/4 剥离代码签名"
if [ "${STRIP:-1}" = "1" ]; then
  bash "$ROOT/Scripts/strip-codesign.sh" "$OUT/Payload" || {
    echo "剥离签名失败，不打包" >&2
    exit 1
  }
else
  echo "  STRIP=0，跳过剥离（产物装不上）" >&2
fi

echo "==> 4/4 打包 + 复验"
( cd "$OUT" && zip -qry -X "$IPA" Payload )
rm -rf "$OUT/Payload"
cp -f "$IPA" "$LATEST"

VERIFY="$OUT/.verify-catcam"
rm -rf "$VERIFY"
mkdir -p "$VERIFY"
unzip -q "$IPA" -d "$VERIFY"
verify_rc=0
verify_out="$(bash "$ROOT/Scripts/strip-codesign.sh" "$VERIFY/Payload" --check 2>&1)" || verify_rc=$?
rm -rf "$VERIFY"
echo "$verify_out"
macho_total="$(printf '%s\n' "$verify_out" | sed -n 's/.*Mach-O total: \([0-9]*\), still signed: \([0-9]*\)/\1/p')"
macho_signed="$(printf '%s\n' "$verify_out" | sed -n 's/.*Mach-O total: \([0-9]*\), still signed: \([0-9]*\)/\2/p')"

size_bytes="$(stat -f %z "$IPA")"
sha256="$(shasum -a 256 "$IPA" | awk '{print $1}')"
built="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

{
  echo "ipa_path=$IPA"
  echo "ipa_name=$IPA_NAME"
  echo "ipa_latest=$LATEST"
  echo "ipa_bytes=$size_bytes"
  echo "ipa_sha256=$sha256"
  echo "macho_total=${macho_total:-0}"
  echo "macho_signed=${macho_signed:-unknown}"
  echo "strip_enabled=${STRIP:-1}"
  echo "verify_rc=$verify_rc"
  echo "built_utc=$built"
  echo "bundle_id=${BUNDLE_ID}"
  echo "display_name=${DISPLAY_NAME}"
  echo "version=${VERSION}"
  echo "minimum_os=${MIN_OS}"
} > "$SUMMARY"

echo
echo "完成！"
ls -lh "$IPA"
echo
echo "bundle id : ${BUNDLE_ID}"
echo "桌面名    : ${DISPLAY_NAME} ${VERSION}"
echo
cat "$SUMMARY"

if [ "$verify_rc" != "0" ] || [ "${macho_signed:-1}" != "0" ]; then
  echo "错误：IPA 内仍有带签名的 Mach-O，拿去装必然 0xE8008001" >&2
  exit 1
fi
