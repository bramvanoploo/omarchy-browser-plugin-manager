#!/bin/bash
# Regression harness for bin/plugin-installer-setup's extension-ID
# derivations and manifest registration (the audit gap: a silently wrong
# derived ID makes Chrome refuse connectNative with no error anywhere).
#   - chrome_extension_id: path hash -> hex -> a-p nibble mapping
#   - chrome_key_id: manifest "key" hash, chrome-key.pub fallback, and the
#     CHROME_STORE_ID last resort
#   - end-to-end: manifests land in the XDG Firefox dir (NOT the dead legacy
#     ~/.mozilla one), allowed_origins carry the path-derived ID and the
#     store ID, and --uninstall removes everything again.
#
# Expected values are computed independently (never by calling the same
# helper twice), so a broken mapping or truncation fails the check.
#
# Usage: test/plugin-installer-registration.sh   (exit 0 = all checks pass)
set -u

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="$REPO_ROOT/bin/plugin-installer-setup"
HOST_NAME="bramvanoploo_omarchy_browser_plugin_manager"
[[ -f $SETUP ]] || { echo "setup script not found: $SETUP"; exit 1; }

TESTHOME=$(mktemp -d)
trap 'rm -rf "$TESTHOME"' EXIT
export HOME="$TESTHOME"
unset XDG_CONFIG_HOME XDG_STATE_HOME

FAILURES=0
check() { # check <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    echo "ok   $1"
  else
    echo "FAIL $1: expected [$2] got [$3]"
    FAILURES=$((FAILURES + 1))
  fi
}

# --- helpers extracted from the setup script (it runs main unconditionally,
# so sourcing it is not an option) ------------------------------------------
eval "$(sed -n '/^chrome_extension_id()/,/^}/p;/^chrome_key_id()/,/^}/p' "$SETUP")"
CHROME_STORE_ID=$(sed -n 's/^CHROME_STORE_ID="\([^"]*\)".*/\1/p' "$SETUP")
[[ -n $CHROME_STORE_ID ]] || { echo "FAIL: could not read CHROME_STORE_ID from $SETUP"; exit 1; }

# Independent reference of the documented rule (comment in the script):
# first 32 hex chars of sha256(abs path, newline stripped), nibbles -> a-p.
ref_path_id() { realpath "$1" | tr -d '\n' | sha256sum | cut -c1-32 | tr '0123456789abcdef' 'abcdefghijklmnop'; }
ref_key_id() { printf '%s' "$1" | base64 -d | sha256sum | cut -c1-32 | tr '0123456789abcdef' 'abcdefghijklmnop'; }

EXT="$TESTHOME/ext"
mkdir -p "$EXT"
printf '{"manifest_version":3}\n' >"$EXT/manifest.json"

# --- chrome_extension_id ----------------------------------------------------
check "chrome_extension_id matches independent hash" "$(ref_path_id "$EXT")" "$(chrome_extension_id "$EXT")"
check "chrome_extension_id is 32 a-p chars" 1 "$(chrome_extension_id "$EXT" | grep -cxE '[a-p]{32}')"

# --- chrome_key_id: manifest key, pem fallback, store-id fallback -----------
KEY_PEM="$TESTHOME/key.pem"
openssl ecparam -name prime256v1 -genkey -noout -out "$KEY_PEM" 2>/dev/null
KEY_B64=$(openssl pkey -in "$KEY_PEM" -pubout -outform DER 2>/dev/null | base64 -w0)
[[ -n $KEY_B64 ]] || { echo "FAIL: openssl key generation failed"; exit 1; }
printf '{"key":"%s"}\n' "$KEY_B64" >"$EXT/manifest.json"
check "chrome_key_id hashes the manifest key" "$(ref_key_id "$KEY_B64")" "$(chrome_key_id "$EXT/manifest.json")"

# A repo whose browser/store/chrome-key.pub exists derives the packed-install
# ID from it (the committed public key is enough; no private key involved).
REPO_DIR="$TESTHOME/pub-repo"; mkdir -p "$REPO_DIR/browser/store"
printf '%s\n' "$KEY_B64" >"$REPO_DIR/browser/store/chrome-key.pub"
printf '{"manifest_version":3}\n' >"$EXT/manifest.json"
check "chrome_key_id falls back to the repo public key" "$(ref_key_id "$KEY_B64")" "$(chrome_key_id "$EXT/manifest.json")"

# No manifest key, no chrome-key.pub anywhere -> the store ID is the answer.
REPO_DIR="$TESTHOME/empty-repo"; mkdir -p "$REPO_DIR/browser/store"
printf '{"manifest_version":3}\n' >"$EXT/manifest.json"
check "chrome_key_id falls back to CHROME_STORE_ID" "$CHROME_STORE_ID" "$(chrome_key_id "$EXT/manifest.json")"

# --- end-to-end registration ------------------------------------------------
out=$(HOME="$TESTHOME" bash "$SETUP" --extension-dir "$EXT" 2>&1); rc=$?
[[ $rc -eq 0 ]] && echo "ok   setup exits 0" || { echo "FAIL setup exit $rc: $out"; FAILURES=$((FAILURES + 1)); }

CM="$TESTHOME/.config/google-chrome/NativeMessagingHosts/$HOST_NAME.json"
FM="$TESTHOME/.config/mozilla/native-messaging-hosts/$HOST_NAME.json"
for f in "$CM" "$FM"; do
  [[ -f $f ]] && echo "ok   wrote $(realpath --relative-to="$TESTHOME" "$f")" || { echo "FAIL missing $f"; FAILURES=$((FAILURES + 1)); }
done
# The XDG Firefox dir is required but the dead pre-133 ~/.mozilla location
# must NOT be created (strict_min_version 142 rules out any reader for it).
if [[ -e $TESTHOME/.mozilla ]]; then
  echo "FAIL legacy ~/.mozilla registration still created"; FAILURES=$((FAILURES + 1))
else
  echo "ok   no legacy ~/.mozilla registration"
fi

jq -e --arg id "chrome-extension://$(ref_path_id "$EXT")/" \
  '.path and .type == "stdio" and (.allowed_origins | index($id)) and (.allowed_origins | index("chrome-extension://'"$CHROME_STORE_ID"'/"))' \
  "$CM" >/dev/null 2>&1 \
  && echo "ok   chromium manifest origins (path-derived + store ID)" \
  || { echo "FAIL chromium manifest origins: $(cat "$CM" 2>/dev/null)"; FAILURES=$((FAILURES + 1)); }
jq -e '.allowed_extensions | (index("bramvanoploo.omarchy-browser-plugin-manager@bram.dev")) and (index("omarchy-browser-plugin-manager@sudo-systems.com"))' \
  "$FM" >/dev/null 2>&1 \
  && echo "ok   firefox manifest add-on IDs" \
  || { echo "FAIL firefox manifest: $(cat "$FM" 2>/dev/null)"; FAILURES=$((FAILURES + 1)); }

# --- uninstall removes both manifests ----------------------------------------
HOME="$TESTHOME" bash "$SETUP" --uninstall >/dev/null 2>&1
for f in "$CM" "$FM"; do
  [[ -f $f ]] && { echo "FAIL uninstall left $f"; FAILURES=$((FAILURES + 1)); } || echo "ok   uninstall removed $(realpath --relative-to="$TESTHOME" "$f")"
done

echo "plugin-installer-registration checks: $FAILURES failure(s)"
exit $(( FAILURES > 0 ? 1 : 0 ))
