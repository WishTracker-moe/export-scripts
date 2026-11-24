# WishTracker export scripts

PowerShell scripts that read your gacha history and hand it to
[WishTracker](https://wishtracker.moe), a free, local-first pity tracker. Your
history goes from the game's own service to your clipboard, and WishTracker
keeps it in your browser.

| Game                | Script                                                               | What it reads                                                      |
| ------------------- | -------------------------------------------------------------------- | ------------------------------------------------------------------ |
| Genshin Impact      | [`genshin-wish-export.ps1`](genshin-wish-export.ps1)                 | The wish history link the game caches while Wish > History is open |
| Wuthering Waves     | [`wuwa-convene-export.ps1`](wuwa-convene-export.ps1)                 | The convene history link the game writes to its logs               |
| Arknights: Endfield | [`endfield-headhunting-export.ps1`](endfield-headhunting-export.ps1) | A records token from SKPORT's record book, after you sign in there |

Each script talks only to the game publisher's history service, saves nothing
unless you pass `-OutFile`, and leaves access keys and tokens out of the
result. The comments at the top of each script explain the details; read them
before you run anything.

## Running a script

WishTracker's import dialog shows a command to copy for your game. It loads the
script from this repository and runs it:

```powershell
powershell -c "& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/WishTracker-moe/export-scripts/main/genshin-wish-export.ps1')))"
```

Or download the script, look through it, then right-click it and choose
**Run with PowerShell**. Paste the result in WishTracker under
**Import > Paste from clipboard**.

## About this repository

The scripts are developed together with WishTracker and copied here
automatically, so changes made here directly are overwritten.
