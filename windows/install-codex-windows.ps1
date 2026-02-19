$ErrorActionPreference = "Stop"

$repoUrl = "https://github.com/nassimna/codex-linux-launcher"
$archiveUrl = "$repoUrl/archive/refs/heads/main.zip"
$tmpDir = Join-Path $env:TEMP ("codex-windows-installer-" + [guid]::NewGuid().ToString("N"))
$zipPath = Join-Path $tmpDir "source.zip"
$extractDir = Join-Path $tmpDir "source"

try {
  $localBridge = Join-Path $PSScriptRoot "codex-windows-bridge.ps1"
  if (Test-Path $localBridge) {
    Write-Host "Using local bridge script: $localBridge"
    $shellExe = if (Get-Command powershell -ErrorAction SilentlyContinue) {
      "powershell"
    }
    elseif (Get-Command pwsh -ErrorAction SilentlyContinue) {
      "pwsh"
    }
    else {
      throw "Neither 'powershell' nor 'pwsh' is available."
    }

    & $shellExe -NoProfile -ExecutionPolicy Bypass -File $localBridge @args
    if ($LASTEXITCODE -ne 0) {
      throw "codex-windows-bridge.ps1 exited with code $LASTEXITCODE"
    }
    return
  }

  New-Item -ItemType Directory -Force -Path $tmpDir, $extractDir | Out-Null

  Write-Host "Downloading codex-linux-launcher archive..."
  $oldProgressPreference = $ProgressPreference
  try {
    # Speed up download in Windows PowerShell by suppressing progress rendering.
    $ProgressPreference = "SilentlyContinue"
    Invoke-WebRequest -Uri $archiveUrl -OutFile $zipPath
  }
  finally {
    $ProgressPreference = $oldProgressPreference
  }
  Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

  $scriptPath = Join-Path $extractDir "codex-linux-launcher-main\windows\codex-windows-bridge.ps1"
  if (-not (Test-Path $scriptPath)) {
    throw "Archive does not include windows/codex-windows-bridge.ps1"
  }

  $shellExe = if (Get-Command powershell -ErrorAction SilentlyContinue) {
    "powershell"
  }
  elseif (Get-Command pwsh -ErrorAction SilentlyContinue) {
    "pwsh"
  }
  else {
    throw "Neither 'powershell' nor 'pwsh' is available."
  }

  & $shellExe -NoProfile -ExecutionPolicy Bypass -File $scriptPath @args
  if ($LASTEXITCODE -ne 0) {
    throw "codex-windows-bridge.ps1 exited with code $LASTEXITCODE"
  }
}
finally {
  Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
}
