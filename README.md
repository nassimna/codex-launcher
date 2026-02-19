# Codex Launcher (Linux + Windows)

This repository contains unofficial portability helpers for running Codex on Linux and Windows, with each platform isolated into its own folder.

## Repository structure

```text
.
├── linux/
│   ├── README.md
│   ├── codex-linux-bridge.sh
│   ├── codex-macos-to-linux.sh
│   └── install-codex-linux.sh
├── windows/
│   ├── README.md
│   ├── codex-windows-bridge.ps1
│   └── install-codex-windows.ps1
├── codex-linux-bridge.sh        # compatibility wrapper -> linux/
├── codex-macos-to-linux.sh      # compatibility wrapper -> linux/
└── install-codex.sh             # compatibility installer wrapper -> linux/
```

## Platform docs

- Linux: `linux/README.md`
- Windows: `windows/README.md`

## Quick start

Linux:

```bash
./linux/codex-linux-bridge.sh
```

Windows (PowerShell):

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\windows\codex-windows-bridge.ps1
```

## Backward compatibility

Root scripts are kept to avoid breaking old commands:

- `./codex-linux-bridge.sh`
- `./codex-macos-to-linux.sh`
- `./install-codex.sh`

These wrappers now delegate to the `linux/` folder.
