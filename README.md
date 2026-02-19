# codex-macos-to-linux

A practical Linux bootstrap script that turns the official `Codex.dmg` package into a runnable Linux setup by extracting `app.asar` and preparing a local Electron runtime.

> This is an **unofficial** helper script. It uses a macOS Codex DMG as the source artifact and adapts it for Linux use.

## Why this exists

You asked for a Linux-friendly, reusable version of the original one-off script. This repo now contains:

- a clear launcher name: `codex-macos-to-linux.sh`
- distro-aware dependency handling
- reproducible workspace paths
- optional offline updates
- generated runnable launcher `run-codex.sh`

## Repository structure

- `codex-macos-to-linux.sh` – bootstrap script
- `README.md` – this file

## Requirements

You need either:

- sudo access (optional, for package install)
- internet access for download/rebuild
- one terminal shell (bash)

At runtime the script looks for:

- `curl`, `git`, `node`, `npm` (`pnpm` is installed automatically)
- `make`, `gcc`, `g++` for native module rebuilds
- a DMG extractor (`7z`/`p7zip`, fallback to bundled 7-Zip CLI)

## Quick start

```bash
chmod +x codex-macos-to-linux.sh
./codex-macos-to-linux.sh
```

First run:
- checks missing system tools and (if needed) installs them with your package manager,
- downloads `Codex.dmg` to `~/Downloads/codex-macos-to-linux/Codex.dmg`,
- extracts `app.asar`,
- installs matching local Electron package,
- rebuilds Linux native modules (`better-sqlite3`, `node-pty`) when needed,
- writes a launcher at:

```
~/.local/share/codex-macos-to-linux/run-codex.sh
```

Run the app:

```bash
~/.local/share/codex-macos-to-linux/run-codex.sh
```

Create a desktop menu entry (so it appears in rofi/drun, app menus):

```bash
./codex-macos-to-linux.sh --install-desktop
```

Open rofi with:

```bash
rofi -show drun
```

If it still does not appear immediately:

```bash
update-desktop-database ~/.local/share/applications
xdg-desktop-menu forceupdate
```

If you already had a stale entry, regenerate after updates:

```bash
./codex-macos-to-linux.sh --force
```

If sandbox blocks startup on your distro, try:

```bash
CODEX_NO_SANDBOX=1 ~/.local/share/codex-macos-to-linux/run-codex.sh
```

## Script options

```bash
./codex-macos-to-linux.sh [options]
```

- `--force` : re-extract and rebuild even if nothing changed
- `--skip-system-deps` : skip automatic package installation
- `--root-dir PATH` : override workspace directory (default `~/.local/share/codex-macos-to-linux`)
- `--download-dir PATH` : override where `Codex.dmg` is downloaded
- `--dmg-path PATH` : set explicit DMG location
- `--force-electron-version X.Y.Z` : manually set Electron version
- `--install-desktop` : write/overwrite desktop menu entry (default: on)
- `--no-desktop` : skip menu entry creation
- `--help` : show option list

## Environment variables

- `FORCE` (0/1)
- `SKIP_SYSTEM_DEPS` (0/1)
- `ROOT_APP_DIR`
- `DOWNLOAD_DIR`
- `DMG_PATH`
- `FORCE_ELECTRON_VERSION`
- `PNPM_HOME`

These are useful in automation or CI setups.

## How it works (high level)

1. **System check**
   - prints distro/kernel/arch details and checks required tools.
2. **Download**
   - grabs official DMG from OpenAI-hosted URL.
3. **Extract**
   - extracts DMG and finds `app.asar`.
4. **Unpack app.asar**
   - extracts app tree into the local workspace.
5. **Resolve Electron version**
   - from DMG `Info.plist` when available, otherwise existing Electron binary fallback.
6. **Install matching Electron tools**
   - local `_tools/node_modules/electron` version aligned to the app.
7. **Native modules**
   - validates `better-sqlite3` / `node-pty` native binaries and rebuilds for the detected Electron ABI when needed.
8. **Launcher creation**
   - writes `run-codex.sh` with sane defaults and `CODEX_HOME`.
9. **CLI optional install**
   - attempts `pnpm i -g @openai/codex`.

## Update flow

To update the application package later:

- Download/update DMG manually
- re-run:

```bash
./codex-macos-to-linux.sh --force
```

This replaces `app_asar` with the latest archive and reruns module rebuild steps.

If you only changed source flags/paths but not app content, run normal mode and it will skip full extraction when DMG hash is unchanged.

## Making it an install-style command (optional)

```bash
ln -s "$(pwd)/codex-macos-to-linux.sh" "$HOME/.local/bin/codex-macos-to-linux"
```

Ensure `~/.local/bin` is in PATH.

## Risk and compatibility notes

- This is a workaround script. It is **not** an official cross-platform Codex build channel.
- Native module rebuild may fail on unusual toolchains/architectures.
- On non-x86_64 architectures behavior is best-effort only.

## Troubleshooting

- If `npm_config` errors appear during rebuild, confirm:
  - `python3`, `make`, `gcc`, `g++` are installed
  - system headers are available
- If launch fails with missing shared libraries, verify local Electron path:
  - `~/.local/share/codex-macos-to-linux/_tools/node_modules/electron/dist/electron`
- If CLI is missing, run:
  - `pnpm setup`
  - `pnpm i -g @openai/codex`
  - add `PNPM_HOME` to PATH
