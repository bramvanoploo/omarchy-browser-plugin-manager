#!/usr/bin/env bash
# Regenerates preview.png for PlugBrug from preview/template.html.
#
#   ./preview/generate-preview.sh
#
# The version pill in the banner is filled from manifest.json ({{VERSION}}).
#
# Sharpness pipeline: the screenshot captures are far larger than the size
# they occupy inside the banner, and Chromium's own downsampling shimmers
# when it reduces them ~3-4x in one step. So the captures are first reduced
# once to about twice their display size with Lanczos plus a light unsharp
# mask, and the whole banner is then rendered at 2x device scale (3840x2160)
# and Lanczos-downscaled to 1920x1080, which keeps the banner's own text
# crisp as well. ImageMagick is required for this; without it the script
# falls back to a plain 1x render of the raw captures.
#
# The generated HTML and the resized assets are assembled in preview/_render/
# (removed again on exit) so template.html always reads the capture sources
# next to it, never the resized copies.
#
# Captured assets must not be named install*, setup* or uninstall*: the
# marketplace security baseline reads complete binaries with those basenames as
# setup programs and refuses to scan them, which blocks submission approval.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_FILE="$PROJECT_DIR/preview.png"
MANIFEST_FILE="$PROJECT_DIR/manifest.json"

if [[ ! -f "$MANIFEST_FILE" ]]; then
  echo "Error: manifest.json not found at $MANIFEST_FILE" >&2
  exit 1
fi

VERSION=$(python3 -c "import json; print(json.load(open('$MANIFEST_FILE'))['version'])" 2>/dev/null \
  || sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MANIFEST_FILE" | head -n1)
if [[ -z "$VERSION" ]]; then
  echo "Error: could not read a version from $MANIFEST_FILE" >&2
  exit 1
fi
echo "==> PlugBrug v$VERSION preview banner"

for asset in catalog_card.png settings_panel.png wizard_confirm.png bg_1920.png; do
  if [[ ! -f "$SCRIPT_DIR/$asset" ]]; then
    echo "Error: required asset $asset missing in $SCRIPT_DIR" >&2
    exit 1
  fi
done

CHROMIUM_BIN="$(command -v chromium || command -v google-chrome || command -v brave || true)"
if [[ -z "$CHROMIUM_BIN" ]]; then
  echo "Error: chromium, google-chrome, or brave not found on PATH" >&2
  exit 1
fi

MAGICK_BIN="$(command -v magick || command -v convert || true)"

WORK_DIR="$SCRIPT_DIR/_render"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/assets"
trap 'rm -rf "$WORK_DIR"' EXIT

sed "s/{{VERSION}}/$VERSION/g" "$SCRIPT_DIR/template.html" > "$WORK_DIR/template.html"
cp "$SCRIPT_DIR/bg_1920.png" "$WORK_DIR/bg_1920.png"

if [[ -n "$MAGICK_BIN" ]]; then
  echo "==> Pre-reducing capture assets ($MAGICK_BIN, Lanczos + unsharp)"
  # settings_panel.png is a 1810px-wide live capture shown ~500px wide.
  "$MAGICK_BIN" "$SCRIPT_DIR/settings_panel.png" \
    -filter lanczos -resize 1000x -unsharp 0x0.7+0.9+0.01 \
    "$WORK_DIR/assets/settings_panel.png"
  # catalog_card.png (736px) and wizard_confirm.png (1344px) display close to
  # native size; only a light sharpen is applied.
  "$MAGICK_BIN" "$SCRIPT_DIR/catalog_card.png" \
    -unsharp 0x0.5+0.5+0.01 \
    "$WORK_DIR/assets/catalog_card.png"
  "$MAGICK_BIN" "$SCRIPT_DIR/wizard_confirm.png" \
    -unsharp 0x0.5+0.5+0.01 \
    "$WORK_DIR/assets/wizard_confirm.png"
  SCALE_FACTOR=2
else
  echo "Warning: ImageMagick not found; rendering raw captures at 1x (softer edges)" >&2
  cp "$SCRIPT_DIR/catalog_card.png" "$SCRIPT_DIR/settings_panel.png" "$SCRIPT_DIR/wizard_confirm.png" \
    "$WORK_DIR/assets/"
  SCALE_FACTOR=1
fi

echo "==> Rendering $OUTPUT_FILE via $CHROMIUM_BIN at ${SCALE_FACTOR}x device scale"
if [[ "$SCALE_FACTOR" == "2" ]]; then
  SHOT_FILE="$WORK_DIR/preview_2x.png"
else
  SHOT_FILE="$OUTPUT_FILE"
fi

"$CHROMIUM_BIN" \
  --headless=new \
  --no-sandbox \
  --disable-gpu \
  --hide-scrollbars \
  --force-device-scale-factor="$SCALE_FACTOR" \
  --window-size=1920,1080 \
  --screenshot="$SHOT_FILE" \
  "file://$WORK_DIR/template.html" >/dev/null 2>&1

if [[ "$SCALE_FACTOR" == "2" ]]; then
  "$MAGICK_BIN" "$SHOT_FILE" -filter lanczos -resize 1920x1080 "$OUTPUT_FILE"
fi

rm -rf "$WORK_DIR"
trap - EXIT

if command -v identify >/dev/null 2>&1; then
  identify "$OUTPUT_FILE"
fi

echo "==> Done: $OUTPUT_FILE"
