# Windows Launcher (Unofficial)

This folder contains the Windows-specific launcher flow.

## Files

- `codex-windows-bridge.ps1` - main Windows setup script
- `install-codex-windows.ps1` - convenience wrapper (uses local bridge when available, otherwise downloads this repo and runs the script)
- `patch-main-windows.cjs` - bundle patcher for editor detection on Windows

## What this script does

1. Downloads (or reuses) `Codex.dmg`.
2. Extracts `app.asar` using 7-Zip.
3. Installs a matching Electron runtime locally.
4. Rebuilds Windows native modules (`better-sqlite3`, `node-pty`) for the app Electron ABI.
5. Patches external editor detection for Windows VS Code paths.
6. Creates launchers:
   - `run-codex.vbs` (windowless, for shortcut/double click)
   - `run-codex.ps1` (actual launcher logic)
   - `run-codex.cmd` (CLI-friendly wrapper)
7. Extracts a Codex logo from app assets and uses it for the Start Menu shortcut icon when possible.

## Prerequisites

- Windows 10/11
- PowerShell 5+ (PowerShell 7 recommended)
- `winget` recommended for one-shot bootstrap installs
- Node.js + npm (auto-installed when missing, unless `-NoBootstrap`)
- 7-Zip (`7z`) (auto-installed when missing, unless `-NoBootstrap`)
- For native rebuilds:
  - Visual Studio Build Tools (Desktop C++ workload, auto-installed when needed)
  - Python 3 (auto-installed when needed)
  - If Python is installed but not in `PATH`, the script also checks common install locations under `%LOCALAPPDATA%\Programs\Python`

## Run

From repository root:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\windows\codex-windows-bridge.ps1
```

Then launch:

```powershell
$env:LOCALAPPDATA\openai-codex-windows\run-codex.vbs
```

## Common options

```powershell
.\windows\codex-windows-bridge.ps1 -Force
.\windows\codex-windows-bridge.ps1 -SkipNativeRebuild
.\windows\codex-windows-bridge.ps1 -RootDir "D:\Apps\openai-codex-windows"
.\windows\codex-windows-bridge.ps1 -NoShortcut
.\windows\codex-windows-bridge.ps1 -ForceElectronVersion "37.3.0"
.\windows\codex-windows-bridge.ps1 -NoBootstrap
```

## Notes

- This is still an unofficial portability helper.
- The script now bootstraps missing dependencies (Node.js, 7-Zip, Python/Build Tools when needed) via `winget` by default.
- Use `-NoBootstrap` to disable auto-install behavior.
- DMG internals can change and break extraction/patching.
