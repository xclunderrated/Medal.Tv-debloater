<#
.SYNOPSIS
  Medal Debloat Mod - strips Home (/home), Discover (/games), Quests, Premium nav; redirects everything to Library; disables ads completely.
.DESCRIPTION
  Run in PowerShell (right-click -> Run with PowerShell, or: powershell -ExecutionPolicy Bypass -File .\Medal-Debloat.ps1)
  Tested against Medal 2638.479.1 (Electron 43, Velopack, app.asar 41MB).
  - Kills Medal, backs up app.asar, extracts asar, patches renderer.min.js + redirect stubs + ad stubs, repacks, verifies.
  - By default also blocks auto-updates (renames Update.exe, reversible). Updates would otherwise wipe the mod.
  - Supports -Restore to undo.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Medal-Debloat.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Medal-Debloat.ps1 -Restore
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Medal-Debloat.ps1 -KeepUpdates  # do NOT block updater
#>
param(
  [switch]$Restore,
  [switch]$KeepUpdates
)

$ErrorActionPreference = 'Stop'

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  [!] $msg" -ForegroundColor Yellow }

# --- 0. Elevate ---
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
  Warn 'Not elevated - relaunching as admin...'
  $elevArgs = "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
  if ($Restore) { $elevArgs += ' -Restore' }
  if ($KeepUpdates) { $elevArgs += ' -KeepUpdates' }
  Start-Process powershell.exe -ArgumentList $elevArgs -Verb RunAs
  exit 0
}

# --- 1. Locate Medal ---
$MedalRoot = Join-Path $env:LOCALAPPDATA 'Medal'
if (-not (Test-Path -LiteralPath $MedalRoot)) { throw "Medal not found at $MedalRoot" }
$AsarPath = Join-Path $MedalRoot 'current\resources\app.asar'
if (-not (Test-Path -LiteralPath $AsarPath)) { throw "app.asar not found at $AsarPath" }
$UpdateExe = Join-Path $MedalRoot 'Update.exe'
$UpdateDisabled = Join-Path $MedalRoot 'Update.exe.disabled'
$AsarBak = "$AsarPath.bak"
Step "Medal found at $MedalRoot"
Ok "app.asar: $([math]::Round((Get-Item -LiteralPath $AsarPath).Length/1MB,1)) MB"

# --- 2. Restore mode ---
if ($Restore) {
  Step 'Restore mode'
  Get-Process -Name 'Medal' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
  if (Test-Path -LiteralPath $AsarBak) {
    Copy-Item -LiteralPath $AsarBak -Destination $AsarPath -Force
    Ok "Restored app.asar from backup"
  } else { Warn "No backup found at $AsarBak - cannot restore asar" }
  if (Test-Path -LiteralPath $UpdateDisabled) {
    Move-Item -LiteralPath $UpdateDisabled -Destination $UpdateExe -Force
    Ok 'Restored Update.exe (updates re-enabled)'
  } elseif (Test-Path -LiteralPath "$UpdateExe.bak") {
    Copy-Item -LiteralPath "$UpdateExe.bak" -Destination $UpdateExe -Force
    Ok 'Restored Update.exe from .bak'
  }
  Write-Host "`nDone. Start Medal normally." -ForegroundColor Green
  exit 0
}

# --- 3. Preconditions ---
Step 'Preconditions'
try { $nodeV = (node --version 2>&1) } catch { throw 'node.js not found. Install LTS from https://nodejs.org then re-run.' }
Ok "node $nodeV"
try { npx --yes -p @electron/asar asar --version 2>&1 | Out-Null } catch { throw 'npx/@electron/asar failed. Need internet for first run.' }
Ok '@electron/asar packer available'

# --- 4. Kill Medal ---
Step 'Closing Medal'
Get-Process -Name 'Medal' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Ok 'Medal processes stopped'

# --- 5. Backup ---
Step 'Backup'
if (-not (Test-Path -LiteralPath $AsarBak)) {
  Copy-Item -LiteralPath $AsarPath -Destination $AsarBak -Force
  Ok "Backup created: $AsarBak"
} else { Ok 'Backup already exists - keeping original' }
# versioned backup too
try {
  $sq = Join-Path $MedalRoot 'current\sq.version'
  $ver = 'unknown'
  if (Test-Path -LiteralPath $sq) {
    $xml = Get-Content -LiteralPath $sq -Raw
    if ($xml -match '<version>([^<]+)</version>') { $ver = $Matches[1] }
  }
  $verBak = "$AsarPath.bak.$ver"
  if (-not (Test-Path -LiteralPath $verBak)) { Copy-Item -LiteralPath $AsarPath -Destination $verBak -Force; Ok "Versioned backup: $verBak" }
} catch { Warn "Versioned backup skipped: $_" }

# --- 6. Extract ---
Step 'Extracting app.asar'
$Work = Join-Path ([IO.Path]::GetTempPath()) ("medal-mod-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
& npx --yes -p @electron/asar asar extract "$AsarPath" "$Work\app" 2>&1 | Out-Null
if (-not (Test-Path -LiteralPath "$Work\app\renderer.min.js")) { throw 'Extract failed: renderer.min.js missing' }
Ok "Extracted to $Work\app"

# --- 7. Patch via embedded node script ---
Step 'Patching (Home/Discover/Quests/Premium -> Library, ads disabled)'
$PatchJs = Join-Path $Work 'patch.cjs'
$PatchCode = @'
// Medal debloat patcher (embedded). Exits non-zero on any assert fail.
const fs = require('fs');
const path = require('path');
const dir = process.argv[2];
const rmin = path.join(dir, 'renderer.min.js');
function assertCount(s, needle, expected, label) {
  let c = 0, i = 0;
  while ((i = s.indexOf(needle, i)) !== -1) { c++; i += needle.length; }
  if (c !== expected) throw new Error(`ASSERT FAIL [${label}]: expected ${expected} got ${c} :: ${needle.slice(0,110)}`);
}
function replaceOnce(s, needle, repl, label) { assertCount(s, needle, 1, label); return s.replace(needle, repl); }
function replaceAllCount(s, needle, repl, expected, label) { assertCount(s, needle, expected, label); return s.split(needle).join(repl); }
let s = fs.readFileSync(rmin, 'utf8');
s = replaceOnce(s, '{icon:(0,a.jsx)(W,{shape:"home-filled",size:24}),label:i({id:"home",defaultMessage:[{type:0,value:"Home"}]}),route:"/home"},', '', 'nav-home');
s = replaceOnce(s, ',{icon:(0,a.jsx)(W,{shape:"game-filled",size:24}),label:i({id:"discover",defaultMessage:[{type:0,value:"Discover"}]}),route:"/games"}', '', 'nav-discover');
s = replaceOnce(s, 'Y.top.push({icon:(0,a.jsx)(W,{shape:"quests-filled",size:24}),label:i({id:"quests",defaultMessage:[{type:0,value:"Quests"}]}),route:"/quests",isQuests:!0}),', '', 'nav-quests');
s = replaceOnce(s, 'q&&Y.top.push({icon:(0,a.jsx)(W,{shape:"medal-premium",size:32,color:"var(--color-brand-primary-400)"}),label:z?i({id:"medal-premium",defaultMessage:[{type:0,value:"Medal Premium"}]}):e?.premiumTrialUsed?i({id:"get-premium",defaultMessage:[{type:0,value:"Get Premium"}]}):i({id:"try-premium",defaultMessage:[{type:0,value:"Try Premium Free"}]}),route:Pw,isPremium:!0}),', '', 'nav-premium');
s = replaceOnce(s, 'c("/home")', 'c("/library")', 'logo1');
s = replaceOnce(s, 'd("/home")', 'd("/library")', 'logo2');
s = replaceOnce(s, 's||"/home"', 's||"/library"', 'default1');
s = replaceOnce(s, 'pathname||"/home"', 'pathname||"/library"', 'default2');
s = replaceOnce(s, 'e("/home",{replace:!0})', 'e("/library",{replace:!0})', 'invalid');
s = replaceOnce(s, '["/home","/login"]', '["/library","/login"]', 'homelogin');
s = replaceAllCount(s, 'e==="/home"', 'e==="/library"', 2, 'gameguard');
s = replaceOnce(s, 'Y==="/home"', 'Y==="/library"', 'navclick-tele');
s = replaceAllCount(s, 'target:"home"', 'target:"library"', 2, 'telemetry');
s = replaceOnce(s, 'activeTab:"home"', 'activeTab:"library"', 'activetab');
// --- ADS: master provider switch (kills all AdProvider ad units app-wide) ---
s = replaceOnce(s, 's=Pt("ads-enabled",!0)', 's=!1', 'ads-flag');
s = replaceOnce(s, 'qs()?.[ja.SKIP_ADS]===!1&&s', '!1', 'ads-unit');
fs.writeFileSync(rmin, s);
console.log('renderer.min.js patched, len=' + s.length);
// --- ADS: useAdsEnabled hook -> always false (kills post-upload ad + 2 min.js spots) ---
const adsPath = path.join(dir, 'chunks', 'renderer-useAdsEnabled.js');
let ah = fs.readFileSync(adsPath, 'utf8');
ah = replaceOnce(ah, '??!0', '??!1', 'ads-enabled-default');
fs.writeFileSync(adsPath, ah);
console.log('useAdsEnabled forced false');
// --- ADS: library grid -> no injected ad cells, no sponsor cards ---
const libAdPath = path.join(dir, 'chunks', 'renderer-LibraryAd.js');
let lh = fs.readFileSync(libAdPath, 'utf8');
lh = replaceOnce(lh, 'Xt({shouldShowAds:o,sponsorCard:n})', 'Xt({shouldShowAds:!1,sponsorCard:null})', 'libad-grid');
fs.writeFileSync(libAdPath, lh);
console.log('LibraryAd grid ads + sponsor cards disabled');
const stub = (name) => `import{o as a}from"./renderer-chunk.js";import{t as d}from"./renderer-react.production.js";import{n as n}from"./renderer-router.js";var t=a(d());function r(){(0,t.useEffect)(()=>{n("/library",{replace:!0})},[]);return null}export{r as default};\n//# sourceMappingURL=${name}.map\n`;
for (const f of ['renderer-HomeRoute.js', 'renderer-Games.2.js', 'renderer-QuestsPage.js']) {
  const p = path.join(dir, 'chunks', f);
  if (!fs.existsSync(p)) throw new Error('missing chunk ' + f);
  fs.writeFileSync(p, stub(f));
  console.log('stubbed ' + f);
}
// --- ADS: stub ad-unit chunks to null components (backstop: nothing can mount an ad) ---
const nullDefault = (name) => `function N(){return null}export default N;\n//# sourceMappingURL=${name}.map\n`;
const nullNamedT = (name) => `function N(){return null}export{N as t};\n//# sourceMappingURL=${name}.map\n`;
for (const f of ['renderer-AdLargeRect.js', 'renderer-AdMediumRect.js', 'renderer-AdLeaderboardBanner.js', 'renderer-LibraryElementAd.js']) {
  const p = path.join(dir, 'chunks', f);
  if (!fs.existsSync(p)) throw new Error('missing ad chunk ' + f);
  fs.writeFileSync(p, nullDefault(f));
  console.log('ad-stubbed ' + f);
}
for (const f of ['renderer-AditudeAdMediumRect.js', 'renderer-AditudeAdMediumLargeRect.js', 'renderer-AditudeAdLargeRect.js']) {
  const p = path.join(dir, 'chunks', f);
  if (!fs.existsSync(p)) throw new Error('missing aditude chunk ' + f);
  fs.writeFileSync(p, nullNamedT(f));
  console.log('ad-stubbed ' + f);
}
const s2 = fs.readFileSync(rmin, 'utf8');
for (const bad of ['route:"/home"', 'route:"/games"', 'route:"/quests"', 'route:Pw,isPremium', 'Pt("ads-enabled",!0)', 'SKIP_ADS]===!1&&s']) {
  if (s2.includes(bad)) throw new Error('LEFTOVER FOUND: ' + bad);
}
if (!s2.includes('route:"/library"')) throw new Error('Library route missing!');
const a2 = fs.readFileSync(adsPath, 'utf8');
if (a2.includes('??!0')) throw new Error('AD LEFTOVER: useAdsEnabled still defaults true');
const l2 = fs.readFileSync(libAdPath, 'utf8');
if (l2.includes('shouldShowAds:o')) throw new Error('AD LEFTOVER: LibraryAd grid injection intact');
console.log('VERIFY OK');
'@
Set-Content -LiteralPath $PatchJs -Value $PatchCode -Encoding UTF8
node $PatchJs "$Work\app"
if ($LASTEXITCODE -ne 0) { throw 'Patch script failed (version mismatch?). Restore backup and report Medal version.' }
Ok 'Patch asserts passed'
node --check "$Work\app\renderer.min.js"
Ok 'JS syntax valid'

# --- 8. Repack (must preserve 585 unpacked files: exes/nodes/src/assets/vendor) ---
Step 'Repacking app.asar'
& npx --yes -p @electron/asar asar pack "$Work\app" "$Work\app.asar" --unpack "{*.node,*.exe,lib/sqlite3.exe}" --unpack-dir "{src/assets,vendor/better-sqlite3}" 2>&1 | Out-Null
if (-not (Test-Path -LiteralPath "$Work\app.asar")) { throw 'Repack failed' }
$listed = & npx --yes -p @electron/asar asar list "$Work\app.asar" 2>&1 | Select-String 'renderer-HomeRoute'
if (-not $listed) { throw 'Repack verify failed: renderer-HomeRoute missing from new asar' }
Ok "New asar: $([math]::Round((Get-Item -LiteralPath "$Work\app.asar").Length/1MB,1)) MB"
Copy-Item -LiteralPath "$Work\app.asar" -Destination $AsarPath -Force
Ok 'Installed patched app.asar (unpacked layout preserved, .unpacked dir untouched)'

# --- 9. Block auto-updates (reversible) ---
if (-not $KeepUpdates) {
  Step 'Blocking auto-updates (reversible via -Restore)'
  if ((Test-Path -LiteralPath $UpdateExe) -and (-not (Test-Path -LiteralPath $UpdateDisabled))) {
    if (-not (Test-Path -LiteralPath "$UpdateExe.bak")) { Copy-Item -LiteralPath $UpdateExe -Destination "$UpdateExe.bak" -Force }
    Move-Item -LiteralPath $UpdateExe -Destination $UpdateDisabled -Force
    Ok 'Update.exe -> Update.exe.disabled (Medal can no longer self-update/wipe mod)'
  } else { Warn 'Update.exe already blocked or missing - skipping' }
  Warn 'You must re-run this script after any manual Medal reinstall/update.'
} else {
  Warn 'Keeping updater enabled - next Medal update WILL wipe the mod (just re-run script).'
}

# --- 10. Cleanup + verify ---
Step 'Verify'
& npx --yes -p @electron/asar asar list "$AsarPath" 2>&1 | Select-String 'renderer-HomeRoute|renderer-Games' | ForEach-Object { Ok $_.ToString().Trim() }
Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
Ok 'Temp cleaned'

Write-Host "`n==============================================" -ForegroundColor Green
Write-Host ' Medal debloat installed.' -ForegroundColor Green
Write-Host ' Removed: Home, Discover (/games), Quests, Premium nav.' -ForegroundColor Green
Write-Host ' Disabled: all display ads, library-grid ads, sponsor cards, post-upload ad.' -ForegroundColor Green
Write-Host ' Everything now lands on Library (/library).' -ForegroundColor Green
Write-Host ' Restore: powershell -ExecutionPolicy Bypass -File .\Medal-Debloat.ps1 -Restore' -ForegroundColor Yellow
Write-Host ' Start Medal normally and check left bar.' -ForegroundColor Green
Write-Host '==============================================`n' -ForegroundColor Green
