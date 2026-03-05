#!/usr/bin/env bash
set -euo pipefail

APP_NAME="openai-codex-linux"
APP_VERSION="1.2.1"
APP_DISPLAY_NAME="OpenAI Codex"
DMG_URL="${DMG_URL:-https://persistent.oaistatic.com/codex-app-prod/Codex.dmg}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-${XDG_DOWNLOAD_DIR:-$HOME/Downloads}/$APP_NAME}"
DMG_PATH="${DMG_PATH:-$DOWNLOAD_DIR/Codex.dmg}"
ROOT_DIR="${ROOT_APP_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/$APP_NAME}"
TOOLS_DIR="$ROOT_DIR/_tools"
TMP_BUILD_DIR="$ROOT_DIR/_native-build"
DMG_EXTRACT_DIR="$ROOT_DIR/dmg_extracted"
APP_ASAR_DIR="$ROOT_DIR/app_asar"
DMG_SIGNATURE_FILE="$ROOT_DIR/.dmg.signature"
RUN_LAUNCHER="$ROOT_DIR/run-codex.sh"
DESKTOP_ENTRY_PATH="${DESKTOP_ENTRY_PATH:-$HOME/.local/share/applications/$APP_NAME.desktop}"
STATE_BACKUP_DIR="${STATE_BACKUP_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/${APP_NAME}-backups}"
STATE_BACKUP_RETENTION="${STATE_BACKUP_RETENTION:-10}"
ENABLE_STATE_BACKUP="${ENABLE_STATE_BACKUP:-1}"
DMG_EXTRACT_BIN=""
DMG_PATH_WAS_SET=0

FORCE="${FORCE:-0}"
SKIP_SYSTEM_DEPS="${SKIP_SYSTEM_DEPS:-0}"
ELECTRON_VERSION_OVERRIDE="${FORCE_ELECTRON_VERSION:-}"
INSTALL_DESKTOP_ENTRY="${INSTALL_DESKTOP_ENTRY:-1}"

refresh_paths() {
  TOOLS_DIR="$ROOT_DIR/_tools"
  TMP_BUILD_DIR="$ROOT_DIR/_native-build"
  DMG_EXTRACT_DIR="$ROOT_DIR/dmg_extracted"
  APP_ASAR_DIR="$ROOT_DIR/app_asar"
  DMG_SIGNATURE_FILE="$ROOT_DIR/.dmg.signature"
  RUN_LAUNCHER="$ROOT_DIR/run-codex.sh"
}

usage() {
  cat <<'EOF'
Usage:
  ./codex-linux-bridge.sh [options]

Options:
  --help                   Show this help and exit
  --force                  Re-extract and rebuild even when unchanged
  --skip-system-deps       Do not install missing apt/pacman/dnf/etc packages
  --root-dir PATH          Override workspace path (default: ~/.local/share/openai-codex-linux)
  --download-dir PATH      Override DMG download folder (default: ~/Downloads/openai-codex-linux)
  --dmg-path PATH          Override Codex.dmg file path
  --force-electron-version  Override detected Electron version
  --install-desktop        Write/overwrite desktop launcher (default: on)
  --no-desktop             Skip desktop launcher creation
  --state-backup-dir PATH  Override state snapshot directory
  --no-state-backup        Disable automatic state snapshot/restore

Environment:
  FORCE, SKIP_SYSTEM_DEPS, ROOT_APP_DIR, DOWNLOAD_DIR, DMG_PATH, FORCE_ELECTRON_VERSION,
  INSTALL_DESKTOP_ENTRY, STATE_BACKUP_DIR, STATE_BACKUP_RETENTION, ENABLE_STATE_BACKUP

Examples:
  ./codex-linux-bridge.sh --force
  SKIP_SYSTEM_DEPS=1 ./codex-linux-bridge.sh
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help)
        usage
        exit 0
        ;;
      --force)
        FORCE=1
        ;;
      --skip-system-deps)
        SKIP_SYSTEM_DEPS=1
        ;;
      --root-dir)
        shift
        ROOT_DIR="${1:?missing value for --root-dir}"
        ROOT_APP_DIR="$ROOT_DIR"
        ;;
      --download-dir)
        shift
        DOWNLOAD_DIR="${1:?missing value for --download-dir}"
        DMG_PATH=""
        ;;
      --dmg-path)
        shift
        DMG_PATH="${1:?missing value for --dmg-path}"
        DMG_PATH_WAS_SET=1
        ;;
      --install-desktop)
        INSTALL_DESKTOP_ENTRY=1
        ;;
      --no-desktop)
        INSTALL_DESKTOP_ENTRY=0
        ;;
      --state-backup-dir)
        shift
        STATE_BACKUP_DIR="${1:?missing value for --state-backup-dir}"
        ;;
      --no-state-backup)
        ENABLE_STATE_BACKUP=0
        ;;
      --force-electron-version)
        shift
        ELECTRON_VERSION_OVERRIDE="${1:?missing value for --force-electron-version}"
        FORCE_ELECTRON_VERSION="$ELECTRON_VERSION_OVERRIDE"
        ;;
      --*)
        fail "Unknown option: $1"
        ;;
      *)
        fail "Unexpected argument: $1"
        ;;
    esac
    shift
  done

  if [ "$DMG_PATH_WAS_SET" -ne 1 ]; then
    DMG_PATH="$DOWNLOAD_DIR/Codex.dmg"
  fi

  refresh_paths
}

log() { echo; echo "=== $* ==="; }
warn() { echo "WARN: $*" >&2; }
fail() { echo "ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

show_system() {
  log "System check"
  echo "OS        : $(. /etc/os-release 2>/dev/null; echo "${NAME:-$ID:-unknown}")"
  echo "Kernel    : $(uname -r)"
  echo "Arch      : $(uname -m)"
  echo "HOME      : $HOME"
  echo "Shell     : $SHELL"
}

package_manager() {
  if have pacman; then
    echo pacman
  elif have apt-get; then
    echo apt
  elif have dnf; then
    echo dnf
  elif have zypper; then
    echo zypper
  elif have apk; then
    echo apk
  else
    echo unknown
  fi
}

package_for_tool() {
  local pm="$1" tool="$2"
  case "$pm" in
    pacman)
      case "$tool" in
        curl) echo curl ;;
        git) echo git ;;
        node) echo nodejs ;;
        npm) echo npm ;;
        pnpm) echo pnpm ;;
        python|python3) echo python ;;
        make) echo base-devel ;;
        gcc|g++) echo base-devel ;;
        7z) echo p7zip ;;
        *) echo "$tool" ;;
      esac
      ;;
    apt)
      case "$tool" in
        curl) echo curl ;;
        git) echo git ;;
        node) echo nodejs ;;
        npm|pnpm) echo "$tool" ;;
        make) echo make ;;
        gcc) echo gcc ;;
        g++) echo g++ ;;
        7z) echo p7zip-full ;;
        python|python3) echo python3 ;;
        *) echo "$tool" ;;
      esac
      ;;
    dnf|zypper)
      case "$tool" in
        curl) echo curl ;;
        git) echo git ;;
        node) echo nodejs ;;
        npm|pnpm) echo "$tool" ;;
        make) echo make ;;
        gcc) echo gcc ;;
        g++) echo gcc-c++ ;;
        7z) echo p7zip ;;
        python|python3) echo python3 ;;
        *) echo "$tool" ;;
      esac
      ;;
    apk)
      case "$tool" in
        curl) echo curl ;;
        git) echo git ;;
        node) echo nodejs ;;
        npm|pnpm) echo "$tool" ;;
        make) echo make ;;
        gcc|g++) echo build-base ;;
        7z) echo p7zip ;;
        python|python3) echo python3 ;;
        *) echo "$tool" ;;
      esac
      ;;
    *)
      echo "$tool"
      ;;
  esac
}

install_system_packages() {
  if [ "$SKIP_SYSTEM_DEPS" = "1" ]; then
    warn "SKIP_SYSTEM_DEPS=1, skipping automatic dependency installation"
    return
  fi

  local pm="$1"; shift
  local -a packages=("$@")

  case "$pm" in
    pacman)
      sudo pacman -S --needed "${packages[@]}"
      ;;
    apt)
      sudo apt-get update
      sudo apt-get install -y "${packages[@]}"
      ;;
    dnf)
      sudo dnf install -y "${packages[@]}"
      ;;
    zypper)
      sudo zypper install -y "${packages[@]}"
      ;;
    apk)
      sudo apk add --no-cache "${packages[@]}"
      ;;
    *)
      warn "Unknown package manager. Install missing dependencies manually: ${packages[*]}"
      ;;
  esac
}

ensure_system_dependencies() {
  log "System dependencies"
  local required=(curl git node npm make gcc g++ python3 7z)
  local missing=()
  local -A seen=()

  local cmd pkg
  for cmd in "${required[@]}"; do
    if ! have "$cmd"; then
      missing+=("$cmd")
    fi
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    return
  fi

  local pm
  pm="$(package_manager)"
  if [ "$pm" = "unknown" ]; then
    warn "Unknown package manager. Install manually: ${missing[*]}"
    return
  fi

  local -a packages=()
  for cmd in "${missing[@]}"; do
    if [ -z "${seen[$cmd]+x}" ]; then
      seen[$cmd]=1
      pkg="$(package_for_tool "$pm" "$cmd")"
      if [ -n "$pkg" ]; then
        packages+=("$pkg")
      fi
    fi
  done

  log "Installing missing packages via $pm: ${packages[*]}"
  install_system_packages "$pm" "${packages[@]}"
}

ensure_pnpm() {
  if have pnpm; then
    return
  fi

  if have corepack; then
    corepack enable >/dev/null 2>&1 || true
    corepack prepare pnpm@latest --activate || fail "Could not activate pnpm via corepack"
    return
  fi

  if have npm; then
    warn "Installing pnpm globally using npm"
    npm i -g pnpm
    return
  fi

  fail "Could not install pnpm automatically (no npm/corepack)."
}

ensure_archive_tool() {
  if have 7z; then
    DMG_EXTRACT_BIN="$(command -v 7z)"
    return
  fi

  local vendor="$ROOT_DIR/.vendor"
  local tarball="$vendor/7z-linux-x64.tar.xz"
  local work="$vendor/7z-extract"
  mkdir -p "$vendor"

  if [ -x "$vendor/7zz" ]; then
    DMG_EXTRACT_BIN="$vendor/7zz"
    return
  fi

  warn "7z/p7zip missing: downloading 7-Zip CLI fallback"
  curl -L --fail --retry 3 --retry-delay 2 \
    -o "$tarball" \
    "https://www.7-zip.org/a/7z2409-linux-x64.tar.xz"

  mkdir -p "$work"
  rm -rf "$work"/*
  tar -xJf "$tarball" -C "$work"

  local candidate
  candidate="$(find "$work" -type f \( -name 7zz -o -name 7z \) | head -n 1 || true)"
  [ -n "$candidate" ] || fail "Fallback 7-Zip archive does not contain 7zz/7z"

  cp "$candidate" "$vendor/7zz"
  chmod +x "$vendor/7zz"
  DMG_EXTRACT_BIN="$vendor/7zz"
}

state_items() {
  cat <<'EOF'
.codex-global-state.json
.credentials.json
auth.json
config.toml
history.jsonl
models_cache.json
sessions
sqlite
shell_snapshots
skills
EOF
}

prune_state_backups() {
  [ -d "$STATE_BACKUP_DIR" ] || return 0

  local keep="$STATE_BACKUP_RETENTION"
  if ! [[ "$keep" =~ ^[0-9]+$ ]]; then
    keep=10
  fi
  if [ "$keep" -lt 1 ]; then
    keep=1
  fi

  local -a snapshots=()
  mapfile -t snapshots < <(find "$STATE_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r)
  local count="${#snapshots[@]}"

  if [ "$count" -le "$keep" ]; then
    return 0
  fi

  local idx
  for ((idx = keep; idx < count; idx += 1)); do
    rm -rf "$STATE_BACKUP_DIR/${snapshots[$idx]}"
  done
}

backup_user_state_snapshot() {
  [ "$ENABLE_STATE_BACKUP" = "1" ] || return 0

  local -a existing=()
  local item
  while IFS= read -r item; do
    if [ -e "$ROOT_DIR/$item" ]; then
      existing+=("$item")
    fi
  done < <(state_items)

  if [ "${#existing[@]}" -eq 0 ]; then
    return 0
  fi

  mkdir -p "$STATE_BACKUP_DIR"
  local stamp
  local dest
  stamp="$(date +%Y%m%d-%H%M%S)"
  dest="$STATE_BACKUP_DIR/$stamp"
  mkdir -p "$dest"

  for item in "${existing[@]}"; do
    cp -a "$ROOT_DIR/$item" "$dest/"
  done

  cat > "$dest/.backup-meta" <<EOF
created_at=$(date -Iseconds)
root_dir=$ROOT_DIR
app_name=$APP_NAME
EOF

  prune_state_backups
}

restore_user_state_from_latest_backup() {
  [ "$ENABLE_STATE_BACKUP" = "1" ] || return 0
  [ -d "$STATE_BACKUP_DIR" ] || return 0

  if [ -f "$ROOT_DIR/history.jsonl" ] || [ -d "$ROOT_DIR/sessions" ] || [ -f "$ROOT_DIR/.codex-global-state.json" ]; then
    return 0
  fi

  local latest
  latest="$(find "$STATE_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r | head -n 1 || true)"
  if [ -z "$latest" ]; then
    return 0
  fi

  local src="$STATE_BACKUP_DIR/$latest"
  local restored=0
  local item
  while IFS= read -r item; do
    if [ -e "$src/$item" ] && [ ! -e "$ROOT_DIR/$item" ]; then
      cp -a "$src/$item" "$ROOT_DIR/"
      restored=$((restored + 1))
    fi
  done < <(state_items)

  if [ "$restored" -gt 0 ]; then
    log "Restored user state from backup snapshot: $src"
  fi
}

find_and_extract_asar() {
  local current_sig
  current_sig="$(sha256sum "$DMG_PATH" | awk '{print $1}')"
  local prev_sig=""
  if [ -f "$DMG_SIGNATURE_FILE" ]; then
    prev_sig="$(cat "$DMG_SIGNATURE_FILE")"
  fi

  if [ "$FORCE" != "1" ] && [ "$current_sig" = "$prev_sig" ] && [ -f "$APP_ASAR_DIR/package.json" ]; then
    log "DMG unchanged, skipping app.asar extraction"
    return
  fi

  log "Extracting Codex.dmg"
  rm -rf "$DMG_EXTRACT_DIR" "$APP_ASAR_DIR"
  mkdir -p "$DMG_EXTRACT_DIR"
  "$DMG_EXTRACT_BIN" x -y -aoa "$DMG_PATH" -o"$DMG_EXTRACT_DIR"

  local app_asar
  app_asar="$(find "$DMG_EXTRACT_DIR" -type f -name app.asar -print | head -n 1 || true)"
  if [ -z "$app_asar" ]; then
    fail "Could not locate app.asar inside DMG"
  fi

  mkdir -p "$APP_ASAR_DIR"
  node "$TOOLS_DIR/node_modules/asar/bin/asar.js" extract "$app_asar" "$APP_ASAR_DIR"
  echo "$current_sig" > "$DMG_SIGNATURE_FILE"
}

patch_main_js_linux_open_target() {
  local -a main_files=()
  if [ -d "$APP_ASAR_DIR/.vite/build" ]; then
    while IFS= read -r file; do
      main_files+=("$file")
    done < <(find "$APP_ASAR_DIR/.vite/build" -maxdepth 1 -type f \( -name 'main.js' -o -name 'main-*.js' \) -print | sort)
  fi

  if [ "${#main_files[@]}" -eq 0 ]; then
    warn "No main bundle found; skipping Linux editor patch"
    return
  fi

  log "Patching app bundle for Linux external editor targets (VS Code, file targets)"
  local main_js
  for main_js in "${main_files[@]}"; do
    node - <<'NODE' "$main_js"
const fs = require('node:fs');
const vm = require('node:vm');
const path = process.argv[2];
let source = fs.readFileSync(path, 'utf8');
const original = source;
const applied = [];

function applyReplacement(name, from, to) {
  if (!source.includes(from)) return false;
  source = source.replace(from, () => to);
  applied.push(name);
  return true;
}

function applyRegexReplacement(name, re, replacement) {
  const next = source.replace(re, replacement);
  if (next === source) return false;
  source = next;
  applied.push(name);
  return true;
}

applyReplacement(
  "legacy-macos-guard",
  'if(!Yr)throw new Error("Opening external editors is only supported on macOS");',
  'if(process.platform==="win32")throw new Error("Opening external editors is not supported on Windows yet");'
);

applyReplacement(
  "legacy-editor-list-guard",
  'async function oN(){if(!Yr)return[];',
  'async function oN(){'
);

const oldSp = 'function Sp(t){try{const e=Dn.spawnSync("which",[t],{encoding:"utf8",timeout:1e3}),n=e.stdout?.trim();if(e.status===0&&n&&Ee.existsSync(n))return n}catch(e){li().debug("Failed to locate command in PATH",{safe:{command:t},sensitive:{error:e}})}return null}';
const oldSpNoMacGuard = 'function Sp(t){if(!Yr)return null;try{const e=Dn.spawnSync("which",[t],{encoding:"utf8",timeout:1e3}),n=e.stdout?.trim();if(e.status===0&&n&&Ee.existsSync(n))return n}catch(e){li().debug("Failed to locate command in PATH",{safe:{command:t},sensitive:{error:e}})}return null}';
const newSp = `function Sp(t){const n=[t,\`/usr/bin/\${t}\`,\`/usr/local/bin/\${t}\`,\`/usr/share/code/bin/\${t}\`,\`/usr/share/codium/bin/\${t}\`,\`/opt/visual-studio-code/bin/\${t}\`,\`/opt/visual-studio-codium/bin/\${t}\`,\`/snap/bin/\${t}\`,\`\${process.env.HOME ?? ""}/.local/bin/\${t}\`,\`\${process.env.HOME ?? ""}/bin/\${t}\`].filter(Boolean);for(const i of n){if(i.includes("/")&&Ee.existsSync(i))return i;try{const e=Dn.spawnSync(\"which\",[i],{encoding:\"utf8\",timeout:1e3}),r=e.stdout?.trim();if(e.status===0&&r&&Ee.existsSync(r))return r}catch(e){li().debug(\"Failed to locate command in PATH\",{safe:{},sensitive:{command:i,error:e}})}}return null}`;

applyReplacement("legacy-sp", oldSp, newSp);
applyReplacement("legacy-sp-no-macos-guard", oldSpNoMacGuard, newSp);

const vscodeDetect = 'detect:()=>Sp("code")||Sp("codium")||sn(["/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code","/Applications/Code.app/Contents/Resources/app/bin/code"])';
const vscodeDetectFromBundle = 'detect:()=>sn(["/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code","/Applications/Code.app/Contents/Resources/app/bin/code"])';
const vscodeInsiderDetect = 'detect:()=>Sp("code-insiders")||Sp("codium-insiders")||sn(["/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code","/Applications/Code - Insiders.app/Contents/Resources/app/bin/code"])';
const vscodeInsiderDetectFromBundle = 'detect:()=>sn(["/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code","/Applications/Code - Insiders.app/Contents/Resources/app/bin/code"])';
const vscodeReplacement = `detect:()=>{const i=process.env.CODEX_VSCODE_PATH?.trim();if(i&&Ee.existsSync(i))return i;const t=Sp("code")||Sp("codium");if(t)return t;return sn(["/var/lib/flatpak/exports/bin/com.visualstudio.code","/var/lib/flatpak/exports/bin/com.vscodium.codium","${process.env.HOME ?? ""}/.local/share/flatpak/exports/bin/com.visualstudio.code","${process.env.HOME ?? ""}/.local/share/flatpak/exports/bin/com.vscodium.codium","${process.env.HOME ?? ""}/.local/bin/code","${process.env.HOME ?? ""}/.local/bin/codium","/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code","/Applications/Code.app/Contents/Resources/app/bin/code"])}`;
const vscodeInsiderReplacement = `detect:()=>{const i=process.env.CODEX_VSCODE_INSIDERS_PATH?.trim();if(i&&Ee.existsSync(i))return i;const t=Sp("code-insiders")||Sp("codium-insiders");if(t)return t;return sn(["/usr/bin/code-insiders","/usr/local/bin/code-insiders","/snap/bin/code-insiders","${process.env.HOME ?? ""}/.local/bin/code-insiders","/var/lib/flatpak/exports/bin/com.visualstudio.code-insiders","${process.env.HOME ?? ""}/.local/share/flatpak/exports/bin/com.visualstudio.code-insiders","/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code","/Applications/Code - Insiders.app/Contents/Resources/app/bin/code"])}`;

applyReplacement("legacy-vscode-detect", vscodeDetect, vscodeReplacement);
applyReplacement("legacy-vscode-detect-bundle", vscodeDetectFromBundle, vscodeReplacement);
applyReplacement("legacy-vscode-insiders-detect", vscodeInsiderDetect, vscodeInsiderReplacement);
applyReplacement("legacy-vscode-insiders-detect-bundle", vscodeInsiderDetectFromBundle, vscodeInsiderReplacement);

const qcOld = 'function Qc({id:t,label:e,icon:n,darwinDetect:r,win32Detect:i,darwinEnv:o,darwinArgs:s}){return{id:t,platforms:{darwin:r?{label:e,icon:n,kind:"editor",detect:r,env:o,args:s??N_}:void 0,win32:i?{label:e,icon:n,kind:"editor",detect:i,args:N_}:void 0}}}';
const qcNew = 'function Qc({id:t,label:e,icon:n,darwinDetect:r,win32Detect:i,linuxDetect:a,darwinEnv:o,darwinArgs:s,linuxEnv:c,linuxArgs:u,linuxOpen:l}){return{id:t,platforms:{darwin:r?{label:e,icon:n,kind:"editor",detect:r,env:o,args:s??N_}:void 0,win32:i?{label:e,icon:n,kind:"editor",detect:i,args:N_}:void 0,linux:a?{label:e,icon:n,kind:"editor",detect:a,env:c,args:u??N_,open:l}:void 0}}}';
applyReplacement("new-qc-linux-support", qcOld, qcNew);

const gleOld = 'const Gle=Qc({id:"vscode",label:"VS Code",icon:"apps/vscode.png",darwinDetect:()=>rn(["/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code","/Applications/Code.app/Contents/Resources/app/bin/code"]),win32Detect:qle});function qle(){return n2({pathCommand:zr("code"),executableName:"Code.exe",installDirName:"Microsoft VS Code"})}';
const gleNew = 'const Gle=Qc({id:"vscode",label:"VS Code",icon:"apps/vscode.png",darwinDetect:()=>rn(["/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code","/Applications/Code.app/Contents/Resources/app/bin/code"]),win32Detect:qle,linuxDetect:__codexVSCodeLinuxDetect,linuxArgs:__codexVSCodeLinuxArgs,linuxOpen:__codexVSCodeLinuxOpen});function qle(){return n2({pathCommand:zr("code"),executableName:"Code.exe",installDirName:"Microsoft VS Code"})}function __codexVSCodeLinuxDetect(){const t=process.env.CODEX_VSCODE_PATH?.trim();if(t&&H.existsSync(t))return t;const e=["/usr/bin/code","/usr/local/bin/code","/usr/share/code/bin/code","/opt/visual-studio-code/bin/code","/usr/bin/codium","/usr/local/bin/codium","/usr/share/codium/bin/codium","/opt/visual-studio-codium/bin/codium","/snap/bin/code","/snap/bin/codium",`${process.env.HOME??""}/.local/bin/code`,`${process.env.HOME??""}/.local/bin/codium`,`${process.env.HOME??""}/.local/share/flatpak/exports/bin/com.visualstudio.code`,`${process.env.HOME??""}/.local/share/flatpak/exports/bin/com.vscodium.codium`,`/var/lib/flatpak/exports/bin/com.visualstudio.code`,`/var/lib/flatpak/exports/bin/com.vscodium.codium`].filter(Boolean);for(const n of e)if(H.existsSync(n))return n;return zr("code")||zr("codium")||null}function __codexVSCodeLinuxArgs(t,e){return e?["--goto",`${t}:${e.line}:${e.column}`]:[t]}async function __codexVSCodeLinuxOpen({command:t,path:e,location:n}){const r=__codexVSCodeLinuxArgs(e,n);try{await pr(t,r)}catch{await pr(t,[e])}}';
applyReplacement("new-vscode-linux-detect", gleOld, gleNew);

const hleOld = 'const Hle=Qc({id:"vscodeInsiders",label:"VS Code Insiders",icon:"apps/vscode-insiders.png",darwinDetect:()=>rn(["/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code","/Applications/Code - Insiders.app/Contents/Resources/app/bin/code"]),win32Detect:Wle});function Wle(){return n2({pathCommand:zr("code-insiders"),executableName:"Code - Insiders.exe",installDirName:"Microsoft VS Code Insiders"})}';
const hleNew = 'const Hle=Qc({id:"vscodeInsiders",label:"VS Code Insiders",icon:"apps/vscode-insiders.png",darwinDetect:()=>rn(["/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code","/Applications/Code - Insiders.app/Contents/Resources/app/bin/code"]),win32Detect:Wle,linuxDetect:__codexVSCodeInsidersLinuxDetect,linuxArgs:__codexVSCodeLinuxArgs,linuxOpen:__codexVSCodeLinuxOpen});function Wle(){return n2({pathCommand:zr("code-insiders"),executableName:"Code - Insiders.exe",installDirName:"Microsoft VS Code Insiders"})}function __codexVSCodeInsidersLinuxDetect(){const t=process.env.CODEX_VSCODE_INSIDERS_PATH?.trim();if(t&&H.existsSync(t))return t;const e=["/usr/bin/code-insiders","/usr/local/bin/code-insiders","/snap/bin/code-insiders",`${process.env.HOME??""}/.local/bin/code-insiders`,`${process.env.HOME??""}/.local/share/flatpak/exports/bin/com.visualstudio.code-insiders`,`/var/lib/flatpak/exports/bin/com.visualstudio.code-insiders`].filter(Boolean);for(const n of e)if(H.existsSync(n))return n;return zr("code-insiders")||zr("codium-insiders")||null}';
applyReplacement("new-vscode-insiders-linux-detect", hleOld, hleNew);

const cuOld = 'function cu({id:t,label:e,icon:n,darwinDetect:r,win32Detect:i,darwinEnv:o,darwinArgs:s}){return{id:t,platforms:{darwin:r?{label:e,icon:n,kind:"editor",detect:r,env:o,args:s??Lv}:void 0,win32:i?{label:e,icon:n,kind:"editor",detect:i,args:Lv}:void 0}}}';
const cuNew = 'function cu({id:t,label:e,icon:n,darwinDetect:r,win32Detect:i,linuxDetect:a,darwinEnv:o,darwinArgs:s,linuxEnv:c,linuxArgs:u,linuxOpen:l}){return{id:t,platforms:{darwin:r?{label:e,icon:n,kind:"editor",detect:r,env:o,args:s??Lv}:void 0,win32:i?{label:e,icon:n,kind:"editor",detect:i,args:Lv}:void 0,linux:a?{label:e,icon:n,kind:"editor",detect:a,env:c,args:u??Lv,open:l}:void 0}}}';
applyReplacement("new-cu-linux-support", cuOld, cuNew);

const xmeOld = 'const Xme=cu({id:"vscode",label:"VS Code",icon:"apps/vscode.png",darwinDetect:()=>an(["/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code","/Applications/Code.app/Contents/Resources/app/bin/code"]),win32Detect:Jme});function Jme(){return OV({pathCommand:Wr("code"),executableName:"Code.exe",installDirName:"Microsoft VS Code"})}';
const xmeNew = 'const Xme=cu({id:"vscode",label:"VS Code",icon:"apps/vscode.png",darwinDetect:()=>an(["/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code","/Applications/Code.app/Contents/Resources/app/bin/code"]),win32Detect:Jme,linuxDetect:__codexVSCodeLinuxDetect,linuxArgs:__codexVSCodeLinuxArgs,linuxOpen:__codexVSCodeLinuxOpen});function Jme(){return OV({pathCommand:Wr("code"),executableName:"Code.exe",installDirName:"Microsoft VS Code"})}function __codexVSCodeLinuxDetect(){const t=process.env.CODEX_VSCODE_PATH?.trim();if(t&&Je.existsSync(t))return t;const e=["/usr/bin/code","/usr/local/bin/code","/usr/share/code/bin/code","/opt/visual-studio-code/bin/code","/usr/bin/codium","/usr/local/bin/codium","/usr/share/codium/bin/codium","/opt/visual-studio-codium/bin/codium","/snap/bin/code","/snap/bin/codium",`${process.env.HOME??""}/.local/bin/code`,`${process.env.HOME??""}/.local/bin/codium`,`${process.env.HOME??""}/.local/share/flatpak/exports/bin/com.visualstudio.code`,`${process.env.HOME??""}/.local/share/flatpak/exports/bin/com.vscodium.codium`,`/var/lib/flatpak/exports/bin/com.visualstudio.code`,`/var/lib/flatpak/exports/bin/com.vscodium.codium`].filter(Boolean);for(const n of e)if(Je.existsSync(n))return n;return Wr("code")||Wr("codium")||null}function __codexVSCodeLinuxArgs(t,e){return e?["--goto",`${t}:${e.line}:${e.column}`]:[t]}async function __codexVSCodeLinuxOpen({command:t,path:e,location:n}){const r=__codexVSCodeLinuxArgs(e,n);try{await dr(t,r)}catch{await dr(t,[e])}}';
applyReplacement("new-vscode-linux-detect-alt", xmeOld, xmeNew);

const qmeOld = 'const Qme=cu({id:"vscodeInsiders",label:"VS Code Insiders",icon:"apps/vscode-insiders.png",darwinDetect:()=>an(["/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code","/Applications/Code - Insiders.app/Contents/Resources/app/bin/code"]),win32Detect:ehe});function ehe(){return OV({pathCommand:Wr("code-insiders"),executableName:"Code - Insiders.exe",installDirName:"Microsoft VS Code Insiders"})}';
const qmeNew = 'const Qme=cu({id:"vscodeInsiders",label:"VS Code Insiders",icon:"apps/vscode-insiders.png",darwinDetect:()=>an(["/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code","/Applications/Code - Insiders.app/Contents/Resources/app/bin/code"]),win32Detect:ehe,linuxDetect:__codexVSCodeInsidersLinuxDetect,linuxArgs:__codexVSCodeLinuxArgs,linuxOpen:__codexVSCodeLinuxOpen});function ehe(){return OV({pathCommand:Wr("code-insiders"),executableName:"Code - Insiders.exe",installDirName:"Microsoft VS Code Insiders"})}function __codexVSCodeInsidersLinuxDetect(){const t=process.env.CODEX_VSCODE_INSIDERS_PATH?.trim();if(t&&Je.existsSync(t))return t;const e=["/usr/bin/code-insiders","/usr/local/bin/code-insiders","/snap/bin/code-insiders",`${process.env.HOME??""}/.local/bin/code-insiders`,`${process.env.HOME??""}/.local/share/flatpak/exports/bin/com.visualstudio.code-insiders`,`/var/lib/flatpak/exports/bin/com.visualstudio.code-insiders`].filter(Boolean);for(const n of e)if(Je.existsSync(n))return n;return Wr("code-insiders")||Wr("codium-insiders")||null}';
applyReplacement("new-vscode-insiders-linux-detect-alt", qmeOld, qmeNew);

const lpeOld = 'async function lpe(t,e,n){const r=eu.find(o=>o.id===t);if(!r)throw new Error(`Unknown open target "${t}"`);const i=r.detect();if(!i)throw new Error(`Open target "${t}" is not available`);if(r.open){await r.open({command:i,path:e,location:n});return}await pr(i,r.args(e,n),{env:r.env?.()})}';
const lpePatched = 'async function lpe(t,e,n){const r=eu.find(o=>o.id===t);if(!r)throw new Error(`Unknown open target "${t}"`);const i=r.detect();if(!i)throw new Error(`Open target "${t}" is not available`);if(t==="vscodeInsiders"&&process.platform==="linux"){const a=r.args(e,n),c=[process.env.CODEX_VSCODE_INSIDERS_PATH,i,"/usr/bin/code-insiders","code-insiders"].filter(Boolean);for(const u of c)try{await pr(u,a,{env:r.env?.()});return}catch{}throw new Error("Open target \\"vscodeInsiders\\" is not available")}if(r.open){await r.open({command:i,path:e,location:n});return}await pr(i,r.args(e,n),{env:r.env?.()})}';
const lpeNew = 'async function lpe(t,e,n){const r=eu.find(o=>o.id===t);if(!r)throw new Error(`Unknown open target "${t}"`);if(t==="vscodeInsiders"&&process.platform==="linux"){const i=r.args(e,n),a=[process.env.CODEX_VSCODE_INSIDERS_PATH,r.detect(),"/usr/bin/code-insiders","/usr/local/bin/code-insiders","/snap/bin/code-insiders",`${process.env.HOME??""}/.local/bin/code-insiders`,`/var/lib/flatpak/exports/bin/com.visualstudio.code-insiders`,`${process.env.HOME??""}/.local/share/flatpak/exports/bin/com.visualstudio.code-insiders`,"code-insiders","codium-insiders"].filter(Boolean);for(const c of a)try{await pr(c,i,{env:r.env?.()});return}catch{try{await pr(c,[e],{env:r.env?.()});return}catch{}}throw new Error("Open target \\"vscodeInsiders\\" is not available")}const i=r.detect();if(!i)throw new Error(`Open target "${t}" is not available`);if(r.open){await r.open({command:i,path:e,location:n});return}await pr(i,r.args(e,n),{env:r.env?.()})}';
applyReplacement("new-lpe-vscode-insiders-open", lpeOld, lpeNew);
applyReplacement("new-lpe-vscode-insiders-open-repatch", lpePatched, lpeNew);

const _heOld = 'async function _he(t,e,n){const r=uu.find(o=>o.id===t);if(!r)throw new Error(`Unknown open target "${t}"`);const i=r.detect();if(!i)throw new Error(`Open target "${t}" is not available`);if(r.open){await r.open({command:i,path:e,location:n});return}await dr(i,r.args(e,n),{env:r.env?.()})}';
const _heNew = 'async function _he(t,e,n){const r=uu.find(o=>o.id===t);if(!r)throw new Error(`Unknown open target "${t}"`);if(t==="vscodeInsiders"&&process.platform==="linux"){const i=r.args(e,n),a=[process.env.CODEX_VSCODE_INSIDERS_PATH,r.detect(),"/usr/bin/code-insiders","/usr/local/bin/code-insiders","/snap/bin/code-insiders",`${process.env.HOME??""}/.local/bin/code-insiders`,`/var/lib/flatpak/exports/bin/com.visualstudio.code-insiders`,`${process.env.HOME??""}/.local/share/flatpak/exports/bin/com.visualstudio.code-insiders`,"code-insiders","codium-insiders"].filter(Boolean);for(const c of a)try{await dr(c,i,{env:r.env?.()});return}catch{try{await dr(c,[e],{env:r.env?.()});return}catch{}}throw new Error("Open target \\"vscodeInsiders\\" is not available")}const i=r.detect();if(!i)throw new Error(`Open target "${t}" is not available`);if(r.open){await r.open({command:i,path:e,location:n});return}await dr(i,r.args(e,n),{env:r.env?.()})}';
applyReplacement("new-open-target-vscode-insiders-alt", _heOld, _heNew);

const vfeOld = 'async function vfe(t,e,n){if(!Yr)throw new Error("Opening external editors is only supported on macOS");const r=bp.find(a=>a.id===t);if(!r)throw new Error(`Unknown open target "${t}"`);const i=r.detect();if(!i)throw new Error(`Open target "${t}" is not available`);if(!(sfe(t)&&await hfe(t,e))){if(t==="xcode"){await afe(e,n);return}if(t==="zed"){await Sfe(i,e,n);return}await ai(i,r.args(e,n),{env:r.env?.()})}}';
const vfePatched = 'async function vfe(t,e,n){if(process.platform==="win32")throw new Error("Opening external editors is not supported on Windows yet");const r=bp.find(a=>a.id===t);if(!r)throw new Error(`Unknown open target "${t}"`);const i=r.detect();if(!i)throw new Error(`Open target "${t}" is not available`);if(!(sfe(t)&&await hfe(t,e))){if(t==="vscodeInsiders"){const a=r.args(e,n),o=[process.env.CODEX_VSCODE_INSIDERS_PATH,i,"/usr/bin/code-insiders","code-insiders"].filter(Boolean);for(const s of o)try{await ai(s,a,{env:r.env?.()});return}catch{}throw new Error("Open target \\"vscodeInsiders\\" is not available")}if(t==="xcode"){await afe(e,n);return}if(t==="zed"){await Sfe(i,e,n);return}await ai(i,r.args(e,n),{env:r.env?.()})}}';
const vfeNew = 'async function vfe(t,e,n){if(process.platform==="win32")throw new Error("Opening external editors is not supported on Windows yet");const r=bp.find(a=>a.id===t);if(!r)throw new Error(`Unknown open target "${t}"`);if(t==="vscodeInsiders"){const i=r.args(e,n),a=[process.env.CODEX_VSCODE_INSIDERS_PATH,r.detect(),"/usr/bin/code-insiders","/usr/local/bin/code-insiders","/snap/bin/code-insiders",`${process.env.HOME??""}/.local/bin/code-insiders`,`/var/lib/flatpak/exports/bin/com.visualstudio.code-insiders`,`${process.env.HOME??""}/.local/share/flatpak/exports/bin/com.visualstudio.code-insiders`,"code-insiders","codium-insiders"].filter(Boolean);for(const o of a)try{await ai(o,i,{env:r.env?.()});return}catch{try{await ai(o,[e],{env:r.env?.()});return}catch{}}throw new Error("Open target \\"vscodeInsiders\\" is not available")}const i=r.detect();if(!i)throw new Error(`Open target "${t}" is not available`);if(!(sfe(t)&&await hfe(t,e))){if(t==="xcode"){await afe(e,n);return}if(t==="zed"){await Sfe(i,e,n);return}await ai(i,r.args(e,n),{env:r.env?.()})}}';
applyReplacement("legacy-vfe-vscode-insiders-open", vfeOld, vfeNew);
applyReplacement("legacy-vfe-vscode-insiders-open-repatch", vfePatched, vfeNew);

const modernEditorFactoryRe = /function ([A-Za-z_$][\w$]*)\(\{id:([A-Za-z_$][\w$]*),label:([A-Za-z_$][\w$]*),icon:([A-Za-z_$][\w$]*),darwinDetect:([A-Za-z_$][\w$]*),win32Detect:([A-Za-z_$][\w$]*),darwinEnv:([A-Za-z_$][\w$]*),darwinArgs:([A-Za-z_$][\w$]*)\}\)\{return\{id:\2,platforms:\{darwin:\5\?\{label:\3,icon:\4,kind:"editor",detect:\5,env:\7,args:\8\?\?([A-Za-z_$][\w$]*)\}:void 0,win32:\6\?\{label:\3,icon:\4,kind:"editor",detect:\6,args:\9\}:void 0\}\}\}/;
applyRegexReplacement(
  "modern-editor-factory-linux-support",
  modernEditorFactoryRe,
  (_, fnName, idVar, labelVar, iconVar, darwinVar, win32Var, darwinEnvVar, darwinArgsVar, defaultArgsVar) =>
    `function ${fnName}({id:${idVar},label:${labelVar},icon:${iconVar},darwinDetect:${darwinVar},win32Detect:${win32Var},linuxDetect:a,darwinEnv:${darwinEnvVar},darwinArgs:${darwinArgsVar},linuxEnv:c,linuxArgs:u,linuxOpen:l}){return{id:${idVar},platforms:{darwin:${darwinVar}?{label:${labelVar},icon:${iconVar},kind:"editor",detect:${darwinVar},env:${darwinEnvVar},args:${darwinArgsVar}??${defaultArgsVar}}:void 0,win32:${win32Var}?{label:${labelVar},icon:${iconVar},kind:"editor",detect:${win32Var},args:${defaultArgsVar}}:void 0,linux:a?{label:${labelVar},icon:${iconVar},kind:"editor",detect:a,env:c,args:u??${defaultArgsVar},open:l}:void 0}}}`
);

const modernVSCodeTargetRe = /const ([A-Za-z_$][\w$]*)=([A-Za-z_$][\w$]*)\(\{id:"vscode",label:"VS Code",icon:"apps\/vscode\.png",([^}]*)\}\);/;
applyRegexReplacement(
  "modern-vscode-linux-target",
  modernVSCodeTargetRe,
  (full, constVar, factoryVar, props) => {
    if (props.includes("linuxDetect:")) return full;
    const cleanProps = props.endsWith(",") ? props.slice(0, -1) : props;
    return `const ${constVar}=${factoryVar}({id:"vscode",label:"VS Code",icon:"apps/vscode.png",${cleanProps},linuxDetect:__codexVSCodeLinuxDetect,linuxArgs:__codexVSCodeLinuxArgs,linuxOpen:__codexVSCodeLinuxOpen});`;
  }
);

const modernVSCodeInsidersTargetRe = /const ([A-Za-z_$][\w$]*)=([A-Za-z_$][\w$]*)\(\{id:"vscodeInsiders",label:"VS Code Insiders",icon:"apps\/vscode-insiders\.png",([^}]*)\}\);/;
applyRegexReplacement(
  "modern-vscode-insiders-linux-target",
  modernVSCodeInsidersTargetRe,
  (full, constVar, factoryVar, props) => {
    if (props.includes("linuxDetect:")) return full;
    const cleanProps = props.endsWith(",") ? props.slice(0, -1) : props;
    return `const ${constVar}=${factoryVar}({id:"vscodeInsiders",label:"VS Code Insiders",icon:"apps/vscode-insiders.png",${cleanProps},linuxDetect:__codexVSCodeInsidersLinuxDetect,linuxArgs:__codexVSCodeLinuxArgs,linuxOpen:__codexVSCodeLinuxOpen});`;
  }
);

const modernFileManagerTargetRe = /const ([A-Za-z_$][\w$]*)=([A-Za-z_$][\w$]*)\(\{id:"fileManager",label:"Finder",icon:"apps\/finder\.png",kind:"fileManager",darwin:\{detect:\(\)=>"open",args:t=>([A-Za-z_$][\w$]*)\(t\)\},win32:\{label:"Explorer",icon:"apps\/file-explorer\.png",detect:([A-Za-z_$][\w$]*),args:t=>[A-Za-z_$][\w$]*\(t\),open:async\(\{path:t\}\)=>([A-Za-z_$][\w$]*)\(t\)\}\}\);/;
applyRegexReplacement(
  "modern-file-manager-linux-target",
  modernFileManagerTargetRe,
  (_, constVar, factoryVar, argsFn, winDetectFn, winOpenFn) =>
    `const ${constVar}=${factoryVar}({id:"fileManager",label:"Finder",icon:"apps/finder.png",kind:"fileManager",darwin:{detect:()=>"open",args:t=>${argsFn}(t)},win32:{label:"Explorer",icon:"apps/file-explorer.png",detect:${winDetectFn},args:t=>${argsFn}(t),open:async({path:t})=>${winOpenFn}(t)},linux:{label:"File Manager",icon:"apps/file-explorer.png",detect:__codexFileManagerLinuxDetect,args:t=>__codexFileManagerLinuxArgs(t)}});`
);

if (!source.includes("function __codexVSCodeLinuxDetect()")) {
  const modernHelperInsertRe = /function ([A-Za-z_$][\w$]*)\(\)\{return ([A-Za-z_$][\w$]*)\(\{pathCommand:([A-Za-z_$][\w$]*)\("code-insiders"\),executableName:"Code - Insiders\.exe",installDirName:"Microsoft VS Code Insiders"\}\)\}/;
  applyRegexReplacement(
    "modern-vscode-linux-helper-inject",
    modernHelperInsertRe,
    (full, insidersWinFn, winResolveFn, whichFn) =>
      `${full}function __codexVSCodeLinuxDetect(){const t=process.env.CODEX_VSCODE_PATH?.trim();if(t)return t;return ${whichFn}("code")||${whichFn}("codium")||null}function __codexVSCodeInsidersLinuxDetect(){const t=process.env.CODEX_VSCODE_INSIDERS_PATH?.trim();if(t)return t;return ${whichFn}("code-insiders")||${whichFn}("codium-insiders")||null}function __codexVSCodeLinuxArgs(t,e){return e?["--goto",\`${"${t}:${e.line}:${e.column}"}\`]:[t]}async function __codexVSCodeLinuxOpen({command:t,path:e,location:n}){const r=__codexVSCodeLinuxArgs(e,n);try{await gr(t,r)}catch{await gr(t,[e])}}`
  );
}

if (!source.includes("function __codexFileManagerLinuxDetect()")) {
  const fileManagerHelperInsertRe = /function ([A-Za-z_$][\w$]*)\(t\)\{let e=t;for\(;;\)\{if\(([A-Za-z_$][\w$]*)\.existsSync\(e\)\)return e;const n=([A-Za-z_$][\w$]*)\.dirname\(e\);if\(n===e\)return null;e=n\}\}/;
  applyRegexReplacement(
    "modern-file-manager-linux-helper-inject",
    fileManagerHelperInsertRe,
    (full, nearestExistingFn, fsVar, pathVar) =>
      `${full}function __codexFileManagerLinuxDetect(){return process.platform==="linux"?"xdg-open":null}function __codexFileManagerLinuxArgs(t){const e=${nearestExistingFn}(t)??t;try{return [${fsVar}.existsSync(e)&&${fsVar}.statSync(e).isDirectory()?e:${pathVar}.dirname(e)]}catch{return [${pathVar}.dirname(e)]}}`
  );
}

if (source !== original) {
  vm.createScript(source, { filename: path });
  fs.writeFileSync(path, source);
  console.log(`[codex-linux] Linux editor patch applied (${path}): ${applied.join(", ")}`);
} else {
  console.log(`[codex-linux] Linux editor patch skipped (${path}): no matching patterns found.`);
}
NODE
  done
}

patch_background_terminal_stop() {
  local webview_index web_bundle_rel web_bundle

  webview_index="$APP_ASAR_DIR/webview/index.html"
  web_bundle_rel=""
  web_bundle=""

  if [ -f "$webview_index" ]; then
    web_bundle_rel="$(grep -oE 'assets/index-[^"]+\.js' "$webview_index" | head -n 1 || true)"
  fi

  if [ -n "$web_bundle_rel" ] && [ -f "$APP_ASAR_DIR/webview/$web_bundle_rel" ]; then
    web_bundle="$APP_ASAR_DIR/webview/$web_bundle_rel"
  else
    web_bundle="$(find "$APP_ASAR_DIR/webview/assets" -maxdepth 1 -name 'index-*.js' -type f -print | head -n 1 || true)"
  fi

  if [ -z "$web_bundle" ]; then
    warn "No webview index-*.js bundle found; skipping background terminal Stop patch"
    return
  fi

  node - <<'NODE' "$web_bundle"
const fs = require("node:fs");

const bundlePath = process.argv[2];
if (!bundlePath) process.exit(0);

let source = fs.readFileSync(bundlePath, "utf8");
const original = source;

function findMatchingBrace(text, openBraceIndex) {
  let depth = 0;
  let inSingle = false;
  let inDouble = false;
  let inTemplate = false;
  let escape = false;
  for (let i = openBraceIndex; i < text.length; i += 1) {
    const ch = text[i];
    if (escape) {
      escape = false;
      continue;
    }
    if (ch === "\\") {
      escape = true;
      continue;
    }
    if (inSingle) {
      if (ch === "'") inSingle = false;
      continue;
    }
    if (inDouble) {
      if (ch === '"') inDouble = false;
      continue;
    }
    if (inTemplate) {
      if (ch === "`") inTemplate = false;
      continue;
    }
    if (ch === "'") {
      inSingle = true;
      continue;
    }
    if (ch === '"') {
      inDouble = true;
      continue;
    }
    if (ch === "`") {
      inTemplate = true;
      continue;
    }
    if (ch === "{") depth += 1;
    if (ch === "}") {
      depth -= 1;
      if (depth === 0) return i;
    }
  }
  return -1;
}

let patchedStopButton = false;
let patchedCleanupHandler = false;

const dispatcherMatch = source.match(/([A-Za-z_$][\w$]*)\.dispatchMessage\("terminal-close",\{sessionId:/);
const dispatchVar = dispatcherMatch?.[1] ?? null;

const panelPropsMatch = source.match(/backgroundTerminals:([A-Za-z_$][\w$]*),isCleaningBackgroundTerminals:([A-Za-z_$][\w$]*),onCleanBackgroundTerminals:([A-Za-z_$][\w$]*)/);
if (panelPropsMatch) {
  const [, terminalsVar, , stopVar] = panelPropsMatch;
  const stopAssignRe = new RegExp(`${stopVar}=\\(\\)=>\\{`);
  const stopAssignMatch = stopAssignRe.exec(source);
  if (stopAssignMatch) {
    const fnStart = stopAssignMatch.index;
    const openBrace = source.indexOf("{", fnStart);
    const closeBrace = findMatchingBrace(source, openBrace);
    if (openBrace !== -1 && closeBrace !== -1) {
      const fnSource = source.slice(fnStart, closeBrace + 1);
      if (!fnSource.includes(`(${terminalsVar}).catch(()=>{`)) {
        const cleanCallMatch = fnSource.match(
          /([A-Za-z_$][\w$]*)\(\)\.catch\(\(\)=>\{[A-Za-z_$][\w$]*\.danger\([A-Za-z_$][\w$]*\.formatMessage\(\{id:"composer\.cleanBackgroundTerminals\.error"/
        );
        if (cleanCallMatch) {
          const cleanFnVar = cleanCallMatch[1];
          const patchedFnSource = fnSource.replace(
            `${cleanFnVar}().catch(()=>{`,
            `${cleanFnVar}(${terminalsVar}).catch(()=>{`
          );
          if (patchedFnSource !== fnSource) {
            source = source.slice(0, fnStart) + patchedFnSource + source.slice(closeBrace + 1);
            patchedStopButton = true;
          }
        }
      }
    }
  }
}

if (dispatchVar) {
  const cleanHandlerRefMatch = source.match(/onStop:([A-Za-z_$][\w$]*),onCleanBackgroundTerminals:([A-Za-z_$][\w$]*)/);
  if (cleanHandlerRefMatch) {
    const cleanHandlerVar = cleanHandlerRefMatch[2];
    const cleanHandlerRe = new RegExp(
      `${cleanHandlerVar}=async\\(\\)=>\\{([A-Za-z_$][\\\\w$]*)\\?\\.type==="local"&&await ([A-Za-z_$][\\\\w$]*)\\.cleanBackgroundTerminals\\(\\1\\.localConversationId\\)\\}`
    );
    source = source.replace(cleanHandlerRe, (_, followUpVar, managerVar) => {
      patchedCleanupHandler = true;
      return `${cleanHandlerVar}=async(H)=>{if(${followUpVar}?.type!=="local")return;await ${managerVar}.cleanBackgroundTerminals(${followUpVar}.localConversationId);for(const B of(H??[])){const z=B?.id;typeof z=="string"&&z.length>0&&${dispatchVar}.dispatchMessage("terminal-close",{sessionId:z})}}`;
    });
  }
}

if (source !== original) {
  fs.writeFileSync(bundlePath, source);
  const updates = [];
  if (patchedStopButton) updates.push("stop-click handler");
  if (patchedCleanupHandler) updates.push("cleanup handler");
  console.log(`[codex-linux] Patched background terminal stop fallback (${updates.join(", ")}).`);
}
NODE
}

patch_plan_mode_indicator() {
  local webview_index web_bundle_rel web_bundle

  webview_index="$APP_ASAR_DIR/webview/index.html"
  web_bundle_rel=""
  web_bundle=""

  if [ -f "$webview_index" ]; then
    web_bundle_rel="$(grep -oE 'assets/index-[^"]+\.js' "$webview_index" | head -n 1 || true)"
  fi

  if [ -n "$web_bundle_rel" ] && [ -f "$APP_ASAR_DIR/webview/$web_bundle_rel" ]; then
    web_bundle="$APP_ASAR_DIR/webview/$web_bundle_rel"
  else
    web_bundle="$(find "$APP_ASAR_DIR/webview/assets" -maxdepth 1 -name 'index-*.js' -type f -print | head -n 1 || true)"
  fi

  if [ -z "$web_bundle" ]; then
    warn "No webview index-*.js bundle found; skipping Plan mode indicator patch"
    return
  fi

  node - <<'NODE' "$web_bundle"
const fs = require("node:fs");

const bundlePath = process.argv[2];
if (!bundlePath) process.exit(0);

let source = fs.readFileSync(bundlePath, "utf8");
const original = source;

function findMatchingBrace(text, openBraceIndex) {
  let depth = 0;
  let inSingle = false;
  let inDouble = false;
  let inTemplate = false;
  let escape = false;
  for (let i = openBraceIndex; i < text.length; i += 1) {
    const ch = text[i];
    if (escape) {
      escape = false;
      continue;
    }
    if (ch === "\\") {
      escape = true;
      continue;
    }
    if (inSingle) {
      if (ch === "'") inSingle = false;
      continue;
    }
    if (inDouble) {
      if (ch === '"') inDouble = false;
      continue;
    }
    if (inTemplate) {
      if (ch === "`") inTemplate = false;
      continue;
    }
    if (ch === "'") {
      inSingle = true;
      continue;
    }
    if (ch === '"') {
      inDouble = true;
      continue;
    }
    if (ch === "`") {
      inTemplate = true;
      continue;
    }
    if (ch === "{") depth += 1;
    if (ch === "}") {
      depth -= 1;
      if (depth === 0) return i;
    }
  }
  return -1;
}

let patchedMethod = false;
let patchedHook = false;

const methodAnchor = "async setLatestCollaborationModeForConversation(";
const methodStart = source.indexOf(methodAnchor);
if (methodStart === -1) {
  console.log("[codex-linux] Plan mode indicator patch skipped: method not found.");
} else {
  const methodOpenBrace = source.indexOf("{", methodStart);
  if (methodOpenBrace === -1) {
    console.log("[codex-linux] Plan mode indicator patch skipped: malformed method.");
  } else {
    const methodCloseBrace = findMatchingBrace(source, methodOpenBrace);
    if (methodCloseBrace === -1) {
      console.log("[codex-linux] Plan mode indicator patch skipped: unbalanced method.");
    } else {
      const methodSource = source.slice(methodStart, methodCloseBrace + 1);
      if (
        !methodSource.includes("try{await this.sendThreadFollowerRequest(") ||
        !methodSource.includes("}finally{this.updateConversationState(")
      ) {
        const methodPattern = /^async setLatestCollaborationModeForConversation\(([^,]+),([^\)]+)\)\{const ([^=]+)=this\.getStreamRole\(\1\);await this\.sendThreadFollowerRequest\(\3,"thread-follower-set-collaboration-mode",\{conversationId:\1,collaborationMode:\2\}\)(\|\||,)this\.updateConversationState\(\1,([^=]+)=>\{\5\.latestCollaborationMode=\2\}\)\}$/;
        const match = methodSource.match(methodPattern);
        if (!match) {
          console.log("[codex-linux] Plan mode indicator patch skipped: expected method pattern not found.");
        } else {
          const [, conversationVar, modeVar, roleVar, , stateVar] = match;
          const patchedMethodSource = `async setLatestCollaborationModeForConversation(${conversationVar},${modeVar}){const ${roleVar}=this.getStreamRole(${conversationVar});try{await this.sendThreadFollowerRequest(${roleVar},"thread-follower-set-collaboration-mode",{conversationId:${conversationVar},collaborationMode:${modeVar}})}finally{this.updateConversationState(${conversationVar},${stateVar}=>{${stateVar}.latestCollaborationMode=${modeVar}})}}`;
          source = source.slice(0, methodStart) + patchedMethodSource + source.slice(methodCloseBrace + 1);
          patchedMethod = true;
        }
      }
    }
  }
}

const hookAnchor = "function n2(t=null){";
const hookStart = source.indexOf(hookAnchor);
if (hookStart === -1) {
  console.log("[codex-linux] Plan mode indicator patch skipped: hook not found.");
} else {
  const hookOpenBrace = source.indexOf("{", hookStart);
  if (hookOpenBrace === -1) {
    console.log("[codex-linux] Plan mode indicator patch skipped: malformed hook.");
  } else {
    const hookCloseBrace = findMatchingBrace(source, hookOpenBrace);
    if (hookCloseBrace === -1) {
      console.log("[codex-linux] Plan mode indicator patch skipped: unbalanced hook.");
    } else {
      const hookSource = source.slice(hookStart, hookCloseBrace + 1);
      const hookAlreadyPatched =
        hookSource.includes("d=i??u?.mode??wU") &&
        hookSource.includes("if(s(b),Nne(),t)") &&
        hookSource.includes("return}},v=A.useEffectEvent(");
      if (!hookAlreadyPatched) {
        let patchedHookSource = hookSource;
        patchedHookSource = patchedHookSource.replace("u=n,d=u?.mode??i??wU,", "u=n,d=i??u?.mode??wU,");
        patchedHookSource = patchedHookSource.replace("p=u??f.find(b=>b.mode===d)??l,", "p=f.find(b=>b.mode===d)??u??l,");
        patchedHookSource = patchedHookSource.replace("g=b=>{if(Nne(),t){", "g=b=>{if(s(b),Nne(),t){");
        patchedHookSource = patchedHookSource.replace("})}return}s(b)},v=A.useEffectEvent(", "})}return}},v=A.useEffectEvent(");

        if (patchedHookSource === hookSource) {
          console.log("[codex-linux] Plan mode indicator patch skipped: expected hook pattern not found.");
        } else {
          source = source.slice(0, hookStart) + patchedHookSource + source.slice(hookCloseBrace + 1);
          patchedHook = true;
        }
      }
    }
  }
}

if (source !== original) {
  fs.writeFileSync(bundlePath, source);
  const updates = [];
  if (patchedMethod) updates.push("method");
  if (patchedHook) updates.push("hook");
  console.log(`[codex-linux] Patched Plan mode indicator refresh on toggle (${updates.join(", ")}).`);
}
NODE
}

patch_sidebar_active_threads() {
  local webview_index web_bundle_rel web_bundle

  webview_index="$APP_ASAR_DIR/webview/index.html"
  web_bundle_rel=""
  web_bundle=""

  if [ -f "$webview_index" ]; then
    web_bundle_rel="$(grep -oE 'assets/index-[^"]+\.js' "$webview_index" | head -n 1 || true)"
  fi

  if [ -n "$web_bundle_rel" ] && [ -f "$APP_ASAR_DIR/webview/$web_bundle_rel" ]; then
    web_bundle="$APP_ASAR_DIR/webview/$web_bundle_rel"
  else
    web_bundle="$(find "$APP_ASAR_DIR/webview/assets" -maxdepth 1 -name 'index-*.js' -type f -print | head -n 1 || true)"
  fi

  if [ -z "$web_bundle" ]; then
    warn "No webview index-*.js bundle found; skipping Active threads sidebar patch"
    return
  fi

  node - <<'NODE' "$web_bundle"
const fs = require("node:fs");

const bundlePath = process.argv[2];
if (!bundlePath) process.exit(0);

let source = fs.readFileSync(bundlePath, "utf8");
const original = source;
const applied = [];

function applyExact(name, from, to, required = true) {
  if (source.includes(to)) return true;
  if (!source.includes(from)) {
    if (required) console.log(`[codex-linux] Active threads sidebar patch: missing pattern (${name}).`);
    return !required;
  }
  source = source.replace(from, () => to);
  applied.push(name);
  return true;
}

const alreadyPatched =
  source.includes('sidebarElectron.activeThreads') &&
  source.includes("codexActiveSidebarItems=") &&
  !source.includes("toggle_active_threads") &&
  !source.includes("codexActiveSidebarItems.length>0?") &&
  source.includes("title:mn,children:f.jsx(DOe,{items:codexActiveSidebarItems");
if (alreadyPatched) process.exit(0);

let ok = true;

ok =
  applyExact(
    "cleanup-setting-key",
    'Os("sidebar-view-v2","threads"),__codexSidebarActiveFilterKey=Os("sidebar-active-thread-filter-v1","all");function $$t(){',
    'Os("sidebar-view-v2","threads");function $$t(){',
    false
  ) && ok;

ok =
  applyExact(
    "cleanup-state",
    'const{groups:Me,isWorkspaceRootOptionsLoading:Oe,workspaceRootOptions:Ue,workspaceRootLabels:He}=YUt(Ie,Re),[Ze,Xe]=cr(H$t),[codexActiveFilter,codexSetActiveFilter]=cr(__codexSidebarActiveFilterKey),codexShowActiveOnly=codexActiveFilter==="active";',
    'const{groups:Me,isWorkspaceRootOptionsLoading:Oe,workspaceRootOptions:Ue,workspaceRootLabels:He}=YUt(Ie,Re),[Ze,Xe]=cr(H$t);',
    false
  ) && ok;

ok =
  applyExact(
    "cleanup-visible-groups",
    'const gt=ft.length,yt=!Oe,dt=be.length>0,codexVisibleGroups=codexShowActiveOnly?Me.map(mn=>({...mn,tasks:mn.tasks.filter(_n=>__codexSidebarIsActiveThread(_n)||j3(_n)===x)})).filter(mn=>mn.tasks.length>0):Me,at=!Pe&&codexVisibleGroups.length===0&&_e.length===0&&!dt;',
    'const gt=ft.length,yt=!Oe,dt=be.length>0,at=!Pe&&Me.length===0&&_e.length===0&&!dt;',
    false
  ) && ok;

ok =
  applyExact(
    "cleanup-visible-items",
    'const vt=ys(Dt),Bt=Ph(),Zt=iWt({items:xe,itemsForVisibilityLookup:[...be,...xe],showRecent:Pe,hasGitRpc:Bt,workspaceTaskFilter:F,currentConversationId:S,isBackgroundSubagentsEnabled:ee}).filter(K$t),codexActiveItems=Zt.filter(mn=>__codexSidebarIsActiveThread(mn.task)||j3(mn.task)===x),codexVisibleItems=codexShowActiveOnly?codexActiveItems:Zt;',
    'const vt=ys(Dt),Bt=Ph(),Zt=iWt({items:xe,itemsForVisibilityLookup:[...be,...xe],showRecent:Pe,hasGitRpc:Bt,workspaceTaskFilter:F,currentConversationId:S,isBackgroundSubagentsEnabled:ee}).filter(K$t);',
    false
  ) && ok;

ok =
  applyExact(
    "cleanup-visible-item-usage",
    'const Ut=Pe&&SUt({items:codexVisibleItems,currentThreadKey:x,maxItems:q5e,getTask:G$t}),en=CUt({pinnedItems:be,showRecent:Pe,recentItems:codexVisibleItems,groups:codexVisibleGroups,isBackgroundSubagentsEnabled:ee}),Wt=new Map;',
    'const Ut=Pe&&SUt({items:Zt,currentThreadKey:x,maxItems:q5e,getTask:G$t}),en=CUt({pinnedItems:be,showRecent:Pe,recentItems:Zt,groups:Me,isBackgroundSubagentsEnabled:ee}),Wt=new Map;',
    false
  ) && ok;

ok =
  applyExact(
    "cleanup-group-selection",
    'if(x!=null)if(t[27]!==x||t[28]!==codexVisibleGroups){for(const mn of codexVisibleGroups)if(mn.tasks.some(_n=>j3(_n)===x)){Ft=mn.path;break}t[27]=x,t[28]=codexVisibleGroups,t[29]=Ft}else Ft=t[29];',
    'if(x!=null)if(t[27]!==x||t[28]!==Me){for(const mn of Me)if(mn.tasks.some(_n=>j3(_n)===x)){Ft=mn.path;break}t[27]=x,t[28]=Me,t[29]=Ft}else Ft=t[29];',
    false
  ) && ok;

ok =
  applyExact(
    "cleanup-toggle-button",
    'f.jsx(I$t,{groupByWorkspace:!Pe,onGroupByWorkspaceChange:mn=>{o({eventName:"codex_app_nav_clicked",metadata:{item:"toggle_recent"}}),De(mn?"threads":"recent")}}),f.jsx(Ge,{className:"h-6 rounded-md px-2 text-xs",color:codexShowActiveOnly?"secondary":"ghostActive",size:"default",onClick:()=>{o({eventName:"codex_app_nav_clicked",metadata:{item:"toggle_active_threads"}}),codexSetActiveFilter(codexShowActiveOnly?"all":"active")},children:f.jsx(q,{id:"sidebarElectron.activeOnlyToggle",defaultMessage:"Active",description:"Toggle button label to show only active threads in sidebar"})})]})',
    'f.jsx(I$t,{groupByWorkspace:!Pe,onGroupByWorkspaceChange:mn=>{o({eventName:"codex_app_nav_clicked",metadata:{item:"toggle_recent"}}),De(mn?"threads":"recent")}})]})',
    false
  ) && ok;

ok =
  applyExact(
    "cleanup-recent-render",
    'children:mn=>f.jsx(DOe,{items:codexVisibleItems,ariaLabel:mn.map(W$t).join(""),',
    'children:mn=>f.jsx(DOe,{items:Zt,ariaLabel:mn.map(W$t).join(""),',
    false
  ) && ok;

ok =
  applyExact(
    "cleanup-grouped-render",
    'groups:codexVisibleGroups,unpinnedItemByTaskKey:ge,',
    'groups:Me,unpinnedItemByTaskKey:ge,',
    false
  ) && ok;

if (!source.includes("function __codexSidebarIsActiveThread(")) {
  ok =
    applyExact(
      "ensure-active-helper",
      'function TIt(t){if(t.kind==="remote"){const e=t.task.task_status_display?.latest_turn_status_display?.turn_status;return t.task.has_unread_turn===!0||e==="in_progress"||e==="pending"}return t.kind==="local"&&t.conversation.hasUnreadTurn?!0:t.kind==="local"?TD(t.conversation):t.kind==="pending-worktree"}function WI(t){',
      'function TIt(t){if(t.kind==="remote"){const e=t.task.task_status_display?.latest_turn_status_display?.turn_status;return t.task.has_unread_turn===!0||e==="in_progress"||e==="pending"}return t.kind==="local"&&t.conversation.hasUnreadTurn?!0:t.kind==="local"?TD(t.conversation):t.kind==="pending-worktree"}function __codexSidebarIsActiveThread(t){if(t.kind==="remote"){const e=t.task.task_status_display?.latest_turn_status_display?.turn_status;return e==="in_progress"||e==="pending"}return t.kind==="local"?TD(t.conversation)||QEe(t.conversation):t.kind==="pending-worktree"}function WI(t){'
    ) && ok;
}

ok =
  applyExact(
    "inject-active-items",
    'const vt=ys(Dt),Bt=Ph(),Zt=iWt({items:xe,itemsForVisibilityLookup:[...be,...xe],showRecent:Pe,hasGitRpc:Bt,workspaceTaskFilter:F,currentConversationId:S,isBackgroundSubagentsEnabled:ee}).filter(K$t);',
    'const vt=ys(Dt),Bt=Ph(),Zt=iWt({items:xe,itemsForVisibilityLookup:[...be,...xe],showRecent:Pe,hasGitRpc:Bt,workspaceTaskFilter:F,currentConversationId:S,isBackgroundSubagentsEnabled:ee}).filter(K$t),codexActiveSidebarItems=Zt.filter(mn=>__codexSidebarIsActiveThread(mn.task)||j3(mn.task)===x);'
  ) && ok;

ok =
  applyExact(
    "upgrade-gated-active-top-section",
    '):null]})}),codexActiveSidebarItems.length>0?f.jsx("div",{className:"px-row-x",children:f.jsx(qL,{children:f.jsx(q,{id:"sidebarElectron.activeThreads",defaultMessage:"Active threads",description:"List label for active threads at the top of the sidebar",children:mn=>f.jsx(DOe,{items:codexActiveSidebarItems,ariaLabel:mn.map(W$t).join(""),currentThreadKey:x,onActivateThread:C,className:"pb-2",itemClassName:"after:block after:h-1 after:content-[\'\'] last:after:hidden",rowOptions:{mutePendingAutomation:!0,expandedSubagentParents:it,onToggleSubagentChildren:Je}})})})}):null,dt?f.jsx("div",{className:"px-row-x",children:f.jsx(qL,{children:f.jsx(q,{id:"sidebarElectron.pinnedThreads"',
    '):null]})}),f.jsx("div",{className:"px-row-x",children:f.jsx(q,{id:"sidebarElectron.activeThreads",defaultMessage:"Active threads",description:"List label for active threads at the top of the sidebar",children:mn=>f.jsx(qL,{title:mn,children:f.jsx(DOe,{items:codexActiveSidebarItems,ariaLabel:mn.map(W$t).join(""),currentThreadKey:x,onActivateThread:C,className:"pb-2",itemClassName:"after:block after:h-1 after:content-[\'\'] last:after:hidden",rowOptions:{mutePendingAutomation:!0,expandedSubagentParents:it,onToggleSubagentChildren:Je}})})})}),dt?f.jsx("div",{className:"px-row-x",children:f.jsx(qL,{children:f.jsx(q,{id:"sidebarElectron.pinnedThreads"',
    false
  ) && ok;

ok =
  applyExact(
    "upgrade-ungated-active-top-section-title",
    '):null]})}),f.jsx("div",{className:"px-row-x",children:f.jsx(qL,{children:f.jsx(q,{id:"sidebarElectron.activeThreads",defaultMessage:"Active threads",description:"List label for active threads at the top of the sidebar",children:mn=>f.jsx(DOe,{items:codexActiveSidebarItems,ariaLabel:mn.map(W$t).join(""),currentThreadKey:x,onActivateThread:C,className:"pb-2",itemClassName:"after:block after:h-1 after:content-[\'\'] last:after:hidden",rowOptions:{mutePendingAutomation:!0,expandedSubagentParents:it,onToggleSubagentChildren:Je}})})})}),dt?f.jsx("div",{className:"px-row-x",children:f.jsx(qL,{children:f.jsx(q,{id:"sidebarElectron.pinnedThreads"',
    '):null]})}),f.jsx("div",{className:"px-row-x",children:f.jsx(q,{id:"sidebarElectron.activeThreads",defaultMessage:"Active threads",description:"List label for active threads at the top of the sidebar",children:mn=>f.jsx(qL,{title:mn,children:f.jsx(DOe,{items:codexActiveSidebarItems,ariaLabel:mn.map(W$t).join(""),currentThreadKey:x,onActivateThread:C,className:"pb-2",itemClassName:"after:block after:h-1 after:content-[\'\'] last:after:hidden",rowOptions:{mutePendingAutomation:!0,expandedSubagentParents:it,onToggleSubagentChildren:Je}})})})}),dt?f.jsx("div",{className:"px-row-x",children:f.jsx(qL,{children:f.jsx(q,{id:"sidebarElectron.pinnedThreads"',
    false
  ) && ok;

ok =
  applyExact(
    "inject-active-top-section",
    '):null]})}),dt?f.jsx("div",{className:"px-row-x",children:f.jsx(qL,{children:f.jsx(q,{id:"sidebarElectron.pinnedThreads"',
    '):null]})}),f.jsx("div",{className:"px-row-x",children:f.jsx(q,{id:"sidebarElectron.activeThreads",defaultMessage:"Active threads",description:"List label for active threads at the top of the sidebar",children:mn=>f.jsx(qL,{title:mn,children:f.jsx(DOe,{items:codexActiveSidebarItems,ariaLabel:mn.map(W$t).join(""),currentThreadKey:x,onActivateThread:C,className:"pb-2",itemClassName:"after:block after:h-1 after:content-[\'\'] last:after:hidden",rowOptions:{mutePendingAutomation:!0,expandedSubagentParents:it,onToggleSubagentChildren:Je}})})})}),dt?f.jsx("div",{className:"px-row-x",children:f.jsx(qL,{children:f.jsx(q,{id:"sidebarElectron.pinnedThreads"'
  ) && ok;

if (!ok) {
  console.log("[codex-linux] Active threads sidebar patch skipped: required patterns not found.");
  process.exit(0);
}

if (source !== original) {
  fs.writeFileSync(bundlePath, source);
  console.log(`[codex-linux] Patched sidebar active threads toggle (${applied.join(", ")}).`);
}
NODE
}

patch_mcp_install_auth() {
  local mcp_bundle
  mcp_bundle="$(find "$APP_ASAR_DIR/webview/assets" -maxdepth 1 -name 'mcp-settings-*.js' -type f -print | head -n 1 || true)"

  if [ -z "$mcp_bundle" ]; then
    warn "No mcp-settings-*.js bundle found; skipping MCP install/authenticate patch"
    return
  fi

  node - <<'NODE' "$mcp_bundle"
const fs = require("node:fs");

const bundlePath = process.argv[2];
if (!bundlePath) process.exit(0);

let source = fs.readFileSync(bundlePath, "utf8");
const original = source;

const oldInstallAndAuth = 'Qe=async a=>{U(r=>({...r,[a.id]:!0})),await V(a),G(a.id)}';
const newInstallAndAuth = 'Qe=async a=>{U(r=>({...r,[a.id]:!0}));const x=!!i[a.id];await V(a);x||await ee(a.id);G(a.id)}';

if (source.includes(newInstallAndAuth)) process.exit(0);
if (!source.includes(oldInstallAndAuth)) process.exit(0);

source = source.replace(oldInstallAndAuth, newInstallAndAuth);

if (source !== original) {
  fs.writeFileSync(bundlePath, source);
  console.log("[codex-linux] Patched MCP install/authenticate click fallback.");
}
NODE
}

resolve_electron_version() {
  if [ -n "$ELECTRON_VERSION_OVERRIDE" ]; then
    echo "$ELECTRON_VERSION_OVERRIDE"
    return
  fi

  local version=""

  if [ -f "$APP_ASAR_DIR/package.json" ]; then
    version="$(node -p "try { const pkg=require('$APP_ASAR_DIR/package.json'); const v=(pkg.devDependencies?.electron || pkg.dependencies?.electron || '').replace(/^\^/, ''); if (/^[0-9]+(\\.[0-9]+){1,2}$/.test(v)) v : '' } catch { '' }" 2>/dev/null || true)"
    if [ -n "$version" ]; then
      echo "$version"
      return
    fi
  fi

  local plist
  plist="$(find "$DMG_EXTRACT_DIR" -type f -name Info.plist | head -n 1 || true)"
  if [ -n "$plist" ]; then
    local version
    version="$(awk '/CFBundleShortVersionString/{getline; if (match($0, /<string>([^<]+)<\/string>/, m)) print m[1]; exit} /CFBundleVersion/{getline; if (match($0, /<string>([^<]+)<\/string>/, m)) print m[1]; exit}' "$plist" || true)"
    if [[ "$version" == *.* ]]; then
      echo "$version"
      return
    fi
    if [ -n "$version" ]; then
      echo "$version"
      return
    fi
  fi

  if have electron; then
    electron --version | tr -d 'v'
    return
  fi

  fail "Could not resolve Electron version. Set FORCE_ELECTRON_VERSION and rerun."
}

ensure_tooling() {
  mkdir -p "$TOOLS_DIR"
  if [ ! -f "$TOOLS_DIR/package.json" ]; then
    cat > "$TOOLS_DIR/package.json" <<'__TOOLS_PKG__'
{
  "name": "codex-linux-tools",
  "private": true,
  "version": "1.0.0"
}
__TOOLS_PKG__
  fi

  if [ ! -d "$TOOLS_DIR/node_modules/asar" ]; then
    pnpm --dir "$TOOLS_DIR" add -D asar @electron/rebuild >/dev/null
  fi
}

ensure_local_electron() {
  local version="$1"
  local current="$(node -p "try { require('$TOOLS_DIR/node_modules/electron/package.json').version } catch (e) { '' }" 2>/dev/null || true)"
  local target="$version"

  if [ "$current" != "$target" ]; then
    log "Installing local Electron $target"
    if ! pnpm --dir "$TOOLS_DIR" add -D "electron@$target"; then
      if [ -n "$current" ]; then
        warn "Failed to install Electron $target; using existing local Electron $current"
        target="$current"
      else
        fail "Failed to install Electron $target and no existing local Electron is available"
      fi
    else
      current="$(node -p "try { require('$TOOLS_DIR/node_modules/electron/package.json').version } catch (e) { '' }" 2>/dev/null || true)"
      if [ -n "$current" ]; then
        target="$current"
      fi
    fi
  fi

  pnpm --dir "$TOOLS_DIR" rebuild electron || true
  ELECTRON_RUNTIME_VERSION="$target"
}

needs_native_rebuild() {
  local bnode="$APP_ASAR_DIR/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
  local pnode="$APP_ASAR_DIR/node_modules/node-pty/build/Release/pty.node"

  if [ "$FORCE" = "1" ]; then
    return 0
  fi

  if [ ! -f "$bnode" ] || [ ! -f "$pnode" ]; then
    return 1
  fi

  file "$bnode" | grep -q "ELF" || return 1
  file "$pnode" | grep -q "ELF" || return 1
  return 0
}

rebuild_native_modules() {
  local electron_version="$1"

  local bsql_version
  local pty_version

  bsql_version="$(node -p "try { require('$APP_ASAR_DIR/node_modules/better-sqlite3/package.json').version } catch (e) { '' }" 2>/dev/null || true)"
  pty_version="$(node -p "try { require('$APP_ASAR_DIR/node_modules/node-pty/package.json').version } catch (e) { '' }" 2>/dev/null || true)"

  [ -n "$bsql_version" ] || bsql_version="12.5.0"
  [ -n "$pty_version" ] || pty_version="1.1.0"

  rm -rf "$TMP_BUILD_DIR"
  mkdir -p "$TMP_BUILD_DIR"

  cat > "$TMP_BUILD_DIR/package.json" <<__NATIVE_PKG__
{
  "name": "codex-native-build",
  "private": true,
  "version": "1.0.0",
  "dependencies": {
    "better-sqlite3": "$bsql_version",
    "node-pty": "$pty_version"
  }
}
__NATIVE_PKG__

  local npm_opts=(--prefix "$TMP_BUILD_DIR" --no-audit --no-fund)

  if ! (
    export npm_config_runtime=electron
    export npm_config_target="$electron_version"
    export npm_config_disturl="https://electronjs.org/headers"
    export npm_config_build_from_source=true
    export npm_config_cache="$TMP_BUILD_DIR/.npm-cache"

    npm "${npm_opts[@]}" install
    npm "${npm_opts[@]}" rebuild better-sqlite3 node-pty
  ); then
    warn "Native rebuild failed; app may still start using existing binaries."
    return
  fi

  if [ ! -f "$TMP_BUILD_DIR/node_modules/better-sqlite3/build/Release/better_sqlite3.node" ] ||
     [ ! -f "$TMP_BUILD_DIR/node_modules/node-pty/build/Release/pty.node" ]; then
    warn "Rebuild completed but native binaries are still missing."
    return
  fi

  rm -rf "$APP_ASAR_DIR/node_modules/better-sqlite3" "$APP_ASAR_DIR/node_modules/node-pty"
  cp -aL "$TMP_BUILD_DIR/node_modules/better-sqlite3" "$APP_ASAR_DIR/node_modules/better-sqlite3"
  cp -aL "$TMP_BUILD_DIR/node_modules/node-pty" "$APP_ASAR_DIR/node_modules/node-pty"
}

write_launcher() {
  cat > "$RUN_LAUNCHER" <<'__LAUNCHER__'
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT_DIR/app_asar"
LOCAL_ELECTRON="$ROOT_DIR/_tools/node_modules/electron/dist/electron"

json_string_field() {
  local key="$1"
  local file="$2"
  sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\\([^\"]\\+\\)\".*/\\1/p" "$file" | head -n 1
}

update_command_hint() {
  local candidates=(
    "$HOME/codex-launcher/linux/codex-linux-bridge.sh"
    "$HOME/codex-linux-launcher/linux/codex-linux-bridge.sh"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [ -x "$candidate" ]; then
      printf '%s --force' "$candidate"
      return 0
    fi
  done
  printf '%s' "codex-linux-bridge.sh --force"
}

notify_update_available() {
  local installed_version="$1"
  local installed_build="$2"
  local latest_version="$3"
  local latest_build="$4"
  local title="Codex update available"
  local update_cmd
  update_cmd="$(update_command_hint)"
  local body
  printf -v body 'Installed: %s (build %s)\nLatest: %s (build %s)\nRun: %s' \
    "$installed_version" "$installed_build" "$latest_version" "$latest_build" "$update_cmd"

  if command -v notify-send >/dev/null 2>&1; then
    notify-send -a "OpenAI Codex" "$title" "$body" || true
  fi

  printf 'INFO: %s\n%s\n' "$title" "$body" >&2
}

notify_up_to_date() {
  local installed_version="$1"
  local installed_build="$2"
  local latest_version="$3"
  local latest_build="$4"
  local title="Codex is up to date"
  local body
  printf -v body 'Installed: %s (build %s)\nLatest: %s (build %s)' \
    "$installed_version" "$installed_build" "$latest_version" "$latest_build"

  if command -v notify-send >/dev/null 2>&1; then
    notify-send -a "OpenAI Codex" "$title" "$body" || true
  fi

  printf 'INFO: %s\n%s\n' "$title" "$body" >&2
}

check_for_updates_once() {
  [ "${CODEX_UPDATE_CHECK:-1}" = "1" ] || return 0
  command -v curl >/dev/null 2>&1 || return 0

  local package_json="$APP_DIR/package.json"
  [ -f "$package_json" ] || return 0

  local local_version
  local local_build
  local feed_url
  local appcast
  local remote_build
  local remote_version

  local_version="$(json_string_field "version" "$package_json")"
  local_build="$(json_string_field "codexBuildNumber" "$package_json")"
  feed_url="$(json_string_field "codexSparkleFeedUrl" "$package_json")"

  [ -n "$feed_url" ] || feed_url="https://persistent.oaistatic.com/codex-app-prod/appcast.xml"
  [[ "$local_build" =~ ^[0-9]+$ ]] || return 0

  appcast="$(curl -fsSL --connect-timeout 3 --max-time 6 "$feed_url" 2>/dev/null || true)"
  [ -n "$appcast" ] || return 0

  remote_build="$(printf '%s\n' "$appcast" | sed -n 's#.*<sparkle:version>\([0-9][0-9]*\)</sparkle:version>.*#\1#p' | head -n 1)"
  remote_version="$(printf '%s\n' "$appcast" | sed -n 's#.*<sparkle:shortVersionString>\([^<][^<]*\)</sparkle:shortVersionString>.*#\1#p' | head -n 1)"

  [[ "$remote_build" =~ ^[0-9]+$ ]] || return 0
  [ -n "$remote_version" ] || remote_version="unknown"

  if [ "$remote_build" -gt "$local_build" ]; then
    notify_update_available "$local_version" "$local_build" "$remote_version" "$remote_build"
  elif [ "${CODEX_UPDATE_NOTIFY_NO_UPDATES:-1}" = "1" ]; then
    notify_up_to_date "$local_version" "$local_build" "$remote_version" "$remote_build"
  fi
}

check_for_updates_async() {
  (check_for_updates_once) &
}

if [ ! -x "$LOCAL_ELECTRON" ]; then
  if command -v electron >/dev/null 2>&1; then
    LOCAL_ELECTRON="$(command -v electron)"
  else
    echo "ERROR: electron not found." >&2
    exit 1
  fi
fi

export ELECTRON_FORCE_IS_PACKAGED=1
export NODE_ENV=production
export CODEX_HOME="$ROOT_DIR"

if [ -z "${CODEX_CLI_PATH:-}" ] && command -v codex >/dev/null 2>&1; then
  export CODEX_CLI_PATH="$(command -v codex)"
fi

if [ -z "${CODEX_VSCODE_PATH:-}" ]; then
  for candidate in "$(command -v code 2>/dev/null || true)" "$(command -v codium 2>/dev/null || true)" "/usr/bin/code" "/usr/local/bin/code" "/usr/share/code/bin/code" "/opt/visual-studio-code/bin/code" "/usr/share/codium/bin/codium" "/opt/visual-studio-codium/bin/codium" "${HOME}/.local/bin/code" "${HOME}/.local/bin/codium" "/snap/bin/code" "/snap/bin/codium" "/var/lib/flatpak/exports/bin/com.visualstudio.code" "/var/lib/flatpak/exports/bin/com.vscodium.codium" "${HOME}/.local/share/flatpak/exports/bin/com.visualstudio.code" "${HOME}/.local/share/flatpak/exports/bin/com.vscodium.codium"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && export CODEX_VSCODE_PATH="$candidate" && break
  done
fi

if [ -z "${CODEX_VSCODE_INSIDERS_PATH:-}" ]; then
  for candidate in "$(command -v code-insiders 2>/dev/null || true)" "$(command -v codium-insiders 2>/dev/null || true)" "/usr/bin/code-insiders" "/usr/local/bin/code-insiders" "/snap/bin/code-insiders" "${HOME}/.local/bin/code-insiders" "/var/lib/flatpak/exports/bin/com.visualstudio.code-insiders" "${HOME}/.local/share/flatpak/exports/bin/com.visualstudio.code-insiders"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && export CODEX_VSCODE_INSIDERS_PATH="$candidate" && break
  done
fi

auto_heal_open_targets() {
  [ "${CODEX_PATCH_AUTO_HEAL:-1}" = "1" ] || return 0

  local main_bundle="$APP_DIR/.vite/build/main.js"
  [ -f "$main_bundle" ] || return 0

  node - <<'NODE' "$main_bundle"
const fs = require("node:fs");

const bundlePath = process.argv[2];
if (!bundlePath) process.exit(0);

let source = fs.readFileSync(bundlePath, "utf8");
const original = source;

function applyRegex(re, replacement) {
  const next = source.replace(re, replacement);
  if (next === source) return false;
  source = next;
  return true;
}

const editorFactoryRe = /function ([A-Za-z_$][\w$]*)\(\{id:([A-Za-z_$][\w$]*),label:([A-Za-z_$][\w$]*),icon:([A-Za-z_$][\w$]*),darwinDetect:([A-Za-z_$][\w$]*),win32Detect:([A-Za-z_$][\w$]*),darwinEnv:([A-Za-z_$][\w$]*),darwinArgs:([A-Za-z_$][\w$]*)\}\)\{return\{id:\2,platforms:\{darwin:\5\?\{label:\3,icon:\4,kind:"editor",detect:\5,env:\7,args:\8\?\?([A-Za-z_$][\w$]*)\}:void 0,win32:\6\?\{label:\3,icon:\4,kind:"editor",detect:\6,args:\9\}:void 0\}\}\}/;
applyRegex(
  editorFactoryRe,
  (_, fnName, idVar, labelVar, iconVar, darwinVar, win32Var, darwinEnvVar, darwinArgsVar, defaultArgsVar) =>
    `function ${fnName}({id:${idVar},label:${labelVar},icon:${iconVar},darwinDetect:${darwinVar},win32Detect:${win32Var},linuxDetect:a,darwinEnv:${darwinEnvVar},darwinArgs:${darwinArgsVar},linuxEnv:c,linuxArgs:u,linuxOpen:l}){return{id:${idVar},platforms:{darwin:${darwinVar}?{label:${labelVar},icon:${iconVar},kind:"editor",detect:${darwinVar},env:${darwinEnvVar},args:${darwinArgsVar}??${defaultArgsVar}}:void 0,win32:${win32Var}?{label:${labelVar},icon:${iconVar},kind:"editor",detect:${win32Var},args:${defaultArgsVar}}:void 0,linux:a?{label:${labelVar},icon:${iconVar},kind:"editor",detect:a,env:c,args:u??${defaultArgsVar},open:l}:void 0}}}`
);

const vscodeRe = /const ([A-Za-z_$][\w$]*)=([A-Za-z_$][\w$]*)\(\{id:"vscode",label:"VS Code",icon:"apps\/vscode\.png",([^}]*)\}\);/;
applyRegex(vscodeRe, (full, constVar, factoryVar, props) => {
  if (props.includes("linuxDetect:")) return full;
  const cleanProps = props.endsWith(",") ? props.slice(0, -1) : props;
  return `const ${constVar}=${factoryVar}({id:"vscode",label:"VS Code",icon:"apps/vscode.png",${cleanProps},linuxDetect:__codexVSCodeLinuxDetect,linuxArgs:__codexVSCodeLinuxArgs,linuxOpen:__codexVSCodeLinuxOpen});`;
});

const insidersRe = /const ([A-Za-z_$][\w$]*)=([A-Za-z_$][\w$]*)\(\{id:"vscodeInsiders",label:"VS Code Insiders",icon:"apps\/vscode-insiders\.png",([^}]*)\}\);/;
applyRegex(insidersRe, (full, constVar, factoryVar, props) => {
  if (props.includes("linuxDetect:")) return full;
  const cleanProps = props.endsWith(",") ? props.slice(0, -1) : props;
  return `const ${constVar}=${factoryVar}({id:"vscodeInsiders",label:"VS Code Insiders",icon:"apps/vscode-insiders.png",${cleanProps},linuxDetect:__codexVSCodeInsidersLinuxDetect,linuxArgs:__codexVSCodeLinuxArgs,linuxOpen:__codexVSCodeLinuxOpen});`;
});

const fileManagerRe = /const ([A-Za-z_$][\w$]*)=([A-Za-z_$][\w$]*)\(\{id:"fileManager",label:"Finder",icon:"apps\/finder\.png",kind:"fileManager",darwin:\{detect:\(\)=>"open",args:t=>([A-Za-z_$][\w$]*)\(t\)\},win32:\{label:"Explorer",icon:"apps\/file-explorer\.png",detect:([A-Za-z_$][\w$]*),args:t=>[A-Za-z_$][\w$]*\(t\),open:async\(\{path:t\}\)=>([A-Za-z_$][\w$]*)\(t\)\}\}\);/;
applyRegex(fileManagerRe, (_, constVar, factoryVar, argsFn, winDetectFn, winOpenFn) =>
  `const ${constVar}=${factoryVar}({id:"fileManager",label:"Finder",icon:"apps/finder.png",kind:"fileManager",darwin:{detect:()=>"open",args:t=>${argsFn}(t)},win32:{label:"Explorer",icon:"apps/file-explorer.png",detect:${winDetectFn},args:t=>${argsFn}(t),open:async({path:t})=>${winOpenFn}(t)},linux:{label:"File Manager",icon:"apps/file-explorer.png",detect:__codexFileManagerLinuxDetect,args:t=>__codexFileManagerLinuxArgs(t)}});`
);

if (!source.includes("function __codexVSCodeLinuxDetect()")) {
  const helperRe = /function ([A-Za-z_$][\w$]*)\(\)\{return ([A-Za-z_$][\w$]*)\(\{pathCommand:([A-Za-z_$][\w$]*)\("code-insiders"\),executableName:"Code - Insiders\.exe",installDirName:"Microsoft VS Code Insiders"\}\)\}/;
  applyRegex(
    helperRe,
    (full, insidersWinFn, winResolveFn, whichFn) =>
      `${full}function __codexVSCodeLinuxDetect(){const t=process.env.CODEX_VSCODE_PATH?.trim();if(t)return t;return ${whichFn}("code")||${whichFn}("codium")||null}function __codexVSCodeInsidersLinuxDetect(){const t=process.env.CODEX_VSCODE_INSIDERS_PATH?.trim();if(t)return t;return ${whichFn}("code-insiders")||${whichFn}("codium-insiders")||null}function __codexVSCodeLinuxArgs(t,e){return e?["--goto",\`${"${t}:${e.line}:${e.column}"}\`]:[t]}async function __codexVSCodeLinuxOpen({command:t,path:e,location:n}){const r=__codexVSCodeLinuxArgs(e,n);try{await gr(t,r)}catch{await gr(t,[e])}}`
  );
}

if (!source.includes("function __codexFileManagerLinuxDetect()")) {
  const fileManagerHelperRe = /function ([A-Za-z_$][\w$]*)\(t\)\{let e=t;for\(;;\)\{if\(([A-Za-z_$][\w$]*)\.existsSync\(e\)\)return e;const n=([A-Za-z_$][\w$]*)\.dirname\(e\);if\(n===e\)return null;e=n\}\}/;
  applyRegex(
    fileManagerHelperRe,
    (full, nearestExistingFn, fsVar, pathVar) =>
      `${full}function __codexFileManagerLinuxDetect(){return process.platform==="linux"?"xdg-open":null}function __codexFileManagerLinuxArgs(t){const e=${nearestExistingFn}(t)??t;try{return [${fsVar}.existsSync(e)&&${fsVar}.statSync(e).isDirectory()?e:${pathVar}.dirname(e)]}catch{return [${pathVar}.dirname(e)]}}`
  );
}

if (source !== original) {
  fs.writeFileSync(bundlePath, source);
  console.error("[codex-linux] Auto-heal: patched open targets in main.js (VS Code + file manager)");
}
NODE
}

auto_heal_sidebar_active_threads() {
  [ "${CODEX_PATCH_AUTO_HEAL:-1}" = "1" ] || return 0

  local webview_index web_bundle_rel web_bundle
  webview_index="$APP_DIR/webview/index.html"
  web_bundle_rel=""
  web_bundle=""

  if [ -f "$webview_index" ]; then
    web_bundle_rel="$(grep -oE 'assets/index-[^"]+\.js' "$webview_index" | head -n 1 || true)"
  fi

  if [ -n "$web_bundle_rel" ] && [ -f "$APP_DIR/webview/$web_bundle_rel" ]; then
    web_bundle="$APP_DIR/webview/$web_bundle_rel"
  else
    web_bundle="$(find "$APP_DIR/webview/assets" -maxdepth 1 -name 'index-*.js' -type f -print | head -n 1 || true)"
  fi

  [ -n "$web_bundle" ] || return 0

  node - <<'NODE' "$web_bundle"
const fs = require("node:fs");

const bundlePath = process.argv[2];
if (!bundlePath) process.exit(0);

let source = fs.readFileSync(bundlePath, "utf8");
const original = source;
const applied = [];

function applyExact(name, from, to, required = true) {
  if (source.includes(to)) return true;
  if (!source.includes(from)) {
    if (required) console.error(`[codex-linux] Auto-heal sidebar patch: missing pattern (${name}).`);
    return !required;
  }
  source = source.replace(from, () => to);
  applied.push(name);
  return true;
}

const alreadyPatched =
  source.includes('sidebarElectron.activeThreads') &&
  source.includes("codexActiveSidebarItems=") &&
  !source.includes("toggle_active_threads") &&
  !source.includes("codexActiveSidebarItems.length>0?") &&
  source.includes("title:mn,children:f.jsx(DOe,{items:codexActiveSidebarItems");
if (alreadyPatched) process.exit(0);

let ok = true;

ok =
  applyExact(
    "cleanup-setting-key",
    'Os("sidebar-view-v2","threads"),__codexSidebarActiveFilterKey=Os("sidebar-active-thread-filter-v1","all");function $$t(){',
    'Os("sidebar-view-v2","threads");function $$t(){',
    false
  ) && ok;

ok =
  applyExact(
    "cleanup-state",
    'const{groups:Me,isWorkspaceRootOptionsLoading:Oe,workspaceRootOptions:Ue,workspaceRootLabels:He}=YUt(Ie,Re),[Ze,Xe]=cr(H$t),[codexActiveFilter,codexSetActiveFilter]=cr(__codexSidebarActiveFilterKey),codexShowActiveOnly=codexActiveFilter==="active";',
    'const{groups:Me,isWorkspaceRootOptionsLoading:Oe,workspaceRootOptions:Ue,workspaceRootLabels:He}=YUt(Ie,Re),[Ze,Xe]=cr(H$t);',
    false
  ) && ok;

ok =
  applyExact(
    "cleanup-visible-groups",
    'const gt=ft.length,yt=!Oe,dt=be.length>0,codexVisibleGroups=codexShowActiveOnly?Me.map(mn=>({...mn,tasks:mn.tasks.filter(_n=>__codexSidebarIsActiveThread(_n)||j3(_n)===x)})).filter(mn=>mn.tasks.length>0):Me,at=!Pe&&codexVisibleGroups.length===0&&_e.length===0&&!dt;',
    'const gt=ft.length,yt=!Oe,dt=be.length>0,at=!Pe&&Me.length===0&&_e.length===0&&!dt;',
    false
  ) && ok;

ok =
  applyExact(
    "cleanup-visible-items",
    'const vt=ys(Dt),Bt=Ph(),Zt=iWt({items:xe,itemsForVisibilityLookup:[...be,...xe],showRecent:Pe,hasGitRpc:Bt,workspaceTaskFilter:F,currentConversationId:S,isBackgroundSubagentsEnabled:ee}).filter(K$t),codexActiveItems=Zt.filter(mn=>__codexSidebarIsActiveThread(mn.task)||j3(mn.task)===x),codexVisibleItems=codexShowActiveOnly?codexActiveItems:Zt;',
    'const vt=ys(Dt),Bt=Ph(),Zt=iWt({items:xe,itemsForVisibilityLookup:[...be,...xe],showRecent:Pe,hasGitRpc:Bt,workspaceTaskFilter:F,currentConversationId:S,isBackgroundSubagentsEnabled:ee}).filter(K$t);',
    false
  ) && ok;

ok =
  applyExact(
    "cleanup-visible-item-usage",
    'const Ut=Pe&&SUt({items:codexVisibleItems,currentThreadKey:x,maxItems:q5e,getTask:G$t}),en=CUt({pinnedItems:be,showRecent:Pe,recentItems:codexVisibleItems,groups:codexVisibleGroups,isBackgroundSubagentsEnabled:ee}),Wt=new Map;',
    'const Ut=Pe&&SUt({items:Zt,currentThreadKey:x,maxItems:q5e,getTask:G$t}),en=CUt({pinnedItems:be,showRecent:Pe,recentItems:Zt,groups:Me,isBackgroundSubagentsEnabled:ee}),Wt=new Map;',
    false
  ) && ok;

ok =
  applyExact(
    "cleanup-group-selection",
    'if(x!=null)if(t[27]!==x||t[28]!==codexVisibleGroups){for(const mn of codexVisibleGroups)if(mn.tasks.some(_n=>j3(_n)===x)){Ft=mn.path;break}t[27]=x,t[28]=codexVisibleGroups,t[29]=Ft}else Ft=t[29];',
    'if(x!=null)if(t[27]!==x||t[28]!==Me){for(const mn of Me)if(mn.tasks.some(_n=>j3(_n)===x)){Ft=mn.path;break}t[27]=x,t[28]=Me,t[29]=Ft}else Ft=t[29];',
    false
  ) && ok;

ok =
  applyExact(
    "cleanup-toggle-button",
    'f.jsx(I$t,{groupByWorkspace:!Pe,onGroupByWorkspaceChange:mn=>{o({eventName:"codex_app_nav_clicked",metadata:{item:"toggle_recent"}}),De(mn?"threads":"recent")}}),f.jsx(Ge,{className:"h-6 rounded-md px-2 text-xs",color:codexShowActiveOnly?"secondary":"ghostActive",size:"default",onClick:()=>{o({eventName:"codex_app_nav_clicked",metadata:{item:"toggle_active_threads"}}),codexSetActiveFilter(codexShowActiveOnly?"all":"active")},children:f.jsx(q,{id:"sidebarElectron.activeOnlyToggle",defaultMessage:"Active",description:"Toggle button label to show only active threads in sidebar"})})]})',
    'f.jsx(I$t,{groupByWorkspace:!Pe,onGroupByWorkspaceChange:mn=>{o({eventName:"codex_app_nav_clicked",metadata:{item:"toggle_recent"}}),De(mn?"threads":"recent")}})]})',
    false
  ) && ok;

ok =
  applyExact(
    "cleanup-recent-render",
    'children:mn=>f.jsx(DOe,{items:codexVisibleItems,ariaLabel:mn.map(W$t).join(""),',
    'children:mn=>f.jsx(DOe,{items:Zt,ariaLabel:mn.map(W$t).join(""),',
    false
  ) && ok;

ok =
  applyExact(
    "cleanup-grouped-render",
    'groups:codexVisibleGroups,unpinnedItemByTaskKey:ge,',
    'groups:Me,unpinnedItemByTaskKey:ge,',
    false
  ) && ok;

if (!source.includes("function __codexSidebarIsActiveThread(")) {
  ok =
    applyExact(
      "ensure-active-helper",
      'function TIt(t){if(t.kind==="remote"){const e=t.task.task_status_display?.latest_turn_status_display?.turn_status;return t.task.has_unread_turn===!0||e==="in_progress"||e==="pending"}return t.kind==="local"&&t.conversation.hasUnreadTurn?!0:t.kind==="local"?TD(t.conversation):t.kind==="pending-worktree"}function WI(t){',
      'function TIt(t){if(t.kind==="remote"){const e=t.task.task_status_display?.latest_turn_status_display?.turn_status;return t.task.has_unread_turn===!0||e==="in_progress"||e==="pending"}return t.kind==="local"&&t.conversation.hasUnreadTurn?!0:t.kind==="local"?TD(t.conversation):t.kind==="pending-worktree"}function __codexSidebarIsActiveThread(t){if(t.kind==="remote"){const e=t.task.task_status_display?.latest_turn_status_display?.turn_status;return e==="in_progress"||e==="pending"}return t.kind==="local"?TD(t.conversation)||QEe(t.conversation):t.kind==="pending-worktree"}function WI(t){'
    ) && ok;
}

ok =
  applyExact(
    "inject-active-items",
    'const vt=ys(Dt),Bt=Ph(),Zt=iWt({items:xe,itemsForVisibilityLookup:[...be,...xe],showRecent:Pe,hasGitRpc:Bt,workspaceTaskFilter:F,currentConversationId:S,isBackgroundSubagentsEnabled:ee}).filter(K$t);',
    'const vt=ys(Dt),Bt=Ph(),Zt=iWt({items:xe,itemsForVisibilityLookup:[...be,...xe],showRecent:Pe,hasGitRpc:Bt,workspaceTaskFilter:F,currentConversationId:S,isBackgroundSubagentsEnabled:ee}).filter(K$t),codexActiveSidebarItems=Zt.filter(mn=>__codexSidebarIsActiveThread(mn.task)||j3(mn.task)===x);'
  ) && ok;

ok =
  applyExact(
    "upgrade-gated-active-top-section",
    '):null]})}),codexActiveSidebarItems.length>0?f.jsx("div",{className:"px-row-x",children:f.jsx(qL,{children:f.jsx(q,{id:"sidebarElectron.activeThreads",defaultMessage:"Active threads",description:"List label for active threads at the top of the sidebar",children:mn=>f.jsx(DOe,{items:codexActiveSidebarItems,ariaLabel:mn.map(W$t).join(""),currentThreadKey:x,onActivateThread:C,className:"pb-2",itemClassName:"after:block after:h-1 after:content-[\'\'] last:after:hidden",rowOptions:{mutePendingAutomation:!0,expandedSubagentParents:it,onToggleSubagentChildren:Je}})})})}):null,dt?f.jsx("div",{className:"px-row-x",children:f.jsx(qL,{children:f.jsx(q,{id:"sidebarElectron.pinnedThreads"',
    '):null]})}),f.jsx("div",{className:"px-row-x",children:f.jsx(q,{id:"sidebarElectron.activeThreads",defaultMessage:"Active threads",description:"List label for active threads at the top of the sidebar",children:mn=>f.jsx(qL,{title:mn,children:f.jsx(DOe,{items:codexActiveSidebarItems,ariaLabel:mn.map(W$t).join(""),currentThreadKey:x,onActivateThread:C,className:"pb-2",itemClassName:"after:block after:h-1 after:content-[\'\'] last:after:hidden",rowOptions:{mutePendingAutomation:!0,expandedSubagentParents:it,onToggleSubagentChildren:Je}})})})}),dt?f.jsx("div",{className:"px-row-x",children:f.jsx(qL,{children:f.jsx(q,{id:"sidebarElectron.pinnedThreads"',
    false
  ) && ok;

ok =
  applyExact(
    "upgrade-ungated-active-top-section-title",
    '):null]})}),f.jsx("div",{className:"px-row-x",children:f.jsx(qL,{children:f.jsx(q,{id:"sidebarElectron.activeThreads",defaultMessage:"Active threads",description:"List label for active threads at the top of the sidebar",children:mn=>f.jsx(DOe,{items:codexActiveSidebarItems,ariaLabel:mn.map(W$t).join(""),currentThreadKey:x,onActivateThread:C,className:"pb-2",itemClassName:"after:block after:h-1 after:content-[\'\'] last:after:hidden",rowOptions:{mutePendingAutomation:!0,expandedSubagentParents:it,onToggleSubagentChildren:Je}})})})}),dt?f.jsx("div",{className:"px-row-x",children:f.jsx(qL,{children:f.jsx(q,{id:"sidebarElectron.pinnedThreads"',
    '):null]})}),f.jsx("div",{className:"px-row-x",children:f.jsx(q,{id:"sidebarElectron.activeThreads",defaultMessage:"Active threads",description:"List label for active threads at the top of the sidebar",children:mn=>f.jsx(qL,{title:mn,children:f.jsx(DOe,{items:codexActiveSidebarItems,ariaLabel:mn.map(W$t).join(""),currentThreadKey:x,onActivateThread:C,className:"pb-2",itemClassName:"after:block after:h-1 after:content-[\'\'] last:after:hidden",rowOptions:{mutePendingAutomation:!0,expandedSubagentParents:it,onToggleSubagentChildren:Je}})})})}),dt?f.jsx("div",{className:"px-row-x",children:f.jsx(qL,{children:f.jsx(q,{id:"sidebarElectron.pinnedThreads"',
    false
  ) && ok;

ok =
  applyExact(
    "inject-active-top-section",
    '):null]})}),dt?f.jsx("div",{className:"px-row-x",children:f.jsx(qL,{children:f.jsx(q,{id:"sidebarElectron.pinnedThreads"',
    '):null]})}),f.jsx("div",{className:"px-row-x",children:f.jsx(q,{id:"sidebarElectron.activeThreads",defaultMessage:"Active threads",description:"List label for active threads at the top of the sidebar",children:mn=>f.jsx(qL,{title:mn,children:f.jsx(DOe,{items:codexActiveSidebarItems,ariaLabel:mn.map(W$t).join(""),currentThreadKey:x,onActivateThread:C,className:"pb-2",itemClassName:"after:block after:h-1 after:content-[\'\'] last:after:hidden",rowOptions:{mutePendingAutomation:!0,expandedSubagentParents:it,onToggleSubagentChildren:Je}})})})}),dt?f.jsx("div",{className:"px-row-x",children:f.jsx(qL,{children:f.jsx(q,{id:"sidebarElectron.pinnedThreads"'
  ) && ok;

if (!ok) process.exit(0);

if (source !== original) {
  fs.writeFileSync(bundlePath, source);
  console.error(`[codex-linux] Auto-heal: patched sidebar active threads toggle (${applied.join(", ")}).`);
}
NODE
}

patch_failure=0

if ! auto_heal_open_targets; then
  patch_failure=1
fi

if ! auto_heal_sidebar_active_threads; then
  patch_failure=1
fi

if [ "$patch_failure" -ne 0 ]; then
  if [ "${CODEX_PATCH_STRICT:-0}" = "1" ]; then
    echo "ERROR: failed to auto-heal runtime patches." >&2
    exit 1
  fi
fi

check_for_updates_async

if [ "${CODEX_NO_SANDBOX:-0}" = "1" ]; then
  exec "$LOCAL_ELECTRON" --no-sandbox "$APP_DIR"
else
  exec "$LOCAL_ELECTRON" "$APP_DIR"
fi
__LAUNCHER__

  chmod +x "$RUN_LAUNCHER"
}

ensure_desktop_entry() {
  # Remove stale duplicate Codex launcher entries from previous runs/names.
  cleanup_legacy_desktop_entries() {
    local app_dir="${HOME}/.local/share/applications"
    local file

    shopt -s nullglob
    for file in "$app_dir"/*.desktop; do
      if grep -q '^Name=OpenAI Codex$' "$file" \
        && grep -q '^Exec=.*run-codex\.sh' "$file" \
        && [ "$file" != "$DESKTOP_ENTRY_PATH" ]; then
        rm -f "$file"
      fi
    done
    shopt -u nullglob
  }

  cleanup_legacy_desktop_entries

  mkdir -p "$(dirname "$DESKTOP_ENTRY_PATH")"
  cat > "$DESKTOP_ENTRY_PATH" <<EOF
[Desktop Entry]
Type=Application
Name=$APP_DISPLAY_NAME
Comment=Run Codex on Linux (unofficial helper)
Exec=$RUN_LAUNCHER
Icon=electron
Terminal=false
Path=$ROOT_DIR
StartupNotify=true
Categories=Development;Utility;Office;
Keywords=ai;assistant;coding;electron;
EOF
  chmod 644 "$DESKTOP_ENTRY_PATH"

  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$(dirname "$DESKTOP_ENTRY_PATH")" >/dev/null 2>&1 || true
  fi

  if command -v xdg-desktop-menu >/dev/null 2>&1; then
    xdg-desktop-menu forceupdate >/dev/null 2>&1 || true
  fi
}

ensure_codex_cli() {
  if have codex; then
    return
  fi

  log "Installing @openai/codex CLI in user scope"
  pnpm setup || true
  export PNPM_HOME="${PNPM_HOME:-$HOME/.local/share/pnpm}"
  mkdir -p "$PNPM_HOME/global/5"
  pnpm i -g @openai/codex || warn "codex CLI installation failed"
}

print_next() {
  log "Done"
  echo "Launcher: $RUN_LAUNCHER"
  echo "Start:    $RUN_LAUNCHER"
  echo "No sandbox: CODEX_NO_SANDBOX=1 $RUN_LAUNCHER"
  if [ "$INSTALL_DESKTOP_ENTRY" = "1" ]; then
    echo "Desktop:  $DESKTOP_ENTRY_PATH"
    echo "Open in rofi: rofi -show drun"
  else
    echo "Desktop:  not installed (use --install-desktop)"
  fi
  echo "Project data: $ROOT_DIR"

  if have codex; then
    echo "CLI:    $(command -v codex)"
  else
    echo "CLI:    not on PATH yet"
    echo "Add once (if needed):"
    echo "  export PNPM_HOME=\"${PNPM_HOME:-$HOME/.local/share/pnpm}\""
    echo "  export PATH=\"${PNPM_HOME:-$HOME/.local/share/pnpm}:\$PATH\""
  fi
}

main() {
  parse_args "$@"
  DMG_PATH="${DMG_PATH:-$DOWNLOAD_DIR/Codex.dmg}"
  show_system
  if [ "$(uname -m)" != "x86_64" ]; then
    warn "Non-x86_64 architecture detected. This project is not validated for ARM/x86."
  fi

  mkdir -p "$ROOT_DIR" "$DOWNLOAD_DIR"
  backup_user_state_snapshot
  ensure_system_dependencies
  ensure_pnpm
  ensure_tooling

  if [ ! -f "$DMG_PATH" ]; then
    log "Downloading Codex dmg from official source"
    curl -L --fail --retry 3 --retry-delay 2 -o "$DMG_PATH" "$DMG_URL"
  else
    echo "Using existing DMG: $DMG_PATH"
  fi

  ensure_archive_tool
  find_and_extract_asar
  restore_user_state_from_latest_backup
  patch_main_js_linux_open_target
  patch_plan_mode_indicator
  patch_sidebar_active_threads
  patch_background_terminal_stop
  patch_mcp_install_auth

  local version
  version="$(resolve_electron_version)"
  log "Electron version: $version"

  ensure_local_electron "$version"
  if [ -n "${ELECTRON_RUNTIME_VERSION:-}" ]; then
    version="$ELECTRON_RUNTIME_VERSION"
  fi
  log "Electron runtime selected: $version"

  if needs_native_rebuild; then
    rebuild_native_modules "$version"
  else
    log "Native modules detected and already executable; skipping rebuild"
  fi

  write_launcher
  if [ "$INSTALL_DESKTOP_ENTRY" = "1" ]; then
    ensure_desktop_entry
  else
    warn "Skipping desktop entry creation (--no-desktop)"
  fi
  ensure_codex_cli
  print_next
}

main "$@"
