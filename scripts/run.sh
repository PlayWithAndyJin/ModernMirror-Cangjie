#!/usr/bin/env bash
set -euo pipefail

# 启动后端服务 数据目录与端口可用环境变量覆盖
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/target/release/bin/main"
if [ ! -x "$BIN" ] && [ -x "$ROOT/main" ]; then
  BIN="$ROOT/main"
fi

if [ ! -x "$BIN" ]; then
  echo "未找到可执行文件 请先运行 scripts/build.sh" >&2
  exit 1
fi

export MODERNMIRROR_DATA="${MODERNMIRROR_DATA:-$ROOT/data}"
export MODERNMIRROR_PORT="${MODERNMIRROR_PORT:-8800}"
export MODERNMIRROR_HOST="${MODERNMIRROR_HOST:-0.0.0.0}"
export MODERNMIRROR_DIST="${MODERNMIRROR_DIST:-$ROOT/frontend/dist}"

if [ "$(uname -s)" = "Darwin" ]; then
  export DYLD_FALLBACK_LIBRARY_PATH="/opt/homebrew/opt/openssl@3/lib:${DYLD_FALLBACK_LIBRARY_PATH:-}"
fi

# 追加仓颉运行时库路径 优先使用随包附带的运行时 兼容未执行 envsetup 的终端
CJ_HOME="${CANGJIE_HOME:-$HOME/cangjie}"
RUNTIME_DIR=""
if [ -d "$ROOT/runtime/lib" ]; then
  RUNTIME_DIR="$ROOT/runtime/lib"
else
  RUNTIME_DIR="$(find "$CJ_HOME/runtime/lib" -maxdepth 1 -type d -name "*cjnative" 2>/dev/null | head -n 1)"
fi
if [ -n "$RUNTIME_DIR" ]; then
  export DYLD_LIBRARY_PATH="$RUNTIME_DIR:${DYLD_LIBRARY_PATH:-}"
  export LD_LIBRARY_PATH="$RUNTIME_DIR:${LD_LIBRARY_PATH:-}"
fi

cd "$ROOT"
exec "$BIN"
