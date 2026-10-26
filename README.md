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

Nuckin's clean 06 KTM 200 XC-W (`z_06_KTM_200_XCW.pak`, included in the zip) working in game.

<table>
  <tr>
    <td width="50%" align="center"><img src="guide/ingame-200xcw-beach.jpg" width="100%" alt="Nuckin's 06 KTM 200 XC-W in game: beach and pier"><br><sub>Beach and pier</sub></td>
    <td width="50%" align="center"><img src="guide/ingame-200xcw-superman.jpg" width="100%" alt="Nuckin's 06 KTM 200 XC-W in game: superman over the trees"><br><sub>Superman over the trees</sub></td>
  </tr>
  <tr>
    <td width="50%" align="center"><img src="guide/ingame-200xcw-stonewall.jpg" width="100%" alt="Nuckin's 06 KTM 200 XC-W in game: stone wall"><br><sub>Stone wall</sub></td>
    <td width="50%" align="center"><img src="guide/ingame-200xcw-canyon.jpg" width="100%" alt="Nuckin's 06 KTM 200 XC-W in game: canyon at night"><br><sub>Canyon at night</sub></td>
  </tr>
  <tr>
    <td width="50%" align="center"><img src="guide/ingame-200xcw-finish.jpg" width="100%" alt="Nuckin's 06 KTM 200 XC-W in game: wheelie at the finish"><br><sub>Wheelie at the finish</sub></td>
    <td width="50%" align="center"><img src="guide/ingame-200xcw-tunnel.jpg" width="100%" alt="Nuckin's 06 KTM 200 XC-W in game: red tunnel wheelie"><br><sub>Red tunnel wheelie</sub></td>
  </tr>
  <tr>
    <td colspan="2" align="center"><img src="guide/ingame-oem-kx450f-ntm.jpg" width="50%" alt="Kawasaki KX450F with the N-TM 01 livery in game"><br><sub><code>z_OEM_Kawasaki_KX450F_N-TM.pak</code> (KX450F, N-TM 01 livery) working in game</sub></td>
  </tr>
</table>

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
