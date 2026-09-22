<#
.SYNOPSIS
  Medal Debloat Mod - strips Home (/home), Discover (/games), Quests, Premium nav; redirects everything to Library; disables ads completely.
.DESCRIPTION
  Run with no flags for the interactive menu (Patch / Restore / Block-Unblock updates / Status / Quit).
  Flags bypass the menu for automation: -Patch, -Restore, -KeepUpdates (legacy, updater is now a separate toggle).
  Tested against Medal 2638.479.1 (Electron 43, Velopack, app.asar 41MB).
  - Patch: kills Medal, backs up app.asar, extracts asar, patches renderer.min.js + redirect stubs + ad stubs, repacks, verifies.
  - Updates are managed separately (menu item 3). Any Medal update wipes the mod - just re-run Patch.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Medal-Debloat.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Medal-Debloat.ps1 -Patch
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Medal-Debloat.ps1 -Restore
#>
param(
  [switch]$Restore,
  [switch]$Patch,
  [switch]$KeepUpdates,
  [switch]$Menu
)

$ErrorActionPreference = 'Stop'
$ModVersion = '6'
$PinnedMedal = '2638.479.1'

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  [!] $msg" -ForegroundColor Yellow }

# --- 0. Elevate ---
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
  Warn 'Not elevated - relaunching as admin...'
  $elevArgs = "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
  if ($Restore) { $elevArgs += ' -Restore' }
  if ($Patch) { $elevArgs += ' -Patch' }
  if ($KeepUpdates) { $elevArgs += ' -KeepUpdates' }
  if ($Menu) { $elevArgs += ' -Menu' }
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
$ModInfoPath = "$AsarPath.modinfo"
$PluginsDir = Join-Path $MedalRoot 'plugins'
Step "Medal found at $MedalRoot"
Ok "app.asar: $([math]::Round((Get-Item -LiteralPath $AsarPath).Length/1MB,1)) MB"

function Get-MedalVersion {
  $sq = Join-Path $MedalRoot 'current\sq.version'
  if (Test-Path -LiteralPath $sq) {
    $xml = Get-Content -LiteralPath $sq -Raw
    if ($xml -match '<version>([^<]+)</version>') { return $Matches[1] }
  }
  return 'unknown'
}

function Write-ModInfo($state) {
  $info = [ordered]@{
    mod   = $ModVersion
    medal = (Get-MedalVersion)
    date  = (Get-Date -Format 'o')
    state = $state
  }
  ($info | ConvertTo-Json) | Set-Content -LiteralPath $ModInfoPath -Encoding UTF8 -Force
}

function Get-ModStatus {
  $st = [ordered]@{
    MedalVer = (Get-MedalVersion)
    Backup   = (Test-Path -LiteralPath $AsarBak)
    Updates  = 'enabled'
    State    = 'UNKNOWN'
    ModInfo  = $null
  }
  if (Test-Path -LiteralPath $ModInfoPath) {
    try { $st.ModInfo = Get-Content -LiteralPath $ModInfoPath -Raw | ConvertFrom-Json } catch { }
  }
  if (Test-Path -LiteralPath $UpdateDisabled) { $st.Updates = 'blocked' }
  elseif (-not (Test-Path -LiteralPath $UpdateExe)) { $st.Updates = 'missing' }
  if ($st.Backup) {
    $h1 = (Get-FileHash -LiteralPath $AsarPath -Algorithm SHA256).Hash
    $h2 = (Get-FileHash -LiteralPath $AsarBak -Algorithm SHA256).Hash
    if ($h1 -eq $h2) { $st.State = 'STOCK' }
    elseif ($st.ModInfo -and $st.ModInfo.mod -eq $ModVersion -and $st.ModInfo.state -eq 'modded') { $st.State = 'MODDED-CURRENT' }
    else { $st.State = 'MODDED-OLD' }
  } else {
    if ($st.ModInfo -and $st.ModInfo.state -eq 'modded') { $st.State = 'MODDED-NOBACKUP' }
    else { $st.State = 'STOCK-NOBACKUP' }
  }
  return $st
}

function Show-Status($st) {
  Write-Host ''
  Write-Host ' Medal status' -ForegroundColor Cyan
  Write-Host "   Medal version : $($st.MedalVer)$(if ($st.MedalVer -ne $PinnedMedal) { "  (pinned: $PinnedMedal - patches may fail elsewhere)" })"
  Write-Host "   Install state : $($st.State)"
  Write-Host "   Backup        : $(if ($st.Backup) { 'present' } else { 'MISSING' })"
  Write-Host "   Updates       : $($st.Updates)"
  if ($st.ModInfo) { Write-Host "   Last mod      : v$($st.ModInfo.mod) on $($st.ModInfo.date) ($($st.ModInfo.state))" }
}

function Stop-Medal {
  Get-Process -Name 'Medal' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
}

function Invoke-RestoreFlow($Headless) {
  Step 'Restore stock'
  if (-not (Test-Path -LiteralPath $AsarBak)) { throw "No backup at $AsarBak - cannot restore. Reinstall Medal if you need stock." }
  $nowVer = Get-MedalVersion
  $matchBak = "$AsarPath.bak.$nowVer"
  if (-not (Test-Path -LiteralPath $matchBak)) {
    Warn "No versioned backup for installed Medal $nowVer - backup may be stale."
    if (-not $Headless) {
      $ans = Read-Host 'Restore anyway? [y/N]'
      if ($ans -ne 'y' -and $ans -ne 'Y') { Ok 'Cancelled.'; return }
    }
  }
  Stop-Medal
  Copy-Item -LiteralPath $AsarBak -Destination $AsarPath -Force
  Ok 'Restored app.asar from backup'
  Write-ModInfo 'stock'
  if ($Headless) {
    if (Test-Path -LiteralPath $UpdateDisabled) {
      Move-Item -LiteralPath $UpdateDisabled -Destination $UpdateExe -Force
      Ok 'Restored Update.exe (updates re-enabled)'
    } elseif (Test-Path -LiteralPath "$UpdateExe.bak") {
      Copy-Item -LiteralPath "$UpdateExe.bak" -Destination $UpdateExe -Force
      Ok 'Restored Update.exe from .bak'
    }
  } else {
    if ((Test-Path -LiteralPath $UpdateDisabled) -or (Test-Path -LiteralPath "$UpdateExe.bak")) {
      $ans = Read-Host 'Re-enable updates too? [Y/n]'
      if ($ans -ne 'n' -and $ans -ne 'N') { Enable-Updates }
    }
  }
  Write-Host "`nDone. Start Medal normally." -ForegroundColor Green
}

function Disable-Updates {
  if ((Test-Path -LiteralPath $UpdateExe) -and (-not (Test-Path -LiteralPath $UpdateDisabled))) {
    if (-not (Test-Path -LiteralPath "$UpdateExe.bak")) { Copy-Item -LiteralPath $UpdateExe -Destination "$UpdateExe.bak" -Force }
    Move-Item -LiteralPath $UpdateExe -Destination $UpdateDisabled -Force
    Ok 'Update.exe -> Update.exe.disabled (Medal can no longer self-update/wipe mod)'
  } else { Warn 'Update.exe already blocked or missing - skipping' }
}

function Enable-Updates {
  if (Test-Path -LiteralPath $UpdateDisabled) {
    Move-Item -LiteralPath $UpdateDisabled -Destination $UpdateExe -Force
    Ok 'Restored Update.exe (updates re-enabled)'
  } elseif (Test-Path -LiteralPath "$UpdateExe.bak") {
    Copy-Item -LiteralPath "$UpdateExe.bak" -Destination $UpdateExe -Force
    Ok 'Restored Update.exe from .bak'
  } else { Warn 'No Update.exe backup found - cannot re-enable' }
}

$SampleYouTube = @'
// Sample plugin: youtube-backup — one-click YouTube login + auto/manual clip uploads.
// Folder: %LOCALAPPDATA%\Medal\plugins\youtube-backup\plugin.js
// Setup: create a FREE "Desktop app" OAuth client at console.cloud.google.com
// (enable YouTube Data API v3), paste the client ID in plugin Settings, open
// this plugin's page and click Connect. Approve in the browser — done.
(function () {
  var S = { clientId: "", refreshToken: "", accessToken: "", accessExp: 0, autoUpload: true, privacy: "unlisted", titleTemplate: "{game} clip {date}", games: "" };

  api.registerSettings([
    { key: "clientId", label: "Google OAuth client ID (Desktop app type)", placeholder: "xxxx.apps.googleusercontent.com" },
    { key: "autoUpload", label: "Auto-upload new clips", type: "checkbox", default: true },
    { key: "privacy", label: "Privacy", type: "select", default: "unlisted", options: [{ value: "private", label: "Private" }, { value: "unlisted", label: "Unlisted" }, { value: "public", label: "Public" }] },
    { key: "titleTemplate", label: "Title template ({game}, {date})", default: "{game} clip {date}" },
    { key: "games", label: "Only these games (comma slugs, blank = all)", placeholder: "gta-v, valorant" }
  ]);

  // ---- PKCE (pure JS SHA256, no dependencies) ----
  function sha256(ascii) {
    function rr(v, a) { return (v >>> a) | (v << (32 - a)); }
    var maxWord = Math.pow(2, 32), result = "";
    var words = [], bitLen = ascii.length * 8;
    var hash = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
    var k = [0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2];
    ascii += "\x80";
    while (ascii.length % 64 - 56) ascii += "\x00";
    for (var i = 0; i < ascii.length; i++) { var j = ascii.charCodeAt(i); if (j >> 8) return ""; words[i >> 2] |= j << ((3 - i) % 4) * 8; }
    words[words.length] = (bitLen / maxWord) | 0; words[words.length] = bitLen;
    for (var j2 = 0; j2 < words.length;) {
      var w = words.slice(j2, j2 += 16), old = hash.slice(0);
      for (var i2 = 0; i2 < 64; i2++) {
        var w15 = w[i2 - 15], w2 = w[i2 - 2];
        var a = hash[0], e = hash[4];
        var t1 = hash[7] + (rr(e, 6) ^ rr(e, 11) ^ rr(e, 25)) + ((e & hash[5]) ^ (~e & hash[6])) + k[i2] + (w[i2] = i2 < 16 ? w[i2] : (w[i2 - 16] + (rr(w15, 7) ^ rr(w15, 18) ^ (w15 >>> 3)) + w[i2 - 7] + (rr(w2, 17) ^ rr(w2, 19) ^ (w2 >>> 10))) | 0);
        var t2 = (rr(a, 2) ^ rr(a, 13) ^ rr(a, 22)) + ((a & hash[1]) ^ (a & hash[2]) ^ (hash[1] & hash[2]));
        hash = [(t1 + t2) | 0].concat(hash); hash[4] = (hash[4] + t1) | 0;
      }
      for (var i3 = 0; i3 < 8; i3++) hash[i3] = (hash[i3] + old[i3]) | 0;
    }
    for (var i4 = 0; i4 < 8; i4++) for (var j3 = 3; j3 + 1; j3--) { var b = (hash[i4] >> (j3 * 8)) & 255; result += (b < 16 ? "0" : "") + b.toString(16); }
    return result;
  }
  function b64url(hex) {
    var bin = "";
    for (var i = 0; i < hex.length; i += 2) bin += String.fromCharCode(parseInt(hex.slice(i, i + 2), 16));
    return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  }
  function verifier() { var c = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~", s = ""; for (var i = 0; i < 64; i++) s += c[Math.floor(Math.random() * c.length)]; return s; }

  api.registerPage({
    id: "youtube-backup",
    title: "YouTube Backup",
    render: function (a) {
      var R = a.React;
      var st = R.useState({ msg: "Checking…", busy: false, connected: false, clips: [] });
      var s = st[0], setS = st[1];
      function refresh() {
        load().then(function () {
          var ok = !!(S.clientId && S.refreshToken);
          return a.MedalIPC.getContents({ limit: 10 }).then(function (q) {
            setS({ msg: ok ? "Connected. New clips auto-upload" + (S.autoUpload ? "." : " (auto-upload off).") : "Add your client ID in Plugins → youtube-backup → Settings, save, then Connect.", busy: false, connected: ok, clips: (q && q.contents) || [] });
          }, function () { setS({ msg: ok ? "Connected." : "Not connected.", busy: false, connected: ok, clips: [] }); });
        });
      }
      R.useEffect(function () { refresh(); }, []);
      function connect() {
        setS({ msg: "Contacting Google…", busy: true, connected: false, clips: s.clips });
        load().then(function () {
          if (!S.clientId) throw new Error("Set your client ID in plugin Settings first.");
          var v = verifier(), ch = b64url(sha256(v));
          return a.MedalIPC.plugins.oauthListen().then(function (r) {
            var p = new URLSearchParams({ client_id: S.clientId, redirect_uri: "http://127.0.0.1:" + r.port, response_type: "code", scope: "https://www.googleapis.com/auth/youtube.upload", access_type: "offline", prompt: "consent", code_challenge: ch, code_challenge_method: "S256" });
            a.MedalIPC.openExternal("https://accounts.google.com/o/oauth2/v2/auth?" + p.toString());
            setS({ msg: "Approve in your browser, then return here…", busy: true, connected: false, clips: s.clips });
            return a.MedalIPC.plugins.oauthAwait().then(function (o) {
              if (!o || !o.code) throw new Error((o && o.error) || "login cancelled");
              return exchange(o.code, v, r.port);
            });
          });
        }).then(function () { refresh(); }, function (e) { setS({ msg: "Failed: " + String((e && e.message) || e), busy: false, connected: false, clips: s.clips }); });
      }
      function uploadOne(c) {
        setS({ msg: "Uploading…", busy: true, connected: s.connected, clips: s.clips });
        load().then(function () { return uploadClipObj(c); }).then(function (id) { setS({ msg: "Uploaded" + (id ? ": " + id : "!"), busy: false, connected: s.connected, clips: s.clips }); }, function (e) { setS({ msg: "Upload failed: " + String((e && e.message) || e), busy: false, connected: s.connected, clips: s.clips }); });
      }
      function label(c, i) {
        var g = ""; try { g = (c.getGame && c.getGame() && (c.getGame().slug || c.getGame().name)) || ""; } catch (e) { }
        var id = ""; try { id = c.getContentId ? c.getContentId() : ""; } catch (e) { }
        return ((g ? g + " — " : "") + "clip " + (id ? String(id).slice(-6) : "#" + (i + 1)));
      }
      return a.el("div", { style: { display: "flex", flexDirection: "column", gap: "10px", maxWidth: "640px" } },
        a.el("h2", { style: { fontSize: "20px", margin: 0 } }, "YouTube Backup"),
        a.el("div", { style: { fontSize: "13px", color: "#c9c9c9" } }, s.msg),
        a.el("button", { disabled: s.busy, onClick: connect, style: { cursor: "pointer", border: "1px solid #b6f34a", background: "#1c2607", color: "#d7ff6b", borderRadius: "8px", padding: "8px 14px", fontSize: "14px", width: "fit-content", opacity: s.busy ? 0.5 : 1 } }, s.connected ? "Reconnect YouTube" : "Connect YouTube"),
        a.el("h3", { style: { fontSize: "15px", margin: "8px 0 0" } }, "Recent clips"),
        s.clips.length === 0 ? a.el("div", { style: { fontSize: "13px", color: "#9a9a9a" } }, "No clips found.") :
          s.clips.map(function (c, i) { return a.el("div", { key: i, style: { display: "flex", alignItems: "center", gap: "10px", border: "1px solid #2c2c2c", borderRadius: "8px", padding: "8px 12px", fontSize: "13px" } }, a.el("span", { style: { flex: 1 } }, label(c, i)), a.el("button", { disabled: s.busy, onClick: function () { uploadOne(c); }, style: { cursor: "pointer", border: "1px solid #3a3a3a", background: "#222", color: "#eee", borderRadius: "6px", padding: "5px 10px", fontSize: "12px" } }, "Upload")); }));
    }
  });

  async function load() {
    var keys = ["clientId", "refreshToken", "accessToken", "accessExp", "autoUpload", "privacy", "titleTemplate", "games"];
    for (var i = 0; i < keys.length; i++) {
      var v = await api.store.get(keys[i], null);
      if (v !== null && v !== undefined && v !== "") S[keys[i]] = v;
    }
    if (S.autoUpload === "false" || S.autoUpload === false) S.autoUpload = false;
  }

  async function exchange(code, v, port) {
    var body = new URLSearchParams({ client_id: S.clientId, code: code, grant_type: "authorization_code", redirect_uri: "http://127.0.0.1:" + port, code_verifier: v });
    var r = await fetch("https://oauth2.googleapis.com/token", { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: body.toString() });
    var j = await r.json();
    if (!r.ok) throw new Error(j.error_description || j.error || ("HTTP " + r.status));
    await api.store.set("refreshToken", j.refresh_token || S.refreshToken);
    await api.store.set("accessToken", j.access_token);
    await api.store.set("accessExp", Date.now() + (j.expires_in || 3600) * 1000);
    S.refreshToken = j.refresh_token || S.refreshToken; S.accessToken = j.access_token; S.accessExp = Date.now() + (j.expires_in || 3600) * 1000;
  }

  async function token() {
    if (S.accessToken && Date.now() < S.accessExp - 60000) return S.accessToken;
    var body = new URLSearchParams({ client_id: S.clientId, refresh_token: S.refreshToken, grant_type: "refresh_token" });
    var r = await fetch("https://oauth2.googleapis.com/token", { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: body.toString() });
    var j = await r.json();
    if (!r.ok) throw new Error("token refresh failed: " + (j.error || r.status));
    S.accessToken = j.access_token; S.accessExp = Date.now() + (j.expires_in || 3600) * 1000;
    await api.store.set("accessToken", S.accessToken); await api.store.set("accessExp", S.accessExp);
    return S.accessToken;
  }

  function toBytes(b) {
    if (typeof b === "string") return new TextEncoder().encode(b);
    if (b instanceof Uint8Array) return b;
    if (ArrayBuffer.isView(b)) return new Uint8Array(b.buffer, b.byteOffset, b.byteLength);
    return new Uint8Array(b);
  }

  async function uploadClip(filePath, title) {
    var at = await token();
    var meta = { snippet: { title: title, categoryId: "20" }, status: { privacyStatus: S.privacy || "unlisted", selfDeclaredMadeForKids: false } };
    var init = await fetch("https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status", {
      method: "POST", headers: { Authorization: "Bearer " + at, "Content-Type": "application/json; charset=UTF-8", "X-Upload-Content-Type": "video/mp4" }, body: JSON.stringify(meta)
    });
    if (init.status === 401) { S.accessExp = 0; at = await token(); return uploadClip(filePath, title); }
    if (!init.ok) throw new Error("upload init failed: HTTP " + init.status);
    var session = init.headers.get("location");
    var bytes = toBytes(await api.MedalIPC.fs.readFile(filePath));
    var CH = 8 * 1024 * 1024, off = 0, videoId = null;
    while (off < bytes.length) {
      var end = Math.min(off + CH, bytes.length) - 1;
      var put = await fetch(session, { method: "PUT", headers: { "Content-Length": String(end - off + 1), "Content-Range": "bytes " + off + "-" + end + "/" + bytes.length }, body: bytes.slice(off, end + 1) });
      if (put.status === 308) { var rg = put.headers.get("range"); off = rg ? parseInt(rg.split("-")[1], 10) + 1 : end + 1; continue; }
      if (!put.ok) throw new Error("upload chunk failed: HTTP " + put.status);
      try { videoId = (await put.json()).id; } catch (e) { }
      off = end + 1;
    }
    return videoId;
  }

  function titleFor(game) {
    var d = new Date();
    return (S.titleTemplate || "{game} clip {date}").replace("{game}", game || "Medal").replace("{date}", d.toISOString().slice(0, 10));
  }

  function gameOf(c) { try { return (c.getGame && c.getGame() && (c.getGame().slug || c.getGame().name)) || ""; } catch (e) { return ""; } }
  function pathOf(c) { try { return c.files().current.video; } catch (e) { return null; } }
  function idOf(c, fp) { try { return c.getContentId ? c.getContentId() : fp; } catch (e) { return fp; } }
  function allowed(game) {
    if (!S.games) return true;
    return S.games.split(",").map(function (g) { return g.trim().toLowerCase(); }).filter(Boolean).indexOf(String(game).toLowerCase()) >= 0;
  }

  async function uploadClipObj(c) {
    await load();
    if (!S.clientId || !S.refreshToken) throw new Error("Connect YouTube first.");
    var fp = pathOf(c);
    if (!fp) throw new Error("Could not resolve clip file.");
    if (!allowed(gameOf(c))) throw new Error("Game filtered out by settings.");
    var key = "done:" + idOf(c, fp);
    var id = await uploadClip(fp, titleFor(gameOf(c)));
    await api.store.set(key, id || true);
    api.toast("YouTube backup uploaded" + (id ? ": " + id : ""));
    return id;
  }

  api.onClip(async function () {
    try {
      await load();
      if (!S.autoUpload || !S.clientId || !S.refreshToken) return;
      var q = await api.MedalIPC.getContents({ limit: 5 });
      var clips = (q && q.contents) || [];
      for (var i = 0; i < clips.length; i++) {
        var c = clips[i];
        if (!allowed(gameOf(c))) continue;
        var fp = pathOf(c);
        if (!fp) continue;
        var done = await api.store.get("done:" + idOf(c, fp), null);
        if (done) continue;
        await uploadClip(fp, titleFor(gameOf(c)));
        await api.store.set("done:" + idOf(c, fp), true);
        api.toast("YouTube backup uploaded");
        break; // one per event; next event handles the rest
      }
    } catch (e) { try { console.error("[youtube-backup]", e); } catch (_) { } }
  });

  api.youtubeBackup = { uploadClipObj: uploadClipObj };
})();
'@

function Invoke-RescanPlugins {
  Step 'Rescanning plugins'
  if (-not (Test-Path -LiteralPath $PluginsDir)) { New-Item -ItemType Directory -Path $PluginsDir -Force | Out-Null }
  $list = @()
  foreach ($d in (Get-ChildItem -LiteralPath $PluginsDir -Directory -ErrorAction SilentlyContinue)) {
    if (-not (Test-Path -LiteralPath (Join-Path $d.FullName 'plugin.js'))) { continue }
    $meta = @{ name = $d.Name; entry = 'plugin.js'; enabled = $true; version = ''; author = ''; description = '' }
    $mf = Join-Path $d.FullName 'manifest.json'
    if (Test-Path -LiteralPath $mf) {
      try {
        $m = Get-Content -LiteralPath $mf -Raw | ConvertFrom-Json
        if ($m.version) { $meta.version = [string]$m.version }
        if ($m.author) { $meta.author = [string]$m.author }
        if ($m.description) { $meta.description = [string]$m.description }
        if ($m.entry) { $meta.entry = [string]$m.entry }
      } catch { Warn "Bad manifest in $($d.Name) - using defaults" }
    }
    $list += $meta
  }
  (@{ plugins = $list } | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath (Join-Path $PluginsDir 'plugins.json') -Encoding UTF8 -Force
  Ok "$($list.Count) plugin(s): $((@($list | ForEach-Object { $_.name })) -join ', ')"
}

function Write-PluginScaffold {
  if (-not (Test-Path -LiteralPath $PluginsDir)) { New-Item -ItemType Directory -Path $PluginsDir -Force | Out-Null }
  $sample = Join-Path $PluginsDir 'youtube-backup'
  if (-not (Test-Path -LiteralPath (Join-Path $sample 'plugin.js'))) {
    New-Item -ItemType Directory -Path $sample -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $sample 'manifest.json') -Value (@{ name = 'youtube-backup'; version = '1.0'; author = 'bundled sample'; description = 'Auto-uploads new clips to YouTube. Needs your own Google OAuth client ID (see plugin settings).'; entry = 'plugin.js' } | ConvertTo-Json) -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $sample 'plugin.js') -Value $SampleYouTube -Encoding UTF8
    Ok 'Sample plugin installed: youtube-backup'
  } else { Ok 'Sample plugin already present - keeping it' }
  Invoke-RescanPlugins
}

function Invoke-UpdateToggle {
  if (Test-Path -LiteralPath $UpdateDisabled) {
    Step 'Unblocking updates'
    Enable-Updates
    Warn 'Next Medal update WILL wipe the mod (just re-run Patch).'
  } else {
    Step 'Blocking updates'
    Disable-Updates
    Warn 'You must re-run Patch after any manual Medal reinstall/update.'
  }
}

function Invoke-PatchFlow($Headless) {
  Step 'Preflight'
  $st = Get-ModStatus
  Show-Status $st
  if ($st.MedalVer -ne $PinnedMedal) { Warn "Medal $($st.MedalVer) != tested $PinnedMedal. Asserts will abort if code drifted." }
  switch ($st.State) {
    'MODDED-CURRENT' {
      Warn 'Current mod already installed.'
      if (-not $Headless) {
        $ans = Read-Host 'Re-patch from backup? [y/N]'
        if ($ans -ne 'y' -and $ans -ne 'Y') { Ok 'Cancelled.'; return }
      }
    }
    'MODDED-OLD' { Warn 'Older mod detected - restoring stock from backup first, then patching.' }
    'MODDED-NOBACKUP' { throw 'Install is modded but no backup exists. Reinstall Medal, then run Patch.' }
  }
  if ($st.State -like 'MODDED*') {
    Stop-Medal
    Copy-Item -LiteralPath $AsarBak -Destination $AsarPath -Force
    Ok 'Restored stock from backup (re-patch base)'
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

  Step 'Plugin folder'
  Write-PluginScaffold

# --- 6. Extract ---
Step 'Extracting app.asar'
$Work = Join-Path ([IO.Path]::GetTempPath()) ("medal-mod-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
& npx --yes -p @electron/asar asar extract "$AsarPath" "$Work\app" 2>&1 | Out-Null
if (-not (Test-Path -LiteralPath "$Work\app\renderer.min.js")) { throw 'Extract failed: renderer.min.js missing' }
  Ok "Extracted to $Work\app"

  Step 'Staging plugin system chunks'
  $PlugLoader = @'
import{o as a}from"./renderer-chunk.js";import{t as d}from"./renderer-react.production.js";import{n as nav}from"./renderer-router.js";
var R=a(d());
const DIR=__PLUGINS_DIR__;
function dec(b){if(typeof b=="string")return b;try{var u8=b instanceof Uint8Array?b:ArrayBuffer.isView(b)?new Uint8Array(b.buffer,b.byteOffset,b.byteLength):new Uint8Array(b);return new TextDecoder().decode(u8)}catch(e){return ""}}
function kvGet(k){return MedalIPC.kvGet(k).catch(function(){return null})}
function kvPut(k,v){return MedalIPC.kvPut(k,v).catch(function(){})}
function makeApi(id,dir,entry){
  return {
    version:"1",
    React:R,
    el:function(t,p){var c=Array.prototype.slice.call(arguments,2);return R.createElement.apply(R,[t,p].concat(c))},
    navigate:function(p,o){return nav(p,o)},
    MedalIPC:MedalIPC,
    plugin:{id:id,dir:dir},
    store:{
      get:function(k,f){return kvGet("medal-plugins:"+id+":"+k).then(function(v){return v==null?f:v})},
      set:function(k,v){return kvPut("medal-plugins:"+id+":"+k,v)}
    },
    onClip:function(cb){var off=MedalIPC.onEvent("contentChanged",cb);entry.cleanups.push(off);return off},
    registerPage:function(pg){entry.pages.push({plugin:id,pageId:pg.id||id,title:pg.title||pg.id||id,render:pg.render})},
    registerSettings:function(schema){entry.schema=schema},
    toast:function(m){try{if(MedalIPC.toast)MedalIPC.toast(m);else console.log("[plugin:"+id+"]",m)}catch(e){console.log("[plugin:"+id+"]",m)}}
  };
}
var started=false;
export async function init(){
  if(started)return;started=true;
  var reg={plugins:[],pages:[],errors:[]};
  window.__medalPlugins=reg;
  try{
    var man=JSON.parse(dec(await MedalIPC.fs.readFile(DIR+"\\plugins.json")));
    var enMap=await kvGet("medal-plugins:enabled")||{};
    var list=man.plugins||[];
    for(var k=0;k<list.length;k++){
      var p=list[k];
      var enabled=enMap[p.name]!==undefined?enMap[p.name]:(p.enabled!==false);
      var entry={name:p.name,version:p.version||"",author:p.author||"",description:p.description||"",enabled:enabled,loaded:false,error:null,pages:[],schema:null,cleanups:[]};
      reg.plugins.push(entry);
      if(!enabled)continue;
      try{
        var code=dec(await MedalIPC.fs.readFile(DIR+"\\"+p.name+"\\"+(p.entry||"plugin.js")));
        var api=makeApi(p.name,DIR+"\\"+p.name,entry);
        entry.api=api;
        new Function("api","pluginId",code+"\n//# sourceURL=medal-plugin-"+p.name+".js")(api,p.name);
        entry.loaded=true;
      }catch(e){entry.error=String((e&&e.message)||e);try{console.error("[plugins] failed: "+p.name,e)}catch(_){}}
    }
  }catch(e){reg.errors.push("manifest: "+String((e&&e.message)||e));try{console.error("[plugins] manifest failed",e)}catch(_){}}
}
'@
  Set-Content -LiteralPath (Join-Path $Work 'app\chunks\renderer-PluginLoader.js') -Value $PlugLoader -Encoding UTF8
  $PlugHome = @'
import{o as a}from"./renderer-chunk.js";import{t as d}from"./renderer-react.production.js";import{t as f}from"./renderer-react-jsx-runtime.production.js";import{n as nav}from"./renderer-router.js";
var t=a(d()),r=f();
const DIR=__PLUGINS_DIR__;
const S={page:{padding:"24px",maxWidth:"860px",color:"#e8e8e8"},h:{fontSize:"22px",fontWeight:"700",margin:"0 0 4px"},sub:{color:"#9a9a9a",fontSize:"13px",margin:"0 0 16px"},card:{border:"1px solid #2c2c2c",borderRadius:"10px",padding:"14px 16px",marginBottom:"12px",background:"#141414"},row:{display:"flex",alignItems:"center",gap:"10px"},name:{fontSize:"15px",fontWeight:"600"},meta:{color:"#9a9a9a",fontSize:"12px"},desc:{fontSize:"13px",color:"#c9c9c9",marginTop:"6px"},btn:{cursor:"pointer",border:"1px solid #3a3a3a",background:"#222",color:"#eee",borderRadius:"8px",padding:"6px 12px",fontSize:"13px"},btnPri:{cursor:"pointer",border:"1px solid #b6f34a",background:"#1c2607",color:"#d7ff6b",borderRadius:"8px",padding:"6px 12px",fontSize:"13px"},err:{color:"#ff7a7a",fontSize:"12px",marginTop:"6px"},field:{marginTop:"8px"},lab:{fontSize:"12px",color:"#9a9a9a",display:"block",marginBottom:"4px"},inp:{width:"100%",background:"#0d0d0d",border:"1px solid #3a3a3a",color:"#eee",borderRadius:"6px",padding:"6px 8px",fontSize:"13px",boxSizing:"border-box"}};
function dec(b){if(typeof b=="string")return b;try{var u8=b instanceof Uint8Array?b:ArrayBuffer.isView(b)?new Uint8Array(b.buffer,b.byteOffset,b.byteLength):new Uint8Array(b);return new TextDecoder().decode(u8)}catch(e){return ""}}
function reg(){return window.__medalPlugins||{plugins:[],errors:[]}}
function allPages(){var o=[],ps=reg().plugins||[];for(var i=0;i<ps.length;i++){o=o.concat(ps[i].pages||[])}return o}
function schemas(){var o={},ps=reg().plugins||[];for(var i=0;i<ps.length;i++){if(ps[i].schema)o[ps[i].name]=ps[i].schema}return o}
function Field(pro){var f=pro.f,v=pro.v,on=pro.on;
  if(f.type==="checkbox")return(0,r.jsx)("label",{style:{display:"flex",alignItems:"center",gap:"8px",fontSize:"13px"},children:[(0,r.jsx)("input",{type:"checkbox",checked:!!v,onChange:function(e){on(e.target.checked)}}),(0,r.jsx)("span",{children:f.label||f.key})]});
  if(f.type==="select")return(0,r.jsxs)("div",{style:S.field,children:[(0,r.jsx)("label",{style:S.lab,children:f.label||f.key}),(0,r.jsx)("select",{value:v==null?"":v,onChange:function(e){on(e.target.value)},style:S.inp,children:(f.options||[]).map(function(o){return(0,r.jsx)("option",{value:o.value,children:o.label||o.value},o.value)})})]});
  if(f.type==="textarea")return(0,r.jsxs)("div",{style:S.field,children:[(0,r.jsx)("label",{style:S.lab,children:f.label||f.key}),(0,r.jsx)("textarea",{value:v==null?"":v,rows:3,onChange:function(e){on(e.target.value)},style:S.inp})]});
  return(0,r.jsxs)("div",{style:S.field,children:[(0,r.jsx)("label",{style:S.lab,children:f.label||f.key}),(0,r.jsx)("input",{type:f.type==="password"?"password":"text",value:v==null?"":v,placeholder:f.placeholder||"",onChange:function(e){on(e.target.value)},style:S.inp})]});
}
function PluginCard(pro){var p=pro.p,en=pro.en,sch=pro.sch,onT=pro.onT;
  var vals=pro.vals,setV=pro.setV,onSave=pro.onSave,open=pro.open,onOpen=pro.onOpen;
  var hasPage=allPages().some(function(pg){return pg.plugin===p.name});
  return(0,r.jsxs)("div",{style:S.card,children:[
    (0,r.jsxs)("div",{style:S.row,children:[
      (0,r.jsxs)("div",{style:{flex:1},children:[
        (0,r.jsx)("div",{style:S.name,children:p.name+(p.version?"  ·  v"+p.version:"")}),
        (0,r.jsx)("div",{style:S.meta,children:[p.author||"local plugin",(p.loaded?"  ·  loaded":(p.enabled?"  ·  load pending":"  ·  disabled"))].join("")})
      ]}),
      hasPage?(0,r.jsx)("button",{style:S.btn,onClick:function(){nav("/plugins/"+p.name)},children:"Open"}):null,
      sch?(0,r.jsx)("button",{style:S.btn,onClick:onOpen,children:open?"Hide settings":"Settings"}):null,
      (0,r.jsx)("button",{style:en?S.btn:S.btnPri,onClick:onT,children:en?"Disable":"Enable"})
    ]}),
    p.description?(0,r.jsx)("div",{style:S.desc,children:p.description}):null,
    p.error?(0,r.jsx)("div",{style:S.err,children:"Error: "+p.error}):null,
    (sch&&open)?(0,r.jsxs)("div",{children:[sch.map(function(fl){return(0,r.jsx)(Field,{f:fl,v:vals[fl.key]!=null?vals[fl.key]:fl.default,on:function(v){var o={};o[fl.key]=v;setV(Object.assign({},vals,o))}},fl.key)}),(0,r.jsx)("div",{style:{marginTop:"10px"},children:(0,r.jsx)("button",{style:S.btnPri,onClick:onSave,children:"Save settings"})})]}):null
  ]});
}
export default function PluginsHome(){
  var st=t.useState({loading:true,plugins:[],enabled:{},schemas:{}}),s=st[0],setS=st[1];
  var ui=t.useState({open:null,vals:{}}),u=ui[0],setU=ui[1];
  t.useEffect(function(){var dead=false;
    (async function(){
      try{
        var man=JSON.parse(dec(await MedalIPC.fs.readFile(DIR+"\\plugins.json")));
        var en=await MedalIPC.kvGet("medal-plugins:enabled").catch(function(){return null})||{};
        if(!dead)setS({loading:false,plugins:man.plugins||[],enabled:en,schemas:schemas()});
        for(var k=0;k<20&&!dead;k++){await new Promise(function(x){setTimeout(x,500)});var sc=schemas();if(Object.keys(sc).length){if(!dead)setS(function(p){return Object.assign({},p,{schemas:sc})});break}}
      }catch(e){if(!dead)setS({loading:false,plugins:[],enabled:{},schemas:{},error:String((e&&e.message)||e)})}
    })();
    return function(){dead=true}
  },[]);
  async function toggle(name){var nen=Object.assign({},s.enabled);var cur=nen[name]!==undefined?nen[name]:true;nen[name]=!cur;await MedalIPC.kvPut("medal-plugins:enabled",nen).catch(function(){});setS(Object.assign({},s,{enabled:nen}))}
  async function openSettings(p){var key=p.name;
    if(u.open===key){setU({open:null,vals:{}});return}
    var vals={};
    for(var i=0;i<(p.schema||[]).length;i++){var fl=p.schema[i];var v=await MedalIPC.kvGet("medal-plugins:"+key+":"+fl.key).catch(function(){return null});vals[fl.key]=v==null?fl.default:v}
    setU({open:key,vals:vals});
  }
  async function saveSettings(p){for(var i=0;i<(p.schema||[]).length;i++){var fl=p.schema[i];await MedalIPC.kvPut("medal-plugins:"+p.name+":"+fl.key,u.vals[fl.key]).catch(function(){})}setU({open:null,vals:{}})}
  function withSchema(p){var sc=s.schemas[p.name];return Object.assign({},p,{schema:sc||null})}
  if(s.loading)return(0,r.jsx)("div",{style:S.page,children:"Loading plugins…"});
  if(s.error)return(0,r.jsxs)("div",{style:S.page,children:[(0,r.jsx)("h2",{style:S.h,children:"Plugins"}),(0,r.jsx)("div",{style:S.err,children:s.error})]});
  return(0,r.jsxs)("div",{style:S.page,children:[
    (0,r.jsx)("h2",{style:S.h,children:"Plugins"}),
    (0,r.jsx)("p",{style:S.sub,children:"Drop a plugin folder into the plugins directory, then use Rescan in the mod menu. Restart Medal after enabling or changing settings."}),
    s.plugins.length===0?(0,r.jsx)("div",{style:S.card,children:"No plugins installed yet."}):s.plugins.map(function(p){
      var full=withSchema(p);var en=s.enabled[p.name]!==undefined?s.enabled[p.name]:true;
      return(0,r.jsx)(PluginCard,{p:full,en:en,sch:full.schema,onT:function(){toggle(p.name)},vals:u.vals,setV:function(v){setU({open:u.open,vals:v})},onSave:function(){saveSettings(full)},open:u.open===p.name,onOpen:function(){openSettings(full)}},p.name)
    }),
    (reg().errors||[]).map(function(e,i){return(0,r.jsx)("div",{style:S.err,key:i,children:e})})
  ]});
}
'@
  Set-Content -LiteralPath (Join-Path $Work 'app\chunks\renderer-PluginsHome.js') -Value $PlugHome -Encoding UTF8
  $PlugPage = @'
import{o as a}from"./renderer-chunk.js";import{t as d}from"./renderer-react.production.js";import{t as f}from"./renderer-react-jsx-runtime.production.js";import{t as loc}from"./renderer-router.js";
var t=a(d()),r=f();
const S={page:{padding:"24px",maxWidth:"860px",color:"#e8e8e8"},err:{color:"#ff7a7a",fontSize:"13px"}};
export default function PluginPage(){
  var st=t.useState({id:null,ready:false}),s=st[0],setS=st[1];
  t.useEffect(function(){var dead=false;
    (async function(){
      try{var l=await loc();var m=(l&&l.pathname||"").match(/^\/plugins\/([^\/]+)/);if(!dead)setS({id:m?decodeURIComponent(m[1]):null,ready:true})}catch(e){if(!dead)setS({id:null,ready:true})}
    })();
    return function(){dead=true}
  },[]);
  if(!s.ready)return(0,r.jsx)("div",{style:S.page,children:"Loading…"});
  var pg=null,api={},ps=(window.__medalPlugins&&window.__medalPlugins.plugins)||[];
  for(var i=0;i<ps.length;i++){var en=ps[i];if(!en.api)continue;
    for(var j=0;j<(en.pages||[]).length;j++){if(en.pages[j].pageId===s.id){pg=en.pages[j];api=en.api;break}}
    if(pg)break;
  }
  if(!pg)for(var k=0;k<ps.length;k++){if(ps[k].name===s.id&&(ps[k].pages||[]).length){pg=ps[k].pages[0];api=ps[k].api||{};break}}
  if(!pg)return(0,r.jsxs)("div",{style:S.page,children:[(0,r.jsx)("h2",{style:{fontSize:"20px"},children:"Plugin not found"}),(0,r.jsx)("div",{style:S.err,children:"No enabled plugin '"+(s.id||"")+"' exposes a page. Enable it in Plugins and restart Medal."})]});
  try{return(0,r.jsx)("div",{style:S.page,children:pg.render(api)})}catch(e){return(0,r.jsx)("div",{style:S.page,children:(0,r.jsx)("div",{style:S.err,children:"Plugin page crashed: "+String((e&&e.message)||e)})})}
}
'@
  Set-Content -LiteralPath (Join-Path $Work 'app\chunks\renderer-PluginPage.js') -Value $PlugPage -Encoding UTF8
  Ok 'PluginPage staged'

# --- 7. Patch via embedded node script ---
Step 'Patching (Home/Discover/Quests/Premium -> Library, ads disabled)'
$PatchJs = Join-Path $Work 'patch.cjs'
$PatchCode = @'
// Medal debloat patcher (embedded). Exits non-zero on any assert fail.
const fs = require('fs');
const path = require('path');
const dir = process.argv[2];
const plugDir = process.argv[3] || '';
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
// --- PLUGINS: nav button under Albums ---
s = replaceOnce(s, 'route:"/albums"}]:[]', 'route:"/albums"}]:[],{icon:(0,a.jsx)(W,{shape:"shapes-filled",size:24}),label:i({id:"plugins",defaultMessage:[{type:0,value:"Plugins"}]}),route:"/plugins"}', 'nav-plugins');
// --- PLUGINS: /plugins routes (manager + per-plugin pages) ---
s = replaceOnce(s, '{element:(0,a.jsx)(Dn,{activeTab:"library",hideOverflow:!1}),children:[{path:"/",lazy:t},{path:"/home/:tab?",lazy:t},{path:Zt.FEED_ITEM,lazy:t}]}', '{element:(0,a.jsx)(Dn,{activeTab:"library",hideOverflow:!1}),children:[{path:"/",lazy:t},{path:"/home/:tab?",lazy:t},{path:Zt.FEED_ITEM,lazy:t}]},{element:(0,a.jsx)(Dn,{activeTab:"plugins"}),children:[{path:"/plugins",lazy:Fe(()=>import("./chunks/renderer-PluginsHome.js"))},{path:"/plugins/:pluginId",lazy:Fe(()=>import("./chunks/renderer-PluginPage.js"))}]}', 'router-plugins');
// --- PLUGINS: boot the loader at app startup (title-bar init component) ---
s = replaceOnce(s, 'MedalIPC.updateSetting(dt.SDKMode,!1)},[]),null}', 'MedalIPC.updateSetting(dt.SDKMode,!1)},[]),(0,p.useEffect)(()=>{import("./chunks/renderer-PluginLoader.js").then(function(m){m.init&&m.init()}).catch(function(){})},[]),null}', 'plugin-loader-mount');
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
for (const good of ['route:"/plugins"', 'renderer-PluginsHome.js', 'renderer-PluginPage.js', 'renderer-PluginLoader.js").then']) {
  if (!s2.includes(good)) throw new Error('PLUGIN LEFTOVER: missing ' + good);
}
// --- PLUGINS: allow %LOCALAPPDATA%\Medal\plugins through the main-process fs path gate ---
// (collectRoots already whitelists <localUserData>/cafe; we add <localUserData>/plugins the same way,
// so MedalIPC.fs.readFile works for the manifest + plugin code. Without this the gate throws
// "MedalIPC: path not allowed for fs:readFile".)
const mainPath = path.join(dir, 'main.min.js');
let mm = fs.readFileSync(mainPath, 'utf8');
mm = replaceOnce(mm, 'e.push(At.default.join(oe.EnvironmentUtils.getLocalUserData(),"cafe"))}catch{}', 'e.push(At.default.join(oe.EnvironmentUtils.getLocalUserData(),"cafe"))}catch{}try{e.push(At.default.join(oe.EnvironmentUtils.getLocalUserData(),"plugins"))}catch{}', 'main-plugins-root');
fs.writeFileSync(mainPath, mm);
const mm2 = fs.readFileSync(mainPath, 'utf8');
if (!mm2.includes('getLocalUserData(),"plugins"')) throw new Error('MAIN LEFTOVER: plugins root not registered');
console.log('main fs gate opened for plugins dir');
// --- OAUTH: one-shot loopback listener so plugins get one-click login (no code paste) ---
mm = replaceOnce(mm2, 'Ie.ipcMain.handle("fs:readFile",(t,n)=>(Vo("fs:readFile",n),Ht.default.readFile(n)))', 'Ie.ipcMain.handle("fs:readFile",(t,n)=>(Vo("fs:readFile",n),Ht.default.readFile(n)));(()=>{let srv=null,port=0,pend=null,waiters=[];const fin=v=>{const w=waiters;waiters=[];w.forEach(f=>{try{f(v)}catch(e){}})};Ie.ipcMain.handle("medal-plugins:oauth-listen",()=>new Promise(res=>{if(srv&&port)return res({port:port});const http=require("node:http");srv=http.createServer((req,rs)=>{try{const u=new URL(req.url||"/","http://127.0.0.1");const code=u.searchParams.get("code"),err=u.searchParams.get("error");rs.writeHead(200,{"Content-Type":"text/html"});rs.end(code?"<html><body><h3>Logged in! Return to Medal.</h3></body></html>":"<html><body><h3>Login did not complete. Return to Medal.</h3></body></html>");if(code||err){pend={code:code||null,error:err||null};fin(pend);pend=null}}catch(e){}});srv.listen(0,"127.0.0.1",()=>{port=srv.address().port;res({port:port})});setTimeout(()=>{try{srv&&srv.close()}catch(e){}srv=null;port=0;fin({code:null,error:"timeout"})},180000)}));Ie.ipcMain.handle("medal-plugins:oauth-await",()=>new Promise(res=>{if(pend){const p=pend;pend=null;res(p)}else waiters.push(res)}))})()', 'main-oauth');
fs.writeFileSync(mainPath, mm);
// --- OAUTH: bridge the new channels into the renderer preload ---
const prePath = path.join(dir, 'preload.min.js');
let pp = fs.readFileSync(prePath, 'utf8');
pp = replaceOnce(pp, 'getPathForFile:e=>r.webUtils.getPathForFile(e)},openExternal:', 'getPathForFile:e=>r.webUtils.getPathForFile(e)},plugins:{oauthListen:()=>r.ipcRenderer.invoke("medal-plugins:oauth-listen"),oauthAwait:()=>r.ipcRenderer.invoke("medal-plugins:oauth-await")},openExternal:', 'preload-plugins-bridge');
fs.writeFileSync(prePath, pp);
const pp2 = fs.readFileSync(prePath, 'utf8');
if (!pp2.includes('medal-plugins:oauth-listen') || !pp2.includes('medal-plugins:oauth-await')) throw new Error('PRELOAD LEFTOVER: oauth bridge missing');
const mm3 = fs.readFileSync(mainPath, 'utf8');
if (!mm3.includes('"medal-plugins:oauth-listen"') || !mm3.includes('"medal-plugins:oauth-await"')) throw new Error('MAIN LEFTOVER: oauth channels missing');
console.log('oauth loopback login wired (main + preload)');
// --- PLUGINS: inject absolute plugins dir into staged chunks ---
if (!plugDir) throw new Error('plugins dir missing (argv[3])');
for (const f of ['renderer-PluginLoader.js', 'renderer-PluginsHome.js']) {
  const pp = path.join(dir, 'chunks', f);
  if (!fs.existsSync(pp)) throw new Error('missing plugin chunk ' + f);
  let cc = fs.readFileSync(pp, 'utf8');
  cc = replaceOnce(cc, '__PLUGINS_DIR__', JSON.stringify(plugDir), 'plugdir-' + f);
  fs.writeFileSync(pp, cc);
  console.log('dir injected into ' + f);
}
const a2 = fs.readFileSync(adsPath, 'utf8');
if (a2.includes('??!0')) throw new Error('AD LEFTOVER: useAdsEnabled still defaults true');
const l2 = fs.readFileSync(libAdPath, 'utf8');
if (l2.includes('shouldShowAds:o')) throw new Error('AD LEFTOVER: LibraryAd grid injection intact');
console.log('VERIFY OK');
'@
Set-Content -LiteralPath $PatchJs -Value $PatchCode -Encoding UTF8
node $PatchJs "$Work\app" "$PluginsDir"
if ($LASTEXITCODE -ne 0) { throw 'Patch script failed (version mismatch?). Restore backup and report Medal version.' }
Ok 'Patch asserts passed'
node --check "$Work\app\renderer.min.js"
node --check "$Work\app\main.min.js"
node --check "$Work\app\preload.min.js"
Ok 'JS syntax valid (renderer + main + preload)'

# --- 8. Repack (must preserve 585 unpacked files: exes/nodes/src/assets/vendor) ---
Step 'Repacking app.asar'
& npx --yes -p @electron/asar asar pack "$Work\app" "$Work\app.asar" --unpack "{*.node,*.exe,lib/sqlite3.exe}" --unpack-dir "{src/assets,vendor/better-sqlite3}" 2>&1 | Out-Null
if (-not (Test-Path -LiteralPath "$Work\app.asar")) { throw 'Repack failed' }
$listed = & npx --yes -p @electron/asar asar list "$Work\app.asar" 2>&1 | Select-String 'renderer-HomeRoute'
if (-not $listed) { throw 'Repack verify failed: renderer-HomeRoute missing from new asar' }
Ok "New asar: $([math]::Round((Get-Item -LiteralPath "$Work\app.asar").Length/1MB,1)) MB"
  Copy-Item -LiteralPath "$Work\app.asar" -Destination $AsarPath -Force
  Ok 'Installed patched app.asar (unpacked layout preserved, .unpacked dir untouched)'
  Write-ModInfo 'modded'

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
  Write-Host ' Start Medal normally and check left bar.' -ForegroundColor Green
  Write-Host '==============================================`n' -ForegroundColor Green
}

function Show-Menu {
  while ($true) {
    Write-Host ''
    Write-Host ' ==========================================' -ForegroundColor Cyan
    Write-Host "  Medal.Tv Debloater v$ModVersion" -ForegroundColor Cyan
    Write-Host ' ==========================================' -ForegroundColor Cyan
    $st = Get-ModStatus
    Show-Status $st
    Write-Host ''
    Write-Host '  [1] Patch (debloat + no ads, redirect to Library)'
    Write-Host '  [2] Restore stock'
    if ($st.Updates -eq 'blocked') { Write-Host '  [3] Unblock updates' }
    else { Write-Host '  [3] Block updates' }
    Write-Host '  [4] Status / verify'
    Write-Host '  [5] Rescan plugins'
    Write-Host '  [Q] Quit'
    Write-Host ''
    $c = Read-Host 'Choice'
    switch ($c.ToUpper()) {
      '1' { try { Invoke-PatchFlow $false } catch { Warn "Patch failed: $_" } }
      '2' { try { Invoke-RestoreFlow $false } catch { Warn "Restore failed: $_" } }
      '3' { try { Invoke-UpdateToggle } catch { Warn "Toggle failed: $_" } }
      '4' { Show-Status (Get-ModStatus) }
      '5' { try { Invoke-RescanPlugins } catch { Warn "Rescan failed: $_" } }
      'Q' { return }
      default { Warn 'Invalid choice - enter 1-5 or Q.' }
    }
  }
}

# --- Entry: flags bypass the menu, no flags (or -Menu) shows it ---
if ($KeepUpdates) { Warn '-KeepUpdates is legacy and ignored: updates are now managed via menu item 3.' }
if ($Restore) { Invoke-RestoreFlow $true }
elseif ($Patch) { Invoke-PatchFlow $true }
else { Show-Menu }
