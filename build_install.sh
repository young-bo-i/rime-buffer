#!/bin/bash
# Builds ETInput.app (恩特输入法, an IMK input method) as a SELF-CONTAINED bundle:
# librime + the Rime shared data are packaged inside, so no separate Squirrel
# install is needed. Installs into the per-user Input Methods folder and
# (re)registers it so it shows in System Settings.
#
# (The SPM target / source dir stay named "RimeBuffer" — that's the internal
# codename / repo; the shipped product is ETInput / 恩特输入法.)
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="ETInput.app"
EXE="ETInput"
DEST="$HOME/Library/Input Methods/$APP"

# Fetch the bundled librime runtime (cached in Vendor/, not committed to git).
./scripts/fetch-rime.sh

# Its OWN Rime user dir so it never fights Squirrel over the userdb LevelDB lock.
# If a live ~/Library/Rime exists (Squirrel installed), seed from it so custom
# schemas carry over; otherwise the app deploys from the bundled SharedSupport on
# first run. Re-run `rm -rf ~/Library/RimeBuffer` to reseed.
RB_USER="$HOME/Library/RimeBuffer"
if [ ! -d "$RB_USER/build" ] && [ -d "$HOME/Library/Rime" ]; then
    echo "==> seeding $RB_USER from ~/Library/Rime"
    rm -rf "$RB_USER"; mkdir -p "$RB_USER"
    rsync -a --exclude 'sync' "$HOME/Library/Rime/" "$RB_USER/"
fi

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/RimeBuffer"
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" \
         "$APP/Contents/Frameworks" "$APP/Contents/SharedSupport"
cp "$BIN" "$APP/Contents/MacOS/$EXE"
cp Info.plist "$APP/Contents/Info.plist"

# Bundle the self-contained runtime: librime + plugins + Rime shared data.
cp -R Vendor/rime/Frameworks/* "$APP/Contents/Frameworks/"
cp -R Vendor/rime/SharedSupport/* "$APP/Contents/SharedSupport/"

# App icon, if it's been generated.
if [ -f "Logo/AppIcon.icns" ]; then
    cp "Logo/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Localized input-source display name (恩特输入法) + the input-mode menu icon.
# Without the .lproj the source shows its raw id; without the icon it renders as
# a blank row and won't enable.
cp -R Resources/*.lproj "$APP/Contents/Resources/" 2>/dev/null || true
cp Resources/etinput.png "$APP/Contents/Resources/" 2>/dev/null || true

# Ad-hoc sign. --deep now that we have nested dylibs (librime + plugins).
echo "==> ad-hoc signing (deep)"
codesign --force --deep --sign - "$APP"

echo "==> stopping any running instance"
pkill -x "$EXE" 2>/dev/null || true
pkill -x RimeBuffer 2>/dev/null || true   # kill a pre-rename instance too
sleep 0.5

echo "==> installing to $DEST"
rm -rf "$DEST"
mkdir -p "$HOME/Library/Input Methods"
cp -R "$APP" "$DEST"

echo "==> registering with Launch Services + IMK"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" || true
open "$DEST" || true

cat <<EOF

==> done.

One-time GUI step to enable it:
  System Settings → Keyboard → (Text Input) Input Sources → Edit… → +
  → Chinese, Simplified (or Other) → "恩特输入法" → Add
Then switch to it with the input menu (or Ctrl-Space) and type.

Watch behaviour:  tail -f ~/rimebuffer.log
Self-contained: librime + Rime data are bundled, no Squirrel needed.
EOF
