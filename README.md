# Codex Launcher (Unofficial)

Unofficial launchers for running Codex on Linux and Windows.
This repository is for developers who want a practical local launcher flow without manually unpacking and patching the desktop app each time.

Quick start:

```bash
git clone https://github.com/nassimna/codex-launcher.git
cd codex-launcher
./linux/codex-linux-bridge.sh
```

On Windows, run `.\windows\codex-windows-bridge.ps1` from the repository root in PowerShell.

## Repository structure

```text
.
├── linux/
│   ├── README.md
│   ├── codex-linux-bridge.sh
│   ├── codex-macos-to-linux.sh
│   └── install-codex-linux.sh
└── windows/
    ├── README.md
    ├── codex-windows-bridge.ps1
    ├── patch-main-windows.cjs
    └── install-codex-windows.ps1
```

## Linux install and run

```bash
git clone https://github.com/nassimna/codex-launcher.git codex-launcher
cd codex-launcher
chmod +x linux/codex-linux-bridge.sh
./linux/codex-linux-bridge.sh
```

Run after install:

```bash
~/.local/share/openai-codex-linux/run-codex.sh
```

Optional one-liner installer:

```bash
curl -fsSL https://raw.githubusercontent.com/nassimna/codex-launcher/main/linux/install-codex-linux.sh | bash
```

## Windows install and run

PowerShell:

```powershell
git clone https://github.com/nassimna/codex-launcher.git codex-launcher
cd codex-launcher
Set-ExecutionPolicy -Scope Process Bypass
.\windows\codex-windows-bridge.ps1
```

Run after install:

```powershell
$env:LOCALAPPDATA\openai-codex-windows\run-codex.vbs
```

Optional installer wrapper:

```powershell
.\windows\install-codex-windows.ps1
```

One-shot install from PowerShell (no git required):

```powershell
irm https://raw.githubusercontent.com/nassimna/codex-launcher/main/windows/install-codex-windows.ps1 | iex
```

The Windows bridge script bootstraps missing dependencies (`Node.js`, `7-Zip`, and native-build prerequisites when required) via `winget` by default.

## Platform details

- Linux details: `linux/README.md`
- Windows details: `windows/README.md`
