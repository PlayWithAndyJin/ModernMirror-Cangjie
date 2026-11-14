#!/usr/bin/env bash
set -euo pipefail

# 准备仓颉标准扩展库 把预编译产物复制到 .deps 目录 使裸 cjpm build 可以直接使用
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/.deps/stdx/stdx"

find_package_dir() {
  local src="$1"
  if [ -z "$src" ]; then
    return 1
  fi
  for sub in "$src" "$src/static/stdx" "$src/stdx" "$src/static"; do
    if [ -f "$sub/stdx.cjo" ] && [ -f "$sub/libstdx.net.http.a" ]; then
      echo "$sub"
      return 0
    fi
  done
  return 1
}

if [ -f "$DEST/stdx.cjo" ]; then
  echo "stdx 已就绪 跳过复制"
  exit 0
fi

CANDIDATES=()
for env_dir in "${CANGJIE_STDX_DIR:-}" "${CANGJIE_STDX_PATH_STATIC:-}" "${CANGJIE_STDX_PATH:-}" "${CANGJIE_HOME:-}/stdx"; do
  if [ -n "$env_dir" ]; then
    CANDIDATES+=("$env_dir")
  fi
done
for base in "${CANGJIE_HOME:-}" "$HOME/cangjie" "$HOME/.cjv" "$HOME/.cangjie" "$HOME"; do
  if [ -z "$base" ] || [ ! -d "$base" ]; then
    continue
  fi
  while IFS= read -r found; do
    if [ -n "$found" ]; then
      CANDIDATES+=("$found")
    fi
  done < <(find "$base" -maxdepth 6 -type f -name "stdx.cjo" 2>/dev/null | sed 's#/stdx.cjo$##' | head -n 20)
done

for candidate in "${CANDIDATES[@]}"; do
  if PACKAGE_DIR="$(find_package_dir "$candidate")"; then
    mkdir -p "$(dirname "$DEST")"
    rm -rf "$DEST"
    cp -R "$PACKAGE_DIR" "$DEST"
    echo "已复制 stdx 从 $PACKAGE_DIR 到 $DEST"
    exit 0
  fi
done

echo "未找到仓颉 stdx 预编译库" >&2
echo "请设置 CANGJIE_STDX_DIR 指向解压后的 stdx 目录 例如 cangjie-stdx-linux-x64-1.0.5.1" >&2
exit 1
