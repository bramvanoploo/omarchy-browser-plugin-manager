#!/bin/bash
# Signs the Firefox add-on with the AMO credentials from .env (unlisted).
# .env is gitignored, so the credentials stay on this machine.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
ENV_FILE="$(cd "$SCRIPT_DIR/../../.." && pwd)/.env"
[[ -f "$ENV_FILE" ]] || { echo "Missing .env with AMO_API_KEY and AMO_API_SECRET" >&2; exit 1; }
set -a; source "$ENV_FILE"; set +a
exec "$SCRIPT_DIR/sign" "$@"
