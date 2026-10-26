#!/usr/bin/env bash
#
# 把 CustomCode/ 里的魔改覆盖到 WebDriverAgent 上。
# 上游不在时，先按固定 commit 拉一份（--depth 1，约 0.8 MB）。
#
# 用法：
#   ./apply.sh               # 目标 ./WebDriverAgent
#   ./apply.sh /tmp/wd       # 指定目标目录
#
# 幂等：WebDriverAgent 已存在且在同一条 commit 上时，只重新覆盖一遍。

set -euo pipefail

UPSTREAM="https://github.com/appium/WebDriverAgent.git"
PIN="e7e2665a00633dc174d7fc579f7e606bc9ba782a"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-$HERE/WebDriverAgent}"

if [ -e "$TARGET/.git" ]; then
  echo "==> 复用已有检出: $TARGET"
  HEAD_SHA="$(git -C "$TARGET" rev-parse HEAD)"
  if [ "$HEAD_SHA" != "$PIN" ]; then
    echo "警告: HEAD=$HEAD_SHA，与 pin=$PIN 不一致；CustomCode 是按 pin 版本改的，覆盖后可能丢上游改动。" >&2
  fi
else
  echo "==> 拉取上游 $PIN"
  git init -q "$TARGET"
  # 上游是 LF；Windows 默认 autocrlf=true 会把工作树转成 CRLF，导致 CustomCode 覆盖后内容错位
  git -C "$TARGET" config core.autocrlf false
  git -C "$TARGET" config core.safecrlf false
  git -C "$TARGET" remote add origin "$UPSTREAM"
  git -C "$TARGET" fetch --depth 1 origin "$PIN"
  git -C "$TARGET" checkout -q -B catpaws FETCH_HEAD
fi

echo "==> 覆盖 CustomCode → $TARGET"
for d in WebDriverAgentLib WebDriverAgent.xcodeproj WebDriverAgentRunner Scripts; do
  [ -d "$HERE/CustomCode/$d" ] || continue
  mkdir -p "$TARGET/$d"
  cp -R "$HERE/CustomCode/$d/." "$TARGET/$d/"
done

# Windows 侧 tar/zip 会丢可执行位；Xcode 的 scheme post-action 直接执行这些脚本
chmod +x "$TARGET/Scripts/"*.sh 2>/dev/null || true

echo
echo "完成: $TARGET"
echo "下一步: ./Scripts/build-unsigned-ipa.sh"
