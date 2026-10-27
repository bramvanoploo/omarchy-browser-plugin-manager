#!/bin/bash
# Signs the Firefox add-on with the AMO credentials from .env (unlisted).
# .env is gitignored, so the credentials stay on this machine.
set -euo pipefail
cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
[[ -f .env ]] || { echo "Missing .env with AMO_API_KEY and AMO_API_SECRET" >&2; exit 1; }
set -a; source .env; set +a
exec ./bin/sign "$@"
