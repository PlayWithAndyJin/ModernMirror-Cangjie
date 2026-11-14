#!/usr/bin/env bash
set -euo pipefail

# 构建 openHiTLS 静态库 输出到 .deps 目录 供 crypto.cj 静态链接
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$ROOT/.deps"
SRC="${OPENHITLS_SRC_DIR:-$DEPS/hitls-src}"
OUT="$DEPS/hitls"
REPO="${OPENHITLS_REPO:-https://gitcode.com/openHiTLS/openHiTLS.git}"
BUILD="$SRC/build"

if [ -f "$OUT/lib/libhitls.a" ] && [ -d "$OUT/include/crypto" ]; then
  echo "openHiTLS 已就绪 跳过构建"
  exit 0
fi

mkdir -p "$DEPS"

if [ ! -d "$SRC/.git" ]; then
  if [ -d "$SRC" ] && [ -n "$(ls -A "$SRC" 2>/dev/null)" ]; then
    echo "使用本地 openHiTLS 源码 $SRC"
  else
    rm -rf "$SRC"
    echo "克隆 openHiTLS 从 $REPO"
    if ! git clone --depth 1 "$REPO" "$SRC"; then
      echo "主仓库不可达 改用 GitHub 镜像" >&2
      rm -rf "$SRC"
      git clone --depth 1 https://github.com/openHiTLS/openHiTLS.git "$SRC"
    fi
  fi
fi

JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
cmake -S "$SRC" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release \
  -DHITLS_BUNDLE_LIB=ON \
  -DHITLS_BUILD_SHARED=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
cmake --build "$BUILD" -j "$JOBS"

mkdir -p "$OUT/lib"
rm -rf "$OUT/include"
cp -R "$SRC/include" "$OUT/include"

if [ -f "$BUILD/libhitls.a" ]; then
  cp "$BUILD/libhitls.a" "$OUT/lib/libhitls.a"
else
  FOUND="$(find "$BUILD" -name "libhitls.a" | head -n 1)"
  if [ -z "$FOUND" ]; then
    echo "未找到 libhitls.a 构建失败" >&2
    exit 1
  fi
  cp "$FOUND" "$OUT/lib/libhitls.a"
fi

echo "openHiTLS 构建完成 $OUT/lib/libhitls.a"
