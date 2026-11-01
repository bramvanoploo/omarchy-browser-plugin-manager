#!/usr/bin/env bash
# Regenerates preview.png for Browser Plugin Manager from preview/template.html.
#
#   ./preview/generate-preview.sh
#
# The version pill in the banner is filled from manifest.json ({{VERSION}}).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_FILE="$PROJECT_DIR/preview.png"
MANIFEST_FILE="$PROJECT_DIR/manifest.json"

if [[ ! -f "$MANIFEST_FILE" ]]; then
  echo "Error: manifest.json not found at $MANIFEST_FILE" >&2
  exit 1
fi

VERSION=$(python3 -c "import json; print(json.load(open('$MANIFEST_FILE'))['version'])" 2>/dev/null || echo "0.8.2")
echo "==> Browser Plugin Manager v$VERSION preview banner"

for asset in catalog_card.png install_wizard.png settings_panel.png; do
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

echo "==> Rendering $OUTPUT_FILE via $CHROMIUM_BIN"
TMP_HTML="$SCRIPT_DIR/_render.html"
sed "s/{{VERSION}}/$VERSION/g" "$SCRIPT_DIR/template.html" > "$TMP_HTML"

"$CHROMIUM_BIN" \
  --headless=new \
  --no-sandbox \
  --disable-gpu \
  --hide-scrollbars \
  --force-device-scale-factor=1 \
  --window-size=1920,1080 \
  --screenshot="$OUTPUT_FILE" \
  "file://$TMP_HTML" >/dev/null 2>&1

rm -f "$TMP_HTML"

if command -v identify >/dev/null 2>&1; then
  identify "$OUTPUT_FILE"
fi

echo "==> Done: $OUTPUT_FILE"
