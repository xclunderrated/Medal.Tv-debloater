# Medal.tv Debloater

One-run mod for the Medal.tv desktop app, by **clu**. Strips it down to your clips — no ads, no Home, no Discover, no Quests.

## Quick start

Paste this in PowerShell, pick **Patch**, restart Medal:

```powershell
iex (irm https://raw.githubusercontent.com/xclunderrated/MedalTV-Debloater/HEAD/Medal-Debloat.ps1)
```

That's it — the script always fetches the newest version, so there's nothing to update by hand. It checks for a newer release on startup and tells you if you're behind.

Prefer files? Grab `Medal-Debloat.ps1` (+ the `Launch-MedalDebloat.cmd` double-click launcher) from the [latest release](https://github.com/xclunderrated/MedalTV-Debloater/releases/latest).

Needs **Windows** and **Node.js LTS** (only for the patching step). Custom install folder? Pass `-MedalRoot "D:\Games\Medal"`, or paste it when asked — it's remembered.

## What's inside

| | |
| --- | --- |
| **Debloat** | Display, library-grid, and post-upload ads disabled. Home, Discover, Quests, and Premium upsells removed — everything lands on your Library. |
| **Send to Discord** | Trim any clip, render to 10/20/50/100 MB, drag it straight into chat. Keeps your audio, and says so if a clip has none. 9:16 vertical mode with draggable crop for TikTok/Reels, keyboard frame-step, hover previews, one-click clip delete. |
| **Compact Library** *(toggleable)* | Tighter grid, slimmer headers, hover-only actions. |
| **Theme Studio** *(toggleable)* | Themes, accent colors, roundness, glass transparency, custom wallpaper with zoom and focus, shareable codes. |

## After Medal updates

Medal updates wipe the mod — just re-run **Patch** afterwards (or pick **Block updates** in the menu to stop updates entirely).

## Troubleshooting

**The script won't run / "not digitally signed"** — PowerShell blocks downloaded `.ps1` files. Either use the one-liner above, or right-click the file → Properties → tick **Unblock** → OK. `Launch-MedalDebloat.cmd` does this for you.

**`Medal is still running and could not be stopped`** — close Medal completely, including the tray icon, then run Patch again.

**`Unsupported Medal build: sidebar code not recognized`** — Medal auto-updated to a build the patcher doesn't know yet. Run **Restore** (to get back to a working app) and report your version — it's in the status box.

**`ASSERT FAIL [...]: expected N got M`** — same thing: a new Medal build changed its internals. Restore and report.

**`node.js not found`** — only needed for patching. Install Node.js LTS from [nodejs.org](https://nodejs.org) and re-run.

**`npx/@electron/asar failed. Need internet for first run.`** — the first patch downloads the asar tool. Everything after that works offline.

**`ffmpeg7.exe not found next to Medal`** — not fatal, the app works. Clip export and Send-to-Discord rendering need it; a Medal update sometimes moves it, so re-run Patch to relocate it.

**`DRAG LEFTOVER: csc.exe not found`** — only affects dragging files into other apps. Needs .NET Framework (present on Windows by default).

**`No backup at ...app.asar.bak`** — nothing to restore from. Reinstall Medal, then Patch.

**A finished render vanished** — the output file is still on disk; Send to Discord shows the path. Older versions didn't keep a list of past renders.

## Safety

- Automatic backup (`app.asar.bak`) before anything is touched.
- Every patch point is verified, and the patched JS is syntax-checked before it is installed.
- **Restore** in the menu undoes it all.

## License

MIT — see [LICENSE](LICENSE). No Medal code is redistributed here; this patches your own local install.

*Unofficial community mod, not affiliated with Medal B.V.*
