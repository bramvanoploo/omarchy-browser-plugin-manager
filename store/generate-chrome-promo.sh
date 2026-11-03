#!/usr/bin/env bash
# Regenerates the Chrome Web Store promo tiles from the store logo.
#
#   ./store/generate-chrome-promo.sh
#
# Outputs (exact CWS submission sizes):
#   chrome-web-store-marquee-1400x560.png   (marquee image)
#   chrome-web-store-promo-440x280.png      (small promo tile)
#
# The logo is inlined from logo.svg into the promo templates, so the tiles
# always carry the current brand mark; re-run this after any logo change.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGO_FILE="$SCRIPT_DIR/logo.svg"

for f in "$LOGO_FILE" "$SCRIPT_DIR/promo-marquee.html" "$SCRIPT_DIR/promo-small.html"; do
  if [[ ! -f "$f" ]]; then
    echo "Error: required input $f missing" >&2
    exit 1
  fi
done

CHROMIUM_BIN="$(command -v chromium || command -v google-chrome || command -v brave || true)"
if [[ -z "$CHROMIUM_BIN" ]]; then
  echo "Error: chromium, google-chrome, or brave not found on PATH" >&2
  exit 1
fi

render() {  # render <template> <WxH> <output>
  local template="$1" size="$2" out="$3" tmp
  tmp="$(mktemp --suffix=.html)"
  trap 'rm -f "$tmp"' EXIT
  python3 - "$template" "$LOGO_FILE" "$tmp" <<'PY'
import sys
template, logo_file, out = sys.argv[1:4]
html = open(template).read()
logo = open(logo_file).read()
assert "{{LOGO}}" in html, f"no {{{{LOGO}}}} placeholder in {template}"
# count=1: only the .logo slot, never a mention of the token in a comment.
open(out, "w").write(html.replace("{{LOGO}}", logo, 1))
PY
  "$CHROMIUM_BIN" \
    --headless=new \
    --no-sandbox \
    --disable-gpu \
    --hide-scrollbars \
    --force-device-scale-factor=1 \
    --window-size="$size" \
    --screenshot="$out" \
    "file://$tmp" >/dev/null 2>&1
  rm -f "$tmp"
  trap - EXIT
}

echo "==> Rendering store promo tiles via $CHROMIUM_BIN"
render "$SCRIPT_DIR/promo-marquee.html" "1400,560" "$SCRIPT_DIR/chrome-web-store-marquee-1400x560.png"
render "$SCRIPT_DIR/promo-small.html"  "440,280"   "$SCRIPT_DIR/chrome-web-store-promo-440x280.png"

if command -v identify >/dev/null 2>&1; then
  identify -format "%f %wx%h\n" \
    "$SCRIPT_DIR/chrome-web-store-marquee-1400x560.png" \
    "$SCRIPT_DIR/chrome-web-store-promo-440x280.png"
fi
echo "Done: upload the marquee as the store marquee image and the 440x280 tile as the small promo tile."
