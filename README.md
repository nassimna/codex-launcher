# Codex Linux Launcher

This project contains a single Bash script that adapts the official `Codex.dmg` package to run on Linux.

It is an **unofficial helper**, built for development use. You still need a valid Codex account/CLI for the app itself.

## Install (one-time)

```bash
git clone <your-repo-url> \
  && cd codex-linux-launcher \
  && chmod +x codex-linux-bridge.sh \
  && ./codex-linux-bridge.sh
```

After install, launch with:

```bash
~/.local/share/openai-codex-linux/run-codex.sh
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

## Files

- `codex-linux-bridge.sh` (primary script)
- `codex-macos-to-linux.sh` (compatibility wrapper; kept intentionally for older references)
- `.gitignore`

## Quick start

```bash
# 1) clone
# git clone <your-repo-url>
# cd codex-linux-launcher

# 2) make executable
chmod +x codex-linux-bridge.sh

# 3) run first time
./codex-linux-bridge.sh
```

The first run prints detected versions, installs missing system tools (optional), extracts the app, rebuilds native modules, and creates:

- `~/.local/share/openai-codex-linux/run-codex.sh`
- `~/.local/share/applications/openai-codex-linux.desktop`

Run it:

```bash
~/.local/share/openai-codex-linux/run-codex.sh
```

Optional: make it globally callable:

```bash
mkdir -p "$HOME/.local/bin"
ln -sfn "$PWD/codex-linux-bridge.sh" "$HOME/.local/bin/codex-launcher"
```

## Update flow

When OpenAI releases a new DMG, rerun in place:

```bash
cd /path/to/codex-linux-launcher
./codex-linux-bridge.sh --force
```

`--force` re-downloads/re-extracts and forces a rebuild.

## Frequently used options

```bash
./codex-linux-bridge.sh [options]

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

## Desktop entry and rofi

If it does not appear in `rofi -show drun` immediately:

```bash
update-desktop-database ~/.local/share/applications
xdg-desktop-menu forceupdate
```

The desktop file path is:

`$HOME/.local/share/applications/openai-codex-linux.desktop`

## Editor integration

The launcher exports environment variables into the Electron process:

- `CODEX_VSCODE_PATH`
- `CODEX_VSCODE_INSIDERS_PATH`
- `CODEX_CLI_PATH`

If you want to force a specific binary:

```bash
CODEX_VSCODE_PATH=/usr/bin/code \
CODEX_VSCODE_INSIDERS_PATH=/usr/bin/code-insiders \
~/.local/share/openai-codex-linux/run-codex.sh
```

## Notes for native modules

Builds can fail on non-standard toolchains. Install dependencies once globally if needed:

- `python` (`python3`)
- `gcc`, `g++`, `make`
- `p7zip` or `7z`
- `node`, `npm` (or `corepack` + `pnpm`)

Native module install in this script uses non-interactive `npm` rebuild commands internally to avoid `pnpm` script-approval prompts.

## Why this can break

- Scripted extraction from `DMG` is a portability workaround, not an official Linux distribution.
- DMG internals can change.
- Native module ABI must match the app's Electron version.
- Linux security policies or older OS images may require adjusting permissions.

## Recommended run as non-root

Run this script as a normal user. Elevated rights are used only when installing system packages.

## GitHub setup

To publish this as a repo:

```bash
git init
# git remote add origin <your-repo-url>
git add README.md codex-linux-bridge.sh codex-macos-to-linux.sh .gitignore

git commit -m "feat: add Linux launcher for Codex DMG"
# git push -u origin main
```
