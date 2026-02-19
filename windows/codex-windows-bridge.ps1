[CmdletBinding()]
param(
  [switch]$Force,
  [switch]$SkipNativeRebuild,
  [string]$RootDir = "$env:LOCALAPPDATA\openai-codex-windows",
  [string]$DownloadDir = "$env:USERPROFILE\Downloads\openai-codex-windows",
  [string]$DmgPath = "",
  [string]$DmgUrl = "https://persistent.oaistatic.com/codex-app-prod/Codex.dmg",
  [string]$ForceElectronVersion = "",
  [switch]$NoShortcut
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $DmgPath) {
  $DmgPath = Join-Path $DownloadDir "Codex.dmg"
}

$AppName = "openai-codex-windows"
$AppDisplayName = "OpenAI Codex (Unofficial)"
$ToolsDir = Join-Path $RootDir "_tools"
$TmpBuildDir = Join-Path $RootDir "_native-build"
$DmgExtractDir = Join-Path $RootDir "dmg_extracted"
$AppAsarDir = Join-Path $RootDir "app_asar"
$DmgSignatureFile = Join-Path $RootDir ".dmg.signature"
$RunLauncher = Join-Path $RootDir "run-codex.cmd"
$ShortcutPath = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$AppDisplayName.lnk"

function Write-Section([string]$Message) {
  Write-Host ""
  Write-Host "=== $Message ==="
}

function Fail([string]$Message) {
  throw $Message
}

function Have([string]$Name) {
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-External {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [string[]]$Arguments = @()
  )
  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    Fail "Command failed: $FilePath $($Arguments -join ' ')"
  }
}

function Ensure-Directories {
  New-Item -ItemType Directory -Force -Path $RootDir | Out-Null
  New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
  New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null
}

function Show-System {
  Write-Section "System check"
  Write-Host "OS        : $([System.Environment]::OSVersion.VersionString)"
  Write-Host "User      : $env:USERNAME"
  Write-Host "RootDir   : $RootDir"
  Write-Host "Download  : $DownloadDir"
}

function Ensure-Prerequisites {
  Write-Section "Prerequisites"
  $required = @("node", "npm")
  foreach ($cmd in $required) {
    if (-not (Have $cmd)) {
      Fail "Missing required command '$cmd'. Install Node.js first."
    }
  }
}

function Ensure-Pnpm {
  if (Have "pnpm") {
    return
  }

  if (Have "corepack") {
    & corepack enable | Out-Null
    & corepack prepare pnpm@latest --activate
    if ($LASTEXITCODE -eq 0 -and (Have "pnpm")) {
      return
    }
  }

  Write-Warning "pnpm not found, installing globally through npm."
  Invoke-External -FilePath "npm" -Arguments @("i", "-g", "pnpm")
}

function Resolve-7Zip {
  $candidates = @(
    "7z",
    "7zz",
    "C:\Program Files\7-Zip\7z.exe",
    "C:\Program Files\7-Zip\7zz.exe"
  )
  foreach ($candidate in $candidates) {
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($cmd) {
      return $cmd.Source
    }
    if (Test-Path $candidate) {
      return $candidate
    }
  }

  Fail "7-Zip not found. Install 7-Zip and ensure '7z' is on PATH."
}

function Ensure-Tooling {
  if (-not (Test-Path (Join-Path $ToolsDir "package.json"))) {
    Set-Content -Path (Join-Path $ToolsDir "package.json") -Encoding Ascii -Value @'
{
  "name": "codex-windows-tools",
  "private": true,
  "version": "1.0.0"
}
'@
  }

  $asarPath = Join-Path $ToolsDir "node_modules\asar\bin\asar.js"
  if (-not (Test-Path $asarPath)) {
    Invoke-External -FilePath "pnpm" -Arguments @("--dir", $ToolsDir, "add", "-D", "asar", "@electron/rebuild")
  }
}

function Download-Dmg {
  if ((Test-Path $DmgPath) -and -not $Force) {
    Write-Host "Using existing DMG: $DmgPath"
    return
  }

  Write-Section "Downloading Codex.dmg"
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $DmgPath) | Out-Null
  Invoke-WebRequest -Uri $DmgUrl -OutFile $DmgPath
}

function Get-DmgHash {
  return (Get-FileHash -Path $DmgPath -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Extract-AppAsar {
  $currentSig = Get-DmgHash
  $previousSig = ""
  if (Test-Path $DmgSignatureFile) {
    $previousSig = (Get-Content -Raw $DmgSignatureFile).Trim()
  }

  if (-not $Force -and $currentSig -eq $previousSig -and (Test-Path (Join-Path $AppAsarDir "package.json"))) {
    Write-Section "DMG unchanged, skipping app.asar extraction"
    return
  }

  Write-Section "Extracting DMG and app.asar"
  Remove-Item -Recurse -Force $DmgExtractDir, $AppAsarDir -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $DmgExtractDir, $AppAsarDir | Out-Null

  $sevenZip = Resolve-7Zip
  Invoke-External -FilePath $sevenZip -Arguments @("x", "-y", "-aoa", $DmgPath, "-o$DmgExtractDir")

  $appAsar = Get-ChildItem -Path $DmgExtractDir -Recurse -File -Filter "app.asar" | Select-Object -First 1
  if (-not $appAsar) {
    Fail "Could not locate app.asar inside DMG."
  }

  $asarCli = Join-Path $ToolsDir "node_modules\asar\bin\asar.js"
  Invoke-External -FilePath "node" -Arguments @($asarCli, "extract", $appAsar.FullName, $AppAsarDir)

  Set-Content -Path $DmgSignatureFile -Encoding Ascii -Value $currentSig
}

function Patch-MainBundle {
  $mainBundle = Get-ChildItem -Path (Join-Path $AppAsarDir ".vite\build") -File -Filter "main-*.js" -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $mainBundle) {
    Write-Warning "No main-*.js bundle found; skipping editor patch."
    return
  }

  Write-Section "Patching external editor detection for Windows"
  $patchScriptPath = Join-Path $ToolsDir "patch-main-windows.cjs"
  Set-Content -Path $patchScriptPath -Encoding Ascii -Value @'
const fs = require("node:fs");
const path = process.argv[2];
let source = fs.readFileSync(path, "utf8");
const original = source;

source = source.replace(
  'if(!Yr)throw new Error("Opening external editors is only supported on macOS");',
  ""
);

source = source.replace(
  'if(process.platform==="win32")throw new Error("Opening external editors is not supported on Windows yet");',
  ""
);

source = source.replace(
  "async function oN(){if(!Yr)return[];",
  "async function oN(){"
);

const oldSp = 'function Sp(t){try{const e=Dn.spawnSync("which",[t],{encoding:"utf8",timeout:1e3}),n=e.stdout?.trim();if(e.status===0&&n&&Ee.existsSync(n))return n}catch(e){li().debug("Failed to locate command in PATH",{safe:{command:t},sensitive:{error:e}})}return null}';
const oldSpNoMacGuard = 'function Sp(t){if(!Yr)return null;try{const e=Dn.spawnSync("which",[t],{encoding:"utf8",timeout:1e3}),n=e.stdout?.trim();if(e.status===0&&n&&Ee.existsSync(n))return n}catch(e){li().debug("Failed to locate command in PATH",{safe:{command:t},sensitive:{error:e}})}return null}';
const newSp = `function Sp(t){const n=[t,\`${process.env.SystemRoot ?? "C:\\\\Windows"}\\\\System32\\\\\${t}\`,\`${process.env.ProgramFiles ?? "C:\\\\Program Files"}\\\\Microsoft VS Code\\\\bin\\\\\${t}\`,\`${process.env.LOCALAPPDATA ?? ""}\\\\Programs\\\\Microsoft VS Code\\\\bin\\\\\${t}\`,\`${process.env.ProgramFiles ?? "C:\\\\Program Files"}\\\\VSCodium\\\\bin\\\\\${t}\`,\`${process.env.LOCALAPPDATA ?? ""}\\\\Programs\\\\VSCodium\\\\bin\\\\\${t}\`].filter(Boolean);for(const i of n){if((i.includes("/")||i.includes("\\\\"))&&Ee.existsSync(i))return i;for(const cmd of ["where","which"]){try{const e=Dn.spawnSync(cmd,[i],{encoding:"utf8",timeout:1e3}),r=e.stdout?.split(/\\r?\\n/).find(Boolean)?.trim();if(e.status===0&&r&&Ee.existsSync(r))return r}catch(e){li().debug("Failed to locate command in PATH",{safe:{},sensitive:{command:i,error:e}})}}}return null}`;

if (source.includes(oldSp)) {
  source = source.replace(oldSp, newSp);
}
if (source.includes(oldSpNoMacGuard)) {
  source = source.replace(oldSpNoMacGuard, newSp);
}

const vscodeDetect = 'detect:()=>Sp("code")||Sp("codium")||sn(["/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code","/Applications/Code.app/Contents/Resources/app/bin/code"])';
const vscodeDetectFromBundle = 'detect:()=>sn(["/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code","/Applications/Code.app/Contents/Resources/app/bin/code"])';
const vscodeInsiderDetect = 'detect:()=>Sp("code-insiders")||Sp("codium-insiders")||sn(["/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code","/Applications/Code - Insiders.app/Contents/Resources/app/bin/code"])';
const vscodeInsiderDetectFromBundle = 'detect:()=>sn(["/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code","/Applications/Code - Insiders.app/Contents/Resources/app/bin/code"])';

const vscodeReplacement = `detect:()=>{const i=process.env.CODEX_VSCODE_PATH?.trim();if(i&&Ee.existsSync(i))return i;return Sp("code.cmd")||Sp("code")||Sp("codium.cmd")||Sp("codium")||sn(["C:\\\\Program Files\\\\Microsoft VS Code\\\\bin\\\\code.cmd","\${process.env.LOCALAPPDATA ?? ""}\\\\Programs\\\\Microsoft VS Code\\\\bin\\\\code.cmd","C:\\\\Program Files\\\\VSCodium\\\\bin\\\\codium.cmd","\${process.env.LOCALAPPDATA ?? ""}\\\\Programs\\\\VSCodium\\\\bin\\\\codium.cmd"])}`;
const vscodeInsiderReplacement = `detect:()=>{const i=process.env.CODEX_VSCODE_INSIDERS_PATH?.trim();if(i&&Ee.existsSync(i))return i;return Sp("code-insiders.cmd")||Sp("code-insiders")||Sp("codium-insiders.cmd")||Sp("codium-insiders")||sn(["C:\\\\Program Files\\\\Microsoft VS Code Insiders\\\\bin\\\\code-insiders.cmd","\${process.env.LOCALAPPDATA ?? ""}\\\\Programs\\\\Microsoft VS Code Insiders\\\\bin\\\\code-insiders.cmd"])}`;

if (source.includes(vscodeDetect)) {
  source = source.replace(vscodeDetect, vscodeReplacement);
}
if (source.includes(vscodeDetectFromBundle)) {
  source = source.replace(vscodeDetectFromBundle, vscodeReplacement);
}
if (source.includes(vscodeInsiderDetect)) {
  source = source.replace(vscodeInsiderDetect, vscodeInsiderReplacement);
}
if (source.includes(vscodeInsiderDetectFromBundle)) {
  source = source.replace(vscodeInsiderDetectFromBundle, vscodeInsiderReplacement);
}

if (source !== original) {
  fs.writeFileSync(path, source);
}
'@

  Invoke-External -FilePath "node" -Arguments @($patchScriptPath, $mainBundle.FullName)
}

function Resolve-ElectronVersion {
  if ($ForceElectronVersion) {
    return $ForceElectronVersion
  }

  $packageJson = Join-Path $AppAsarDir "package.json"
  if (Test-Path $packageJson) {
    $version = & node -e "const pkg=require(process.argv[1]);const raw=(pkg.devDependencies?.electron||pkg.dependencies?.electron||'').replace(/^\^/,'');if(/^[0-9]+(\.[0-9]+){1,}$/.test(raw))process.stdout.write(raw);" $packageJson
    if ($LASTEXITCODE -eq 0 -and $version) {
      return $version
    }
  }

  if (Have "electron") {
    $raw = & electron --version
    if ($LASTEXITCODE -eq 0) {
      return $raw.TrimStart("v")
    }
  }

  Fail "Could not determine Electron version. Use -ForceElectronVersion."
}

function Ensure-LocalElectron([string]$Version) {
  $current = ""
  $electronPkg = Join-Path $ToolsDir "node_modules\electron\package.json"
  if (Test-Path $electronPkg) {
    $current = & node -e "process.stdout.write(require(process.argv[1]).version || '');" $electronPkg
  }

  if ($current -ne $Version) {
    Write-Section "Installing local Electron $Version"
    Invoke-External -FilePath "pnpm" -Arguments @("--dir", $ToolsDir, "add", "-D", "electron@$Version")
  }

  & pnpm --dir $ToolsDir rebuild electron | Out-Null
}

function Test-IsPortableExecutable([string]$Path) {
  if (-not (Test-Path $Path)) {
    return $false
  }

  $bytes = [System.IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -lt 2) {
    return $false
  }
  return ($bytes[0] -eq 0x4D -and $bytes[1] -eq 0x5A) # MZ
}

function Needs-NativeRebuild {
  if ($Force) {
    return $true
  }
  if ($SkipNativeRebuild) {
    return $false
  }

  $sqliteNode = Join-Path $AppAsarDir "node_modules\better-sqlite3\build\Release\better_sqlite3.node"
  $ptyNode = Join-Path $AppAsarDir "node_modules\node-pty\build\Release\pty.node"

  if (-not (Test-IsPortableExecutable $sqliteNode)) {
    return $true
  }
  if (-not (Test-IsPortableExecutable $ptyNode)) {
    return $true
  }
  return $false
}

function Rebuild-NativeModules([string]$ElectronVersion) {
  if ($SkipNativeRebuild) {
    Write-Warning "Skipping native rebuild by request."
    return
  }

  Write-Section "Rebuilding native modules for Electron $ElectronVersion"
  Remove-Item -Recurse -Force $TmpBuildDir -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $TmpBuildDir | Out-Null

  $bsqlPkg = Join-Path $AppAsarDir "node_modules\better-sqlite3\package.json"
  $ptyPkg = Join-Path $AppAsarDir "node_modules\node-pty\package.json"
  $bsqlVersion = "12.5.0"
  $ptyVersion = "1.1.0"

  if (Test-Path $bsqlPkg) {
    $value = & node -e "process.stdout.write(require(process.argv[1]).version || '');" $bsqlPkg
    if ($LASTEXITCODE -eq 0 -and $value) { $bsqlVersion = $value }
  }
  if (Test-Path $ptyPkg) {
    $value = & node -e "process.stdout.write(require(process.argv[1]).version || '');" $ptyPkg
    if ($LASTEXITCODE -eq 0 -and $value) { $ptyVersion = $value }
  }

  Set-Content -Path (Join-Path $TmpBuildDir "package.json") -Encoding Ascii -Value @"
{
  "name": "codex-native-build",
  "private": true,
  "version": "1.0.0",
  "dependencies": {
    "better-sqlite3": "$bsqlVersion",
    "node-pty": "$ptyVersion"
  }
}
"@

  $oldRuntime = $env:npm_config_runtime
  $oldTarget = $env:npm_config_target
  $oldDisturl = $env:npm_config_disturl
  $oldBuildFromSource = $env:npm_config_build_from_source
  $oldCache = $env:npm_config_cache

  try {
    $env:npm_config_runtime = "electron"
    $env:npm_config_target = $ElectronVersion
    $env:npm_config_disturl = "https://electronjs.org/headers"
    $env:npm_config_build_from_source = "true"
    $env:npm_config_cache = Join-Path $TmpBuildDir ".npm-cache"

    & npm --prefix $TmpBuildDir --no-audit --no-fund install
    if ($LASTEXITCODE -ne 0) {
      Write-Warning "Native module install failed. Install Visual Studio Build Tools and retry."
      return
    }
    & npm --prefix $TmpBuildDir --no-audit --no-fund rebuild better-sqlite3 node-pty
    if ($LASTEXITCODE -ne 0) {
      Write-Warning "Native module rebuild failed. Install Visual Studio Build Tools and retry."
      return
    }
  }
  finally {
    $env:npm_config_runtime = $oldRuntime
    $env:npm_config_target = $oldTarget
    $env:npm_config_disturl = $oldDisturl
    $env:npm_config_build_from_source = $oldBuildFromSource
    $env:npm_config_cache = $oldCache
  }

  $rebuiltSqlite = Join-Path $TmpBuildDir "node_modules\better-sqlite3\build\Release\better_sqlite3.node"
  $rebuiltPty = Join-Path $TmpBuildDir "node_modules\node-pty\build\Release\pty.node"

  if (-not (Test-Path $rebuiltSqlite) -or -not (Test-Path $rebuiltPty)) {
    Write-Warning "Rebuild completed but expected binaries were not produced."
    return
  }

  Remove-Item -Recurse -Force (Join-Path $AppAsarDir "node_modules\better-sqlite3"), (Join-Path $AppAsarDir "node_modules\node-pty") -ErrorAction SilentlyContinue
  Copy-Item -Recurse -Force (Join-Path $TmpBuildDir "node_modules\better-sqlite3") (Join-Path $AppAsarDir "node_modules\better-sqlite3")
  Copy-Item -Recurse -Force (Join-Path $TmpBuildDir "node_modules\node-pty") (Join-Path $AppAsarDir "node_modules\node-pty")
}

function Write-Launcher {
  $content = @'
@echo off
setlocal EnableExtensions

set "ROOT_DIR=%~dp0"
set "ROOT_DIR=%ROOT_DIR:~0,-1%"
set "APP_DIR=%ROOT_DIR%\app_asar"
set "LOCAL_ELECTRON=%ROOT_DIR%\_tools\node_modules\electron\dist\electron.exe"

if not exist "%LOCAL_ELECTRON%" (
  for /f "delims=" %%I in ('where electron 2^>nul') do (
    set "LOCAL_ELECTRON=%%I"
    goto after_electron
  )
  echo ERROR: electron.exe not found.
  exit /b 1
)

:after_electron
set "ELECTRON_FORCE_IS_PACKAGED=1"
set "NODE_ENV=production"
set "CODEX_HOME=%ROOT_DIR%"

if not defined CODEX_CLI_PATH (
  for /f "delims=" %%I in ('where codex 2^>nul') do (
    set "CODEX_CLI_PATH=%%I"
    goto after_codex
  )
)
:after_codex

if not defined CODEX_VSCODE_PATH (
  for %%C in (code.cmd code codium.cmd codium) do (
    for /f "delims=" %%I in ('where %%C 2^>nul') do (
      set "CODEX_VSCODE_PATH=%%I"
      goto after_vscode
    )
  )
)
:after_vscode

if not defined CODEX_VSCODE_INSIDERS_PATH (
  for %%C in (code-insiders.cmd code-insiders codium-insiders.cmd codium-insiders) do (
    for /f "delims=" %%I in ('where %%C 2^>nul') do (
      set "CODEX_VSCODE_INSIDERS_PATH=%%I"
      goto after_vscode_insiders
    )
  )
)
:after_vscode_insiders

if "%CODEX_NO_SANDBOX%"=="1" (
  "%LOCAL_ELECTRON%" --no-sandbox "%APP_DIR%"
) else (
  "%LOCAL_ELECTRON%" "%APP_DIR%"
)
'@

  Set-Content -Path $RunLauncher -Encoding Ascii -Value $content
}

function Ensure-Shortcut {
  if ($NoShortcut) {
    Write-Warning "Skipping Start Menu shortcut (-NoShortcut)."
    return
  }

  Write-Section "Creating Start Menu shortcut"
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ShortcutPath) | Out-Null
  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($ShortcutPath)
  $shortcut.TargetPath = $RunLauncher
  $shortcut.WorkingDirectory = $RootDir
  $shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,220"
  $shortcut.Save()
}

function Ensure-CodexCli {
  if (Have "codex") {
    return
  }

  Write-Section "Installing @openai/codex CLI"
  & pnpm setup | Out-Null
  if (-not $env:PNPM_HOME) {
    $env:PNPM_HOME = "$env:LOCALAPPDATA\pnpm"
  }
  Invoke-External -FilePath "pnpm" -Arguments @("add", "-g", "@openai/codex")
}

function Print-NextSteps([string]$ElectronVersion) {
  Write-Section "Done"
  Write-Host "Electron : $ElectronVersion"
  Write-Host "Launcher : $RunLauncher"
  Write-Host "RootDir  : $RootDir"
  if (-not $NoShortcut) {
    Write-Host "Shortcut : $ShortcutPath"
  }
  Write-Host ""
  Write-Host "Start Codex:"
  Write-Host "  $RunLauncher"
}

function Main {
  Ensure-Directories
  Show-System
  Ensure-Prerequisites
  Ensure-Pnpm
  Ensure-Tooling
  Download-Dmg
  Extract-AppAsar
  Patch-MainBundle

  $electronVersion = Resolve-ElectronVersion
  Write-Section "Electron version: $electronVersion"
  Ensure-LocalElectron -Version $electronVersion

  if (Needs-NativeRebuild) {
    Rebuild-NativeModules -ElectronVersion $electronVersion
  }
  else {
    Write-Section "Native modules already look compatible, skipping rebuild"
  }

  Write-Launcher
  Ensure-Shortcut
  Ensure-CodexCli
  Print-NextSteps -ElectronVersion $electronVersion
}

Main
