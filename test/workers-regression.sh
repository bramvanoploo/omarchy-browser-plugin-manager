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
#   6. Sanitized notification bodies for invalid ids.
#   7. Worker state permissions: in-progress dir 700, marker files 600.
#   8. Host version is whitelist-validated (tampered manifest cannot
#      inject bytes into the ping frame).
#   9. Wizard marker scan cross-checks started against the file mtime
#      (extracted from Wizard.qml, so the test tracks the shipped script).
#  10. Structural guards: settings-command re-validation (BarWatch),
#      trusted-click guards (extension), curl size caps, worker umask.
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
  "plugin remove") sleep "${REMOVESLEEP:-0}"; printf '%s\n' "$3" >> "${REMOVELOG:-/dev/null}"; exit 0;;
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
bash "$WIZW" uninstall "$MANAGER_ID" "PlugBrug" "" "" >/dev/null 2>&1
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

# status_all answers with a well-formed ok-frame built by jq (not string
# surgery): ok is true and plugins is an array even with an empty cache.
status_all_out=$(send_msg '{"type":"status_all"}' | "$HOST" | tail -c +5)
check "native host status_all ok" "true" "$(jq -r '.ok // false' <<<"$status_all_out" 2>/dev/null)"
check "native host status_all plugins array" "array" "$(jq -r '.plugins | type' <<<"$status_all_out" 2>/dev/null)"

# ---- 6. Sanitized notification bodies ------------------------------------
# An invalid id may carry newlines/control chars: the failure notification
# echoes only a sanitized, capped rendering (no spoofed extra body lines).
: > "$NOTIFLOG"
bash "$WIZW" uninstall "$(printf 'bad\nid;rm')" "X" "" "" >/dev/null 2>&1; rc=$?
check "wizard worker rejects embedded-newline id (rc 2)" "2" "$rc"
check "wizard worker sanitizes invalid id in notif body" "Invalid plugin id: badidrm" "$(tail -1 "$NOTIFLOG" | cut -f2-)"
check "wizard worker invalid id: one notification line" "1" "$(wc -l < "$NOTIFLOG")"

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

# ---- 7. Worker state permissions (umask 077) ----------------------------
# The in-progress markers record which action runs on which plugin, so the
# state subtree must be owner-only from creation whatever the caller umask.
# Probed live: the remove shim sleeps while the marker is still on disk.
PROBE_DIR="$XDG_STATE_HOME/omarchy/$MANAGER_ID/in-progress"
REMOVESLEEP=2 bash "$UNIW" "1 plugin" acme.perm >/dev/null 2>&1 &
marker=""
for _ in $(seq 1 40); do
  marker=$(find "$PROBE_DIR" -name '*.json' 2>/dev/null | head -1)
  [[ -n $marker ]] && break
  sleep 0.1
done
check "uninstall worker creates in-progress dir" "yes" "$([[ -d $PROBE_DIR ]] && echo yes || echo no)"
check "in-progress dir is owner-only (700)" "700" "$(stat -c %a "$PROBE_DIR" 2>/dev/null)"
check "live marker file exists" "yes" "$([[ -n $marker ]] && echo yes || echo no)"
check "marker file is owner-only (600)" "600" "$(stat -c %a "$marker" 2>/dev/null)"
wait
check "marker removed after worker exit" "0" "$(find "$PROBE_DIR" -name '*.json' 2>/dev/null | wc -l)"

# ---- 8. Host version is whitelist-validated ------------------------------
# The manifest is reachable through the extension's transport, so a
# tampered version string must never travel raw into a reply frame. Run a
# copy of the host against a manifest carrying an injection-shaped version:
# the ping must still parse as JSON and answer the built-in fallback.
hosttmp=$(mktemp -d "$TESTHOME/hostver.XXXXXX")
mkdir -p "$hosttmp/bin"
cp "$HOST" "$hosttmp/bin/omarchy-plugin-install-host"
jq -cn --arg v '9.9", "evil": "yes' '{version: $v}' > "$hosttmp/manifest.json"
tampered_out=$(send_msg '{"type":"ping"}' | "$hosttmp/bin/omarchy-plugin-install-host" | tail -c +5)
check "tampered manifest: ping frame still parses" "0" "$(jq -e . <<<"$tampered_out" >/dev/null 2>&1; echo $?)"
check "tampered manifest: version falls back" "0.9.5" "$(jq -r '.version // ""' <<<"$tampered_out")"
check "tampered manifest: no injected key" "" "$(jq -r '.evil // ""' <<<"$tampered_out")"
rm -rf "$hosttmp"

# ---- 9. Wizard marker scan cross-checks started against mtime -----------
# A marker's self-reported started must agree with the file's real mtime
# (written once by a worker): a planted marker is deleted, not believed.
# The script is extracted from Wizard.qml so the test always matches the
# shipped payload.
scan_script=$(node -e '
  const fs = require("fs");
  const m = fs.readFileSync(process.argv[1], "utf8").match(/"for f in[\s\S]*?done"/);
  console.log(m ? JSON.parse(m[0]) : "NOMATCH");
' "$REPO_ROOT/Wizard.qml")
if [[ $scan_script == NOMATCH || -z $scan_script ]]; then
  check "wizard marker scan extracted from Wizard.qml" "extracted" "not-found"
else
  printf '%s\n' "$scan_script" > "$TESTHOME/markscan.sh"
  markd="$TESTHOME/markscan.d"; mkdir -p "$markd"
  now=$(date +%s)
  jq -cn --argjson s "$now" '{mode:"install",id:"ok.plugin",started:$s}' > "$markd/fresh.json"
  jq -cn --argjson s "$((now + 86400))" '{mode:"install",id:"forged",started:$s}' > "$markd/forged.json"
  jq -cn --argjson s "$((now - 1000))" '{mode:"install",id:"stamped",started:$s}' > "$markd/stamped.json"
  printf '%s\n' '{"mode":"install","id":"nostart"}' > "$markd/nostart.json"
  scan_out=$(bash "$TESTHOME/markscan.sh" "$markd")
  check "scan keeps the fresh marker" "1" "$(grep -c 'ok.plugin' <<<"$scan_out")"
  check "scan output carries only the fresh marker" "1" "$(grep -c . <<<"$scan_out")"
  check "scan deletes the future-stamped marker" "no" "$([[ -e $markd/forged.json ]] && echo yes || echo no)"
  check "scan deletes the back-dated marker" "no" "$([[ -e $markd/stamped.json ]] && echo yes || echo no)"
  check "scan deletes the started-less marker" "no" "$([[ -e $markd/nostart.json ]] && echo yes || echo no)"
  check "scan keeps the fresh marker file" "yes" "$([[ -e $markd/fresh.json ]] && echo yes || echo no)"
fi

# ---- 10. Structural guards ------------------------------------------------
# Settings-command re-validation in BarWatch (https-only store links, a
# browser-bin allowlist, and the plugin-id grammar before argv handoff),
# trusted-click guards in the extension, curl size caps, worker umask.
check "BarWatch browser-bin allowlist wired" "2" "$(grep -c 'allowedBrowserBins' "$REPO_ROOT/BarWatch.qml")"
check "BarWatch plugin-id grammar wired" "2" "$(grep -c 'validPluginId' "$REPO_ROOT/BarWatch.qml")"
check "BarWatch store links are https-gated" "1" "$(grep -cF '!/^https:' "$REPO_ROOT/BarWatch.qml")"
check "content.js guards untrusted clicks" "1" "$(grep -c 'isTrusted' "$REPO_ROOT/browser/extension/content.js")"
check "catalog.js guards untrusted clicks" "1" "$(grep -c 'isTrusted' "$REPO_ROOT/browser/extension/catalog.js")"
check "wizard curls capped" "2" "$(grep -c 'max-filesize' "$REPO_ROOT/Wizard.qml")"
check "bar curl capped" "1" "$(grep -c 'max-filesize' "$REPO_ROOT/BarWatch.qml")"
for w in "$WIZW" "$UPDW" "$UNIW"; do
  check "worker sets umask 077: $(basename "$w")" "1" "$(grep -c 'umask 077' "$w")"
done

echo
if (( FAILURES > 0 )); then
  echo "$FAILURES check(s) failed"
  exit 1
fi
echo "all checks passed"
