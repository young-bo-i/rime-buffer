#!/bin/bash
# Builds RimeBuffer.app (an IMK input method), installs it into the per-user
# Input Methods folder, and (re)registers it so it shows in System Settings.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="RimeBuffer.app"
DEST="$HOME/Library/Input Methods/$APP"

# RimeBuffer uses its OWN user dir so it never fights Squirrel over the userdb
# LevelDB lock. Seed it from the live ~/Library/Rime (includes the compiled
# build/ so no deploy is needed). Re-run `rm -rf ~/Library/RimeBuffer` to reseed
# after editing your Rime config.
RB_USER="$HOME/Library/RimeBuffer"
if [ ! -d "$RB_USER/build" ]; then
    echo "==> seeding $RB_USER from ~/Library/Rime"
    rm -rf "$RB_USER"; mkdir -p "$RB_USER"
    rsync -a --exclude 'sync' "$HOME/Library/Rime/" "$RB_USER/"
fi

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/RimeBuffer"
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RimeBuffer"
cp Info.plist "$APP/Contents/Info.plist"

# Ad-hoc sign for local testing (a trusted identity needs interactive keychain
# access we don't have in a background shell — errSecInternalComponent — and is
# only needed for the make-default/notarized phase). No nested code, so no --deep.
echo "==> ad-hoc signing"
codesign --force --sign - "$APP"

echo "==> stopping any running instance"
pkill -x RimeBuffer 2>/dev/null || true
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
  → Chinese, Simplified (or Other) → "RimeBuffer" → Add
Then switch to it with the input menu (or Ctrl-Space) and type.

Watch behaviour:  tail -f ~/rimebuffer.log
Your Squirrel stays installed as the fallback — switch back anytime.
EOF
