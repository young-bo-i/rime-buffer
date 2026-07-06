#!/bin/bash
# =============================================================================
# 拉取 librime 运行时到 Vendor/rime/，用于把 RimeBuffer 打成自包含 app
# （装一个就能用，无需单独安装 Squirrel）。
#
# 来源：Squirrel 官方 .pkg。librime 是静态链接的（依赖只有系统 libSystem/libc++），
# 所以只需取 librime.1.dylib + 3 个插件 + SharedSupport（默认词库/方案）。
# 不取 Sparkle（那是 Squirrel 自己的更新器，RimeBuffer 用自己的自动更新）。
#
# Vendor/ 是 gitignore 的——不把二进制提交进仓库，构建时按锁定版本拉取。
#
#   ./scripts/fetch-rime.sh            # 已存在则跳过
#   ./scripts/fetch-rime.sh --force    # 强制重新拉取
#   SQUIRREL_VERSION=1.1.2 ./scripts/fetch-rime.sh
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

SQUIRREL_VERSION="${SQUIRREL_VERSION:-1.1.2}"
DEST="Vendor/rime"
FORCE="${1:-}"

if [ -f "$DEST/Frameworks/librime.1.dylib" ] && [ -f "$DEST/SharedSupport/default.yaml" ] && [ "$FORCE" != "--force" ]; then
    echo "==> $DEST 已就绪（--force 可强制重取）"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PKG_URL="https://github.com/rime/squirrel/releases/download/${SQUIRREL_VERSION}/Squirrel-${SQUIRREL_VERSION}.pkg"
echo "==> 下载 $PKG_URL"
curl -fL "$PKG_URL" -o "$TMP/squirrel.pkg"

echo "==> 展开 pkg"
pkgutil --expand-full "$TMP/squirrel.pkg" "$TMP/expand" >/dev/null
SRC="$TMP/expand/Payload/Squirrel.app/Contents"
[ -f "$SRC/Frameworks/librime.1.dylib" ] || { echo "!! pkg 里没找到 librime.1.dylib"; exit 1; }

echo "==> 提取到 $DEST"
rm -rf "$DEST"
mkdir -p "$DEST/Frameworks"
cp "$SRC/Frameworks/librime.1.dylib" "$DEST/Frameworks/"
cp -R "$SRC/Frameworks/rime-plugins" "$DEST/Frameworks/"
cp -R "$SRC/SharedSupport" "$DEST/SharedSupport"

echo "==> 完成（Squirrel ${SQUIRREL_VERSION}）："
du -sh "$DEST/Frameworks" "$DEST/SharedSupport"
