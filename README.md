# Medal.tv Debloater

Made by **clu**. Strips the Medal.tv desktop app down to your clips — no ads, no Home/Discover/Quests.

**Run (no download needed)** — paste in PowerShell:

```powershell
iex (irm https://raw.githubusercontent.com/xclunderrated/Medal.Tv-debloater/v66/Medal-Debloat.ps1)
```

Or download `Medal-Debloat.ps1` (+ `Launch-MedalDebloat.cmd` double-click launcher) from the [latest release](https://github.com/xclunderrated/Medal.Tv-debloater/releases/latest).

## What's inside

- **Debloat** — display, library-grid, and post-upload ads disabled; Home, Discover, Quests, and Premium upsells removed and redirected to your Library.
- **Send to Discord** — trim any clip, render to 10/20/50/100 MB, drag it straight into chat. 9:16 vertical mode with draggable crop for TikTok/Reels, keyboard frame-step, hover previews, one-click clip delete.
- **Compact Library** (toggleable) — tighter grid, slimmer headers, hover-only actions.
- **Theme Studio** (toggleable) — themes, accent colors, roundness, glass transparency, custom wallpaper with zoom and focus, shareable codes.

## Use

1. Run the one-liner above (or right-click-run a downloaded `Medal-Debloat.ps1`).
2. Pick **Patch**, restart Medal.
3. Re-run Patch after every Medal update (updates might wipe the mod). or just disable updates.

Custom install folder? Pass `-MedalRoot "D:\Games\Medal"`, or paste it when asked — it's remembered. Needs Windows + Node.js LTS.

## Safety

Backed up automatically (`app.asar.bak`), verified before anything is touched, **Restore** undoes it all.

*Unofficial community mod, not affiliated with Medal B.V. It patches your own local install — no Medal code is redistributed here.*
