#!/usr/bin/env bash
set -euo pipefail

# Prefer local bridge when this installer is running from a repo/archive checkout.
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
LOCAL_BRIDGE="$SCRIPT_DIR/codex-linux-bridge.sh"

if [ -f "$LOCAL_BRIDGE" ]; then
  chmod +x "$LOCAL_BRIDGE"
  exec "$LOCAL_BRIDGE" "$@"
fi

REPO_URL="https://github.com/nassimna/codex-linux-launcher"
ARCHIVE_URL="${REPO_URL}/archive/refs/heads/main.tar.gz"
TMP_DIR="$(mktemp -d)"
TARGET_DIR="$TMP_DIR/codex-linux-launcher-main"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl is required." >&2
  exit 1
fi

if ! command -v tar >/dev/null 2>&1; then
  echo "ERROR: tar is required." >&2
  exit 1
fi

echo "Downloading codex-linux-launcher archive..."
curl -fsSL "$ARCHIVE_URL" -o "$TMP_DIR/source.tar.gz"

tar -xzf "$TMP_DIR/source.tar.gz" -C "$TMP_DIR"

if [ ! -f "$TARGET_DIR/linux/codex-linux-bridge.sh" ]; then
  echo "ERROR: extracted package does not contain expected files." >&2
  exit 1
fi

chmod +x "$TARGET_DIR/linux/codex-linux-bridge.sh"

# Use user's current directory as workspace by default (same as script behavior)
cd "$TARGET_DIR"
./linux/codex-linux-bridge.sh "$@"
