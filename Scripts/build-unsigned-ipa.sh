#!/bin/bash
#
# 构建 WebDriverAgentRunner 并打包成「真·未签名 IPA」，交给 Sideloadly 重签安装。
#
# 关键步骤 3/4：剥离包内所有代码签名。Xcode 的 build-for-testing 会把 XCTRunner 桩 app
# 和 XCTest 等系统 framework 带签名拷过来，而 PlugIns/ 里的 xctest 是未签名的；
# 混签名包 iOS 直接拒装（0xE8008001）。剥离后 Sideloadly 才能整体重签。
#
# 用法：
#   Scripts/build-unsigned-ipa.sh                    # 默认 generic/platform=iOS
#   DEST='id=<UDID>' Scripts/build-unsigned-ipa.sh   # 指定真机（走 thinning，需要模拟器运行时）
#   DERIVED=/path/to/dd Scripts/build-unsigned-ipa.sh
#   STRIP=0 Scripts/build-unsigned-ipa.sh            # 跳过剥离（只用于排查，产物装不上）
#
# 产物：
#   dist/WebDriverAgentRunner-unsigned.ipa
#   dist/WebDriverAgentRunner*.xctestrun
#   dist/build.log
#   dist/ipa-summary.txt        # 大小 / SHA-256 / 签名校验结果，ASCII，给本机脚本读

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WDA="$ROOT/WebDriverAgent"
DERIVED="${DERIVED:-$WDA/build/dd}"
DEST="${DEST:-generic/platform=iOS}"
OUT="$ROOT/dist"
PRODUCTS="$DERIVED/Build/Products/Debug-iphoneos"
APP_SRC="$PRODUCTS/WebDriverAgentRunner-Runner.app"
IPA=""                      # 构建后按 catpaws-<版本号>.ipa 命名，见下面
SUMMARY="$OUT/ipa-summary.txt"

mkdir -p "$OUT"
rm -f "$SUMMARY"

# push.cmd 走 tar，Windows 侧没有可执行位，解包后 Scripts/*.sh 会变成 644；
# Xcode 的 scheme post-action 是直接执行 embed-runner-icon.sh 的，这里先自愈。
chmod +x "$WDA/Scripts/"*.sh 2>/dev/null || true

echo "==> 1/4 构建 (destination: $DEST)"
set +e
xcodebuild build-for-testing \
  -project "$WDA/WebDriverAgent.xcodeproj" \
  -scheme WebDriverAgentRunner \
  -destination "$DEST" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  > "$OUT/build.log" 2>&1
rc=$?
set -e
if [ $rc -ne 0 ]; then
  echo "构建失败，错误如下（完整日志: $OUT/build.log）：" >&2
  grep -n "error:" "$OUT/build.log" | head -20 >&2
  exit $rc
fi
if [ ! -d "$APP_SRC" ]; then
  echo "没有找到 $APP_SRC" >&2
  exit 1
fi

# 产物命名：catpaws-<CFBundleShortVersionString>.ipa（版本号只从 Info.plist 取，不另设一份）
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_SRC/Info.plist" 2>/dev/null || echo 0.0.0)"
IPA_NAME="catpaws-${VERSION}.ipa"
IPA="$OUT/$IPA_NAME"
LATEST="$OUT/catpaws-latest.ipa"
COMPAT="$OUT/WebDriverAgentRunner-unsigned.ipa"

echo "==> 2/4 组装 Payload"
rm -rf "$OUT/Payload" "$OUT"/catpaws-*.ipa "$COMPAT"
mkdir -p "$OUT/Payload"
ditto "$APP_SRC" "$OUT/Payload/WebDriverAgentRunner-Runner.app"

# 不该进 IPA 的东西
PAYLOAD="$OUT/Payload/WebDriverAgentRunner-Runner.app"
rm -rf "$PAYLOAD/PlugIns/"*.dSYM
find "$OUT/Payload" -name '.DS_Store' -delete

# Runner.app 自己也要有启动屏：iOS 14+ 缺 UILaunchScreen 会把 App 放进兼容模式，
# UIScreen 报 320×480@3x（= 960×1440），而 /screenshot 仍是原生 1284×2778，
# /device 的 screen.pixel/point/scale 就会和截图打架（见 Docs/CATCAM_APP.md §8）。
/usr/libexec/PlistBuddy -c 'Delete :UILaunchScreen' "$PAYLOAD/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c 'Add :UILaunchScreen dict' "$PAYLOAD/Info.plist"
if ! /usr/libexec/PlistBuddy -c 'Print :UILaunchScreen' "$PAYLOAD/Info.plist" >/dev/null 2>&1; then
  echo "UILaunchScreen 注入失败，停止打包" >&2
  exit 1
fi
echo "  UILaunchScreen 已注入 Runner.app/Info.plist"

# actool 会把图标资源同时产物化到 xctest 里，但 iOS 只读 Runner.app 根目录那一份
# （由 WebDriverAgent/Scripts/embed-runner-icon.sh 抬上去），删掉能省 ~3 MB。
if [ -f "$PAYLOAD/Assets.car" ] && [ -d "$PAYLOAD/PlugIns/WebDriverAgentRunner.xctest" ]; then
  rm -f "$PAYLOAD/PlugIns/WebDriverAgentRunner.xctest/Assets.car"
  find "$PAYLOAD/PlugIns/WebDriverAgentRunner.xctest" -maxdepth 1 -name 'AppIcon*.png' -delete
fi

echo "==> 2.5/4 调整扩展 bundle id（REID）"
# 背景：Xcode 生成的 XCTRunner 结构是「反向嵌套」——
#   主 App  com.facebook.WebDriverAgentRunner.xctrunner
#   扩展    com.facebook.WebDriverAgentRunner        （PlugIns/*.xctest）
# 而 isideload（iloader 用的库）在 update_bundle_id() 里要求
#   扩展 id 必须以主 App id 开头且更长，否则报
#   "Extension X is not part of the main app bundle identifier: Y"。
# 这里只改扩展 id，把它变成主 App id 的子域：
#   com.facebook.WebDriverAgentRunner.xctrunner.tests
# 主 App id 一个字符都不动；xctest 文件名/路径也不动
# （go-ios 按【路径】加载 xctest、模块名取自【文件名】，不依赖 id）。
# REID=0 可关闭本步，回到 Xcode 原始结构。
XT_PLIST="$PAYLOAD/PlugIns/WebDriverAgentRunner.xctest/Info.plist"
if [ "${REID:-1}" = "1" ] && [ -f "$XT_PLIST" ]; then
  APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PAYLOAD/Info.plist")"
  OLD_XT_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$XT_PLIST")"
  NEW_XT_ID="${XT_ID:-${APP_ID}.tests}"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${NEW_XT_ID}" "$XT_PLIST"
  echo "  主 App  id: ${APP_ID}   (未改动)"
  echo "  扩展    id: ${OLD_XT_ID} -> ${NEW_XT_ID}"
else
  echo "  REID=0，保持 Xcode 原始的 .xctrunner 反向嵌套结构"
fi

# 记录【最终进包】的 id（REID 之后），后面 summary 用这两个值
FINAL_RUNNER_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PAYLOAD/Info.plist")"
FINAL_XTEST_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$XT_PLIST" 2>/dev/null || echo '?')"
FINAL_DISPLAY_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$PAYLOAD/Info.plist" 2>/dev/null || echo '?')"

echo "==> 3/4 剥离代码签名"
if [ "${STRIP:-1}" = "1" ]; then
  bash "$ROOT/Scripts/strip-codesign.sh" "$OUT/Payload" || {
    echo "剥离签名失败，不打包" >&2
    exit 1
  }
else
  echo "  STRIP=0，跳过剥离（产物是混签名包，iOS 会拒装）" >&2
fi

echo "==> 4/4 打包"
( cd "$OUT" && zip -qry -X "$IPA" Payload )
rm -rf "$OUT/Payload"

# 两个稳定入口：catpaws-latest.ipa（脚本/文档都指向它）和旧名（兼容老流程）
cp -f "$IPA" "$LATEST"
cp -f "$IPA" "$COMPAT"

cp "$DERIVED"/Build/Products/*.xctestrun "$OUT"/ 2>/dev/null || true

# 对最终 IPA 再验一遍：解包 → 扫描 Mach-O → 报告
echo "==> 校验最终 IPA"
VERIFY="$OUT/.verify"
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
  echo "ipa_compat=$COMPAT"
  echo "ipa_bytes=$size_bytes"
  echo "ipa_sha256=$sha256"
  echo "macho_total=${macho_total:-0}"
  echo "macho_signed=${macho_signed:-unknown}"
  echo "strip_enabled=${STRIP:-1}"
  echo "verify_rc=$verify_rc"
  echo "built_utc=$built"
  echo "reid_enabled=${REID:-1}"
  echo "runner_bundle_id=${FINAL_RUNNER_ID}"
  echo "xctest_bundle_id=${FINAL_XTEST_ID}"
  echo "display_name=${FINAL_DISPLAY_NAME}"
  echo "version=${VERSION}"
} > "$SUMMARY"

echo
echo "完成："
ls -lh "$IPA"
echo
echo "bundle id（最终进包值）:"
echo "  runner app : ${FINAL_RUNNER_ID}"
echo "  xctest     : ${FINAL_XTEST_ID}"
echo
cat "$SUMMARY"

if [ "$verify_rc" != "0" ] || [ "${macho_signed:-1}" != "0" ]; then
  echo "错误：IPA 内仍有带签名的 Mach-O，拿去装必然 0xE8008001" >&2
  exit 1
fi
