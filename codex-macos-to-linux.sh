#!/usr/bin/env bash
set -e

# Backward-compatible wrapper kept for convenience.
exec "$(dirname "$0")/codex-linux-bridge.sh" "$@"
