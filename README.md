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

```powershell
# Run (auto-elevates, backs up, patches, verifies):
powershell -ExecutionPolicy Bypass -File .\Medal-Debloat.ps1

# Undo everything:
powershell -ExecutionPolicy Bypass -File .\Medal-Debloat.ps1 -Restore

# Patch but keep auto-updates enabled (mod WILL be wiped on next update):
powershell -ExecutionPolicy Bypass -File .\Medal-Debloat.ps1 -KeepUpdates
```

Requirements: Windows, Node.js LTS (for asar repacking, fetched automatically via npx on first run), internet on first run.

## How it works

1. Kills Medal, backs up `current\resources\app.asar` → `app.asar.bak` (+ versioned backup, never overwritten).
2. Extracts the asar, applies string patches with **exact-count asserts** to `renderer.min.js` (+ `useAdsEnabled`, `LibraryAd`), replaces Home/Games/Quests route chunks and 7 ad-unit chunks with tiny redirect/null stubs.
3. Repacks with `@electron/asar`, preserving the 585 unpacked files (`*.node`, `*.exe`, `src/assets/**`, `vendor/better-sqlite3/**`) so native modules keep working.
4. Verifies (no leftover routes/ad wiring, JS syntax valid), then **blocks auto-updates** by renaming `Update.exe` → `Update.exe.disabled` (reversible via `-Restore`), since any update would wipe the mod.

## Compatibility

Pinned and tested against **Medal 2638.479.1**. Every patch asserts exact match counts — on a different Medal version the script **aborts instead of corrupting** your install. Re-run the script after any manual Medal reinstall/update.

## Disclaimer

Unofficial community mod. Not affiliated with Medal B.V. Use at your own risk — a backup is created automatically, and `-Restore` undoes everything. No Medal code is redistributed here; the script only contains patch patterns applied locally to your own install.
