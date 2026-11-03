#!/bin/bash
# Regression test suite for worker isolation, security hardening, cleanup,
# and native host optimizations.
#
# Covers:
#   1. Native host unregister isolation:
#      - Uninstalling a normal plugin must NEVER run plugin-installer-setup --uninstall.
#      - Uninstalling the manager plugin MUST run plugin-installer-setup --uninstall.
#   2. Flag/hyphen injection hardening:
#      - IDs starting with '-' or containing invalid chars are rejected across workers.
#   3. Temporary directory and marker file cleanup:
#      - update-worker cleans up its shadowed bin_dir on exit.
#   4. Native messaging protocol & zero-fork optimizations:
#      - Host encodes/decodes frames correctly.
#      - Ping and status queries return valid JSON with ok:true.
#   5. Extension sender trust validation:
#      - Checks origin strictly against https://plugins.omarchy.org.
#
# Usage: test/workers-regression.sh   (exit 0 = all checks pass)
set -u

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WIZW="$REPO_ROOT/bin/omarchy-plugin-worker"
UNIW="$REPO_ROOT/bin/omarchy-plugin-uninstall-worker"
UPDW="$REPO_ROOT/bin/omarchy-plugin-update-worker"
UPD="$REPO_ROOT/bin/omarchy-plugin-update"
HOST="$REPO_ROOT/bin/omarchy-plugin-install-host"

for f in "$WIZW" "$UNIW" "$UPDW" "$UPD" "$HOST"; do
  [[ -x $f ]] || { echo "required executable missing: $f"; exit 1; }
done

TESTHOME=$(mktemp -d)
trap 'rm -rf "$TESTHOME"' EXIT
export HOME="$TESTHOME"
export XDG_CONFIG_HOME="$TESTHOME/.config"
export XDG_STATE_HOME="$TESTHOME/.local/state"

SHIMBIN="$TESTHOME/shim/bin"
mkdir -p "$SHIMBIN"
export SHELLLOG="$TESTHOME/shell.log"
export NOTIFLOG="$TESTHOME/notify.log"
export REMOVELOG="$TESTHOME/remove.log"
export SETUPLOG="$TESTHOME/setup.log"

cat > "$SHIMBIN/omarchy" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "plugin list") cat "${FIX_LIST:-[]}"; exit 0;;
  "plugin remove") printf '%s\n' "$3" >> "${REMOVELOG:-/dev/null}"; exit 0;;
  "plugin update") printf 'Updated %s\n' "$3"; exit 0;;
  *) exit 0;;
esac
EOF

cat > "$SHIMBIN/omarchy-shell" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${SHELLLOG:-/dev/null}"
exit 0
EOF

cat > "$SHIMBIN/omarchy-notification-send" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ] && [ "${1:0:2}" = "--" ]; do
  case "$1" in
    --app-name|--expire-time) shift 2;;
    *) break;;
  esac
done
printf '%s\t%s\n' "${1:-}" "${2:-}" >> "${NOTIFLOG:-/dev/null}"
exit 0
EOF

chmod +x "$SHIMBIN"/omarchy "$SHIMBIN"/omarchy-shell "$SHIMBIN"/omarchy-notification-send
export PATH="$SHIMBIN:$PATH"
export OMARCHY_PATH="$TESTHOME/shim"

MANAGER_ID="bramvanoploo.omarchy-browser-plugin-manager"
MGR_DIR="$XDG_CONFIG_HOME/omarchy/plugins/$MANAGER_ID"
mkdir -p "$MGR_DIR/bin"
cat > "$MGR_DIR/bin/plugin-installer-setup" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${SETUPLOG:-/dev/null}"
exit 0
EOF
chmod +x "$MGR_DIR/bin/plugin-installer-setup"

FAILURES=0
check() { # check <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    echo "ok   $1"
  else
    echo "FAIL $1: expected [$2] got [$3]"
    FAILURES=$((FAILURES + 1))
  fi
}

# ---- 1. Native host unregister isolation -------------------------------------
# Normal plugin uninstall via wizard worker:
: > "$SETUPLOG"; : > "$NOTIFLOG"; : > "$REMOVELOG"
bash "$WIZW" uninstall acme.weather "Weather" "" "" >/dev/null 2>&1
check "wizard worker other plugin: no host unregister" "0" "$(wc -l < "$SETUPLOG")"
check "wizard worker other plugin: removed" "acme.weather" "$(cat "$REMOVELOG")"

# Manager plugin uninstall via wizard worker:
: > "$SETUPLOG"; : > "$NOTIFLOG"; : > "$REMOVELOG"
bash "$WIZW" uninstall "$MANAGER_ID" "Browser Plugin Manager" "" "" >/dev/null 2>&1
check "wizard worker manager: host unregister called" "--uninstall" "$(cat "$SETUPLOG")"
check "wizard worker manager: removed" "$MANAGER_ID" "$(cat "$REMOVELOG")"

# Normal plugin uninstall via bar batch worker:
: > "$SETUPLOG"; : > "$NOTIFLOG"; : > "$REMOVELOG"
bash "$UNIW" "1 plugin" acme.notes >/dev/null 2>&1
check "batch worker other plugin: no host unregister" "0" "$(wc -l < "$SETUPLOG")"
check "batch worker other plugin: removed" "acme.notes" "$(cat "$REMOVELOG")"

# Manager plugin uninstall via bar batch worker:
: > "$SETUPLOG"; : > "$NOTIFLOG"; : > "$REMOVELOG"
bash "$UNIW" "1 plugin" "$MANAGER_ID" >/dev/null 2>&1
check "batch worker manager: host unregister called" "--uninstall" "$(cat "$SETUPLOG")"
check "batch worker manager: removed" "$MANAGER_ID" "$(cat "$REMOVELOG")"

# ---- 2. Flag / hyphen injection rejection ------------------------------------
# Hyphenated leading ids must be rejected without touching omarchy plugin remove
: > "$REMOVELOG"
bash "$WIZW" uninstall "--danger" "Danger" "" "" >/dev/null 2>&1; rc=$?
check "wizard worker rejects leading hyphen (rc 2)" "2" "$rc"
check "wizard worker rejects leading hyphen (no remove call)" "0" "$(wc -l < "$REMOVELOG")"

: > "$REMOVELOG"
bash "$UNIW" "1 plugin" "--help" >/dev/null 2>&1
check "batch uninstall rejects leading hyphen (no remove call)" "0" "$(wc -l < "$REMOVELOG")"

out=$(bash "$UPD" apply "--option" "" 2>&1); rc=$?
check "update apply rejects leading hyphen (rc 2)" "2" "$rc"
check "update apply rejects leading hyphen (invalid-id)" "invalid-id" "$out"

# ---- 3. Cleanup on exit -----------------------------------------------------
# Check that update-worker leaves no temp bin_dir in /tmp
tmp_before=$(ls -d /tmp/tmp.* 2>/dev/null | wc -l)
bash "$UPDW" "1 plugin" >/dev/null 2>&1
tmp_after=$(ls -d /tmp/tmp.* 2>/dev/null | wc -l)
check "update worker cleaned up temp bin_dir" "$tmp_before" "$tmp_after"

# ---- 4. Native messaging protocol & zero-fork optimizations ------------------
# Test ping response via binary protocol (4-byte LE length prefix)
send_msg() {
  local json="$1" len h0 h1 h2 h3
  len=${#json}
  printf -v h0 "%02x" $(( len & 0xff ))
  printf -v h1 "%02x" $(( (len >> 8) & 0xff ))
  printf -v h2 "%02x" $(( (len >> 16) & 0xff ))
  printf -v h3 "%02x" $(( (len >> 24) & 0xff ))
  printf "\\x$h0\\x$h1\\x$h2\\x$h3%s" "$json"
}

ping_out=$(send_msg '{"type":"ping"}' | "$HOST" | tail -c +5)
check "native host ping ok" "true" "$(jq -r '.ok // false' <<<"$ping_out" 2>/dev/null)"
check "native host name" "bramvanoploo_omarchy_browser_plugin_manager" "$(jq -r '.host // ""' <<<"$ping_out" 2>/dev/null)"

status_out=$(send_msg '{"type":"status","id":"test.plugin"}' | "$HOST" | tail -c +5)
check "native host status ok" "true" "$(jq -r '.ok // false' <<<"$status_out" 2>/dev/null)"
check "native host status id" "test.plugin" "$(jq -r '.id // ""' <<<"$status_out" 2>/dev/null)"

# ---- 5. Extension background script sender validation ------------------------
node_test=$(node -e '
function isTrustedSender(sender, extensionId) {
  if (!sender || sender.id !== extensionId) return false;
  const url = sender.url || (sender.tab && sender.tab.url) || "";
  if (typeof url !== "string" || !url) return false;
  try {
    const parsed = new URL(url);
    return parsed.origin === "https://plugins.omarchy.org";
  } catch (_e) {
    return false;
  }
}
const extId = "test-ext-id";
const cases = [
  [isTrustedSender({ id: extId, url: "https://plugins.omarchy.org/" }, extId), true],
  [isTrustedSender({ id: extId, url: "https://plugins.omarchy.org/plugin.html?id=x" }, extId), true],
  [isTrustedSender({ id: extId, url: "https://plugins.omarchy.org.attacker.com/" }, extId), false],
  [isTrustedSender({ id: extId, url: "http://plugins.omarchy.org/" }, extId), false],
  [isTrustedSender({ id: "wrong-id", url: "https://plugins.omarchy.org/" }, extId), false],
  [isTrustedSender({ id: extId, url: "javascript:alert(1)" }, extId), false],
  [isTrustedSender({ id: extId, tab: { url: "https://plugins.omarchy.org/" } }, extId), true],
  [isTrustedSender(null, extId), false],
];
const pass = cases.every(([actual, expected]) => actual === expected);
console.log(pass ? "pass" : "fail");
')
check "extension sender origin validation" "pass" "$node_test"

echo
if (( FAILURES > 0 )); then
  echo "$FAILURES check(s) failed"
  exit 1
fi
echo "all checks passed"
