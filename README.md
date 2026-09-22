# Medal.Tv Debloater

A one-run PowerShell mod that strips Medal.tv's desktop app down to what matters: **your clips**.

## What it removes

| Bloat | What happens |
|---|---|
| Home page (`/home`) | Nav entry removed, all routes redirect to Library |
| Discover (`/games`) | Nav entry removed, route redirects to Library |
| Quests | Nav entry removed, route redirects to Library |
| Premium upsell nav | Premium nav entry removed |
| Display ads | `AdProvider` master switch forced off app-wide |
| Library-grid ads + sponsor cards | Grid ad injection disabled |
| Post-upload ad | `useAdsEnabled` forced false |
| Ad-unit chunks (7) | Stubbed to null components (Aditude, Leaderboard, Library element ad) |

Everything lands on **Library (`/library`)** — including the app logo, which normally goes Home.

## Usage

Run with no flags for the interactive menu:

```
 ==== Medal.Tv Debloater v3 ====
 [1] Patch (debloat + no ads, redirect to Library)
 [2] Restore stock
 [3] Block / Unblock updates
 [4] Status / verify
 [Q] Quit
```

```powershell
# Menu (auto-elevates):
powershell -ExecutionPolicy Bypass -File .\Medal-Debloat.ps1

# Headless (automation):
powershell -ExecutionPolicy Bypass -File .\Medal-Debloat.ps1 -Patch
powershell -ExecutionPolicy Bypass -File .\Medal-Debloat.ps1 -Restore
```

The menu shows live status (Medal version, STOCK / MODDED, backup present, updates blocked). Running **Patch over an older mod** automatically restores stock from backup first, then patches — no manual restore dance.

Requirements: Windows, Node.js LTS (for asar repacking, fetched automatically via npx on first run), internet on first run.

## How it works

1. Kills Medal, backs up `current\resources\app.asar` → `app.asar.bak` (+ versioned backup, never overwritten).
2. Extracts the asar, applies string patches with **exact-count asserts** to `renderer.min.js` (+ `useAdsEnabled`, `LibraryAd`), replaces Home/Games/Quests route chunks and 7 ad-unit chunks with tiny redirect/null stubs.
3. Repacks with `@electron/asar`, preserving the 585 unpacked files (`*.node`, `*.exe`, `src/assets/**`, `vendor/better-sqlite3/**`) so native modules keep working.
4. Verifies (no leftover routes/ad wiring, JS syntax valid) and records state in `app.asar.modinfo` (used by the menu's status readout).
5. Updates are managed separately (menu item 3: `Update.exe` ↔ `Update.exe.disabled`), since any Medal update wipes the mod — just re-run Patch afterwards.

## Plugin system

Patching adds a **Plugins** button under Albums in the left bar, opening a manager page (`/plugins`).

- Plugins live in `%LOCALAPPDATA%\Medal\plugins\<name>\plugin.js` (optional `manifest.json` with name/version/author/description). Drop a folder in, run **Rescan plugins** (menu item 5), restart Medal.
- The manager lists plugins with **enable/disable toggles** and per-plugin **settings** (declared via `api.registerSettings`). Plugins can also add their own pages (`api.registerPage` → `/plugins/<id>`).
- Plugin API: `api.React`, `api.el` (no JSX build needed), `api.navigate`, `api.MedalIPC` (clips, kv storage, dialogs), `api.store` (namespaced persistence), `api.onClip` (new-clip events), `api.toast`.
- A **youtube-backup sample plugin** is scaffolded automatically: it embeds YouTube Studio right on its plugin page — log in once inside it (no Google Cloud project, no API keys, no quotas), and new clips **auto-upload** (plus per-clip **Upload** buttons). The embedded session persists across restarts. Caveats: if Google ever refuses embedded sign-in, the plugin says so and points at the API-login fallback; UI automation can break when YouTube changes its uploader markup, and the plugin reports exactly which step failed.
- The patch registers the plugins folder in the main-process file-access allowlist (so plugins load via `MedalIPC.fs`) and adds a one-shot localhost OAuth listener channel (`medal-plugins:oauth-listen`/`oauth-await`, bridged in the preload) used by the one-click login.
- The bundled youtube-backup sample auto-upgrades on Patch (old copy kept as `plugin.js.bak`); user-modified plugins are never touched.

Only install plugins you trust — they run with full renderer privileges.

## Compatibility

Pinned and tested against **Medal 2638.479.1**. Every patch asserts exact match counts — on a different Medal version the script **aborts instead of corrupting** your install. Re-run the script after any manual Medal reinstall/update.

## Disclaimer

Unofficial community mod. Not affiliated with Medal B.V. Use at your own risk — a backup is created automatically, and `-Restore` undoes everything. No Medal code is redistributed here; the script only contains patch patterns applied locally to your own install.
