#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MASTER="$DIR/et-logo.svg"
MENU_MASTER="$DIR/menubar-template.svg"
ICONSET="$DIR/AppIcon.iconset"
ICNS="$DIR/AppIcon.icns"
SWIFT_RENDERER="$DIR/render-svg.swift"
SWIFT_CACHE="$DIR/.swift-module-cache"

fail() {
  echo "generate.sh: $*" >&2
  exit 1
}

need_file() {
  [ -f "$1" ] || fail "missing $1"
}

render_with_swift() {
  command -v swift >/dev/null 2>&1 || return 1
  mkdir -p "$SWIFT_CACHE"
  swift -module-cache-path "$SWIFT_CACHE" "$SWIFT_RENDERER" "$1" "$2" "$3" "$4" >/dev/null 2>&1
}

render_with_sips() {
  command -v sips >/dev/null 2>&1 || return 1
  sips -s format png -z "$4" "$3" "$1" --out "$2" >/dev/null 2>&1
}

render_with_qlmanage() {
  command -v qlmanage >/dev/null 2>&1 || return 1
  command -v sips >/dev/null 2>&1 || return 1

  local input="$1"
  local output="$2"
  local width="$3"
  local height="$4"
  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/et-logo-render.XXXXXX")"

  qlmanage -t -s "$width" -o "$tmp" "$input" >/dev/null 2>&1 || {
    rm -rf "$tmp"
    return 1
  }

  local thumb
  thumb="$(find "$tmp" -maxdepth 1 -type f -name '*.png' -print | head -n 1)"
  if [ -z "$thumb" ]; then
    rm -rf "$tmp"
    return 1
  fi

  sips -s format png -z "$height" "$width" "$thumb" --out "$output" >/dev/null 2>&1
  rm -rf "$tmp"
}

render_svg() {
  local input="$1"
  local output="$2"
  local width="$3"
  local height="$4"

  rm -f "$output"
  if render_with_swift "$input" "$output" "$width" "$height" && [ -s "$output" ]; then
    return 0
  fi
  rm -f "$output"
  if render_with_sips "$input" "$output" "$width" "$height" && [ -s "$output" ]; then
    return 0
  fi
  rm -f "$output"
  if render_with_qlmanage "$input" "$output" "$width" "$height" && [ -s "$output" ]; then
    return 0
  fi

  fail "could not render $input to $output"
}

build_icns_with_python() {
  command -v python3 >/dev/null 2>&1 || fail "python3 is required for the ICNS fallback"
  python3 - "$ICONSET" "$ICNS" <<'PY'
from pathlib import Path
import struct
import sys

iconset = Path(sys.argv[1])
output = Path(sys.argv[2])

members = [
    ("icp4", "icon_16x16.png"),
    ("ic11", "icon_16x16@2x.png"),
    ("icp5", "icon_32x32.png"),
    ("ic12", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic13", "icon_128x128@2x.png"),
    ("ic08", "icon_256x256.png"),
    ("ic14", "icon_256x256@2x.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"),
]

chunks = []
for code, filename in members:
    data = (iconset / filename).read_bytes()
    chunks.append(code.encode("ascii") + struct.pack(">I", len(data) + 8) + data)

payload = b"".join(chunks)
output.write_bytes(b"icns" + struct.pack(">I", len(payload) + 8) + payload)
PY
}

need_file "$MASTER"
need_file "$MENU_MASTER"
need_file "$SWIFT_RENDERER"
command -v iconutil >/dev/null 2>&1 || fail "iconutil is required"
trap 'rm -rf "$SWIFT_CACHE"' EXIT

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

render_svg "$MASTER" "$ICONSET/icon_16x16.png" 16 16
render_svg "$MASTER" "$ICONSET/icon_16x16@2x.png" 32 32
render_svg "$MASTER" "$ICONSET/icon_32x32.png" 32 32
render_svg "$MASTER" "$ICONSET/icon_32x32@2x.png" 64 64
render_svg "$MASTER" "$ICONSET/icon_128x128.png" 128 128
render_svg "$MASTER" "$ICONSET/icon_128x128@2x.png" 256 256
render_svg "$MASTER" "$ICONSET/icon_256x256.png" 256 256
render_svg "$MASTER" "$ICONSET/icon_256x256@2x.png" 512 512
render_svg "$MASTER" "$ICONSET/icon_512x512.png" 512 512
render_svg "$MASTER" "$ICONSET/icon_512x512@2x.png" 1024 1024

rm -f "$ICNS"
if ! iconutil -c icns -o "$ICNS" "$ICONSET" >/dev/null 2>&1 || [ ! -s "$ICNS" ]; then
  rm -f "$ICNS"
  echo "generate.sh: iconutil could not build this iconset here; using ICNS container fallback" >&2
  build_icns_with_python
fi
[ -s "$ICNS" ] || fail "failed to create $ICNS"

render_svg "$MENU_MASTER" "$DIR/menubar-template.png" 36 36
[ -s "$DIR/menubar-template.png" ] || fail "failed to create menu bar PNG"

for path in \
  "$ICONSET/icon_16x16.png" \
  "$ICONSET/icon_16x16@2x.png" \
  "$ICONSET/icon_32x32.png" \
  "$ICONSET/icon_32x32@2x.png" \
  "$ICONSET/icon_128x128.png" \
  "$ICONSET/icon_128x128@2x.png" \
  "$ICONSET/icon_256x256.png" \
  "$ICONSET/icon_256x256@2x.png" \
  "$ICONSET/icon_512x512.png" \
  "$ICONSET/icon_512x512@2x.png" \
  "$DIR/menubar-template.png" \
  "$ICNS"; do
  [ -s "$path" ] || fail "expected non-empty output missing: $path"
done

echo "Generated AppIcon.iconset, AppIcon.icns, and menubar-template.png"
