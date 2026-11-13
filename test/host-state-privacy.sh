#!/bin/bash
# Regression harness for the native host's privacy fixes
# (bin/omarchy-plugin-install-host):
#   - owner-only state storage: dir 700, every entry loses group/other access,
#     including pre-existing files written world-readable by older releases
#   - presence heartbeats (marketplace URLs) never travel in process argv
#   - record_visit dedupe, staleness pruning, payload validation
#   - clear_visit prunes exactly one tab key
#   - focus-request consumption answers "activate" and stamps consumedBy
#   - stamp_seen install evidence: mode, freshness, key pruning, corrupt-entry
#     repair (a non-numeric value must not read as fresh)
#
# The host script guards main() behind [[ ${BASH_SOURCE[0]} == "$0" ]], so
# sourcing it here only defines functions. Everything runs against a throwaway
# HOME/XDG_STATE_HOME and is cleaned up on exit.
#
# Usage: test/host-state-privacy.sh   (exit 0 = all checks pass)
set -u

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="$REPO_ROOT/bin/omarchy-plugin-install-host"
[[ -f $HOST ]] || { echo "host script not found: $HOST"; exit 1; }

TESTHOME=$(mktemp -d)
trap 'rm -rf "$TESTHOME"' EXIT
export HOME="$TESTHOME"
export XDG_STATE_HOME="$TESTHOME/.local/state"
STATE_DIR="$XDG_STATE_HOME/omarchy/bramvanoploo.omarchy-browser-plugin-manager"
TABS_FILE="$STATE_DIR/browser-tabs.json"

FAILURES=0
check() { # check <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    echo "ok   $1"
  else
    echo "FAIL $1: expected [$2] got [$3]"
    FAILURES=$((FAILURES + 1))
  fi
}
perms() { stat -c '%a' "$1" 2>/dev/null || echo missing; }

# Source the host library once (functions only; main() does not run).
# shellcheck disable=SC1091
source "$HOST"
# The host sets `set -euo pipefail`; relax -e so the checks below can inspect
# the exit codes of intentionally-invalid payloads.
set +e

# --- seed: pre-existing state from an older release, world-readable (022) ---
(
  umask 022
  mkdir -p "$STATE_DIR"
  printf '%s\n' '{"tabs":[{"source":"firefox","key":"stale1","url":"http://old/x","ts":1}]}' >"$TABS_FILE"
  printf '%s\n' '{"pollMinutes":5}' >"$STATE_DIR/settings.json"
  printf 'not json\n' >"$STATE_DIR/browser-watch.json"
  mkdir -p "$STATE_DIR/sub"
  printf 'x' >"$STATE_DIR/sub/nested.conf"
)

# --- heartbeat writes: validation, dedupe, argv-hostile URL -----------------
# Live argv sampler: /proc is polled continuously while the heartbeats run,
# so a URL leaking into any short-lived child's argv (jq, printf, cat) is
# caught. Canary string is unique to this harness.
CANARY='plugins.omarchy.org/plugin.html?id=argvcanary'
SAMPLE="$TESTHOME/argv-hits"
: > "$SAMPLE"
(
  for _ in $(seq 1 300); do
    for p in $(pgrep -f -- "$CANARY" 2>/dev/null); do
      [[ "$p" == "$$" ]] && continue
      echo hit >> "$SAMPLE"
    done
    sleep 0.02
  done
) &
sampler=$!

record_visit '{"type":"visit","source":"firefox","key":"k1","url":"https://plugins.omarchy.org/plugin.html?id=argvcanary&x=--arg foo","active":true}' >/dev/null
record_visit '{"type":"visit","source":"chromium","key":"k2","url":"https://plugins.omarchy.org/","active":false}' >/dev/null
record_visit '{"type":"visit","source":"firefox","key":"k1","url":"https://plugins.omarchy.org/plugin.html?id=argvcanary&x=--arg foo","active":true}' >/dev/null
record_visit '{"type":"visit","source":"firefox","key":"k4","url":"https://plugins.omarchy.org/plugin.html?id=argvcanary","active":true}' >/dev/null
record_visit '{"type":"visit","source":"chromium","key":"k5","url":"https://plugins.omarchy.org/","active":false}' >/dev/null
record_visit '{"type":"visit","source":"firefox","key":"k1","url":"https://plugins.omarchy.org/plugin.html?id=argvcanary&x=--arg foo","active":true}' >/dev/null

# sample the sampler's steady-state self-match noise baseline: it matches
# only transient pgrep helpers, which never carry the canary's URL data.
check "heartbeat URL never appears in child argv" 0 "$(grep -c . "$SAMPLE")"
kill "$sampler" 2>/dev/null; wait "$sampler" 2>/dev/null

record_visit '{"type":"visit","source":"firefox","key":"k3"}' >/dev/null 2>&1
check "url-less visit rejected (rc)" 1 $?
record_visit '"just-a-string"' >/dev/null 2>&1
check "non-object payload rejected (rc)" 1 $?

check "tabs file keys (deduped, stale pruned)" "k1,k2,k4,k5" \
  "$(jq -r '[.tabs[].key] | sort | join(",")' "$TABS_FILE")"
check "url survives verbatim" "https://plugins.omarchy.org/plugin.html?id=argvcanary&x=--arg foo" \
  "$(jq -r '.tabs[] | select(.key=="k1") | .url' "$TABS_FILE")"

# --- owner-only tightening (dir + pre-existing files, incl. subdir) ---------
check "state dir mode" 700 "$(perms "$STATE_DIR")"
check "browser-tabs.json mode" 600 "$(perms "$TABS_FILE")"
check "settings.json mode" 600 "$(perms "$STATE_DIR/settings.json")"
check "browser-watch.json mode" 600 "$(perms "$STATE_DIR/browser-watch.json")"
check "subdir mode" 700 "$(perms "$STATE_DIR/sub")"
# Nested files are not chmod'ed individually; the 700 directory makes them
# unreachable for anyone but the owner, which is the protection.
check "nested file mode (protected by dir 700)" 644 "$(perms "$STATE_DIR/sub/nested.conf")"

# --- clear_visit drops exactly one key ---------------------------------------
clear_visit '{"type":"unvisit","key":"k2"}' >/dev/null
check "clear_visit prunes one key" "k1,k4,k5" "$(jq -r '[.tabs[].key] | sort | join(",")' "$TABS_FILE")"

# --- focus request consumption ------------------------------------------------
( umask 022
  printf '{"ts":%s,"nonce":1,"consumedBy":""}\n' "$(( $(date +%s) * 1000 ))" >"$STATE_DIR/browser-focus.json" )
out=$(record_visit '{"type":"visit","source":"firefox","key":"k1","url":"https://plugins.omarchy.org/","active":true}')
check "focus request answered" "activate" "$out"
check "consumedBy stamped" "k1" "$(jq -r .consumedBy "$STATE_DIR/browser-focus.json")"
check "browser-focus.json mode" 600 "$(perms "$STATE_DIR/browser-focus.json")"

# --- stale-entry pruning -------------------------------------------------------
printf '%s\n' '{"tabs":[{"source":"firefox","key":"ancient","url":"http://x","ts":1}]}' >"$TABS_FILE"
record_visit '{"type":"visit","source":"firefox","key":"fresh","url":"http://y"}' >/dev/null
check "stale entry pruned" "fresh" "$(jq -r '[.tabs[].key] | join(",")' "$TABS_FILE")"

# --- watch beacon still writes, privately --------------------------------------
record_watch '{"type":"watch","id":"acme.weather","repo":"https://github.com/acme/weather.git","name":"Weather"}'
check "browser-watch.json mode (watch)" 600 "$(perms "$STATE_DIR/browser-watch.json")"
check "watch record id" "acme.weather" "$(jq -r .id "$STATE_DIR/browser-watch.json")"

# --- stamp_seen install evidence (browser-extension-seen.json) ---------------
check "seen file absent initially" "missing" "$(perms "$STATE_DIR/browser-extension-seen.json")"
stamp_seen firefox
check "seen file mode" 600 "$(perms "$SEEN_FILE")"
check "seen firefox numeric" "number" "$(jq -r '.firefox | type' "$SEEN_FILE")"
check "seen chrome absent" "null" "$(jq -r '.chrome | type' "$SEEN_FILE")"
stamp_seen brave
check "unknown family ignored" "null" "$(jq -r '.chrome | type' "$SEEN_FILE")"
first_seen=$(jq -r '.firefox' "$SEEN_FILE")
stamp_seen firefox
check "fresh stamp not rewritten" "$first_seen" "$(jq -r '.firefox' "$SEEN_FILE")"
# stale entries are refreshed and unknown keys pruned on merge
printf '{"firefox":1,"safari":123}\n' >"$SEEN_FILE"
stamp_seen firefox
check "stale firefox refreshed" "true" "$(jq -r '.firefox > 1' "$SEEN_FILE")"
check "merge prunes unknown keys" "firefox" "$(jq -r 'keys | join(",")' "$SEEN_FILE")"
stamp_seen chrome
check "second family merged in" "chrome,firefox" "$(jq -r 'keys | sort | join(",")' "$SEEN_FILE")"
# regression: a corrupt non-numeric entry must not read as fresh (jq's total
# ordering puts strings above numbers, which used to lock the family out of
# ever being re-stamped)
printf '{"firefox":"yesterday"}\n' >"$SEEN_FILE"
stamp_seen firefox
check "corrupt entry repaired" "number" "$(jq -r '.firefox | type' "$SEEN_FILE")"
check "corrupt sibling kept usable" "true" "$(jq -r '.firefox > 0' "$SEEN_FILE")"

echo
if (( FAILURES > 0 )); then
  echo "$FAILURES check(s) failed"
  exit 1
fi
echo "all checks passed"
