// patch-main-windows.cjs
// Patches the Codex Electron main bundle for Windows compatibility.
// Replaces macOS-only editor detection with cross-platform equivalents.
//
// Usage: node patch-main-windows.cjs <path-to-main-bundle.js>

const fs = require("node:fs");
const vm = require("node:vm");

const bundlePath = process.argv[2];
if (!bundlePath) {
  console.error("Usage: node patch-main-windows.cjs <main-bundle.js>");
  process.exit(1);
}

let source = fs.readFileSync(bundlePath, "utf8");
const original = source;

// --- 1. Remove macOS-only guards ---

source = source.replace(
  'if(!Yr)throw new Error("Opening external editors is only supported on macOS");',
  ""
);

source = source.replace(
  'if(process.platform==="win32")throw new Error("Opening external editors is not supported on Windows yet");',
  ""
);

// Remove early-return guard on editor list function
source = source.replace(
  "async function oN(){if(!Yr)return[];",
  "async function oN(){"
);

// --- 2. Replace the Sp (resolve-command-in-PATH) function ---
// The original uses `which` which doesn't exist on Windows.
// Replace with a version that tries `where` first (Windows) then `which` (Unix).

const oldSp =
  'function Sp(t){try{const e=Dn.spawnSync("which",[t],{encoding:"utf8",timeout:1e3}),n=e.stdout?.trim();if(e.status===0&&n&&Ee.existsSync(n))return n}catch(e){li().debug("Failed to locate command in PATH",{safe:{command:t},sensitive:{error:e}})}return null}';

const oldSpNoMacGuard =
  'function Sp(t){if(!Yr)return null;try{const e=Dn.spawnSync("which",[t],{encoding:"utf8",timeout:1e3}),n=e.stdout?.trim();if(e.status===0&&n&&Ee.existsSync(n))return n}catch(e){li().debug("Failed to locate command in PATH",{safe:{command:t},sensitive:{error:e}})}return null}';

// Build the replacement Sp function as a plain string to avoid template
// literal / replacement-string pitfalls.
const newSp = [
  "function Sp(t){",
  'var cmds=process.platform==="win32"?["where"]:["which"];',
  "for(var ci=0;ci<cmds.length;ci++){",
  "try{",
  'var e=Dn.spawnSync(cmds[ci],[t],{encoding:"utf8",timeout:1e3}),',
  "n=e.stdout&&e.stdout.split(/\\r?\\n/).find(Boolean);",
  "n=n&&n.trim();",
  "if(e.status===0&&n&&Ee.existsSync(n))return n",
  '}catch(e){li().debug("Failed to locate command in PATH",{safe:{command:t},sensitive:{error:e}})}',
  "}",
  "return null}",
].join("");

if (source.includes(oldSp)) {
  source = source.replace(oldSp, newSp);
} else if (source.includes(oldSpNoMacGuard)) {
  source = source.replace(oldSpNoMacGuard, newSp);
}

// --- 3. Replace VS Code detection paths ---
// Original detects macOS .app bundle paths.  Add Windows search paths.

const vscodeDetect =
  'detect:()=>Sp("code")||Sp("codium")||sn(["/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code","/Applications/Code.app/Contents/Resources/app/bin/code"])';
const vscodeDetectFromBundle =
  'detect:()=>sn(["/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code","/Applications/Code.app/Contents/Resources/app/bin/code"])';
const vscodeInsiderDetect =
  'detect:()=>Sp("code-insiders")||Sp("codium-insiders")||sn(["/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code","/Applications/Code - Insiders.app/Contents/Resources/app/bin/code"])';
const vscodeInsiderDetectFromBundle =
  'detect:()=>sn(["/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code","/Applications/Code - Insiders.app/Contents/Resources/app/bin/code"])';

// Replacement: check env var first, then try .cmd variants (Windows), then
// fall back to macOS paths so the same binary can run on either platform.
const vscodeReplacement =
  'detect:()=>{var i=process.env.CODEX_VSCODE_PATH;if(i&&i.trim()&&Ee.existsSync(i.trim()))return i.trim();return Sp("code.cmd")||Sp("code")||Sp("codium.cmd")||Sp("codium")||sn(["/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code","/Applications/Code.app/Contents/Resources/app/bin/code"])}';

const vscodeInsiderReplacement =
  'detect:()=>{var i=process.env.CODEX_VSCODE_INSIDERS_PATH;if(i&&i.trim()&&Ee.existsSync(i.trim()))return i.trim();return Sp("code-insiders.cmd")||Sp("code-insiders")||Sp("codium-insiders.cmd")||Sp("codium-insiders")||sn(["/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code","/Applications/Code - Insiders.app/Contents/Resources/app/bin/code"])}';

for (const [search, replacement] of [
  [vscodeDetect, vscodeReplacement],
  [vscodeDetectFromBundle, vscodeReplacement],
  [vscodeInsiderDetect, vscodeInsiderReplacement],
  [vscodeInsiderDetectFromBundle, vscodeInsiderReplacement],
]) {
  if (source.includes(search)) {
    source = source.replace(search, replacement);
  }
}

// --- 4. Validate and write ---

if (source === original) {
  console.log("No patches matched — bundle may already be patched or patterns changed.");
  process.exit(0);
}

// Verify the patched source is still valid JavaScript
try {
  vm.createScript(source, { filename: bundlePath });
} catch (e) {
  console.error("ERROR: Patched bundle has a syntax error — aborting write.");
  console.error(e.message.slice(0, 300));
  process.exit(1);
}

fs.writeFileSync(bundlePath, source);
const lineCount = source.split("\n").length;
console.log("Patch applied successfully. Lines: " + lineCount);
