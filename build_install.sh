#!/bin/bash
# Builds ETInput.app (恩特输入法, an IMK input method) as a SELF-CONTAINED bundle:
# librime + the Rime shared data are packaged inside, so no separate Squirrel
# install is needed. Installs into the per-user Input Methods folder and
# registers + enables + selects it so it shows in System Settings / the input menu.
#
# IMPORTANT invariants (learned the hard way — see RELEASE.md):
#   * The .app directory name MUST be ASCII (ETInput.app). The Chinese product
#     name lives only in CFBundleName/CFBundleDisplayName + InfoPlist.strings.
#     A CJK bundle path breaks the System Settings picker's name/icon resolution.
#   * There must be EXACTLY ONE bundle with this id on disk. A stray copy (e.g.
#     left in the repo working tree) registers the same input-source id at a
#     second path and poisons TIS/LaunchServices → blank/greyed picker row. So
#     we assemble in a throwaway staging dir and delete it after installing.
#
# (The SPM target / source dir stay named "RimeBuffer" — internal codename / repo;
# the shipped product is ETInput / 恩特输入法.)
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="ETInput.app"                   # ASCII bundle dir name (display name is Chinese via InfoPlist.strings)
EXE="ETInput"
STAGE=".build/stage"                # assemble here, not in the repo root
APP_PATH="$STAGE/$APP"
DEST="$HOME/Library/Input Methods/$APP"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# Fetch the bundled librime runtime (cached in Vendor/, not committed to git).
./scripts/fetch-rime.sh

# Its OWN Rime user dir (never fights Squirrel over the userdb LevelDB lock).
# Self-contained: the app deploys its schemas from the BUNDLED SharedSupport
# (Vendor stock + rime-data/, default 串击 my_serial + 并击 my_combo) into this
# dir on first launch. Wipe any stale deploy — from an older build or the
# previous local RimeBuffer — so this install reflects exactly what ships,
# instead of leftover data (e.g. an old 并击-first default). Set
# RB_KEEP_USERDB=1 to preserve a prior learned userdb.
RB_USER="$HOME/Library/RimeBuffer"
if [ -d "$RB_USER" ] && [ "${RB_KEEP_USERDB:-0}" != "1" ]; then
    echo "==> resetting $RB_USER so the app redeploys fresh from the bundle"
    rm -rf "$RB_USER"
fi

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/RimeBuffer"
echo "==> assembling $APP (in $STAGE)"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" \
         "$APP_PATH/Contents/Frameworks" "$APP_PATH/Contents/SharedSupport"
cp "$BIN" "$APP_PATH/Contents/MacOS/$EXE"
cp Info.plist "$APP_PATH/Contents/Info.plist"

# Bump CFBundleVersion on the installed copy each build so LaunchServices/TIS
# re-read the bundle's metadata instead of serving a stale cache. (Source
# Info.plist is untouched, so git stays clean.)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%s)" "$APP_PATH/Contents/Info.plist" 2>/dev/null || true
# A complete .app has a PkgInfo (both Squirrel and Sogou ship one).
printf 'APPL????' > "$APP_PATH/Contents/PkgInfo"

# Bundle the self-contained runtime: librime + plugins + Rime shared data.
cp -R Vendor/rime/Frameworks/* "$APP_PATH/Contents/Frameworks/"
cp -R Vendor/rime/SharedSupport/* "$APP_PATH/Contents/SharedSupport/"

# Overlay OUR Rime schemas (雾凇 rime_ice base + 串击 my_serial 默认 + 并击 my_combo,
# 及 cn_dicts/en_dicts/lua/opencc/custom_phrase) onto the stock SharedSupport so a
# fresh install deploys the real schemas — not just default luna_pinyin. This is
# what makes 串击/并击 work WITHOUT a separate Squirrel/~/Library/Rime. The secret
# rime_ai.local.json is intentionally NOT bundled (only rime_ai.example.json).
cp -R rime-data/* "$APP_PATH/Contents/SharedSupport/"

# App icon, if it's been generated.
if [ -f "Logo/AppIcon.icns" ]; then
    cp "Logo/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
fi

# Localized input-source display name (恩特输入法) + the input-mode menu icon.
# Without the .lproj the source shows its raw id; without the icon it renders as
# a blank row and won't enable.
cp -R Resources/*.lproj "$APP_PATH/Contents/Resources/" 2>/dev/null || true
cp Resources/etinput.pdf "$APP_PATH/Contents/Resources/" 2>/dev/null || true
cp Resources/etinput-menu.pdf "$APP_PATH/Contents/Resources/" 2>/dev/null || true
cp Resources/menubar-template.png "$APP_PATH/Contents/Resources/" 2>/dev/null || true

# Ad-hoc sign. --deep now that we have nested dylibs (librime + plugins).
echo "==> ad-hoc signing (deep)"
codesign --force --deep --sign - "$APP_PATH"

echo "==> purging stray/duplicate registrations (same id at other paths poisons the picker)"
pkill -x "$EXE" 2>/dev/null || true
pkill -x RimeBuffer 2>/dev/null || true
sleep 0.5
# Any leftover copies in the repo tree or a previous CJK-named install.
for stray in "恩特输入法.app" "ETInput.app" \
             "$HOME/Library/Input Methods/恩特输入法.app"; do
    if [ -e "$stray" ]; then
        "$LSREGISTER" -u "$stray" 2>/dev/null || true
        rm -rf "$stray"
        echo "    removed stray: $stray"
    fi
done

echo "==> installing to $DEST"
rm -rf "$DEST"
"$LSREGISTER" -u "$DEST" 2>/dev/null || true
mkdir -p "$HOME/Library/Input Methods"
cp -R "$APP_PATH" "$DEST"
rm -rf "$STAGE/$APP"                 # don't leave a staging copy lying around

echo "==> registering the single installed copy with Launch Services"
"$LSREGISTER" -f "$DEST" || true

echo "==> self-install: register + enable + select inside the login session"
open -n "$DEST" --args --install    # short-lived instance does the TIS calls, then exits
sleep 2
open "$DEST" || true                 # start the IMK server (status menu / ready)

cat <<EOF

==> done. Installed a single ASCII-named bundle and self-enabled it.

If 恩特输入法 doesn't appear in the input menu (⌃Space) immediately, run:
  killall TextInputMenuAgent SystemUIServer
(or log out / back in once). Then switch to it and type 'nihao' -> 你好.

Watch behaviour:  tail -f ~/rimebuffer.log
Self-contained: librime + Rime data are bundled, no Squirrel needed.
EOF
