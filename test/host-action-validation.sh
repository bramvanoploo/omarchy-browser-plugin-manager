#!/bin/bash
# Regression harness for the native host's core security gate: validate_action
# (bin/omarchy-plugin-install-host). The host never installs anything itself;
# it summons the consent wizard only after this gate (re)proves the request is
# trustworthy:
#   - id/repo shape rules (normalize_target)
#   - local plugin state must match the requested action (already-installed,
#     not-installed, enable/disable pairs, placement is local-only)
#   - a FRESH catalog fetch must contain the id, its repo must match the
#     requested repo (after /.git and trailing-slash normalization), and an
#     install must point at a one-click-installable, non-built-in entry
#   - an unreachable or unparseable catalog fails closed
#
# curl and omarchy are shimmed on PATH: the catalog body and the plugin list
# are fixed per check. Like the privacy harness, the host's main() is guarded
# behind [[ ${BASH_SOURCE[0]} == "$0" ]], so sourcing only defines functions.
#
# Usage: test/host-action-validation.sh   (exit 0 = all checks pass)
set -u

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="$REPO_ROOT/bin/omarchy-plugin-install-host"
[[ -f $HOST ]] || { echo "host script not found: $HOST"; exit 1; }

TESTHOME=$(mktemp -d)
trap 'rm -rf "$TESTHOME"' EXIT
export HOME="$TESTHOME"
export XDG_STATE_HOME="$TESTHOME/.local/state"
export XDG_CONFIG_HOME="$TESTHOME/.config"
mkdir -p "$TESTHOME/bin"
export PATH="$TESTHOME/bin:$PATH"

# curl shim: prints $FIX_CATALOG (a file path) and succeeds, else fails like
# a dead network. The real call passes flags the shim ignores.
cat > "$TESTHOME/bin/curl" <<'EOF'
#!/bin/bash
if [[ -n "${FIX_CATALOG:-}" && -f "$FIX_CATALOG" ]]; then
  cat "$FIX_CATALOG"
  exit 0
fi
exit 22
EOF
cat > "$TESTHOME/bin/omarchy" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "plugin" && "${2:-}" == "list" ]]; then
  printf '%s' "${FIX_LIST:-[]}"
  exit 0
fi
exit 1
EOF
chmod +x "$TESTHOME/bin/curl" "$TESTHOME/bin/omarchy"

FAILURES=0
check() { # check <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    echo "ok   $1"
  else
    echo "FAIL $1: expected [$2] got [$3]"
    FAILURES=$((FAILURES + 1))
  fi
}

# shellcheck disable=SC1091
source "$HOST"
set +e
# Empty every per-process plugin-list cache between checks.
PLUGIN_LIST_CACHE="" PLUGIN_LIST_CACHE_AT=0

set_list() { export FIX_LIST="$1"; PLUGIN_LIST_CACHE=""; PLUGIN_LIST_CACHE_AT=0; }
set_catalog() { printf '%s' "$1" > "$TESTHOME/catalog.json"; export FIX_CATALOG="$TESTHOME/catalog.json"; }
no_catalog() { export FIX_CATALOG=""; }

GOOD_CATALOG='[{"id":"acme.weather","repo":"https://github.com/acme/weather",
  "installAvailable":true,"upstreamCheckStatus":"ok",
  "installCommand":"omarchy plugin add https://github.com/acme/weather","builtIn":false}]'
GOOD_PAYLOAD='{"id":"acme.weather","repo":"https://github.com/acme/weather"}'

gate() { # gate <payload> <mode> -> prints reason, sets GATE_RC
  GATE_OUT=$(validate_action "$1" "$2" 2>/dev/null)
  GATE_RC=$?
  printf '%s' "$GATE_OUT"
}

# --- happy path: fresh installable entry, plugin not installed -------------
set_list '[]'
set_catalog "$GOOD_CATALOG"
check "valid install passes" "0" "$(gate "$GOOD_PAYLOAD" install >/dev/null; echo $GATE_RC)"

# --- repo spelling normalizes (catalog trailing slash, payload .git) -------
set_catalog '[{"id":"acme.weather","repo":"https://github.com/acme/weather/",
  "installAvailable":true,"upstreamCheckStatus":"ok","installCommand":"x","builtIn":false}]'
check "repo .git/trailing-slash normalize" "0" \
  "$(gate '{"id":"acme.weather","repo":"https://github.com/acme/weather.git/"}' install >/dev/null; echo $GATE_RC)"

# --- the catalog entry must point at the repo the page asked for ----------
set_catalog '[{"id":"acme.weather","repo":"https://github.com/evil/weather",
  "installAvailable":true,"upstreamCheckStatus":"ok","installCommand":"x","builtIn":false}]'
check "repo mismatch rejected" "repo-mismatch" "$(gate "$GOOD_PAYLOAD" install)"

# --- entry missing / not one-click-installable / built-in -----------------
set_catalog '[]'
check "unknown plugin id rejected" "unknown-plugin-id" "$(gate "$GOOD_PAYLOAD" install)"
set_catalog '[{"id":"acme.weather","repo":"https://github.com/acme/weather",
  "installAvailable":false,"upstreamCheckStatus":"ok","installCommand":"x","builtIn":false}]'
check "not installAvailable rejected" "not-one-click-installable" "$(gate "$GOOD_PAYLOAD" install)"
set_catalog '[{"id":"acme.weather","repo":"https://github.com/acme/weather",
  "installAvailable":true,"upstreamCheckStatus":"failed","installCommand":"x","builtIn":false}]'
check "failed upstream check rejected" "not-one-click-installable" "$(gate "$GOOD_PAYLOAD" install)"
set_catalog '[{"id":"acme.weather","repo":"https://github.com/acme/weather",
  "installAvailable":true,"upstreamCheckStatus":"ok","installCommand":"x","builtIn":true}]'
check "built-in entry rejected" "not-one-click-installable" "$(gate "$GOOD_PAYLOAD" install)"

# --- catalog unreachable / corrupt must fail closed ------------------------
set_catalog 'not json at all {'
check "corrupt catalog fails closed" "catalog-unreachable" "$(gate "$GOOD_PAYLOAD" install)"
no_catalog
check "unreachable catalog fails closed" "catalog-unreachable" "$(gate "$GOOD_PAYLOAD" install)"

# --- payload shape rules run before any local or network work --------------
set_catalog "$GOOD_CATALOG"
check "bad id grammar rejected" "invalid-plugin-id" "$(gate '{"id":"Bad Id","repo":"https://github.com/acme/weather"}' install)"
check "id traversal rejected" "invalid-plugin-id" "$(gate '{"id":"acme..weather","repo":"https://github.com/acme/weather"}' install)"
check "empty id rejected" "invalid-plugin-id" "$(gate '{}' install)"
check "non-github repo rejected" "invalid-repo-url" "$(gate '{"id":"acme.weather","repo":"https://evil.example/acme/weather"}' install)"
check "repo dot-component rejected" "invalid-repo-url" "$(gate '{"id":"acme.weather","repo":"https://github.com/../weather"}' install)"

# --- local-state rules ------------------------------------------------------
set_list '[{"id":"acme.weather","enabled":true,"firstParty":false,"kinds":["bar-widget"]}]'
check "install of installed plugin refused" "already-installed" "$(gate "$GOOD_PAYLOAD" install)"
check "enable of enabled plugin refused" "already-enabled" "$(gate "$GOOD_PAYLOAD" enable)"
check "disable of enabled plugin passes" "0" "$(gate "$GOOD_PAYLOAD" disable >/dev/null; echo $GATE_RC)"
check "unknown mode rejected" "unknown-message-type" "$(gate "$GOOD_PAYLOAD" frobnicate)"
set_list '[]'
check "uninstall of absent plugin refused" "not-installed" "$(gate "$GOOD_PAYLOAD" uninstall)"
set_list '[{"id":"acme.core","enabled":true,"firstParty":true,"kinds":[]}]'
check "uninstall of first-party refused" "not-installed" "$(gate '{"id":"acme.core","repo":"https://github.com/acme/core"}' uninstall)"

# --- placement validates local state only (no catalog round-trip) ---------
set_list '[{"id":"acme.weather","enabled":true,"firstParty":false,"kinds":["bar-widget"]}]'
no_catalog
check "placement works offline" "0" "$(gate "$GOOD_PAYLOAD" placement >/dev/null; echo $GATE_RC)"
set_list '[{"id":"acme.weather","enabled":true,"firstParty":false,"kinds":[]}]'
check "placement on non-widget refused" "not-a-bar-widget" "$(gate "$GOOD_PAYLOAD" placement)"

echo
if (( FAILURES > 0 )); then
  echo "$FAILURES check(s) failed"
  exit 1
fi
echo "all checks passed"
