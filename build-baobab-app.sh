#!/bin/bash

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$SCRIPT_DIR/scripts/lib/baobab-bash-bootstrap.sh"
ensure_baobab_bash "$0" "$@"

set -euo pipefail

BAOBAB_BASH_BIN="${BAOBAB_BASH_BIN:-$BASH}"

exec "$BAOBAB_BASH_BIN" "$SCRIPT_DIR/scripts/build-baobab-app.sh" "$@"
