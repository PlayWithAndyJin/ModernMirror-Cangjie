#!/usr/bin/env bash
set -euo pipefail

# 启动临时实例做基本自检 覆盖健康检查 登录 仓库列表 接口文档
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
PORT="${SMOKE_PORT:-18800}"

cleanup() {
  if [ -n "${PID:-}" ]; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

MODERNMIRROR_DATA="$TMP" \
MODERNMIRROR_HOST="127.0.0.1" \
MODERNMIRROR_PORT="$PORT" \
MODERNMIRROR_DIST="$ROOT/frontend/dist" \
bash "$ROOT/scripts/run.sh" >"$TMP/server.log" 2>&1 &
PID=$!

ready=0
for _ in $(seq 1 60); do
  if curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.5
done

if [ "$ready" != "1" ]; then
  echo "服务启动超时" >&2
  cat "$TMP/server.log" >&2
  exit 1
fi

curl -sf "http://127.0.0.1:$PORT/api/health" | grep -q "ok"

TOKEN="$(curl -sf -X POST "http://127.0.0.1:$PORT/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin123"}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')"

curl -sf -H "Session-Token: $TOKEN" "http://127.0.0.1:$PORT/admin/repos" | grep -q "pypi"
curl -sf -H "Session-Token: $TOKEN" "http://127.0.0.1:$PORT/admin/users" | grep -q "admin"
curl -sf -H "Session-Token: $TOKEN" "http://127.0.0.1:$PORT/docs" >/dev/null
curl -sf -H "Session-Token: $TOKEN" "http://127.0.0.1:$PORT/openapi.json" | grep -q "ModernMirror"

echo "自检通过"
