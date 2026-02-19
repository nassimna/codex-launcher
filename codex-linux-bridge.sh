#!/usr/bin/env bash
set -euo pipefail

# Backward-compatible wrapper. Real Linux implementation lives in linux/.
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"

exec "$SCRIPT_DIR/linux/codex-linux-bridge.sh" "$@"
