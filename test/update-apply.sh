#!/bin/bash
# Fixture harness for the mutating workers that change plugin state:
#   bin/omarchy-plugin-update apply    — the shared pinned, fail-closed update
#   bin/omarchy-plugin-update-worker   — bar widget batch update
#   bin/omarchy-plugin-uninstall-worker — bar widget removal
#   bin/omarchy-plugin-worker          — wizard install/update/uninstall
#
# What is verified:
#   - pinned apply: fast-forwards to exactly the reviewed sha; leaves the
#     clone untouched when upstream advanced past the pin; rolls back to
#     ORIG_HEAD when validation fails; refuses malformed pins/ids (exit 2,
#     never falls through to the unverified CLI path)
#   - empty pin = explicit unverified opt-in: the plain CLI runs, and its
#     output decides cli-uptodate vs cli-updated vs cli-failed
#   - the batch worker's PATH shadow swallows each CLI call's rescanPlugins
#     and fires exactly one real rescan per batch; in-progress markers are
#     created and cleaned up; notification summaries list failures
#   - the uninstall worker mirrors the CLI's id validation and notifies
#   - the wizard worker maps apply's status words to its notifications and
#     its install mode lands through the enable/retry loop
#
# omarchy / omarchy-shell / omarchy-notification-send / curl are PATH shims
# logging their invocations; the git work is real, under a sandbox HOME.
#
# Usage: test/update-apply.sh   (exit 0 = all checks pass)
set -u

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
UPD="$REPO_ROOT/bin/omarchy-plugin-update"
UPDW="$REPO_ROOT/bin/omarchy-plugin-update-worker"
UNIW="$REPO_ROOT/bin/omarchy-plugin-uninstall-worker"
WIZW="$REPO_ROOT/bin/omarchy-plugin-worker"
for f in "$UPD" "$UPDW" "$UNIW" "$WIZW"; do
  [[ -x $f ]] || { echo "worker missing or not executable: $f"; exit 1; }
done

TESTHOME=$(mktemp -d)
trap 'rm -rf "$TESTHOME"' EXIT
export HOME="$TESTHOME"
export XDG_CONFIG_HOME="$TESTHOME/.config"
export XDG_STATE_HOME="$TESTHOME/.local/state"
export GIT_AUTHOR_NAME=tester GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=tester GIT_COMMITTER_EMAIL=t@example.com
PLUG="$XDG_CONFIG_HOME/omarchy/plugins"
mkdir -p "$PLUG"

# ---- shims ---------------------------------------------------------------
# FIX_* env vars steer the shims per invocation. omarchy-shell and
# omarchy-notification-send log every call to $SHELLLOG / $NOTIFLOG.
SHIMBIN="$TESTHOME/shim/bin"
mkdir -p "$SHIMBIN"
export SHELLLOG="$TESTHOME/shell.log"
export NOTIFLOG="$TESTHOME/notify.log"
export removelog="$TESTHOME/remove.log"
cat > "$SHIMBIN/omarchy" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "plugin list") cat "${FIX_LIST:-[]}"; exit 0;;
  "plugin validate") [ -n "${FIX_VALIDATE_FAIL:-}" ] && exit 1; exit 0;;
  "plugin update")
    # real CLIs end with "omarchy-shell shell rescanPlugins"; reproduce it so
    # the batch worker's PATH shadow can be observed swallowing it:
    printf '%s\n' "${FIX_UPDATE_OUT:-Updated $3}"
    omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
    exit "${FIX_UPDATE_RC:-0}";;
  "plugin add")
    id="${FIX_ADD_ID:-from-repo.plugin}"
    mkdir -p "$XDG_CONFIG_HOME/omarchy/plugins/$id"
    printf '{"id":"%s","name":"From Repo","version":"0.1.0"}' "$id" \
      > "$XDG_CONFIG_HOME/omarchy/plugins/$id/manifest.json"
    exit 0;;
  "plugin remove") printf '%s\n' "$3" >> "${removelog:-/dev/null}"; exit "${FIX_REMOVE_RC:-0}";;
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
# args: --app-name NAME --expire-time MS TITLE BODY
while [ $# -gt 0 ] && [ "${1:0:2}" = "--" ]; do
  case "$1" in
    --app-name|--expire-time) shift 2;;
    *) break;;
  esac
done
printf '%s\t%s\n' "${1:-}" "${2:-}" >> "${NOTIFLOG:-/dev/null}"
exit 0
EOF
cat > "$SHIMBIN/curl" <<'EOF'
#!/bin/bash
[ -n "${FIX_CATALOG_FAIL:-}" ] && exit 22
cat "${FIX_CATALOG:-/dev/null}"
EOF
chmod +x "$SHIMBIN"/omarchy "$SHIMBIN"/omarchy-shell "$SHIMBIN"/omarchy-notification-send "$SHIMBIN"/curl
export PATH="$SHIMBIN:$PATH"
# The workers prefer $OMARCHY_PATH/bin over PATH for omarchy-shell and
# omarchy-notification-send; on a real Omarchy box that would hit the real
# binaries (summoning the live shell!), so point it at the shim bin here.
export OMARCHY_PATH="$TESTHOME/shim"

FAILURES=0
check() { # check <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    echo "ok   $1"
  else
    echo "FAIL $1: expected [$2] got [$3]"
    FAILURES=$((FAILURES + 1))
  fi
}

# mk_clone <id> -> echoes "A_sha B_sha"; clone at A, origin tip B (descendant).
mk_clone() {
  local id="$1"
  local d="$TESTHOME/origin-$id.git" w="$TESTHOME/work-$id"
  git init -q --bare -b main "$d"
  git init -q -b main "$w"
  printf 'base\n' > "$w/README.md"
  git -C "$w" add README.md >/dev/null
  git -C "$w" commit -q -m "base for $id"
  git -C "$w" remote add origin "$d"
  git -C "$w" push -q origin main
  local a; a=$(git -C "$w" rev-parse HEAD)
  git clone -q "$d" "$PLUG/$id"
  git -C "$w" commit -q --allow-empty -m "advance $id"
  git -C "$w" push -q origin main
  local b; b=$(git -C "$w" rev-parse HEAD)
  printf '%s %s' "$a" "$b"
}

# ---- apply: pinned success -----------------------------------------------
read -r A1 B1 < <(mk_clone pinned.plugin)
out=$(bash "$UPD" apply pinned.plugin "$B1" 2>&1); rc=$?
check "apply pinned: exit 0" "0" "$rc"
check "apply pinned: status word" "pinned" "$out"
check "apply pinned: clone at the pin" "$B1" "$(git -C "$PLUG/pinned.plugin" rev-parse HEAD)"

# ---- apply: upstream advanced past the pin (fail closed) ------------------
read -r A2 B2 < <(mk_clone adv.plugin)
# pin is the OLD commit A2 while origin's tip is B2:
out=$(bash "$UPD" apply adv.plugin "$A2" 2>&1); rc=$?
check "apply advanced: exit 1" "1" "$rc"
check "apply advanced: status word" "upstream-advanced" "$out"
check "apply advanced: clone untouched" "$A2" "$(git -C "$PLUG/adv.plugin" rev-parse HEAD)"

# ---- apply: validation failure rolls back --------------------------------
read -r A3 B3 < <(mk_clone valfail.plugin)
out=$(FIX_VALIDATE_FAIL=1 bash "$UPD" apply valfail.plugin "$B3" 2>&1); rc=$?
check "apply validate-fail: exit 1" "1" "$rc"
check "apply validate-fail: status word" "validate-failed" "$out"
check "apply validate-fail: rolled back to ORIG_HEAD" "$A3" "$(git -C "$PLUG/valfail.plugin" rev-parse HEAD)"

# ---- apply: malformed pin / id never reach the CLI -----------------------
out=$(bash "$UPD" apply pinned.plugin "deadbeef" 2>&1); rc=$?
check "apply short sha: exit 2" "2" "$rc"
check "apply short sha: status word" "invalid-sha" "$out"
out=$(bash "$UPD" apply "Bad/../Id" "$B1" 2>&1); rc=$?
check "apply bad id: exit 2" "2" "$rc"
check "apply bad id: status word" "invalid-id" "$out"
out=$(bash "$UPD" apply nothere.plugin "$B1" 2>&1); rc=$?
check "apply missing clone: exit 1" "1" "$rc"
check "apply missing clone: status word" "not-git" "$out"

# ---- apply: empty pin = unverified CLI opt-in ----------------------------
out=$(FIX_UPDATE_OUT="Already up to date." bash "$UPD" apply pinned.plugin "" 2>&1); rc=$?
check "apply cli up-to-date: exit 0" "0" "$rc"
check "apply cli up-to-date: status word" "cli-uptodate" "$out"
out=$(FIX_UPDATE_OUT="Updated pinned.plugin" bash "$UPD" apply pinned.plugin "" 2>&1); rc=$?
check "apply cli updated: exit 0" "0" "$rc"
check "apply cli updated: status word" "cli-updated" "$out"
out=$(FIX_UPDATE_RC=3 FIX_UPDATE_OUT="plugin not found" bash "$UPD" apply pinned.plugin "" 2>&1); rc=$?
check "apply cli failed: exit 1" "1" "$rc"
check "apply cli failed: status + raw output" "cli-failed
plugin not found" "$out"

# ---- apply: symlinked plugin dirs are never followed ----------------------
# A dev clone linked into the plugins folder must not be updated through
# the link (pinned path nor the unverified CLI path), matching cmd_check's
# symlink skip.
git clone -q "$TESTHOME/origin-pinned.plugin.git" "$TESTHOME/devlink-target" 2>/dev/null
ln -s "$TESTHOME/devlink-target" "$PLUG/link.plugin"
out=$(bash "$UPD" apply link.plugin "$B1" 2>&1); rc=$?
check "apply symlink pinned: exit 1" "1" "$rc"
check "apply symlink pinned: status word" "not-git" "$out"
: > "$TESTHOME/shell.log"
out=$(FIX_UPDATE_OUT="Updated link.plugin" bash "$UPD" apply link.plugin "" 2>&1); rc=$?
check "apply symlink unverified: exit 1 (CLI never reached)" "1" "$rc"
check "apply symlink unverified: status word" "not-git" "$out"
rm -f "$PLUG/link.plugin"; rm -rf "$TESTHOME/devlink-target"

# ---- update worker: mixed batch, one rescan, marker cleanup --------------
read -r A4 B4 < <(mk_clone batchok.plugin)
: > "$SHELLLOG"; : > "$NOTIFLOG"
rm -rf "$XDG_STATE_HOME"
bash "$UPDW" "2 plugins" "batchok.plugin:$B4" "adv.plugin:$A2" >/dev/null 2>&1
check "worker notif title" "Plugin updates finished" "$(head -1 "$NOTIFLOG" | cut -f1)"
check "worker notif body lists the pin violation" \
  "1 updated, 1 failed: adv.plugin (upstream advanced past the verified commit)" \
  "$(head -1 "$NOTIFLOG" | cut -f2-)"
check "worker rescan swallowed to exactly one per batch" "1" "$(grep -c 'shell rescanPlugins' "$SHELLLOG")"
check "worker marker cleaned up on exit" "0" "$(find "$XDG_STATE_HOME/omarchy/bramvanoploo.omarchy-browser-plugin-manager/in-progress" -type f | wc -l)"
check "worker summoned the wizard running stage" "1" "$(grep -c 'shell summon bramvanoploo' "$SHELLLOG")"
check "worker batchok clone landed on the pin" "$B4" "$(git -C "$PLUG/batchok.plugin" rev-parse HEAD)"

# ---- update worker: all-unverified batch (empty sha -> CLI) --------------
: > "$SHELLLOG"; : > "$NOTIFLOG"
FIX_UPDATE_OUT="Already up to date." bash "$UPDW" "1 plugins" "pinned.plugin:" >/dev/null 2>&1
check "worker unverified: CLI path title" "Plugins updated" "$(head -1 "$NOTIFLOG" | cut -f1)"
check "worker unverified: CLI rescan swallowed to one" "1" "$(grep -c 'shell rescanPlugins' "$SHELLLOG")"

# ---- update worker: malformed pin fails closed (never hits CLI) ----------
: > "$SHELLLOG"; : > "$NOTIFLOG"
bash "$UPDW" "x" "batchok.plugin:deadbeef" >/dev/null 2>&1
check "worker malformed pin: counted as failed" "0 updated, 1 failed: batchok.plugin" "$(head -1 "$NOTIFLOG" | cut -f2-)"
check "worker malformed pin: no CLI update call" "0" "$(grep -c 'shell rescanPlugins' "$SHELLLOG")"

# ---- uninstall worker -----------------------------------------------------
: > "$SHELLLOG"; : > "$NOTIFLOG"; : > "$TESTHOME/remove.log"
bash "$UNIW" "2 plugins" batchok.plugin "bad id" >/dev/null 2>&1
check "uninstall notif title" "Plugin removals finished" "$(head -1 "$NOTIFLOG" | cut -f1)"
# The worker blanks ids that fail the CLI's id pattern before recording the
# failure (faithful to the original inline worker), so the invalid spec
# shows up as a blank entry: "1 failed:" + " " + empty id.
check "uninstall notif body" "1 removed, 1 failed: " "$(head -1 "$NOTIFLOG" | cut -f2-)"
check "uninstall only removed the valid id" "batchok.plugin" "$(cat "$TESTHOME/remove.log")"
check "uninstall fired exactly one rescan" "1" "$(grep -c 'shell rescanPlugins' "$SHELLLOG")"
check "uninstall summoned running stage" "1" "$(grep -c 'shell summon bramvanoploo' "$SHELLLOG")"

# ---- wizard worker: update modes ------------------------------------------
read -r A5 B5 < <(mk_clone wiz.plugin)
: > "$NOTIFLOG"
bash "$WIZW" update wiz.plugin "Wiz Plugin" "https://example.invalid/wiz" "$B5" >/dev/null 2>&1
check "wizard pinned update: title" "Plugin updated" "$(head -1 "$NOTIFLOG" | cut -f1)"
check "wizard pinned update: names the commit" \
  "Wiz Plugin is updated to verified commit $(printf %s "$B5" | cut -c1-7)." \
  "$(head -1 "$NOTIFLOG" | cut -f2-)"
: > "$NOTIFLOG"
bash "$WIZW" update wiz.plugin "Wiz Plugin" "https://example.invalid/wiz" "$A5" >/dev/null 2>&1
check "wizard advanced-past-pin: title" "Update unavailable" "$(head -1 "$NOTIFLOG" | cut -f1)"
check "wizard advanced-past-pin: untouched wording" \
  "Wiz Plugin: upstream advanced past the verified commit; the plugin was left untouched." \
  "$(head -1 "$NOTIFLOG" | cut -f2-)"
: > "$NOTIFLOG"
bash "$WIZW" update wiz.plugin "Wiz Plugin" "x" "malformed-pin" >/dev/null 2>&1
check "wizard malformed pin: refuses" \
  "Wiz Plugin: the verified commit pin is malformed; refusing to update." \
  "$(head -1 "$NOTIFLOG" | cut -f2-)"
: > "$NOTIFLOG"
FIX_UPDATE_OUT="Already up to date." bash "$WIZW" update wiz.plugin "Wiz Plugin" "x" "" >/dev/null 2>&1
check "wizard unverified up-to-date: title" "Plugin up to date" "$(head -1 "$NOTIFLOG" | cut -f1)"

# ---- wizard worker: install mode (enable loop lands) ----------------------
: > "$NOTIFLOG"
export FIX_LIST="$TESTHOME/wizlist.json"
jq -n '[{id:"from-repo.plugin",name:"From Repo",version:"0.1.0",enabled:true}]' > "$FIX_LIST"
FIX_ADD_ID=from-repo.plugin bash "$WIZW" install from-repo.plugin "From Repo" "https://github.com/acme/from-repo.git" "" >/dev/null 2>&1
check "wizard install: enabled notification" \
  "From Repo is installed and enabled." "$(head -1 "$NOTIFLOG" | cut -f2-)"

# ---- wizard worker: install mode rejects non-GitHub repos ------------------
# The repo URL reaches the worker as a bare argv string; it is re-validated
# before omarchy plugin add sees it (fail closed, no clone attempted).
: > "$NOTIFLOG"
out=$(bash "$WIZW" install sneaky.plugin "Sneaky" "https://evil.invalid/x/../y" "" 2>&1); rc=$?
check "wizard install rejects non-github repo: exit 2" "2" "$rc"
check "wizard install rejects non-github repo: notif" \
  "Sneaky: invalid plugin repository URL." "$(head -1 "$NOTIFLOG" | cut -f2-)"
check "wizard install rejects non-github repo: no clone" "0" "$(ls -d "$PLUG/sneaky.plugin" 2>/dev/null | wc -l)"
: > "$NOTIFLOG"
bash "$WIZW" install sneaky2.plugin "Sneaky2" "https://github.com/../escape" "" >/dev/null 2>&1; rc=$?
check "wizard install rejects dot-component repo: exit 2" "2" "$rc"

# ---- wizard worker: notification bodies are sanitized ----------------------
# A display name carrying a newline could spoof a second notification line.
: > "$NOTIFLOG"
FIX_REMOVE_RC=0 bash "$WIZW" uninstall wiz.plugin "$(printf 'Ev\nil')" "" "" >/dev/null 2>&1
check "wizard uninstall: name control chars stripped" \
  "Evil has been removed." "$(tail -1 "$NOTIFLOG" | cut -f2-)"
check "wizard uninstall: one notification line per run" "1" "$(wc -l < "$NOTIFLOG")"

# ---- wizard worker: uninstall mode ----------------------------------------
: > "$NOTIFLOG"
FIX_REMOVE_RC=0 bash "$WIZW" uninstall wiz.plugin "Wiz Plugin" "" "" >/dev/null 2>&1
check "wizard uninstall: notification" "Wiz Plugin has been removed." "$(head -1 "$NOTIFLOG" | cut -f2-)"

# ---- wizard worker: marker protocol (mode recorded, cleaned up) -----------
: > "$SHELLLOG"
rm -rf "$XDG_STATE_HOME"
bash "$WIZW" uninstall gone.plugin "Gone" "" "" >/dev/null 2>&1
MARKDIR="$XDG_STATE_HOME/omarchy/bramvanoploo.omarchy-browser-plugin-manager/in-progress"
check "wizard marker cleaned up on exit" "0" "$(find "$MARKDIR" -type f 2>/dev/null | wc -l)"

echo
if (( FAILURES > 0 )); then
  echo "$FAILURES check(s) failed"
  exit 1
fi
echo "all checks passed"
