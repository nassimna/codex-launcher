# Codex Launcher (Unofficial)

This repository contains separate launchers for running Codex on Linux and Windows.

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
    └── install-codex-windows.ps1
```

## Linux install and run

```bash
git clone https://github.com/nassimna/codex-linux-launcher.git codex-launcher
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
curl -fsSL https://raw.githubusercontent.com/nassimna/codex-linux-launcher/main/linux/install-codex-linux.sh | bash
```

## Windows install and run

PowerShell:

```powershell
git clone https://github.com/nassimna/codex-linux-launcher.git codex-launcher
cd codex-launcher
winget install --id 7zip.7zip -e
Set-ExecutionPolicy -Scope Process Bypass
.\windows\codex-windows-bridge.ps1
```

Run after install:

```powershell
$env:LOCALAPPDATA\openai-codex-windows\run-codex.cmd
```

Optional installer wrapper:

```powershell
.\windows\install-codex-windows.ps1
```

## Platform details

- Linux details: `linux/README.md`
- Windows details: `windows/README.md`
