#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require sips
require iconutil
require swift
require python3

tmpdir="$(mktemp -d "$ROOT/.generate-tmp.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

export SWIFT_MODULE_CACHE_PATH="$tmpdir/swift-module-cache"
export CLANG_MODULE_CACHE_PATH="$tmpdir/clang-module-cache"
mkdir -p "$SWIFT_MODULE_CACHE_PATH" "$CLANG_MODULE_CACHE_PATH"

renderer="$tmpdir/render-svg.swift"
cat > "$renderer" <<'SWIFT'
import AppKit
import CoreGraphics
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadImage(_ path: String) -> NSImage {
    let url = URL(fileURLWithPath: path)
    guard let image = NSImage(contentsOf: url) else {
        fail("Unable to load SVG: \(path)")
    }
    return image
}

func renderPNG(src: String, size: Int, out: String) {
    let image = loadImage(src)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fail("Unable to allocate bitmap: \(out)")
    }

    rep.size = NSSize(width: size, height: size)
    let rect = NSRect(x: 0, y: 0, width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        fail("Unable to create bitmap context: \(out)")
    }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    NSColor.clear.setFill()
    rect.fill()
    image.draw(
        in: rect,
        from: NSRect(origin: .zero, size: image.size),
        operation: .sourceOver,
        fraction: 1.0,
        respectFlipped: false,
        hints: [.interpolation: NSImageInterpolation.high]
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        fail("Unable to encode PNG: \(out)")
    }

    do {
        try data.write(to: URL(fileURLWithPath: out), options: .atomic)
    } catch {
        fail("Unable to write PNG \(out): \(error)")
    }
}

// Input-source icons MUST be 16x16 pt pages (Sogou/Apple convention) — a
// bigger MediaBox renders oversized in System Settings. Multiple sources
// become multiple pages: page 1 = normal (black), page 2 = selected/dark
// (white), the same two-page layout Sogou's menubarpinyin.pdf uses.
func renderPDF(srcs: [String], pageSize: CGFloat, out: String) {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
        fail("Unable to create PDF data consumer: \(out)")
    }

    var mediaBox = CGRect(x: 0, y: 0, width: pageSize, height: pageSize)
    guard let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
        fail("Unable to create PDF context: \(out)")
    }

    for src in srcs {
        let image = loadImage(src)
        pdf.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: false)
        image.draw(
            in: NSRect(x: 0, y: 0, width: pageSize, height: pageSize),
            from: NSRect(origin: .zero, size: image.size),
            operation: .sourceOver,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()
        pdf.endPDFPage()
    }
    pdf.closePDF()

    do {
        try data.write(to: URL(fileURLWithPath: out), options: .atomic)
    } catch {
        fail("Unable to write PDF \(out): \(error)")
    }
}

let args = CommandLine.arguments
if args.count == 5 && args[1] == "png" {
    guard let size = Int(args[3]) else {
        fail("Invalid PNG size: \(args[3])")
    }
    renderPNG(src: args[2], size: size, out: args[4])
} else if args.count >= 5 && args[1] == "pdf" {
    guard let size = Int(args[2]) else {
        fail("Invalid PDF page size: \(args[2])")
    }
    renderPDF(srcs: Array(args[4...]), pageSize: CGFloat(size), out: args[3])
} else {
    fail("Usage: render-svg.swift png input.svg size output.png | pdf size output.pdf input.svg [input2.svg ...]")
}
SWIFT

render_png() {
  local src="$1"
  local size="$2"
  local out="$3"

  swift "$renderer" png "$src" "$size" "$out"
}

render_pdf() {
  local out="$1"
  local size="$2"
  shift 2

  swift "$renderer" pdf "$size" "$out" "$@"
}

assert_nonempty() {
  local file="$1"
  if [[ ! -s "$file" ]]; then
    echo "Generated file is missing or empty: $file" >&2
    exit 1
  fi
}

assert_png_size() {
  local file="$1"
  local expected="$2"
  local width height
  width="$(sips -g pixelWidth "$file" 2>/dev/null | awk '/pixelWidth:/ {print $2}')"
  height="$(sips -g pixelHeight "$file" 2>/dev/null | awk '/pixelHeight:/ {print $2}')"
  if [[ "$width" != "$expected" || "$height" != "$expected" ]]; then
    echo "Unexpected PNG size for $file: ${width}x${height}, expected ${expected}x${expected}" >&2
    exit 1
  fi
}

rm -rf AppIcon.iconset AppIcon.icns menubar-template.png inputsource.pdf menuicon.pdf
mkdir -p AppIcon.iconset

render_png app-icon.svg 16 AppIcon.iconset/icon_16x16.png
render_png app-icon.svg 32 AppIcon.iconset/icon_16x16@2x.png
render_png app-icon.svg 32 AppIcon.iconset/icon_32x32.png
render_png app-icon.svg 64 AppIcon.iconset/icon_32x32@2x.png
render_png app-icon.svg 128 AppIcon.iconset/icon_128x128.png
render_png app-icon.svg 256 AppIcon.iconset/icon_128x128@2x.png
render_png app-icon.svg 256 AppIcon.iconset/icon_256x256.png
render_png app-icon.svg 512 AppIcon.iconset/icon_256x256@2x.png
render_png app-icon.svg 512 AppIcon.iconset/icon_512x512.png
render_png app-icon.svg 1024 AppIcon.iconset/icon_512x512@2x.png

iconutil_log="$tmpdir/iconutil.log"
if ! iconutil -c icns AppIcon.iconset -o AppIcon.icns 2>"$iconutil_log"; then
  echo "iconutil rejected the iconset; writing a PNG-backed ICNS fallback." >&2
  sed 's/^/  /' "$iconutil_log" >&2
  python3 - <<'PY'
from pathlib import Path
import struct

root = Path(".")
entries = [
    ("icp4", root / "AppIcon.iconset/icon_16x16.png"),
    ("ic11", root / "AppIcon.iconset/icon_16x16@2x.png"),
    ("icp5", root / "AppIcon.iconset/icon_32x32.png"),
    ("icp6", root / "AppIcon.iconset/icon_32x32@2x.png"),
    ("ic12", root / "AppIcon.iconset/icon_32x32@2x.png"),
    ("ic07", root / "AppIcon.iconset/icon_128x128.png"),
    ("ic13", root / "AppIcon.iconset/icon_128x128@2x.png"),
    ("ic08", root / "AppIcon.iconset/icon_256x256.png"),
    ("ic14", root / "AppIcon.iconset/icon_256x256@2x.png"),
    ("ic09", root / "AppIcon.iconset/icon_512x512.png"),
    ("ic10", root / "AppIcon.iconset/icon_512x512@2x.png"),
]
chunks = []
for code, path in entries:
    data = path.read_bytes()
    chunks.append(code.encode("ascii") + struct.pack(">I", len(data) + 8) + data)
body = b"".join(chunks)
(root / "AppIcon.icns").write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
PY
fi

render_png menubar.svg 36 menubar-template.png

# Colored brand icon: System Settings row (tsInputMethodIconFileKey).
render_pdf inputsource.pdf 16 inputsource.svg

# Monochrome ET glyph for the system input menu / menu bar (tsInputMode*Icon
# keys): page 1 black for light menus, page 2 white for the selected/dark
# state — mirrors Sogou's two-page menubarpinyin.pdf.
sed 's/#000000/#FFFFFF/g' menubar.svg > "$tmpdir/menubar-white.svg"
render_pdf menuicon.pdf 16 menubar.svg "$tmpdir/menubar-white.svg"

for spec in \
  "AppIcon.iconset/icon_16x16.png:16" \
  "AppIcon.iconset/icon_16x16@2x.png:32" \
  "AppIcon.iconset/icon_32x32.png:32" \
  "AppIcon.iconset/icon_32x32@2x.png:64" \
  "AppIcon.iconset/icon_128x128.png:128" \
  "AppIcon.iconset/icon_128x128@2x.png:256" \
  "AppIcon.iconset/icon_256x256.png:256" \
  "AppIcon.iconset/icon_256x256@2x.png:512" \
  "AppIcon.iconset/icon_512x512.png:512" \
  "AppIcon.iconset/icon_512x512@2x.png:1024" \
  "menubar-template.png:36"; do
  file="${spec%%:*}"
  size="${spec##*:}"
  assert_nonempty "$file"
  assert_png_size "$file" "$size"
done

assert_nonempty AppIcon.icns
assert_nonempty inputsource.pdf
assert_nonempty menuicon.pdf

python3 - menubar-template.png <<'PY'
import struct
import sys
import zlib

path = sys.argv[1]
data = open(path, "rb").read()
if data[:8] != b"\x89PNG\r\n\x1a\n":
    raise SystemExit(f"{path} is not a PNG")

pos = 8
width = height = bit_depth = color_type = None
idat = []
while pos < len(data):
    length = struct.unpack(">I", data[pos:pos + 4])[0]
    ctype = data[pos + 4:pos + 8]
    payload = data[pos + 8:pos + 8 + length]
    pos += 12 + length
    if ctype == b"IHDR":
      width, height, bit_depth, color_type = struct.unpack(">IIBB", payload[:10])
    elif ctype == b"IDAT":
      idat.append(payload)
    elif ctype == b"IEND":
      break

if bit_depth != 8 or color_type not in (4, 6):
    raise SystemExit(f"{path} must be 8-bit grayscale+alpha or RGBA, got bit_depth={bit_depth}, color_type={color_type}")

channels = 2 if color_type == 4 else 4
bpp = channels
raw = zlib.decompress(b"".join(idat))
stride = width * channels

def paeth(a, b, c):
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c

rows = []
offset = 0
prev = bytearray(stride)
for _ in range(height):
    filter_type = raw[offset]
    offset += 1
    row = bytearray(raw[offset:offset + stride])
    offset += stride
    for i in range(stride):
        left = row[i - bpp] if i >= bpp else 0
        up = prev[i]
        up_left = prev[i - bpp] if i >= bpp else 0
        if filter_type == 1:
            row[i] = (row[i] + left) & 0xff
        elif filter_type == 2:
            row[i] = (row[i] + up) & 0xff
        elif filter_type == 3:
            row[i] = (row[i] + ((left + up) // 2)) & 0xff
        elif filter_type == 4:
            row[i] = (row[i] + paeth(left, up, up_left)) & 0xff
        elif filter_type != 0:
            raise SystemExit(f"Unsupported PNG filter {filter_type}")
    rows.append(row)
    prev = row

opaque_pixels = 0
transparent_pixels = 0
for row in rows:
    for i in range(0, stride, channels):
        if color_type == 4:
            gray, alpha = row[i], row[i + 1]
            rgb = (gray, gray, gray)
        else:
            rgb = (row[i], row[i + 1], row[i + 2])
            alpha = row[i + 3]
        if alpha:
            opaque_pixels += 1
            if rgb != (0, 0, 0):
                raise SystemExit(f"{path} contains non-black visible pixels: {rgb}")
        else:
            transparent_pixels += 1

if opaque_pixels == 0 or transparent_pixels == 0:
    raise SystemExit(f"{path} must contain both visible black pixels and transparency")
PY

echo "Generated Logo2 assets:"
find . -maxdepth 2 -path './.generate-tmp.*' -prune -o -type f -print | sort | sed 's#^\./##'
