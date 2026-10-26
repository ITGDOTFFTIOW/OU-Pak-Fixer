# Open Unleashed Pak Fixer

![Nuckin's 06 KTM 200 XC-W in Open Unleashed](guide/hero-ktm-xcw.jpg)

A Windows app for **MX vs ATV Unleashed / Open Unleashed** `.pak` mods. It fixes broken paks, installs and removes them, warns about clashes, and previews every bike and gear item in a 3D Showroom.

<p align="center">
  <a href="https://github.com/ITGDOTFFTIOW/OU-Pak-Fixer/releases/latest"><img src="https://img.shields.io/badge/DOWNLOAD-latest%20release-e31c23?style=for-the-badge" alt="Download the latest release" height="56"></a>
</p>

On the release page, scroll to **Assets** and click the **.zip** file. Don't use the green **Code** button; that downloads the source, not the app.

**How to use it:** see the [User Guide](GUIDE.md).

## Requirements
- Windows 10 or 11 (PowerShell 5.1 is built in)
- MX vs ATV Unleashed (Steam) / Open Unleashed

## Install
1. Download the .zip from the [latest release](https://github.com/ITGDOTFFTIOW/OU-Pak-Fixer/releases/latest).
2. Right-click the zip > **Properties** > tick **Unblock** > **OK**.
3. Extract it anywhere. You get one folder, `OU Pak Fixer`.
4. Run **`OPEN UI.bat`** in that folder.

## In game

<!-- Gallery placeholders: drop the images into guide/ and remove the comment markers. -->
<!-- ![Nuckin's 06 KTM 200 XC-W, clean](guide/ingame-200xcw-clean.jpg) -->
<!-- ![OEM replica bikes in game](guide/ingame-oem-1.jpg) -->
<!-- ![OEM replica bikes in game](guide/ingame-oem-2.jpg) -->

| Nuckin's 06 KTM 200 XC-W | OEM replica bikes in game | OEM replica bikes in game |
|---|---|---|
| *Screenshot coming soon* | *Screenshot coming soon* | *Screenshot coming soon* |

## FAQ and troubleshooting

**What do Good, Broken and Clash mean?**
- **Good**: ready to go.
- **Broken**: the pak needs fixing (bad texture headers, or a name that loads before the game's own files, such as one starting with `$`). Tick it and click **Fix selected**.
- **Clash**: another installed pak replaces the same item. Only one shows in game. Remove the one you don't want.

**How do I find my game folder?**
The app finds it by itself. If it picks the wrong one, click **Change** on the top bar and choose the game's `data` folder (the one with `common.pak`). For Steam that is usually `C:\Program Files (x86)\Steam\steamapps\common\MX vs. ATV Unleashed\data`. In Steam you can also right-click the game > **Manage** > **Browse local files** and open `data`.

**A skin doesn't show up in game.**
- Check its status in **PACK MANAGER > Installed**. Broken paks must be fixed first.
- If it says **Clash**, another pak replaces the same item. Remove the other one.
- Make sure you picked the right bike and team/livery in game. The Showroom card shows which bike and livery the skin replaces.
- Restart the game after installing or removing paks.

**Windows blocks the .bat or PowerShell.**
- Right-click the downloaded zip > **Properties** > tick **Unblock** > **OK**, then extract it again.
- If SmartScreen shows "Windows protected your PC", click **More info** > **Run anyway**.
- The .bat files start PowerShell with `-ExecutionPolicy Bypass` for this app only. Your system setting is not changed.

**How do I undo or uninstall?**
- To take a pak out of the game: tick it under **Installed** and click **Remove**. It moves to `Pack Files\Disabled`, and nothing is deleted.
- To restore an original download: the untouched copy is in `Pack Files\Originals`.
- To uninstall the app: remove your paks from the game first if you want the game back to stock, then delete the `OU Pak Fixer` folder. The app never changes the game's own paks or your save.

**Where can I get more skins?**
The [MVA Unleashed Mod Collection on ModDB](https://www.moddb.com/mods/mva-unleashed-mod-collection). Put downloaded paks in `Pack Files\Broken` and fix them from **PACK MANAGER > Broken**.

**If the window app won't start**
`FIX PAKS.bat` and `Pack Manager\MANAGE PACKS.bat` do the same fixing and turning paks on/off from a console window. See the [User Guide](GUIDE.md#fallback-fix-paksbat-and-manage-packsbat).

## Credits and thanks
The included skin, Nuckin's 06 KTM 200 XC-W, is by NuckinFutz197. Thanks to the community skin creators and to the MVA Unleashed Mod Collection. See [CREDITS.md](CREDITS.md).

All rights reserved.
