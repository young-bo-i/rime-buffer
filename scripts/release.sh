#!/bin/bash
# =============================================================================
# RimeBuffer 发布脚本
#
# 打一个 v 开头的 tag 并推到 GitHub（origin），触发 .github/workflows/release.yml
# 构建 → 打包 → 创建 Release。已安装的 RimeBuffer 会自动检测到这个 Release 并提示更新。
#
# 用法：
#   ./scripts/release.sh          # patch +1 (0.1.0 -> 0.1.1)
#   ./scripts/release.sh patch    # 同上
#   ./scripts/release.sh minor    # 0.1.0 -> 0.2.0
#   ./scripts/release.sh major    # 0.1.0 -> 1.0.0
#   ./scripts/release.sh 0.3.2    # 指定版本号
# =============================================================================
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
die()     { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

cd "$(dirname "$0")/.."

# Push tags to whichever remote hosts the CI. Prefer 'origin' if it's GitHub,
# else fall back to a 'github' remote.
REMOTE="origin"
if ! git remote get-url origin 2>/dev/null | grep -qi github.com; then
    if git remote get-url github >/dev/null 2>&1; then
        REMOTE="github"
    else
        die "找不到指向 github.com 的远程（origin 或 github）。"
    fi
fi
info "发布远程: $REMOTE ($(git remote get-url "$REMOTE"))"

# Latest v* tag on GitHub is the source of truth for "current version".
current="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || echo v0.0.0)"
current="${current#v}"
info "当前版本: $current"

bump() {
    IFS='.' read -r major minor patch <<< "$1"
    case "$2" in
        major) echo "$((major + 1)).0.0" ;;
        minor) echo "$major.$((minor + 1)).0" ;;
        *)     echo "$major.$minor.$((patch + 1))" ;;
    esac
}

arg="${1:-patch}"
case "$arg" in
    patch|minor|major) new="$(bump "$current" "$arg")" ;;
    *)
        [[ "$arg" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "版本号格式应为 x.y.z: $arg"
        new="$arg"
        ;;
esac
tag="v$new"

echo ""
read -p "确认发布 $tag？(y/n) " -n 1 -r; echo
[[ $REPLY =~ ^[Yy]$ ]] || { warn "已取消"; exit 0; }

if [[ -n $(git status -s) ]]; then
    warn "有未提交的更改，将随本次发布一起提交。"
    git status -s
    read -p "commit 信息: " msg
    git add -A
    git commit -m "${msg:-chore: release $tag}"
fi

# Keep the plist version in sync so local/dev builds report the right number.
if [ -f Info.plist ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $new" Info.plist 2>/dev/null || true
    if [[ -n $(git status -s Info.plist) ]]; then
        git add Info.plist
        git commit -m "chore: bump version to $new"
    fi
fi

if git rev-parse "$tag" >/dev/null 2>&1; then
    read -p "$tag 已存在，删除并重建？(y/n) " -n 1 -r; echo
    [[ $REPLY =~ ^[Yy]$ ]] || die "已取消"
    git tag -d "$tag"
    git push "$REMOTE" ":refs/tags/$tag" 2>/dev/null || true
fi

info "推送代码到 $REMOTE..."
git push "$REMOTE" HEAD:main

info "创建并推送 tag $tag..."
git tag "$tag"
git push "$REMOTE" "$tag"

owner_repo="$(git remote get-url "$REMOTE" | sed -E 's#.*github.com[:/]##; s/\.git$//')"
echo ""
success "已推送 $tag，GitHub Actions 正在构建。"
echo "  构建进度: https://github.com/$owner_repo/actions"
echo "  Release:  https://github.com/$owner_repo/releases/tag/$tag"
