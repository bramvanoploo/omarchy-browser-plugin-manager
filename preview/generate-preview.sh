#!/usr/bin/env bash
set -euo pipefail

# Render preview.png (1920x1080) from template.html + captured assets.
# Assets: wizard_install.png, wizard_disable.png (wizard overlay cards,
# cropped from full-screen grim captures by crop-wizard.py),
# buttons_install.png, buttons_disable.png, catalog_icons.png
# (marketplace page screenshots from ~/Pictures/screenshots).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_FILE="$PROJECT_DIR/preview.png"
MANIFEST_FILE="$PROJECT_DIR/manifest.json"

if [[ ! -f "$MANIFEST_FILE" ]]; then
  echo "Error: manifest.json not found at $MANIFEST_FILE" >&2
  exit 1
fi

VERSION=$(python3 -c "import json; print(json.load(open('$MANIFEST_FILE'))['version'])" 2>/dev/null || echo "0.0.0")
echo "==> Preparing preview banner for Browser Plugin Manager v$VERSION..."

for asset in wizard_install.png wizard_disable.png buttons_install.png buttons_disable.png catalog_icons.png; do
  if [[ ! -f "$SCRIPT_DIR/$asset" ]]; then
    echo "Error: required asset $asset missing in $SCRIPT_DIR (see README.md to re-capture)" >&2
    exit 1
  fi
done

RENDER_HTML="$SCRIPT_DIR/index.rendered.html"
sed "s/{{VERSION}}/$VERSION/g" "$SCRIPT_DIR/template.html" > "$RENDER_HTML"

echo "==> Rendering 1920x1080 preview banner via Chromium headless..."
chromium \
  --headless=new \
  --no-sandbox \
  --disable-gpu \
  --hide-scrollbars \
  --force-device-scale-factor=1 \
  --window-size=1920,1080 \
  --screenshot="$OUTPUT_FILE" \
  "file://$RENDER_HTML" 2>/dev/null

rm -f "$RENDER_HTML"

if command -v identify >/dev/null 2>&1; then
  identify "$OUTPUT_FILE"
fi

echo "==> Successfully created $OUTPUT_FILE for v$VERSION!"
