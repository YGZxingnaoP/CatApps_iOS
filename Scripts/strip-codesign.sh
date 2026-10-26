#!/bin/bash
#
# 剥离 iOS 包内「全部」代码签名，让 Sideloadly / AltStore 用自己的证书整体重签。
#
# 为什么必须剥：Xcode 的 build-for-testing 会把 XCTRunner 桩 app 和 XCTest 等 14 个
# 系统 framework 原样拷贝过来，它们带着苹果证书的签名；而 PlugIns/ 里的
# WebDriverAgentRunner.xctest、Frameworks/WebDriverAgentLib.framework 是未签名的。
# 这种「混签名」包 iOS 一律拒装（0xE8008001 ApplicationVerificationFailed）。
#
# 只删 _CodeSignature 目录是不够的：真正的签名数据在 Mach-O 的 LC_CODE_SIGNATURE
# load command 里，必须用 codesign --remove-signature 去掉。
#
# 用法：
#   Scripts/strip-codesign.sh <App.app | Payload 目录>        就地剥离 + 校验
#   Scripts/strip-codesign.sh <in.ipa> [out.ipa]              解包 → 剥离 → 重新打包
#   Scripts/strip-codesign.sh <目标> --check                  只报告签名状态，不改文件
#
# 退出码：0 = 目标内所有 Mach-O 都无签名；1 = 仍有残留签名；2 = 参数/环境错误。

set -uo pipefail

CHECK=0
TARGET=""
OUT=""

for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *)
      if [ -z "$TARGET" ]; then
        TARGET="$arg"
      elif [ -z "$OUT" ]; then
        OUT="$arg"
      else
        echo "too many arguments: $arg" >&2
        exit 2
      fi
      ;;
  esac
done

if [ -z "$TARGET" ]; then
  echo "usage: $0 <App.app|Payload|in.ipa> [out.ipa] [--check]" >&2
  exit 2
fi
if [ ! -e "$TARGET" ]; then
  echo "not found: $TARGET" >&2
  exit 2
fi

TMPFILES=()
cleanup() {
  if [ ${#TMPFILES[@]} -gt 0 ]; then
    rm -rf "${TMPFILES[@]}"
  fi
}
trap cleanup EXIT

# 列出目录下所有 Mach-O 普通文件（符号链接不算，避免同一份二进制处理两次）
list_machos() { # $1=dir $2=out-file
  local dir="$1" out="$2"
  [ -n "$dir" ] || return 1
  find "$dir" -type f -print0 2>/dev/null |
    while IFS= read -r -d '' f; do
      case "$(file -b "$f" 2>/dev/null)" in
        Mach-O*) printf '%s\n' "$f" ;;
      esac
    done > "$out"
}

strip_dir() { # $1=dir
  local dir="$1" mc="$2"
  local n=0

  # 1) 签名目录与描述文件
  while IFS= read -r -d '' d; do
    rm -rf "$d"
  done < <(find "$dir" -type d \( -name '_CodeSignature' -o -name 'SC_Info' \) -print0 2>/dev/null)
  find "$dir" -type f \( -name 'embedded.mobileprovision' -o -name 'CodeResources' \
       -o -name '.DS_Store' \) -delete 2>/dev/null
  # 删掉 _CodeSignature 后可能留下悬空符号链接
  find "$dir" -type l ! -exec test -e {} \; -delete 2>/dev/null

  # 2) Mach-O 内部的 LC_CODE_SIGNATURE
  list_machos "$dir" "$mc"
  while IFS= read -r f; do
    codesign --remove-signature "$f" >/dev/null 2>&1 || true
    n=$((n + 1))
  done < "$mc"
  printf '  stripped %s Mach-O binaries\n' "$n"
}

check_dir() { # $1=dir $2=out  -> prints report, echoes "TOTAL BAD" as last line
  local dir="$1" mc="$2"
  local f total=0 bad=0

  list_machos "$dir" "$mc"
  while IFS= read -r f; do
    total=$((total + 1))
    if otool -l "$f" 2>/dev/null | grep -q 'LC_CODE_SIGNATURE'; then
      printf '  SIGNED  %s\n' "${f#"$dir"/}"
      bad=$((bad + 1))
    fi
  done < "$mc"

  local leftover
  leftover=$(find "$dir" -type d -name '_CodeSignature' 2>/dev/null | wc -l | tr -d ' ')
  if [ "$leftover" != "0" ]; then
    printf '  LEFT    %s _CodeSignature dir(s)\n' "$leftover"
    bad=$((bad + leftover))
  fi

  printf '%s %s\n' "$total" "$bad"
}

# ---- 目录模式 -------------------------------------------------------------
strip_and_check_dir() { # $1=dir
  local dir="$1" mc report total bad
  mc=$(mktemp)
  TMPFILES+=("$mc")

  if [ "$CHECK" = "0" ]; then
    printf '==> stripping signatures in %s\n' "$dir"
    strip_dir "$dir" "$mc"
  fi

  printf '==> verifying %s\n' "$dir"
  report=$(check_dir "$dir" "$mc")
  printf '%s\n' "$report" | sed '$d'
  read -r total bad <<< "$(printf '%s\n' "$report" | tail -1)"
  printf '  Mach-O total: %s, still signed: %s\n' "$total" "$bad"
  [ "$bad" = "0" ] && return 0 || return 1
}

# ---- IPA 模式 -------------------------------------------------------------
strip_and_check_ipa() {
  local in="$1" outp="$2" tmp
  if [ -z "$outp" ]; then
    outp="${in%.ipa}-stripped.ipa"
  fi
  tmp=$(mktemp -d)
  TMPFILES+=("$tmp")

  printf '==> unpack %s\n' "$in"
  unzip -q "$in" -d "$tmp" || { echo "unzip failed" >&2; return 2; }
  if [ ! -d "$tmp/Payload" ]; then
    echo "no Payload/ inside $in" >&2
    return 2
  fi

  mkdir -p "$(dirname "$outp")"
  if [ "$CHECK" = "1" ]; then
    strip_and_check_dir "$tmp/Payload"
    return $?
  fi

  strip_and_check_dir "$tmp/Payload" || {
    echo "strip/verify failed, nothing written" >&2
    return 1
  }
  printf '==> repack %s\n' "$outp"
  ( cd "$tmp" && zip -qry -X payload.zip Payload ) || return 2
  mv -f "$tmp/payload.zip" "$outp" || return 2
  ls -l "$outp"
  return 0
}

# ---- main -----------------------------------------------------------------
case "$TARGET" in
  *.ipa)
    strip_and_check_ipa "$TARGET" "$OUT"
    ;;
  *)
    if [ ! -d "$TARGET" ]; then
      echo "not a directory: $TARGET" >&2
      exit 2
    fi
    strip_and_check_dir "$TARGET"
    ;;
esac
