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
$ModVersion = '34'
$PinnedMedal = '2638.479.1'

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  [!] $msg" -ForegroundColor Yellow }

# --- 0. Elevate ---
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$MedalRootCheck = Join-Path $env:LOCALAPPDATA 'Medal'
$CanWriteMedal = $false
try {
  if (Test-Path -LiteralPath $MedalRootCheck) {
    $tw = Join-Path $MedalRootCheck '.write_test'
    [IO.File]::WriteAllText($tw, '1')
    if (Test-Path -LiteralPath $tw) { Remove-Item -LiteralPath $tw -Force; $CanWriteMedal = $true }
  }
} catch {}
if (-not $IsAdmin -and -not $CanWriteMedal) {
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


$SampleDiscord = @'
// discord-send  -  trim a clip, render it to a Discord-size target, drag it into Discord.
// Folder: %LOCALAPPDATA%\Medal\plugins\discord-send\plugin.js
(function () {
  var S = { defaultTarget: "20", resolution: "720p", showInSidebar: true };
  var TARGETS = [10, 20, 50, 100];
  var PAGE_SIZE = 100;
  var vidEl = null; // active preview element, driven by the custom transport + timeline
  var tlSkip = false; // suppress the track click-to-seek right after a handle drag
  var searchTimer = null; // debounce handle for the library search box
  var lastQuery = ""; // freshest search text - render closures go stale across the debounce, so the guard reads this

  api.registerSettings([
    { key: "defaultTarget", label: "Default size target (MB)", type: "select", default: "20", options: [{ value: "10", label: "10 MB (Discord free)" }, { value: "20", label: "20 MB (Recommended)" }, { value: "50", label: "50 MB" }, { value: "100", label: "100 MB (Nitro)" }] },
    { key: "showInSidebar", label: "Show Discord in Medal left sidebar", type: "checkbox", default: true },
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

  // ---------- palette / shared styles (UI only) ----------
  var C = {
    blurple: "#5865F2",
    blurpleSoft: "rgba(88,101,242,0.14)",
    lime: "#b6f34a",
    limeSoft: "rgba(182,243,74,0.10)",
    bg: "#161616",
    card: "#1a1a1a",
    inset: "#101010",
    border: "#2c2c2c",
    borderSoft: "#252525",
    txt: "#f0f0f0",
    sub: "#b9b9b9",
    dim: "#888888",
    danger: "#ff7a7a",
    warn: "#ffcf7a"
  };
  var CHROME_TOP = 56; // Medal's custom title bar height (CSS px) - overlays start below it so minimize/maximize stay visible

  function Page(a) {
    var R = a.React;
    var st = R.useState({
      clips: [],
      idx: -1,
      selectedClip: null,
      src: "",
      dur: 0,
      start: 0,
      end: 0,
      hasMeta: false,
      target: 20,
      busy: false,
      cur: 0,
      playing: false,
      msg: "Loading clips...",
      outPath: "",
      outSize: 0,
      showModal: false,
      editor: false,
      search: "",
      limit: PAGE_SIZE,
      hasMore: true,
      loadingMore: false
    });
    var s = st[0];
    function set(patch) {
      st[1](function (prev) {
        var n = {};
        for (var k in prev) n[k] = prev[k];
        for (var k2 in patch) n[k2] = patch[k2];
        return n;
      });
    }

    // every word in the query must appear somewhere in title / game / label / filename
    function matchClip(c, i, words) {
      var fp = "";
      try { fp = String(api.clipPath(c) || ""); } catch (_) { fp = ""; }
      var base = fp.split("/").pop().split("\\").pop();
      var hay = ((titleOf(c, "") || "") + " " + (gameOf(c, "") || "") + " " + (label(c, i) || "") + " " + base).toLowerCase();
      for (var w = 0; w < words.length; w++) { if (hay.indexOf(words[w]) < 0) return false; }
      return true;
    }

    function fetchClips(query, limit, append) {
      var opts = { limit: limit || s.limit || PAGE_SIZE };
      if (query && query.trim()) opts.textSearch = query.trim();
      return a.MedalIPC.getContents(opts).then(function (q) {
        // stale response? a newer query was typed since - ignore so old
        // results can never overwrite the current search box text
        // (reads lastQuery, not s.search: this closure predates the keystroke)
        if ((query || "") !== (lastQuery || "")) return [];
        var newClips = (q && q.contents) || [];
        var words = (query && query.trim()) ? query.trim().toLowerCase().split(/\s+/) : [];
        var shown = words.length ? newClips.filter(function (c, i) { return matchClip(c, i, words); }) : newClips;
        var combined = append ? s.clips.concat(shown) : shown;
        var msg = combined.length ? ("Showing " + combined.length + " clips. Pick one to trim and send.") : (query ? "No clips matching '" + query + "'." : "No clips found.");
        set({
          clips: combined,
          hasMore: newClips.length >= (limit || PAGE_SIZE),
          loadingMore: false,
          msg: s.src ? s.msg : msg
        });
        return combined;
      }, function (e) {
        set({ loadingMore: false, msg: "Could not list clips: " + String((e && e.message) || e) });
        return [];
      });
    }

    function init() {
      load().then(function () {
        var t = parseInt(S.defaultTarget, 10) || 20;
        set({ target: t });
        return fetchClips("", PAGE_SIZE, false).then(function (clips) {
          consumePending(clips);
        });
      });
    }
    R.useEffect(function () { init(); }, []);
    R.useEffect(function () {
      function onKey(e) {
        try {
          if (e.key === "Escape" || e.keyCode === 27) {
            if (s.showModal) set({ showModal: false });
            else if (s.editor) set({ editor: false });
            return;
          }
          var isSpace = e.key === " " || e.code === "Space" || e.keyCode === 32;
          if (isSpace && s.editor && !s.showModal) {
            var t = e.target;
            var tag = (t && t.tagName) ? String(t.tagName).toUpperCase() : "";
            if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || tag === "BUTTON" || (t && t.isContentEditable)) return;
            try { e.preventDefault(); } catch (_) { }
            togglePlay();
          }
        } catch (_) { }
      }
      try { window.addEventListener("keydown", onKey); } catch (_) { }
      return function () { try { window.removeEventListener("keydown", onKey); } catch (_) { } };
    });

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
          else if (p.videoPath) {
            set({ src: p.videoPath, selectedClip: null, idx: -1, editor: true, msg: "Clip selected from menu. Set trim & size, then hit Render." });
          }
          if (p.title) api.toast("Selected: " + p.title);
        }
      }, function () { });
    }

    function pick(i, list, dir) {
      var clips = list || s.clips;
      var c = clips[i];
      if (!c) return;
      var fp = api.clipPath(c);
      if (!fp) { set({ msg: "Could not resolve clip path (cloud-only clip?)." }); return; }

      if (s.idx === i && s.src === fp && s.hasMeta) {
        set({ editor: true });
        return;
      }

      var d = durOf(c);
      var isFolder = !/\.mp4$/i.test(fp);
      var initialEnd = d > 0 ? round1(Math.min(d, 30)) : 15;

      set({
        idx: i,
        selectedClip: c,
        src: fp,
        dur: d,
        start: 0,
        end: initialEnd,
        cur: 0,
        playing: false,
        hasMeta: d > 0,
        editor: true,
        msg: isFolder ? "DASH package selected (" + (d > 0 ? d.toFixed(1) + "s" : "ready") + "). Set trim & size, then hit Render." : (d > 0 ? "Clip selected (" + d.toFixed(1) + "s). Ready to trim." : "Loading clip preview..."),
        outPath: "",
        outSize: 0,
        showModal: false,
        slideDir: dir || 0
      });
    }

    function previewUrl() {
      if (s.src && /\.mp4$/i.test(s.src)) {
        return "file:///" + encodeURI(String(s.src).replace(/\\/g, "/")).replace(/^\/+/, "").replace(/#/g, "%23").replace(/\?/g, "%3F");
      }
      return "";
    }

    function onMeta(e) {
      try {
        var d = e && e.target && e.target.duration ? Number(e.target.duration) : 0;
        if (!(d > 0)) return;
        var curEnd = s.end > 0 ? s.end : round1(Math.min(d, 30));
        set({ dur: round1(d), end: Math.min(round1(d), curEnd), hasMeta: true, msg: "Preview ready (" + round1(d) + "s). Adjust trim & size, then hit Render." });
      } catch (err) { }
    }

    function onVideoRef(el) {
      vidEl = el || null;
      // NOTE: this closure is a NEW function every render, so React calls the
      // old one with null on every commit. Never set() unconditionally here
      // or it loops forever (Maximum update depth exceeded). Only clear the
      // flag when it is actually set.
      if (!el) { if (s.playing) set({ playing: false }); return; }
      try {
        if (el.readyState >= 1 && el.duration > 0 && !s.hasMeta) {
          onMeta({ target: el });
        }
      } catch (e) { }
    }

    function onTime(e) {
      try {
        var t = Number(e && e.target && e.target.currentTime) || 0;
        if (Math.abs(t - (s.cur || 0)) > 0.4) set({ cur: round1(t) });
      } catch (err) { }
    }

    function onPlayState(playing) {
      if (!!s.playing !== !!playing) set({ playing: !!playing });
    }

    function togglePlay() {
      if (!vidEl) return;
      try {
        if (vidEl.paused) { vidEl.play(); } else { vidEl.pause(); }
      } catch (e) { }
    }


    function seekTo(t) {
      var t2 = round1(Math.max(0, Number(t) || 0));
      if (durBase > 0) t2 = Math.min(t2, durBase);
      if (vidEl && !isFolder && durBase > 0) { try { vidEl.currentTime = t2; } catch (e) { } }
      set({ cur: t2 });
    }

    function setEdge(which) {
      var base = vidEl ? (Number(vidEl.currentTime) || 0) : (s.cur || 0);
      base = round1(Math.max(0, base));
      if (which === "start") set(clampTrim(base, s.end));
      else set(clampTrim(s.start, base));
    }

    function tlSeek(e) {
      if (tlSkip) { tlSkip = false; return; }
      try {
        var el = document.getElementById("ds-tl-track");
        if (!el) return;
        var r = el.getBoundingClientRect();
        if (!r.width) return;
        var ratio = ((e.clientX - r.left) / r.width);
        ratio = Math.max(0, Math.min(1, ratio));
        var t = round1(ratio * (durBase > 0 ? durBase : 60));
        if (vidEl && !isFolder && durBase > 0) { try { vidEl.currentTime = Math.min(t, durBase); } catch (err) { } }
        set({ cur: t });
      } catch (err) { }
    }

    function rulerSeek(e) {
      try {
        var el = e.currentTarget || e.target;
        if (!el || !el.getBoundingClientRect) return;
        var r = el.getBoundingClientRect();
        if (!r.width) return;
        var ratio = ((e.clientX - r.left) / r.width);
        ratio = Math.max(0, Math.min(1, ratio));
        var t = round1(ratio * (durBase > 0 ? durBase : 60));
        if (vidEl && !isFolder && durBase > 0) { try { vidEl.currentTime = Math.min(t, durBase); } catch (err) { } }
        set({ cur: t });
      } catch (err) { }
    }

    function stepFrame(dir) {
      try {
        var base = (s.cur || 0) + dir / 30;
        var cap = durBase > 0 ? durBase : 600;
        var t = Math.round(Math.max(0, Math.min(cap, base)) * 1000) / 1000;
        if (vidEl) {
          try { vidEl.pause(); } catch (_) { }
          if (!isFolder && durBase > 0) { try { vidEl.currentTime = Math.min(t, durBase); } catch (_) { } }
        }
        set({ cur: t, playing: false });
      } catch (_) { }
    }

    function frameArrow(dir) {
      if (!(s.src && s.editor)) return null;
      return a.el("button", {
        onClick: function () { stepFrame(dir); },
        title: dir < 0 ? "Previous frame (1/30s)" : "Next frame (1/30s)",
        style: {
          position: "fixed", top: "50%", transform: "translateY(-50%)",
          left: dir < 0 ? "10px" : "auto", right: dir > 0 ? "10px" : "auto",
          zIndex: 90001, width: "44px", height: "64px", padding: 0,
          background: "#1d1d22", color: "#e5e5e5",
          border: "1px solid #383838", borderRadius: "10px",
          fontSize: "22px", fontWeight: "800", lineHeight: "1",
          cursor: "pointer", opacity: 0.85
        }
      }, dir < 0 ? "<" : ">");
    }

    function edgeDrag(which, e) {
      try { e.preventDefault(); e.stopPropagation(); } catch (_) { }
      function move(ev) {
        try {
          var el = document.getElementById("ds-tl-track");
          if (!el) return;
          var r = el.getBoundingClientRect();
          if (!r.width) return;
          var ratio = ((ev.clientX - r.left) / r.width);
          ratio = Math.max(0, Math.min(1, ratio));
          var t = round1(ratio * (durBase > 0 ? durBase : 60));
          // move the trim edge AND the playhead (with preview follow) in one set
          var tp = which === "start" ? clampTrim(t, s.end) : clampTrim(s.start, t);
          tp.cur = t;
          if (vidEl && !isFolder) { try { vidEl.currentTime = Math.min(t, durBase > 0 ? durBase : t); } catch (_) { } }
          set(tp);
        } catch (_) { }
      }
      function up() {
        try { window.removeEventListener("mousemove", move); window.removeEventListener("mouseup", up); } catch (_) { }
        tlSkip = true;
      }
      try { window.addEventListener("mousemove", move); window.addEventListener("mouseup", up); } catch (_) { }
    }

    function rulerTicks() {
      var out = [];
      var total = durBase > 0 ? durBase : 0;
      for (var i = 0; i <= 4; i++) {
        (function (i) {
          var pct = i * 25;
          var tt = total > 0 ? round1(total * i / 4) : 0;
          var lab = total > 0 ? fmtTime(tt) : (i === 0 ? "0:00" : "--:--");
          out.push(a.el("div", {
            key: i,
            onClick: total > 0 ? (function (tt) { return function (e) { try { e.stopPropagation(); } catch (_) { } seekTo(tt); }; })(tt) : null,
            title: total > 0 ? ("Seek to " + lab) : null,
            style: {
              position: "absolute", top: 0, bottom: 0, left: pct + "%",
              borderLeft: i === 0 ? "none" : "1px solid #2e2e2e",
              paddingLeft: "5px", fontSize: "11px", color: "#777",
              transform: pct === 100 ? "translateX(-100%)" : "none", paddingRight: pct === 100 ? "2px" : "0",
              whiteSpace: "nowrap", cursor: total > 0 ? "pointer" : "default"
            }
          }, lab));
        })(i);
      }
      if (total > 0) {
        var step = total > 40 ? Math.ceil(total / 40) : 1;
        for (var k = step; k < total; k += step) {
          (function (k) {
            out.push(a.el("div", {
              key: "m" + k,
              style: { position: "absolute", top: "5px", bottom: "3px", left: ((k / total) * 100) + "%", width: "1px", background: "#2c2c2c", pointerEvents: "none" }
            }));
          })(k);
        }
      }
      return out;
    }

    function onSrcError() {
      set({ hasMeta: s.dur > 0, msg: "Direct preview unavailable  -  you can still trim & Render." });
    }

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

    function doRender(targetMB) {
      var P = a.MedalIPC.plugins || {};
      if (!P.discordRender) {
        set({ msg: "Discord render bridge missing. Ensure patch v18 is installed and restart Medal." });
        return;
      }
      if (!s.src) { set({ msg: "Pick a clip first." }); return; }
      var t = clampTrim(s.start, s.end);
      if (!(t.end > t.start)) { set({ msg: "Invalid trim range (end must be greater than start)." }); return; }
      var mb = targetMB || s.target;
      var dur = (t.end - t.start).toFixed(1);
      set({ busy: true, target: mb, msg: "Rendering " + dur + "s clip to " + mb + " MB target... please wait", outPath: "", outSize: 0 });
      load().then(function () {
        return P.discordRender({ src: s.src, start: t.start, end: t.end, targetMB: mb, resolution: S.resolution || "720p" });
      }).then(function (r) {
        var op = (r && (r.outPath || r.path)) || "";
        var sz = (r && r.sizeBytes) || 0;
        if (!op) throw new Error("Renderer did not return a valid output file.");
        api.toast("Discord render complete: " + fmtMB(sz));
        set({
          busy: false,
          outPath: op,
          outSize: sz,
          showModal: true,
          msg: "Render complete (" + fmtMB(sz) + ")! Drag into Discord."
        });
      }, function (e) {
        set({ busy: false, msg: "Render failed: " + String((e && e.message) || e) });
      });
    }

    function thumbOf() {
      if (s.selectedClip) {
        try { return s.selectedClip.thumbnail_path || s.selectedClip.thumbnailPath || s.selectedClip.image_path || null; } catch (e) { }
      }
      if (s.clips && s.idx >= 0 && s.clips[s.idx]) {
        try { return s.clips[s.idx].thumbnail_path || s.clips[s.idx].thumbnailPath || s.clips[s.idx].image_path || null; } catch (e) { }
      }
      return null;
    }

    function thumbUrlOf(c) {
      var tp = null;
      try { tp = c.thumbnail_path || c.thumbnailPath || c.image_path || null; } catch (e) { }
      if (!tp) return null;
      return "file:///" + encodeURI(String(tp).replace(/\\/g, "/")).replace(/^\/+/, "").replace(/#/g, "%23").replace(/\?/g, "%3F");
    }

    function onDragStart(e) {
      var P = a.MedalIPC.plugins || {};
      try { if (e && e.dataTransfer) { e.dataTransfer.effectAllowed = "copy"; } } catch (_) { }
      if (!s.outPath) return;
      if (P.discordDragSync) {
        try {
          P.discordDragSync({ path: s.outPath, thumb: thumbOf() });
          set({ msg: "Drop the file into any Discord channel or DM! (Or use Open folder)." });
        } catch (err) {
          set({ msg: "Drag bridge issue: Use 'Open folder' to drag the file manually." });
        }
      } else {
        set({ msg: "Drag bridge not available. Use 'Open folder' to drag the file into Discord." });
      }
    }

    function openFolder() {
      if (s.outPath) a.MedalIPC.fs.showInFolder(s.outPath);
    }

    function copyPath() {
      if (!s.outPath) return;
      try {
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(s.outPath).then(function () { api.toast("Path copied to clipboard"); }, function () { set({ msg: "Path: " + s.outPath }); });
        } else {
          set({ msg: "Path: " + s.outPath });
        }
      } catch (e) { set({ msg: "Path: " + s.outPath }); }
    }

    function onSearchChange(e) {
      var q = e.target.value;
      lastQuery = q;
      set({ search: q });
      try { if (searchTimer) clearTimeout(searchTimer); } catch (_) { }
      searchTimer = setTimeout(function () { fetchClips(q, PAGE_SIZE, false); }, 250);
    }

    function loadMore() {
      var nextLimit = s.clips.length + PAGE_SIZE;
      set({ loadingMore: true });
      fetchClips(s.search, nextLimit, false);
    }

    function label(c, i) {
      var g = gameOf(c);
      var t = titleOf(c, "");
      if (t) return (g ? g + "  -  " : "") + t;
      var id = idOf(c, "");
      return ((g ? g + "  -  " : "") + "clip " + (id ? String(id).slice(-6) : "#" + (i + 1)));
    }

    // ---------- derived UI state (display only) ----------
    var isFolder = s.src && !/\.mp4$/i.test(s.src);
    var trimLen = (s.end > s.start) ? (s.end - s.start) : 0;
    var estBitrate = trimLen > 0 ? Math.round((s.target * 8192) / trimLen) : 0;
    var lowQ = estBitrate > 0 && estBitrate < 800;
    var activeThumb = s.selectedClip ? thumbUrlOf(s.selectedClip) : (s.clips[s.idx] ? thumbUrlOf(s.clips[s.idx]) : null);
    var durBase = s.dur > 0 ? s.dur : 0;
    var p0 = durBase > 0 ? Math.max(0, Math.min(100, (s.start / durBase) * 100)) : 0;
    var p1 = durBase > 0 ? Math.max(0, Math.min(100, (s.end / durBase) * 100)) : 0;
    var pc = durBase > 0 ? Math.max(0, Math.min(100, ((s.cur || 0) / durBase) * 100)) : 0;
    var clipGame = s.selectedClip ? gameOf(s.selectedClip) : "";
    var clipTitle = s.selectedClip ? (titleOf(s.selectedClip, "") || label(s.selectedClip, s.idx)) : "Selected clip";
    var msgLower = String(s.msg || "").toLowerCase();
    var isErr = msgLower.indexOf("failed") >= 0 || msgLower.indexOf("could not") >= 0 || msgLower.indexOf("missing") >= 0 || msgLower.indexOf("invalid") >= 0 || msgLower.indexOf("unavailable") >= 0 || msgLower.indexOf("bridge") >= 0;

    var statusKind = "idle", statusText = "Pick a clip below";
    if (s.busy) { statusKind = "busy"; statusText = "Rendering " + s.target + " MB..."; }
    else if (isErr && !s.src) { statusKind = "err"; statusText = "Something needs attention"; }
    else if (s.outPath) { statusKind = "ok"; statusText = "Ready to share  -  " + fmtMB(s.outSize); }
    else if (s.src) {
      statusKind = isErr ? "err" : "ready";
      statusText = trimLen > 0 ? (trimLen.toFixed(1) + "s  ->  " + s.target + " MB") : "Adjust trim, then Render";
    }
    else if (s.clips.length) { statusKind = "idle"; statusText = s.clips.length + " clips  -  pick one"; }

    function LibGrid() {
      return a.el("div", { style: { display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(220px, 1fr))", gap: "12px" } },
        s.clips.map(function (c, i) {
          var sel = s.idx === i;
          var tu = thumbUrlOf(c);
          var du = durOf(c);
          return a.el("div", {
            key: String(idOf(c, i)) + ":" + i,
            onClick: function () { pick(i); },
            title: label(c, i),
            style: {
              cursor: "pointer", borderRadius: "10px", overflow: "hidden",
              border: sel ? "2px solid " + C.blurple : "2px solid #242424",
              background: "#141414",
              boxShadow: sel ? "0 0 14px rgba(88,101,242,0.35)" : "none",
              transition: "all 0.15s ease"
            }
          },
            a.el("div", { style: { position: "relative", width: "100%", paddingTop: "56.25%", background: "#0a0a0a" } },
              tu ? a.el("img", { src: tu, draggable: false, style: { position: "absolute", top: 0, left: 0, width: "100%", height: "100%", objectFit: "cover", display: "block" } }) : null,
              du > 0 ? a.el("div", { style: { position: "absolute", bottom: "6px", right: "6px", background: "rgba(0,0,0,0.8)", color: "#fff", fontSize: "11px", fontWeight: "700", padding: "2px 6px", borderRadius: "4px" } }, fmtTime(du)) : null
            ),
            a.el("div", { style: { padding: "8px 10px", fontSize: "12px", color: sel ? "#cdd4ff" : "#e8e8e8", fontWeight: sel ? "700" : "400", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" } }, label(c, i))
          );
        }));
    }

    function backBtn() { return { cursor: "pointer", border: "1px solid #383838", background: "#1c1c1c", color: "#fff", borderRadius: "8px", padding: "7px 14px", fontSize: "13px", fontWeight: "800", whiteSpace: "nowrap", flexShrink: 0 }; }

    function sizeBtn(t) {
      var sel = s.target === t;
      var main = t + " MB";
      var sub = t === 10 ? "Free" : (t === 20 ? "Recommended" : (t === 100 ? "Nitro" : "Large"));
      return a.el("button", {
        key: t, disabled: s.busy,
        onClick: function () { set({ target: t }); },
        style: {
          cursor: s.busy ? "not-allowed" : "pointer", flex: 1, minWidth: "96px",
          border: "1px solid " + (sel ? C.blurple : "#333"),
          background: sel ? C.blurpleSoft : "#141414",
          color: sel ? "#dfe3ff" : "#bbb",
          borderRadius: "10px", padding: "8px 6px", textAlign: "center",
          boxShadow: sel ? "0 0 0 1px " + C.blurple + ", 0 2px 10px rgba(88,101,242,0.25)" : "none",
          opacity: s.busy ? 0.6 : 1
        }
      },
        a.el("div", { style: { fontSize: "14px", fontWeight: "800" } }, main),
        a.el("div", { style: { fontSize: "11px", color: sel ? "#aeb6ff" : "#777" } }, sub)
      );
    }

    function inspSection(title, children) {
      return a.el("div", { style: { display: "flex", flexDirection: "column", gap: "8px", padding: "10px 0 2px" } },
        a.el("div", { style: { fontSize: "10px", fontWeight: "800", letterSpacing: "1px", color: "#777", textTransform: "uppercase" } }, title),
        children
      );
    }

    function discordIcon(px) {
      return a.el("svg", { width: px, height: px, viewBox: "0 0 127.14 96.36", fill: "#ffffff" },
        a.el("path", { d: "M107.7,8.07A105.15,105.15,0,0,0,81.47,0a72.06,72.06,0,0,0-3.36,6.83A97.68,97.68,0,0,0,49,6.83,72.37,72.37,0,0,0,45.64,0,105.89,105.89,0,0,0,19.39,8.09C2.79,32.65-1.71,56.6.54,80.21h0A105.73,105.73,0,0,0,32.71,96.36,77.7,77.7,0,0,0,39.6,85.25a68.42,68.42,0,0,1-10.85-5.18c.91-.66,1.8-1.34,2.66-2a75.57,75.57,0,0,0,64.32,0c.87.71,1.76,1.39,2.66,2a68.68,68.68,0,0,1-10.87,5.19,77,77,0,0,0,6.89,11.1A105.25,105.25,0,0,0,126.6,80.22h0C129.24,52.84,122.09,29.11,107.7,8.07ZM42.45,65.69C36.18,65.69,31,60,31,53s5-12.74,11.43-12.74S54,46,53.86,53,48.81,65.69,42.45,65.69Zm42.24,0C78.41,65.69,73.25,60,73.25,53s5-12.74,11.44-12.74S96.23,46,96.12,53,91.08,65.69,84.69,65.69Z" })
      );
    }


    function metaItem(lab, val) {
      return a.el("div", { style: { display: "flex", alignItems: "baseline", gap: "6px", fontSize: "11px", whiteSpace: "nowrap" } },
        a.el("span", { style: { color: "#666" } }, lab),
        a.el("span", { style: { color: "#ccc", fontWeight: "700" } }, val)
      );
    }

    function statusPill() {
      var dot = statusKind === "busy" ? "#9aa3ff" : (statusKind === "ok" ? C.lime : (statusKind === "err" ? C.danger : (statusKind === "ready" ? C.blurple : "#777")));
      var bd = statusKind === "busy" ? "rgba(88,101,242,0.5)" : (statusKind === "ok" ? "rgba(182,243,74,0.4)" : (statusKind === "err" ? "rgba(255,122,122,0.4)" : "rgba(88,101,242,0.35)"));
      var bg = statusKind === "busy" ? C.blurpleSoft : (statusKind === "ok" ? C.limeSoft : (statusKind === "err" ? "rgba(255,122,122,0.08)" : "rgba(255,255,255,0.03)"));
      return a.el("div", { style: { display: "flex", alignItems: "center", gap: "8px", fontSize: "12px", fontWeight: "700", color: "#ddd", background: bg, border: "1px solid " + bd, borderRadius: "20px", padding: "6px 12px", whiteSpace: "nowrap" } },
        a.el("span", { style: { width: "8px", height: "8px", borderRadius: "50%", background: dot } }),
        statusText
      );
    }

    return a.el("div", { style: { display: "flex", flexDirection: "column", gap: "10px", width: "100%", paddingBottom: "60px", position: "relative" } },
      // ===== Header =====
      a.el("div", { style: { display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: "12px", flexWrap: "wrap" } },
        a.el("div", { style: { display: "flex", alignItems: "center", gap: "12px" } },
          a.el("div", { style: { width: "42px", height: "42px", borderRadius: "12px", background: C.blurple, display: "flex", alignItems: "center", justifyContent: "center", boxShadow: "0 4px 16px rgba(88,101,242,0.45)", flexShrink: 0 } },
            a.el("svg", { width: "24", height: "24", viewBox: "0 0 127.14 96.36", fill: "#ffffff" },
              a.el("path", { d: "M107.7,8.07A105.15,105.15,0,0,0,81.47,0a72.06,72.06,0,0,0-3.36,6.83A97.68,97.68,0,0,0,49,6.83,72.37,72.37,0,0,0,45.64,0,105.89,105.89,0,0,0,19.39,8.09C2.79,32.65-1.71,56.6.54,80.21h0A105.73,105.73,0,0,0,32.71,96.36,77.7,77.7,0,0,0,39.6,85.25a68.42,68.42,0,0,1-10.85-5.18c.91-.66,1.8-1.34,2.66-2a75.57,75.57,0,0,0,64.32,0c.87.71,1.76,1.39,2.66,2a68.68,68.68,0,0,1-10.87,5.19,77,77,0,0,0,6.89,11.1A105.25,105.25,0,0,0,126.6,80.22h0C129.24,52.84,122.09,29.11,107.7,8.07ZM42.45,65.69C36.18,65.69,31,60,31,53s5-12.74,11.43-12.74S54,46,53.86,53,48.81,65.69,42.45,65.69Zm42.24,0C78.41,65.69,73.25,60,73.25,53s5-12.74,11.44-12.74S96.23,46,96.12,53,91.08,65.69,84.69,65.69Z" })
            )
          ),
          a.el("div", { style: { display: "flex", flexDirection: "column", gap: "2px" } },
            a.el("h2", { style: { fontSize: "22px", fontWeight: "800", margin: 0, color: "#fff", lineHeight: "1.1" } }, "Send to Discord"),
            a.el("div", { style: { fontSize: "12px", color: "#888" } }, "Trim a clip to Discord's upload limit, then drag & drop it into any chat.")
          )
        ),
        statusPill()
      ),

      // ===== Status banner (busy / error / success only - no tutorial text) =====
      (s.busy || isErr || s.outPath) ? a.el("div", {
        style: {
          fontSize: "13px", padding: "9px 12px", borderRadius: "8px",
          color: s.busy ? "#cdd4ff" : (isErr ? "#ffb3b3" : (s.outPath ? "#d7ff6b" : "#b0b0b0")),
          background: s.busy ? C.blurpleSoft : (isErr ? "rgba(255,122,122,0.07)" : (s.outPath ? C.limeSoft : "rgba(255,255,255,0.04)")),
          border: "1px solid " + (s.busy ? "rgba(88,101,242,0.4)" : (isErr ? "rgba(255,122,122,0.3)" : (s.outPath ? "rgba(182,243,74,0.3)" : "#282828")))
        }
      }, (s.busy ? "... " : "") + s.msg) : null,

      // ===== Editor overlay: separate full-screen window, grid state untouched =====
      (s.src && s.editor) ? a.el("div", { style: { position: "fixed", top: CHROME_TOP, left: 0, right: 0, bottom: 0, zIndex: 90000, background: "#0b0b0e", padding: "10px 18px 14px", boxSizing: "border-box", display: "flex", flexDirection: "column" } },
        frameArrow(-1),
        frameArrow(1),
        a.el("style", {}, "@keyframes dsClipIn{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:none}}@keyframes dsClipL{from{opacity:0;transform:translateX(28px)}to{opacity:1;transform:none}}@keyframes dsClipR{from{opacity:0;transform:translateX(-28px)}to{opacity:1;transform:none}}"),
        // centered wrapper: margin auto centers vertically, top-aligns + scrolls on overflow
        a.el("div", { style: { width: "100%", maxWidth: "1550px", margin: "auto", maxHeight: "100%", overflowY: "auto", paddingBottom: "2px" } },
        // top bar
        a.el("div", { style: { display: "flex", alignItems: "center", gap: "12px", rowGap: "8px", flexWrap: "wrap", margin: "0 0 8px" } },
          a.el("button", { onClick: function () { set({ editor: false }); }, style: backBtn() }, "< Back to clips"),
          a.el("div", { style: { flex: 1, minWidth: "140px", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap", fontSize: "14px", fontWeight: "800", color: "#fff" } }, clipTitle),
          clipGame ? metaItem("Game", clipGame) : null,
          metaItem("Length", durBase > 0 ? fmtTime(durBase) : "--:--"),
          metaItem("Keep", trimLen > 0 ? (trimLen.toFixed(1) + "s") : "0s"),
          metaItem("Size", s.target + " MB"),
          estBitrate > 0 ? metaItem("Rate", "~" + estBitrate + " kbps") : null,
          a.el("button", { onClick: function () { vidEl = null; set({ src: "", idx: -1, selectedClip: null, cur: 0, playing: false, outPath: "", outSize: 0, showModal: false, editor: false, msg: "Pick a clip below." }); }, style: { background: "none", border: "1px solid #333", color: "#999", cursor: "pointer", fontSize: "12px", borderRadius: "6px", padding: "4px 10px" } }, "x Clear")
        ),

        // editor card
        a.el("div", { key: "card-" + (s.idx >= 0 ? s.idx : "x"), style: { border: "1px solid " + C.border, background: "#141417", borderRadius: "14px", overflow: "hidden", boxShadow: "0 4px 20px rgba(0,0,0,0.4)", animation: !s.slideDir ? "dsClipIn 0.2s ease" : (s.slideDir > 0 ? "dsClipL 0.22s ease" : "dsClipR 0.22s ease") } },

        // stage: preview + inspector rail (stretched so the player fills the rail height)
        a.el("div", { style: { display: "flex", alignItems: "stretch", flexWrap: "wrap" } },
          // preview stage
          a.el("div", { style: { flex: "1", minWidth: "280px", padding: "10px", display: "flex", flexDirection: "column", gap: "8px", background: "#0b0b0e" } },
            isFolder ?
              a.el("div", { style: { flex: 1, minHeight: "120px", background: "#000", border: "1px solid #2a2a2a", borderRadius: "8px", padding: "16px 18px", textAlign: "center", display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: "6px" } },
                a.el("div", { style: { fontSize: "14px", fontWeight: "700", color: "#cdd4ff" } }, "DASH session clip"),
                a.el("div", { style: { fontSize: "12px", color: "#888", maxWidth: "360px" } }, "Medal multi-chunk recording  -  no video preview. Trim on the timeline below; Render remuxes it directly."),
                s.dur > 0 ? a.el("div", { style: { fontSize: "13px", color: "#ddd", marginTop: "4px" } }, "Duration: " + s.dur.toFixed(1) + "s") : null
              ) :
              a.el("div", { style: { flex: "1 1 auto", minHeight: "120px", maxHeight: "44vh", display: "flex", background: "#000", borderRadius: "8px", border: "1px solid #2c2c2c", overflow: "hidden" } },
                a.el("video", {
                  ref: onVideoRef, key: s.src, src: previewUrl(),
                  onLoadedMetadata: onMeta, onCanPlay: onMeta, onTimeUpdate: onTime,
                  onPlay: function () { onPlayState(true); }, onPause: function () { onPlayState(false); },
                  onError: onSrcError, onClick: togglePlay,
                  style: { width: "100%", height: "100%", objectFit: "contain", background: "#000", cursor: "pointer", display: "block" }
                })
              ),
          ),

          // inspector rail
          a.el("div", { style: { width: "248px", flexShrink: 0, flexGrow: 0, padding: "2px 14px 14px", background: "#141417", borderLeft: "1px solid " + C.borderSoft, overflowY: "auto", maxHeight: "56vh" } },
            inspSection("Trim",
              a.el("div", { style: { display: "flex", flexDirection: "column", gap: "8px" } },
                a.el("div", { style: { fontSize: "13px", color: "#cdd4ff", fontWeight: "800" } }, trimLen > 0 ? (trimLen.toFixed(1) + "s  (" + fmtTime(s.start) + " - " + fmtTime(s.end) + ")") : "0s")
              )
            ),
            inspSection("Export size",
              a.el("div", { style: { display: "flex", flexDirection: "column", gap: "8px" } },
                a.el("div", { style: { display: "flex", gap: "6px", flexWrap: "wrap" } }, TARGETS.map(sizeBtn)),
                lowQ ? a.el("div", { style: { fontSize: "11px", color: C.warn, background: "rgba(255,207,122,0.07)", border: "1px solid rgba(255,207,122,0.3)", borderRadius: "8px", padding: "6px 8px" } }, "Long clip + small size = blurry. Shorten the trim or raise the target.") : null,
                a.el("div", { style: { fontSize: "11px", color: "#666" } }, "Quality: " + (S.resolution || "720p") + " (Plugins settings)")
              )
            ),
            inspSection("Clip",
              a.el("div", { style: { display: "flex", flexDirection: "column", gap: "3px", fontSize: "12px" } },
                a.el("div", { style: { color: "#eee", fontWeight: "700", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" } }, clipTitle),
                a.el("div", { style: { color: "#888" } }, (clipGame ? clipGame + "  -  " : "") + (durBase > 0 ? (durBase.toFixed(1) + "s") : "duration Unknown")),
                isFolder ? a.el("div", { style: { color: "#888" } }, "DASH package (no preview)") : null
              )
            ),
            a.el("button", {
              disabled: s.busy,
              onClick: function () { doRender(s.target); },
              style: {
                cursor: s.busy ? "wait" : "pointer", marginTop: "12px",
                border: "1px solid " + C.blurple, background: s.busy ? "#232842" : C.blurple,
                color: "#fff", borderRadius: "10px", padding: "12px 16px",
                fontSize: "14px", fontWeight: "800",
                boxShadow: s.busy ? "none" : "0 4px 18px rgba(88,101,242,0.4)",
                opacity: s.busy ? 0.7 : 1, transition: "all 0.15s ease", width: "100%",
                display: "flex", alignItems: "center", justifyContent: "center", gap: "8px"
              }
            }, discordIcon(15), s.busy ? "... Rendering" : ("Render " + s.target + " MB"))
          )
        ),

        // timeline dock
        a.el("div", { style: { borderTop: "1px solid " + C.borderSoft, background: "#101013", padding: "8px 14px 10px", display: "flex", flexDirection: "column", gap: "6px" } },
          a.el("div", { style: { display: "flex", flexDirection: "column", alignItems: "center", gap: "6px" } },
            a.el("span", { style: { fontSize: "12px", color: "#eee", fontWeight: "800", whiteSpace: "nowrap" } }, fmtTime(s.cur || 0) + " / " + (durBase > 0 ? fmtTime(durBase) : "--:--")),
            a.el("div", { style: { display: "flex", gap: "6px", justifyContent: "center" } },
              a.el("button", { onClick: function () { setEdge("start"); }, title: "Move trim start to the playhead", style: ghostBtnSm() }, "Set start"),
              a.el("button", { onClick: function () { setEdge("end"); }, title: "Move trim end to the playhead", style: ghostBtnSm() }, "Set end")
            )
          ),
          // ruler
          a.el("div", { onClick: rulerSeek, title: "Click to move the playhead", style: { position: "relative", height: "18px", marginTop: "2px", cursor: "pointer", userSelect: "none" } }, rulerTicks()),
          // video track: black with seconds ruler, dimmed cutaways, draggable handles, playhead
          a.el("div", {
            id: "ds-tl-track", onClick: tlSeek, title: "Click to move the playhead",
            style: {
              position: "relative", height: "56px", borderRadius: "8px", overflow: "hidden",
              border: "1px solid #333", cursor: "pointer", backgroundColor: "#000", userSelect: "none"
            }
          },
            a.el("div", { style: { position: "absolute", top: 0, bottom: 0, left: 0, width: p0 + "%", background: "rgba(255,255,255,0.07)" } }),
            a.el("div", { style: { position: "absolute", top: 0, bottom: 0, left: p1 + "%", right: 0, background: "rgba(255,255,255,0.07)" } }),
            a.el("div", { style: { position: "absolute", top: 0, bottom: 0, left: p0 + "%", width: Math.max(0, p1 - p0) + "%", background: "rgba(88,101,242,0.30)", border: "2px solid " + C.blurple, borderRadius: "3px", boxSizing: "border-box", pointerEvents: "none" } }),
            a.el("div", { onMouseDown: function (e) { edgeDrag("start", e); }, title: "Drag to set trim start", style: { position: "absolute", top: 0, bottom: 0, left: "calc(" + p0 + "% - 7px)", width: "14px", cursor: "ew-resize", background: "rgba(255,255,255,0.95)", border: "1px solid rgba(0,0,0,0.4)", borderRadius: "4px" } }),
            a.el("div", { onMouseDown: function (e) { edgeDrag("end", e); }, title: "Drag to set trim end", style: { position: "absolute", top: 0, bottom: 0, left: "calc(" + p1 + "% - 7px)", width: "14px", cursor: "ew-resize", background: "rgba(255,255,255,0.95)", border: "1px solid rgba(0,0,0,0.4)", borderRadius: "4px" } }),
            a.el("div", { style: { position: "absolute", top: 0, bottom: 0, left: pc + "%", width: "3px", background: "#fff", boxShadow: "0 0 8px rgba(255,255,255,0.9)", pointerEvents: "none" } },
              a.el("div", { style: { position: "absolute", top: "-1px", left: "-5px", width: "12px", height: "12px", borderRadius: "50%", background: "#fff" } })
            )
          ),
          a.el("div", { style: { fontSize: "11px", color: "#5f5f5f" } }, "Click the ruler or track to seek  -  drag the wide handles to trim.")
        ),

      // ===== Share row (only after a render, inside the overlay) =====
      s.src && s.outPath ? a.el("div", { style: { borderTop: "1px solid rgba(88,101,242,0.45)", background: "linear-gradient(180deg, rgba(88,101,242,0.10) 0%, rgba(88,101,242,0.03) 100%)", padding: "14px 18px", display: "flex", flexDirection: "column", gap: "10px" } },
        a.el("div", { style: { display: "flex", alignItems: "center", gap: "8px", flexWrap: "wrap" } },
          a.el("span", { style: { fontSize: "14px", fontWeight: "800", color: "#fff" } }, "Your file is ready"),
          a.el("span", { style: { fontSize: "12px", fontWeight: "700", background: C.blurple, color: "#fff", padding: "2px 8px", borderRadius: "6px" } }, fmtMB(s.outSize)),
          a.el("span", { style: { fontSize: "12px", color: "#aeb6ff" } }, fmtTime(trimLen) + "  -  " + s.target + " MB target")
        ),
        a.el("div", { style: { display: "flex", gap: "8px", flexWrap: "wrap" } },
          a.el("button", { onClick: function () { set({ showModal: true }); }, style: primaryBtn() }, "Open Discord share window"),
          a.el("button", { onClick: openFolder, style: ghostBtn() }, "Open folder"),
          a.el("button", { onClick: copyPath, style: ghostBtn() }, "Copy path")
        )
      ) : null,
        ),
        ),
      ) : null,

      // ===== Library (full-screen grid) =====
      a.el("div", { style: { display: "flex", flexDirection: "column", gap: "10px", padding: "4px 2px 20px" } },
        a.el("div", { style: { display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: "10px" } },
          a.el("div", { style: { display: "flex", alignItems: "center", gap: "8px" } },
            a.el("h3", { style: { fontSize: "15px", fontWeight: "800", margin: 0, color: "#fff" } }, "Clips"),
            a.el("span", { style: { fontSize: "12px", color: "#999", background: "#222", padding: "2px 8px", borderRadius: "10px" } }, s.clips.length + " loaded"),
            (s.clips.length === 0 && !s.search) ? a.el("span", { style: { fontSize: "12px", color: "#666" } }, "Loading clips...") : null
          ),
          a.el("input", {
            type: "text",
            placeholder: "Search clips (game, title)...",
            value: s.search,
            onChange: onSearchChange,
            style: { width: "240px", background: "#0e0e0e", border: "1px solid #383838", color: "#eee", borderRadius: "8px", padding: "7px 10px", fontSize: "13px" }
          })
        ),

        s.clips.length === 0 ? a.el("div", { style: { fontSize: "13px", color: "#888", padding: "24px 0", textAlign: "center" } }, s.search ? ("No clips match '" + s.search + "'.") : "No clips found in library.") :
          LibGrid(),

        s.hasMore ? a.el("button", {
          disabled: s.loadingMore,
          onClick: loadMore,
          style: {
            cursor: s.loadingMore ? "wait" : "pointer",
            border: "1px solid #333", background: "#181818", color: "#ccc",
            borderRadius: "8px", padding: "10px", fontSize: "13px", fontWeight: "700",
            marginTop: "8px", transition: "all 0.15s ease"
          }
        }, s.loadingMore ? "Loading more clips..." : "Load more clips (+100)") : null
      ),

      // ===== Share popup modal (kept, restyled to match) =====
      s.showModal && s.outPath ? a.el("div", {
        style: {
          position: "fixed", top: CHROME_TOP, left: 0, right: 0, bottom: 0, background: "rgba(5, 7, 12, 0.85)", backdropFilter: "blur(8px)",
          display: "flex", alignItems: "center", justifyContent: "center",
          zIndex: 99999, padding: "20px", boxSizing: "border-box"
        },
        onClick: function (e) {
          if (e.target === e.currentTarget) set({ showModal: false });
        }
      },
        a.el("div", {
          style: {
            width: "100%", maxWidth: "480px", background: "#161b24",
            border: "1px solid #283142", borderRadius: "16px", padding: "24px",
            boxShadow: "0 20px 50px rgba(0,0,0,0.8), 0 0 0 1px rgba(255,255,255,0.05)",
            display: "flex", flexDirection: "column", alignItems: "center", boxSizing: "border-box"
          }
        },
          a.el("div", { style: { width: "100%", display: "flex", justifyContent: "space-between", alignItems: "center", paddingBottom: "14px", borderBottom: "1px solid #232a38" } },
            a.el("div", { style: { width: "24px" } }),
            a.el("span", { style: { fontSize: "14px", fontWeight: "800", letterSpacing: "1.2px", color: "#d0d7e3", textTransform: "uppercase" } }, "Share on Discord"),
            a.el("button", {
              onClick: function () { set({ showModal: false }); },
              style: { background: "none", border: "none", color: "#7a8494", cursor: "pointer", fontSize: "20px", lineHeight: "1", padding: "0" }
            }, "x")
          ),

          a.el("div", { style: { fontSize: "12px", color: "#8d98aa", marginTop: "12px" } }, fmtTime(trimLen) + " clip  -  rendered at " + fmtMB(s.outSize) + " (" + s.target + " MB target)"),

          a.el("div", { style: { width: "100%", display: "flex", flexDirection: "column", alignItems: "center", gap: "8px", margin: "12px 0 16px" } },
            a.el("span", { style: { fontSize: "12px", color: "#8d98aa", fontWeight: "500" } }, "Render a different size instead"),
            a.el("div", { style: { display: "flex", background: "#0e1117", padding: "3px", borderRadius: "8px", border: "1px solid #252c3b", gap: "3px" } },
              TARGETS.map(function (t) {
                var sel = s.target === t;
                return a.el("button", {
                  key: t,
                  disabled: s.busy,
                  onClick: function () {
                    if (s.target !== t) doRender(t);
                  },
                  style: {
                    cursor: s.busy ? "wait" : "pointer", border: "none",
                    background: sel ? C.blurple : "transparent",
                    color: sel ? "#ffffff" : "#7e8b9f",
                    borderRadius: "6px", padding: "6px 14px", fontSize: "12px", fontWeight: "700",
                    transition: "all 0.15s ease",
                    boxShadow: sel ? "0 2px 8px rgba(88,101,242,0.4)" : "none"
                  }
                }, t === 10 ? "10 MB" : (t === 100 ? "100 MB" : t + " MB"));
              })
            )
          ),

          a.el("div", { style: { display: "flex", alignItems: "center", justifyContent: "center", gap: "14px", margin: "4px 0 10px" } },
            a.el("div", { style: { width: "36px", height: "36px", borderRadius: "50%", background: "#212836", border: "1px solid #303b4e", display: "flex", alignItems: "center", justifyContent: "center" } },
              a.el("svg", { width: "18", height: "18", viewBox: "0 0 24 24", fill: "none", stroke: "#8b95ff", strokeWidth: "2.5", strokeLinecap: "round", strokeLinejoin: "round" },
                a.el("polygon", { points: "5 3 19 12 5 21 5 3", fill: "#8b95ff" })
              )
            ),
            a.el("div", { style: { display: "flex", alignItems: "center", gap: "5px" } },
              a.el("span", { style: { color: C.blurple, fontSize: "14px", letterSpacing: "2px" } }, "..."),
              a.el("div", { style: { width: "20px", height: "26px", borderRadius: "4px", background: C.blurple, display: "flex", alignItems: "center", justifyContent: "center", boxShadow: "0 0 10px rgba(88,101,242,0.6)" } },
                a.el("span", { style: { color: "#fff", fontSize: "10px", fontWeight: "900" } }, ">")
              ),
              a.el("span", { style: { color: C.blurple, fontSize: "14px", letterSpacing: "2px" } }, "...")
            ),
            a.el("div", { style: { width: "36px", height: "36px", borderRadius: "50%", background: C.blurple, display: "flex", alignItems: "center", justifyContent: "center", boxShadow: "0 0 14px rgba(88,101,242,0.5)" } },
              a.el("svg", { width: "22", height: "22", viewBox: "0 0 127.14 96.36", fill: "#ffffff" },
                a.el("path", { d: "M107.7,8.07A105.15,105.15,0,0,0,81.47,0a72.06,72.06,0,0,0-3.36,6.83A97.68,97.68,0,0,0,49,6.83,72.37,72.37,0,0,0,45.64,0,105.89,105.89,0,0,0,19.39,8.09C2.79,32.65-1.71,56.6.54,80.21h0A105.73,105.73,0,0,0,32.71,96.36,77.7,77.7,0,0,0,39.6,85.25a68.42,68.42,0,0,1-10.85-5.18c.91-.66,1.8-1.34,2.66-2a75.57,75.57,0,0,0,64.32,0c.87.71,1.76,1.39,2.66,2a68.68,68.68,0,0,1-10.87,5.19,77,77,0,0,0,6.89,11.1A105.25,105.25,0,0,0,126.6,80.22h0C129.24,52.84,122.09,29.11,107.7,8.07ZM42.45,65.69C36.18,65.69,31,60,31,53s5-12.74,11.43-12.74S54,46,53.86,53,48.81,65.69,42.45,65.69Zm42.24,0C78.41,65.69,73.25,60,73.25,53s5-12.74,11.44-12.74S96.23,46,96.12,53,91.08,65.69,84.69,65.69Z" })
              )
            )
          ),

          a.el("div", { style: { textAlign: "center", margin: "4px 0 14px" } },
            a.el("div", { style: { fontSize: "18px", fontWeight: "800", color: "#ffffff", marginBottom: "3px" } }, "Drag & Drop"),
            a.el("div", { style: { fontSize: "13px", color: "#8d98aa" } }, "Drag this clip into any Discord chat to upload it")
          ),

          a.el("div", {
            draggable: true,
            onDragStart: onDragStart,
            style: {
              cursor: "grab", position: "relative", width: "100%", maxWidth: "400px", height: "210px",
              borderRadius: "12px", overflow: "hidden", border: "2px dashed " + C.blurple, background: "#0d1017",
              boxShadow: "0 8px 30px rgba(0,0,0,0.6)",
              display: "flex", alignItems: "center", justifyContent: "center",
              transition: "transform 0.15s ease"
            }
          },
            activeThumb ? a.el("img", {
              src: activeThumb,
              draggable: false,
              style: { width: "100%", height: "100%", objectFit: "cover", display: "block" }
            }) : a.el("div", { style: { width: "100%", height: "100%", background: "#0a0c10", display: "flex", alignItems: "center", justifyContent: "center", color: "#555" } }, "Clip Ready"),

            a.el("div", { style: { position: "absolute", inset: 0, background: "linear-gradient(to top, rgba(0,0,0,0.8) 0%, transparent 60%)", pointerEvents: "none" } }),

            a.el("div", {
              style: {
                position: "absolute", top: "10px", right: "10px",
                background: "rgba(0,0,0,0.8)", backdropFilter: "blur(4px)", color: "#fff",
                fontSize: "12px", fontWeight: "700", padding: "3px 8px", borderRadius: "4px",
                border: "1px solid rgba(255,255,255,0.15)"
              }
            }, fmtTime(trimLen)),

            a.el("div", {
              style: {
                position: "absolute", bottom: "10px", right: "10px",
                background: C.blurple, color: "#ffffff",
                fontSize: "12px", fontWeight: "700", padding: "3px 8px", borderRadius: "4px",
                boxShadow: "0 2px 8px rgba(0,0,0,0.4)"
              }
            }, fmtMB(s.outSize)),

            a.el("div", {
              style: {
                position: "absolute", bottom: "10px", left: "12px",
                display: "flex", alignItems: "center", gap: "6px", color: "#ffffff",
                fontSize: "12px", fontWeight: "600", textShadow: "0 1px 4px rgba(0,0,0,0.9)"
              }
            }, "Click & drag box into Discord")
          ),

          a.el("div", { style: { width: "100%", display: "flex", gap: "10px", justifyContent: "center", marginTop: "18px" } },
            a.el("button", { onClick: openFolder, style: btnModal() }, "Open Folder"),
            a.el("button", { onClick: copyPath, style: btnModal() }, "Copy Path"),
            a.el("button", { onClick: function () { set({ showModal: false }); }, style: btnModalPri() }, "Done")
          )
        )
      ) : null
    );
  }

  function primaryBtn() { return { cursor: "pointer", border: "1px solid " + C.blurple, background: C.blurple, color: "#fff", borderRadius: "8px", padding: "9px 16px", fontSize: "13px", fontWeight: "800", boxShadow: "0 2px 10px rgba(88,101,242,0.4)" }; }
  function ghostBtn() { return { cursor: "pointer", border: "1px solid #383838", background: "#1c1c1c", color: "#ddd", borderRadius: "8px", padding: "9px 16px", fontSize: "13px", fontWeight: "600" }; }
  function ghostBtnSm() { return { cursor: "pointer", border: "1px solid #383838", background: "#1c1c1c", color: "#ddd", borderRadius: "7px", padding: "5px 14px", fontSize: "11px", fontWeight: "700", minWidth: "96px", whiteSpace: "nowrap" }; }
  function btnModal() { return { cursor: "pointer", border: "1px solid #2c3545", background: "#1b212c", color: "#c8d0dc", borderRadius: "8px", padding: "8px 16px", fontSize: "13px", fontWeight: "600", transition: "all 0.15s ease" }; }
  function btnModalPri() { return { cursor: "pointer", border: "1px solid " + C.blurple, background: C.blurple, color: "#ffffff", borderRadius: "8px", padding: "8px 20px", fontSize: "13px", fontWeight: "700", boxShadow: "0 2px 10px rgba(88,101,242,0.4)", transition: "all 0.15s ease" }; }
  function round1(n) { return Math.round(Number(n) * 10) / 10; }
  function fmtMB(n) {
    n = Number(n) || 0;
    if (n <= 0) return "0 MB";
    return (n / 1024 / 1024).toFixed(1) + " MB";
  }
  function fmtTime(sec) {
    var s = Math.max(0, Math.round(Number(sec) || 0));
    var m = Math.floor(s / 60);
    var rem = s % 60;
    return (m < 10 ? "0" + m : m) + ":" + (rem < 10 ? "0" + rem : rem);
  }

  function meta(c) {
    try {
      if (!c) return null;
      var m = c.metadata;
      if (typeof m === "string") { try { m = JSON.parse(m); } catch (e) { return null; } }
      return m || null;
    } catch (e) { return null; }
  }

  function durOf(c) {
    if (!c) return 0;
    try {
      if (typeof c.getDuration === "function") { var gd = c.getDuration(); if (gd > 0) return Number(gd); }
      var m = meta(c);
      if (m) {
        if (m.clipDuration > 0) return Number(m.clipDuration);
        if (m.duration > 0) return Number(m.duration);
        if (m.durationMs > 0) return Number(m.durationMs) / 1000;
      }
      if (c.duration > 0) return Number(c.duration);
    } catch (e) { }
    return 0;
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
    var keys = ["defaultTarget", "resolution", "showInSidebar"];
    for (var i = 0; i < keys.length; i++) {
      var v = await api.store.get(keys[i], null);
      if (v !== null && v !== undefined && v !== "") S[keys[i]] = v;
    }
    if (S.showInSidebar === "false" || S.showInSidebar === false) S.showInSidebar = false;
    else S.showInSidebar = true;
    try { localStorage.setItem("medal-plugins:discord-sidebar", S.showInSidebar ? "true" : "false"); } catch(e) {}
  }
  load();
})();

'@

function Invoke-RescanPlugins {
  Step 'Rescanning plugins'
  if (-not (Test-Path -LiteralPath $PluginsDir)) { New-Item -ItemType Directory -Path $PluginsDir -Force | Out-Null }
  $retired = Join-Path $PluginsDir 'youtube-backup'
  if (Test-Path -LiteralPath $retired) { Remove-Item -LiteralPath $retired -Recurse -Force -ErrorAction SilentlyContinue; Ok 'Retired plugin removed: youtube-backup' }
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
  $utf8NoBom = New-Object System.Text.UTF8Encoding $false
  [IO.File]::WriteAllText((Join-Path $PluginsDir 'plugins.json'), (@{ plugins = $list } | ConvertTo-Json -Depth 5), $utf8NoBom)
  Ok "$($list.Count) plugin(s): $((@($list | ForEach-Object { $_.name })) -join ', ')"
}

function Write-BundledSample($spec) {
  $sample = Join-Path $PluginsDir $spec.name
  New-Item -ItemType Directory -Path $sample -Force | Out-Null
  $utf8NoBom = New-Object System.Text.UTF8Encoding $false
  $mfJson = (@{ name = $spec.name; version = $spec.version; author = 'bundled sample'; bundledMod = $ModVersion; description = $spec.description; entry = 'plugin.js' } | ConvertTo-Json)
  [IO.File]::WriteAllText((Join-Path $sample 'manifest.json'), $mfJson, $utf8NoBom)
  [IO.File]::WriteAllText((Join-Path $sample 'plugin.js'), $spec.content, $utf8NoBom)
}

function Write-PluginScaffold {
  if (-not (Test-Path -LiteralPath $PluginsDir)) { New-Item -ItemType Directory -Path $PluginsDir -Force | Out-Null }
  $specs = @(
    @{ name = 'discord-send'; version = '2.14'; description = 'Trim a clip, render it to a Discord-size target, then drag it straight into Discord.'; content = $SampleDiscord }
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
function dec(b){if(typeof b=="string")return b.replace(/^\ufeff/,"");try{var u8=b instanceof Uint8Array?b:ArrayBuffer.isView(b)?new Uint8Array(b.buffer,b.byteOffset,b.byteLength):new Uint8Array(b);return new TextDecoder().decode(u8).replace(/^\ufeff/,"")}catch(e){return ""}}
function kvGet(k){return MedalIPC.kvGet(k).catch(function(){return null})}
function kvPut(k,v){return MedalIPC.kvPut(k,v).catch(function(){})}
// ---- shared clip helpers: absolute file path, thumbnail URLs, library-like grid ----
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
  var u="file:///"+encodeURI(String(p).replace(/\\/g,"/")).replace(/^\/+/,"").replace(/#/g,"%23").replace(/\?/g,"%3F");
  var pr=Promise.resolve(u);
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
    return J.jsxs("div",{key:pro.keyOf?pro.keyOf(c,i):i,onClick:function(){pro.onPick&&pro.onPick(c,i)},title:pro.label?pro.label(c,i):"",style:{cursor:"pointer",borderRadius:"8px",overflow:"hidden",border:sel?"2px solid #b6f34a":"2px solid #282828",background:"#141414",boxShadow:sel?"0 0 10px rgba(182,243,74,0.35)":"none",transition:"all 0.15s ease"},children:[
      J.jsx(Thumb,{clip:c}),
      J.jsx("div",{style:{padding:"6px 8px",fontSize:"12px",color:sel?"#b6f34a":"#e8e8e8",fontWeight:sel?"600":"400",whiteSpace:"nowrap",overflow:"hidden",textOverflow:"ellipsis"},children:pro.label?pro.label(c,i):("clip "+(i+1))})
    ]});
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
    registerPage:function(pg){var r={plugin:id,pageId:pg.id||id,title:pg.title||pg.id||id,render:pg.render};entry.pages.push(r);reg.pages.push(r)},
    registerClipAction:function(a){var rec={plugin:id,id:a.id,label:a.label||a.id,run:a.run};entry.clipActions.push(rec);reg.clipActions.push(rec)},
    registerSettings:function(schema){entry.schema=schema},
    toast:function(m){try{if(MedalIPC.toast)MedalIPC.toast(m);else console.log("[plugin:"+id+"]",m)}catch(e){console.log("[plugin:"+id+"]",m)}}
  };
}
var started=false;
export async function init(force){
  if(started&&!force)return;started=true;
  var reg={plugins:[],pages:[],errors:[],clipActions:[]};
  window.__medalPlugins=reg;
  try{
    var manRaw=dec(await MedalIPC.fs.readFile(DIR+"\\plugins.json"));
    // Strip BOM + leading whitespace; plugins.json uses UTF-8 with BOM (239 187 191).
    var cleanMan=manRaw.replace(/^[\ufeff\s\r\n]+/,"");
    var man;
    try{man=JSON.parse(cleanMan)}catch(err){reg.errors.push("MANIFEST-DECODE: "+String((err&&err.message)||err)+" (possible BOM or whitespace  -  stripped, retrying)");man={plugins:[]}}
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
  $utf8NoBom = New-Object System.Text.UTF8Encoding $false
  [IO.File]::WriteAllText((Join-Path $Work 'app\chunks\renderer-PluginLoader.js'), $PlugLoader, $utf8NoBom)
  $PlugHome = @'
import{o as a}from"./renderer-chunk.js";import{t as d}from"./renderer-react.production.js";import{t as f}from"./renderer-react-jsx-runtime.production.js";import{n as nav}from"./renderer-router.js";
var t=a(d()),r=f();
const DIR=__PLUGINS_DIR__;
const S={page:{padding:"24px",maxWidth:"1600px",width:"100%",height:"100%",overflowY:"auto",boxSizing:"border-box",color:"#e8e8e8",margin:"0 auto"},h:{fontSize:"22px",fontWeight:"700",margin:"0 0 4px"},sub:{color:"#9a9a9a",fontSize:"13px",margin:"0 0 16px"},card:{border:"1px solid #2c2c2c",borderRadius:"10px",padding:"14px 16px",marginBottom:"12px",background:"#141414"},row:{display:"flex",alignItems:"center",gap:"10px"},name:{fontSize:"15px",fontWeight:"600"},meta:{color:"#9a9a9a",fontSize:"12px"},desc:{fontSize:"13px",color:"#c9c9c9",marginTop:"6px"},btn:{cursor:"pointer",border:"1px solid #3a3a3a",background:"#222",color:"#eee",borderRadius:"8px",padding:"6px 12px",fontSize:"13px"},btnPri:{cursor:"pointer",border:"1px solid #b6f34a",background:"#1c2607",color:"#d7ff6b",borderRadius:"8px",padding:"6px 12px",fontSize:"13px"},err:{color:"#ff7a7a",fontSize:"12px",marginTop:"6px"},field:{marginTop:"8px"},lab:{fontSize:"12px",color:"#9a9a9a",display:"block",marginBottom:"4px"},inp:{width:"100%",background:"#0d0d0d",border:"1px solid #3a3a3a",color:"#eee",borderRadius:"6px",padding:"6px 8px",fontSize:"13px",boxSizing:"border-box"}};
function dec(b){if(typeof b=="string")return b.replace(/^\ufeff/,"");try{var u8=b instanceof Uint8Array?b:ArrayBuffer.isView(b)?new Uint8Array(b.buffer,b.byteOffset,b.byteLength):new Uint8Array(b);return new TextDecoder().decode(u8).replace(/^\ufeff/,"")}catch(e){return ""}}
function reg(){return window.__medalPlugins||{plugins:[],errors:[]}}
function liveOf(name){try{var ps=(window.__medalPlugins&&window.__medalPlugins.plugins)||[];for(var i=0;i<ps.length;i++){if(ps[i].name===name)return ps[i];}}catch(e){}return null}
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
  var txt=hasReg?("loader: registry live ("+nplug+" plugins)"+(lst&&lst.stage?(", stage "+lst.stage):"")):("loader: "+(lst?("stage="+lst.stage+(lst.error?("  -  "+lst.error):"")):"never started"));
  var bad=!hasReg||(lst&&lst.stage==="failed");
  return(0,r.jsxs)("div",{style:{border:"1px solid "+(bad?"#7a2e2e":"#2c2c2c"),background:bad?"#1c0f0f":"#101010",borderRadius:"8px",padding:"8px 12px",fontSize:"12px",color:bad?"#ff9a9a":"#9a9a9a",marginBottom:"12px",display:"flex",gap:"10px",alignItems:"center"},children:[
    (0,r.jsx)("span",{style:{flex:1},children:txt+(pro.msg?("  -  "+pro.msg):"")}),
    (0,r.jsx)("button",{onClick:pro.onRetry,style:{cursor:"pointer",border:"1px solid #3a3a3a",background:"#222",color:"#eee",borderRadius:"6px",padding:"4px 10px",fontSize:"12px"},children:"Retry loader"})
  ]});
}
function PluginCard(pro){var p=pro.p,en=pro.en,sch=pro.sch,onT=pro.onT;
  var vals=pro.vals,setV=pro.setV,onSave=pro.onSave,open=pro.open,onOpen=pro.onOpen;
  var lv=liveOf(p.name);
  var isLoaded=!!(lv&&lv.loaded);
  var err=(lv&&lv.error)||p.error||null;
  var hasPage=allPages().some(function(pg){return pg.plugin===p.name})||(lv&&lv.pages&&lv.pages.length>0)||(en&&(p.name==="discord-send"));
  var statusText=isLoaded?"   -   loaded":(err?("   -   error: "+err):(en?"   -   load pending":"   -   disabled"));
  return(0,r.jsxs)("div",{style:S.card,children:[
    (0,r.jsxs)("div",{style:S.row,children:[
      (0,r.jsxs)("div",{style:{flex:1},children:[
        (0,r.jsx)("div",{style:S.name,children:p.name+(p.version?"   -   v"+p.version:"")}),
        (0,r.jsx)("div",{style:S.meta,children:[p.author||"local plugin",statusText].join("")})
      ]}),
      hasPage?(0,r.jsx)("button",{style:S.btn,onClick:function(){nav("/plugins/"+p.name)},children:"Open"}):null,
      sch?(0,r.jsx)("button",{style:S.btn,onClick:onOpen,children:open?"Hide settings":"Settings"}):null,
      (0,r.jsx)("button",{style:en?S.btn:S.btnPri,onClick:onT,children:en?"Disable":"Enable"})
    ]}),
    p.description?(0,r.jsx)("div",{style:S.desc,children:p.description}):null,
    err?(0,r.jsx)("div",{style:S.err,children:"Error: "+err}):null,
    (sch&&open)?(0,r.jsxs)("div",{children:[sch.map(function(fl){return(0,r.jsx)(Field,{f:fl,v:vals[fl.key]!=null?vals[fl.key]:fl.default,on:function(v){var o={};o[fl.key]=v;setV(Object.assign({},vals,o))}},fl.key)}),(0,r.jsx)("div",{style:{marginTop:"10px"},children:(0,r.jsx)("button",{style:S.btnPri,onClick:onSave,children:"Save settings"})})]}):null
  ]});
}
export default function PluginsHome(){
  var st=t.useState({loading:true,plugins:[],enabled:{},schemas:{},tick:0}),s=st[0],setS=st[1];
  var ui=t.useState({open:null,vals:{}}),u=ui[0],setU=ui[1];
  function refresh() {
    return (async function(){
      var raw=dec(await MedalIPC.fs.readFile(DIR+"\\plugins.json"));
      var man=JSON.parse(raw.replace(/^\ufeff\s\r\n]+/,""));
      var en=await MedalIPC.kvGet("medal-plugins:enabled").catch(function(){return null})||{};
      setS(function(prev){return Object.assign({},prev,{loading:false,plugins:man.plugins||[],enabled:en,schemas:schemas()})});
      for(var k=0;k<20;k++){
        await new Promise(function(x){setTimeout(x,400)});
        var sc=schemas();
        if(Object.keys(sc).length){
          setS(function(p){return Object.assign({},p,{schemas:sc})});
          break;
        }
      }
    })();
  }
  t.useEffect(function(){refresh().catch(function(e){setS(function(p){return Object.assign({},p,{loading:false,plugins:[],enabled:{},schemas:{},error:String((e&&e.message)||e)})})})},[]);
  function retryLoad() {
    setS(function(p){return Object.assign({},p,{loading:true})});
    var p;
    try { p = import("./renderer-PluginLoader.js"); }
    catch(e) { setS(function(p){return Object.assign({},p,{loading:false,msg:"Retry import threw: "+String((e&&e.message)||e)})}); return; }
    Promise.resolve(p).then(function(m){return m.init&&m.init(true)}).then(function(){
      refresh().catch(function(e){setS(function(p){return Object.assign({},p,{loading:false,msg:"Retry init failed: "+String((e&&e.message)||e)})})});
    },function(e){
      setS(function(p){return Object.assign({},p,{loading:false,msg:"Retry import failed: "+String((e&&e.message)||e)})});
    });
  }
  async function toggle(name){
    var nen=Object.assign({},s.enabled);
    var cur=nen[name]!==undefined?nen[name]:true;
    nen[name]=!cur;
    await MedalIPC.kvPut("medal-plugins:enabled",nen).catch(function(){});
    setS(function(p){return Object.assign({},p,{enabled:nen})});
    retryLoad();
  }
  async function openSettings(p){
    var key=p.name;
    if(u.open===key){setU({open:null,vals:{}});return}
    var vals={};
    for(var i=0;i<(p.schema||[]).length;i++){
      var fl=p.schema[i];
      var v=await MedalIPC.kvGet("medal-plugins:"+key+":"+fl.key).catch(function(){return null});
      vals[fl.key]=v==null?fl.default:v;
    }
    setU({open:key,vals:vals});
  }
  async function saveSettings(p){
    for(var i=0;i<(p.schema||[]).length;i++){
      var fl=p.schema[i];
      var val=u.vals[fl.key];
      await MedalIPC.kvPut("medal-plugins:"+p.name+":"+fl.key,val).catch(function(){});
      if(p.name==="discord-send"&&fl.key==="showInSidebar"){
        try{localStorage.setItem("medal-plugins:discord-sidebar",val?"true":"false")}catch(e){}
      }
    }
    setU({open:null,vals:{}});
    retryLoad();
  }
  function withSchema(p){var sc=s.schemas[p.name];return Object.assign({},p,{schema:sc||null})}
  if(s.loading)return(0,r.jsx)("div",{style:S.page,children:"Loading plugins..."});
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
  $utf8NoBom = New-Object System.Text.UTF8Encoding $false
  [IO.File]::WriteAllText((Join-Path $Work 'app\chunks\renderer-PluginsHome.js'), $PlugHome, $utf8NoBom)
  $PlugPage = @'
import{o as a}from"./renderer-chunk.js";import{t as d}from"./renderer-react.production.js";import{t as f}from"./renderer-react-jsx-runtime.production.js";import{t as loc}from"./renderer-router.js";
var t=a(d()),r=f();
const S={page:{padding:"24px",maxWidth:"1600px",width:"100%",height:"100%",overflowY:"auto",boxSizing:"border-box",color:"#e8e8e8",margin:"0 auto"},err:{color:"#ff7a7a",fontSize:"13px"}};
function PluginView(pro){
  try{return(0,r.jsx)("div",{style:S.page,children:(0,r.jsx)(pro.render,pro.api)})}
  catch(e){return(0,r.jsx)("div",{style:S.page,children:(0,r.jsx)("div",{style:S.err,children:"Plugin page crashed: "+String((e&&e.message)||e)})})}
}
export default function PluginPage(){
  var st=t.useState({id:null,ready:false,tick:0,timedOut:false}),s=st[0],setS=st[1];
  t.useEffect(function(){var dead=false;
    (async function(){
      try{var l=await loc();var m=(l&&l.pathname||"").match(/^\/plugins\/([^\/]+)/);if(!dead)setS(function(p){return Object.assign({},p,{id:m?decodeURIComponent(m[1]):null,ready:true})})}catch(e){if(!dead)setS(function(p){return Object.assign({},p,{id:null,ready:true})})}
    })();
    return function(){dead=true}
  },[]);
  t.useEffect(function(){
    var tId=setInterval(function(){
      var ps=(window.__medalPlugins&&window.__medalPlugins.plugins)||[];
      var found=false;
      for(var i=0;i<ps.length;i++){
        if(ps[i].name===s.id&&(ps[i].pages||[]).length){found=true;break}
        for(var j=0;j<(ps[i].pages||[]).length;j++){if(ps[i].pages[j].pageId===s.id){found=true;break}}
      }
      if(found){setS(function(prev){return Object.assign({},prev,{tick:(prev.tick||0)+1})});clearInterval(tId)}
    },250);
    var timeout=setTimeout(function(){clearInterval(tId);setS(function(prev){return Object.assign({},prev,{timedOut:true})})},4000);
    return function(){clearInterval(tId);clearTimeout(timeout)};
  },[s.id]);
  if(!s.ready)return(0,r.jsx)("div",{style:S.page,children:"Loading..."});
  var pg=null,api={},ps=(window.__medalPlugins&&window.__medalPlugins.plugins)||[];
  for(var i=0;i<ps.length;i++){var en=ps[i];if(!en.api)continue;
    for(var j=0;j<(en.pages||[]).length;j++){if(en.pages[j].pageId===s.id){pg=en.pages[j];api=en.api;break}}
    if(pg)break;
  }
  if(!pg)for(var k=0;k<ps.length;k++){if(ps[k].name===s.id&&(ps[k].pages||[]).length){pg=ps[k].pages[0];api=ps[k].api||{};break}}
  if(!pg){
    var lv=null;for(var x=0;x<ps.length;x++){if(ps[x].name===s.id){lv=ps[x];break}}
    if(lv&&lv.error)return(0,r.jsxs)("div",{style:S.page,children:[(0,r.jsx)("h2",{style:{fontSize:"20px"},children:"Plugin failed to load"}),(0,r.jsx)("div",{style:S.err,children:lv.error})]});
    if(!s.timedOut)return(0,r.jsx)("div",{style:S.page,children:"Loading plugin '"+(s.id||"")+"'..."});
    return(0,r.jsxs)("div",{style:S.page,children:[(0,r.jsx)("h2",{style:{fontSize:"20px"},children:"Plugin not found"}),(0,r.jsx)("div",{style:S.err,children:"No enabled plugin '"+(s.id||"")+"' exposes a page. Enable it in Plugins and restart Medal."})]});
  }
  return(0,r.jsx)(PluginView,{render:pg.render,api:api},s.id);
}
'@
  $utf8NoBom = New-Object System.Text.UTF8Encoding $false
  [IO.File]::WriteAllText((Join-Path $Work 'app\chunks\renderer-PluginPage.js'), $PlugPage, $utf8NoBom)
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
s = replaceOnce(s, 'route:"/albums"}]:[]', 'route:"/albums"}]:[],{icon:(0,a.jsx)(W,{shape:"shapes-filled",size:24}),label:i({id:"plugins",defaultMessage:[{type:0,value:"Plugins"}]}),route:"/plugins"},...(typeof localStorage!=="undefined"&&localStorage.getItem("medal-plugins:discord-sidebar")==="false"?[]:[{icon:(0,a.jsx)(W,{shape:"social-discord",size:24}),label:"Discord",route:"/plugins/discord-send"}])', 'nav-plugins');
s = replaceOnce(s, '!(Y.route==="/games"&&/\\/games\\/[^/]+\\/clips?\\//.test(v))&&(v.startsWith(Y.route)||Y.route.includes(v))', '!(Y.route==="/games"&&/\\/games\\/[^/]+\\/clips?\\//.test(v))&&!(Y.route==="/plugins"&&v!=="/plugins")&&!(Y.route==="/plugins/discord-send"&&v!=="/plugins/discord-send")&&(v.startsWith(Y.route)||Y.route.includes(v))', 'nav-active-exact');
// --- PLUGINS: /plugins routes (manager + per-plugin pages) ---
s = replaceOnce(s, '{element:(0,a.jsx)(Dn,{activeTab:"library",hideOverflow:!1}),children:[{path:"/",lazy:t},{path:"/home/:tab?",lazy:t},{path:Zt.FEED_ITEM,lazy:t}]}', '{element:(0,a.jsx)(Dn,{activeTab:"library",hideOverflow:!1}),children:[{path:"/",lazy:t},{path:"/home/:tab?",lazy:t},{path:Zt.FEED_ITEM,lazy:t}]},{element:(0,a.jsx)(Dn,{activeTab:"plugins",hideOverflow:!1}),children:[{path:"/plugins",lazy:Fe(()=>import("./chunks/renderer-PluginsHome.js"))},{path:"/plugins/:pluginId",lazy:Fe(()=>import("./chunks/renderer-PluginPage.js"))}]}', 'router-plugins');
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
mm = replaceOnce(mm4, 'return{path:out,temp:true}}),Ie.ipcMain.handle("fs:resolveStaffDebugFolderPath"', 'return{path:out,temp:true}}),Ie.ipcMain.handle("medal-plugins:discord-render",async(s,o)=>{const fs=require("node:fs"),path=require("node:path"),os=require("node:os"),cp=require("node:child_process");const ff=path.join(os.homedir(),"AppData","Local","Medal","ffmpeg7.exe");try{await fs.promises.access(ff)}catch(e){throw new Error("discord-render: ffmpeg7.exe not found at "+ff)}const src=o&&o.src;if(!src)throw new Error("discord-render: missing src");const start=Math.max(0,Number(o.start)||0);const end=Number(o.end);if(!(end>start))throw new Error("discord-render: bad trim range (end must be after start)");const targetMB=Math.min(100,Math.max(1,Number(o.targetMB)||20));const res=String(o.resolution||"720p");async function findMpd(d,depth){const ents=await fs.promises.readdir(d,{withFileTypes:true}).catch(()=>[]);for(const e of ents){const p=path.join(d,e.name);if(e.isFile()&&e.name.toLowerCase()==="session.mpd")return p;if(e.isDirectory()&&depth>0){const r=await findMpd(p,depth-1);if(r)return r}}return null}let inFile=src;const sst=await fs.promises.stat(src).catch(()=>null);if(!sst)throw new Error("discord-render: src not found: "+src);if(!(sst.isFile()&&/\\.mp4$/i.test(src))){const dir=sst.isDirectory()?src:path.dirname(src);const mpd=await findMpd(dir,3);if(!mpd)throw new Error("discord-render: no DASH package under: "+dir);const base=path.dirname(mpd);const ents=await fs.promises.readdir(base);const pick=re=>ents.filter(f=>re.test(f)).sort().map(f=>path.join(base,f));const vv=pick(/^chunk-stream0-.*\\.m4s$/i),aa=pick(/^chunk-stream1-.*\\.m4s$/i);const has=async p=>{try{await fs.promises.access(p);return true}catch(e){return false}};if(!(await has(path.join(base,"init-stream0.m4s")))||!vv.length)throw new Error("discord-render: video segments missing");const rargs=["-hide_banner","-y","-i","concat:"+[path.join(base,"init-stream0.m4s")].concat(vv).join("|")];if(await has(path.join(base,"init-stream1.m4s"))&&aa.length)rargs.push("-i","concat:"+[path.join(base,"init-stream1.m4s")].concat(aa).join("|"));inFile=path.join(dir,"discord-src-"+Date.now()+".mp4");rargs.push("-c","copy",inFile);await new Promise((res2,rej)=>{cp.execFile(ff,rargs,{timeout:600000},(e2,so,se)=>{if(e2)rej(new Error("discord-render: remux failed: "+String(se||e2.message).slice(-300)));else res2(true)})})}const dur=end-start;const totalBits=Math.floor(targetMB*1024*1024*8*0.85);let vbits=Math.floor(totalBits/dur)-128000;if(vbits<200000)vbits=200000;const vf=res==="source"?[]:["-vf","scale="+(res==="1080p"?"-2:1080":"-2:720")+":force_original_aspect_ratio=decrease"];const out=path.join(path.dirname(inFile),"discord-"+Date.now()+".mp4");const args=["-hide_banner","-y","-i",inFile,"-ss",String(start),"-to",String(end)].concat(vf,["-c:v","libx264","-preset","veryfast","-b:v",String(vbits),"-maxrate",String(Math.floor(vbits*1.3)),"-bufsize",String(Math.floor(vbits*2)),"-c:a","aac","-b:a","128k","-movflags","+faststart",out]);await new Promise((res2,rej)=>{cp.execFile(ff,args,{timeout:1200000},(e2,so,se)=>{if(e2)rej(new Error("discord-render: ffmpeg failed: "+String(se||e2.message).slice(-400)));else res2(true)})});if(inFile!==src)await fs.promises.unlink(inFile).catch(()=>{});const ost=await fs.promises.stat(out).catch(()=>null);if(!ost||!ost.size)throw new Error("discord-render: no output produced");return{path:out,sizeBytes:ost.size}}),Ie.ipcMain.on("medal-plugins:discord-drag",(e,o)=>{try{const NI=require("electron").nativeImage;let icon=NI.createEmpty();try{const cands=[o&&o.icon,o&&o.thumb].filter(Boolean);for(const p of cands){const im=NI.createFromPath(p);if(im&&!im.isEmpty()){icon=im;break}}}catch(_){}e.sender.startDrag({file:o.path,icon:icon});e.returnValue={ok:true}}catch(err){try{e.returnValue={ok:false,error:String(err&&err.message||err)}}catch(_){}}}),Ie.ipcMain.handle("fs:resolveStaffDebugFolderPath"', 'main-discord-bridges');
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
