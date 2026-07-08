#!/bin/bash
# =============================================================================
# 打包「恩特输入法」为向导式 .pkg 安装器（装到 /Library/Input Methods 并自动注册）。
#
#   ./scripts/make-pkg.sh <version> <path-to-ETInput.app> [output.pkg]
#
# 与 build_install.sh / CI 组装出来的 ETInput.app 配套使用。未做 Apple 公证
# （无 Developer ID Installer 证书），产物为未签名 pkg。
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?用法: make-pkg.sh <version> <ETInput.app> [out.pkg]}"
APP="${2:?缺少 ETInput.app 路径}"
OUT="${3:-ETInput-${VERSION}.pkg}"
IDENT="com.isaac.inputmethod.ETInput"

[ -d "$APP" ] || { echo "!! 找不到 $APP"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 组件包：把 ETInput.app 装到 /Library/Input Methods，带 postinstall 注册脚本。
mkdir -p "$TMP/root"
cp -R "$APP" "$TMP/root/恩特输入法.app"
chmod +x scripts/pkg/scripts/postinstall

pkgbuild \
    --root "$TMP/root" \
    --install-location "/Library/Input Methods" \
    --identifier "$IDENT" \
    --version "$VERSION" \
    --scripts scripts/pkg/scripts \
    "$TMP/component.pkg"

# 产品包：套上欢迎/说明/完成三页向导。
productbuild \
    --distribution scripts/pkg/distribution.xml \
    --resources scripts/pkg/resources \
    --package-path "$TMP" \
    "$OUT"

echo "==> 已生成 $OUT ($(du -h "$OUT" | cut -f1))"
