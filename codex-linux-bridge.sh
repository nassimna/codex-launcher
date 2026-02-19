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

Environment:
  FORCE, SKIP_SYSTEM_DEPS, ROOT_APP_DIR, DOWNLOAD_DIR, DMG_PATH, FORCE_ELECTRON_VERSION, INSTALL_DESKTOP_ENTRY

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
  local main_js
  main_js="$(find "$APP_ASAR_DIR/.vite/build" -maxdepth 1 -name 'main-*.js' -type f -print | head -n 1 || true)"

  if [ -z "$main_js" ]; then
    warn "No main-*.js bundle found; skipping Linux editor patch"
    return
  fi

  if grep -q "Opening external editors is not supported on Windows yet" "$main_js" 2>/dev/null && \
     grep -q 'function Sp(t){const n=' "$main_js" 2>/dev/null; then
    return
  fi

  log "Patching app bundle for Linux external editor targets (VS Code, file targets)"
  node - <<'NODE' "$main_js"
const fs = require('node:fs');
const path = process.argv[2];
let source = fs.readFileSync(path, 'utf8');

const original = source;

source = source.replace(
  'if(!Yr)throw new Error("Opening external editors is only supported on macOS");',
  'if(process.platform==="win32")throw new Error("Opening external editors is not supported on Windows yet");'
);

source = source.replace(
  'async function oN(){if(!Yr)return[];',
  'async function oN(){'
);

const oldSp = 'function Sp(t){try{const e=Dn.spawnSync("which",[t],{encoding:"utf8",timeout:1e3}),n=e.stdout?.trim();if(e.status===0&&n&&Ee.existsSync(n))return n}catch(e){li().debug("Failed to locate command in PATH",{safe:{command:t},sensitive:{error:e}})}return null}';
const oldSpNoMacGuard = 'function Sp(t){if(!Yr)return null;try{const e=Dn.spawnSync("which",[t],{encoding:"utf8",timeout:1e3}),n=e.stdout?.trim();if(e.status===0&&n&&Ee.existsSync(n))return n}catch(e){li().debug("Failed to locate command in PATH",{safe:{command:t},sensitive:{error:e}})}return null}';
const newSp = `function Sp(t){const n=[t,\`/usr/bin/\${t}\`,\`/usr/local/bin/\${t}\`,\`/usr/share/code/bin/\${t}\`,\`/usr/share/codium/bin/\${t}\`,\`/opt/visual-studio-code/bin/\${t}\`,\`/opt/visual-studio-codium/bin/\${t}\`,\`/snap/bin/\${t}\`,\`\${process.env.HOME ?? ""}/.local/bin/\${t}\`,\`\${process.env.HOME ?? ""}/bin/\${t}\`].filter(Boolean);for(const i of n){if(i.includes("/")&&Ee.existsSync(i))return i;try{const e=Dn.spawnSync(\"which\",[i],{encoding:\"utf8\",timeout:1e3}),r=e.stdout?.trim();if(e.status===0&&r&&Ee.existsSync(r))return r}catch(e){li().debug(\"Failed to locate command in PATH\",{safe:{},sensitive:{command:i,error:e}})}}return null}`;

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
const vscodeReplacement = `detect:()=>{const i=process.env.CODEX_VSCODE_PATH?.trim();if(i&&Ee.existsSync(i))return i;const t=Sp("code")||Sp("codium");if(t)return t;return sn(["/var/lib/flatpak/exports/bin/com.visualstudio.code","/var/lib/flatpak/exports/bin/com.vscodium.codium","${process.env.HOME ?? ""}/.local/share/flatpak/exports/bin/com.visualstudio.code","${process.env.HOME ?? ""}/.local/share/flatpak/exports/bin/com.vscodium.codium","${process.env.HOME ?? ""}/.local/bin/code","${process.env.HOME ?? ""}/.local/bin/codium","/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code","/Applications/Code.app/Contents/Resources/app/bin/code"])}`;
const vscodeInsiderReplacement = `detect:()=>{const i=process.env.CODEX_VSCODE_INSIDERS_PATH?.trim();if(i&&Ee.existsSync(i))return i;return Sp("code-insiders")||Sp("codium-insiders")||sn(["/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code","/Applications/Code - Insiders.app/Contents/Resources/app/bin/code"])}`;

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
NODE
}

resolve_electron_version() {
  if [ -n "$ELECTRON_VERSION_OVERRIDE" ]; then
    echo "$ELECTRON_VERSION_OVERRIDE"
    return
  fi

  local version=""

  if [ -f "$APP_ASAR_DIR/package.json" ]; then
    version="$(node -p "try { const pkg=require('$APP_ASAR_DIR/package.json'); const v=(pkg.devDependencies?.electron || pkg.dependencies?.electron || '').replace(/^\^/, ''); if (/^[0-9]+(\\.[0-9]+){1,}$/.test(v)) v : '' } catch { '' }" 2>/dev/null || true)"
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

  if [ "$current" != "$version" ]; then
    log "Installing local Electron $version"
    pnpm --dir "$TOOLS_DIR" add -D "electron@$version"
  fi

  pnpm --dir "$TOOLS_DIR" rebuild electron || true
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
  for candidate in "$(command -v code-insiders 2>/dev/null || true)" "$(command -v codium-insiders 2>/dev/null || true)" "/usr/bin/code-insiders" "/usr/local/bin/code-insiders" "/var/lib/flatpak/exports/bin/com.visualstudio.code-insiders" "${HOME}/.local/share/flatpak/exports/bin/com.visualstudio.code-insiders"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && export CODEX_VSCODE_INSIDERS_PATH="$candidate" && break
  done
fi

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
  patch_main_js_linux_open_target

  local version
  version="$(resolve_electron_version)"
  log "Electron version: $version"

  ensure_local_electron "$version"

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
