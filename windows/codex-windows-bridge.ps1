[CmdletBinding()]
param(
  [switch]$Force,
  [switch]$SkipNativeRebuild,
  [string]$RootDir = "$env:LOCALAPPDATA\openai-codex-windows",
  [string]$DownloadDir = "$env:USERPROFILE\Downloads\openai-codex-windows",
  [string]$DmgPath = "",
  [string]$DmgUrl = "https://persistent.oaistatic.com/codex-app-prod/Codex.dmg",
  [string]$ForceElectronVersion = "",
  [switch]$NoShortcut,
  [switch]$NoBootstrap
)

$ErrorActionPreference = "Stop"

trap {
  $line = $_.InvocationInfo.ScriptLineNumber
  $text = $_.InvocationInfo.Line
  Write-Error "Script failed at line ${line}: $text`n$($_.Exception.Message)"
  exit 1
}

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
$RunLauncherCmd = Join-Path $RootDir "run-codex.cmd"
$RunLauncherPs1 = Join-Path $RootDir "run-codex.ps1"
$RunLauncherVbs = Join-Path $RootDir "run-codex.vbs"
$RunLauncher = $RunLauncherVbs
$LauncherIcon = Join-Path $RootDir "codex-logo.ico"
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

function Add-ToPathIfPresent([string]$Dir) {
  if (-not $Dir) {
    return
  }
  if (-not (Test-Path $Dir)) {
    return
  }
  if ($env:PATH -notlike "*$Dir*") {
    $env:PATH = "$Dir;$env:PATH"
  }
}

function Refresh-PathHints {
  Add-ToPathIfPresent "$env:ProgramFiles\nodejs"
  Add-ToPathIfPresent "$env:LOCALAPPDATA\Microsoft\WinGet\Links"
  Add-ToPathIfPresent "$env:LOCALAPPDATA\Programs\Python\Python312"
  Add-ToPathIfPresent "$env:LOCALAPPDATA\Programs\Python\Python312\Scripts"
  Add-ToPathIfPresent "$env:LOCALAPPDATA\Programs\Python\Launcher"
}

function Invoke-WingetInstall {
  param(
    [Parameter(Mandatory = $true)][string]$PackageId,
    [Parameter(Mandatory = $true)][string]$DisplayName,
    [string]$Scope = "",
    [string[]]$ExtraArguments = @()
  )

  if (-not (Have "winget")) {
    return $false
  }

  $args = @(
    "install",
    "--id", $PackageId,
    "-e",
    "--silent",
    "--accept-source-agreements",
    "--accept-package-agreements"
  )
  if ($Scope) {
    $args += @("--scope", $Scope)
  }
  if ($ExtraArguments -and $ExtraArguments.Count -gt 0) {
    $args += $ExtraArguments
  }

  Write-Section "Installing $DisplayName"
  & winget @args
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "winget install failed for $DisplayName (exit $LASTEXITCODE)."
    return $false
  }
  return $true
}

function Ensure-Prerequisites {
  Write-Section "Prerequisites"
  Refresh-PathHints

  if ((Have "node") -and (Have "npm")) {
    return
  }

  if ($NoBootstrap) {
    Fail "Missing Node.js/npm. Install Node.js LTS and rerun, or remove -NoBootstrap."
  }

  if (-not (Have "winget")) {
    Fail "Missing Node.js/npm and winget is unavailable. Install Node.js LTS manually and rerun."
  }

  if (-not (Invoke-WingetInstall -PackageId "OpenJS.NodeJS.LTS" -DisplayName "Node.js LTS" -Scope "user")) {
    Fail "Node.js installation failed. Install Node.js manually and rerun."
  }

  Refresh-PathHints
  if (-not (Have "node") -or -not (Have "npm")) {
    Fail "Node.js was installed but node/npm are not in PATH yet. Open a new terminal and rerun."
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

function Find-7ZipCandidate {
  $candidates = @(
    "7z",
    "7zz",
    "$env:ProgramFiles\7-Zip\7z.exe",
    "$env:ProgramFiles\7-Zip\7zz.exe",
    "${env:ProgramFiles(x86)}\7-Zip\7z.exe",
    "${env:ProgramFiles(x86)}\7-Zip\7zz.exe",
    "$env:LOCALAPPDATA\Programs\7-Zip\7z.exe",
    "$env:LOCALAPPDATA\Programs\7-Zip\7zz.exe",
    "$env:ChocolateyInstall\bin\7z.exe",
    "$env:ChocolateyInstall\bin\7zz.exe"
  ) | Where-Object { $_ -and $_.Trim() -ne "" }

  foreach ($candidate in $candidates) {
    $commandInfo = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($commandInfo) {
      if ($commandInfo -is [System.Array]) {
        $commandInfo = $commandInfo[0]
      }
      $resolvedPath = $commandInfo.Source
      if (-not $resolvedPath -and $commandInfo.Path) {
        $resolvedPath = $commandInfo.Path
      }
      if ($resolvedPath) {
        return $resolvedPath
      }
    }
    if (Test-Path $candidate) {
      return $candidate
    }
  }

  $wingetPackageRoots = Get-ChildItem -Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Directory -Filter "7zip.7zip_*" -ErrorAction SilentlyContinue
  foreach ($root in $wingetPackageRoots) {
    $foundExecutables = Get-ChildItem -Path $root.FullName -Recurse -File -Filter "7z.exe" -ErrorAction SilentlyContinue
    if ($foundExecutables) {
      return $foundExecutables[0].FullName
    }
  }

  return ""
}

function Resolve-7Zip {
  $existing = Find-7ZipCandidate
  if ($existing) {
    return $existing
  }

  if (-not $NoBootstrap -and (Have "winget")) {
    if (Invoke-WingetInstall -PackageId "7zip.7zip" -DisplayName "7-Zip") {
      $installed = Find-7ZipCandidate
      if ($installed) {
        return $installed
      }
    }
  }

  Fail "7-Zip not found. Install it with: winget install --id 7zip.7zip -e"
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
  $oldProgressPreference = $ProgressPreference
  try {
    # PowerShell 5 can spend significant time rendering progress bars.
    $ProgressPreference = "SilentlyContinue"
    Invoke-WebRequest -Uri $DmgUrl -OutFile $DmgPath
  }
  finally {
    $ProgressPreference = $oldProgressPreference
  }
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
  # 7-Zip may report errors for macOS symlinks that cannot be created without
  # admin privileges on Windows. These are harmless — we only need app.asar.
  # Temporarily relax error handling so symlink stderr does not trigger the trap.
  $savedEAP = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  & $sevenZip x -y -aoa $DmgPath "-o$DmgExtractDir"
  $sevenZipExit = $LASTEXITCODE
  $ErrorActionPreference = $savedEAP

  $appAsar = Get-ChildItem -Path $DmgExtractDir -Recurse -File -Filter "app.asar" | Select-Object -First 1
  if (-not $appAsar) {
    Fail "7-Zip extraction failed (exit code $sevenZipExit). Could not locate app.asar inside DMG."
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

  # Use the standalone patch script shipped alongside the bridge.
  # This avoids PowerShell heredoc escaping issues with JS template literals.
  $patchScript = Join-Path $PSScriptRoot "patch-main-windows.cjs"
  if (-not (Test-Path $patchScript)) {
    Write-Warning "patch-main-windows.cjs not found next to bridge script; skipping editor patch."
    return
  }

  & node $patchScript $mainBundle.FullName
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "Editor patch failed (exit $LASTEXITCODE). The app will still work but VS Code detection may not function."
  }
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
  $installedNow = $false
  $electronPkg = Join-Path $ToolsDir "node_modules\electron\package.json"
  if (Test-Path $electronPkg) {
    $current = & node -e "process.stdout.write(require(process.argv[1]).version || '');" $electronPkg
  }

  if ($current -ne $Version) {
    Write-Section "Installing local Electron $Version"
    Invoke-External -FilePath "pnpm" -Arguments @("--dir", $ToolsDir, "add", "-D", "electron@$Version")
    $installedNow = $true
  }

  # Rebuilding Electron each run is unnecessary and slows startup.
  # Keep it for forced runs or right after installation.
  if ($Force -or $installedNow) {
    & pnpm --dir $ToolsDir rebuild electron | Out-Null
  }
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
  if (-not (Test-IsPortableExecutable $sqliteNode)) {
    return $true
  }

  # node-pty can work via build/Release/pty.node OR prebuilds/win32-x64/*.node
  $ptyNode = Join-Path $AppAsarDir "node_modules\node-pty\build\Release\pty.node"
  $ptyPrebuilds = Join-Path $AppAsarDir "node_modules\node-pty\prebuilds\win32-x64"
  if (-not (Test-IsPortableExecutable $ptyNode)) {
    $hasPrebuilt = $false
    if (Test-Path $ptyPrebuilds) {
      $prebuiltFiles = Get-ChildItem -Path $ptyPrebuilds -Filter "*.node" -ErrorAction SilentlyContinue
      if ($prebuiltFiles) { $hasPrebuilt = $true }
    }
    if (-not $hasPrebuilt) {
      return $true
    }
  }
  return $false
}

function Resolve-PythonExecutable {
  Refresh-PathHints

  foreach ($pyCmd in @("python", "python3", "py")) {
    try {
      $cmd = Get-Command $pyCmd -ErrorAction SilentlyContinue | Select-Object -First 1
      if (-not $cmd) {
        continue
      }
      $path = $cmd.Source
      if (-not $path -and $cmd.Path) {
        $path = $cmd.Path
      }
      if (-not $path) {
        continue
      }
      $pyOut = & $path --version 2>&1
      if ($LASTEXITCODE -eq 0 -and $pyOut -match 'Python \d') {
        return $path
      }
    } catch {}
  }

  $pathCandidates = @(
    "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe",
    "$env:ProgramFiles\Python313\python.exe",
    "$env:ProgramFiles\Python312\python.exe",
    "$env:ProgramFiles\Python311\python.exe"
  )
  foreach ($candidate in $pathCandidates) {
    if (-not (Test-Path $candidate)) {
      continue
    }
    try {
      $pyOut = & $candidate --version 2>&1
      if ($LASTEXITCODE -eq 0 -and $pyOut -match 'Python \d') {
        return $candidate
      }
    } catch {}
  }

  return ""
}

function Test-PythonAvailable {
  return [bool](Resolve-PythonExecutable)
}

function Test-VsBuildToolsAvailable {
  $vsWhere = Join-Path "${env:ProgramFiles(x86)}" "Microsoft Visual Studio\Installer\vswhere.exe"
  if (-not (Test-Path $vsWhere)) {
    return $false
  }

  $installPath = & $vsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $installPath) {
    return $false
  }

  $msvcRoot = Join-Path $installPath "VC\Tools\MSVC"
  return (Test-Path $msvcRoot)
}

function Ensure-NativeBuildToolchain {
  $pythonPath = Resolve-PythonExecutable
  $status = @{
    Python = [bool]$pythonPath
    PythonPath = $pythonPath
    BuildTools = Test-VsBuildToolsAvailable
  }

  if ($NoBootstrap -or -not (Have "winget")) {
    return $status
  }

  if (-not $status.Python) {
    $ok = Invoke-WingetInstall -PackageId "Python.Python.3.12" -DisplayName "Python 3.12" -Scope "user"
    if ($ok) {
      $status.PythonPath = Resolve-PythonExecutable
      $status.Python = [bool]$status.PythonPath
    }
  }

  if (-not $status.BuildTools) {
    $ok = Invoke-WingetInstall `
      -PackageId "Microsoft.VisualStudio.2022.BuildTools" `
      -DisplayName "Visual Studio Build Tools (C++)" `
      -ExtraArguments @("--override", "--wait --quiet --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended")
    if ($ok) {
      $status.BuildTools = Test-VsBuildToolsAvailable
    }
  }

  return $status
}

function Rebuild-NativeModules([string]$ElectronVersion) {
  if ($SkipNativeRebuild) {
    Write-Warning "Skipping native rebuild by request."
    return
  }

  $toolchain = Ensure-NativeBuildToolchain
  if (-not $toolchain.Python -or -not $toolchain.BuildTools) {
    Write-Warning "Native module rebuild requires Python 3 and Visual Studio Build Tools (Desktop C++ workload)."
    if (-not $toolchain.Python) {
      Write-Warning "Python is missing. Install with: winget install Python.Python.3.12"
    }
    if (-not $toolchain.BuildTools) {
      Write-Warning "Visual Studio Build Tools are missing. Install with: winget install Microsoft.VisualStudio.2022.BuildTools --override ""--wait --quiet --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"""
    }
    Write-Warning "Skipping rebuild for now."
    return
  }

  if ($toolchain.PythonPath) {
    $env:PYTHON = $toolchain.PythonPath
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

  # Install packages with --ignore-scripts so node-pty does not try to build
  # from source during install (its winpty build is broken in the npm tarball
  # because GetCommitHash.bat is missing). We then use @electron/rebuild to
  # compile better-sqlite3 from source for the correct Electron ABI, and rely
  # on node-pty's prebuilt N-API binaries (prebuilds/win32-x64).
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

  $nativeDepsInstalled = $false

  # Prefer pnpm (already bootstrapped by this script) to avoid npm wrapper
  # inconsistencies on some Windows setups.
  & pnpm --dir $TmpBuildDir install --ignore-scripts
  if ($LASTEXITCODE -eq 0) {
    $nativeDepsInstalled = $true
  } else {
    Write-Warning "pnpm install for native modules failed. Trying npm fallback."
  }

  if (-not $nativeDepsInstalled) {
    $npmCommand = Get-Command npm -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($npmCommand) {
      $npmPath = $npmCommand.Source
      if (-not $npmPath -and $npmCommand.Path) {
        $npmPath = $npmCommand.Path
      }
      if ($npmPath) {
        & $npmPath install --prefix $TmpBuildDir --no-audit --no-fund --ignore-scripts
        if ($LASTEXITCODE -eq 0) {
          $nativeDepsInstalled = $true
        }
      }
    }
  }

  if (-not $nativeDepsInstalled) {
    Write-Warning "Native module install failed with both pnpm and npm. Check network connectivity and your Node toolchain, then retry."
    return
  }

  # Rebuild better-sqlite3 from source for the Electron ABI.
  # Use @electron/rebuild from the shared tools directory (installed by Ensure-Tooling).
  $rebuildCli = Join-Path $ToolsDir "node_modules\@electron\rebuild\lib\cli.js"
  if (-not (Test-Path $rebuildCli)) {
    $rebuildCli = Join-Path $ToolsDir "node_modules\.bin\electron-rebuild.cmd"
  }
  & node $rebuildCli --version $ElectronVersion --module-dir $TmpBuildDir --only better-sqlite3 --force
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "better-sqlite3 rebuild failed. Ensure Python 3 and Visual Studio Build Tools (Desktop C++ workload with MSVC v143 and Windows SDK) are installed."
    return
  }

  # Copy rebuilt better-sqlite3 into the app
  $rebuiltSqlite = Join-Path $TmpBuildDir "node_modules\better-sqlite3\build\Release\better_sqlite3.node"
  if (-not (Test-Path $rebuiltSqlite)) {
    Write-Warning "better-sqlite3 rebuild completed but binary was not produced."
    return
  }
  Remove-Item -Recurse -Force (Join-Path $AppAsarDir "node_modules\better-sqlite3") -ErrorAction SilentlyContinue
  Copy-Item -Recurse -Force (Join-Path $TmpBuildDir "node_modules\better-sqlite3") (Join-Path $AppAsarDir "node_modules\better-sqlite3")

  # node-pty ships prebuilt N-API binaries for win32-x64 that work across
  # Node/Electron versions. Copy the whole module including prebuilds.
  $ptyPrebuilds = Join-Path $TmpBuildDir "node_modules\node-pty\prebuilds\win32-x64"
  if (Test-Path $ptyPrebuilds) {
    Remove-Item -Recurse -Force (Join-Path $AppAsarDir "node_modules\node-pty") -ErrorAction SilentlyContinue
    Copy-Item -Recurse -Force (Join-Path $TmpBuildDir "node_modules\node-pty") (Join-Path $AppAsarDir "node_modules\node-pty")
  } else {
    Write-Warning "node-pty prebuilt binaries not found. Terminal features may not work."
  }
}

function Write-Launcher {
  $cmdContent = @'
@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-codex.ps1" %*
exit /b %ERRORLEVEL%
'@

  $ps1Content = @'
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$PassThruArgs
)

$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppDir = Join-Path $RootDir "app_asar"
$LocalElectron = Join-Path $RootDir "_tools\node_modules\electron\dist\electron.exe"

if (-not (Test-Path $LocalElectron)) {
  $electronCmd = Get-Command electron -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $electronCmd) {
    throw "electron.exe not found."
  }
  $LocalElectron = $electronCmd.Source
}

$env:ELECTRON_FORCE_IS_PACKAGED = "1"
$env:NODE_ENV = "production"
$env:CODEX_HOME = $RootDir

if (-not $env:CODEX_CLI_PATH) {
  $localCli = Join-Path $RootDir "bin\codex\codex.exe"
  if (Test-Path $localCli) {
    $env:CODEX_CLI_PATH = $localCli
  } else {
    $codexCmd = Get-Command codex.cmd -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($codexCmd) {
      $cmdDir = Split-Path -Parent $codexCmd.Source
      $candidate = Join-Path $cmdDir "node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\codex\codex.exe"
      if (Test-Path $candidate) {
        $env:CODEX_CLI_PATH = $candidate
      }
    }
    if (-not $env:CODEX_CLI_PATH) {
      $codexExe = Get-Command codex.exe -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($codexExe) {
        $env:CODEX_CLI_PATH = $codexExe.Source
      }
    }
  }
}

$rgDir = Join-Path $RootDir "bin\path"
if (Test-Path $rgDir) {
  $env:PATH = "$rgDir;$env:PATH"
}

if (-not $env:CODEX_VSCODE_PATH) {
  foreach ($name in @("code.cmd", "code", "codium.cmd", "codium")) {
    $candidate = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($candidate) {
      $env:CODEX_VSCODE_PATH = $candidate.Source
      break
    }
  }
}

if (-not $env:CODEX_VSCODE_INSIDERS_PATH) {
  foreach ($name in @("code-insiders.cmd", "code-insiders", "codium-insiders.cmd", "codium-insiders")) {
    $candidate = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($candidate) {
      $env:CODEX_VSCODE_INSIDERS_PATH = $candidate.Source
      break
    }
  }
}

$launchArgs = @()
if ($env:CODEX_NO_SANDBOX -eq "1") {
  $launchArgs += "--no-sandbox"
}
$launchArgs += $AppDir
if ($PassThruArgs) {
  $launchArgs += $PassThruArgs
}

if ($env:CODEX_ATTACH -eq "1") {
  & $LocalElectron @launchArgs
  exit $LASTEXITCODE
}

Start-Process -FilePath $LocalElectron -ArgumentList $launchArgs -WorkingDirectory $RootDir
'@

  $vbsContent = @'
Option Explicit

Dim shell, fso, rootDir, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

rootDir = fso.GetParentFolderName(WScript.ScriptFullName)
command = "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & rootDir & "\run-codex.ps1"""

shell.Run command, 0, False
'@

  Set-Content -Path $RunLauncherCmd -Encoding Ascii -Value $cmdContent
  Set-Content -Path $RunLauncherPs1 -Encoding Ascii -Value $ps1Content
  Set-Content -Path $RunLauncherVbs -Encoding Ascii -Value $vbsContent
}

function Convert-PngToIco {
  param(
    [Parameter(Mandatory = $true)][string]$PngPath,
    [Parameter(Mandatory = $true)][string]$IcoPath
  )

  Add-Type -AssemblyName System.Drawing
  $img = [System.Drawing.Image]::FromFile($PngPath)
  try {
    $width = [Math]::Min($img.Width, 256)
    $height = [Math]::Min($img.Height, 256)
  }
  finally {
    $img.Dispose()
  }

  [byte[]]$pngBytes = [System.IO.File]::ReadAllBytes($PngPath)
  $stream = [System.IO.File]::Create($IcoPath)
  $writer = New-Object System.IO.BinaryWriter($stream)
  try {
    $icoWidth = if ($width -ge 256) { 0 } else { [byte]$width }
    $icoHeight = if ($height -ge 256) { 0 } else { [byte]$height }

    $writer.Write([UInt16]0)  # reserved
    $writer.Write([UInt16]1)  # type = icon
    $writer.Write([UInt16]1)  # count

    $writer.Write([byte]$icoWidth)
    $writer.Write([byte]$icoHeight)
    $writer.Write([byte]0)    # colors
    $writer.Write([byte]0)    # reserved
    $writer.Write([UInt16]1)  # color planes
    $writer.Write([UInt16]32) # bpp
    $writer.Write([UInt32]$pngBytes.Length)
    $writer.Write([UInt32]22) # file offset
    $writer.Write($pngBytes)
  }
  finally {
    $writer.Close()
    $stream.Close()
  }
}

function Resolve-LogoPng {
  $roots = @($DmgExtractDir, $AppAsarDir)
  $candidates = @()

  foreach ($root in $roots) {
    if (-not (Test-Path $root)) {
      continue
    }
    $candidates += Get-ChildItem -Path $root -Recurse -File -Include "*.png" -ErrorAction SilentlyContinue |
      Where-Object {
        $_.Name -match "(?i)(codex|logo|icon|appicon)" -or
        $_.DirectoryName -match "(?i)(icon|resources|assets)"
      }
  }

  if (-not $candidates -or $candidates.Count -eq 0) {
    return ""
  }

  $best = $candidates |
    Sort-Object `
      @{ Expression = { [int]($_.FullName -match "(?i)(appicon|codex)") }; Descending = $true }, `
      @{ Expression = { $_.Length }; Descending = $true } |
    Select-Object -First 1

  return $best.FullName
}

function Ensure-LauncherIcon {
  if (-not $Force -and (Test-Path $LauncherIcon)) {
    return $LauncherIcon
  }

  $pngPath = Resolve-LogoPng
  if (-not $pngPath) {
    Write-Warning "Could not locate a Codex logo PNG in extracted files."
    return ""
  }

  try {
    Convert-PngToIco -PngPath $pngPath -IcoPath $LauncherIcon
    return $LauncherIcon
  }
  catch {
    Write-Warning "Failed to generate launcher icon from $pngPath"
    return ""
  }
}

function Ensure-Shortcut {
  if ($NoShortcut) {
    Write-Warning "Skipping Start Menu shortcut (-NoShortcut)."
    return
  }

  Write-Section "Creating Start Menu shortcut"
  $iconPath = Ensure-LauncherIcon

  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ShortcutPath) | Out-Null
  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($ShortcutPath)
  $shortcut.TargetPath = "$env:SystemRoot\System32\wscript.exe"
  $shortcut.Arguments = "`"$RunLauncherVbs`""
  $shortcut.WorkingDirectory = $RootDir
  if ($iconPath) {
    $shortcut.IconLocation = "$iconPath,0"
  } else {
    $shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,220"
  }
  $shortcut.Save()
}

function Ensure-CodexCli {
  if (-not (Have "codex")) {
    Write-Section "Installing @openai/codex CLI"
    & pnpm setup | Out-Null
    if (-not $env:PNPM_HOME) {
      $env:PNPM_HOME = "$env:LOCALAPPDATA\pnpm"
    }
    Invoke-External -FilePath "pnpm" -Arguments @("add", "-g", "@openai/codex")
  }

  # Locate the native codex.exe binary inside the npm/pnpm global packages
  # and copy it to $RootDir\bin\ so the launcher can reference it directly.
  # The npm wrapper scripts (codex.cmd / codex.ps1) are NOT usable by the
  # Electron app which needs the real PE executable.
  $binDir = Join-Path $RootDir "bin"
  $targetExe = Join-Path $binDir "codex\codex.exe"
  if (Test-Path $targetExe) {
    return
  }

  Write-Section "Locating native codex.exe"
  $nativeExe = $null
  $searchRoots = @(
    "$env:APPDATA\npm\node_modules\@openai\codex",
    "$env:LOCALAPPDATA\pnpm\global\5\node_modules\@openai\codex",
    "$env:LOCALAPPDATA\pnpm\global\node_modules\@openai\codex"
  )
  foreach ($root in $searchRoots) {
    $candidate = Join-Path $root "node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\codex\codex.exe"
    if (Test-Path $candidate) {
      $nativeExe = $candidate
      break
    }
  }

  # Fallback: search recursively from npm global prefix
  if (-not $nativeExe) {
    $npmPrefix = (& npm.cmd prefix -g 2>$null)
    if ($npmPrefix) {
      $found = Get-ChildItem -Path $npmPrefix -Recurse -File -Filter "codex.exe" -ErrorAction SilentlyContinue |
               Where-Object { $_.FullName -match 'codex-win32' } |
               Select-Object -First 1
      if ($found) { $nativeExe = $found.FullName }
    }
  }

  if (-not $nativeExe) {
    Write-Warning "Could not locate native codex.exe. The Electron app may prompt for CODEX_CLI_PATH."
    return
  }

  # Copy the entire vendor arch directory so companion binaries
  # (codex-command-runner.exe, codex-windows-sandbox-setup.exe) and the
  # path directory (rg.exe) are available next to codex.exe.
  $vendorArchDir = Split-Path -Parent (Split-Path -Parent $nativeExe)
  New-Item -ItemType Directory -Force -Path $binDir | Out-Null
  Copy-Item -Recurse -Force (Join-Path $vendorArchDir "codex") (Join-Path $binDir "codex")
  $vendorPathDir = Join-Path $vendorArchDir "path"
  if (Test-Path $vendorPathDir) {
    Copy-Item -Recurse -Force $vendorPathDir (Join-Path $binDir "path")
  }
  Write-Host "Copied native codex binaries to $binDir"
}

function Print-NextSteps([string]$ElectronVersion) {
  Write-Section "Done"
  Write-Host "Electron : $ElectronVersion"
  Write-Host "Launcher : $RunLauncherVbs"
  Write-Host "CLI      : $RunLauncherCmd"
  Write-Host "RootDir  : $RootDir"
  if (-not $NoShortcut) {
    Write-Host "Shortcut : $ShortcutPath"
  }
  Write-Host ""
  Write-Host "Start Codex:"
  Write-Host "  $RunLauncherVbs"
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
