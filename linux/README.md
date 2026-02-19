# Linux Launcher (Unofficial)

This folder contains the Linux-specific implementation that adapts the official `Codex.dmg` package to run on Linux.

## Files

- `codex-linux-bridge.sh` - primary Linux launcher/setup script
- `codex-macos-to-linux.sh` - compatibility wrapper to the main Linux script
- `install-codex-linux.sh` - Linux installer bootstrap script

## Install (one-time)

From repository root:

```bash
git clone https://github.com/nassimna/codex-linux-launcher.git codex-launcher
cd codex-launcher
chmod +x linux/codex-linux-bridge.sh
./linux/codex-linux-bridge.sh
```

Or with curl:

```bash
curl -fsSL https://raw.githubusercontent.com/nassimna/codex-linux-launcher/main/linux/install-codex-linux.sh | bash
```

## What this script does

1. Downloads (or reuses) `Codex.dmg`.
2. Extracts `app.asar` and unpacks it into a writable workspace.
3. Selects a compatible Electron runtime.
4. Installs/updates required dependencies.
5. Builds Linux native modules (`better-sqlite3`, `node-pty`) for your Electron ABI.
6. Patches the app bundle so external editor detection includes:
   - `code`
   - `codium`
   - `code-insiders`
   - `codium-insiders`
7. Generates a runnable launcher script and a desktop file for application menus.

## Output paths

The first run creates:

- `~/.local/share/openai-codex-linux/run-codex.sh`
- `~/.local/share/applications/openai-codex-linux.desktop`

Run it with:

```bash
~/.local/share/openai-codex-linux/run-codex.sh
```

## Update flow

```bash
cd /path/to/codex-launcher
./linux/codex-linux-bridge.sh --force
```

`--force` re-downloads/re-extracts and forces a rebuild.

## Frequently used options

```bash
./linux/codex-linux-bridge.sh [options]

--force                   re-run extraction and native rebuild
--skip-system-deps         do not attempt package installation
--root-dir PATH           workspace path (default ~/.local/share/openai-codex-linux)
--download-dir PATH       where to store Codex.dmg
--dmg-path PATH           use a specific downloaded DMG
--force-electron-version   override detected Electron version
--install-desktop          write/overwrite desktop entry (default: on)
--no-desktop              skip desktop entry creation
--help                    show usage
```

## Notes

- This is an unofficial helper and DMG internals can change.
- Native module ABI must match Electron version.
- Run as a non-root user. Elevated rights are only needed for package installation.
