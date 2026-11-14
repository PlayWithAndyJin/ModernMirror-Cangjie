#!/usr/bin/env bash
set -euo pipefail

# 一次性准备全部依赖 含 stdx openHiTLS 与前端构建产物
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

bash "$ROOT/scripts/setup-stdx.sh"
bash "$ROOT/scripts/build-openhitls.sh"

if [ "${SKIP_FRONTEND:-0}" != "1" ]; then
  if [ -f "$ROOT/frontend/package.json" ]; then
    cd "$ROOT/frontend"
    npm ci --no-audit --no-fund
    npm run build
  fi
fi

echo "依赖准备完成"
