#!/usr/bin/env bash
set -euo pipefail

# 编译仓颉后端 缺少依赖时自动准备
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v cjc >/dev/null 2>&1; then
  for envsetup in "$HOME/cangjie/envsetup.sh" "${CANGJIE_HOME:-}/envsetup.sh" "/usr/local/cangjie/envsetup.sh"; do
    if [ -f "$envsetup" ]; then
      # shellcheck disable=SC1090
      source "$envsetup"
      break
    fi
  done
fi

if ! command -v cjc >/dev/null 2>&1; then
  echo "未找到仓颉编译器 请先安装 SDK 或设置 CANGJIE_HOME" >&2
  exit 1
fi

if [ ! -f "$ROOT/.deps/stdx/stdx/stdx.cjo" ] || [ ! -f "$ROOT/.deps/hitls/lib/libhitls.a" ]; then
  bash "$ROOT/scripts/setup.sh"
fi

cd "$ROOT"
cjpm build
echo "编译完成 target/release/bin/main"
