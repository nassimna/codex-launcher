# Windows Launcher (Unofficial)

This folder contains the Windows-specific launcher flow.

## Files

- `codex-windows-bridge.ps1` - main Windows setup script
- `install-codex-windows.ps1` - convenience wrapper (downloads this repo and runs the script)

## What this script does

1. Downloads (or reuses) `Codex.dmg`.
2. Extracts `app.asar` using 7-Zip.
3. Installs a matching Electron runtime locally.
4. Rebuilds Windows native modules (`better-sqlite3`, `node-pty`) for the app Electron ABI.
5. Patches external editor detection for Windows VS Code paths.
6. Creates `run-codex.cmd` and an optional Start Menu shortcut.

## Prerequisites

- Windows 10/11
- PowerShell 5+ (PowerShell 7 recommended)
- Node.js + npm
- 7-Zip (`7z` available in PATH or default install path)
  - If missing, the script tries to install it automatically via `winget`.
  - Manual install command: `winget install --id 7zip.7zip -e`
- For native rebuilds:
  - Visual Studio Build Tools (Desktop C++ workload)
  - Python 3

## Run

From repository root:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\windows\codex-windows-bridge.ps1
```

Then launch:

```powershell
$env:LOCALAPPDATA\openai-codex-windows\run-codex.cmd
```

## Common options

```powershell
.\windows\codex-windows-bridge.ps1 -Force
.\windows\codex-windows-bridge.ps1 -SkipNativeRebuild
.\windows\codex-windows-bridge.ps1 -RootDir "D:\Apps\openai-codex-windows"
.\windows\codex-windows-bridge.ps1 -NoShortcut
.\windows\codex-windows-bridge.ps1 -ForceElectronVersion "37.3.0"
```

## Notes

- This is still an unofficial portability helper.
- If native rebuild fails, install C++ build tools and rerun.
- DMG internals can change and break extraction/patching.
