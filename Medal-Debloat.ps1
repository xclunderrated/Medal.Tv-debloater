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
$ModVersion = '15'
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
// Sample plugin: youtube-backup — embedded YouTube Studio uploader.
// Folder: %LOCALAPPDATA%\Medal\plugins\youtube-backup\plugin.js
// No Google Cloud project needed. Open this plugin's page, log into YouTube
// once inside the embedded window, and new clips upload automatically.
(function () {
  var S = { autoUpload: true, privacy: "unlisted", titleTemplate: "{game} clip {date}", games: "" };
  var PART = "persist:youtube-upload";
  var STUDIO = "https://studio.youtube.com";
  var view = null;          // webview element, set by the page
  var queue = [];           // pending upload jobs
  var busy = false;

  api.registerSettings([
    { key: "autoUpload", label: "Auto-upload new clips", type: "checkbox", default: true },
    { key: "privacy", label: "Privacy", type: "select", default: "unlisted", options: [{ value: "private", label: "Private" }, { value: "unlisted", label: "Unlisted" }, { value: "public", label: "Public" }] },
    { key: "titleTemplate", label: "Title template ({game}, {date})", default: "{game} clip {date}" },
    { key: "games", label: "Only these games (comma slugs, blank = all)", placeholder: "gta-v, valorant" }
  ]);

  // ---------- guest helpers (run inside the YouTube webview) ----------
  var GUEST = "(" + function () {
    window.__ytu = window.__ytu || {
      q: function (sels) {
        for (var i = 0; i < sels.length; i++) { try { var el = document.querySelector(sels[i]); if (el && el.offsetParent !== null) return el; } catch (e) { } }
        return null;
      },
      byText: function (tags, txt) {
        var els = [];
        for (var i = 0; i < tags.length; i++) { try { els = els.concat(Array.prototype.slice.call(document.querySelectorAll(tags[i]))); } catch (e) { } }
        txt = txt.toLowerCase();
        for (var j = 0; j < els.length; j++) { try { if ((els[j].innerText || "").toLowerCase().indexOf(txt) >= 0 && els[j].offsetParent !== null) return els[j]; } catch (e) { } }
        return null;
      },
      setText: function (el, text) {
        try {
          el.focus();
          document.execCommand("selectAll", false, null);
          document.execCommand("insertText", false, text);
          el.dispatchEvent(new Event("input", { bubbles: true }));
          return (el.innerText || "").indexOf(text.slice(0, 20)) >= 0;
        } catch (e) { return false; }
      },
      setFile: function (b64, name) {
        try {
          var bin = atob(b64), arr = new Uint8Array(bin.length);
          for (var i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
          var f = new File([arr], name, { type: "video/mp4" });
          var dt = new DataTransfer(); dt.items.add(f);
          var inp = document.querySelector('ytcp-uploads-dialog input[type="file"], #content input[type="file"], input[type="file"][accept*="video"]');
          if (!inp) return "no-input";
          inp.files = dt.files;
          inp.dispatchEvent(new Event("change", { bubbles: true }));
          inp.dispatchEvent(new Event("input", { bubbles: true }));
          return "ok";
        } catch (e) { return "err:" + String((e && e.message) || e); }
      }
    };
  } + ")();";

  function ex(js, ms) {
    if (!view || !view.executeJavaScript) return Promise.reject(new Error("upload window not open — open this plugin's page first"));
    var p;
    try { p = view.executeJavaScript(js, false); } catch (e) { return Promise.reject(e); }
    return Promise.race([Promise.resolve(p), new Promise(function (_, rej) { setTimeout(function () { rej(new Error("youtube step timed out")); }, ms || 20000); })]);
  }
  function exInit() { return ex(GUEST, 10000); }
  function loggedIn() {
    return ex("(function(){try{return !!(document.querySelector('button#avatar-btn,#avatar-btn')&&document.querySelector('#avatar-btn').offsetParent)}catch(e){return false}})()", 8000).then(function (v) { return !!v; }, function () { return false; });
  }
  function blocked() {
    return ex("(function(){try{var t=(document.body&&document.body.innerText||'').toLowerCase();return t.indexOf('could not sign you in')>=0||t.indexOf('may not be secure')>=0||t.indexOf('this browser or app may not be secure')>=0}catch(e){return false}})()", 8000).then(function (v) { return !!v; }, function () { return false; });
  }
  function waitGuest(expr, timeout) {
    var code = "(function(){var t0=Date.now(),to=" + (timeout || 30000) + ";return new Promise(function(res){(function poll(){var v;try{v=(" + expr + ")}catch(e){v=null}if(v)return res(JSON.stringify({ok:true}));if(Date.now()-t0>to)return res(JSON.stringify({ok:false}));setTimeout(poll,700)})()})})()";
    return ex(code, (timeout || 30000) + 5000).then(function (r) { try { return JSON.parse(r).ok; } catch (e) { return false; } });
  }
  function clickFirst(sels) {
    return ex("(function(){return window.__ytu.q(" + JSON.stringify(sels) + ")?(window.__ytu.q(" + JSON.stringify(sels) + ").click(),'clicked'):'missing'})", 10000);
  }
  function clickText(tags, txt) {
    return ex("(function(){var el=window.__ytu.byText(" + JSON.stringify(tags) + "," + JSON.stringify(txt) + ");if(el){el.click();return 'clicked'}return 'missing'})", 10000);
  }

  var LOGLINES = [];
  function logL(m) {
    try {
      LOGLINES.push(new Date().toISOString().slice(11, 19) + " " + m);
      if (LOGLINES.length > 40) LOGLINES = LOGLINES.slice(-40);
    } catch (e) { }
  }
  function withTimeout(p, ms, label) {
    return Promise.race([Promise.resolve(p), new Promise(function (_, rej) { setTimeout(function () { rej(new Error((label || "step") + " timed out after " + (ms || 25000) + "ms")); }, ms || 25000); })]);
  }

  var CREATE = ["button[aria-label='Create']", "#create-icon", "ytcp-button#create"];
  var NEXT = ["#next-button", "ytcp-button#next-button"];
  var KIDS_NO = ['tp-yt-paper-radio-button[name="NOT_MADE_FOR_KIDS"]', 'paper-radio-button[name="NOT_MADE_FOR_KIDS"]'];
  var TITLE = "ytcp-video-metadata-editor #textbox";

  api.registerPage({
    id: "youtube-backup",
    title: "YouTube Backup",
    render: function (a) {
      var R = a.React;
      var st = R.useState({ msg: "Checking login…", clips: [] });
      var s = st[0], setS = st[1];
      var sl = R.useState(-1);
      var wv = R.useState("loading…");
      var wvS = wv[0], setWv = wv[1];
      var bp = R.useState(0);
      var vref = R.useRef(null);
      if (!vref.current) vref.current = function (el) {
        view = el;
        if (!el) return;
        try {
          el.addEventListener("did-fail-load", function (e) { setWv("failed " + (e.errorCode || "") + " " + (e.errorDescription || "")); });
          el.addEventListener("did-start-loading", function () { setWv("loading…"); });
          el.addEventListener("did-stop-loading", function () { setWv("ready"); });
          el.addEventListener("dom-ready", function () { setWv("ready"); });
        } catch (e) { }
        check(); pump();
      };
      function say(m) { logL(m); try { bp[1](function (x) { return (x || 0) + 1; }); } catch (e) { } }
      function reloadView() { try { if (view && view.reload) { view.reload(); setWv("loading…"); } } catch (e) { } }
      function check() {
        withTimeout(loggedIn(), 15000, "login check").then(function (ok) {
          if (ok) { refreshClips("Logged in. New clips auto-upload" + (S.autoUpload ? "." : " (auto-upload off).")); return; }
          blocked().then(function (b) {
            refreshClips(b ? "Google blocked sign-in inside embedded windows on this account. Fallback: use the API login from the plugin README instead." : "Log into YouTube in the window below (once — it stays logged in).");
          });
        }, function (e) { refreshClips("Login check failed: " + String((e && e.message) || e)); });
      }
      function refreshClips(msg) {
        withTimeout(load().then(function () { return a.MedalIPC.getContents({ limit: 10 }); }), 20000, "clip list").then(function (q) {
          setS({ msg: msg, clips: (q && q.contents) || [] });
        }, function (e) { setS({ msg: msg + " (clip list failed: " + String((e && e.message) || e) + ")", clips: [] }); });
      }
      function uploadOne(c) {
        say("upload pressed");
        setS({ msg: "Queued — uploading…", clips: s.clips });
        enqueue(c, function (m) { say("step: " + m); setS({ msg: m, clips: s.clips }); }, function (e) { say("FAILED: " + String((e && e.message) || e)); setS({ msg: "Upload failed: " + String((e && e.message) || e), clips: s.clips }); });
      }
      function selfTest() {
        say("self-test start");
        say("test: window element? " + (!!view));
        if (!view || !view.executeJavaScript) { say("FAIL: no upload window element"); return; }
        withTimeout(exInit(), 12000, "guest init").then(function () {
          return withTimeout(ex("(function(){return 'guest-ok:'+!!window.__ytu})()", 8000), 12000, "guest ping");
        }).then(function (e) {
          say("test: " + e);
          return withTimeout(loggedIn(), 12000, "login check");
        }).then(function (li) {
          say("test: logged in? " + li);
          return withTimeout(ex("(function(){return !!window.__ytu.q(" + JSON.stringify(CREATE) + ")})()", 10000), 14000, "create button");
        }).then(function (cb) {
          say("test: Create button visible? " + cb);
          say(cb ? "self-test done — uploader looks ready" : "self-test: open studio.youtube.com in the window and log in, then re-run");
        }, function (e) { say("FAIL: " + String((e && e.message) || e)); });
      }
      function label(c, i) {
        var g = gameOf(c);
        var id = ""; try { id = c.getContentId ? c.getContentId() : ""; } catch (e) { }
        return ((g ? g + " — " : "") + "clip " + (id ? String(id).slice(-6) : "#" + (i + 1)));
      }
      R.useEffect(function () { refreshClips("Checking login…"); check(); }, []);
      return a.el("div", { style: { display: "flex", flexDirection: "column", gap: "10px", maxWidth: "720px" } },
        a.el("h2", { style: { fontSize: "20px", margin: 0 } }, "YouTube Backup"),
        a.el("div", { style: { fontSize: "13px", color: "#c9c9c9" } }, s.msg),
        a.el("webview", { ref: vref.current, src: STUDIO, partition: PART, allowpopups: "true", style: { width: "100%", height: "560px", border: "1px solid #2c2c2c", borderRadius: "10px", background: "#000" } }),
        a.el("div", { style: { display: "flex", alignItems: "center", gap: "10px", fontSize: "12px", color: "#9a9a9a" } },
          a.el("span", null, "Window: " + wvS),
          a.el("button", { onClick: reloadView, style: { cursor: "pointer", border: "1px solid #3a3a3a", background: "#222", color: "#eee", borderRadius: "6px", padding: "4px 10px", fontSize: "12px" } }, "Reload window"),
          a.el("button", { onClick: selfTest, style: { cursor: "pointer", border: "1px solid #3a3a3a", background: "#222", color: "#eee", borderRadius: "6px", padding: "4px 10px", fontSize: "12px" } }, "Run self-test")),
        a.el("div", { style: { fontSize: "11px", color: "#8a8a8a", fontFamily: "monospace", whiteSpace: "pre-wrap", maxHeight: "130px", overflowY: "auto", border: "1px solid #222", borderRadius: "6px", padding: "6px 8px", background: "#0d0d0d" } }, LOGLINES.slice(-8).join("\n") || "activity log empty — press Upload or Run self-test"),
        a.el("h3", { style: { fontSize: "15px", margin: "8px 0 0" } }, "Recent clips"),
        s.clips.length === 0 ? a.el("div", { style: { fontSize: "13px", color: "#9a9a9a" } }, "No clips found.") :
          a.el("div", null,
            a.el(a.ClipGrid, { clips: s.clips, selected: sl[0], onPick: function (c, i) { sl[1](i); }, label: label }),
            (sl[0] >= 0 && s.clips[sl[0]]) ? a.el("button", { onClick: function () { uploadOne(s.clips[sl[0]]); }, style: { cursor: "pointer", border: "1px solid #b6f34a", background: "#1c2607", color: "#d7ff6b", borderRadius: "8px", padding: "8px 14px", fontSize: "14px", marginTop: "10px", width: "fit-content" } }, "Upload selected") : null));
    }
  });

  async function load() {
    var keys = ["autoUpload", "privacy", "titleTemplate", "games"];
    for (var i = 0; i < keys.length; i++) {
      var v = await api.store.get(keys[i], null);
      if (v !== null && v !== undefined && v !== "") S[keys[i]] = v;
    }
    if (S.autoUpload === "false" || S.autoUpload === false) S.autoUpload = false;
  }

  function toBytes(b) {
    if (typeof b === "string") return new TextEncoder().encode(b);
    if (b instanceof Uint8Array) return b;
    if (ArrayBuffer.isView(b)) return new Uint8Array(b.buffer, b.byteOffset, b.byteLength);
    return new Uint8Array(b);
  }
  function b64(bytes) {
    var s = "", CH = 32768;
    for (var i = 0; i < bytes.length; i += CH) s += String.fromCharCode.apply(null, bytes.subarray(i, i + CH));
    return btoa(s);
  }

  async function dropFile(fp) {
    var bytes = toBytes(await api.MedalIPC.fs.readFile(fp));
    var name = String(fp).split(/[/\\]/).pop() || "clip.mp4";
    var CH = 2 * 1024 * 1024, off = 0;
    await ex("window.__ytu_acc='';'ready'", 8000);
    while (off < bytes.length) {
      var piece = b64(bytes.subarray(off, Math.min(off + CH, bytes.length)));
      await ex("window.__ytu_acc+=(" + JSON.stringify(piece) + ");'part:'+window.__ytu_acc.length", 15000);
      off += CH;
    }
    var fin = await ex("(function(){var r=window.__ytu.setFile(window.__ytu_acc,'" + name.replace(/'/g, "") + "');window.__ytu_acc='';return r})()", 20000);
    if (fin !== "ok") throw new Error("YouTube did not accept the file (" + fin + ")");
  }

  function titleFor(game) {
    var d = new Date();
    return (S.titleTemplate || "{game} clip {date}").replace("{game}", game || "Medal").replace("{date}", d.toISOString().slice(0, 10));
  }

  function gameOf(c) { try { return (c.getGame && c.getGame() && (c.getGame().slug || c.getGame().name)) || ""; } catch (e) { return ""; } }
  function pathOf(c) {
    try {
      if (c.video_path) return c.video_path;          // library rows carry the absolute path
      if (c.videoPath) return c.videoPath;
      var f = null;
      try { f = c.files ? c.files() : null; } catch (e) { }
      if (f && f.current && f.current.video) return f.current.video;
      if (c.getVideoPath) { var gp = c.getVideoPath(); if (gp) return gp; }
    } catch (e) { }
    return null;
  }
  function diag(c) {
    try {
      var ks = [];
      for (var k in c) { try { if (typeof c[k] !== "function") ks.push(k + "=" + String(c[k]).slice(0, 40)); } catch (e) { } if (ks.length > 8) break; }
      return ks.join(" | ") || "(no readable fields)";
    } catch (e) { return "(unreadable object)"; }
  }
  function idOf(c, fp) { try { return c.getContentId ? c.getContentId() : fp; } catch (e) { return fp; } }
  function allowed(game) {
    if (!S.games) return true;
    return S.games.split(",").map(function (g) { return g.trim().toLowerCase(); }).filter(Boolean).indexOf(String(game).toLowerCase()) >= 0;
  }

  // Local clips are DASH folders, not files: export to a single mp4 first.
  // Returns {path, temp} - temp files live next to the source (allowed fs root).
  async function resolveUpload(c, onStep) {
    var step = onStep || function () { };
    var p = pathOf(c);
    if (!p) throw new Error("Could not resolve clip file (local file missing — cloud-only clip? " + diag(c) + ")");
    if (/\.mp4$/i.test(p)) return { path: p, temp: false };
    step("muxing clip to mp4…");
    logL("muxing " + p);
    var r = await withTimeout(api.MedalIPC.plugins.exportMp4(p), 600000, "clip export");
    if (!r || !r.path) throw new Error("export failed");
    logL("muxed -> " + r.path);
    return { path: r.path, temp: !!r.temp };
  }

  async function uploadClipObj(c, onStep) {
    await withTimeout(load(), 15000, "settings load");
    var step = function (m) { logL("step: " + m); (onStep || function () { })(m); };
    if (!allowed(gameOf(c))) throw new Error("Game filtered out by settings.");
    var src = await resolveUpload(c, step);
    var key = "done:" + idOf(c, src.path);
    step("opening uploader…");
    await withTimeout(exInit(), 15000, "guest init");
    logL("guest ready, checking login");
    if (!(await withTimeout(loggedIn(), 15000, "login check"))) throw new Error("Not logged into YouTube in the embedded window.");
    await ex("(function(){if(window.location.href.indexOf('studio.youtube.com')!==0)window.location.href='" + STUDIO + "';return 'nav'})()", 8000);
    step("starting upload…");
    var created = await waitGuest("window.__ytu.q(" + JSON.stringify(CREATE) + ")", 30000);
    if (!created) throw new Error("Studio Create button not found.");
    await clickFirst(CREATE);
    var up = await waitGuest("window.__ytu.byText(['paper-item','ytcp-text-menu-item','tp-yt-paper-item'],'upload videos')", 15000);
    if (!up) throw new Error("Upload menu item not found.");
    await clickText(['paper-item', 'ytcp-text-menu-item', 'tp-yt-paper-item'], "upload videos");
    var dlg = await waitGuest("document.querySelector('ytcp-uploads-dialog')&&document.querySelector('ytcp-uploads-dialog input[type=file]')", 20000);
    if (!dlg) throw new Error("Upload dialog did not open.");
    step("dropping video…");
    logL("reading clip file");
    await withTimeout(dropFile(src.path), 120000, "file drop");
    var det = await waitGuest("document.querySelector('ytcp-video-metadata-editor')", 30000);
    if (!det) throw new Error("Details screen did not appear.");
    step("filling details…");
    var t = titleFor(gameOf(c));
    await ex("(function(){var els=document.querySelectorAll(" + JSON.stringify(TITLE) + ");for(var i=0;i<els.length;i++){if(els[i].offsetParent&&window.__ytu.setText(els[i]," + JSON.stringify(t) + "))return 'ok'}return 'missing'})()", 15000);
    await clickFirst(KIDS_NO);
    for (var n = 0; n < 3; n++) {
      var nb = await ex("(function(){var e=window.__ytu.q(" + JSON.stringify(NEXT) + ");if(e){e.click();return 'ok'}var d=window.__ytu.byText(['button'],'done');if(d){d.click();return 'done'}var p=window.__ytu.byText(['button'],'publish');if(p){p.click();return 'done'}return null})()", 10000);
      if (nb === "done") break;
      await new Promise(function (x) { setTimeout(x, 2500); });
    }
    var vis = (S.privacy || "unlisted").toUpperCase();
    await ex("(function(){var sels=['tp-yt-paper-radio-button[name=\"" + vis + "\"]','paper-radio-button[name=\"" + vis + "\"]'];var e=window.__ytu.q(sels);if(e){e.click();return 'ok'}return 'missing'})()", 15000);
    step("publishing…");
    await ex("(function(){var d=window.__ytu.byText(['button'],'done')||window.__ytu.byText(['button'],'publish')||window.__ytu.q(['#done-button','#publish-button']);if(d){d.click();return 'ok'}return 'missing'})()", 10000);
    await waitGuest("!document.querySelector('ytcp-uploads-dialog')||!!window.__ytu.byText(['span','div'],'upload complete')", 10000);
    await withTimeout(api.store.set(key, true), 10000, "mark done");
    if (src.temp) { try { await api.MedalIPC.fs.remove([src.path]); logL("temp cleaned"); } catch (e) { logL("temp cleanup skipped"); } }
    logL("done");
    api.toast("YouTube backup uploaded");
    return true;
  }

  function pump() {
    if (busy || !queue.length) return;
    busy = true;
    var job = queue.shift();
    job.run().then(function () { }, function (e) { try { console.error("[youtube-backup]", e); } catch (_) { } job.onFail && job.onFail(e); }).then(function () { busy = false; setTimeout(pump, 2000); });
  }
  function enqueue(c, onStep, onFail) {
    queue.push({ run: function () { return uploadClipObj(c, onStep); }, onFail: onFail });
    pump();
  }

  api.onClip(async function () {
    try {
      await load();
      if (!S.autoUpload) return;
      var q = await api.MedalIPC.getContents({ limit: 5 });
      var clips = (q && q.contents) || [];
      for (var i = 0; i < clips.length; i++) {
        var c = clips[i];
        if (!allowed(gameOf(c))) continue;
        var fp = pathOf(c);
        if (!fp) continue;
        var done = await api.store.get("done:" + idOf(c, fp), null);
        if (done) continue;
        if (!view) { api.toast("YouTube backup: open the plugin page once so the uploader is ready"); return; }
        enqueue(c);
        break; // one per event; next event handles the rest
      }
    } catch (e) { try { console.error("[youtube-backup]", e); } catch (_) { } }
  });

  // Library ⋯ menu entry (rendered by the mod's menu patch via api.registerClipAction).
  api.registerClipAction({ id: "youtube-upload", label: "Upload to YouTube", run: function (clip) {
    if (!clip) { api.toast("No clip"); return; }
    if (!view) { api.toast("YouTube backup: open the plugin page once so the uploader is ready"); return; }
    api.toast("Queued for YouTube upload");
    enqueue(clip, function () { }, function (e) { api.toast("YouTube upload failed: " + String((e && e.message) || e)); });
  } });
})();
'@

$SampleDiscord = @'
// discord-send — trim a clip, render it to a Discord-size target, drag it into Discord.
// Folder: %LOCALAPPDATA%\Medal\plugins\discord-send\plugin.js
// Needs mod with the discord bridges (Render in Medal-Debloat, restart Medal).
(function () {
  var S = { defaultTarget: "25", resolution: "720p" };
  var TARGETS = [10, 25, 50, 100];

  api.registerSettings([
    { key: "defaultTarget", label: "Default size target (MB)", type: "select", default: "25", options: [{ value: "10", label: "10 MB (Discord free)" }, { value: "25", label: "25 MB" }, { value: "50", label: "50 MB" }, { value: "100", label: "100 MB (Nitro)" }] },
    { key: "resolution", label: "Render resolution", type: "select", default: "720p", options: [{ value: "720p", label: "720p (recommended)" }, { value: "1080p", label: "1080p (bigger, softer at small MB)" }, { value: "source", label: "Source (no rescale)" }] }
  ]);

  api.registerPage({ id: "discord-send", title: "Send to Discord", render: Page });
  api.registerClipAction({
    id: "discord-send", label: "Send to Discord",
    run: function (clip) {
      var info = null;
      try {
        info = {
          at: Date.now(),
          contentId: idOf(clip, null),
          videoPath: api.clipPath(clip),
          title: titleOf(clip, ""),
          game: gameOf(clip, "")
        };
      } catch (e) { info = null; }
      api.store.set("pending", info).then(function () { api.navigate("/plugins/discord-send"); });
    }
  });

  function Page(a) {
    var R = a.React;
    var st = R.useState({ clips: [], idx: -1, src: "", dur: 0, start: 0, end: 0, hasMeta: false, target: 25, busy: false, msg: "Loading clips…", outPath: "", outSize: 0 });
    var s = st[0];
    function set(patch) { st[1](function (prev) { var n = {}; for (var k in prev) n[k] = prev[k]; for (var k2 in patch) n[k2] = patch[k2]; return n; }); }

    function init() {
      load().then(function () {
        var t = parseInt(S.defaultTarget, 10) || 25;
        return a.MedalIPC.getContents({ limit: 30 }).then(function (q) {
          var clips = (q && q.contents) || [];
          set({ clips: clips, target: t, msg: clips.length ? "Pick a clip below, then trim it." : "No clips found. Record something first." });
          consumePending(clips);
        }, function (e) { set({ msg: "Could not list clips: " + String((e && e.message) || e) }); });
      });
    }
    R.useEffect(function () { init(); }, []);

    function consumePending(clips) {
      api.store.get("pending", null).then(function (p) {
        if (!p || typeof p !== "object") return;
        api.store.set("pending", null);
        if (p.at && (Date.now() - p.at > 10 * 60 * 1000)) return;
        if (p.videoPath || p.contentId) {
          var idx = -1;
          for (var i = 0; i < clips.length; i++) {
            if (p.contentId && idOf(clips[i], null) && idOf(clips[i], null) === p.contentId) { idx = i; break; }
            if (p.videoPath && api.clipPath(clips[i]) === p.videoPath) { idx = i; break; }
          }
          if (idx >= 0) pick(idx, clips);
          else if (p.videoPath) set({ src: p.videoPath, msg: "Selected from menu. Trim it, pick a size, hit Render." });
          if (p.title) api.toast("Selected: " + p.title);
        }
      }, function () { });
    }

    function pick(i, list) {
      var clips = list || s.clips;
      var c = clips[i];
      var fp = api.clipPath(c);
      if (!fp) { set({ msg: "Could not resolve that clip's file (cloud-only?)." }); return; }
      set({ idx: i, src: fp, dur: 0, start: 0, end: 0, hasMeta: false, msg: "Loading preview…", outPath: "", outSize: 0 });
      if (!/\.mp4$/i.test(fp)) set({ msg: "Folder-based clip: no preview, but Render still works (it muxes first)." });
    }

    function previewUrl() {
      if (s.src && /\.mp4$/i.test(s.src)) return "file:///" + encodeURI(String(s.src).replace(/\\/g, "/")).replace(/^\/+/, "");
      return "";
    }

    function onMeta(e) {
      try {
        var d = e && e.target && e.target.duration ? e.target.duration : 0;
        if (!(d > 0)) return;
        var end = d <= 90 ? d : 30;
        set({ dur: d, start: 0, end: round1(end), hasMeta: true, msg: "Trim it, pick a size, hit Render." });
      } catch (err) { }
    }

    function onSrcError() { set({ msg: "Preview blocked — you can still Render." }); }

    function clampTrim(nstart, nend) {
      var d = s.dur || 0;
      var ns = Math.max(0, Number(nstart) || 0);
      var ne = Number(nend);
      if (!(ne > 0)) ne = d || 60;
      if (d > 0) { ns = Math.min(ns, d); ne = Math.min(ne, d); }
      if (ne < ns + 0.5) ne = ns + 0.5;
      if (d > 0 && ne > d) { ne = d; if (ns > ne - 0.5) ns = Math.max(0, ne - 0.5); }
      return { start: round1(ns), end: round1(ne) };
    }

    function quick(kind) {
      var d = s.dur || 0;
      if (kind === "full" && d > 0) set({ start: 0, end: round1(d) });
      else if (kind === "first15") set(clampTrim(0, 15));
      else if (kind === "last15") set(clampTrim(Math.max(0, (d || 60) - 15), d || 60));
      else if (kind === "first30") set(clampTrim(0, 30));
    }

    function render() {
      var P = a.MedalIPC.plugins || {};
      if (!P.discordRender) { set({ msg: "This needs the latest mod. Re-run Patch in Medal-Debloat, restart Medal, and come back." }); return; }
      if (!s.src) { set({ msg: "Pick a clip first." }); return; }
      var t = clampTrim(s.start, s.end);
      if (!(t.end > t.start)) { set({ msg: "Bad trim range." }); return; }
      set({ busy: true, msg: "Rendering " + (t.end - t.start).toFixed(1) + "s to " + s.target + "MB… (takes a bit)", outPath: "", outSize: 0 });
      load().then(function () {
        return P.discordRender({ src: s.src, start: t.start, end: t.end, targetMB: s.target, resolution: S.resolution || "720p" });
      }).then(function (r) {
        var op = (r && (r.outPath || r.path)) || "";
        var sz = (r && r.sizeBytes) || 0;
        if (!op) throw new Error("renderer returned no file");
        api.toast("Discord render done: " + fmtMB(sz));
        set({ busy: false, outPath: op, outSize: sz, msg: "Done — drag it into Discord below." });
      }, function (e) { set({ busy: false, msg: "Render failed: " + String((e && e.message) || e) }); });
    }

    function thumbOf() {
      if (!s.clips || s.idx < 0 || !s.clips[s.idx]) return null;
      var c = s.clips[s.idx];
      try { return c.thumbnail_path || c.thumbnailPath || c.image_path || null; } catch (e) { return null; }
    }

    function onDragStart(e) {
      var P = a.MedalIPC.plugins || {};
      try { if (e && e.dataTransfer) { e.dataTransfer.effectAllowed = "copy"; } } catch (_) { }
      if (!s.outPath) return;
      if (P.discordDragSync) {
        try { P.discordDragSync({ path: s.outPath, thumb: thumbOf() }); set({ msg: "Drop it in Discord now. If nothing drags, use Open folder." }); }
        catch (err) { set({ msg: "Drag bridge failed — use Open folder and drag the file manually." }); }
      } else {
        set({ msg: "Drag bridge needs the latest mod. Use Open folder for now." });
      }
    }

    function openFolder() {
      if (s.outPath) a.MedalIPC.fs.showInFolder(s.outPath);
    }

    function copyPath() {
      if (!s.outPath) return;
      try {
        if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(s.outPath).then(function () { api.toast("Path copied"); }, function () { set({ msg: "Copy failed. Path: " + s.outPath }); });
        else set({ msg: "Path: " + s.outPath });
      } catch (e) { set({ msg: "Path: " + s.outPath }); }
    }

    function label(c, i) {
      var g = gameOf(c);
      var t = titleOf(c, "");
      if (t) return (g ? g + " — " : "") + t;
      var id = idOf(c, "");
      return ((g ? g + " — " : "") + "clip " + (id ? String(id).slice(-6) : "#" + (i + 1)));
    }

    var trimLen = (s.end > s.start) ? (s.end - s.start) : 0;

    return a.el("div", { style: { display: "flex", flexDirection: "column", gap: "10px", maxWidth: "720px" } },
      a.el("h2", { style: { fontSize: "20px", margin: 0 } }, "Send to Discord"),
      a.el("div", { style: { fontSize: "13px", color: "#c9c9c9" } }, s.msg),

      a.el("h3", { style: { fontSize: "15px", margin: "8px 0 0" } }, "1 · Pick a clip"),
      s.clips.length === 0 ? a.el("div", { style: { fontSize: "13px", color: "#9a9a9a" } }, "No clips.") :
        a.el(a.ClipGrid, { clips: s.clips, selected: s.idx, onPick: function (c, i) { pick(i); }, label: label }),

      s.src ? a.el("h3", { style: { fontSize: "15px", margin: "8px 0 0" } }, "2 · Trim it") : null,
      s.src ? a.el("video", { key: s.src, src: previewUrl(), controls: true, onLoadedMetadata: onMeta, onError: onSrcError, style: { width: "100%", maxHeight: "320px", background: "#000", borderRadius: "10px", border: "1px solid #2c2c2c" } }) : null,
      s.src ? a.el("div", { style: { display: "flex", gap: "8px", alignItems: "center", fontSize: "13px", flexWrap: "wrap" } },
        a.el("label", null, "Start ",
          a.el("input", { type: "number", min: 0, step: 0.5, value: s.start, onChange: function (e) { var t = clampTrim(e.target.value, s.end); set(t); }, style: inp() })),
        a.el("label", null, "End ",
          a.el("input", { type: "number", min: 0, step: 0.5, value: s.end, onChange: function (e) { var t = clampTrim(s.start, e.target.value); set(t); }, style: inp() })),
        s.hasMeta ? a.el("span", { style: { color: "#9a9a9a" } }, "len " + trimLen.toFixed(1) + "s") : a.el("span", { style: { color: "#9a9a9a" } }, "no preview metadata — type the range, Render validates it"),
        a.el("button", { onClick: function () { quick("full"); }, style: btn() }, "Full"),
        a.el("button", { onClick: function () { quick("first15"); }, style: btn() }, "First 15s"),
        a.el("button", { onClick: function () { quick("last15"); }, style: btn() }, "Last 15s"),
        a.el("button", { onClick: function () { quick("first30"); }, style: btn() }, "First 30s")
      ) : null,
      s.src ? a.el("div", { style: { display: "flex", gap: "10px", alignItems: "center", fontSize: "12px", color: "#9a9a9a" } },
        a.el("span", { style: { minWidth: "70px" } }, "Trim range"),
        a.el("input", { type: "range", min: 0, max: s.dur || 600, step: 0.1, value: s.start, onChange: function (e) { var t = clampTrim(s.start, e.target.value); set(t); }, style: { flex: 1 } }),
        a.el("input", { type: "range", min: 0, max: s.dur || 600, step: 0.1, value: s.end, onChange: function (e) { var t = clampTrim(s.start, e.target.value); set(t); }, style: { flex: 1 } })
      ) : null,

      s.src ? a.el("h3", { style: { fontSize: "15px", margin: "8px 0 0" } }, "3 · Size target") : null,
      s.src ? a.el("div", { style: { display: "flex", gap: "8px", flexWrap: "wrap" } },
        TARGETS.map(function (t) {
          var sel = s.target === t;
          return a.el("button", { key: t, disabled: s.busy, onClick: function () { set({ target: t }); }, style: sel ? btnPri() : btn() }, t + "MB");
        })
      ) : null,

      s.src ? a.el("button", { disabled: s.busy, onClick: render, style: Object.assign(btnPri(), { opacity: s.busy ? 0.5 : 1, marginTop: "4px", width: "fit-content" }) }, s.busy ? "Rendering…" : "Render for Discord") : null,

      s.outPath ? a.el("div", { style: { border: "1px solid #b6f34a", background: "#141a08", borderRadius: "10px", padding: "12px 14px", display: "flex", flexDirection: "column", gap: "8px" } },
        a.el("div", { style: { fontSize: "14px", fontWeight: "600" } }, "Ready — " + fmtMB(s.outSize)),
        a.el("div", { draggable: true, onDragStart: onDragStart, style: { cursor: "grab", border: "1px dashed #b6f34a", borderRadius: "8px", padding: "12px", textAlign: "center", fontSize: "14px", color: "#d7ff6b" } }, "⬇ Drag this into Discord ⬇"),
        a.el("div", { style: { fontSize: "11px", color: "#9a9a9a", wordBreak: "break-all" } }, s.outPath),
        a.el("div", { style: { display: "flex", gap: "8px", flexWrap: "wrap" } },
          a.el("button", { onClick: openFolder, style: btn() }, "Open folder"),
          a.el("button", { onClick: copyPath, style: btn() }, "Copy path"),
          a.el("button", { disabled: s.busy, onClick: render, style: btn() }, "Re-render"))
      ) : null
    );
  }

  function btn() { return { cursor: "pointer", border: "1px solid #3a3a3a", background: "#222", color: "#eee", borderRadius: "6px", padding: "5px 10px", fontSize: "12px" }; }
  function btnPri() { return { cursor: "pointer", border: "1px solid #b6f34a", background: "#1c2607", color: "#d7ff6b", borderRadius: "6px", padding: "5px 10px", fontSize: "12px" }; }
  function inp() { return { width: "70px", background: "#0d0d0d", border: "1px solid #3a3a3a", color: "#eee", borderRadius: "6px", padding: "4px 6px", fontSize: "12px" }; }
  function round1(n) { return Math.round(Number(n) * 10) / 10; }
  function fmtMB(n) {
    n = Number(n) || 0;
    if (n <= 0) return "0MB";
    return (n / 1024 / 1024).toFixed(1) + "MB";
  }

  // getContents() returns PLAIN rows: read raw fields first, methods as fallback.
  function meta(c) {
    try {
      if (!c) return null;
      var m = c.metadata;
      if (typeof m === "string") { try { m = JSON.parse(m); } catch (e) { return null; } }
      return m || null;
    } catch (e) { return null; }
  }
  function gameOf(c) {
    try {
      if (!c) return "";
      if (c.getGame && typeof c.getGame === "function") { var g = c.getGame(); if (g) return g.slug || g.name || ""; }
      if (c.game) return c.game.slug || c.game.name || "";
      var m = meta(c);
      if (m && (m.gameName || m.game)) return m.gameName || m.game;
      return "";
    } catch (e) { return ""; }
  }
  function idOf(c, fp) {
    try {
      if (!c) return fp;
      if (c.getContentId && typeof c.getContentId === "function") { var id = c.getContentId(); if (id) return id; }
      if (c.contentId) return c.contentId;
      if (c.local_content_id) return c.local_content_id;
      if (c.id) return c.id;
      return fp;
    } catch (e) { return fp; }
  }
  function titleOf(c, fb) {
    try {
      var m = meta(c);
      if (m && typeof m.title === "string" && m.title && m.title !== "Untitled") return m.title;
    } catch (e) { }
    return fb;
  }

  async function load() {
    var keys = ["defaultTarget", "resolution"];
    for (var i = 0; i < keys.length; i++) {
      var v = await api.store.get(keys[i], null);
      if (v !== null && v !== undefined && v !== "") S[keys[i]] = v;
    }
  }
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

function Write-BundledSample($spec) {
  $sample = Join-Path $PluginsDir $spec.name
  New-Item -ItemType Directory -Path $sample -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $sample 'manifest.json') -Value (@{ name = $spec.name; version = $spec.version; author = 'bundled sample'; bundledMod = $ModVersion; description = $spec.description; entry = 'plugin.js' } | ConvertTo-Json) -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $sample 'plugin.js') -Value $spec.content -Encoding UTF8
}

function Write-PluginScaffold {
  if (-not (Test-Path -LiteralPath $PluginsDir)) { New-Item -ItemType Directory -Path $PluginsDir -Force | Out-Null }
  $specs = @(
    @{ name = 'youtube-backup'; version = '2.1'; description = 'Auto-uploads new clips to YouTube via embedded Studio window. No API keys needed.'; content = $SampleYouTube },
    @{ name = 'discord-send'; version = '2.0'; description = 'Trim a clip, render it to a Discord-size target, then drag it straight into Discord.'; content = $SampleDiscord }
  )
  foreach ($spec in $specs) {
    $sample = Join-Path $PluginsDir $spec.name
    if (-not (Test-Path -LiteralPath (Join-Path $sample 'plugin.js'))) {
      Write-BundledSample $spec
      Ok "Sample plugin installed: $($spec.name)"
    } else {
      $stale = $true
      $mf = Join-Path $sample 'manifest.json'
      if (Test-Path -LiteralPath $mf) {
        try {
          $m = Get-Content -LiteralPath $mf -Raw | ConvertFrom-Json
          if ($m.author -eq 'bundled sample' -and $m.bundledMod -and [int]$m.bundledMod -ge [int]$ModVersion) { $stale = $false }
        } catch { }
      }
      if ($stale) {
        $cur = Get-Content -LiteralPath $mf -Raw -ErrorAction SilentlyContinue
        if ($cur -and $cur -notmatch 'bundled sample') { Warn "$($spec.name) looks user-modified - keeping your version" }
        else {
          Copy-Item -LiteralPath (Join-Path $sample 'plugin.js') -Destination (Join-Path $sample 'plugin.js.bak') -Force -ErrorAction SilentlyContinue
          Write-BundledSample $spec
          Ok "Sample plugin upgraded to current version: $($spec.name) (old plugin.js kept as plugin.js.bak)"
        }
      } else { Ok "Sample plugin already current - keeping it: $($spec.name)" }
    }
  }
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
import{o as a}from"./renderer-chunk.js";import{t as d}from"./renderer-react.production.js";import{t as f}from"./renderer-react-jsx-runtime.production.js";import{n as nav}from"./renderer-router.js";
var R=a(d()),J=f();
const DIR=__PLUGINS_DIR__;
function dec(b){if(typeof b=="string")return b;try{var u8=b instanceof Uint8Array?b:ArrayBuffer.isView(b)?new Uint8Array(b.buffer,b.byteOffset,b.byteLength):new Uint8Array(b);return new TextDecoder().decode(u8)}catch(e){return ""}}
function kvGet(k){return MedalIPC.kvGet(k).catch(function(){return null})}
function kvPut(k,v){return MedalIPC.kvPut(k,v).catch(function(){})}
// ---- shared clip helpers: absolute file path, thumbnail blob URLs, library-like grid ----
function clipPath(c){
  try{
    if(!c)return null;
    if(c.video_path)return c.video_path;
    if(c.videoPath)return c.videoPath;
    var f=null;
    try{f=c.files?c.files():null}catch(e){}
    if(f&&f.current&&f.current.video)return f.current.video;
    if(c.getVideoPath){var gp=c.getVideoPath();if(gp)return gp}
  }catch(e){}
  return null;
}
function thumbPath(c){
  try{
    if(!c)return null;
    if(c.thumbnail_path)return c.thumbnail_path;
    if(c.thumbnailPath)return c.thumbnailPath;
    if(c.image_path)return c.image_path;
  }catch(e){}
  return null;
}
var thumbCache={};
function thumbUrl(c){
  var p=thumbPath(c);
  if(!p)return Promise.resolve(null);
  if(thumbCache[p])return thumbCache[p];
  var ext=String(p).split(".").pop().toLowerCase();
  var mime=ext==="png"?"image/png":(ext==="webp"?"image/webp":"image/jpeg");
  var pr=MedalIPC.fs.readFile(p).then(function(b){
    var u8=b instanceof Uint8Array?b:new Uint8Array(b);
    return URL.createObjectURL(new Blob([u8],{type:mime}));
  }).catch(function(){return null});
  thumbCache[p]=pr;
  return pr;
}
function Thumb(pro){
  var st=R.useState({url:null}),s=st[0],setS=st[1];
  R.useEffect(function(){var dead=false;thumbUrl(pro.clip).then(function(u){if(!dead)setS({url:u})});return function(){dead=true}},[pro.clip]);
  if(!s.url)return J.jsx("div",{style:{width:"100%",height:"90px",background:"#0a0a0a"}});
  return J.jsx("img",{src:s.url,alt:"",draggable:false,style:{width:"100%",height:"90px",objectFit:"cover",display:"block",background:"#000"}});
}
function ClipGrid(pro){
  var clips=pro.clips||[];
  return J.jsx("div",{style:{display:"grid",gridTemplateColumns:"repeat(auto-fill,minmax(160px,1fr))",gap:"10px"},children:clips.map(function(c,i){
    var sel=pro.selected===i;
    return J.jsxs("div",{onClick:function(){pro.onPick&&pro.onPick(c,i)},title:pro.label?pro.label(c,i):"",children:[
      J.jsx(Thumb,{clip:c}),
      J.jsx("div",{style:{padding:"6px 8px",fontSize:"12px",color:"#e8e8e8",whiteSpace:"nowrap",overflow:"hidden",textOverflow:"ellipsis"},children:pro.label?pro.label(c,i):("clip "+(i+1))})
    ],pro.keyOf?pro.keyOf(c,i):i});
  })});
}
function makeApi(id,dir,entry,reg){
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
    clipPath:clipPath,
    thumbUrl:thumbUrl,
    ClipGrid:ClipGrid,
    registerPage:function(pg){entry.pages.push({plugin:id,pageId:pg.id||id,title:pg.title||pg.id||id,render:pg.render})},
    registerClipAction:function(a){var rec={plugin:id,id:a.id,label:a.label||a.id,run:a.run};entry.clipActions.push(rec);reg.clipActions.push(rec)},
    registerSettings:function(schema){entry.schema=schema},
    toast:function(m){try{if(MedalIPC.toast)MedalIPC.toast(m);else console.log("[plugin:"+id+"]",m)}catch(e){console.log("[plugin:"+id+"]",m)}}
  };
}
var started=false;
export async function init(){
  if(started)return;started=true;
  var reg={plugins:[],pages:[],errors:[],clipActions:[]};
  window.__medalPlugins=reg;
  try{
    var man=JSON.parse(dec(await MedalIPC.fs.readFile(DIR+"\\plugins.json")));
    var enMap=await kvGet("medal-plugins:enabled")||{};
    var list=man.plugins||[];
    for(var k=0;k<list.length;k++){
      var p=list[k];
      var enabled=enMap[p.name]!==undefined?enMap[p.name]:(p.enabled!==false);
      var entry={name:p.name,version:p.version||"",author:p.author||"",description:p.description||"",enabled:enabled,loaded:false,error:null,pages:[],schema:null,cleanups:[],clipActions:[]};
      reg.plugins.push(entry);
      if(!enabled)continue;
      try{
        var code=dec(await MedalIPC.fs.readFile(DIR+"\\"+p.name+"\\"+(p.entry||"plugin.js")));
        var api=makeApi(p.name,DIR+"\\"+p.name,entry,reg);
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
function LoaderBox(pro){
  var lst=null,hasReg=false,nplug=0;
  try{
    lst=window.__medalLoaderStatus||null;
    hasReg=!!window.__medalPlugins;
    nplug=hasReg?((window.__medalPlugins.plugins||[]).length):0;
  }catch(e){}
  var txt=hasReg?("loader: registry live ("+nplug+" plugins)"+(lst&&lst.stage?(", stage "+lst.stage):"")):("loader: "+(lst?("stage="+lst.stage+(lst.error?(" — "+lst.error):"")):"never started"));
  var bad=!hasReg||(lst&&lst.stage==="failed");
  return(0,r.jsxs)("div",{style:{border:"1px solid "+(bad?"#7a2e2e":"#2c2c2c"),background:bad?"#1c0f0f":"#101010",borderRadius:"8px",padding:"8px 12px",fontSize:"12px",color:bad?"#ff9a9a":"#9a9a9a",marginBottom:"12px",display:"flex",gap:"10px",alignItems:"center"},children:[
    (0,r.jsx)("span",{style:{flex:1},children:txt+(pro.msg?(" · "+pro.msg):"")}),
    (0,r.jsx)("button",{onClick:pro.onRetry,style:{cursor:"pointer",border:"1px solid #3a3a3a",background:"#222",color:"#eee",borderRadius:"6px",padding:"4px 10px",fontSize:"12px"},children:"Retry loader"})
  ]});
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
function loaderStatus() {
  try { return window.__medalLoaderStatus || null; } catch (e) { return null; }
}
export default function PluginsHome(){
  var st=t.useState({loading:true,plugins:[],enabled:{},schemas:{}}),s=st[0],setS=st[1];
  var ui=t.useState({open:null,vals:{}}),u=ui[0],setU=ui[1];
  function refresh() {
    return (async function(){
      var man=JSON.parse(dec(await MedalIPC.fs.readFile(DIR+"\\plugins.json")));
      var en=await MedalIPC.kvGet("medal-plugins:enabled").catch(function(){return null})||{};
      setS({loading:false,plugins:man.plugins||[],enabled:en,schemas:schemas()});
      for(var k=0;k<20;k++){await new Promise(function(x){setTimeout(x,500)});var sc=schemas();if(Object.keys(sc).length){setS(function(p){return Object.assign({},p,{schemas:sc})});break}}
    })();
  }
  t.useEffect(function(){refresh().catch(function(e){setS({loading:false,plugins:[],enabled:{},schemas:{},error:String((e&&e.message)||e)})})},[]);
  function retryLoad() {
    setS(Object.assign({},s,{loading:true}));
    var p;
    try { p = import("./renderer-PluginLoader.js"); }
    catch(e) { setS(Object.assign({},s,{loading:false,msg:"Retry import threw: "+String((e&&e.message)||e)})); return; }
    Promise.resolve(p).then(function(m){return m.init&&m.init()}).then(function(){refresh().catch(function(e){setS(Object.assign({},s,{loading:false,msg:"Retry init failed: "+String((e&&e.message)||e)}))})},function(e){setS(Object.assign({},s,{loading:false,msg:"Retry import failed: "+String((e&&e.message)||e)}))});
  }
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
    (0,r.jsx)(LoaderBox,{onRetry:retryLoad,msg:s.msg}),
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
// Stable wrapper: the plugin's render() runs inside PluginView so hooks it calls
// live on this fiber. Calling render() inline in PluginPage would change that
// fiber's hook count between renders -> minified React error #310.
function PluginView(pro){
  try{return(0,r.jsx)("div",{style:S.page,children:pro.render(pro.api)})}
  catch(e){return(0,r.jsx)("div",{style:S.page,children:(0,r.jsx)("div",{style:S.err,children:"Plugin page crashed: "+String((e&&e.message)||e)})})}
}
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
  return(0,r.jsx)(PluginView,{render:pg.render,api:api},s.id);
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
s = replaceOnce(s, 'MedalIPC.updateSetting(dt.SDKMode,!1)},[]),null}', 'MedalIPC.updateSetting(dt.SDKMode,!1)},[]),(0,p.useEffect)(()=>{try{window.__medalLoaderStatus={stage:"effect-ran",at:Date.now()}}catch(e){}import("./chunks/renderer-PluginLoader.js").then(function(m){try{window.__medalLoaderStatus.stage="imported"}catch(e){}return m.init&&m.init()}).then(function(){try{window.__medalLoaderStatus.stage="ready"}catch(e){}}).catch(function(e){try{window.__medalLoaderStatus={stage:"failed",error:String((e&&e.message)||e)}}catch(_){}})},[]),null}', 'plugin-loader-mount');
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
// --- YOUTUBE: Medal blocks non-Medal webviews (black screen). Its URL allowlist
// (qtt, checked by xE on webview attach + page loads) only has medal.tv hosts,
// so studio.youtube.com gets preventDefault()ed. Add YouTube + Google auth hosts.
mm = replaceOnce(mm2, 'var qtt=["medal.tv","www.medal.tv","test-medal.tv","www.test-medal.tv","staging-medal.tv","www.staging-medal.tv","support.medal.tv"]', 'var qtt=["medal.tv","www.medal.tv","test-medal.tv","www.test-medal.tv","staging-medal.tv","www.staging-medal.tv","support.medal.tv","studio.youtube.com","www.youtube.com","youtube.com","accounts.google.com"]', 'main-youtube-hosts');
fs.writeFileSync(mainPath, mm);
// --- OAUTH: one-shot loopback listener so plugins get one-click login (no code paste) ---
mm = replaceOnce(mm, 'Ie.ipcMain.handle("fs:readFile",(t,n)=>(Vo("fs:readFile",n),Ht.default.readFile(n)))', 'Ie.ipcMain.handle("fs:readFile",(t,n)=>(Vo("fs:readFile",n),Ht.default.readFile(n)));(()=>{let srv=null,port=0,pend=null,waiters=[];const fin=v=>{const w=waiters;waiters=[];w.forEach(f=>{try{f(v)}catch(e){}})};Ie.ipcMain.handle("medal-plugins:oauth-listen",()=>new Promise(res=>{if(srv&&port)return res({port:port});const http=require("node:http");srv=http.createServer((req,rs)=>{try{const u=new URL(req.url||"/","http://127.0.0.1");const code=u.searchParams.get("code"),err=u.searchParams.get("error");rs.writeHead(200,{"Content-Type":"text/html"});rs.end(code?"<html><body><h3>Logged in! Return to Medal.</h3></body></html>":"<html><body><h3>Login did not complete. Return to Medal.</h3></body></html>");if(code||err){pend={code:code||null,error:err||null};fin(pend);pend=null}}catch(e){}});srv.listen(0,"127.0.0.1",()=>{port=srv.address().port;res({port:port})});setTimeout(()=>{try{srv&&srv.close()}catch(e){}srv=null;port=0;fin({code:null,error:"timeout"})},180000)}));Ie.ipcMain.handle("medal-plugins:oauth-await",()=>new Promise(res=>{if(pend){const p=pend;pend=null;res(p)}else waiters.push(res)}))})()', 'main-oauth');
fs.writeFileSync(mainPath, mm);
// --- OAUTH: bridge the new channels into the renderer preload ---
const prePath = path.join(dir, 'preload.min.js');
let pp = fs.readFileSync(prePath, 'utf8');
pp = replaceOnce(pp, 'getPathForFile:e=>r.webUtils.getPathForFile(e)},openExternal:', 'getPathForFile:e=>r.webUtils.getPathForFile(e)},plugins:{oauthListen:()=>r.ipcRenderer.invoke("medal-plugins:oauth-listen"),oauthAwait:()=>r.ipcRenderer.invoke("medal-plugins:oauth-await"),exportMp4:e=>r.ipcRenderer.invoke("medal-plugins:export-mp4",e),discordRender:e=>r.ipcRenderer.invoke("medal-plugins:discord-render",e),discordDragSync:e=>r.ipcRenderer.sendSync("medal-plugins:discord-drag",e)},openExternal:', 'preload-plugins-bridge');
fs.writeFileSync(prePath, pp);
const pp2 = fs.readFileSync(prePath, 'utf8');
if (!pp2.includes('medal-plugins:oauth-listen') || !pp2.includes('medal-plugins:oauth-await') || !pp2.includes('medal-plugins:export-mp4') || !pp2.includes('medal-plugins:discord-render') || !pp2.includes('medal-plugins:discord-drag')) throw new Error('PRELOAD LEFTOVER: plugins bridge missing');
const mm3 = fs.readFileSync(mainPath, 'utf8');
if (!mm3.includes('"medal-plugins:oauth-listen"') || !mm3.includes('"medal-plugins:oauth-await"')) throw new Error('MAIN LEFTOVER: oauth channels missing');
if (!mm3.includes('"studio.youtube.com"')) throw new Error('MAIN LEFTOVER: youtube hosts not allowlisted');
// --- EXPORT: mux fragmented local clips (DASH session.mpd + .m4s) to a single mp4 via Medal's own ffmpeg ---
// Local clips are folders, not files - the uploader needs a real mp4, so this IPC remuxes with -c copy.
mm = replaceOnce(mm3, 'a.success>0&&oa(),a}),Ie.ipcMain.handle("fs:resolveStaffDebugFolderPath"', 'a.success>0&&oa(),a}),Ie.ipcMain.handle("medal-plugins:export-mp4",async(s,n)=>{const fs=require("node:fs"),path=require("node:path"),os=require("node:os"),cp=require("node:child_process");const ff=path.join(os.homedir(),"AppData","Local","Medal","ffmpeg7.exe");try{await fs.promises.access(ff)}catch(e){throw new Error("export-mp4: ffmpeg7.exe not found at "+ff)}const st=await fs.promises.stat(n).catch(()=>null);if(!st)throw new Error("export-mp4: clip path not found: "+n);if(st.isFile()&&/\\.mp4$/i.test(n))return{path:n,temp:false};const dir=st.isDirectory()?n:path.dirname(n);async function findMpd(d,depth){const ents=await fs.promises.readdir(d,{withFileTypes:true}).catch(()=>[]);for(const e of ents){const p=path.join(d,e.name);if(e.isFile()&&e.name.toLowerCase()==="session.mpd")return p;if(e.isDirectory()&&depth>0){const r=await findMpd(p,depth-1);if(r)return r}}return null}const mpd=await findMpd(dir,3);if(!mpd)throw new Error("export-mp4: no DASH package (session.mpd) under: "+dir);const base=path.dirname(mpd);const ents=await fs.promises.readdir(base);const pick=re=>ents.filter(f=>re.test(f)).sort().map(f=>path.join(base,f));const v=pick(/^chunk-stream0-.*\\.m4s$/i),a=pick(/^chunk-stream1-.*\\.m4s$/i);const has=async p=>{try{await fs.promises.access(p);return true}catch(e){return false}};if(!(await has(path.join(base,"init-stream0.m4s")))||!v.length)throw new Error("export-mp4: video segments missing in: "+base);const args=["-hide_banner","-y","-i","concat:"+[path.join(base,"init-stream0.m4s")].concat(v).join("|")];if(await has(path.join(base,"init-stream1.m4s"))&&a.length)args.push("-i","concat:"+[path.join(base,"init-stream1.m4s")].concat(a).join("|"));const out=path.join(dir,"clip-upload-"+Date.now()+".mp4");args.push("-c","copy","-movflags","+faststart",out);await new Promise((res,rej)=>{cp.execFile(ff,args,{timeout:600000},(e,stdout,stderr)=>{if(e)rej(new Error("export-mp4: ffmpeg failed: "+String(stderr||e.message).slice(-400)));else res(true)})});const ost=await fs.promises.stat(out).catch(()=>null);if(!ost||ost.size<100000)throw new Error("export-mp4: output missing/too small: "+out);return{path:out,temp:true}}),Ie.ipcMain.handle("fs:resolveStaffDebugFolderPath"', 'main-export-mp4');
fs.writeFileSync(mainPath, mm);
const mm4 = fs.readFileSync(mainPath, 'utf8');
if (!mm4.includes('"medal-plugins:export-mp4"')) throw new Error('MAIN LEFTOVER: export-mp4 missing');
console.log('clip export-mp4 wired');
// --- DISCORD: size-targeted trim+transcode render + OS file-drag bridges ---
// discord-render: {src, start, end, targetMB, resolution} -> {path, sizeBytes}.
// src may be an mp4 or a DASH clip folder (remuxed first, same concat approach).
mm = replaceOnce(mm4, 'return{path:out,temp:true}}),Ie.ipcMain.handle("fs:resolveStaffDebugFolderPath"', 'return{path:out,temp:true}}),Ie.ipcMain.handle("medal-plugins:discord-render",async(s,o)=>{const fs=require("node:fs"),path=require("node:path"),os=require("node:os"),cp=require("node:child_process");const ff=path.join(os.homedir(),"AppData","Local","Medal","ffmpeg7.exe");try{await fs.promises.access(ff)}catch(e){throw new Error("discord-render: ffmpeg7.exe not found at "+ff)}const src=o&&o.src;if(!src)throw new Error("discord-render: missing src");const start=Math.max(0,Number(o.start)||0);const end=Number(o.end);if(!(end>start))throw new Error("discord-render: bad trim range (end must be after start)");const targetMB=Math.min(100,Math.max(1,Number(o.targetMB)||25));const res=String(o.resolution||"720p");async function findMpd(d,depth){const ents=await fs.promises.readdir(d,{withFileTypes:true}).catch(()=>[]);for(const e of ents){const p=path.join(d,e.name);if(e.isFile()&&e.name.toLowerCase()==="session.mpd")return p;if(e.isDirectory()&&depth>0){const r=await findMpd(p,depth-1);if(r)return r}}return null}let inFile=src;const sst=await fs.promises.stat(src).catch(()=>null);if(!sst)throw new Error("discord-render: src not found: "+src);if(!(sst.isFile()&&/\\.mp4$/i.test(src))){const dir=sst.isDirectory()?src:path.dirname(src);const mpd=await findMpd(dir,3);if(!mpd)throw new Error("discord-render: no DASH package under: "+dir);const base=path.dirname(mpd);const ents=await fs.promises.readdir(base);const pick=re=>ents.filter(f=>re.test(f)).sort().map(f=>path.join(base,f));const vv=pick(/^chunk-stream0-.*\\.m4s$/i),aa=pick(/^chunk-stream1-.*\\.m4s$/i);const has=async p=>{try{await fs.promises.access(p);return true}catch(e){return false}};if(!(await has(path.join(base,"init-stream0.m4s")))||!vv.length)throw new Error("discord-render: video segments missing");const rargs=["-hide_banner","-y","-i","concat:"+[path.join(base,"init-stream0.m4s")].concat(vv).join("|")];if(await has(path.join(base,"init-stream1.m4s"))&&aa.length)rargs.push("-i","concat:"+[path.join(base,"init-stream1.m4s")].concat(aa).join("|"));inFile=path.join(dir,"discord-src-"+Date.now()+".mp4");rargs.push("-c","copy",inFile);await new Promise((res2,rej)=>{cp.execFile(ff,rargs,{timeout:600000},(e2,so,se)=>{if(e2)rej(new Error("discord-render: remux failed: "+String(se||e2.message).slice(-300)));else res2(true)})})}const dur=end-start;const totalBits=Math.floor(targetMB*1024*1024*8*0.85);let vbits=Math.floor(totalBits/dur)-128000;if(vbits<200000)vbits=200000;const vf=res==="source"?[]:["-vf","scale="+(res==="1080p"?"-2:1080":"-2:720")+":force_original_aspect_ratio=decrease"];const out=path.join(path.dirname(inFile),"discord-"+Date.now()+".mp4");const args=["-hide_banner","-y","-i",inFile,"-ss",String(start),"-to",String(end)].concat(vf,["-c:v","libx264","-preset","veryfast","-b:v",String(vbits),"-maxrate",String(Math.floor(vbits*1.3)),"-bufsize",String(Math.floor(vbits*2)),"-c:a","aac","-b:a","128k","-movflags","+faststart",out]);await new Promise((res2,rej)=>{cp.execFile(ff,args,{timeout:1200000},(e2,so,se)=>{if(e2)rej(new Error("discord-render: ffmpeg failed: "+String(se||e2.message).slice(-400)));else res2(true)})});if(inFile!==src)await fs.promises.unlink(inFile).catch(()=>{});const ost=await fs.promises.stat(out).catch(()=>null);if(!ost||!ost.size)throw new Error("discord-render: no output produced");return{path:out,sizeBytes:ost.size}}),Ie.ipcMain.handle("medal-plugins:discord-drag",(e,o)=>{try{const NI=require("electron").nativeImage;let icon=NI.createEmpty();try{const cands=[o&&o.icon,o&&o.thumb].filter(Boolean);for(const p of cands){const im=NI.createFromPath(p);if(im&&!im.isEmpty()){icon=im;break}}}catch(_){}e.sender.startDrag({file:o.path,icon:icon});e.returnValue={ok:true}}catch(err){try{e.returnValue={ok:false,error:String(err&&err.message||err)}}catch(_){}}}),Ie.ipcMain.handle("fs:resolveStaffDebugFolderPath"', 'main-discord-bridges');
fs.writeFileSync(mainPath, mm);
const mm5 = fs.readFileSync(mainPath, 'utf8');
if (!mm5.includes('"medal-plugins:discord-render"') || !mm5.includes('"medal-plugins:discord-drag"')) throw new Error('MAIN LEFTOVER: discord bridges missing');
console.log('discord render+drag wired');
console.log('oauth loopback login wired (main + preload)');
// --- PLUGINS: clip context-menu rows registered by plugins (e.g. Upload to YouTube) ---
// Rendered right after the Download row, only for plugins that registered while enabled.
const cmPath = path.join(dir, 'chunks', 'renderer-ClipContextMenu.js');
let cm = fs.readFileSync(cmPath, 'utf8');
cm = replaceOnce(cm, '}):(0,e.jsx)(c,{className:d,onClick:()=>w(t,n),children:s.download}),de&&', '}):(0,e.jsx)(c,{className:d,onClick:()=>w(t,n),children:s.download}),(window.__medalPlugins&&window.__medalPlugins.clipActions||[]).map(function(act){return(0,e.jsx)(c,{className:d,onClick:function(){try{act.run(t,n)}catch(err){}},children:act.label},act.plugin+"-"+act.id)}),de&&', 'menu-clip-actions');
fs.writeFileSync(cmPath, cm);
const cm2 = fs.readFileSync(cmPath, 'utf8');
if (!cm2.includes('__medalPlugins.clipActions')) throw new Error('MENU LEFTOVER: clip actions not injected');
console.log('clip context-menu actions wired');
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
