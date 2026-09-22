# Medal.tv Debloater

Made by **clu**.

Strips the Medal.tv desktop app down to your clips. No ads, no Home/Discover/Quests pages — everything opens straight into your Library.

**Download:** grab `Medal-Debloat.ps1` from the [latest release](https://github.com/xclunderrated/Medal.Tv-debloater/releases/latest).

## What you get

- **No ads** — display ads, library-grid ads, and post-upload ads all disabled.
- **No clutter** — Home, Discover, Quests, and Premium-upsell nav entries removed; those routes redirect to your Library.
- **Send to Discord plugin** — trim any clip and render it to a Discord-friendly size (10/20/50/100 MB), then drag it straight into any chat. Includes a **9:16 vertical mode** for TikTok/Reels: a draggable crop frame over the preview, renders true vertical video.
- **Compact Library plugin** (optional, toggleable) — tighter library grid: smaller cards, slimmer headers, hover-only action buttons.

## Usage

1. Run the script (auto-elevates if needed):
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Medal-Debloat.ps1
   ```
2. Pick **Patch** from the menu, then **restart Medal**.
3. After any Medal update, just run Patch again (updates wipe the mod).

Other menu options: **Restore stock**, **Block/Unblock updates**, **Status/verify**.

Requirements: Windows + Node.js LTS (used for repacking; fetched automatically on first run).

## Safety

- Your original app is backed up automatically (`app.asar.bak`) before anything is touched.
- Every patch is verified before it ships — if anything doesn't match your Medal version, the script aborts instead of breaking your install.
- **Restore** undoes everything.

## Disclaimer

Unofficial community mod, not affiliated with Medal B.V. Use at your own risk. No Medal code is redistributed here — the script only patches your own local install.
