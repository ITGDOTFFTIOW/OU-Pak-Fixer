# Open Unleashed Pak Fixer - WinForms UI
# PowerShell + System.Windows.Forms only. Dot-sources Manage-OUPaks.ps1 for helpers.
param([switch]$SmokeTest)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
# App identity: own taskbar group + icon instead of PowerShell's (must run before any window is created)
$script:OuAppId = 'OpenUnleashed.PakFixer'
# Release version + GitHub repo used by ABOUT > Version > Check for updates ('OWNER/REPO' = not configured yet)
$script:OU_Version = '1.0.0'
$script:OU_VersionDate = '2026-10-26'
$script:OU_UpdateRepo = 'ITGDOTFFTIOW/OU-Pak-Fixer'
try {
  if (-not ('OuAppId' -as [type])) { Add-Type -Namespace '' -Name 'OuAppId' -MemberDefinition '[System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string AppID);' -ErrorAction Stop }
  $script:OuAppIdResult = [OuAppId]::SetCurrentProcessExplicitAppUserModelID($script:OuAppId)
} catch { $script:OuAppIdResult = -1 }

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$manage = Join-Path $here 'Manage-OUPaks.ps1'
if (-not (Test-Path -LiteralPath $manage)) { throw "Manage-OUPaks.ps1 not found next to OU-UI.ps1: $here" }

. $manage
$script:OU3DPump = $true   # 3D waits pump WinForms messages (UI stays responsive)

$brokenDir = Join-Path $root 'Pack Files\Broken'
$fixedDir  = Join-Path $root 'Pack Files\Fixed'
$disabledDir = Join-Path $root 'Pack Files\Disabled'
$origDir = Join-Path $root 'Pack Files\Originals'
$catalogPath = Join-Path $here 'mod-catalog.json'
$readmePath = Join-Path $root 'README.txt'
$versionPath = Join-Path $root 'VERSION.txt'
foreach ($d in @($brokenDir, $fixedDir, $disabledDir, $origDir)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

# ---------- catalog ----------
$script:CatalogByName = @{}
$script:CatalogNorm = $null
$script:CatalogPacks = @()
$script:CatOrder = @('Bikes','Rider gear','Add-ons','Tires','Camera','Bike + gear sets','Mega skin packs','Misc')
$script:ClassOrder = @('50cc minis','125 / 250F','250 / 450','500','ATV','Other vehicles')

function Load-Catalog {
  $script:CatalogByName = @{}
  $script:CatalogNorm = $null
  $script:CatalogPacks = @()
  if (-not (Test-Path -LiteralPath $catalogPath)) { return }
  try {
    $raw = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8
    $obj = $raw | ConvertFrom-Json
    if ($obj.categories) { $script:CatOrder = @($obj.categories) }
    if ($obj.classOrder) { $script:ClassOrder = @($obj.classOrder) }
    foreach ($p in @($obj.packs)) {
      $script:CatalogPacks += $p
      if ($p.pak) { $script:CatalogByName[$p.pak.ToLowerInvariant()] = $p }
    }
  } catch {
    # catalog optional
  }
}

function Get-CatalogMeta([string]$fileName) {
  if (-not $fileName) { return $null }
  $key = $fileName.ToLowerInvariant()
  if ($script:CatalogByName.ContainsKey($key)) { return $script:CatalogByName[$key] }
  # Normalize: drop leading z_/$$$ and trailing (N) from fixer renames
  $base = [IO.Path]::GetFileNameWithoutExtension($fileName)
  $ext = [IO.Path]::GetExtension($fileName)
  $stripped = ($base -replace '^z_','' -replace '^[^A-Za-z0-9]+','' -replace '\s*\(\d+\)$','')
  $alt = ($stripped + $ext).ToLowerInvariant()
  if ($script:CatalogByName.ContainsKey($alt)) { return $script:CatalogByName[$alt] }
  # Catalog keys may still have leading $ - match by normalized core
  if (-not $script:CatalogNorm) {
    $script:CatalogNorm = @{}
    foreach ($k in @($script:CatalogByName.Keys)) {
      $bn = [IO.Path]::GetFileNameWithoutExtension($k)
      $ex = [IO.Path]::GetExtension($k)
      $core = (($bn -replace '^[^A-Za-z0-9]+','') + $ex).ToLowerInvariant()
      if (-not $script:CatalogNorm.ContainsKey($core)) { $script:CatalogNorm[$core] = $script:CatalogByName[$k] }
    }
  }
  if ($script:CatalogNorm.ContainsKey($alt)) { return $script:CatalogNorm[$alt] }
  $null
}

function Format-Size([long]$bytes) {
  if ($bytes -ge 1MB) { '{0:N1} MB' -f ($bytes / 1MB) }
  elseif ($bytes -ge 1KB) { '{0:N0} KB' -f ($bytes / 1KB) }
  else { "$bytes B" }
}

function Wait-GameClosedGui {
  while (Game-Running) {
    $r = [System.Windows.Forms.MessageBox]::Show(
      "Open Unleashed is running.`n`nClose the game, then click Retry.`nClick Cancel to abort.",
      'Game running',
      [System.Windows.Forms.MessageBoxButtons]::RetryCancel,
      [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($r -eq [System.Windows.Forms.DialogResult]::Cancel) { return $false }
  }
  $true
}

function Find-PreviewPath([string]$packName) {
  if (-not $packName) { return $null }
  $exact = Join-Path $prevD ("{0}.png" -f $packName)
  if (Test-Path -LiteralPath $exact) { return $exact }
  $hit = Get-ChildItem -LiteralPath $prevD -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -ieq '.png' -and $_.BaseName -ieq $packName } |
    Select-Object -First 1
  if ($hit) { return $hit.FullName }
  $null
}

function Get-BrokenInstalled {
  if (-not $game) { return @() }
  $inst = @(Installed)
  if (-not $inst.Count) { return @() }
  $um = Unused-Map $inst
  @($inst | Where-Object {
    (Count-Broken $_.FullName) -gt 0 -or $um.ContainsKey($_.Name) -or (Needs-LoadOrder $_.Name)
  })
}

function Confirm-ClashesGui($sel) {
  $sel = @($sel)
  if (-not $sel.Count) { return 'none' }
  try {
    $un = @(& $fixer -ListOnly -UnusedReport @($sel | ForEach-Object { $_.FullName }))
    if ($un.Count) {
      $lines = $un | ForEach-Object {
        $f = $_.Split('|')
        $s = if ($f[3] -eq '1') { " -> will rename to $(Split-Path $f[2] -Leaf)" }
             elseif ($f[2]) { " (did you mean $(Split-Path $f[2] -Leaf)?)" }
             else { ' (no similar game file)' }
        "  $($f[0]): $(Split-Path $f[1] -Leaf)$s"
      }
      [void][System.Windows.Forms.MessageBox]::Show(
        ("Note - unused files (rest of each pack still works):`n`n" + ($lines -join "`n")),
        'Unused files',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information)
    }
  } catch {}

  $have = @{}
  foreach ($p in (Installed)) { $have[$p.Name] = Get-Labels $p.FullName }
  $found = $false
  $msg = New-Object System.Text.StringBuilder
  [void]$msg.AppendLine('CLASH WARNING - only one version of each item will show in game:')
  for ($a = 0; $a -lt $sel.Count; $a++) {
    $mine = Get-Labels $sel[$a].FullName
    $against = @($have.Keys | Sort-Object | ForEach-Object { ,@($_, $have[$_], 'installed') }) +
               @(for ($b = 0; $b -lt $a; $b++) { ,@($sel[$b].Name, (Get-Labels $sel[$b].FullName), 'also being added') })
    $hits = @()
    foreach ($o in $against) {
      $same = @($mine | Where-Object { $o[1].Contains($_) })
      if ($same.Count) { $hits += , @($o[0], $o[2], $same) }
    }
    if ($hits.Count) {
      $found = $true
      [void]$msg.AppendLine('')
      [void]$msg.AppendLine("$($sel[$a].Name) clashes with:")
      foreach ($h in $hits) {
        [void]$msg.AppendLine("  $($h[0]) ($($h[1]))")
        $h[2] | Select-Object -First 6 | ForEach-Object { [void]$msg.AppendLine("      - $_") }
        if ($h[2].Count -gt 6) { [void]$msg.AppendLine("      ...and $($h[2].Count - 6) more") }
      }
    }
  }
  if (-not $found) { return 'all' }
  $r = [System.Windows.Forms.MessageBox]::Show(
    ($msg.ToString() + "`n`nYes = add all`nNo = skip clashing ones`nCancel = abort"),
    'Clash warning',
    [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
    [System.Windows.Forms.MessageBoxIcon]::Warning)
  switch ($r) {
    ([System.Windows.Forms.DialogResult]::Yes) { 'all' }
    ([System.Windows.Forms.DialogResult]::No)  { 'skip' }
    default { 'none' }
  }
}

function Filter-SkipClashes($sel) {
  $instNow = New-Object System.Collections.Generic.List[string]
  foreach ($ip in (Installed)) { foreach ($x in (Get-Labels $ip.FullName)) { [void]$instNow.Add($x) } }
  $keep = @(); $taken = New-Object System.Collections.Generic.List[string]
  foreach ($p in $sel) {
    $l = Get-Labels $p.FullName
    if (@($l | Where-Object { $instNow.Contains($_) -or $taken.Contains($_) }).Count) {
      Set-Status "skipped (clashes): $($p.Name)"
    } else {
      $keep += $p
      $l | ForEach-Object { [void]$taken.Add($_) }
    }
  }
  ,$keep
}

Load-Catalog

# ---------- form shell ----------
# YouTube-style fullscreen glyphs. Expand=4 outward corners; Collapse=2 diagonal inward brackets with wide center gap (not a +).
function New-FullscreenGlyphIcon {
  param(
    [ValidateSet('Expand','Collapse')][string]$Mode,
    [int]$Size = 24,
    [System.Drawing.Color]$Color = [System.Drawing.Color]::White
  )
  $bmp = New-Object System.Drawing.Bitmap($Size, $Size)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.Clear([System.Drawing.Color]::Transparent)
  $pen = New-Object System.Drawing.Pen($Color, 2.1)
  $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  if ($Mode -eq 'Expand') {
    # Two diagonal outward corners (TL + BR) - YouTube expand, not a 4-corner box
    $m = [Math]::Max(2, [int][Math]::Round($Size * 0.14))
    $arm = [Math]::Max(6, [int][Math]::Round($Size * 0.34))
    # Top-left pointing out
    $g.DrawLine($pen, $m, $m, $m + $arm, $m)
    $g.DrawLine($pen, $m, $m, $m, $m + $arm)
    # Bottom-right pointing out
    $g.DrawLine($pen, $Size - $m - $arm, $Size - $m, $Size - $m, $Size - $m)
    $g.DrawLine($pen, $Size - $m, $Size - $m - $arm, $Size - $m, $Size - $m)
  } else {
    # Two diagonal inward L-brackets; tips stay far apart so center stays open (not a plus)
    $ix = [Math]::Max(6, [int][Math]::Round($Size * 0.28))
    $iy = $ix
    $arm = [Math]::Max(5, $ix - 2)
    $g.DrawLine($pen, $ix - $arm, $iy, $ix, $iy)
    $g.DrawLine($pen, $ix, $iy - $arm, $ix, $iy)
    $jx = $Size - $ix; $jy = $Size - $iy
    $g.DrawLine($pen, $jx, $jy, $jx + $arm, $jy)
    $g.DrawLine($pen, $jx, $jy, $jx, $jy + $arm)
  }
  $pen.Dispose(); $g.Dispose()
  return $bmp
}
$script:FsIconExpandOn  = New-FullscreenGlyphIcon -Mode Expand   -Size 24 -Color ([System.Drawing.Color]::White)
$script:FsIconExpandOff = New-FullscreenGlyphIcon -Mode Expand   -Size 24 -Color ([System.Drawing.Color]::FromArgb(140, 140, 148))
$script:FsIconCollapse  = New-FullscreenGlyphIcon -Mode Collapse -Size 24 -Color ([System.Drawing.Color]::White)
$script:FsIconExpand = $script:FsIconExpandOff  # default until button enabled

# Small tool glyphs drawn in code (no font fallback surprises): Refresh = circular arrow, More = three dots.
function New-OuToolGlyphIcon([ValidateSet('Refresh', 'More')][string]$Mode, [int]$Size = 16, [System.Drawing.Color]$Color = [System.Drawing.Color]::White) {
  $bmp = New-Object System.Drawing.Bitmap($Size, $Size)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.Clear([System.Drawing.Color]::Transparent)
  $br = New-Object System.Drawing.SolidBrush $Color
  if ($Mode -eq 'More') {
    $d = [Math]::Max(3, [int]($Size / 5)); $y = [int](($Size - $d) / 2); $gap = [int](($Size - 3 * $d) / 4)
    for ($i = 0; $i -lt 3; $i++) { $g.FillEllipse($br, ($gap + $i * ($d + $gap)), $y, $d, $d) }
  } else {
    $pen = New-Object System.Drawing.Pen $Color, ([Math]::Max(1.6, $Size / 9.0))
    $m = [Math]::Max(2, [int]($Size * 0.18)); $r = ($Size - 2 * $m) / 2.0; $cx = $Size / 2.0; $cy = $Size / 2.0
    $start = 20.0; $sweep = 280.0
    $g.DrawArc($pen, [single]$m, [single]$m, [single](2 * $r), [single](2 * $r), [single]$start, [single]$sweep)
    $a = ($start + $sweep) * [Math]::PI / 180.0
    $ex = $cx + $r * [Math]::Cos($a); $ey = $cy + $r * [Math]::Sin($a)
    $tx = -[Math]::Sin($a); $ty = [Math]::Cos($a); $nx = [Math]::Cos($a); $ny = [Math]::Sin($a)
    $h = $Size * 0.22
    $pts = [System.Drawing.PointF[]]@(
      (New-Object System.Drawing.PointF([single]($ex + $tx * $h * 1.1), [single]($ey + $ty * $h * 1.1))),
      (New-Object System.Drawing.PointF([single]($ex - $tx * $h * 0.5 + $nx * $h), [single]($ey - $ty * $h * 0.5 + $ny * $h))),
      (New-Object System.Drawing.PointF([single]($ex - $tx * $h * 0.5 - $nx * $h), [single]($ey - $ty * $h * 0.5 - $ny * $h)))
    )
    $g.FillPolygon($br, $pts)
    $pen.Dispose()
  }
  $br.Dispose(); $g.Dispose()
  return $bmp
}
$script:IconRefresh = New-OuToolGlyphIcon -Mode Refresh -Size 16 -Color ([System.Drawing.Color]::White)
$script:IconMore    = New-OuToolGlyphIcon -Mode More    -Size 16 -Color ([System.Drawing.Color]::White)

# Dark drop-down menus (Open / preview More) + ListView header repaint helper. Missing compiler never blocks launch.
if (-not ('OuDarkMenuColors' -as [type])) {
  try {
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System; using System.Drawing; using System.Windows.Forms; using System.Runtime.InteropServices;
public class OuDarkMenuColors : ProfessionalColorTable {
  private Color back, border, hover;
  public OuDarkMenuColors(Color back, Color border, Color hover) { this.back = back; this.border = border; this.hover = hover; UseSystemColors = false; }
  public override Color ToolStripDropDownBackground { get { return back; } }
  public override Color MenuBorder { get { return border; } }
  public override Color MenuItemBorder { get { return hover; } }
  public override Color MenuItemSelected { get { return hover; } }
  public override Color MenuItemSelectedGradientBegin { get { return hover; } }
  public override Color MenuItemSelectedGradientEnd { get { return hover; } }
  public override Color MenuItemPressedGradientBegin { get { return hover; } }
  public override Color MenuItemPressedGradientEnd { get { return hover; } }
  public override Color ImageMarginGradientBegin { get { return back; } }
  public override Color ImageMarginGradientMiddle { get { return back; } }
  public override Color ImageMarginGradientEnd { get { return back; } }
  public override Color SeparatorDark { get { return border; } }
  public override Color SeparatorLight { get { return back; } }
}
public static class OuLvHeader {
  [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] static extern bool InvalidateRect(IntPtr h, IntPtr r, bool erase);
  public static void Invalidate(IntPtr listView) {
    IntPtr hdr = SendMessage(listView, 0x101F, IntPtr.Zero, IntPtr.Zero); // LVM_GETHEADER
    if (hdr != IntPtr.Zero) InvalidateRect(hdr, IntPtr.Zero, true);
  }
}
'@
  } catch { }
}

# ==================== Open Unleashed theme (dark glass + red accents) ====================
# Background photos: Settings\Theme\bg-NN[ name].jpg (e.g. 'bg-03 seat grab indian air.jpg'), in name order. Launch opens on a random one;
# the photo then moves to the next one (wrapping) on every top-tab or side-tab change.
$script:ThemeBgDir = Join-Path $root 'Settings\Theme'
$script:ThemeBgPaths = @()
try { $script:ThemeBgPaths = @(Get-ChildItem -LiteralPath $script:ThemeBgDir -File -ErrorAction Stop | Where-Object { $_.Name -match '^bg-\d+( [^\\/]*)?\.(jpe?g|png)$' } | Sort-Object Name | ForEach-Object { $_.FullName }) } catch { $script:ThemeBgPaths = @() }
if (-not $script:ThemeBgPaths.Count) { $script:ThemeBgPaths = @(Join-Path $script:ThemeBgDir 'ktm-xcw-bg.jpg') }   # older installs
$script:ThemeBgPath = $script:ThemeBgPaths[0]
# App icon (197N front plate). Missing/bad file never blocks launch.
$script:AppIconPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Theme\OU-PakFixer.ico'
$script:AppIcon = $null
try { if (Test-Path -LiteralPath $script:AppIconPath) { $script:AppIcon = New-Object System.Drawing.Icon($script:AppIconPath) } } catch { $script:AppIcon = $null }
function Set-OuFormIcon($f) {
  if (-not $f -or -not $script:AppIcon) { return }
  try { $f.Icon = $script:AppIcon; $f.ShowIcon = $true } catch { }
}
$script:Theme = [ordered]@{
  Accent       = [System.Drawing.Color]::FromArgb(227, 28, 35)       # CTA red ~#E31C23
  AccentDark   = [System.Drawing.Color]::FromArgb(160, 20, 28)
  AccentSoft   = [System.Drawing.Color]::FromArgb(90, 28, 32)        # selected nav/rail
  SelectBg     = [System.Drawing.Color]::FromArgb(227, 28, 35)        # same as Accent / Run fixer CTA
  CheckedBg    = [System.Drawing.Color]::FromArgb(227, 28, 35)        # same as Accent (checked == selected red)
  PanelOpaque  = [System.Drawing.Color]::FromArgb(22, 22, 26)        # lists/inputs
  PanelHeavy   = [System.Drawing.Color]::FromArgb(14, 14, 16)        # near-opaque fill for children on heavy cards
  PanelDeep    = [System.Drawing.Color]::FromArgb(16, 16, 18)
  ButtonFace   = [System.Drawing.Color]::FromArgb(45, 45, 48)        # secondary flat
  ButtonBorder = [System.Drawing.Color]::FromArgb(70, 70, 76)
  Text         = [System.Drawing.Color]::White
  TextMuted    = [System.Drawing.Color]::FromArgb(180, 180, 185)
  Splitter     = [System.Drawing.Color]::FromArgb(40, 40, 44)
  GlassAlpha      = 190                                                 # light chrome (top/nav/fixTop/manage/sel/btn)
  GlassAlphaHeavy = 238                                                 # heavy cards (fixTop/selTray/fixBtnChrome/fixPrevPanel)
  GlassAlphaPreview = 155                                                # lightest glass (rail/list/preview)
  GlassRGB        = @(16, 16, 18)
}
$script:OuClearBg = [System.Drawing.Color]::FromArgb(16, 16, 18)  # paint Clear(); never pass Theme lookup/$null

function Set-OuDoubleBuffer([System.Windows.Forms.Control]$c, [switch]$OpaquePaint) {
  try {
    $flags = [System.Reflection.BindingFlags]'NonPublic, Instance'
    $mi = $c.GetType().GetMethod('SetStyle', $flags)
    if ($mi) {
      $style = [System.Windows.Forms.ControlStyles]::OptimizedDoubleBuffer -bor
               [System.Windows.Forms.ControlStyles]::AllPaintingInWmPaint -bor
               [System.Windows.Forms.ControlStyles]::UserPaint
      if ($OpaquePaint) {
        $style = $style -bor [System.Windows.Forms.ControlStyles]::Opaque
      } else {
        $style = $style -bor [System.Windows.Forms.ControlStyles]::SupportsTransparentBackColor
      }
      [void]$mi.Invoke($c, @($style, $true))
    }
  } catch { }
}

if (-not $script:OuGlassAlpha) { $script:OuGlassAlpha = @{} }
if (-not $script:OuGlassHooked) { $script:OuGlassHooked = New-Object 'System.Collections.Generic.HashSet[object]' }
$script:OuFormBgCache = $null
$script:OuFormBgCacheSize = New-Object System.Drawing.Size(0, 0)
$script:OuGlassResizeTimer = $null
$script:OuGlassSyncBusy = $false

# Form BackgroundImageLayout=Stretch dest rect in form client coords
function Get-OuFormBgDestRect {
  # Matches form.BackgroundImageLayout = Stretch: photo fills entire client (no letterbox).
  if (-not $form -or -not $form.BackgroundImage) { return $null }
  $img = $form.BackgroundImage
  $cw = [Math]::Max(1, $form.ClientSize.Width)
  $ch = [Math]::Max(1, $form.ClientSize.Height)
  return @{ Img = $img; Dest = (New-Object System.Drawing.Rectangle(0, 0, $cw, $ch)) }
}

# One stretched copy of the theme photo at form client size. Rebuild only when size changes.
function Ensure-OuFormBgCache([switch]$Force) {
  if (-not $form -or -not $form.BackgroundImage) { return $null }
  $cw = [Math]::Max(1, $form.ClientSize.Width)
  $ch = [Math]::Max(1, $form.ClientSize.Height)
  if (-not $Force -and $script:OuFormBgCache -and -not $script:OuFormBgCache.Size.IsEmpty -and $script:OuFormBgCacheSize.Width -eq $cw -and $script:OuFormBgCacheSize.Height -eq $ch) {
    return $script:OuFormBgCache
  }
  $old = $script:OuFormBgCache
  $bmp = New-Object System.Drawing.Bitmap($cw, $ch, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try {
    $g.Clear([System.Drawing.Color]$script:OuClearBg)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
    $g.DrawImage($form.BackgroundImage, (New-Object System.Drawing.Rectangle(0, 0, $cw, $ch)))
  } finally { $g.Dispose() }
  $script:OuFormBgCache = $bmp
  $script:OuFormBgCacheSize = New-Object System.Drawing.Size($cw, $ch)
  if ($old) { try { $old.Dispose() } catch { } }
  return $script:OuFormBgCache
}

function Draw-OuFormBgInControl([System.Windows.Forms.Control]$ctrl, [System.Drawing.Graphics]$g) {
  # Blit the cached Stretch-filled form photo into this control's client area.
  if (-not $form -or -not $form.IsHandleCreated -or -not $ctrl.IsHandleCreated) { return }
  $g.Clear([System.Drawing.Color]$script:OuClearBg)
  $cache = Ensure-OuFormBgCache
  if (-not $cache) { return }
  $origin = $form.PointToClient($ctrl.PointToScreen([System.Drawing.Point]::Empty))
  $cw = $ctrl.ClientSize.Width
  $ch = $ctrl.ClientSize.Height
  if ($cw -le 0 -or $ch -le 0) { return }
  $src = New-Object System.Drawing.Rectangle($origin.X, $origin.Y, $cw, $ch)
  $cacheRect = New-Object System.Drawing.Rectangle(0, 0, $cache.Width, $cache.Height)
  $hit = [System.Drawing.Rectangle]::Intersect($src, $cacheRect)
  if ($hit.Width -le 0 -or $hit.Height -le 0) { return }
  $dx = $hit.X - $origin.X
  $dy = $hit.Y - $origin.Y
  $dst = New-Object System.Drawing.Rectangle($dx, $dy, $hit.Width, $hit.Height)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
  $g.DrawImage($cache, $dst, $hit, [System.Drawing.GraphicsUnit]::Pixel)
}

# BackgroundImage composite for PictureBox: form photo + alpha under the Image (letterbox shows glass).
function Update-OuGlassBackgroundImage([System.Windows.Forms.Control]$c, [int]$alpha, [switch]$Force) {
  if (-not $c -or $c.IsDisposed) { return }
  if (-not $c.IsHandleCreated) { return }
  if (-not $form -or -not $form.IsHandleCreated -or -not $form.BackgroundImage) { return }
  $w = [Math]::Max(1, $c.ClientSize.Width)
  $h = [Math]::Max(1, $c.ClientSize.Height)
  if (-not $Force -and $c.BackgroundImage -and $c.BackgroundImage.Width -eq $w -and $c.BackgroundImage.Height -eq $h) { return }
  $bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try {
    Draw-OuFormBgInControl $c $g
    $rgb = $script:Theme.GlassRGB
    $br = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($alpha, $rgb[0], $rgb[1], $rgb[2]))
    $g.FillRectangle($br, 0, 0, $w, $h)
    $br.Dispose()
  } finally { $g.Dispose() }
  $old = $c.BackgroundImage
  $c.BackgroundImage = $bmp
  $c.BackgroundImageLayout = 'None'
  if ($old) { try { $old.Dispose() } catch { } }
}

# Light glass fill for a rect inside a control (catalog rows / content surfaces).
function Draw-OuContentGlass([System.Windows.Forms.Control]$ctrl, [System.Drawing.Graphics]$g, [System.Drawing.Rectangle]$bounds, [int]$alpha = -1) {
  if ($alpha -lt 0) { $alpha = [int]$script:Theme.GlassAlphaPreview }
  if ($bounds.Width -le 0 -or $bounds.Height -le 0) { return }
  $state = $g.Save()
  try {
    $g.SetClip($bounds)
    $g.Clear([System.Drawing.Color]$script:OuClearBg)
    $cache = Ensure-OuFormBgCache
    if ($cache -and $form -and $form.IsHandleCreated -and $ctrl.IsHandleCreated) {
      $origin = $form.PointToClient($ctrl.PointToScreen([System.Drawing.Point]::Empty))
      $src = New-Object System.Drawing.Rectangle(($origin.X + $bounds.X), ($origin.Y + $bounds.Y), $bounds.Width, $bounds.Height)
      $cacheRect = New-Object System.Drawing.Rectangle(0, 0, $cache.Width, $cache.Height)
      $hit = [System.Drawing.Rectangle]::Intersect($src, $cacheRect)
      if ($hit.Width -gt 0 -and $hit.Height -gt 0) {
        $dx = $hit.X - $origin.X
        $dy = $hit.Y - $origin.Y
        $dst = New-Object System.Drawing.Rectangle($dx, $dy, $hit.Width, $hit.Height)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
        $g.DrawImage($cache, $dst, $hit, [System.Drawing.GraphicsUnit]::Pixel)
      }
    }
    $rgb = $script:Theme.GlassRGB
    $br = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($alpha, $rgb[0], $rgb[1], $rgb[2]))
    $g.FillRectangle($br, $bounds)
    $br.Dispose()
  } finally { $g.Restore($state) }
}

function Invalidate-OuGlass([switch]$ForceBg) {
  if ($script:OuGlassSyncBusy) { return }
  $script:OuGlassSyncBusy = $true
  try {
    if ($ForceBg) { [void](Ensure-OuFormBgCache -Force) } else { [void](Ensure-OuFormBgCache) }
    foreach ($c in @($script:OuGlassHooked)) {
      try { if ($c -and -not $c.IsDisposed) { $c.Invalidate() } } catch { }
    }
    # Always rebuild catalog/preview composites: panel origin in form can change without client size change (splitters).
    if ($script:OuPreviewSurface -and -not $script:OuPreviewSurface.IsDisposed) {
      Update-OuGlassBackgroundImage $script:OuPreviewSurface ([int]$script:Theme.GlassAlphaPreview) -Force
    }
    if ($script:OuCatalogSurface -and -not $script:OuCatalogSurface.IsDisposed) {
      Update-OuGlassBackgroundImage $script:OuCatalogSurface ([int]$script:Theme.GlassAlphaPreview) -Force
    }
  } finally {
    $script:OuGlassSyncBusy = $false
  }
}

# Debounce form/splitter glass refresh so drag/resize does not full-blit every pixel.
function Request-OuGlassRefresh([switch]$ForceBg) {
  if (-not $script:OuGlassResizeTimer) {
    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = 75
    $t.Add_Tick({
      param($sender, $e)
      try {
        $sender.Stop()
        $force = [bool]$script:OuGlassRefreshForce
        $script:OuGlassRefreshForce = $false
        # Only dirty the stretched form-bg cache when the form size changed (ForceBg).
        if ($force) { $script:OuFormBgCacheSize = New-Object System.Drawing.Size(0, 0) }
        Invalidate-OuGlass -ForceBg:$force
      } catch { }
    })
    $script:OuGlassResizeTimer = $t
  }
  if ($ForceBg) { $script:OuGlassRefreshForce = $true }
  $script:OuGlassResizeTimer.Stop()
  $script:OuGlassResizeTimer.Start()
}

# ---------- Background rotation (lazy decode + small cache, never blocks the UI) ----------
# Decode = read file bytes, then copy into a premultiplied bitmap so painting never has to decode again.
$script:OuBgDecodeScript = {
  param([string]$path)
  $bytes = [IO.File]::ReadAllBytes($path)
  $ms = New-Object IO.MemoryStream(,$bytes)
  try {
    $src = [System.Drawing.Image]::FromStream($ms)
    try {
      $bmp = New-Object System.Drawing.Bitmap($src.Width, $src.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
      $g = [System.Drawing.Graphics]::FromImage($bmp)
      try { $g.DrawImage($src, 0, 0, $src.Width, $src.Height) } finally { $g.Dispose() }
      , $bmp
    } finally { $src.Dispose() }
  } finally { $ms.Dispose() }
}
$script:OuBgIndex = 0          # photo on screen
$script:OuBgWanted = -1        # photo waiting for its decode (-1 = none)
$script:OuBgCache = @{}        # path -> decoded Bitmap (current, wanted and next only)
$script:OuBgBad = @{}          # path -> $true when missing/unreadable (skipped)
$script:OuBgJob = $null        # @{ Path; Ps; Iar } one background decode at a time
$script:OuBgRs = $null
$script:OuBgTimer = $null
$script:OuBgSwaps = 0

function Test-OuBgUsable([int]$i) {
  if ($i -lt 0 -or $i -ge $script:ThemeBgPaths.Count) { return $false }
  $p = [string]$script:ThemeBgPaths[$i]
  if ($script:OuBgBad.ContainsKey($p)) { return $false }
  if ($script:OuBgCache.ContainsKey($p)) { return $true }
  if (-not [IO.File]::Exists($p)) { $script:OuBgBad[$p] = $true; return $false }
  return $true
}

function Get-OuBgNextIndex([int]$from) {
  $n = $script:ThemeBgPaths.Count
  for ($k = 1; $k -le $n; $k++) {
    $i = ($from + $k) % $n
    if (Test-OuBgUsable $i) { return $i }
  }
  return -1
}

function Get-OuBgRunspace {
  $rs = $script:OuBgRs
  if ($rs) {
    $st = $rs.RunspaceStateInfo.State
    if ($st -eq 'Opened' -or $st -eq 'Opening' -or $st -eq 'BeforeOpen') { return $rs }
    try { $rs.Dispose() } catch { }
  }
  $rs = [runspacefactory]::CreateRunspace()
  $rs.ApartmentState = 'MTA'
  $rs.OpenAsync()   # opens off the UI thread; decodes start once it is Opened
  $script:OuBgRs = $rs
  return $rs
}

function Start-OuBgDecode([int]$i) {
  if ($script:OuBgJob) { return $false }
  if (-not (Test-OuBgUsable $i)) { return $false }
  $p = [string]$script:ThemeBgPaths[$i]
  if ($script:OuBgCache.ContainsKey($p)) { return $false }
  try {
    $rs = Get-OuBgRunspace
    if ($rs.RunspaceStateInfo.State -ne 'Opened') { return $true }   # still opening: timer retries
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:OuBgDecodeScript).AddArgument($p)
    $script:OuBgJob = @{ Path = $p; Ps = $ps; Iar = $ps.BeginInvoke() }
  } catch {
    # No background runspace: decode now (one photo, only when it is actually needed)
    try { $script:OuBgCache[$p] = & $script:OuBgDecodeScript $p } catch { $script:OuBgBad[$p] = $true }
  }
  return $true
}

function Complete-OuBgDecode {
  $j = $script:OuBgJob
  if (-not $j -or -not $j.Iar.IsCompleted) { return }
  $script:OuBgJob = $null
  $bmp = $null
  try {
    $out = $j.Ps.EndInvoke($j.Iar)
    foreach ($x in @($out)) { if ($x -is [System.Drawing.Image]) { $bmp = [System.Drawing.Image]$x } }
  } catch { $bmp = $null }
  try { $j.Ps.Dispose() } catch { }
  if ($bmp) { $script:OuBgCache[$j.Path] = $bmp } else { $script:OuBgBad[$j.Path] = $true }
}

function Trim-OuBgCache {
  $keep = @{}
  foreach ($i in @($script:OuBgIndex, $script:OuBgWanted, (Get-OuBgNextIndex $script:OuBgIndex))) {
    if ($i -ge 0 -and $i -lt $script:ThemeBgPaths.Count) { $keep[[string]$script:ThemeBgPaths[$i]] = $true }
  }
  foreach ($p in @($script:OuBgCache.Keys)) {
    if ($keep.ContainsKey($p)) { continue }
    $img = $script:OuBgCache[$p]
    if ($form -and [object]::ReferenceEquals($form.BackgroundImage, $img)) { continue }
    $script:OuBgCache.Remove($p)
    try { $img.Dispose() } catch { }
  }
}

function Apply-OuBackground([int]$i) {
  $p = [string]$script:ThemeBgPaths[$i]
  $img = $script:OuBgCache[$p]
  if (-not $img -or -not $form -or $form.IsDisposed) { return }
  $script:OuBgIndex = $i
  $script:OuBgWanted = -1
  $script:ThemeBgImage = $img
  $script:ThemeBgPath = $p
  $form.BackgroundImage = $img
  $form.BackgroundImageLayout = 'Stretch'
  $script:OuBgSwaps++
  # Same glass path as a resize: rebuild the one stretched copy, repaint glass panels + composites.
  Invalidate-OuGlass -ForceBg
  try { $form.Invalidate($true) } catch { }
  Trim-OuBgCache
}

function Invoke-OuBgTick {
  Complete-OuBgDecode
  $w = $script:OuBgWanted
  if ($w -ge 0) {
    if (-not (Test-OuBgUsable $w)) { $script:OuBgWanted = Get-OuBgNextIndex $w; if ($script:OuBgWanted -eq $script:OuBgIndex) { $script:OuBgWanted = -1 }; return }
    if ($script:OuBgCache.ContainsKey([string]$script:ThemeBgPaths[$w])) { Apply-OuBackground $w; return }
    [void](Start-OuBgDecode $w)
    return
  }
  if ($script:OuBgJob) { return }
  # Idle: prefetch the next photo so the next tab change swaps instantly
  $nx = Get-OuBgNextIndex $script:OuBgIndex
  if ($nx -ge 0 -and $nx -ne $script:OuBgIndex -and (Start-OuBgDecode $nx)) { return }
  if ($script:OuBgTimer) { $script:OuBgTimer.Stop() }
}

function Start-OuBgTimer {
  if (-not $script:OuBgTimer) {
    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = 60
    $t.Add_Tick({ try { Invoke-OuBgTick } catch { } })
    $script:OuBgTimer = $t
  }
  $script:OuBgTimer.Start()
}

# Called once per top-tab / side-tab change.
function Step-OuBackground {
  try {
    if (-not $form -or $form.IsDisposed -or $script:ThemeBgPaths.Count -lt 2) { return }
    $from = $(if ($script:OuBgWanted -ge 0) { $script:OuBgWanted } else { $script:OuBgIndex })
    $nx = Get-OuBgNextIndex $from
    if ($nx -lt 0 -or $nx -eq $script:OuBgIndex) { $script:OuBgWanted = -1; return }
    if ($script:OuBgCache.ContainsKey([string]$script:ThemeBgPaths[$nx])) { Apply-OuBackground $nx }
    else { $script:OuBgWanted = $nx }
    Start-OuBgTimer
  } catch { }
}

# Nested panels cannot see form BackgroundImage through opaque SplitContainer ancestors.
# Fix: each glass panel paints the form photo cropped to its bounds, then GlassAlpha dark overlay.
function Enable-OuGlass([System.Windows.Forms.Control]$c, [int]$alpha = -1) {
  if ($alpha -lt 0) { $alpha = [int]$script:Theme.GlassAlpha }
  Set-OuDoubleBuffer $c -OpaquePaint
  $c.BackgroundImage = $null
  $c.BackColor = $script:Theme.PanelDeep
  $script:OuGlassAlpha[$c] = $alpha
  if ($script:OuGlassHooked.Contains($c)) { return }
  [void]$script:OuGlassHooked.Add($c)
  $c.Add_Paint({
    param($sender, $e)
    Draw-OuFormBgInControl $sender $e.Graphics
    $a = [int]$script:Theme.GlassAlpha
    if ($script:OuGlassAlpha.ContainsKey($sender)) { $a = [int]$script:OuGlassAlpha[$sender] }
    $rgb = $script:Theme.GlassRGB
    $br = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($a, $rgb[0], $rgb[1], $rgb[2]))
    $e.Graphics.FillRectangle($br, $sender.ClientRectangle)
    $br.Dispose()
  })
  # Local invalidate only - never cascade Invalidate-OuGlass from child resize (was full UI flash).
  $c.Add_Resize({
    param($sender, $e)
    try { $sender.Invalidate() } catch { }
  })
}
function Set-OuSeeThroughHost([System.Windows.Forms.Control]$c) {
  Set-OuDoubleBuffer $c
  $c.BackgroundImage = $null
  $c.BackColor = [System.Drawing.Color]::Transparent
}

function Set-OuSecondaryButton([System.Windows.Forms.Button]$b) {
  $b.FlatStyle = 'Flat'
  $b.FlatAppearance.BorderSize = 1
  $b.FlatAppearance.BorderColor = $script:Theme.ButtonBorder
  $b.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(60, 60, 66)
  $b.FlatAppearance.MouseDownBackColor = $script:Theme.AccentDark
  $b.BackColor = $script:Theme.ButtonFace
  $b.ForeColor = $script:Theme.Text
  $b.UseVisualStyleBackColor = $false
}

function Set-OuPrimaryButton([System.Windows.Forms.Button]$b) {
  $b.FlatStyle = 'Flat'
  $b.FlatAppearance.BorderSize = 0
  $b.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(240, 50, 55)
  $b.FlatAppearance.MouseDownBackColor = $script:Theme.AccentDark
  $b.BackColor = $script:Theme.Accent
  $b.ForeColor = $script:Theme.Text
  $b.UseVisualStyleBackColor = $false
  $b.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
}

function Set-OuNavIdle([System.Windows.Forms.Button]$b) {
  $b.FlatStyle = 'Flat'
  $b.FlatAppearance.BorderSize = 0
  $b.BackColor = [System.Drawing.Color]::Transparent
  $b.ForeColor = $script:Theme.TextMuted
  $b.UseVisualStyleBackColor = $false
  $b.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
}

function Set-OuNavSelected([System.Windows.Forms.Button]$b) {
  $b.FlatStyle = 'Flat'
  $b.FlatAppearance.BorderSize = 0
  $b.BackColor = $script:Theme.AccentSoft
  $b.ForeColor = $script:Theme.Text
  $b.UseVisualStyleBackColor = $false
  $b.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
}

function Set-OuRailIdle([System.Windows.Forms.Button]$b) {
  Set-OuSecondaryButton $b
  $b.FlatAppearance.BorderSize = 0
  $b.BackColor = [System.Drawing.Color]::Transparent
  $b.TextAlign = 'MiddleLeft'
}

if (-not $script:OuRailPaintHooked) { $script:OuRailPaintHooked = New-Object 'System.Collections.Generic.HashSet[object]' }
function Set-OuRailSelected([System.Windows.Forms.Button]$b) {
  $b.FlatStyle = 'Flat'
  $b.FlatAppearance.BorderSize = 0
  $b.BackColor = $script:Theme.AccentSoft
  $b.ForeColor = $script:Theme.Text
  $b.UseVisualStyleBackColor = $false
  if (-not $script:OuRailPaintHooked.Contains($b)) {
    [void]$script:OuRailPaintHooked.Add($b)
    $b.Add_Paint({
      param($sender, $e)
      if ($sender.BackColor.ToArgb() -eq $script:Theme.AccentSoft.ToArgb()) {
        $br = New-Object System.Drawing.SolidBrush ($script:Theme.Accent)
        $e.Graphics.FillRectangle($br, 0, 4, 3, $sender.ClientSize.Height - 8)
        $br.Dispose()
      }
    })
  }
}

function Set-OuDarkInput([System.Windows.Forms.Control]$c) {
  $c.BackColor = $script:Theme.PanelOpaque
  $c.ForeColor = $script:Theme.Text
  if ($c -is [System.Windows.Forms.TextBox]) { $c.BorderStyle = 'FixedSingle' }
  if ($c -is [System.Windows.Forms.ListView]) {
    $c.BackColor = $script:Theme.PanelOpaque
    $c.ForeColor = $script:Theme.Text
    $c.GridLines = $false
    $c.BorderStyle = 'FixedSingle'
  }
  if ($c -is [System.Windows.Forms.ListBox] -or $c -is [System.Windows.Forms.CheckedListBox]) {
    $c.BackColor = $script:Theme.PanelOpaque
    $c.ForeColor = $script:Theme.Text
    $c.BorderStyle = 'FixedSingle'
  }
  if ($c -is [System.Windows.Forms.ComboBox]) {
    $c.BackColor = $script:Theme.PanelOpaque
    $c.ForeColor = $script:Theme.Text
    $c.FlatStyle = 'Flat'
  }
}

# Solid near-opaque surface for children that cover heavy glass cards (list/pic/inputs).
function Set-OuHeavySurface([System.Windows.Forms.Control]$c) {
  $c.BackColor = $script:Theme.PanelHeavy
  try { $c.ForeColor = $script:Theme.Text } catch { }
}


function Set-OuLabel([System.Windows.Forms.Label]$l, [switch]$Muted) {
  $l.BackColor = [System.Drawing.Color]::Transparent
  $l.ForeColor = if ($Muted) { $script:Theme.TextMuted } else { $script:Theme.Text }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Open Unleashed Pak Fixer'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(1100, 720)
$form.MinimumSize = New-Object System.Drawing.Size(900, 580)
$form.BackColor = $script:Theme.PanelDeep
Set-OuFormIcon $form
# Full-bleed OU photo behind translucent cards
# Launch photo (random pick) decodes now; the rest decode in the background only when needed.
$script:ThemeBgImage = $null
$script:OuBgStart = $(if ($script:ThemeBgPaths.Count -gt 1) { Get-Random -Minimum 0 -Maximum $script:ThemeBgPaths.Count } else { 0 })
for ($bk = 0; $bk -lt $script:ThemeBgPaths.Count -and -not $script:ThemeBgImage; $bk++) {
  $bi = ($script:OuBgStart + $bk) % $script:ThemeBgPaths.Count   # missing/unreadable pick -> try the next one
  if (-not (Test-OuBgUsable $bi)) { continue }
  $bp = [string]$script:ThemeBgPaths[$bi]
  try {
    $script:OuBgCache[$bp] = & $script:OuBgDecodeScript $bp
    $script:ThemeBgImage = $script:OuBgCache[$bp]
    $script:ThemeBgPath = $bp
    $script:OuBgIndex = $bi
    $form.BackgroundImage = $script:ThemeBgImage
    $form.BackgroundImageLayout = 'Stretch'
  } catch { $script:OuBgBad[$bp] = $true; $script:ThemeBgImage = $null }
}
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

# Top: game path
$top = New-Object System.Windows.Forms.Panel
$top.Dock = 'Top'
$top.Height = 48
$top.Name = 'top'
Enable-OuGlass $top ([int]$script:Theme.GlassAlphaHeavy)
$form.Controls.Add($top)

$lblFolder = New-Object System.Windows.Forms.Label
$lblFolder.Text = 'Game folder'
$lblFolder.AutoSize = $true
$lblFolder.Location = New-Object System.Drawing.Point(12, 15)
Set-OuLabel $lblFolder
$top.Controls.Add($lblFolder)

$txtGame = New-Object System.Windows.Forms.TextBox
$txtGame.ReadOnly = $true
$txtGame.Location = New-Object System.Drawing.Point(100, 12)
$txtGame.Width = 860
$txtGame.Anchor = 'Top,Left,Right'
Set-OuDarkInput $txtGame
$top.Controls.Add($txtGame)

$btnChange = New-Object System.Windows.Forms.Button
$btnChange.Text = 'Change'
$btnChange.Width = 90
$btnChange.Height = 28
$btnChange.Location = New-Object System.Drawing.Point(980, 10)
$btnChange.Anchor = 'Top,Right'
Set-OuSecondaryButton $btnChange
$top.Controls.Add($btnChange)

# Top nav bar (under game path)
$navBar = New-Object System.Windows.Forms.Panel
$navBar.Dock = 'Top'
$navBar.Height = 42
$navBar.Name = 'navBar'
Enable-OuGlass $navBar
$form.Controls.Add($navBar)

$navNames = @('PACK MANAGER','GALLERY','SETTINGS','ABOUT')
$navButtons = @{}
$navFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$navFlow.Dock = 'Fill'
$navFlow.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 6)
$navFlow.WrapContents = $false
$navBar.Controls.Add($navFlow)

foreach ($n in $navNames) {
  $b = New-Object System.Windows.Forms.Button
  $b.Text = $n
  $b.AutoSize = $true
  $b.Height = 28
  $b.FlatStyle = 'Flat'
  $b.FlatAppearance.BorderSize = 0
  $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 6, 0)
  $b.Padding = New-Object System.Windows.Forms.Padding(10, 0, 10, 0)
  Set-OuNavIdle $b
  $b.Tag = $n
  [void]$navFlow.Controls.Add($b)
  $navButtons[$n] = $b
}

# Status
$status = New-Object System.Windows.Forms.StatusStrip
$status.BackColor = $script:Theme.PanelOpaque
$status.ForeColor = $script:Theme.Text
$status.SizingGrip = $false
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Spring = $true
$statusLabel.TextAlign = 'MiddleLeft'
$statusLabel.Text = 'Ready'
$statusLabel.ForeColor = $script:Theme.Text
[void]$status.Items.Add($statusLabel)
$form.Controls.Add($status)
function Set-Status([string]$t) { $statusLabel.Text = $t }

# Body: left rail + content
$body = New-Object System.Windows.Forms.Panel
$body.Dock = 'Fill'
Set-OuSeeThroughHost $body
$form.Controls.Add($body)
$body.BringToFront()
$navBar.SendToBack()
$top.SendToBack()

# Resizable: left rail | content (drag divider)
$bodySplit = New-Object System.Windows.Forms.SplitContainer
$bodySplit.Dock = 'Fill'
$bodySplit.Orientation = 'Vertical'
$bodySplit.SplitterWidth = 6
$bodySplit.FixedPanel = 'None'
$bodySplit.BackColor = $script:Theme.Splitter
Set-OuSeeThroughHost $bodySplit.Panel1
Set-OuSeeThroughHost $bodySplit.Panel2
$bodySplit.Add_SplitterMoved({ Request-OuGlassRefresh })
$body.Controls.Add($bodySplit)

$leftRail = New-Object System.Windows.Forms.Panel
$leftRail.Dock = 'Fill'
$leftRail.Name = 'leftRail'
Enable-OuGlass $leftRail ([int]$script:Theme.GlassAlphaPreview)
$bodySplit.Panel1.Controls.Add($leftRail)

$hostPanel = New-Object System.Windows.Forms.Panel
$hostPanel.Dock = 'Fill'
$hostPanel.Padding = New-Object System.Windows.Forms.Padding(10)
Set-OuSeeThroughHost $hostPanel
$bodySplit.Panel2.Controls.Add($hostPanel)

function New-ActionButton([string]$text, [int]$width = 110) {
  # $width kept for call compatibility; buttons stretch inside New-ButtonTable
  $b = New-Object System.Windows.Forms.Button
  $b.Text = $text
  $b.Height = 32
  $b.MinimumSize = New-Object System.Drawing.Size(72, 32)
  $b.AutoEllipsis = $true
  $b.Dock = 'Fill'
  $b.Margin = New-Object System.Windows.Forms.Padding(2, 0, 2, 0)
  Set-OuSecondaryButton $b
  $b
}

function New-ButtonTable([System.Windows.Forms.Control[]]$buttons) {
  $t = New-Object System.Windows.Forms.TableLayoutPanel
  $t.Height = 40
  $t.Padding = New-Object System.Windows.Forms.Padding(4)
  $t.RowCount = 1
  $t.ColumnCount = $buttons.Count
  [void]$t.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
  $pct = [single](100.0 / [Math]::Max(1, $buttons.Count))
  for ($i = 0; $i -lt $buttons.Count; $i++) {
    [void]$t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, $pct)))
    $t.Controls.Add($buttons[$i], $i, 0)
  }
  ,$t
}

function Set-ButtonRow([System.Windows.Forms.TableLayoutPanel]$table, [System.Windows.Forms.Control[]]$buttons) {
  # Rebuild equal-width columns with only the buttons this source needs (no empty gaps).
  $table.SuspendLayout()
  try {
    $table.Controls.Clear()
    $table.ColumnStyles.Clear()
    $n = [Math]::Max(1, @($buttons).Count)
    $table.ColumnCount = $n
    $pct = [single](100.0 / $n)
    for ($i = 0; $i -lt @($buttons).Count; $i++) {
      $b = $buttons[$i]
      $b.Visible = $true
      [void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, $pct)))
      $table.Controls.Add($b, $i, 0)
    }
  } finally {
    $table.ResumeLayout()
  }
}

function Clear-LeftRail {
  $leftRail.Controls.Clear()
}

# ---------- tab state ----------
# Each page's left-rail controls are built once and parked here when the user switches away
# (Controls.Clear() detaches, it does not dispose), then re-attached on return so filters, search text,
# source toggle, checkboxes and rail scroll stay exactly as left. Pages only reload when pack data changed.
$script:RailCache = @{}        # rail key -> @{ Controls = Control[]; Scroll = @{ control -> Point } }
$script:RailCacheExtra = @{}   # rail key -> page globals that belong to that rail (e.g. gallery sub buttons)
$script:LeftRailKey = $null    # key of the controls currently in $leftRail
$script:CatalogDirty = $true   # PACK MANAGER rows need a rescan (Add/Remove/Fix/previews/game folder)
$script:CatalogBuiltSource = $null
$script:ShowroomDirty = $false # Showroom results need a rebuild on return (only matters after a Search)
$script:ViewState = @{}        # page scroll / top-row memory

function Get-OuScrollPos([System.Windows.Forms.Control]$c) {
  try {
    if (-not $c -or $c.IsDisposed) { return $null }
    $p = $c.AutoScrollPosition
    return (New-Object System.Drawing.Point((-$p.X), (-$p.Y)))
  } catch { return $null }
}
function Set-OuScrollPos([System.Windows.Forms.Control]$c, $pt) {
  if (-not $c -or $c.IsDisposed -or $null -eq $pt) { return }
  try { $c.PerformLayout(); $c.AutoScrollPosition = [System.Drawing.Point]$pt } catch { }
}

function Save-LeftRail {
  $k = $script:LeftRailKey
  if (-not $k) { return }
  $ctrls = New-Object System.Collections.Generic.List[System.Windows.Forms.Control]
  $scroll = @{}
  foreach ($c in $leftRail.Controls) {
    $ctrls.Add($c)
    if ($c -is [System.Windows.Forms.ScrollableControl] -and $c.AutoScroll) { $scroll[$c] = Get-OuScrollPos $c }
  }
  $script:RailCache[$k] = @{ Controls = $ctrls.ToArray(); Scroll = $scroll }
}

function Switch-LeftRail([string]$key) {
  # Returns $true when the rail for $key was restored from cache (caller skips its builder).
  if ($script:LeftRailKey -eq $key -and $leftRail.Controls.Count -gt 0) { return $true }
  Save-LeftRail
  $entry = $null
  if ($script:RailCache.ContainsKey($key)) { $entry = $script:RailCache[$key] }
  $restored = $false
  $leftRail.SuspendLayout()
  try {
    $leftRail.Controls.Clear()
    $script:LeftRailKey = $key
    if ($entry -and $entry.Controls -and $entry.Controls.Count) {
      $alive = @($entry.Controls | Where-Object { $_ -and -not $_.IsDisposed })
      if ($alive.Count -eq $entry.Controls.Count) {
        $leftRail.Controls.AddRange([System.Windows.Forms.Control[]]$alive)
        $restored = $true
      }
    }
  } finally { $leftRail.ResumeLayout($true) }
  if ($restored) {
    foreach ($c in @($entry.Scroll.Keys)) { Set-OuScrollPos $c $entry.Scroll[$c] }
  } else {
    [void]$script:RailCache.Remove($key)
  }
  return $restored
}

function Set-PackDataChanged {
  # Anything that adds/removes/fixes packs, makes/deletes previews or changes the game folder.
  $script:CatalogDirty = $true
  $script:ShowroomDirty = $true
}

function Save-ViewState {
  # Remember scroll / top row of the page being left (handles survive Visible=false, this is a safety net).
  try {
    switch ($script:CurrentPage) {
      'PACK MANAGER' {
        if ($lstCatalog.IsHandleCreated -and $lstCatalog.Items.Count -gt 0 -and $lstCatalog.TopItem) { $script:ViewState['CatalogTop'] = [string]$lstCatalog.TopItem.Tag }
      }
      'GALLERY' {
        if ($script:ManageSub -eq 'Showroom' -and $showCardFlow) { $script:ViewState['ShowroomScroll'] = Get-OuScrollPos $showCardFlow }
      }
      'SETTINGS' { if ($settingsFlow) { $script:ViewState['SettingsScroll'] = Get-OuScrollPos $settingsFlow } }
    }
  } catch { }
}

function Restore-CatalogTop {
  try {
    $want = [string]$script:ViewState['CatalogTop']
    if (-not $want -or $lstCatalog.Items.Count -eq 0 -or -not $lstCatalog.IsHandleCreated) { return }
    if ($lstCatalog.TopItem -and [string]$lstCatalog.TopItem.Tag -eq $want) { return }
    $script:SuppressCheck = $true
    foreach ($ti in $lstCatalog.Items) {
      if ([string]$ti.Tag -eq $want) { $lstCatalog.TopItem = $ti; break }
    }
  } catch { } finally { $script:SuppressCheck = $false }
}

function Add-RailHeader([string]$text) {
  $l = New-Object System.Windows.Forms.Label
  $l.Text = $text
  $l.Dock = 'Top'
  $l.Height = 28
  $l.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
  $l.Padding = New-Object System.Windows.Forms.Padding(10, 8, 0, 0)
  Set-OuLabel $l
  $leftRail.Controls.Add($l)
  $l.BringToFront()
  return $l
}

function Add-RailButton([string]$text, [string]$tag) {
  $b = New-Object System.Windows.Forms.Button
  $b.Text = $text
  $b.Dock = 'Top'
  $b.Height = 34
  $b.TextAlign = 'MiddleLeft'
  $b.Padding = New-Object System.Windows.Forms.Padding(12, 0, 0, 0)
  Set-OuRailIdle $b
  $b.Tag = $tag
  $leftRail.Controls.Add($b)
  $b.BringToFront()
  $b
}

# ==================== PACK MANAGER (catalog) ====================
$pnlFix = New-Object System.Windows.Forms.Panel
$pnlFix.Dock = 'Fill'
Set-OuSeeThroughHost $pnlFix
$pnlFix.Visible = $false
$hostPanel.Controls.Add($pnlFix)

# Selected tray (bottom of PACK MANAGER)
$selTray = New-Object System.Windows.Forms.Panel
$selTray.Dock = 'Bottom'
$selTray.Height = 110
$selTray.Name = 'selTray'
Enable-OuGlass $selTray ([int]$script:Theme.GlassAlphaHeavy)
$pnlFix.Controls.Add($selTray)

$lblSelTitle = New-Object System.Windows.Forms.Label
$lblSelTitle.Text = 'Selected packs'
Set-OuLabel $lblSelTitle
$lblSelTitle.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$lblSelTitle.AutoSize = $true
$lblSelTitle.Location = New-Object System.Drawing.Point(4, 4)
$selTray.Controls.Add($lblSelTitle)

# Glass host (ListBox ignores BackgroundImage; empty client was solid PanelDeep). Host=155; list height tracks items.
$selListHost = New-Object System.Windows.Forms.Panel
$selListHost.Location = New-Object System.Drawing.Point(4, 26)
$selListHost.Size = New-Object System.Drawing.Size(700, 50)
$selListHost.Anchor = 'Top,Left,Right,Bottom'
$selListHost.Name = 'selListHost'
Enable-OuGlass $selListHost ([int]$script:Theme.GlassAlphaPreview)
$script:OuSelectedSurface = $selListHost
$selTray.Controls.Add($selListHost)

$lstSelected = New-Object System.Windows.Forms.ListBox
$lstSelected.Dock = 'Top'
$lstSelected.IntegralHeight = $true
$lstSelected.Name = 'lstSelected'
$lstSelected.BorderStyle = 'None'
$lstSelected.ForeColor = $script:Theme.Text
$lstSelected.BackColor = $script:Theme.PanelDeep
$lstSelected.DrawMode = 'OwnerDrawFixed'
$lstSelected.ItemHeight = 18
$lstSelected.Height = 0
$lstSelected.Add_DrawItem({
  param($s, $e)
  if ($e.Index -lt 0) { return }
  Draw-OuContentGlass $selListHost $e.Graphics $e.Bounds ([int]$script:Theme.GlassAlphaPreview)
  if (($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0) {
    $ab = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(210, $script:Theme.Accent.R, $script:Theme.Accent.G, $script:Theme.Accent.B))
    $e.Graphics.FillRectangle($ab, $e.Bounds)
    $ab.Dispose()
  }
  $text = [string]$lstSelected.Items[$e.Index]
  [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $text, $lstSelected.Font, $e.Bounds, $script:Theme.Text,
    [System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix)
})
$selListHost.Controls.Add($lstSelected)

function Sync-SelectedListHeight {
  if (-not $lstSelected -or -not $selListHost) { return }
  $n = $lstSelected.Items.Count
  $maxH = [Math]::Max(0, $selListHost.ClientSize.Height)
  if ($n -le 0) { $lstSelected.Height = 0; return }
  $lstSelected.Height = [Math]::Min($maxH, $n * [Math]::Max(1, $lstSelected.ItemHeight))
}
$selListHost.Add_Resize({ Sync-SelectedListHeight })

# ---------- PACK MANAGER bottom bar: actions on the left, Open (menu) + Refresh on the right ----------
# One "Fix selected" button: Broken = old Run fixer (Yes/No/Cancel), Installed = old Fix Broken. Legacy names alias it.
$btnFixSelected = New-ActionButton 'Fix selected' 100
$btnFixSelected.Name = 'btnFixSelected'
$btnRunFixer = $btnFixSelected
$btnMgrFix = $btnFixSelected
$btnMgrAddDisk = New-ActionButton 'Add from disk' 112
$btnMgrAdd = New-ActionButton 'Install selected' 120
$btnMgrRemove = New-ActionButton 'Remove' 80
$btnPmOpen = New-ActionButton ('Open ' + [char]0x25BE) 84
$btnPmOpen.Name = 'btnPmOpen'
$btnRefreshBroken = New-ActionButton '' 36
$btnRefreshBroken.Name = 'btnPmRefresh'
$btnRefreshBroken.AccessibleName = 'Refresh'
$btnRefreshBroken.MinimumSize = New-Object System.Drawing.Size(30, 32)
$btnRefreshBroken.Image = $script:IconRefresh
$btnRefreshBroken.ImageAlign = 'MiddleCenter'
$script:PmBtnWidth = @{}
$script:PmBtnWidth[$btnFixSelected] = 100; $script:PmBtnWidth[$btnMgrAddDisk] = 112; $script:PmBtnWidth[$btnMgrAdd] = 120; $script:PmBtnWidth[$btnMgrRemove] = 80
$script:PmRowLeft = @()

$fixBtnRow = New-Object System.Windows.Forms.TableLayoutPanel
$fixBtnRow.Name = 'fixBtnRow'
$fixBtnRow.Height = 40
$fixBtnRow.Padding = New-Object System.Windows.Forms.Padding(2, 2, 2, 2)
$fixBtnRow.RowCount = 1
[void]$fixBtnRow.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$fixBtnRow.Dock = 'Bottom'
$pnlFix.Controls.Add($fixBtnRow)

function Set-PmBottomRowStyles {
  # Left actions keep their natural width with a flexible gap before Open/Refresh; if the pane gets too
  # narrow the gap collapses and the actions share the space instead (Open/Refresh never get pushed out).
  $left = @($script:PmRowLeft)
  $need = 8 + 84 + 36 + 8 + ($left.Count * 4)
  foreach ($b in $left) { $need += [int]$script:PmBtnWidth[$b] }
  $tight = ($fixBtnRow.ClientSize.Width -gt 0 -and $fixBtnRow.ClientSize.Width -lt $need)
  if ($fixBtnRow.ColumnStyles.Count -ne ($left.Count + 3)) { return }
  for ($i = 0; $i -lt $left.Count; $i++) {
    $cs = $fixBtnRow.ColumnStyles[$i]
    if ($tight) { $cs.SizeType = [System.Windows.Forms.SizeType]::Percent; $cs.Width = [single](100.0 / [Math]::Max(1, $left.Count)) }
    else { $cs.SizeType = [System.Windows.Forms.SizeType]::Absolute; $cs.Width = [single]$script:PmBtnWidth[$left[$i]] }
  }
  $gap = $fixBtnRow.ColumnStyles[$left.Count]
  if ($tight) { $gap.SizeType = [System.Windows.Forms.SizeType]::Absolute; $gap.Width = 0 }
  else { $gap.SizeType = [System.Windows.Forms.SizeType]::Percent; $gap.Width = 100 }
}

function Set-PmBottomRow([System.Windows.Forms.Control[]]$leftButtons) {
  $script:PmRowLeft = @($leftButtons)
  $fixBtnRow.SuspendLayout()
  try {
    $fixBtnRow.Controls.Clear()
    $fixBtnRow.ColumnStyles.Clear()
    $fixBtnRow.ColumnCount = $script:PmRowLeft.Count + 3
    $col = 0
    foreach ($b in $script:PmRowLeft) {
      $b.Visible = $true
      [void]$fixBtnRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, [single]$script:PmBtnWidth[$b])))
      $fixBtnRow.Controls.Add($b, $col, 0); $col++
    }
    [void]$fixBtnRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $col++
    [void]$fixBtnRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 84)))
    $fixBtnRow.Controls.Add($btnPmOpen, $col, 0); $col++
    [void]$fixBtnRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 36)))
    $fixBtnRow.Controls.Add($btnRefreshBroken, $col, 0)
    $btnPmOpen.Visible = $true; $btnRefreshBroken.Visible = $true
    Set-PmBottomRowStyles
  } finally { $fixBtnRow.ResumeLayout() }
}
$fixBtnRow.Add_Resize({ Set-PmBottomRowStyles })

$fixTop = New-Object System.Windows.Forms.Panel
$fixTop.Dock = 'Top'
$fixTop.Height = 36
$fixTop.Name = 'fixTop'
Enable-OuGlass $fixTop ([int]$script:Theme.GlassAlphaHeavy)
$pnlFix.Controls.Add($fixTop)

$lblFixTitle = New-Object System.Windows.Forms.Label
$lblFixTitle.Text = 'PACK MANAGER - Full catalog (Installed)'
Set-OuLabel $lblFixTitle
$lblFixTitle.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$lblFixTitle.AutoSize = $true
$lblFixTitle.Location = New-Object System.Drawing.Point(2, 5)
$fixTop.Controls.Add($lblFixTitle)

Set-OuPrimaryButton $btnFixSelected
Set-OuPrimaryButton $btnMgrAdd
Set-OuPrimaryButton $btnMgrAddDisk

# Dark context menus (Open folder menu, preview More menu)
function New-OuDarkMenu {
  $m = New-Object System.Windows.Forms.ContextMenuStrip
  $m.ShowImageMargin = $false
  $m.ShowItemToolTips = $true
  $m.Font = New-Object System.Drawing.Font('Segoe UI', 9)
  $m.BackColor = $script:Theme.PanelOpaque
  $m.ForeColor = $script:Theme.Text
  try {
    if ('OuDarkMenuColors' -as [type]) {
      $ct = New-Object OuDarkMenuColors($script:Theme.PanelOpaque, $script:Theme.ButtonBorder, $script:Theme.AccentDark)
      $rd = New-Object System.Windows.Forms.ToolStripProfessionalRenderer($ct)
      $rd.RoundedEdges = $false
      $m.Renderer = $rd
    }
  } catch { }
  return $m
}
function Add-OuMenuItem($menu, [string]$text, [string]$tag, [string]$tip) {
  $mi = New-Object System.Windows.Forms.ToolStripMenuItem
  $mi.Text = $text
  $mi.Tag = $tag
  $mi.ToolTipText = $tip
  $mi.ForeColor = $script:Theme.Text
  $mi.Padding = New-Object System.Windows.Forms.Padding(4, 2, 4, 2)
  [void]$menu.Items.Add($mi)
  return $mi
}

$lstCatalog = New-Object System.Windows.Forms.ListView
$lstCatalog.View = 'Details'
$lstCatalog.FullRowSelect = $true
$lstCatalog.MultiSelect = $true
$lstCatalog.CheckBoxes = $true
$lstCatalog.HideSelection = $false
$lstCatalog.GridLines = $true
$lstCatalog.HeaderStyle = 'Clickable'  # required for user-draggable column dividers
$lstCatalog.AllowColumnReorder = $false
Set-OuDarkInput $lstCatalog
$lstCatalog.Name = 'lstCatalog'
$script:OuCatalogSurface = $lstCatalog
$script:OuGlassAlpha[$lstCatalog] = [int]$script:Theme.GlassAlphaPreview
$lstCatalog.Add_Resize({ if ($script:OuCatalogSurface) { Update-OuGlassBackgroundImage $script:OuCatalogSurface ([int]$script:Theme.GlassAlphaPreview) } })
$lstCatalog.Add_HandleCreated({ Update-OuGlassBackgroundImage $script:OuCatalogSurface ([int]$script:Theme.GlassAlphaPreview) })
$lstCatalog.OwnerDraw = $true
# Column 0 header carries a tri-state "all visible" checkbox (checked / some / none); other headers stay default.
function Get-CatalogHeaderCheckState {
  $n = $lstCatalog.Items.Count
  if ($n -le 0) { return 'Unchecked' }
  $c = $lstCatalog.CheckedItems.Count
  if ($c -le 0) { return 'Unchecked' }
  if ($c -ge $n) { return 'Checked' }
  return 'Indeterminate'
}
function Update-CatalogHeaderCheck {
  try { if ($lstCatalog.IsHandleCreated -and ('OuLvHeader' -as [type])) { [OuLvHeader]::Invalidate($lstCatalog.Handle) } } catch { }
}
function Toggle-CatalogVisibleChecks {
  # Header click: tick every visible row, or untick them all when they are all ticked already.
  if ($lstCatalog.Items.Count -le 0) { return }
  $target = ((Get-CatalogHeaderCheckState) -ne 'Checked')
  $script:SuppressCheck = $true
  try {
    foreach ($it in $lstCatalog.Items) {
      $it.Checked = $target
      $nm = [string]$it.Tag
      if (-not $nm) { $nm = [string]$it.Text }
      if (-not $nm) { continue }
      if ($target) { [void]$script:CheckedNames.Add($nm) } else { [void]$script:CheckedNames.Remove($nm) }
    }
  } finally { $script:SuppressCheck = $false }
  Update-SelectedTray
  Refresh-CatalogRowStyles
  $lstCatalog.Invalidate()
}
$lstCatalog.Add_DrawColumnHeader({
  param($s, $e)
  if ($e.ColumnIndex -ne 0) { $e.DrawDefault = $true; return }
  $e.DrawBackground()
  $st = Get-CatalogHeaderCheckState
  Draw-OuListCheckbox $e.Graphics $e.Bounds ($st -eq 'Checked') $false -Indeterminate:($st -eq 'Indeterminate')
  $tr = New-Object System.Drawing.Rectangle(($e.Bounds.X + 22), $e.Bounds.Y, [Math]::Max(1, $e.Bounds.Width - 24), $e.Bounds.Height)
  [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.Header.Text, $e.Font, $tr, [System.Drawing.SystemColors]::ControlText,
    [System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix)
})
$lstCatalog.Add_ColumnClick({ param($s, $e) if ($e.Column -eq 0) { Toggle-CatalogVisibleChecks } })
# Details+OwnerDraw: DrawSubItem(col0) paints over DrawItem; checkbox drawn in DrawSubItem.
$lstCatalog.Add_DrawItem({
  param($s, $e)
  # Background/text/checkbox handled in DrawSubItem so glyphs are not covered.
})
$lstCatalog.Add_DrawSubItem({
  param($s, $e)
  if ($null -eq $e.Item) { return }
  # Light glass content surface (outer fixTop/fixBtnChrome are Heavy)
  Draw-OuContentGlass $lstCatalog $e.Graphics $e.Bounds ([int]$script:Theme.GlassAlphaPreview)
  if ($e.Item.Selected -or $e.Item.Checked) {
    $ab = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(210, $script:Theme.Accent.R, $script:Theme.Accent.G, $script:Theme.Accent.B))
    $e.Graphics.FillRectangle($ab, $e.Bounds)
    $ab.Dispose()
  }
  $accentRow = ($e.Item.Selected -or $e.Item.Checked)
  $padX = 4
  if ($e.ColumnIndex -eq 0) {
    # High-contrast checkbox (white rim) so it stays visible on dark AND accent-red rows
    Draw-OuListCheckbox $e.Graphics $e.Bounds $e.Item.Checked $accentRow
    $padX = 22
  }
  $name = [string]$e.Item.Tag
  $sc = $null
  if ($name -and $script:CatalogStatusColors.ContainsKey($name)) { $sc = $script:CatalogStatusColors[$name] }
  $fc = $script:ColorNormal
  # On accent-red rows: all columns white. Else Status keeps Good/Broken/Clash color.
  if (-not $accentRow -and $e.ColumnIndex -eq 1 -and $sc) { $fc = $sc }  # 1 = Status
  if (-not $accentRow -and $e.ColumnIndex -eq 0 -and $e.Item.ForeColor.ToArgb() -eq $script:ColorUnknown.ToArgb()) { $fc = $script:ColorUnknown }
  $tRect = New-Object System.Drawing.Rectangle(($e.Bounds.X + $padX), $e.Bounds.Y, [Math]::Max(1, $e.Bounds.Width - $padX - 2), $e.Bounds.Height)
  [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.SubItem.Text, $lstCatalog.Font, $tRect, $fc,
    [System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix)
})
# OwnerDraw removes the native checkbox glyph; Keep CheckBoxes=$true for state, draw our own, hit-test left pad.
$script:OuCheckHitW = 20
$lstCatalog.Add_MouseDown({
  param($s, $e)
  if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
  $hit = $lstCatalog.HitTest($e.Location)
  if ($null -eq $hit.Item) { return }
  # Native StateImage clicks still work when present; also treat left pad of row as checkbox.
  $entire = $hit.Item.GetBounds([System.Windows.Forms.ItemBoundsPortion]::Entire)
  $inCheck = ($hit.Location -eq [System.Windows.Forms.ListViewHitTestLocations]::StateImage) -or
             ($e.X -ge $entire.X -and $e.X -lt ($entire.X + $script:OuCheckHitW))
  if (-not $inCheck) { return }
  if ($hit.Location -eq [System.Windows.Forms.ListViewHitTestLocations]::StateImage) { return } # let LV toggle
  # Label/elsewhere in check pad: toggle ourselves (OwnerDraw often has no StateImage gutter)
  $hit.Item.Checked = -not $hit.Item.Checked
})
$lstCatalog.Dock = 'Fill'
# Initial column widths only (users can drag dividers). Status sits next to Pak so it is visible at small window
# sizes; Description is last and may be cut off.
[void]$lstCatalog.Columns.Add('Pak', 230)
[void]$lstCatalog.Columns.Add('Status', 74)
[void]$lstCatalog.Columns.Add('Type', 120)
[void]$lstCatalog.Columns.Add('Notes', 170)
[void]$lstCatalog.Columns.Add('Description', 260)
$pnlFix.Controls.Add($lstCatalog)
$lstCatalog.BringToFront()

# Empty-state message inside the catalog list (glass panel + centered muted text, like the Preview placeholder)
$script:CatalogEmptyText = ''
$pnlCatalogEmpty = New-Object System.Windows.Forms.Panel
$pnlCatalogEmpty.Name = 'pnlCatalogEmpty'
$pnlCatalogEmpty.Visible = $false
Set-OuDoubleBuffer $pnlCatalogEmpty -OpaquePaint
$pnlCatalogEmpty.BackColor = $script:Theme.PanelDeep
$pnlCatalogEmpty.Add_Paint({
  param($sender, $e)
  Draw-OuContentGlass $sender $e.Graphics $sender.ClientRectangle ([int]$script:Theme.GlassAlphaPreview)
  $fl = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::WordBreak -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix
  $r = New-Object System.Drawing.Rectangle(8, 0, [Math]::Max(1, $sender.ClientSize.Width - 16), $sender.ClientSize.Height)
  [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, [string]$script:CatalogEmptyText, $form.Font, $r, $script:Theme.TextMuted, $fl)
})
$lstCatalog.Controls.Add($pnlCatalogEmpty)
[void]$script:OuGlassHooked.Add($pnlCatalogEmpty)
$lstCatalog.Add_Resize({ Layout-CatalogEmpty })
$lstCatalog.Add_ColumnWidthChanged({ if ($pnlCatalogEmpty.Visible) { $pnlCatalogEmpty.Invalidate() } })

function Get-CatalogHeaderHeight {
  $h = 24
  try {
    if ($lstCatalog.Items.Count -gt 0) {
      $b = $lstCatalog.Items[0].GetBounds([System.Windows.Forms.ItemBoundsPortion]::Entire)
      if ($b.Y -gt 0 -and $b.Y -lt 60) { $h = $b.Y }
    }
  } catch { }
  return $h
}

function Layout-CatalogEmpty {
  if (-not $pnlCatalogEmpty -or -not $script:CatalogEmptyText) { if ($pnlCatalogEmpty) { $pnlCatalogEmpty.Visible = $false }; return }
  $cw = $lstCatalog.ClientSize.Width; $ch = $lstCatalog.ClientSize.Height
  $top = Get-CatalogHeaderHeight
  $n = $lstCatalog.Items.Count
  if ($n -gt 0) {
    # Rows are shown (e.g. installed packs that are all Broken): put the help under the last row if it fits.
    try {
      $lb = $lstCatalog.Items[$n - 1].GetBounds([System.Windows.Forms.ItemBoundsPortion]::Entire)
      $top = [Math]::Max($top, $lb.Bottom + 6)
    } catch { $top = $ch }
  }
  $lines = @(([string]$script:CatalogEmptyText) -split "`n").Count
  $h = [Math]::Max(40, $lines * 17 + 24)
  $w = [Math]::Min([Math]::Max(120, $cw - 24), 560)
  if (($ch - $top) -lt ($h + 4) -or $cw -lt 140) { $pnlCatalogEmpty.Visible = $false; return }
  $y = $top + [int](($ch - $top - $h) / 2)
  $x = [int](($cw - $w) / 2)
  $pnlCatalogEmpty.SetBounds($x, $y, $w, $h)
  $pnlCatalogEmpty.Visible = $true
  $pnlCatalogEmpty.BringToFront()
  $pnlCatalogEmpty.Invalidate()
}

function Update-CatalogEmpty {
  if (-not $pnlCatalogEmpty) { return }
  $total = @($script:CatalogRows).Count
  $vis = $lstCatalog.Items.Count
  $working = @($script:CatalogRows | Where-Object { $_ -and $_.Status -ne 'Broken' }).Count
  $brokenRel = 'Pak Fixer\Pack Files\Broken'
  $txt = ''
  switch ($script:CatalogSource) {
    'Installed' {
      if ($total -eq 0 -or $working -eq 0) {
        $head = $(if ($total -eq 0) { 'No packs installed yet.' } else { 'No working packs installed yet.' })
        $txt = $head + "`nPut broken .pak files in $brokenRel (Open $([char]0x25BE) > Broken)." +
               "`nThen switch Source to Broken, check the packs and press Fix selected (Yes = install)." +
               "`nFixed packs go into the game and show up here."
      } elseif ($vis -eq 0) { $txt = 'No packs match the filters' }
    }
    'Broken' {
      if ($total -eq 0) { $txt = "No broken packs waiting.`nPut .pak files in $brokenRel (Open $([char]0x25BE) > Broken),`npress $([char]0x27F3) Refresh (F5), then check them and press Fix selected." }
      elseif ($vis -eq 0) { $txt = 'No packs match the filters' }
    }
    'Disabled' {
      if ($total -eq 0) { $txt = "No disabled packs.`nPacks you Remove from Installed (or fix without installing) land here." }
      elseif ($vis -eq 0) { $txt = 'No packs match the filters' }
    }
  }
  $script:CatalogEmptyText = $txt
  if (-not $txt) { $pnlCatalogEmpty.Visible = $false; return }
  Layout-CatalogEmpty
}

# PACK MANAGER left-rail filter controls (built once, cached by Switch-LeftRail)
$script:FixFilterControls = $null
$script:CatalogRows = @()   # @{File; Meta; Name; Desc; Type; Status; StatusColor; Bytes; Notes; ...}
$script:SuppressCheck = $false
$script:SuppressFilter = $false
$script:LastCatalogIndex = -1
$script:CheckedNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$script:CatalogSource = 'Installed'  # Installed | Broken | Disabled (always opens on Installed; not persisted)
$script:PmMoreFiltersOpen = $false    # "More filters" expander; session only (not saved)

# ---------- PACK MANAGER preview pane (right) ----------
$script:FixPrevIndex = 0
$fixPrevPanel = New-Object System.Windows.Forms.Panel
$fixPrevPanel.Dock = 'Right'
$fixPrevPanel.Width = 260
$fixPrevPanel.Padding = New-Object System.Windows.Forms.Padding(8, 4, 4, 4)
$fixPrevPanel.Name = 'fixPrevPanel'
Enable-OuGlass $fixPrevPanel ([int]$script:Theme.GlassAlphaHeavy)
$pnlFix.Controls.Add($fixPrevPanel)

$lblFixPrevTitle = New-Object System.Windows.Forms.Label
$lblFixPrevTitle.Text = 'Preview'
$lblFixPrevTitle.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$lblFixPrevTitle.Dock = 'Top'
$lblFixPrevTitle.Height = 22
Set-OuLabel $lblFixPrevTitle
$fixPrevPanel.Controls.Add($lblFixPrevTitle)

$btnFixMakePrev = New-Object System.Windows.Forms.Button
$btnFixMakePrev.Text = 'Make previews'
$btnFixMakePrev.Dock = 'Fill'
Set-OuSecondaryButton $btnFixMakePrev
# Small "more" button: opens a menu with Delete previews... ($btnFixDelPrev name kept; enable rules unchanged)
$btnFixDelPrev = New-Object System.Windows.Forms.Button
$btnFixDelPrev.Text = ''
$btnFixDelPrev.Name = 'btnFixPrevMore'
$btnFixDelPrev.AccessibleName = 'More preview actions'
$btnFixDelPrev.Dock = 'Fill'
Set-OuSecondaryButton $btnFixDelPrev
$btnFixDelPrev.Image = $script:IconMore
$btnFixDelPrev.ImageAlign = 'MiddleCenter'
$script:PrevMoreMenu = New-OuDarkMenu
$script:PrevMoreDelete = Add-OuMenuItem $script:PrevMoreMenu ('Delete previews' + [char]0x2026) 'DeletePreviews' 'Delete preview images for the checked packs (asks first)'
$script:PrevMoreDelete.Add_Click({ Invoke-FixDeletePreviews })
$btnFixFullScreen = New-Object System.Windows.Forms.Button
$btnFixFullScreen.Text = ''
$btnFixFullScreen.Dock = 'Fill'
$btnFixFullScreen.Enabled = $false
Set-OuSecondaryButton $btnFixFullScreen
function Update-FixFullScreenIcon {
  if (-not $btnFixFullScreen) { return }
  $btnFixFullScreen.Image = $(if ($btnFixFullScreen.Enabled) { $script:FsIconExpandOn } else { $script:FsIconExpandOff })
}
$btnFixFullScreen.Image = $script:FsIconExpandOff
$btnFixFullScreen.ImageAlign = 'MiddleCenter'
$btnFixFullScreen.Text = ''
$btnFixFullScreen.Add_EnabledChanged({ Update-FixFullScreenIcon })
# Preview chrome (top to bottom): title | Make/Delete/FS | image | filename | arrows 50/50
# Preview chrome: title(top) | image(fill) | bottom stack Make/Delete/FS + filename + arrows
$fixPrevBottom = New-Object System.Windows.Forms.TableLayoutPanel
$fixPrevBottom.Dock = 'Bottom'
$fixPrevBottom.Height = 104
$fixPrevBottom.ColumnCount = 1
$fixPrevBottom.RowCount = 3
$fixPrevBottom.Padding = New-Object System.Windows.Forms.Padding(0)
$fixPrevBottom.Name = 'fixPrevBottom'
[void]$fixPrevBottom.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 36)))
[void]$fixPrevBottom.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 28)))
[void]$fixPrevBottom.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 40)))
[void]$fixPrevBottom.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))

# Row A: Make previews | More (...) | FS
$fixPrevBtnRow = New-Object System.Windows.Forms.TableLayoutPanel
$fixPrevBtnRow.Dock = 'Fill'
$fixPrevBtnRow.ColumnCount = 3
$fixPrevBtnRow.RowCount = 1
$fixPrevBtnRow.Padding = New-Object System.Windows.Forms.Padding(0, 2, 0, 2)
$fixPrevBtnRow.Name = 'fixPrevBtnRow'
[void]$fixPrevBtnRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$fixPrevBtnRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 36)))
[void]$fixPrevBtnRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 40)))
$btnFixMakePrev.Margin = New-Object System.Windows.Forms.Padding(0, 0, 2, 0)
$btnFixDelPrev.Margin = New-Object System.Windows.Forms.Padding(2, 0, 2, 0)
$btnFixFullScreen.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 0)
$fixPrevBtnRow.Controls.Add($btnFixMakePrev, 0, 0)
$fixPrevBtnRow.Controls.Add($btnFixDelPrev, 1, 0)
$fixPrevBtnRow.Controls.Add($btnFixFullScreen, 2, 0)
$fixPrevBottom.Controls.Add($fixPrevBtnRow, 0, 0)

# Row B: filename / position
$lblFixPrevPos = New-Object System.Windows.Forms.Label
$lblFixPrevPos.Dock = 'Fill'
$lblFixPrevPos.AutoSize = $false
$lblFixPrevPos.TextAlign = 'MiddleCenter'
$lblFixPrevPos.AutoEllipsis = $true
$lblFixPrevPos.Name = 'lblFixPrevPos'
Set-OuLabel $lblFixPrevPos
$lblFixPrevPos.ForeColor = $script:Theme.Text
$fixPrevBottom.Controls.Add($lblFixPrevPos, 0, 1)

# Row C: arrows 50/50
$fixPrevNav = New-Object System.Windows.Forms.TableLayoutPanel
$fixPrevNav.Dock = 'Fill'
$fixPrevNav.ColumnCount = 2
$fixPrevNav.RowCount = 1
$fixPrevNav.Padding = New-Object System.Windows.Forms.Padding(0, 2, 0, 0)
$fixPrevNav.Name = 'fixPrevNav'
[void]$fixPrevNav.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
[void]$fixPrevNav.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
$btnFixPrevBack = New-Object System.Windows.Forms.Button
$btnFixPrevBack.Text = [string][char]0x25C0
$btnFixPrevBack.Dock = 'Fill'
$btnFixPrevBack.Margin = New-Object System.Windows.Forms.Padding(0, 0, 2, 0)
Set-OuSecondaryButton $btnFixPrevBack
$fixPrevNav.Controls.Add($btnFixPrevBack, 0, 0)
$btnFixPrevNext = New-Object System.Windows.Forms.Button
$btnFixPrevNext.Text = [string][char]0x25B6
$btnFixPrevNext.Dock = 'Fill'
$btnFixPrevNext.Margin = New-Object System.Windows.Forms.Padding(2, 0, 0, 0)
Set-OuSecondaryButton $btnFixPrevNext
$fixPrevNav.Controls.Add($btnFixPrevNext, 1, 0)
$fixPrevBottom.Controls.Add($fixPrevNav, 0, 2)

$fixPrevPanel.Controls.Add($fixPrevBottom)

$picFix = New-Object System.Windows.Forms.PictureBox
$picFix.Dock = 'Fill'
$picFix.SizeMode = 'Zoom'
$picFix.BackColor = $script:Theme.PanelDeep
$picFix.Name = 'picFix'
$script:OuPreviewSurface = $picFix
$script:OuGlassAlpha[$picFix] = [int]$script:Theme.GlassAlphaPreview
$picFix.Add_Resize({ if ($script:OuPreviewSurface) { Update-OuGlassBackgroundImage $script:OuPreviewSurface ([int]$script:Theme.GlassAlphaPreview) } })
$picFix.Add_HandleCreated({ Update-OuGlassBackgroundImage $script:OuPreviewSurface ([int]$script:Theme.GlassAlphaPreview) })
$picFix.BorderStyle = 'FixedSingle'
$fixPrevPanel.Controls.Add($picFix)
$picFix.BringToFront()

$lblFixPrevMsg = New-Object System.Windows.Forms.Label
$lblFixPrevMsg.Dock = 'Fill'
$lblFixPrevMsg.TextAlign = 'MiddleCenter'
$lblFixPrevMsg.BackColor = [System.Drawing.Color]::Transparent
Set-OuLabel $lblFixPrevMsg -Muted
$picFix.Controls.Add($lblFixPrevMsg)
# ---------- Resizable PACK MANAGER layout (drag dividers) ----------
$fixSplit = New-Object System.Windows.Forms.SplitContainer
$fixSplit.Dock = 'Fill'
$fixSplit.Orientation = 'Vertical'
$fixSplit.SplitterWidth = 6
$fixSplit.FixedPanel = 'None'
$fixSplit.BackColor = $script:Theme.Splitter
Set-OuSeeThroughHost $fixSplit.Panel1
Set-OuSeeThroughHost $fixSplit.Panel2

$fixCenterSplit = New-Object System.Windows.Forms.SplitContainer
$fixCenterSplit.Dock = 'Fill'
$fixCenterSplit.Orientation = 'Horizontal'
$fixCenterSplit.SplitterWidth = 6
$fixSplit.Add_SplitterMoved({ Request-OuGlassRefresh })
$fixCenterSplit.FixedPanel = 'None'
$fixCenterSplit.BackColor = $script:Theme.Splitter
Set-OuSeeThroughHost $fixCenterSplit.Panel1
Set-OuSeeThroughHost $fixCenterSplit.Panel2
$fixCenterSplit.Add_SplitterMoved({ Request-OuGlassRefresh })

foreach ($c in @($lstCatalog, $fixTop, $selTray, $fixBtnRow, $fixPrevPanel)) { if ($pnlFix.Controls.Contains($c)) { $pnlFix.Controls.Remove($c) } }
$lstCatalog.Dock = 'Fill'
$fixCenterSplit.Panel1.Controls.Add($lstCatalog)
$fixCenterSplit.Panel1.Controls.Add($fixTop)
$fixTop.SendToBack()
$lstCatalog.BringToFront()
$selTray.Dock = 'Fill'
$fixCenterSplit.Panel2.Controls.Add($selTray)
$fixSplit.Panel1.Controls.Add($fixCenterSplit)
# Bottom action chrome: glass panel behind button row (opacity matches top bar; buttons unchanged)
$fixBtnChrome = New-Object System.Windows.Forms.Panel
$fixBtnChrome.Dock = 'Bottom'
$fixBtnChrome.Height = 48
$fixBtnChrome.Padding = New-Object System.Windows.Forms.Padding(4, 4, 4, 4)
$fixBtnChrome.Name = 'fixBtnChrome'
Enable-OuGlass $fixBtnChrome ([int]$script:Theme.GlassAlphaHeavy)
$fixBtnRow.Dock = 'Fill'
$fixBtnChrome.Controls.Add($fixBtnRow)
$fixSplit.Panel1.Controls.Add($fixBtnChrome)
$fixBtnChrome.SendToBack(); $fixCenterSplit.BringToFront()
$fixPrevPanel.Dock = 'Fill'
$fixSplit.Panel2.Controls.Add($fixPrevPanel)
$pnlFix.Controls.Add($fixSplit)

$script:SplitsInit = $false
$script:FixSplitsInit = $false
function Init-Splitters {
  if ($script:SplitsInit) { return }
  try {
    $bodySplit.Panel1MinSize = 140; $bodySplit.Panel2MinSize = 380
    $bodySplit.SplitterDistance = 220
  } catch {}
  $script:SplitsInit = $true
}
function Init-FixSplitters {
  if ($script:FixSplitsInit) { return }
  if ($fixSplit.Width -lt 400 -or $fixCenterSplit.Height -lt 150) { return }
  try {
    $fixSplit.Panel1MinSize = 200; $fixSplit.Panel2MinSize = 160
    $fixSplit.SplitterDistance = [Math]::Max(200, $fixSplit.Width - 266)
  } catch {}
  try {
    $fixCenterSplit.Panel1MinSize = 120; $fixCenterSplit.Panel2MinSize = 60
    $fixCenterSplit.SplitterDistance = [Math]::Max(120, $fixCenterSplit.Height - 116)
  } catch {}
  $script:FixSplitsInit = $true
}
$pnlFix.Add_VisibleChanged({ if ($pnlFix.Visible) { Init-FixSplitters } })
$pnlFix.Add_SizeChanged({ if ($pnlFix.Visible) { Init-FixSplitters } })
$form.Add_Shown({ Init-Splitters; if ($pnlFix.Visible) { Init-FixSplitters }; Invalidate-OuGlass })

# ---------- 3D bike previews (OU3DHost via Manage-OUPaks.ps1: Start-OU3D / Test-OU3DReady) ----------
# Lazy: compile starts on Showroom Search / first 3D need, in a background runspace. All model loads and renders run on the
# OU3DHost worker thread; the UI only queues requests. Any failure falls back to the flat images.
$script:Live3D = $null; $script:Live3DToken = ''; $script:Live3DPak = ''; $script:Live3DSlot = ''
$script:Showroom3DAsked = New-Object 'System.Collections.Generic.HashSet[string]'
$script:Showroom3DWanted = New-Object System.Collections.ArrayList
$script:OU3DPoll = $null
$script:LastMake3D = 0; $script:LastMake3DFail = 0

function Get-Item3DSlot($it) {
  # Bike items: the *_Plastics / *_Plastics_NN texture name (the slot the stock .sub models skin).
  if (-not $it -or $it.Kind -ne 'bike') { return $null }
  foreach ($e in @($it.Entries)) {
    $bn = [string]$e.BaseName
    if ($bn -match '(?i)_Plastics(_\d+)?$' -and $bn -notmatch '(?i)_AI$') { return $bn }
  }
  $null
}
function Test-Row3D($row) {
  if (-not $row -or -not $row.Slot3D -or -not $row.PackPath) { return $false }
  if ($script:OU3DState -ne 'ready') { return $false }
  try { return [OU3DHost]::HasModel([string]$row.Slot3D) } catch { return $false }
}
function Start-OU3DPoll {
  # 3D was wanted before the compile finished: when it is ready, fill in the waiting card thumbs and the live view.
  if ($script:OU3DState -eq 'failed' -or $script:OU3DPoll) { return }
  Start-OU3D
  if ($script:OU3DState -eq 'failed') { return }
  $t = New-Object System.Windows.Forms.Timer
  $t.Interval = 200
  $t.Add_Tick({
    try {
      if ($script:OU3DState -eq 'loading' -and $script:OU3DAr -and -not $script:OU3DAr.IsCompleted) { return }
      if ($script:OU3DPoll) { $script:OU3DPoll.Stop(); $script:OU3DPoll.Dispose(); $script:OU3DPoll = $null }
      if (-not (Test-OU3DReady)) { Set-Status ("3D previews unavailable (flat previews still work): {0}" -f $script:OU3DError); return }
      if (Test-ShowroomActive) {
        $want = @($script:Showroom3DWanted.ToArray()); $script:Showroom3DWanted.Clear()
        foreach ($pb in $want) { if ($pb -and -not $pb.IsDisposed) { Request-Showroom3DThumb $pb } }
        Update-FixPreview
      }
    } catch {}
  })
  $script:OU3DPoll = $t
  $t.Start()
}
function Request-Showroom3DThumb([System.Windows.Forms.PictureBox]$pb) {
  # Card thumb -> side-only 3D image (rendered + cached in Pack Manager\Previews if missing). Flat thumb stays on failure.
  try {
    if (-not $pb -or $pb.IsDisposed) { return }
    $key = [string]$pb.Tag
    if (-not $key -or $script:Showroom3DAsked.Contains($key)) { return }
    $r = Find-ShowroomRowByKey $key
    if (-not $r -or -not $r.Slot3D) { [void]$script:Showroom3DAsked.Add($key); return }
    if (-not (Test-OU3DReady)) {
      if ($script:OU3DState -ne 'failed') { if (-not $script:Showroom3DWanted.Contains($pb)) { $script:ShowroomLoadStats.Req3D++; [void]$script:Showroom3DWanted.Add($pb) }; Start-OU3DPoll }
      return
    }
    [void]$script:Showroom3DAsked.Add($key)
    if (-not (Test-Row3D $r)) { return }
    $script:ShowroomLoadStats.Req3D++
    [OU3DHost]::ThumbAsync($pb, [string]$r.PackPath, [string]$r.Slot3D, 184, 110)
  } catch {}
}
function Hide-Live3D {
  # Set unconditionally: Visible reads false while a parent is hidden, but the flag must still be cleared
  if ($script:Live3D) { $script:Live3D.Visible = $false }
}
function Show-Live3D($row) {
  # Live rotating model over the preview surface (drag rotate, wheel zoom, double-click reset). picFix.Image keeps the flat image.
  if (-not (Test-Row3D $row)) { Hide-Live3D; return $false }
  try {
    if (-not $script:Live3D) {
      $v = New-Object OULiveView
      $v.Dock = 'Fill'
      $v.BackColor = $script:Theme.PanelDeep
      $v.Visible = $false
      $picFix.Controls.Add($v)
      if ($script:UiToolTip) { $script:UiToolTip.SetToolTip($v, 'Drag to rotate, mouse wheel to zoom, double-click to reset') }
      $script:Live3D = $v
    }
    $tok = "{0}|{1}|{2}" -f $row.PackPath, $row.Slot3D, (Get-Item -LiteralPath $row.PackPath).LastWriteTimeUtc.Ticks
    if ($script:Live3DToken -ne $tok) {
      $script:Live3DToken = $tok; $script:Live3DPak = [string]$row.PackPath; $script:Live3DSlot = [string]$row.Slot3D
      [OU3DHost]::SceneAsync($script:Live3D, $script:Live3DPak, $script:Live3DSlot, $tok)
    } else { try { [void][OU3DHost]::ApplyRiderToView($script:Live3D) } catch {} }   # rider number may have changed since
    $script:Live3D.Visible = $true
    $script:Live3D.BringToFront()
    $btnFixFullScreen.Enabled = $true
    return $true
  } catch { Hide-Live3D; return $false }
}

function Clear-FixPreview {
  Hide-Live3D
  if ($picFix.Image) { $old = $picFix.Image; $picFix.Image = $null; $old.Dispose() }
  if ($btnFixFullScreen) { $btnFixFullScreen.Enabled = $false }
}

function Update-FixPreview {
  if ((Get-Command Test-ShowroomActive -ErrorAction SilentlyContinue) -and (Test-ShowroomActive)) {
    Clear-FixPreview
    $checked = @($script:ShowroomChecked | Sort-Object)
    $btnFixMakePrev.Enabled = ($checked.Count -gt 0)
    $btnFixDelPrev.Enabled = ($checked.Count -gt 0)
    $btnFixPrevBack.Enabled = ($checked.Count -gt 1)
    $btnFixPrevNext.Enabled = ($checked.Count -gt 1)
    $name = $script:ShowroomSelected
    # Only an explicit card click (or Back/Next) selects; checked items are never auto-previewed
    if (-not $name) {
      $lblFixPrevMsg.Text = 'Click a bike card to preview it'
      $lblFixPrevMsg.Visible = $true
      $lblFixPrevPos.Text = ''
      return
    }
    $row = Find-ShowroomRowByKey $name
    $label = if ($row) { $row.DisplayName } else { $name }
    if ($checked.Count -gt 0) {
      $idx = [array]::IndexOf($checked, $name)
      if ($idx -ge 0) { $script:FixPrevIndex = $idx }
      $lblFixPrevPos.Text = ("{0} / {1} {2} {3}" -f ([Math]::Max(1, $script:FixPrevIndex + 1)), $checked.Count, [char]0x00B7, $label)
    } else {
      $lblFixPrevPos.Text = $label
    }
    # Bike item with a stock model: live rotating 3D view on top (flat image stays underneath for fallback/fullscreen)
    $live = $false
    if ($row -and $row.Slot3D) { if (Test-OU3DReady) { $live = Show-Live3D $row } else { Start-OU3DPoll } }
    # Prefer decoded item preferred-thumb in the shared preview panel
    $img = $null
    if ($row) { $img = Get-ShowroomItemBitmap $row 0 0 }
    if ($img) {
      try {
        # Clone so Clear-FixPreview dispose does not wipe the cache entry
        $clone = New-Object System.Drawing.Bitmap $img
        $picFix.Image = $clone
        $lblFixPrevMsg.Text = ''
        $lblFixPrevMsg.Visible = $false
        $btnFixFullScreen.Enabled = $true
      } catch {
        $lblFixPrevMsg.Text = 'Item thumb could not be shown'; $lblFixPrevMsg.Visible = $true
      }
      return
    }
    # Fallback: pack contact sheet PNG if present
    $packName = if ($row) { $row.PackFile } else { $null }
    $path = if ($packName) { Find-PreviewPath $packName } else { $null }
    if (-not $path) {
      $lblFixPrevMsg.Text = 'No item thumb - texture missing or undecodable'
      $lblFixPrevMsg.Visible = (-not $live)
      if (-not $live) { $lblFixPrevMsg.BringToFront() }
      return
    }
    try {
      $bytes = [IO.File]::ReadAllBytes($path)
      $ms = New-Object IO.MemoryStream(,$bytes)
      $picFix.Image = [System.Drawing.Image]::FromStream($ms)
      $ms.Dispose()
      $lblFixPrevMsg.Visible = $false
      $btnFixFullScreen.Enabled = $true
    } catch {
      $lblFixPrevMsg.Text = 'Preview could not be loaded'; $lblFixPrevMsg.Visible = $true
    }
    return
  }
  Clear-FixPreview
  $checked = @(Get-CheckedNames | Sort-Object)
  $btnFixMakePrev.Enabled = ($checked.Count -gt 0)
  $btnFixDelPrev.Enabled = ($checked.Count -gt 0)
  $btnFixPrevBack.Enabled = ($checked.Count -gt 1)
  $btnFixPrevNext.Enabled = ($checked.Count -gt 1)
  $name = $null
  # Prefer highlighted row for browse; else cycle checked packs
  if ($lstCatalog.SelectedItems.Count -gt 0) {
    $hit = $lstCatalog.SelectedItems[0]
    $name = [string]$hit.Tag
    if (-not $name) { $name = [string]$hit.Text }
    if ($checked.Count -gt 0) {
      $idx = [array]::IndexOf($checked, $name)
      if ($idx -ge 0) { $script:FixPrevIndex = $idx }
      $lblFixPrevPos.Text = ("{0} / {1} {2} {3}" -f ([Math]::Max(1, $script:FixPrevIndex + 1)), $checked.Count, [char]0x00B7, $name)
    } else {
      $lblFixPrevPos.Text = $name
    }
  } elseif ($checked.Count -gt 0) {
    if ($script:FixPrevIndex -ge $checked.Count) { $script:FixPrevIndex = $checked.Count - 1 }
    if ($script:FixPrevIndex -lt 0) { $script:FixPrevIndex = 0 }
    $name = $checked[$script:FixPrevIndex]
    $lblFixPrevPos.Text = ("{0} / {1} {2} {3}" -f ($script:FixPrevIndex + 1), $checked.Count, [char]0x00B7, $name)
  } else {
    $script:FixPrevIndex = 0
    $lblFixPrevMsg.Text = 'Check packs for actions, or click a row to browse preview'
    $lblFixPrevMsg.Visible = $true
    $lblFixPrevPos.Text = ''
    return
  }
  if (-not $name) {
    $lblFixPrevMsg.Text = 'Check packs for actions, or click a row to browse preview'
    $lblFixPrevMsg.Visible = $true
    return
  }
  $path = Find-PreviewPath $name
  if (-not $path) { $lblFixPrevMsg.Text = 'No preview - click Make previews'; $lblFixPrevMsg.Visible = $true; return }
  try {
    $bytes = [IO.File]::ReadAllBytes($path)
    $ms = New-Object IO.MemoryStream(,$bytes)
    $picFix.Image = [System.Drawing.Image]::FromStream($ms)
    $ms.Dispose()
    $lblFixPrevMsg.Visible = $false
    $btnFixFullScreen.Enabled = $true
  } catch {
    $lblFixPrevMsg.Text = 'Preview could not be loaded'; $lblFixPrevMsg.Visible = $true
  }
}

function Invoke-FixDeletePreviews {
  $names = @(Get-CheckedNames | Sort-Object)
  if (-not $names.Count) { [void][System.Windows.Forms.MessageBox]::Show('Select one or more packs first.', 'Delete previews'); return }
  $hits = @(); $none = 0
  foreach ($nm in $names) {
    $any = $false
    $p = Find-PreviewPath $nm; if ($p -and (Test-Path -LiteralPath $p)) { $hits += $p; $any = $true }
    foreach ($f3 in @(Get-Pack3DPreviewFiles $nm)) { $hits += $f3.FullName; $any = $true }
    if (-not $any) { $none++ }
  }
  if (-not $hits.Count) { [void][System.Windows.Forms.MessageBox]::Show(("None of the {0} selected pack(s) have a preview." -f $names.Count), 'Delete previews'); return }
  $ans = [System.Windows.Forms.MessageBox]::Show(("Delete {0} preview(s) for the selected packs?" -f $hits.Count), 'Delete previews', 'YesNo', 'Question')
  if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }
  if ($picFix.Image) { $picFix.Image.Dispose(); $picFix.Image = $null }
  $del = 0; $fail = 0
  foreach ($p in $hits) { try { Remove-Item -LiteralPath $p -Force -ErrorAction Stop; $del++ } catch { $fail++ } }
  Refresh-CatalogList
  Update-FixPreview
  if ((Get-Command Test-ShowroomActive -EA SilentlyContinue) -and (Test-ShowroomActive)) { Clear-ShowroomThumbs; Refresh-ShowroomGrid }
  Set-Status ("Deleted {0} preview(s)" -f $del)
  $msg = "{0} preview(s) deleted, {1} selected pack(s) had no preview." -f $del, $none
  if ($fail) { $msg += "`n{0} could not be deleted." -f $fail }
  [void][System.Windows.Forms.MessageBox]::Show($msg, 'Delete previews')
}
function Get-CheckedNames {
  if ((Get-Command Test-ShowroomActive -ErrorAction SilentlyContinue) -and (Test-ShowroomActive)) {
    # Checked cards are items; Make/Delete operate on unique source packs
    return @(Get-ShowroomCheckedPackNames)
  }
  # Held checkbox selection (CheckedNames mirror restored on refresh).
  $names = New-Object System.Collections.Generic.List[string]
  if ($lstCatalog.CheckedItems.Count -gt 0) {
    foreach ($it in $lstCatalog.CheckedItems) {
      $nm = [string]$it.Tag
      if (-not $nm) { $nm = [string]$it.Text }
      if ($nm) { [void]$names.Add($nm) }
    }
  } elseif ($script:CheckedNames.Count -gt 0) {
    foreach ($nm in @($script:CheckedNames)) { [void]$names.Add($nm) }
  }
  return @($names)
}

function Sync-CheckedNamesFromList {
  $script:CheckedNames.Clear()
  foreach ($it in $lstCatalog.CheckedItems) {
    $nm = [string]$it.Tag
    if (-not $nm) { $nm = [string]$it.Text }
    if ($nm) { [void]$script:CheckedNames.Add($nm) }
  }
}

function Get-CheckedCatalogFiles {
  # Collect FileInfo targets FIRST from checked packs (flat array - no nested ,@() trap).
  $byName = @{}
  foreach ($r in $script:CatalogRows) {
    if ($r -and $r.Name -and $r.File) { $byName[$r.Name] = $r.File }
  }
  $list = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
  foreach ($nm in (Get-CheckedNames)) {
    if ($byName.ContainsKey($nm)) {
      $f = $byName[$nm]
      if ($f -and (Test-Path -LiteralPath $f.FullName)) { [void]$list.Add($f) }
    }
  }
  return @($list.ToArray())
}
function Get-Make3DSummary {
  if ($script:OU3DState -ne 'ready') { return ("`n3D bike previews unavailable: {0}" -f $script:OU3DError) }
  $t = "`n{0} 3D bike preview(s) made (side + stacked)." -f $script:LastMake3D
  if ($script:LastMake3DFail) { $t += " {0} 3D render(s) failed (flat previews kept)." -f $script:LastMake3DFail }
  $t
}
function Invoke-FixMakePreviews {
  $names = @(Get-CheckedNames | Sort-Object)
  if (-not $names.Count) { [void][System.Windows.Forms.MessageBox]::Show('Select one or more packs first.', 'Make previews'); return }
  New-Item -ItemType Directory -Force -Path $prevD | Out-Null
  $byName = @{}
  foreach ($r in $script:CatalogRows) { if ($r -and $r.Name -and $r.File) { $byName[$r.Name] = $r.File } }
  if ((Get-Command Test-ShowroomActive -EA SilentlyContinue) -and (Test-ShowroomActive)) { foreach ($r in $script:ShowroomRows) { if ($r -and $r.PackFile -and $r.File) { $byName[$r.PackFile] = $r.File } elseif ($r -and $r.Name -and $r.File) { $byName[$r.Name] = $r.File } } }
  $todo = @(); $same = 0; $gone = 0
  $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
  try { [void](Test-OU3DReady -Wait) } finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
  foreach ($nm in $names) {
    if (-not $byName.ContainsKey($nm)) { $gone++; continue }
    $srcItem = $byName[$nm]
    $src = $srcItem.FullName
    if (-not (Test-Path -LiteralPath $src)) { $gone++; continue }
    $out = Join-Path $prevD ("{0}.png" -f $nm)
    $flatFresh = (Test-Path -LiteralPath $out) -and (Get-Item -LiteralPath $out).LastWriteTime -gt (Get-Item -LiteralPath $src).LastWriteTime
    if ($flatFresh -and (Test-Pack3DFresh $src)) { $same++; continue }
    $todo += [pscustomobject]@{ File = $nm; FullName = $src; Flat = (-not $flatFresh) }
  }
  if (-not $todo.Count) {
    [void][System.Windows.Forms.MessageBox]::Show(("All {0} checked pack(s) already have previews." -f $same), 'Make previews')
    Update-FixPreview; return
  }
  $btnFixMakePrev.Enabled = $false; $btnFixDelPrev.Enabled = $false
  $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
  Set-Status ("Making {0} preview(s)..." -f $todo.Count)
  # Make-Previews (Manage-OUPaks.ps1) logs via Write-Host and opens Explorer; silence/skip that here.
  try {
    $log = @(Make-Previews $todo 6>&1 | ForEach-Object { "$_" })
  } catch { $log = @("ERROR: $($_.Exception.Message)") }
  finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
  $flatTodo = @($todo | Where-Object { $_.Flat })
  $made = @($flatTodo | Where-Object { Test-Path -LiteralPath (Join-Path $prevD ("{0}.png" -f $_.File)) }).Count
  $fail = $flatTodo.Count - $made
  $msg = "{0} preview(s) made, {1} already had one." -f $made, $same
  $msg += Get-Make3DSummary
  if ($fail) { $msg += "`n{0} pack(s) had no bike/rider textures or couldn't be previewed." -f $fail }
  if ($gone) { $msg += "`n{0} selected pack(s) are no longer in the current source." -f $gone }
  Refresh-CatalogList
  if ((Get-Command Test-ShowroomActive -EA SilentlyContinue) -and (Test-ShowroomActive)) { Clear-ShowroomThumbs; Refresh-ShowroomGrid }
  Update-FixPreview
  Update-FixStatus
  [void][System.Windows.Forms.MessageBox]::Show($msg, 'Make previews')
}

$btnFixPrevBack.Add_Click({
  if ((Get-Command Test-ShowroomActive -ErrorAction SilentlyContinue) -and (Test-ShowroomActive)) {
    $checked = @($script:ShowroomChecked | Sort-Object)
    $n = $checked.Count
    if (-not $n) { return }
    $script:FixPrevIndex = ($script:FixPrevIndex - 1 + $n) % $n
    Select-ShowroomPack $checked[$script:FixPrevIndex]
    return
  }
  $checked = @(Get-CheckedNames | Sort-Object)
  $n = $checked.Count
  if (-not $n) { return }
  $script:FixPrevIndex = ($script:FixPrevIndex - 1 + $n) % $n
  $target = $checked[$script:FixPrevIndex]
  $script:SuppressCheck = $true
  try {
    $lstCatalog.SelectedItems.Clear()
    foreach ($it in $lstCatalog.Items) {
      if ([string]$it.Tag -eq $target) { $it.Selected = $true; $it.EnsureVisible(); break }
    }
  } finally { $script:SuppressCheck = $false }
  Update-FixPreview
})
$btnFixPrevNext.Add_Click({
  if ((Get-Command Test-ShowroomActive -ErrorAction SilentlyContinue) -and (Test-ShowroomActive)) {
    $checked = @($script:ShowroomChecked | Sort-Object)
    $n = $checked.Count
    if (-not $n) { return }
    $script:FixPrevIndex = ($script:FixPrevIndex + 1) % $n
    Select-ShowroomPack $checked[$script:FixPrevIndex]
    return
  }
  $checked = @(Get-CheckedNames | Sort-Object)
  $n = $checked.Count
  if (-not $n) { return }
  $script:FixPrevIndex = ($script:FixPrevIndex + 1) % $n
  $target = $checked[$script:FixPrevIndex]
  $script:SuppressCheck = $true
  try {
    $lstCatalog.SelectedItems.Clear()
    foreach ($it in $lstCatalog.Items) {
      if ([string]$it.Tag -eq $target) { $it.Selected = $true; $it.EnsureVisible(); break }
    }
  } finally { $script:SuppressCheck = $false }
  Update-FixPreview
})
function Show-FixPreviewFullScreen {
  if (-not $picFix.Image -and -not ($script:Live3D -and $script:Live3D.Visible)) {
    [void][System.Windows.Forms.MessageBox]::Show('No preview image loaded. Check a pack with a preview, or click Make previews.', 'Full screen')
    return
  }
  $fs = New-Object System.Windows.Forms.Form
  $fs.Text = 'Preview - Full screen'
  $fs.WindowState = 'Maximized'
  $fs.FormBorderStyle = 'None'
  $fs.BackColor = [System.Drawing.Color]::Black
  $fs.KeyPreview = $true
  $fs.StartPosition = 'CenterScreen'
  $fs.TopMost = $true
  Set-OuFormIcon $fs

  # Top status bar
  $topBar = New-Object System.Windows.Forms.Panel
  $topBar.Dock = 'Top'
  $topBar.Height = 36
  $topBar.BackColor = [System.Drawing.Color]::FromArgb(28, 28, 32)
  $fs.Controls.Add($topBar)
  $lblFs = New-Object System.Windows.Forms.Label
  $lblFs.Dock = 'Fill'
  $lblFs.TextAlign = 'MiddleLeft'
  $lblFs.Padding = New-Object System.Windows.Forms.Padding(12, 0, 12, 0)
  $lblFs.ForeColor = [System.Drawing.Color]::FromArgb(210, 210, 210)
  $lblFs.Text = $lblFixPrevPos.Text
  $topBar.Controls.Add($lblFs)

  # Bottom chrome: Prev | Next | Make | Delete | Exit (collapse)
  $bot = New-Object System.Windows.Forms.Panel
  $bot.Dock = 'Bottom'
  $bot.Height = 48
  $bot.BackColor = [System.Drawing.Color]::FromArgb(28, 28, 32)
  $fs.Controls.Add($bot)
  $chrome = New-Object System.Windows.Forms.TableLayoutPanel
  $chrome.Dock = 'Fill'
  $chrome.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 6)
  $chrome.ColumnCount = 6
  $chrome.RowCount = 1
  [void]$chrome.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 44)))
  [void]$chrome.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 44)))
  [void]$chrome.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
  [void]$chrome.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
  [void]$chrome.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 12)))
  [void]$chrome.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 44)))
  $bot.Controls.Add($chrome)

  function New-FsChromeBtn([string]$text) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Dock = 'Fill'
    $b.FlatStyle = 'Flat'
    $b.ForeColor = [System.Drawing.Color]::White
    $b.BackColor = [System.Drawing.Color]::FromArgb(55, 55, 62)
    $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(80, 80, 90)
    return $b
  }
  $btnFsBack = New-FsChromeBtn ([string][char]0x25C0)
  $btnFsNext = New-FsChromeBtn ([string][char]0x25B6)
  $btnFsMake = New-FsChromeBtn 'Make previews'
  $btnFsDel = New-FsChromeBtn 'Delete previews'
  $btnExitFs = New-FsChromeBtn ''
  $btnExitFs.Image = $script:FsIconCollapse
  $btnExitFs.ImageAlign = 'MiddleCenter'
  $chrome.Controls.Add($btnFsBack, 0, 0)
  $chrome.Controls.Add($btnFsNext, 1, 0)
  $chrome.Controls.Add($btnFsMake, 2, 0)
  $chrome.Controls.Add($btnFsDel, 3, 0)
  $chrome.Controls.Add($btnExitFs, 5, 0)

  $picFs = New-Object System.Windows.Forms.PictureBox
  $picFs.Dock = 'Fill'
  $picFs.SizeMode = 'Zoom'
  $picFs.BackColor = [System.Drawing.Color]::Black
  if ($picFix.Image) { $picFs.Image = New-Object System.Drawing.Bitmap($picFix.Image) }
  $fs.Controls.Add($picFs)
  $picFs.BringToFront()
  # Live 3D bike in full screen when the main panel shows one (main view pauses while this is open)
  $fsLive = $null
  if ($script:Live3D -and $script:Live3D.Visible) {
    try {
      $fsLive = New-Object OULiveView
      $fsLive.Dock = 'Fill'
      $fsLive.BackColor = [System.Drawing.Color]::Black
      $picFs.Controls.Add($fsLive)
      $script:Live3D.Paused = $true
    } catch { $fsLive = $null }
  }
  $topBar.BringToFront()
  $bot.BringToFront()

  $syncFsFromMain = {
    if ($picFs.Image) { $oldFs = $picFs.Image; $picFs.Image = $null; $oldFs.Dispose() }
    if ($picFix.Image) { $picFs.Image = New-Object System.Drawing.Bitmap($picFix.Image) }
    if ($fsLive) {
      $showLive = [bool]($script:Live3D -and $script:Live3D.Visible)
      if ($showLive -and -not [object]::Equals($fsLive.Tag, $script:Live3DToken)) {
        try {
          if ($script:Live3D.Scene -and [object]::Equals($script:Live3D.Tag, $script:Live3DToken)) {
            $fsLive.Tag = $script:Live3DToken; $fsLive.Message = ''; $fsLive.Scene = $script:Live3D.Scene   # already loaded: share it
          } else { [OU3DHost]::SceneAsync($fsLive, $script:Live3DPak, $script:Live3DSlot, $script:Live3DToken) }
        } catch { $showLive = $false }
      }
      $fsLive.Visible = $showLive
    }
    $lblFs.Text = $lblFixPrevPos.Text
    $btnFsBack.Enabled = $btnFixPrevBack.Enabled
    $btnFsNext.Enabled = $btnFixPrevNext.Enabled
    $btnFsMake.Enabled = $btnFixMakePrev.Enabled
    $btnFsDel.Enabled = $btnFixDelPrev.Enabled
  }
  & $syncFsFromMain

  $closeFs = {
    if ($picFs.Image) { $img = $picFs.Image; $picFs.Image = $null; $img.Dispose() }
    $fs.Close()
  }
  $btnExitFs.Add_Click($closeFs)
  $btnFsBack.Add_Click({ $btnFixPrevBack.PerformClick(); & $syncFsFromMain })
  $btnFsNext.Add_Click({ $btnFixPrevNext.PerformClick(); & $syncFsFromMain })
  $btnFsMake.Add_Click({ Invoke-FixMakePreviews; & $syncFsFromMain })
  $btnFsDel.Add_Click({ Invoke-FixDeletePreviews; & $syncFsFromMain })
  $fs.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq 'Escape') { & $closeFs }
    elseif ($e.KeyCode -eq 'Left') { $btnFixPrevBack.PerformClick(); & $syncFsFromMain }
    elseif ($e.KeyCode -eq 'Right') { $btnFixPrevNext.PerformClick(); & $syncFsFromMain }
  })
  if ($script:UiToolTip) {
    $script:UiToolTip.SetToolTip($btnExitFs, 'Exit full screen')
    $script:UiToolTip.SetToolTip($btnFsBack, 'Previous selected pack preview')
    $script:UiToolTip.SetToolTip($btnFsNext, 'Next selected pack preview')
    $script:UiToolTip.SetToolTip($btnFsMake, 'Build preview images for the selected packs')
    $script:UiToolTip.SetToolTip($btnFsDel, 'Delete preview images for the selected packs')
  }
  [void]$fs.ShowDialog($form)
  if ($picFs.Image) { $img2 = $picFs.Image; $picFs.Image = $null; $img2.Dispose() }
  if ($fsLive) { try { $fsLive.Dispose() } catch {} }
  if ($script:Live3D) { $script:Live3D.Paused = $false }
  $fs.Dispose()
}

$btnFixFullScreen.Add_Click({ Show-FixPreviewFullScreen })
$btnFixMakePrev.Add_Click({ Invoke-FixMakePreviews })
$btnFixDelPrev.Add_Click({ $script:PrevMoreMenu.Show($btnFixDelPrev, (New-Object System.Drawing.Point($btnFixDelPrev.Width, 0)), [System.Windows.Forms.ToolStripDropDownDirection]::AboveLeft) })

function Type-OfMeta($meta) {
  if (-not $meta) { return 'Unknown' }
  $cat = [string]$meta.cat
  $sub = [string]$meta.sub
  if ($cat -in @('Bikes','Rider gear','Add-ons','Misc')) {
    if ($sub) { return "$cat - $sub" }
  }
  if ($cat) { return $cat }
  'Unknown'
}

function Get-CatalogSourceFiles {
  switch ($script:CatalogSource) {
    'Installed' {
      if (-not $game) { return @() }
      return @(Installed)
    }
    'Disabled' {
      return @(Get-ChildItem -LiteralPath $disabledDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -ieq '.pak' } | Sort-Object Name)
    }
    default {
      return @(Get-ChildItem -LiteralPath $brokenDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -ieq '.pak' } | Sort-Object Name)
    }
  }
}

function Get-CatalogSourceDir {
  switch ($script:CatalogSource) {
    'Installed' { if ($game) { return $game } else { return $null } }
    'Disabled' { return $disabledDir }
    default { return $brokenDir }
  }
}

$script:ColorGood = [System.Drawing.Color]::FromArgb(60, 200, 90)
$script:ColorBroken = [System.Drawing.Color]::FromArgb(230, 70, 70)
$script:ColorClash = [System.Drawing.Color]::FromArgb(255, 160, 40)
$script:ColorNormal = [System.Drawing.Color]::White
$script:ColorUnknown = [System.Drawing.Color]::FromArgb(170, 170, 175)

function Get-PackBrokenReason([System.IO.FileInfo]$f, $unusedMap) {
  if (-not $f) { return $false }
  try {
    if ((Count-Broken $f.FullName) -gt 0) { return $true }
  } catch { return $true }
  if ($unusedMap -and $unusedMap.ContainsKey($f.Name)) { return $true }
  if (Needs-LoadOrder $f.Name) { return $true }
  return $false
}

function Status-FromInstalledTag([string]$tag) {
  # Tags from Installed Packs.txt / Get-Tags, e.g. "[OK]", "[1-17]", "[4,9] [BROKEN]"
  if (-not $tag) { return @{ Status = 'Good'; Color = $script:ColorGood } }
  if ($tag -match '(?i)BROKEN|UNUSED') {
    return @{ Status = 'Broken'; Color = $script:ColorBroken }
  }
  if ($tag -match '\[\d') {
    return @{ Status = 'Clash'; Color = $script:ColorClash }
  }
  return @{ Status = 'Good'; Color = $script:ColorGood }
}

function Build-CatalogRows {
  $script:CatalogScanCount = [int]$script:CatalogScanCount + 1
  $script:CatalogRows = @()
  $files = @(Get-CatalogSourceFiles)
  if (-not $files.Count) { return }

  # Batch unused-map once for this source (texture/load-order still per file).
  $um = @{}
  try { $um = Unused-Map $files } catch { $um = @{} }

  $tags = $null
  if ($script:CatalogSource -eq 'Installed' -and $game) {
    try { $tags = Get-Tags } catch { $tags = @{} }
  }

  foreach ($f in $files) {
    $meta = Get-CatalogMeta $f.Name
    $notesArr = @()
    if ($meta -and $meta.notes) { $notesArr = @($meta.notes) }
    $notesText = if ($notesArr.Count) { ($notesArr -join ' - ') } else { '' }
    $clashFree = $true
    foreach ($n in $notesArr) {
      if ($n -match '(?i)only one|conflicts with|Use ONE|REQUIRED by|BROKEN') { $clashFree = $false; break }
    }
    if ($meta -and [int]($meta.clashes) -gt 0) { $clashFree = $false }

    # Status: Broken wins over Clash; Good otherwise.
    $status = 'Good'
    $statusColor = $script:ColorGood
    if ($script:CatalogSource -eq 'Installed' -and $tags) {
      $tg = $tags[$f.Name]
      $st = Status-FromInstalledTag $tg
      $status = $st.Status
      $statusColor = $st.Color
      # Prefer live file diagnostics if tag missed a broken pack
      if ($status -ne 'Broken' -and (Get-PackBrokenReason $f $um)) {
        $status = 'Broken'; $statusColor = $script:ColorBroken
      }
    } else {
      # Broken / Disabled folders: diagnose the file (Clash mainly for Installed).
      if (Get-PackBrokenReason $f $um) {
        $status = 'Broken'; $statusColor = $script:ColorBroken
      } else {
        $status = 'Good'; $statusColor = $script:ColorGood
      }
    }

    $script:CatalogRows += [pscustomobject]@{
      File = $f
      Meta = $meta
      Name = $f.Name
      Desc = if ($meta) { [string]$meta.desc } else { '(not in catalog)' }
      Type = (Type-OfMeta $meta)
      Status = $status
      StatusColor = $statusColor
      Bytes = [long]$f.Length
      Notes = $notesText
      Cat = if ($meta) { [string]$meta.cat } else { 'Unknown' }
      Sub = if ($meta) { [string]$meta.sub } else { '' }
      Cls = if ($meta) { [string]$meta.cls } else { '' }
      Brand = if ($meta) { [string]$meta.brand } else { '' }
      Rep = if ($meta) { [string]$meta.rep } else { '' }
      ClashFree = $clashFree
      HasPreview = [bool](Find-PreviewPath $f.Name)
      Kb = if ($meta -and $meta.kb) { [int]$meta.kb } else { [int]([math]::Round($f.Length / 1KB)) }
    }
  }
}

function Get-FixFilterState {
  $st = @{ Cat = 'All'; Sub = 'All'; Cls = 'All'; Sort = 'category'; Q = ''; HasPrev = $false; Clashes = $false; Solo = $false }
  if (-not $script:FixFilterControls) { return $st }
  $c = $script:FixFilterControls
  if ($c.Cat.SelectedItem) { $st.Cat = [string]$c.Cat.SelectedItem }
  if ($c.Sub.SelectedItem) { $st.Sub = [string]$c.Sub.SelectedItem }
  if ($c.Cls.SelectedItem) { $st.Cls = [string]$c.Cls.SelectedItem }
  if ($c.Sort.SelectedItem) {
    $map = @{
      'By category' = 'category'
      'By pak name' = 'name'
      'Fewest notes first' = 'fewest'
      'Most notes first' = 'most'
      'Largest first' = 'size'
    }
    $lab = [string]$c.Sort.SelectedItem
    if ($map.ContainsKey($lab)) { $st.Sort = $map[$lab] }
  }
  $st.Q = [string]$c.Search.Text
  $st.HasPrev = [bool]$c.HasPrev.Checked
  $st.Clashes = [bool]$c.Clashes.Checked
  $st.Solo = [bool]$c.Solo.Checked
  $st
}

function Get-FilteredCatalogRows {
  $st = Get-FixFilterState
  $needle = $st.Q.Trim().ToLowerInvariant()
  $rows = @($script:CatalogRows | Where-Object {
    ($st.Cat -eq 'All' -or $_.Cat -eq $st.Cat) -and
    ($st.Sub -eq 'All' -or $_.Sub -eq $st.Sub) -and
    ($st.Cls -eq 'All' -or (@($_.Cls -split ',\s*') -contains $st.Cls)) -and
    ((-not $st.HasPrev) -or $_.HasPreview) -and
    ((-not $st.Clashes) -or $_.Status -eq 'Clash') -and
    ((-not $st.Solo) -or $_.ClashFree) -and
    ($needle -eq '' -or (
      ($_.Name + ' ' + $_.Desc + ' ' + $_.Brand + ' ' + $_.Rep + ' ' + $_.Notes + ' ' + $_.Type).ToLowerInvariant().Contains($needle)
    ))
  })
  $byCat = {
    param($a,$b)
    $ia = [array]::IndexOf($script:CatOrder, $a.Cat); if ($ia -lt 0) { $ia = 99 }
    $ib = [array]::IndexOf($script:CatOrder, $b.Cat); if ($ib -lt 0) { $ib = 99 }
    if ($ia -ne $ib) { return ($ia - $ib) }
    $c = [string]::Compare($a.Sub, $b.Sub, $true); if ($c) { return $c }
    [string]::Compare($a.Desc, $b.Desc, $true)
  }
  switch ($st.Sort) {
    'name' { $rows = @($rows | Sort-Object { $_.Name.ToLowerInvariant() }) }
    'fewest' { $rows = @($rows | Sort-Object { (@($_.Notes -split ' - ')).Count }, { $_.Cat }, { $_.Name }) }
    'most' { $rows = @($rows | Sort-Object { -(@($_.Notes -split ' - ')).Count }, { $_.Cat }, { $_.Name }) }
    'size' { $rows = @($rows | Sort-Object Bytes -Descending) }
    default { $rows = @($rows | Sort-Object @{Expression={ $i=[array]::IndexOf($script:CatOrder, $_.Cat); if($i -lt 0){99}else{$i} }}, Sub, Desc) }
  }
  return @($rows)
}

function Update-SelectedTray {
  $lstSelected.BeginUpdate()
  try {
    $lstSelected.Items.Clear()
    $names = @(Get-CheckedNames | Sort-Object)
    foreach ($n in $names) { [void]$lstSelected.Items.Add($n) }
    $lblSelTitle.Text = ("Selected packs ({0})" -f $names.Count)
  } finally { $lstSelected.EndUpdate() }; Sync-SelectedListHeight
  Update-ManageBarState
  Update-FixPreview
  Update-FixStatus
}

function Apply-SourceUI {
  # Bottom bar per Source (actions left, Open + Refresh always right):
  #   Installed: Add from disk | Fix selected | Remove      Broken: Fix selected      Disabled: Install selected
  $src = $script:CatalogSource
  foreach ($b in @($btnMgrAddDisk, $btnMgrAdd, $btnMgrRemove, $btnFixSelected)) { $b.Visible = $false }
  switch ($src) {
    'Installed' {
      Set-PmBottomRow @($btnMgrAddDisk, $btnFixSelected, $btnMgrRemove)
      Set-Tip $btnFixSelected 'Fix the checked installed packs (headers, unused names, load order)'
    }
    'Disabled' { Set-PmBottomRow @($btnMgrAdd) }
    default { # Broken
      Set-PmBottomRow @($btnFixSelected)
      Set-Tip $btnFixSelected 'Fix the checked Broken packs, then choose: install into the game, or send to Disabled'
    }
  }
  Update-ManageBarState
}

function Update-ManageBarState {
  $n = @(Get-CheckedNames).Count
  $src = $script:CatalogSource
  $btnFixSelected.Enabled = (($src -eq 'Broken' -or $src -eq 'Installed') -and $n -gt 0)
  $btnMgrAdd.Enabled = ($src -eq 'Disabled' -and $n -gt 0)
  $btnMgrAddDisk.Enabled = ($src -eq 'Installed')
  $btnMgrRemove.Enabled = ($src -eq 'Installed' -and $n -gt 0)
  Update-CatalogHeaderCheck
}

function Update-FixStatus {
  $src = $script:CatalogSource
  $total = @($script:CatalogRows).Count
  $fixedN = @(Get-ChildItem -LiteralPath $fixedDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ieq '.pak' }).Count
  $selN = @(Get-CheckedNames).Count
  $vis = $lstCatalog.Items.Count
  $lblFixTitle.Text = ("PACK MANAGER - Full catalog ({0})" -f $src)
  Set-Status ("{0}: {1} pack(s) | {2} selected | {3} shown | {4} in Fixed" -f $src, $total, $selN, $vis, $fixedN)
}

if (-not $script:CatalogStatusColors) { $script:CatalogStatusColors = @{} }

function Get-CatalogRowBackColor([System.Windows.Forms.ListViewItem]$item) {
  if ($item.Selected) { return $script:Theme.SelectBg }
  if ($item.Checked) { return $script:Theme.CheckedBg }
  return [System.Drawing.Color]$script:OuClearBg
}

function Apply-CatalogItemBaseColors([System.Windows.Forms.ListViewItem]$item) {
  $item.UseItemStyleForSubItems = $false
  $bg = Get-CatalogRowBackColor $item
  $accentRow = ($item.Selected -or $item.Checked)
  $item.BackColor = $bg
  $item.ForeColor = $script:ColorNormal
  foreach ($si in $item.SubItems) { $si.BackColor = $bg; $si.ForeColor = $script:ColorNormal }
  if (-not $accentRow) {
    $name = [string]$item.Tag
    if ($name -and $script:CatalogStatusColors.ContainsKey($name) -and $item.SubItems.Count -gt 1) {
      $item.SubItems[1].ForeColor = $script:CatalogStatusColors[$name]
    }
  }
}

function Refresh-CatalogRowStyles {
  foreach ($it in $lstCatalog.Items) { Apply-CatalogItemBaseColors $it }
}

function Draw-OuListCheckbox([System.Drawing.Graphics]$g, [System.Drawing.Rectangle]$bounds, [bool]$checked, [bool]$onAccentRow = $false, [switch]$Indeterminate) {
  $sz = 15
  $x = $bounds.X + 3
  $y = $bounds.Y + [Math]::Max(0, [int](($bounds.Height - $sz) / 2))
  $r = New-Object System.Drawing.Rectangle($x, $y, $sz, $sz)
# Dark charcoal box (near-black); white check when checked.
  $boxFill = [System.Drawing.Color]::FromArgb(12, 12, 14)
  $boxBorder = [System.Drawing.Color]::FromArgb(55, 55, 60)
  if ($onAccentRow) { $boxBorder = [System.Drawing.Color]::FromArgb(30, 30, 34) }
  $br = New-Object System.Drawing.SolidBrush $boxFill
  $g.FillRectangle($br, $r)
  $br.Dispose()
  $pen = New-Object System.Drawing.Pen $boxBorder, 1.5
  $g.DrawRectangle($pen, $r)
  $pen.Dispose()
  if ($checked) {
    $p2 = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 2.2
    $p2.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $p2.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $g.DrawLines($p2, @(
      (New-Object System.Drawing.Point(($x + 3), ($y + 8))),
      (New-Object System.Drawing.Point(($x + 6), ($y + 11))),
      (New-Object System.Drawing.Point(($x + 12), ($y + 3)))
    ))
    $p2.Dispose()
  } elseif ($Indeterminate) {
    $ib = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
    $g.FillRectangle($ib, ($x + 4), ($y + 6), 8, 3)
    $ib.Dispose()
  }
}

function Refresh-CatalogList([switch]$KeepShowroom) {
  # Full rescan of the current Source (disk + diagnostics), then redraw. Called by actions that change pack data,
  # the Refresh button, Source switches, and Show-Page when $script:CatalogDirty is set.
  # -KeepShowroom: the rescan is not because data changed (first show / Source switch), so leave Showroom results alone.
  Build-CatalogRows
  $script:CatalogDirty = $false
  $script:CatalogBuiltSource = $script:CatalogSource
  if (-not $KeepShowroom) { $script:ShowroomDirty = $true }
  # Drop checked names that no longer exist
  $exist = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($r in $script:CatalogRows) { [void]$exist.Add($r.Name) }
  $dead = @($script:CheckedNames | Where-Object { -not $exist.Contains($_) })
  foreach ($d in $dead) { [void]$script:CheckedNames.Remove($d) }
  Update-CatalogView
}

function Update-CatalogView {
  # Filter/sort the cached rows into the list (no disk scan). Keeps highlighted row(s) and top row when they survive the filter.
  $keepSel = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($si in $lstCatalog.SelectedItems) { $t = [string]$si.Tag; if ($t) { [void]$keepSel.Add($t) } }
  $keepTop = $null
  try { if ($lstCatalog.IsHandleCreated -and $lstCatalog.TopItem) { $keepTop = [string]$lstCatalog.TopItem.Tag } } catch { }

  # Rebuild subtype dropdown from current category (suppress events to avoid recursion)
  if ($script:FixFilterControls) {
    $st = Get-FixFilterState
    $subs = New-Object System.Collections.Generic.List[string]
    [void]$subs.Add('All')
    $script:CatalogRows | Where-Object { $st.Cat -eq 'All' -or $_.Cat -eq $st.Cat } |
      ForEach-Object { if ($_.Sub -and -not $subs.Contains($_.Sub)) { [void]$subs.Add($_.Sub) } }
    $sorted = @($subs[0]) + @($subs | Select-Object -Skip 1 | Sort-Object)
    $prev = $script:FixFilterControls.Sub.SelectedItem
    $script:SuppressFilter = $true
    try {
      $script:FixFilterControls.Sub.Items.Clear()
      foreach ($s in $sorted) { [void]$script:FixFilterControls.Sub.Items.Add($s) }
      if ($prev -and $sorted -contains $prev) { $script:FixFilterControls.Sub.SelectedItem = $prev }
      else { $script:FixFilterControls.Sub.SelectedIndex = 0 }
    } finally {
      $script:SuppressFilter = $false
    }
  }

  $rows = @(Get-FilteredCatalogRows)
  $script:SuppressCheck = $true
  $lstCatalog.BeginUpdate()
  try {
    $script:CatalogStatusColors = @{}
    $lstCatalog.Items.Clear()
    foreach ($r in $rows) {
      if (-not $r -or -not $r.PSObject.Properties['Name'] -or -not $r.Name) { continue }
      $item = New-Object System.Windows.Forms.ListViewItem([string]$r.Name)
      $item.Tag = $r.Name
      # Column order: Pak | Status | Type | Notes | Description
      [void]$item.SubItems.Add([string]$r.Status)
      [void]$item.SubItems.Add($r.Type)
      $noteShort = $r.Notes
      if ($noteShort.Length -gt 80) { $noteShort = $noteShort.Substring(0, 77) + '...' }
      [void]$item.SubItems.Add($noteShort)
      [void]$item.SubItems.Add([string]$r.Desc)
      if ($r.StatusColor) { $script:CatalogStatusColors[$r.Name] = $r.StatusColor }
      else { [void]$script:CatalogStatusColors.Remove($r.Name) }
      if ($script:CheckedNames.Contains($r.Name)) { $item.Checked = $true }
      Apply-CatalogItemBaseColors $item
      if ($r.Cat -eq 'Unknown' -and -not $item.Selected) {
        $item.ForeColor = $script:ColorUnknown
        $item.SubItems[0].ForeColor = $script:ColorUnknown
      }
      [void]$lstCatalog.Items.Add($item)
      if ($keepSel.Contains([string]$r.Name)) {
        $item.Selected = $true
        Apply-CatalogItemBaseColors $item
      }
    }
  } finally {
    $lstCatalog.EndUpdate()
    $script:SuppressCheck = $false
  }
  # TopItem only on a live list (setting it earlier forces handle creation and replays check notifications)
  if ($keepTop -and $lstCatalog.IsHandleCreated) {
    $script:SuppressCheck = $true
    try {
      foreach ($ti in $lstCatalog.Items) { if ([string]$ti.Tag -eq $keepTop) { $lstCatalog.TopItem = $ti; break } }
    } catch { } finally { $script:SuppressCheck = $false }
  }
  Update-SelectedTray
  Update-CatalogEmpty
}

function Build-FixFiltersRail {
  # Source toggle, Search and Category always visible; the rest sits under "More filters" (session-only state).
  Clear-LeftRail
  [void](Add-RailHeader 'Catalog filters')

  $panel = New-Object System.Windows.Forms.Panel
  $panel.Dock = 'Fill'
  $panel.AutoScroll = $true
  $panel.Padding = New-Object System.Windows.Forms.Padding(8)
  $panel.BackColor = [System.Drawing.Color]::Transparent
  $leftRail.Controls.Add($panel)
  $panel.BringToFront()

  $y = 8
  $lbSrc = New-Object System.Windows.Forms.Label
  $lbSrc.Text = 'Source'
  $lbSrc.Location = New-Object System.Drawing.Point(8, $y)
  $lbSrc.AutoSize = $true
  Set-OuLabel $lbSrc
  $panel.Controls.Add($lbSrc)
  $y += 18

  # Segmented toggle: three equal columns, one row (no wrapping)
  $srcSeg = New-Object System.Windows.Forms.TableLayoutPanel
  $srcSeg.Name = 'srcSeg'
  $srcSeg.Location = New-Object System.Drawing.Point(8, $y)
  $srcSeg.Size = New-Object System.Drawing.Size(190, 28)
  $srcSeg.ColumnCount = 3
  $srcSeg.RowCount = 1
  $srcSeg.Padding = New-Object System.Windows.Forms.Padding(0)
  $srcSeg.Margin = New-Object System.Windows.Forms.Padding(0)
  $srcSeg.BackColor = [System.Drawing.Color]::Transparent
  [void]$srcSeg.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
  for ($ci = 0; $ci -lt 3; $ci++) { [void]$srcSeg.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.333))) }
  $panel.Controls.Add($srcSeg)
  $script:SourceSegment = $srcSeg

  $script:SourceButtons = @{}
  $col = 0
  foreach ($srcName in @('Installed','Broken','Disabled')) {
    $sb = New-Object System.Windows.Forms.Button
    $sb.Text = $srcName
    $sb.Tag = $srcName
    $sb.Dock = 'Fill'
    $sb.AutoEllipsis = $false
    $sb.FlatStyle = 'Flat'
    $sb.Margin = New-Object System.Windows.Forms.Padding(1, 0, 1, 0)
    $sb.Padding = New-Object System.Windows.Forms.Padding(0)
    if ($srcName -eq $script:CatalogSource) { Set-OuRailSelected $sb } else { Set-OuRailIdle $sb }
    $sb.TextAlign = 'MiddleCenter'
    $script:SourceButtons[$srcName] = $sb
    Set-Tip $sb ("Show {0} packs in the catalog" -f $srcName)
    $srcSeg.Controls.Add($sb, $col, 0); $col++
    $sb.Add_Click({
      param($sender, $e)
      $next = [string]$sender.Tag
      if ($next -eq $script:CatalogSource) { return }
      $script:CatalogSource = $next
      $script:CheckedNames.Clear()
      $script:FixPrevIndex = 0
      foreach ($k in $script:SourceButtons.Keys) {
        $b = $script:SourceButtons[$k]
        if ($k -eq $script:CatalogSource) { Set-OuRailSelected $b } else { Set-OuRailIdle $b }
        $b.TextAlign = 'MiddleCenter'
      }
      Apply-SourceUI
      Refresh-CatalogList -KeepShowroom
      Step-OuBackground
    })
  }
  $y += 36

  function Add-LabeledCombo($parent, [string]$label, [string[]]$items, [int]$top) {
    $lb = New-Object System.Windows.Forms.Label
    $lb.Text = $label
    $lb.Location = New-Object System.Drawing.Point(8, $top)
    $lb.AutoSize = $true
    Set-OuLabel $lb
    $parent.Controls.Add($lb)
    $cb = New-Object System.Windows.Forms.ComboBox
    $cb.DropDownStyle = 'DropDownList'
    $cb.Location = New-Object System.Drawing.Point(8, ($top + 18))
    $cb.Width = 190
    foreach ($i in $items) { [void]$cb.Items.Add($i) }
    if ($cb.Items.Count) { $cb.SelectedIndex = 0 }
    Set-OuDarkInput $cb
    Set-OuHeavySurface $cb
    $parent.Controls.Add($cb)
    $cb
  }
  function Add-RailCheck($parent, [string]$text, [int]$top) {
    $ck = New-Object System.Windows.Forms.CheckBox
    $ck.Text = $text
    $ck.Location = New-Object System.Drawing.Point(8, $top)
    $ck.AutoSize = $true
    $ck.ForeColor = $script:Theme.Text
    $ck.BackColor = [System.Drawing.Color]::Transparent
    $parent.Controls.Add($ck)
    $ck
  }

  $lbS = New-Object System.Windows.Forms.Label
  $lbS.Text = 'Search'
  $lbS.Location = New-Object System.Drawing.Point(8, $y)
  $lbS.AutoSize = $true
  Set-OuLabel $lbS
  $panel.Controls.Add($lbS)
  $txtSearch = New-Object System.Windows.Forms.TextBox
  $txtSearch.Location = New-Object System.Drawing.Point(8, ($y + 18))
  $txtSearch.Width = 190
  Set-OuDarkInput $txtSearch
  Set-OuHeavySurface $txtSearch
  $panel.Controls.Add($txtSearch)
  Set-Tip $txtSearch 'Filter by pak name, description, type or notes'
  $y += 52

  $catItems = @('All') + @($script:CatOrder) + @('Unknown')
  $cmbCat = Add-LabeledCombo $panel 'Category' $catItems $y; $y += 54

  # "More filters" expander
  $btnMore = New-Object System.Windows.Forms.Button
  $btnMore.Name = 'btnMoreFilters'
  $btnMore.Location = New-Object System.Drawing.Point(4, $y)
  $btnMore.Size = New-Object System.Drawing.Size(194, 26)
  Set-OuRailIdle $btnMore
  $btnMore.Padding = New-Object System.Windows.Forms.Padding(2, 0, 0, 0)
  $btnMore.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
  $panel.Controls.Add($btnMore)
  Set-Tip $btnMore 'Show or hide Subtype, Bike class, Sort, Has preview, Clashes and Clash-free only'
  $y += 30

  $more = New-Object System.Windows.Forms.Panel
  $more.Name = 'pnlMoreFilters'
  $more.Location = New-Object System.Drawing.Point(0, $y)
  $more.BackColor = [System.Drawing.Color]::Transparent
  $panel.Controls.Add($more)
  $my = 0
  $cmbSub = Add-LabeledCombo $more 'Subtype' @('All') $my; $my += 52
  $clsItems = @('All') + @($script:ClassOrder)
  $cmbCls = Add-LabeledCombo $more 'Bike class' $clsItems $my; $my += 52
  $cmbSort = Add-LabeledCombo $more 'Sort' @('By category','By pak name','Fewest notes first','Most notes first','Largest first') $my; $my += 54
  $chkHasPrev = Add-RailCheck $more 'Has preview' $my; $my += 24
  $chkClashes = Add-RailCheck $more 'Clashes' $my; $my += 24
  $chkSolo = Add-RailCheck $more 'Clash-free only' $my; $my += 26
  Set-Tip $chkHasPrev 'Only packs that already have a preview image'
  Set-Tip $chkClashes 'Only packs whose Status is Clash'
  Set-Tip $chkSolo 'Only packs with no clash notes'
  $more.Size = New-Object System.Drawing.Size(204, $my)
  $more.Visible = [bool]$script:PmMoreFiltersOpen

  $script:FixFilterControls = @{
    Cat = $cmbCat; Sub = $cmbSub; Cls = $cmbCls; Sort = $cmbSort; Search = $txtSearch; HasPrev = $chkHasPrev; Clashes = $chkClashes; Solo = $chkSolo
    More = $btnMore; MorePanel = $more
  }
  Update-PmMoreFiltersButton

  $btnMore.Add_Click({ Toggle-PmMoreFilters })

  # Filters only re-filter cached rows; disk rescans happen on data changes / Refresh / Source switch.
  $handler = { if (-not $script:SuppressFilter) { Update-CatalogView }; Update-PmMoreFiltersButton }
  $cmbCat.Add_SelectedIndexChanged({
    if ($script:SuppressFilter) { return }
    # reset subtype when category changes
    if ($script:FixFilterControls) {
      $script:SuppressFilter = $true
      try { $script:FixFilterControls.Sub.SelectedIndex = 0 } finally { $script:SuppressFilter = $false }
    }
    Update-CatalogView
    Update-PmMoreFiltersButton
  })
  $cmbSub.Add_SelectedIndexChanged($handler)
  $cmbCls.Add_SelectedIndexChanged($handler)
  $cmbSort.Add_SelectedIndexChanged($handler)
  $chkHasPrev.Add_CheckedChanged($handler)
  $chkClashes.Add_CheckedChanged($handler)
  $chkSolo.Add_CheckedChanged($handler)
  $txtSearch.Add_TextChanged($handler)
}

function Toggle-PmMoreFilters {
  $script:PmMoreFiltersOpen = -not $script:PmMoreFiltersOpen
  if ($script:FixFilterControls -and $script:FixFilterControls.MorePanel) { $script:FixFilterControls.MorePanel.Visible = $script:PmMoreFiltersOpen }
  Update-PmMoreFiltersButton
}

function Update-PmMoreFiltersButton {
  # "More filters >" / "More filters v"; when collapsed, say how many hidden filters are active.
  $c = $script:FixFilterControls
  if (-not $c -or -not $c.ContainsKey('More') -or -not $c.More) { return }
  $active = 0
  if ($c.Sub.SelectedIndex -gt 0) { $active++ }
  if ($c.Cls.SelectedIndex -gt 0) { $active++ }
  if ($c.HasPrev.Checked) { $active++ }
  if ($c.Clashes.Checked) { $active++ }
  if ($c.Solo.Checked) { $active++ }
  $arrow = $(if ($script:PmMoreFiltersOpen) { [char]0x25BE } else { [char]0x25B8 })
  $t = 'More filters ' + $arrow
  if (-not $script:PmMoreFiltersOpen -and $active -gt 0) { $t += (' ({0} on)' -f $active) }
  $c.More.Text = $t
}

# Highlight = browse preview only (does not clear checks). Checkboxes = held action selection.
$lstCatalog.Add_SelectedIndexChanged({
  if ($script:SuppressCheck) { return }
  Refresh-CatalogRowStyles
  $lstCatalog.Invalidate()
  Update-FixPreview
})

$lstCatalog.Add_ItemChecked({
  param($sender, $e)
  if ($script:SuppressCheck) { return }
  $name = [string]$e.Item.Tag
  if (-not $name) { $name = [string]$e.Item.Text }
  if (-not $name) { return }
  if ($e.Item.Checked) { [void]$script:CheckedNames.Add($name) }
  else { [void]$script:CheckedNames.Remove($name) }
  Update-SelectedTray
  Refresh-CatalogRowStyles
  $lstCatalog.Invalidate()
})

# Shift+click range-check from last clicked row
$lstCatalog.Add_MouseClick({
  param($sender, $e)
  $hit = $lstCatalog.HitTest($e.Location)
  if (-not $hit.Item) { return }
  $idx = $hit.Item.Index
  if ([System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Shift -and $script:LastCatalogIndex -ge 0) {
    $a = [Math]::Min($script:LastCatalogIndex, $idx)
    $b = [Math]::Max($script:LastCatalogIndex, $idx)
    $state = $lstCatalog.Items[$script:LastCatalogIndex].Checked
    $script:SuppressCheck = $true
    try {
      for ($i = $a; $i -le $b; $i++) {
        $lstCatalog.Items[$i].Checked = $state
        $name = [string]$lstCatalog.Items[$i].Tag
        if (-not $name) { $name = [string]$lstCatalog.Items[$i].Text }
        if ($state) { [void]$script:CheckedNames.Add($name) } else { [void]$script:CheckedNames.Remove($name) }
      }
    } finally { $script:SuppressCheck = $false }
    Update-SelectedTray
  }
  $script:LastCatalogIndex = $idx
})

function Invoke-GuiFixer {
  try {
    if ($script:CatalogSource -ne 'Broken') {
      [void][System.Windows.Forms.MessageBox]::Show('This fixer run only works on the Broken source. Switch Source to Broken, or use Fix selected on Installed.', 'Fix selected')
      return
    }
    $names = @(Get-CheckedNames)
    if (-not $names.Count) {
      [void][System.Windows.Forms.MessageBox]::Show('Check one or more packs first.', 'Fix selected')
      return
    }
    # Verify they still exist in Broken
    $pending = @()
    foreach ($n in $names) {
      $p = Join-Path $brokenDir $n
      if (Test-Path -LiteralPath $p) { $pending += $n }
    }
    if (-not $pending.Count) {
      [void][System.Windows.Forms.MessageBox]::Show("None of the selected packs are still in Pack Files\Broken.", 'Fix selected')
      Refresh-CatalogList
      return
    }
    $ask = [System.Windows.Forms.MessageBox]::Show(
      ("Fix {0} selected pack(s)?`n`nYes = fix and install into the game (copy stays in Fixed)`nNo = fix only, do not install (those packs go to Disabled)`nCancel = abort" -f $pending.Count),
      'Fix selected',
      [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
      [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($ask -eq [System.Windows.Forms.DialogResult]::Cancel) { Set-Status 'Fixer cancelled'; return }
    $mode = if ($ask -eq [System.Windows.Forms.DialogResult]::Yes) { 'yes' } else { 'no' }
    if ($mode -eq 'yes') {
      if (-not $game) {
        [void][System.Windows.Forms.MessageBox]::Show('Set the game folder first (Change button), or choose No to fix without installing.')
        return
      }
      if (-not (Wait-GameClosedGui)) { Set-Status 'Cancelled - game still running'; return }
    }
    Set-Status ("Running fixer on {0} selected pack(s)..." -f $pending.Count)
    [System.Windows.Forms.Application]::DoEvents()
    $out = @(& $fixer -NoPrompt -InstallMode $mode -OnlyPacks $pending 2>&1)
    $result = $out | Where-Object { $_ -is [string] -and $_ -like 'RESULT|*' } | Select-Object -Last 1
    $nFixed = 0; $nOk = 0; $nInst = 0; $nFail = 0; $nSkip = 0; $nDis = 0
    if ($result) {
      $parts = $result.Split('|')
      for ($i = 1; $i -lt $parts.Count - 1; $i += 2) {
        switch ($parts[$i]) {
          'FIXED' { $nFixed = [int]$parts[$i+1] }
          'OK' { $nOk = [int]$parts[$i+1] }
          'SKIPPED' { $nSkip = [int]$parts[$i+1] }
          'INSTALLED' { $nInst = [int]$parts[$i+1] }
          'FAIL' { $nFail = [int]$parts[$i+1] }
          'DISABLED' { $nDis = [int]$parts[$i+1] }
        }
      }
    }
    $script:CheckedNames.Clear()
    Refresh-CatalogList
    # Catalog is PACK MANAGER now; Refresh-CatalogList already ran above.
    $msg = ("{0} fixed, {1} already OK" -f $nFixed, $nOk)
    if ($nSkip) { $msg += (", {0} skipped" -f $nSkip) }
    if ($mode -eq 'yes') { $msg += (", {0} installed" -f $nInst) }
    if ($nFail) { $msg += (", {0} install failed" -f $nFail) }
    if ($nDis) { $msg += (", {0} moved to Disabled" -f $nDis) }
    Set-Status $msg
    [void][System.Windows.Forms.MessageBox]::Show($msg, 'Fixer done')
  } catch {
    Set-Status ("Fixer failed: {0}" -f $_.Exception.Message)
    [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Fixer failed')
  }
}

function Invoke-PmRefresh {
  # Refresh button / F5: rescan the active Source (on Installed also rewrites Installed Packs.txt).
  if ($script:CatalogSource -eq 'Installed') {
    try { Refresh-List } catch { }
  }
  Refresh-CatalogList
}
$btnRefreshBroken.Add_Click({ Invoke-PmRefresh })
$btnFixSelected.Add_Click({
  if ($script:CatalogSource -eq 'Broken') { Invoke-GuiFixer } else { Invoke-MgrFixBroken }
})

function Invoke-MgrAdd {
  try {
    if ($script:CatalogSource -ne 'Disabled') {
      [void][System.Windows.Forms.MessageBox]::Show('Switch Source to Disabled and check the packs to install.', 'Install selected')
      return
    }
    if (-not $game) { [void][System.Windows.Forms.MessageBox]::Show('Set the game folder first.'); return }
    $sel = @(Get-CheckedCatalogFiles)
    if (-not $sel.Count) {
      [void][System.Windows.Forms.MessageBox]::Show('Check one or more Disabled packs to install.', 'Install selected')
      return
    }
    if (-not (Wait-GameClosedGui)) { Set-Status 'Cancelled - game still running'; return }
    $go = Confirm-ClashesGui $sel
    if ($go -eq 'none') { Set-Status 'Install cancelled'; return }
    if ($go -eq 'skip') { $sel = @(Filter-SkipClashes $sel) }
    $n = 0
    foreach ($p in $sel) {
      if (-not (Test-Path -LiteralPath $p.FullName)) { continue }
      Set-Status "Fixing / installing $($p.Name)..."
      [System.Windows.Forms.Application]::DoEvents()
      $fixed = Fix-Pack $p
      if (-not $fixed) { continue }
      if (Move-Safe $fixed $game) {
        Set-Status "INSTALLED: $($fixed.Name)"
        $n++
      }
    }
    $script:CheckedNames.Clear()
    Refresh-CatalogList
    Set-Status ("Installed {0} pack(s)" -f $n)
  } catch {
    [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Install failed')
  }
}

function Invoke-MgrRemove {
  try {
    if ($script:CatalogSource -ne 'Installed') {
      [void][System.Windows.Forms.MessageBox]::Show('Switch Source to Installed and select packs to remove.', 'Remove')
      return
    }
    if (-not $game) { [void][System.Windows.Forms.MessageBox]::Show('Set the game folder first.'); return }
    # Snapshot ALL selected packs BEFORE any UI clear/rebuild
    $sel = @(Get-CheckedCatalogFiles)
    if (-not $sel.Count) {
      [void][System.Windows.Forms.MessageBox]::Show('Select one or more installed packs to remove.')
      return
    }
    if (-not (Wait-GameClosedGui)) { Set-Status 'Cancelled - game still running'; return }
    $n = 0
    $failed = @()
    foreach ($p in $sel) {
      if ($null -eq $p -or -not $p.FullName) { $failed += '(invalid entry)'; continue }
      if (-not (Test-Path -LiteralPath $p.FullName)) { continue }
      if (Move-Safe $p $disD) {
        Set-Status "REMOVED: $($p.Name)"
        $n++
      } else {
        $failed += $p.Name
      }
    }
    $script:CheckedNames.Clear()
    Refresh-CatalogList
    Set-Status ("Removed {0} pack(s) to Pack Files\Disabled" -f $n)
    if ($failed.Count) {
      [void][System.Windows.Forms.MessageBox]::Show(("Could not move {0} pack(s):
{1}" -f $failed.Count, ($failed -join "
")), 'Remove')
    }
  } catch {
    [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Remove failed')
  }
}

function Invoke-MgrFixBroken {
  try {
    if ($script:CatalogSource -ne 'Installed') {
      [void][System.Windows.Forms.MessageBox]::Show('Switch Source to Installed or Broken, check packs, then press Fix selected.', 'Fix selected')
      return
    }
    if (-not $game) { [void][System.Windows.Forms.MessageBox]::Show('Set the game folder first.'); return }
    $broken = @(Get-BrokenInstalled)
    if (-not $broken.Count) {
      [void][System.Windows.Forms.MessageBox]::Show('No broken packs installed.')
      Set-Status ("{0} packs installed - 0 broken" -f @(Installed).Count)
      return
    }
    $sel = @(Get-CheckedCatalogFiles)
    $targets = @()
    if ($sel.Count) {
      $brokenNames = @($broken | ForEach-Object { $_.Name.ToLower() })
      $targets = @($sel | Where-Object { $brokenNames -contains $_.Name.ToLower() })
      if (-not $targets.Count) {
        $r = [System.Windows.Forms.MessageBox]::Show(
          "None of the selected packs are broken.`n`nFix all $($broken.Count) broken pack(s) instead?",
          'Fix selected',
          [System.Windows.Forms.MessageBoxButtons]::YesNo,
          [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($r -ne 'Yes') { return }
        $targets = $broken
      }
    } else {
      $r = [System.Windows.Forms.MessageBox]::Show(
        "No selection - fix all $($broken.Count) broken installed pack(s)?",
        'Fix selected',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
      if ($r -ne 'Yes') { return }
      $targets = $broken
    }
    if (-not (Wait-GameClosedGui)) { Set-Status 'Cancelled - game still running'; return }
    $n = 0
    foreach ($p in $targets) {
      if (-not (Test-Path -LiteralPath $p.FullName)) { continue }
      Set-Status "Fixing $($p.Name)..."
      [System.Windows.Forms.Application]::DoEvents()
      try {
        $r = Fix-Pack $p -Loud
        if ($r) { $n++ }
      } catch {
        [void][System.Windows.Forms.MessageBox]::Show("Couldn't fix $($p.Name): $($_.Exception.Message)")
      }
    }
    $script:CheckedNames.Clear()
    Refresh-CatalogList
    Set-Status ("Fixed {0} pack(s)" -f $n)
  } catch {
    [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Fix failed')
  }
}

function Invoke-MgrAddFromDisk {
  try {
    if ($script:CatalogSource -ne 'Installed') {
      [void][System.Windows.Forms.MessageBox]::Show('Switch Source to Installed to add packs from disk.', 'Add from disk')
      return
    }
    if (-not $game) { [void][System.Windows.Forms.MessageBox]::Show('Set the game folder first.'); return }
    if (-not (Wait-GameClosedGui)) { Set-Status 'Cancelled - game still running'; return }
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = 'PAK packs (*.pak)|*.pak|All files (*.*)|*.*'
    $ofd.Multiselect = $true
    $ofd.Title = 'Select pack(s) to add'
    if ($ofd.ShowDialog() -ne 'OK') { return }
    $sel = @()
    foreach ($fp in $ofd.FileNames) {
      $name = Split-Path $fp -Leaf
      $dest = Join-Path $disD $name
      if (-not (Test-Path -LiteralPath $dest)) {
        Copy-Item -LiteralPath $fp -Destination $dest -Force
      }
      $sel += Get-Item -LiteralPath $dest
    }
    if (-not $sel.Count) { return }
    $go = Confirm-ClashesGui $sel
    if ($go -eq 'none') { Set-Status 'Add cancelled'; return }
    if ($go -eq 'skip') { $sel = @(Filter-SkipClashes $sel) }
    $n = 0
    foreach ($p in $sel) {
      if (-not (Test-Path -LiteralPath $p.FullName)) { continue }
      Set-Status "Fixing / adding $($p.Name)..."
      [System.Windows.Forms.Application]::DoEvents()
      $fixed = Fix-Pack $p
      if (-not $fixed) { continue }
      if (Move-Safe $fixed $game) {
        Set-Status "ADDED: $($fixed.Name)"
        $n++
      }
    }
    $script:CheckedNames.Clear()
    # Stay on Installed so the newly added packs appear in the catalog
    $script:CatalogSource = 'Installed'
    Apply-SourceUI
    Refresh-CatalogList
    Set-Status ("Added {0} pack(s) from disk" -f $n)
  } catch {
    [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Add from disk failed')
  }
}

function Open-InstalledPacksTxt {
  try {
    if (-not (Test-Path -LiteralPath $listTxt)) {
      Set-Status 'Creating Installed Packs.txt...'
      [System.Windows.Forms.Application]::DoEvents()
      Refresh-List
    }
    if (-not (Test-Path -LiteralPath $listTxt)) {
      [void][System.Windows.Forms.MessageBox]::Show("Could not create Installed Packs.txt.`nSet the game folder first.", 'Open Installed Packs.txt')
      return
    }
    Start-Process -FilePath $listTxt
  } catch {
    [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Open Installed Packs.txt')
  }
}

$btnMgrAddDisk.Add_Click({ Invoke-MgrAddFromDisk })
$btnMgrAdd.Add_Click({ Invoke-MgrAdd })
$btnMgrRemove.Add_Click({ Invoke-MgrRemove })

# ---------- Open (menu): Game folder, Broken, Disabled, Fixed, Originals, Installed Packs.txt ----------
function Get-PmOpenTarget([string]$key, [switch]$Ensure) {
  # Path behind each Open menu item. -Ensure creates a missing Pack Files folder / Installed Packs.txt first.
  $p = $null
  switch ($key) {
    'Game'      { if ($game) { return [string]$game } else { return $null } }
    'Broken'    { $p = $brokenDir }
    'Disabled'  { $p = $disabledDir }
    'Fixed'     { $p = $fixedDir }
    'Originals' { $p = $origDir }
    'List'      { return [string]$listTxt }
  }
  if ($Ensure -and $p -and -not (Test-Path -LiteralPath $p)) { [void][System.IO.Directory]::CreateDirectory($p) }
  return $p
}
function Open-PmTarget([string]$key) {
  try {
    if ($key -eq 'List') { Open-InstalledPacksTxt; return }
    $p = Get-PmOpenTarget $key -Ensure
    if (-not $p) { [void][System.Windows.Forms.MessageBox]::Show('Set the game folder first (Change button at the top).', 'Open'); return }
    if (-not (Test-Path -LiteralPath $p)) { [void][System.Windows.Forms.MessageBox]::Show("Folder not found:`n$p", 'Open'); return }
    Start-Process explorer.exe $p
  } catch {
    [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Open')
  }
}
$script:PmOpenMenu = New-OuDarkMenu
$script:PmOpenMenu.Name = 'PmOpenMenu'
[void](Add-OuMenuItem $script:PmOpenMenu 'Game folder' 'Game' 'Open the game data folder (installed packs) in Explorer')
[void]$script:PmOpenMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void](Add-OuMenuItem $script:PmOpenMenu 'Broken' 'Broken' 'Open Pack Files\Broken (drop packs to fix here)')
[void](Add-OuMenuItem $script:PmOpenMenu 'Disabled' 'Disabled' 'Open Pack Files\Disabled (packs not in the game)')
[void](Add-OuMenuItem $script:PmOpenMenu 'Fixed' 'Fixed' 'Open Pack Files\Fixed (copies of fixed packs)')
[void](Add-OuMenuItem $script:PmOpenMenu 'Originals' 'Originals' 'Open Pack Files\Originals (untouched originals)')
[void]$script:PmOpenMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void](Add-OuMenuItem $script:PmOpenMenu 'Installed Packs.txt' 'List' 'Open Pack Manager\Installed Packs.txt (creates it first if needed)')
foreach ($mi in $script:PmOpenMenu.Items) {
  if ($mi -is [System.Windows.Forms.ToolStripMenuItem]) { $mi.Add_Click({ param($sender, $e) Open-PmTarget ([string]$sender.Tag) }) }
}
$script:PmOpenMenu.Add_Opening({
  foreach ($mi in $script:PmOpenMenu.Items) {
    if ($mi -is [System.Windows.Forms.ToolStripMenuItem] -and [string]$mi.Tag -eq 'Game') { $mi.Enabled = [bool]$game }
  }
})
$btnPmOpen.Add_Click({ $script:PmOpenMenu.Show($btnPmOpen, (New-Object System.Drawing.Point($btnPmOpen.Width, 0)), [System.Windows.Forms.ToolStripDropDownDirection]::AboveLeft) })

# F5 = Refresh while PACK MANAGER is showing
function Invoke-PmKey([System.Windows.Forms.Keys]$key) {
  if ($key -ne [System.Windows.Forms.Keys]::F5) { return $false }
  if ($script:CurrentPage -ne 'PACK MANAGER' -or $script:ShowroomPreloading) { return $false }
  Invoke-PmRefresh
  return $true
}
$form.KeyPreview = $true
$form.Add_KeyDown({
  param($sender, $e)
  if (Invoke-PmKey $e.KeyCode) { $e.Handled = $true; $e.SuppressKeyPress = $true }
})



# ---------- ToolTips (PACK MANAGER + shared actions) ----------
$script:UiToolTip = New-Object System.Windows.Forms.ToolTip
$script:UiToolTip.AutoPopDelay = 10000
$script:UiToolTip.InitialDelay = 400
$script:UiToolTip.ReshowDelay = 200
$script:UiToolTip.ShowAlways = $true
function Set-Tip([System.Windows.Forms.Control]$ctrl, [string]$text) {
  if ($null -eq $ctrl) { return }
  $script:UiToolTip.SetToolTip($ctrl, $text)
}
Set-Tip $btnMgrAddDisk 'Pick .pak files from disk, copy into Disabled, fix them, and install into the game'
Set-Tip $btnMgrAdd 'Fix and install the checked Disabled packs into the game'
Set-Tip $btnMgrRemove 'Move the checked installed packs out of the game into Disabled'
Set-Tip $btnFixSelected 'Fix the checked installed packs (headers, unused names, load order)'
Set-Tip $btnPmOpen 'Open a folder in Explorer: game, Broken, Disabled, Fixed, Originals, or Installed Packs.txt'
Set-Tip $btnRefreshBroken 'Refresh (F5)'
Set-Tip $btnFixMakePrev 'Build preview images for the checked packs'
Set-Tip $btnFixDelPrev 'More preview actions (Delete previews' + [char]0x2026 + ')'
Set-Tip $btnFixFullScreen 'Full screen'
Set-Tip $btnFixPrevBack 'Show the previous selected pack preview'
Set-Tip $btnFixPrevNext 'Show the next selected pack preview'
Set-Tip $btnChange 'Change the saved Open Unleashed game data folder'
# Top nav tips
foreach ($nk in @($navButtons.Keys)) {
  $nb = $navButtons[$nk]
  switch ($nk) {
    'PACK MANAGER' { Set-Tip $nb 'Manage installed, Broken, and Disabled packs' }
    'GALLERY'       { Set-Tip $nb 'Showroom preview gallery and Custom Packs' }
    'SETTINGS'      { Set-Tip $nb 'Game folder, paths, and advanced settings.txt' }
    'ABOUT'         { Set-Tip $nb 'README and Version (with Check for updates)' }
  }
}

# ==================== Gallery (Showroom / Custom Packs) ====================
$pnlManage = New-Object System.Windows.Forms.Panel
$pnlManage.Dock = 'Fill'
$pnlManage.Visible = $false
Set-OuSeeThroughHost $pnlManage
$hostPanel.Controls.Add($pnlManage)

# Legacy Installed Packs panel kept for helpers; not shown in Gallery.
$pnlInstalled = New-Object System.Windows.Forms.Panel
$pnlInstalled.Dock = 'Fill'
$pnlInstalled.Visible = $false
$pnlManage.Controls.Add($pnlInstalled)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = 'Installed Packs'
$lblTitle.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object System.Drawing.Point(4, 4)
$pnlInstalled.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = 'View and manage installed custom packs.'
$lblSub.AutoSize = $true
$lblSub.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
$lblSub.Location = New-Object System.Drawing.Point(6, 32)
$pnlInstalled.Controls.Add($lblSub)

$lst = New-Object System.Windows.Forms.ListView
$lst.View = 'Details'
$lst.FullRowSelect = $true
$lst.MultiSelect = $true
$lst.HideSelection = $false
$lst.GridLines = $true
$lst.Location = New-Object System.Drawing.Point(4, 58)
$lst.Size = New-Object System.Drawing.Size(520, 400)
$lst.Anchor = 'Top,Bottom,Left,Right'
[void]$lst.Columns.Add('Pack', 300)
[void]$lst.Columns.Add('Status', 180)
$pnlInstalled.Controls.Add($lst)

$lblCount = New-Object System.Windows.Forms.Label
$lblCount.Text = '0 packs listed'
$lblCount.AutoSize = $true
$lblCount.Location = New-Object System.Drawing.Point(6, 466)
$lblCount.Anchor = 'Bottom,Left'
$lblCount.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
$pnlInstalled.Controls.Add($lblCount)

$grpPrev = New-Object System.Windows.Forms.GroupBox
$grpPrev.Text = 'Preview'
$grpPrev.Location = New-Object System.Drawing.Point(536, 58)
$grpPrev.Size = New-Object System.Drawing.Size(260, 340)
$grpPrev.Anchor = 'Top,Bottom,Right'
$pnlInstalled.Controls.Add($grpPrev)

$pic = New-Object System.Windows.Forms.PictureBox
$pic.Dock = 'Fill'
$pic.SizeMode = 'Zoom'
$pic.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
$grpPrev.Controls.Add($pic)

$lblNoPrev = New-Object System.Windows.Forms.Label
$lblNoPrev.Text = 'No preview available'
$lblNoPrev.Dock = 'Bottom'
$lblNoPrev.Height = 24
$lblNoPrev.TextAlign = 'MiddleCenter'
$lblNoPrev.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 120)
$grpPrev.Controls.Add($lblNoPrev)

$btnAdd = New-ActionButton '+ Add'
$btnRemove = New-ActionButton 'Remove'
$btnFix = New-ActionButton 'Fix Broken'
$btnRefresh = New-ActionButton 'Refresh'
$btnRow = New-ButtonTable @($btnAdd, $btnRemove, $btnFix, $btnRefresh)
Set-OuPrimaryButton $btnAdd
Set-OuPrimaryButton $btnFix
$btnRow.Location = New-Object System.Drawing.Point(4, 490)
$btnRow.Size = New-Object System.Drawing.Size(792, 40)
$btnRow.Anchor = 'Bottom,Left,Right'
$pnlInstalled.Controls.Add($btnRow)

# ----- Showroom page (center card grid + shared right preview) -----
$pnlShowroom = New-Object System.Windows.Forms.Panel
$pnlShowroom.Dock = 'Fill'
$pnlShowroom.Visible = $false
$pnlShowroom.Name = 'pnlShowroom'
Enable-OuGlass $pnlShowroom ([int]$script:Theme.GlassAlphaPreview)
$pnlManage.Controls.Add($pnlShowroom)

$showSplit = New-Object System.Windows.Forms.SplitContainer
$showSplit.Dock = 'Fill'
$showSplit.Orientation = 'Vertical'
$showSplit.SplitterWidth = 6
$showSplit.BackColor = $script:Theme.Splitter
$showSplit.Name = 'showSplit'
Set-OuSeeThroughHost $showSplit.Panel1
Set-OuSeeThroughHost $showSplit.Panel2
$showSplit.Add_SplitterMoved({ Request-OuGlassRefresh })
$pnlShowroom.Controls.Add($showSplit)

$showCenterHost = New-Object System.Windows.Forms.Panel
$showCenterHost.Dock = 'Fill'
$showCenterHost.Name = 'showCenterHost'
Enable-OuGlass $showCenterHost ([int]$script:Theme.GlassAlphaPreview)
$showSplit.Panel1.Controls.Add($showCenterHost)

$lblShowTitle = New-Object System.Windows.Forms.Label
$lblShowTitle.Text = 'SHOWROOM'
$lblShowTitle.Dock = 'Top'
$lblShowTitle.Height = 28
$lblShowTitle.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$lblShowTitle.Padding = New-Object System.Windows.Forms.Padding(8, 6, 0, 0)
$lblShowTitle.Name = 'lblShowTitle'
Set-OuLabel $lblShowTitle
$showCenterHost.Controls.Add($lblShowTitle)

$lblShowMissing = New-Object System.Windows.Forms.Label
  $lblShowMissing.Text = '0 items in this filter have no usable thumb'
$lblShowMissing.Dock = 'Bottom'
$lblShowMissing.Height = 26
$lblShowMissing.TextAlign = 'MiddleLeft'
$lblShowMissing.Padding = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
$lblShowMissing.Name = 'lblShowMissing'
Set-OuLabel $lblShowMissing -Muted
$showCenterHost.Controls.Add($lblShowMissing)

$showCardFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$showCardFlow.Dock = 'Fill'
$showCardFlow.AutoScroll = $true
$showCardFlow.WrapContents = $true
$showCardFlow.FlowDirection = 'LeftToRight'
$showCardFlow.Padding = New-Object System.Windows.Forms.Padding(6)
$showCardFlow.BackColor = [System.Drawing.Color]::Transparent
$showCardFlow.Name = 'showCardFlow'
$showCenterHost.Controls.Add($showCardFlow)
Enable-OuGlass $showCardFlow ([int]$script:Theme.GlassAlphaPreview)
# Search progress (visible only while Search preloads the card thumbs)
# Custom-painted bar (WinForms ProgressBar ignores ForeColor under visual styles): dark track + accent-red fill.
$script:ShowroomProgress = New-Object System.Windows.Forms.Panel
$script:ShowroomProgress.Dock = 'Top'
$script:ShowroomProgress.Height = 6
$script:ShowroomProgress.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 44)
$script:ShowroomProgress.Visible = $false
$script:ShowroomProgress.Name = 'showroomProgress'
$script:ShowroomProgressFill = New-Object System.Windows.Forms.Panel
$script:ShowroomProgressFill.Dock = 'Left'
$script:ShowroomProgressFill.Width = 0
$script:ShowroomProgressFill.BackColor = $script:Theme.Accent
$script:ShowroomProgressFill.Name = 'showroomProgressFill'
$script:ShowroomProgress.Controls.Add($script:ShowroomProgressFill)
$script:ShowroomProgressPct = 0
function Set-ShowroomProgress([int]$pct) {
  if (-not $script:ShowroomProgress) { return }
  $pct = [Math]::Max(0, [Math]::Min(100, $pct))
  $script:ShowroomProgressPct = $pct
  $w = [int][Math]::Round($script:ShowroomProgress.ClientSize.Width * $pct / 100.0)
  if ($script:ShowroomProgressFill.Width -ne $w) { $script:ShowroomProgressFill.Width = $w }
}
$script:ShowroomProgress.Add_Resize({ Set-ShowroomProgress $script:ShowroomProgressPct })
$showCenterHost.Controls.Add($script:ShowroomProgress)
$script:ShowroomProgress.BringToFront()
$showCardFlow.BringToFront()

$showPrevHost = New-Object System.Windows.Forms.Panel
$showPrevHost.Dock = 'Fill'
$showPrevHost.Name = 'showPrevHost'
Set-OuSeeThroughHost $showPrevHost
$showSplit.Panel2.Controls.Add($showPrevHost)

$script:ShowSplitsInit = $false
function Init-ShowSplitters {
  if ($script:ShowSplitsInit) { return }
  if ($showSplit.Width -lt 400) { return }
  try {
    $showSplit.Panel1MinSize = 220
    $showSplit.Panel2MinSize = 160
    $showSplit.SplitterDistance = [Math]::Max(220, $showSplit.Width - 266)
  } catch {}
  $script:ShowSplitsInit = $true
}
$pnlShowroom.Add_VisibleChanged({ if ($pnlShowroom.Visible) { Init-ShowSplitters } })
$pnlShowroom.Add_SizeChanged({ if ($pnlShowroom.Visible) { Init-ShowSplitters } })

# Custom Packs (coming soon teaser). Left-aligned block centered on the glass panel; Update-CustomPacksLayout re-centers on resize.
$pnlCustomPacks = New-Object System.Windows.Forms.Panel
$pnlCustomPacks.Dock = 'Fill'
$pnlCustomPacks.Visible = $false
$pnlCustomPacks.Name = 'pnlCustomPacks'
Enable-OuGlass $pnlCustomPacks 200
$pnlManage.Controls.Add($pnlCustomPacks)
$script:CustomPacksTeaser = [ordered]@{
  Tag     = 'COMING SOON'
  Title   = 'Custom Packs'
  Sub     = 'Build your own packs from the items you see in the Showroom.'
  Bullets = @(
    'Pick bikes and gear: helmet, goggles, jersey & pants, and boots',
    'Build full rider outfits from pieces of different packs',
    'Every piece gets its own slot, so nothing overwrites anything else',
    'Bike skins stay on their own model, limited to the game''s liveries'
  )
}
$script:CustomPacksCtl = @{ Bullets = @(); Dots = @() }
function New-CustomPacksLabel([string]$text, [float]$size, [System.Drawing.FontStyle]$style, [System.Drawing.Color]$color, [string]$name) {
  $l = New-Object System.Windows.Forms.Label
  $l.Text = $text
  $l.Name = $name
  $l.AutoSize = $true
  $l.UseMnemonic = $false
  $l.Font = New-Object System.Drawing.Font('Segoe UI', $size, $style)
  $l.BackColor = [System.Drawing.Color]::Transparent
  $l.ForeColor = $color
  $pnlCustomPacks.Controls.Add($l)
  $l
}
$script:CustomPacksCtl.Tag = New-CustomPacksLabel $script:CustomPacksTeaser.Tag 9 ([System.Drawing.FontStyle]::Bold) $script:Theme.Accent 'lblCustomPacksTag'
$script:CustomPacksCtl.Title = New-CustomPacksLabel $script:CustomPacksTeaser.Title 22 ([System.Drawing.FontStyle]::Bold) $script:Theme.Text 'lblCustomPacksTitle'
$script:CustomPacksCtl.Bar = New-Object System.Windows.Forms.Panel
$script:CustomPacksCtl.Bar.Name = 'customPacksAccentBar'
$script:CustomPacksCtl.Bar.Size = New-Object System.Drawing.Size(56, 3)
$script:CustomPacksCtl.Bar.BackColor = $script:Theme.Accent
$pnlCustomPacks.Controls.Add($script:CustomPacksCtl.Bar)
$script:CustomPacksCtl.Sub = New-CustomPacksLabel $script:CustomPacksTeaser.Sub 10.5 ([System.Drawing.FontStyle]::Regular) $script:Theme.TextMuted 'lblCustomPacksSub'
$__i = 0
foreach ($__line in $script:CustomPacksTeaser.Bullets) {
  $d = New-Object System.Windows.Forms.Panel
  $d.Name = "customPacksDot$__i"
  $d.Size = New-Object System.Drawing.Size(6, 6)
  $d.BackColor = $script:Theme.Accent
  $pnlCustomPacks.Controls.Add($d)
  $script:CustomPacksCtl.Dots += $d
  $script:CustomPacksCtl.Bullets += (New-CustomPacksLabel $__line 10 ([System.Drawing.FontStyle]::Regular) $script:Theme.Text "lblCustomPacksBullet$__i")
  $__i++
}
function Update-CustomPacksLayout {
  $c = $script:CustomPacksCtl
  if (-not $c -or -not $c.Title) { return }
  $cw = $pnlCustomPacks.ClientSize.Width; $ch = $pnlCustomPacks.ClientSize.Height
  $w = $c.Sub.PreferredWidth
  foreach ($b in $c.Bullets) { $w = [Math]::Max($w, $b.PreferredWidth + 22) }
  $w = [Math]::Max($w, $c.Title.PreferredWidth)
  $bulletTop = 128; $step = 30
  $h = $bulletTop + $step * $c.Bullets.Count
  $x0 = [int][Math]::Max(16, ($cw - $w) / 2)
  $y0 = [int][Math]::Max(16, ($ch - $h) / 2 - 20)
  $c.Tag.Location = New-Object System.Drawing.Point($x0, $y0)
  $c.Title.Location = New-Object System.Drawing.Point(($x0 - 4), ($y0 + 20))
  $c.Bar.Location = New-Object System.Drawing.Point($x0, ($y0 + 68))
  $c.Sub.Location = New-Object System.Drawing.Point(($x0 - 2), ($y0 + 82))
  for ($i = 0; $i -lt $c.Bullets.Count; $i++) {
    $yy = $y0 + $bulletTop + $i * $step
    $c.Dots[$i].Location = New-Object System.Drawing.Point($x0, ($yy + 8))
    $c.Bullets[$i].Location = New-Object System.Drawing.Point(($x0 + 16), $yy)
  }
  $pnlCustomPacks.Invalidate()
}
$pnlCustomPacks.Add_Resize({ if ($pnlCustomPacks.Visible) { Update-CustomPacksLayout } })
$pnlCustomPacks.Add_VisibleChanged({ if ($pnlCustomPacks.Visible) { Update-CustomPacksLayout } })
Set-Tip $script:CustomPacksCtl.Title 'Custom Packs - coming soon'

$script:ManageSub = 'Showroom'
$script:ShowroomRows = @()
$script:ShowroomSelected = $null
$script:ShowroomChecked = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$script:ShowroomFilterControls = $null
$script:ShowroomThumbCache = @{}
$script:ShowroomPakBytes = @{}
$script:ShowroomTexBytes = @{}      # ItemKey -> raw texture entry bytes (read on Search, off the UI thread)
$script:ShowroomEagerThumbs = $true # Search preloads every card thumb (flat + 3D) up front; hover never loads anything
$script:ShowroomPreloading = $false
$script:ShowroomPreloadCancel = $false
$script:ShowroomCloseAfterPreload = $false
$script:ShowroomPreloadRs = $null
$script:ShowroomLastPreload = $null
# Instrumentation: loads/decodes done on the UI thread or queued for 3D (hover must never change these)
$script:ShowroomLoadStats = @{ UiDecode = 0; UiRead = 0; Req3D = 0; Preloads = 0 }
$script:ShowroomHasSearched = $false
$script:ShowroomCardMap = @{}
$script:SuppressShowroom = $false

function Test-ShowroomActive {
  return ($script:CurrentPage -eq 'GALLERY' -and $script:ManageSub -eq 'Showroom')
}

function Attach-FixPreviewHost([System.Windows.Forms.Control]$hostCtrl) {
  if (-not $fixPrevPanel -or -not $hostCtrl) { return }
  if ($fixPrevPanel.Parent -eq $hostCtrl) { return }
  if ($fixPrevPanel.Parent) {
    try { [void]$fixPrevPanel.Parent.Controls.Remove($fixPrevPanel) } catch {}
  }
  $fixPrevPanel.Dock = 'Fill'
  $hostCtrl.Controls.Add($fixPrevPanel)
  $fixPrevPanel.BringToFront()
  if ($hostCtrl -ne $showPrevHost) { Hide-Live3D }
}

function Clear-ShowroomThumbs {
  foreach ($k in @($script:ShowroomThumbCache.Keys)) {
    try {
      $img = $script:ShowroomThumbCache[$k]
      if ($img) { $img.Dispose() }
    } catch {}
  }
  $script:ShowroomThumbCache = @{}
  $script:ShowroomPakBytes = @{}
  $script:ShowroomTexBytes = @{}
}

function Get-ShowroomBikeClass([string]$model, [string]$metaCls) {
  if ($metaCls) { return [string]$metaCls }
  if (-not $model) { return '' }
  if ($model -match '(?i)ATV|Quad') { return 'ATV' }
  if ($model -match '450') { return '450' }
  if ($model -match '250') { return '250' }
  if ($model -match '125') { return '125' }
  ''
}

function Get-ShowroomPakBytes([string]$packPath) {
  if (-not $packPath) { return $null }
  if (-not $script:ShowroomPakBytes) { $script:ShowroomPakBytes = @{} }
  if ($script:ShowroomPakBytes.ContainsKey($packPath)) { return $script:ShowroomPakBytes[$packPath] }
  if (-not (Test-Path -LiteralPath $packPath)) { return $null }
  try {
    $script:ShowroomLoadStats.UiRead++
    $b = [IO.File]::ReadAllBytes($packPath)
    $script:ShowroomPakBytes[$packPath] = $b
    return $b
  } catch { return $null }
}

function Read-OuPakSlice([string]$path, [long]$offset, [int]$length) {
  # Read one entry's bytes from a pak (read-only, shared; never writes). Used only when the Search preload missed it.
  if (-not $path -or $length -le 0 -or $offset -lt 0) { return $null }
  $script:ShowroomLoadStats.UiRead++
  $fs = $null
  try {
    $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    if ($offset + $length -gt $fs.Length) { return $null }
    [void]$fs.Seek($offset, [IO.SeekOrigin]::Begin)
    $buf = New-Object byte[] $length
    $got = 0
    while ($got -lt $length) { $n = $fs.Read($buf, $got, $length - $got); if ($n -le 0) { break }; $got += $n }
    if ($got -ne $length) { return $null }
    return ,$buf
  } catch { return $null } finally { if ($fs) { $fs.Dispose() } }
}

function Get-ShowroomPreferredEntry($row) {
  if (-not $row -or -not $row.Entries) { return $null }
  $ents = @($row.Entries)
  if (-not $ents.Count) { return $null }
  if ($row.PreferredThumbPart) {
    $hit = @($ents | Where-Object { $_.Part -eq $row.PreferredThumbPart } | Select-Object -First 1)
    if ($hit -and $hit[0]) { return $hit[0] }
  }
  $ents[0]
}

function Get-ShowroomItemBitmap($row, [int]$maxW = 0, [int]$maxH = 0) {
  if (-not $row -or -not $row.ItemKey) { return $null }
  $cacheKey = "{0}|{1}x{2}" -f $row.ItemKey, $maxW, $maxH
  if ($script:ShowroomThumbCache.ContainsKey($cacheKey)) { return $script:ShowroomThumbCache[$cacheKey] }
  $ent = Get-ShowroomPreferredEntry $row
  if (-not $ent -or [int]$ent.Length -lt 36 -or [int]$ent.Offset -lt 0) { return $null }
  if (-not ('OUPreview' -as [type])) {
    try { Load-Preview } catch { return $null }
  }
  if (-not ('OUPreview' -as [type])) { return $null }
  # Texture bytes were read on Search (background); fall back to reading just this entry from the pak (read-only)
  $b = $null; $off = 0
  if ($script:ShowroomTexBytes.ContainsKey([string]$row.ItemKey)) { $b = $script:ShowroomTexBytes[[string]$row.ItemKey] }
  if (-not $b) {
    $b = Read-OuPakSlice $row.PackPath ([long]$ent.Offset) ([int]$ent.Length)
    if ($b) { $script:ShowroomTexBytes[[string]$row.ItemKey] = $b }
  }
  if (-not $b) { return $null }
  try {
    $info = ''
    $script:ShowroomLoadStats.UiDecode++
    $src = [OUPreview]::Decode($b, $off, $b.Length, [ref]$info)
    if (-not $src) { return $null }
    $bm = $src
    if ($maxW -gt 0 -and $maxH -gt 0 -and ($src.Width -gt $maxW -or $src.Height -gt $maxH)) {
      $scale = [Math]::Min($maxW / [double]$src.Width, $maxH / [double]$src.Height)
      if ($scale -gt 1) { $scale = 1 }
      $w = [Math]::Max(1, [int]($src.Width * $scale))
      $h = [Math]::Max(1, [int]($src.Height * $scale))
      $bm = New-Object System.Drawing.Bitmap $w, $h
      $g = [System.Drawing.Graphics]::FromImage($bm)
      $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
      $g.DrawImage($src, 0, 0, $w, $h)
      $g.Dispose()
      $src.Dispose()
    }
    $script:ShowroomThumbCache[$cacheKey] = $bm
    return $bm
  } catch { return $null }
}

function Get-ShowroomThumb([string]$path) {
  # Legacy pack-PNG thumb helper (still used if a sheet path is passed).
  if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $null }
  if ($script:ShowroomThumbCache.ContainsKey($path)) { return $script:ShowroomThumbCache[$path] }
  try {
    $bytes = [IO.File]::ReadAllBytes($path)
    $ms = New-Object IO.MemoryStream(,$bytes)
    $src = [System.Drawing.Image]::FromStream($ms)
    $ms.Dispose()
    $maxW = 184; $maxH = 110
    $scale = [Math]::Min($maxW / [double]$src.Width, $maxH / [double]$src.Height)
    if ($scale -gt 1) { $scale = 1 }
    $w = [Math]::Max(1, [int]($src.Width * $scale))
    $h = [Math]::Max(1, [int]($src.Height * $scale))
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
    $g.DrawImage($src, 0, 0, $w, $h)
    $g.Dispose()
    $src.Dispose()
    $script:ShowroomThumbCache[$path] = $bmp
    return $bmp
  } catch { return $null }
}

function Find-ShowroomRowByKey([string]$key) {
  if (-not $key) { return $null }
  @($script:ShowroomRows | Where-Object { $_.ItemKey -eq $key } | Select-Object -First 1)[0]
}

function Get-ShowroomCheckedPackNames {
  $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($k in @($script:ShowroomChecked)) {
    $r = Find-ShowroomRowByKey $k
    if ($r -and $r.PackFile) { [void]$set.Add($r.PackFile) }
  }
  @($set)
}

function Get-ShowroomCheckedItems {
  <# Item-level multi-select for Showroom / future Custom Packs.
     Each row ItemKey = "{PackFile}|{GroupKey}" where GroupKey = "{Kind}|{Model}|{Skin}".
     Returns full ShowroomRows for checked ItemKeys (stable PackFile+Model+Skin identity). #>
  $list = New-Object System.Collections.ArrayList
  foreach ($k in @($script:ShowroomChecked)) {
    $r = Find-ShowroomRowByKey $k
    if ($r) { [void]$list.Add($r) }
  }
  @($list.ToArray())
}

function Build-ShowroomRows {
  $script:ShowroomBuildCount = [int]$script:ShowroomBuildCount + 1
  $script:ShowroomRows = @()
  if (-not $game) { return }
  if (-not (Get-Command Get-ShowroomItems -ErrorAction SilentlyContinue)) { return }

  $files = @()
  try { $files = @(Installed) } catch { $files = @() }
  if (-not $files.Count) { return }

  # Skip Unused-Map here (slow; hangs Gallery). Tags + catalog meta are enough for Showroom filters.
  $um = @{}
  $tags = @{}
  try { $tags = Get-Tags } catch { $tags = @{} }

  $packMeta = @{}
  $fi = 0
  foreach ($f in $files) {
    $fi++; Invoke-ShowroomPump 'Reading pack info' $fi $files.Count
    if (-not $f) { continue }
    $meta = Get-CatalogMeta $f.Name
    $notesArr = @()
    if ($meta -and $meta.notes) { $notesArr = @($meta.notes) }
    $notesText = if ($notesArr.Count) { ($notesArr -join ' - ') } else { '' }
    $clashFree = $true
    foreach ($n in $notesArr) {
      if ($n -match '(?i)only one|conflicts with|Use ONE|REQUIRED by|BROKEN') { $clashFree = $false; break }
    }
    if ($meta -and [int]($meta.clashes) -gt 0) { $clashFree = $false }

    $status = 'Good'
    $tg = $null
    if ($tags) { $tg = $tags[$f.Name] }
    $st = Status-FromInstalledTag $tg
    $status = $st.Status
    # Broken-via-unused skipped in Showroom for speed (Pack Manager still full-checks)

    $packMeta[$f.Name] = [pscustomobject]@{
      File = $f
      Meta = $meta
      Desc = if ($meta) { [string]$meta.desc } else { '(not in catalog)' }
      Cat = if ($meta) { [string]$meta.cat } else { '' }
      Sub = if ($meta) { [string]$meta.sub } else { '' }
      Cls = if ($meta) { [string]$meta.cls } else { '' }
      Brand = if ($meta) { [string]$meta.brand } else { '' }
      Rep = if ($meta) { [string]$meta.rep } else { '' }
      Type = (Type-OfMeta $meta)
      Notes = $notesText
      ClashFree = $clashFree
      Status = $status
      Bytes = [long]$f.Length
      PackHasSheet = [bool](Find-PreviewPath $f.Name)
    }
  }

  $items = @()
  $items = @()
  if ($script:ShowroomPreloading) {
    # one pack at a time so the window keeps pumping (same result as one call with all packs)
    $acc = New-Object System.Collections.ArrayList
    $fi = 0
    foreach ($f in $files) {
      $fi++; Invoke-ShowroomPump 'Scanning packs' $fi $files.Count
      try { foreach ($x in @(Get-ShowroomItems -Pak @($f))) { [void]$acc.Add($x) } } catch {}
    }
    $items = @($acc)
  } else {
    try { $items = @(Get-ShowroomItems -Pak $files) } catch { $items = @() }
  }

  $ii = 0
  foreach ($it in $items) {
    $ii++; Invoke-ShowroomPump 'Indexing items' $ii $items.Count
    $pm = $null
    if ($packMeta.ContainsKey($it.PackFile)) { $pm = $packMeta[$it.PackFile] }
    $cat = if ($pm -and $pm.Cat) { $pm.Cat } elseif ($it.Kind -eq 'gear') { 'Rider gear' } else { 'Bikes' }
    $sub = if ($pm) { $pm.Sub } else { '' }
    $cls = ''
    if ($it.Kind -eq 'bike') {
      $cls = Get-ShowroomBikeClass $it.Model $(if ($pm) { $pm.Cls } else { '' })
    } elseif ($pm) { $cls = $pm.Cls }

    $ent = Get-ShowroomPreferredEntry $it
    $hasThumb = [bool]($ent -and [int]$ent.Length -ge 36 -and [int]$ent.Offset -ge 0 -and $it.PreferredThumbPart)
    $itemKey = "{0}|{1}" -f $it.PackFile, $it.GroupKey
    $partsText = if ($it.Parts) { (@($it.Parts) -join ', ') } else { '' }
    $disp = if ($it.DisplayName) { [string]$it.DisplayName } else { ("{0} {1}" -f $it.Model, $it.Skin).Trim() }

    $script:ShowroomRows += [pscustomobject]@{
      ItemKey = $itemKey
      GroupKey = [string]$it.GroupKey
      File = $(if ($pm) { $pm.File } else { $null })
      PackFile = [string]$it.PackFile
      PackPath = [string]$it.PackPath
      Name = [string]$it.PackFile   # pack name for Make-previews mapping
      Kind = [string]$it.Kind
      Model = [string]$it.Model
      Skin = [string]$it.Skin
      Parts = @($it.Parts)
      PartsText = $partsText
      PreferredThumbPart = $it.PreferredThumbPart
      PreferredThumbPath = $it.PreferredThumbPath
      TexturePaths = @($it.TexturePaths)
      Entries = @($it.Entries)
      ItemNotes = @($it.Notes)
      DisplayName = $disp
      Desc = $(if ($pm) { $pm.Desc } else { $disp })
      Cat = $cat
      Sub = $sub
      Cls = $cls
      Brand = $(if ($pm) { $pm.Brand } else { '' })
      Rep = $(if ($pm) { $pm.Rep } else { '' })
      Type = $(if ($pm) { $pm.Type } else { $it.Kind })
      Notes = $(if ($pm) { $pm.Notes } else { '' })
      ClashFree = $(if ($pm) { [bool]$pm.ClashFree } else { $true })
      Status = $(if ($pm) { $pm.Status } else { 'Good' })
      Bytes = $(if ($pm) { [long]$pm.Bytes } else { 0L })
      HasPreview = $hasThumb
      Slot3D = (Get-Item3DSlot $it)
      PackHasSheet = $(if ($pm) { [bool]$pm.PackHasSheet } else { $false })
      PreviewPath = $(if ($pm -and $pm.PackHasSheet) { Find-PreviewPath $it.PackFile } else { $null })
    }
  }
}

function Get-ShowroomFilterState {
  $st = @{ Cat = 'All'; Sub = 'All'; Cls = 'All'; Sort = 'category'; Q = ''; HasPrev = $false; Clashes = $false; Solo = $false }
  if (-not $script:ShowroomFilterControls) { return $st }
  $c = $script:ShowroomFilterControls
  if ($c.Cat -and $c.Cat.SelectedItem) { $st.Cat = [string]$c.Cat.SelectedItem }
  if ($c.Sub -and $c.Sub.SelectedItem) { $st.Sub = [string]$c.Sub.SelectedItem }
  if ($c.Cls -and $c.Cls.SelectedItem) { $st.Cls = [string]$c.Cls.SelectedItem }
  if ($c.Sort -and $c.Sort.SelectedItem) {
    $map = @{
      'By category' = 'category'
      'By pak name' = 'name'
      'Fewest notes first' = 'fewest'
      'Most notes first' = 'most'
      'Largest first' = 'size'
    }
    $lab = [string]$c.Sort.SelectedItem
    if ($map.ContainsKey($lab)) { $st.Sort = $map[$lab] }
  }
  if ($c.Search) { $st.Q = [string]$c.Search.Text }
  if ($c.HasPrev) { $st.HasPrev = [bool]$c.HasPrev.Checked }
  if ($c.Clashes) { $st.Clashes = [bool]$c.Clashes.Checked }
  if ($c.Solo) { $st.Solo = [bool]$c.Solo.Checked }
  $st
}

function Get-FilteredShowroomRows {
  $st = Get-ShowroomFilterState
  $needle = $st.Q.Trim().ToLowerInvariant()
  $rows = @($script:ShowroomRows | Where-Object {
    ($st.Cat -eq 'All' -or $_.Cat -eq $st.Cat) -and
    ($st.Sub -eq 'All' -or $_.Sub -eq $st.Sub) -and
    ($st.Cls -eq 'All' -or (@($_.Cls -split ',\s*') -contains $st.Cls) -or ($_.Cls -eq $st.Cls)) -and
    ((-not $st.HasPrev) -or $_.HasPreview) -and
    ((-not $st.Clashes) -or $_.Status -eq 'Clash') -and
    ((-not $st.Solo) -or $_.ClashFree) -and
    ($needle -eq '' -or (
      ($_.DisplayName + ' ' + $_.PackFile + ' ' + $_.Kind + ' ' + $_.Model + ' ' + $_.Skin + ' ' + $_.PartsText + ' ' + $_.Desc + ' ' + $_.Brand + ' ' + $_.Rep + ' ' + $_.Notes + ' ' + $_.Type + ' ' + $_.Cat).ToLowerInvariant().Contains($needle)
    ))
  })
  switch ($st.Sort) {
    'name' { $rows = @($rows | Sort-Object { $_.PackFile.ToLowerInvariant() }, { $_.DisplayName.ToLowerInvariant() }) }
    'fewest' { $rows = @($rows | Sort-Object { (@($_.Notes -split ' - ') | Where-Object { $_ }).Count }, { $_.Cat }, { $_.DisplayName }) }
    'most' { $rows = @($rows | Sort-Object { -((@($_.Notes -split ' - ') | Where-Object { $_ }).Count) }, { $_.Cat }, { $_.DisplayName }) }
    'size' { $rows = @($rows | Sort-Object @{ Expression = 'Bytes'; Descending = $true }, DisplayName) }
    default {
      $rows = @($rows | Sort-Object @{
        Expression = {
          $i = [array]::IndexOf($script:CatOrder, $_.Cat)
          if ($i -lt 0) { 99 } else { $i }
        }
      }, Kind, Model, Skin, PackFile)
    }
  }
  $rows
}

function Update-ShowroomCardChrome([System.Windows.Forms.Panel]$card, [bool]$selected) {
  if (-not $card) { return }
  $card.BackColor = $(if ($selected) { $script:Theme.AccentSoft } else { $script:Theme.PanelDeep })
  $card.Invalidate()
}

function New-ShowroomCard($row) {
  $card = New-Object System.Windows.Forms.Panel
  $card.Size = New-Object System.Drawing.Size(200, 186)
  $card.Margin = New-Object System.Windows.Forms.Padding(8)
  $card.Padding = New-Object System.Windows.Forms.Padding(6)
  $card.BackColor = $script:Theme.PanelDeep
  $card.Tag = $row.ItemKey
  $card.Cursor = [System.Windows.Forms.Cursors]::Hand

  $card.Add_Paint({
    param($sender, $e)
    $sel = ($script:ShowroomSelected -and [string]$sender.Tag -eq $script:ShowroomSelected)
    $penW = $(if ($sel) { 3 } else { 1 })
    $col = $(if ($sel) { $script:Theme.Accent } else { [System.Drawing.Color]::FromArgb(70, 70, 78) })
    $pen = New-Object System.Drawing.Pen $col, $penW
    $e.Graphics.DrawRectangle($pen, 1, 1, $sender.Width - 3, $sender.Height - 3)
    $pen.Dispose()
  })

  $chk = New-Object System.Windows.Forms.CheckBox
  $chk.AutoSize = $true
  $chk.Location = New-Object System.Drawing.Point(6, 4)
  $chk.BackColor = [System.Drawing.Color]::Transparent
  $chk.ForeColor = $script:Theme.Text
  $chk.Checked = $script:ShowroomChecked.Contains($row.ItemKey)
  $chk.Tag = $row.ItemKey
  $chk.Add_CheckedChanged({
    param($sender, $e)
    if ($script:SuppressShowroom) { return }
    $nm = [string]$sender.Tag
    if ($sender.Checked) {
      [void]$script:ShowroomChecked.Add($nm)
      Select-ShowroomPack $nm   # checking a card also selects/highlights it and shows its preview + 3D
    } else {
      [void]$script:ShowroomChecked.Remove($nm)
      Update-FixPreview          # unchecking leaves the current preview as is
    }
  })
  $card.Controls.Add($chk)

  $picBox = New-Object System.Windows.Forms.PictureBox
  $picBox.Location = New-Object System.Drawing.Point(8, 26)
  $picBox.Size = New-Object System.Drawing.Size(184, 110)
  $picBox.SizeMode = 'Zoom'
  $picBox.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 28)
  $picBox.BorderStyle = 'FixedSingle'
  $picBox.Tag = $row.ItemKey
  # Thumbs were all loaded by Search (Invoke-ShowroomPreload, off the UI thread). No hover handlers: hovering loads nothing.
  $thumb = Get-ShowroomCachedThumb $row
  if ($thumb) { $picBox.Image = $thumb }
  $card.Controls.Add($picBox)

  $lblName = New-Object System.Windows.Forms.Label
  $lblName.Location = New-Object System.Drawing.Point(8, 140)
  $lblName.Size = New-Object System.Drawing.Size(184, 18)
  $lblName.AutoEllipsis = $true
  $lblName.Text = $row.DisplayName
  $lblName.Tag = $row.ItemKey
  Set-OuLabel $lblName
  $card.Controls.Add($lblName)

  $lblCat = New-Object System.Windows.Forms.Label
  $lblCat.Location = New-Object System.Drawing.Point(8, 160)
  $lblCat.Size = New-Object System.Drawing.Size(184, 16)
  $lblCat.AutoEllipsis = $true
  $kindLab = if ($row.Kind) { $row.Kind } else { '?' }
  $partsShort = if ($row.PartsText) { $row.PartsText } else { 'no parts' }
  $lblCat.Text = ("{0} · {1} · {2}" -f $kindLab, $row.PackFile, $partsShort)
  $lblCat.Tag = $row.ItemKey
  Set-OuLabel $lblCat -Muted
  $card.Controls.Add($lblCat)

  $click = {
    param($sender, $e)
    $nm = [string]$sender.Tag
    if (-not $nm -and $sender.Parent) { $nm = [string]$sender.Parent.Tag }
    if (-not $nm) { return }
    Select-ShowroomPack $nm   # re-clicking the selected card keeps it selected (preview never goes empty)
  }
  $card.Add_Click($click)
  $picBox.Add_Click($click)
  $lblName.Add_Click($click)
  $lblCat.Add_Click($click)

  $card
}

function Clear-ShowroomSelection {
  # Deselect: preview/3D view go empty
  $script:ShowroomSelected = $null
  foreach ($kv in @($script:ShowroomCardMap.GetEnumerator())) { Update-ShowroomCardChrome $kv.Value $false }
  Update-FixPreview
}

function Test-ShowroomCardImages {
  # Instrumentation: every card's picture must already be set once Search finishes
  $res = [ordered]@{ Cards = 0; NoImage = 0; NoImageNoTexture = 0; NoImageKeys = @() }
  foreach ($kv in @($script:ShowroomCardMap.GetEnumerator())) {
    $res.Cards++
    $pb = $null; foreach ($c in $kv.Value.Controls) { if ($c -is [System.Windows.Forms.PictureBox]) { $pb = $c; break } }
    if (-not $pb -or -not $pb.Image) {
      $res.NoImage++
      $r = Find-ShowroomRowByKey ([string]$kv.Key)
      if (-not $r -or -not $r.HasPreview) { $res.NoImageNoTexture++ }
      $res.NoImageKeys += [string]$kv.Key
    }
  }
  [pscustomobject]$res
}

function Test-ShowroomCheckboxPreview([int]$index = -1) {
  # Instrumentation: click a card's checkbox (real Click -> CheckedChanged) and check the preview follows it
  $cards = @($showCardFlow.Controls)
  if (-not $cards.Count) { return [pscustomobject]@{ Key = ''; Selects = $false; Img = $false; Live3D = $false; UncheckKeeps = $false; Restored = $false } }
  if ($index -lt 0) { $index = [Math]::Min(2, $cards.Count - 1) }
  $card = $cards[$index]; $key = [string]$card.Tag
  $chk = $null; foreach ($c in $card.Controls) { if ($c -is [System.Windows.Forms.CheckBox]) { $chk = $c; break } }
  $was = [bool]$chk.Checked
  $mi = [System.Windows.Forms.Control].GetMethod('OnClick', [Reflection.BindingFlags]'Instance,NonPublic')
  $a = [object[]]::new(1); $a[0] = [EventArgs]::Empty
  if ($was) { [void]$mi.Invoke($chk, $a) }          # start unchecked
  [void]$mi.Invoke($chk, $a)                         # check -> select + preview
  $st = Get-ShowroomPreviewState
  $selects = ($chk.Checked -and $st.Selected -eq $key)
  [void]$mi.Invoke($chk, $a)                         # uncheck -> preview stays
  $st2 = Get-ShowroomPreviewState
  if ($was) { [void]$mi.Invoke($chk, $a) }           # restore original check state
  [pscustomobject]@{ Key = $key; Selects = $selects; Img = $st.Img; Live3D = $st.Live3D; UncheckKeeps = ($st2.Selected -eq $key -and ($st2.Img -or $st2.Live3D)); Restored = ([bool]$chk.Checked -eq $was) }
}

function Get-ShowroomPreviewState {
  [pscustomobject]@{
    Selected = [string]$script:ShowroomSelected
    Img      = [bool]$picFix.Image
    Live3D   = [bool]($script:Live3D -and $script:Live3D.Visible)
  }
}

function Test-ShowroomClickLoads([int]$n = 5) {
  # Instrumentation: click cards (real Click handlers) and prove no card image is (re)loaded by the click
  $snap = @{}
  foreach ($kv in @($script:ShowroomCardMap.GetEnumerator())) { foreach ($c in $kv.Value.Controls) { if ($c -is [System.Windows.Forms.PictureBox]) { $snap[[string]$kv.Key] = $c.Image } } }
  $thumbKeys = @($script:ShowroomThumbCache.Keys | Where-Object { [string]$_ -like '*|184x110' }).Count
  $req0 = $script:ShowroomLoadStats.Req3D; $q0 = 0; try { $q0 = [OU3DHost]::QueueLength } catch {}
  $mi = [System.Windows.Forms.Control].GetMethod('OnClick', [Reflection.BindingFlags]'Instance,NonPublic')
  $clicked = 0; $states = @()
  foreach ($kv in @($script:ShowroomCardMap.GetEnumerator() | Select-Object -First $n)) {
    $pb = $null; foreach ($c in $kv.Value.Controls) { if ($c -is [System.Windows.Forms.PictureBox]) { $pb = $c; break } }
    if (-not $pb) { continue }
    $a = [object[]]::new(1); $a[0] = [EventArgs]::Empty
    [void]$mi.Invoke($pb, $a); $clicked++
    $states += (Get-ShowroomPreviewState)
  }
  $changed = 0
  foreach ($kv in @($script:ShowroomCardMap.GetEnumerator())) { foreach ($c in $kv.Value.Controls) { if ($c -is [System.Windows.Forms.PictureBox]) { if (-not [object]::ReferenceEquals($snap[[string]$kv.Key], $c.Image)) { $changed++ } } } }
  $q1 = 0; try { $q1 = [OU3DHost]::QueueLength } catch {}
  [pscustomobject]@{
    Clicked = $clicked
    CardImagesChanged = $changed
    ThumbKeysAdded = (@($script:ShowroomThumbCache.Keys | Where-Object { [string]$_ -like '*|184x110' }).Count - $thumbKeys)
    Req3D = ($script:ShowroomLoadStats.Req3D - $req0)
    Queue = ("{0}->{1}" -f $q0, $q1)
    PreviewShownOnClick = [bool](@($states | Where-Object { $_.Img -or $_.Live3D }).Count -eq $clicked)
  }
}

function Select-ShowroomPack([string]$name) {
  # name = ItemKey (pack|kind|model|skin)
  if (-not $name) { return }
  $script:ShowroomSelected = $name
  foreach ($kv in @($script:ShowroomCardMap.GetEnumerator())) {
    Update-ShowroomCardChrome $kv.Value ($kv.Key -eq $name)
  }
  # Card thumbs were preloaded by Search; selecting only shows the preview from the loaded texture bytes
  Update-FixPreview
}

function Get-Showroom3DThumbKey($row) {
  $num = ''; $on = $true
  try { if ('OU3DHost' -as [type]) { $num = [string][OU3DHost]::DisplayNumber; $on = [bool][OU3DHost]::ShowNumber } } catch {}
  "{0}|3d|{1}|{2}|184x110" -f $row.ItemKey, $(if ($on) { 'n' } else { 'b' }), $num
}

function Get-ShowroomCachedThumb($row) {
  # Cache lookup only (never decodes): 3D side thumb for the current rider look, else the flat item thumb.
  if (-not $row) { return $null }
  $k3 = Get-Showroom3DThumbKey $row
  if ($script:ShowroomThumbCache.ContainsKey($k3)) { return $script:ShowroomThumbCache[$k3] }
  $kf = "{0}|184x110" -f $row.ItemKey
  if ($script:ShowroomThumbCache.ContainsKey($kf)) { return $script:ShowroomThumbCache[$kf] }
  $null
}

$script:ShowroomPreloadScript = {
  param($jobs, $sync)
  # Background (no UI access): read each card's texture entry from its pak (read-only), decode + scale the flat thumb,
  # then (once the 3D engine is ready) load or render the 3D side thumb. Results go into $sync for the UI thread.
  function Scale-Bm($src, [int]$maxW, [int]$maxH) {
    if ($src.Width -le $maxW -and $src.Height -le $maxH) { return $src }
    $scale = [Math]::Min($maxW / [double]$src.Width, $maxH / [double]$src.Height)
    $w = [Math]::Max(1, [int]($src.Width * $scale)); $h = [Math]::Max(1, [int]($src.Height * $scale))
    $bm = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bm)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
    $g.DrawImage($src, 0, 0, $w, $h); $g.Dispose(); $src.Dispose()
    $bm
  }
  $byPack = @{}
  foreach ($j in $jobs) { if ($j.Flat) { if (-not $byPack.ContainsKey($j.Pack)) { $byPack[$j.Pack] = New-Object System.Collections.ArrayList }; [void]$byPack[$j.Pack].Add($j) } }
  foreach ($pk in $byPack.Keys) {
    if ($sync.Cancel) { break }
    $fs = $null
    try {
      $fs = New-Object IO.FileStream($pk, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
      foreach ($j in ($byPack[$pk] | Sort-Object { [long]$_.Off })) {
        if ($sync.Cancel) { break }
        try {
          if ([long]$j.Off + [int]$j.Len -le $fs.Length) {
            $buf = New-Object byte[] ([int]$j.Len)
            [void]$fs.Seek([long]$j.Off, [IO.SeekOrigin]::Begin)
            $got = 0; while ($got -lt $buf.Length) { $n = $fs.Read($buf, $got, $buf.Length - $got); if ($n -le 0) { break }; $got += $n }
            if ($got -eq $buf.Length) {
              $sync.Tex[$j.Key] = $buf
              $info = ''
              $src = [OUPreview]::Decode($buf, 0, $buf.Length, [ref]$info)
              if ($src) { $sync.Flat[$j.Key] = (Scale-Bm $src 184 110) }
            }
          }
        } catch { $sync.Errors++ }
        $sync.Done++
      }
    } catch { $sync.Errors++ } finally { if ($fs) { $fs.Dispose() } }
  }
  # 3D side thumbs: wait for the UI to say the engine is ready (or unavailable)
  $want3 = @($jobs | Where-Object { $_.Slot })
  if ($want3.Count -and -not $sync.Cancel) {
    $sync.Phase = 'wait3d'
    while (-not $sync.Ready3D -and -not $sync.No3D -and -not $sync.Cancel) { Start-Sleep -Milliseconds 20 }
    if ($sync.Ready3D -and -not $sync.Cancel) {
      $sync.Phase = '3d'
      $numbered = [bool][OU3DHost]::ShowNumber
      foreach ($j in $want3) {
        if ($sync.Cancel) { break }
        try {
          if ([OU3DHost]::HasModel([string]$j.Slot)) {
            if (-not [OU3DHost]::IsFresh($j.Pack, $j.Slot, $numbered)) { $sync.Rendered++ }
            [void][OU3DHost]::EnsurePreviews($j.Pack, $j.Slot, $false, $numbered)   # renders into Pack Manager\Previews only if missing/stale
            $sp = [OU3DHost]::SidePath($j.Pack, $j.Slot, $numbered)
            if ([IO.File]::Exists($sp)) { $sync.Side[$j.Key] = [OU3DHost]::LoadScaled($sp, 184, 110) }
          }
        } catch { $sync.Errors++; $sync.Err3D = $_.Exception.Message }
        $sync.Done3D++
      }
    }
  }
  $sync.Phase = 'done'
}

function Get-ShowroomPreloadRunspace {
  $rs = $script:ShowroomPreloadRs
  if ($rs -and $rs.RunspaceStateInfo.State -eq 'Opened') { return $rs }
  $rs = [runspacefactory]::CreateRunspace()
  $rs.ApartmentState = 'MTA'
  $rs.Open()
  $script:ShowroomPreloadRs = $rs
  $rs
}

function Set-ShowroomBusyUi([bool]$busy) {
  # While loading: keep the window responsive (repaint/move) but block anything that would re-enter the Showroom.
  if ($busy) {
    $script:ShowroomBusyRestore = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    $stack.Push($leftRail)
    $sb = $(if ($script:ShowroomFilterControls) { $script:ShowroomFilterControls.SearchBtn } else { $null })
    while ($stack.Count) {
      $c = $stack.Pop()
      foreach ($ch in $c.Controls) {
        if ($ch -eq $sb) { continue }
        if ($ch -is [System.Windows.Forms.Panel] -or $ch -is [System.Windows.Forms.GroupBox]) { $stack.Push($ch); continue }
        if ($ch.Enabled) { [void]$script:ShowroomBusyRestore.Add($ch); $ch.Enabled = $false }
      }
    }
    foreach ($nb in $navButtons.Values) { if ($nb.Enabled) { [void]$script:ShowroomBusyRestore.Add($nb); $nb.Enabled = $false } }
    if ($fixPrevPanel -and $fixPrevPanel.Enabled) { [void]$script:ShowroomBusyRestore.Add($fixPrevPanel); $fixPrevPanel.Enabled = $false }
    if ($sb) { $script:ShowroomSearchText = $sb.Text; $sb.Text = 'Cancel loading' }
    if ($script:ShowroomProgress) { Set-ShowroomProgress 0; $script:ShowroomProgress.Visible = $true }
  } else {
    foreach ($c in @($script:ShowroomBusyRestore)) { try { if (-not $c.IsDisposed) { $c.Enabled = $true } } catch {} }
    $script:ShowroomBusyRestore = $null
    $sb = $(if ($script:ShowroomFilterControls) { $script:ShowroomFilterControls.SearchBtn } else { $null })
    if ($sb -and $script:ShowroomSearchText) { $sb.Text = $script:ShowroomSearchText }
    if ($script:ShowroomProgress) { $script:ShowroomProgress.Visible = $false }
  }
}

function Invoke-ShowroomPreload($rows) {
  # Load every result card's thumbs up front, off the UI thread, before the cards are shown. The UI thread only pumps
  # messages and updates the progress bar. Fills $script:ShowroomThumbCache (flat + 3D) and $script:ShowroomTexBytes.
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $res = [pscustomobject]@{ Rows = @($rows).Count; Flat = 0; Side = 0; Rendered = 0; Errors = 0; Ms = 0; FlatMs = 0; Wait3DMs = 0; Cancelled = $false; Engine3D = '' }
  if (-not ('OUPreview' -as [type])) { try { Load-Preview } catch {} }
  $jobs = New-Object System.Collections.ArrayList
  foreach ($r in @($rows)) {
    if (-not $r -or -not $r.ItemKey) { continue }
    $needFlat = $false; $off = 0L; $len = 0
    if ($r.HasPreview -and ('OUPreview' -as [type]) -and -not $script:ShowroomThumbCache.ContainsKey(("{0}|184x110" -f $r.ItemKey))) {
      $ent = Get-ShowroomPreferredEntry $r
      if ($ent -and [int]$ent.Length -ge 36 -and [long]$ent.Offset -ge 0) { $needFlat = $true; $off = [long]$ent.Offset; $len = [int]$ent.Length }
    }
    $slot = $null
    if ($r.Slot3D -and $r.PackPath -and $script:OU3DState -ne 'failed' -and -not $script:ShowroomThumbCache.ContainsKey((Get-Showroom3DThumbKey $r))) {
      $slot = [string]$r.Slot3D
      if ($script:OU3DState -eq 'ready') { try { if (-not [OU3DHost]::HasModel($slot)) { $slot = $null } } catch {} }
    }
    if ($needFlat -or $slot) {
      [void]$jobs.Add(@{ Key = [string]$r.ItemKey; Pack = [string]$r.PackPath; Flat = $needFlat; Off = $off; Len = $len; Slot = $slot })
    }
  }
  $nFlat = @($jobs | Where-Object { $_.Flat }).Count
  $n3 = @($jobs | Where-Object { $_.Slot }).Count
  if (-not $jobs.Count) { $res.Ms = $sw.ElapsedMilliseconds; $script:ShowroomLastPreload = $res; return $res }
  $script:ShowroomLoadStats.Preloads++

  $sync = [hashtable]::Synchronized(@{
    Tex = @{}; Flat = @{}; Side = @{}; Done = 0; Done3D = 0; Rendered = 0; Errors = 0; Err3D = ''
    Cancel = $false; Ready3D = $false; No3D = $false; Phase = 'flat'
  })
  if ($script:ShowroomPreloadCancel) { $res.Cancelled = $true; $res.Ms = $sw.ElapsedMilliseconds; $script:ShowroomLastPreload = $res; return $res }
  $ps = $null
  try {
    $ps = [PowerShell]::Create()
    $ps.Runspace = Get-ShowroomPreloadRunspace
    [void]$ps.AddScript($script:ShowroomPreloadScript).AddArgument(@($jobs)).AddArgument($sync)
    $ar = $ps.BeginInvoke()
    $total = $nFlat + $n3
    if ($n3) { Start-OU3D }
    $wait3 = $null; $lastUi = -1000
    while (-not $ar.IsCompleted) {
      [System.Windows.Forms.Application]::DoEvents()
      if ($script:ShowroomPreloadCancel -and -not $sync.Cancel) { $sync.Cancel = $true }
      # 3D engine (compiles in the background on the first Search): tell the worker when it is usable
      if ($n3 -and -not $sync.Ready3D -and -not $sync.No3D) {
        if ($sync.Phase -ne 'flat' -and -not $wait3) { $wait3 = [Diagnostics.Stopwatch]::StartNew() }
        if (Test-OU3DReady) { $sync.Ready3D = $true }
        elseif ($script:OU3DState -eq 'failed' -or ($wait3 -and $wait3.ElapsedMilliseconds -gt 600000)) { $sync.No3D = $true }
        if ($res.FlatMs -eq 0 -and $sync.Phase -ne 'flat') { $res.FlatMs = $sw.ElapsedMilliseconds }
      }
      if ($sw.ElapsedMilliseconds - $lastUi -ge 100) {
        $lastUi = $sw.ElapsedMilliseconds
        $done = [int]$sync.Done + [int]$sync.Done3D
        $pct = $(if ($total) { [int][Math]::Min(100, 100 * $done / $total) } else { 0 })
        if ($script:ShowroomProgress) { Set-ShowroomProgress $pct }
        $what = switch ($sync.Phase) { 'flat' { 'thumbnails' } 'wait3d' { 'thumbnails (starting 3D engine)' } '3d' { '3D thumbnails' } default { 'thumbnails' } }
        $txt = "SHOWROOM - Loading {0} for {1} items... {2}/{3}" -f $what, $res.Rows, $done, $total
        if ($lblShowTitle) { $lblShowTitle.Text = $txt }
        Set-Status ("GALLERY - Showroom | loading {0} {1}/{2} ({3}%)" -f $what, $done, $total, $pct)
      }
      Start-Sleep -Milliseconds 15
    }
    if ($res.FlatMs -eq 0) { $res.FlatMs = $sw.ElapsedMilliseconds }
    try { [void]$ps.EndInvoke($ar) } catch { $res.Errors++ }
  } finally {
    if ($ps) { try { $ps.Dispose() } catch {} }
  }
  foreach ($k in @($sync.Tex.Keys)) { $script:ShowroomTexBytes[$k] = $sync.Tex[$k] }
  foreach ($k in @($sync.Flat.Keys)) {
    $ck = "{0}|184x110" -f $k
    if ($script:ShowroomThumbCache.ContainsKey($ck)) { try { $sync.Flat[$k].Dispose() } catch {}; continue }
    $script:ShowroomThumbCache[$ck] = $sync.Flat[$k]; $res.Flat++
  }
  $byKey = @{}; foreach ($r in @($rows)) { if ($r) { $byKey[[string]$r.ItemKey] = $r } }
  foreach ($k in @($sync.Side.Keys)) {
    $ck = Get-Showroom3DThumbKey $byKey[$k]
    if ($script:ShowroomThumbCache.ContainsKey($ck)) { try { $sync.Side[$k].Dispose() } catch {}; continue }
    $script:ShowroomThumbCache[$ck] = $sync.Side[$k]; $res.Side++
  }
  $res.Rendered = [int]$sync.Rendered; $res.Errors += [int]$sync.Errors
  $res.Cancelled = [bool]$sync.Cancel
  $res.Engine3D = $(if ($sync.Ready3D) { 'ready' } elseif ($n3) { [string]$script:OU3DState } else { 'n/a' })
  if ($wait3) { $res.Wait3DMs = $wait3.ElapsedMilliseconds }
  $res.Ms = $sw.ElapsedMilliseconds
  $script:ShowroomLastPreload = $res
  $res
}

function Clear-ShowroomGallery {
  $script:ShowroomHasSearched = $false
  $script:ShowroomDirty = $false
  $script:ShowroomRows = @()
  $script:ShowroomSelected = $null
  if ($script:ShowroomChecked) { $script:ShowroomChecked.Clear() }
  Clear-ShowroomThumbs
  if ($showCardFlow) {
    $script:SuppressShowroom = $true
    try {
      $showCardFlow.SuspendLayout()
      $showCardFlow.Controls.Clear()
      $script:ShowroomCardMap = @{}
    } finally {
      $showCardFlow.ResumeLayout($true)
      $script:SuppressShowroom = $false
    }
  }
  if ($lblShowTitle) { $lblShowTitle.Text = 'SHOWROOM - Installed (click Search to load items)' }
  if ($lblShowMissing) { $lblShowMissing.Text = 'Set filters, then click Search under the filters' }
  if ((Get-Command Clear-FixPreview -EA SilentlyContinue)) { Clear-FixPreview }
  if ((Get-Command Set-Status -EA SilentlyContinue)) { Set-Status 'GALLERY - Showroom | waiting for Search' }
}

function Invoke-ShowroomSearch {
  if ($script:ShowroomPreloading) { $script:ShowroomPreloadCancel = $true; return }   # button reads 'Cancel loading'
  $script:ShowroomHasSearched = $true
  $script:ShowroomSelected = $null   # new Search: the new first card gets selected when it finishes
  Start-OU3D   # lazy 3D compile + stock model index, in the background
  if ($form) { $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor }
  try {
    Refresh-ShowroomGrid
  } finally {
    if ($form) { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
  }
}

function Refresh-ShowroomGrid {
  if (-not $script:ShowroomHasSearched) {
    # Keep center empty until Search; do not scan Installed packs yet
    if ($showCardFlow -and $showCardFlow.Controls.Count) {
      $script:SuppressShowroom = $true
      try { $showCardFlow.Controls.Clear(); $script:ShowroomCardMap = @{} } finally { $script:SuppressShowroom = $false }
    }
    if ($lblShowTitle) { $lblShowTitle.Text = 'SHOWROOM - Installed (click Search to load items)' }
    if ($lblShowMissing) { $lblShowMissing.Text = 'Set filters, then click Search under the filters' }
    return
  }
  if ($script:ShowroomPreloading) { return }
  # Whole Search (pack scan, thumb preload, card build) runs with the Showroom locked and the message loop pumping,
  # so the window stays responsive; the Search button reads 'Cancel loading' meanwhile.
  $script:ShowroomPreloading = $true
  $script:ShowroomPreloadCancel = $false
  $script:ShowroomPumpSw = [Diagnostics.Stopwatch]::StartNew()
  $tm = [ordered]@{ RowsMs = 0; PreloadMs = 0; CardsMs = 0; TotalMs = 0; Rows = 0; Cancelled = $false }
  $swAll = [Diagnostics.Stopwatch]::StartNew()
  # Old cards may hold thumbs that were just disposed (Clear-ShowroomThumbs): take them down before pumping messages
  $script:SuppressShowroom = $true
  try { $showCardFlow.Controls.Clear(); $script:ShowroomCardMap = @{} } finally { $script:SuppressShowroom = $false }
  if ((Get-Command Clear-FixPreview -EA SilentlyContinue)) { Clear-FixPreview }
  Set-ShowroomBusyUi $true
  try {
    Update-ShowroomGridCore $tm
  } finally {
    Set-ShowroomBusyUi $false
    $script:ShowroomPreloading = $false
    $tm.TotalMs = $swAll.ElapsedMilliseconds
    $tm.Cancelled = [bool]$script:ShowroomPreloadCancel
    $script:ShowroomLastSearch = [pscustomobject]$tm
    if ($script:ShowroomCloseAfterPreload) {
      $script:ShowroomCloseAfterPreload = $false
      $t = New-Object System.Windows.Forms.Timer; $t.Interval = 50
      $t.Add_Tick({ param($s, $e); $s.Stop(); $s.Dispose(); try { $form.Close() } catch {} })
      $t.Start()
    }
  }
}

function Invoke-ShowroomPump([string]$text, [int]$done, [int]$total) {
  # Keep the window alive during the Search (only while the Showroom is locked for it); throttled to ~20 updates/s
  if (-not $script:ShowroomPreloading) { return }
  if ($script:ShowroomPumpSw -and $script:ShowroomPumpSw.ElapsedMilliseconds -lt 50) { return }
  if ($script:ShowroomPumpSw) { $script:ShowroomPumpSw.Restart() }
  if ($text) {
    $pct = $(if ($total -gt 0) { [int][Math]::Min(100, 100 * $done / $total) } else { 0 })
    if ($script:ShowroomProgress) { Set-ShowroomProgress $pct }
    if ($lblShowTitle) { $lblShowTitle.Text = ("SHOWROOM - {0}... {1}/{2}" -f $text, $done, $total) }
    Set-Status ("GALLERY - Showroom | {0} {1}/{2} ({3}%)" -f $text.ToLower(), $done, $total, $pct)
  }
  [System.Windows.Forms.Application]::DoEvents()
}

function Update-ShowroomGridCore($tm) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  Build-ShowroomRows
  $tm.RowsMs = $sw.ElapsedMilliseconds
  $script:ShowroomDirty = $false
  $exist = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($r in $script:ShowroomRows) { [void]$exist.Add($r.ItemKey) }
  foreach ($d in @($script:ShowroomChecked | Where-Object { -not $exist.Contains($_) })) {
    [void]$script:ShowroomChecked.Remove($d)
  }
  if ($script:ShowroomSelected -and -not $exist.Contains($script:ShowroomSelected)) {
    $script:ShowroomSelected = $null
  }

  if ($script:ShowroomFilterControls -and $script:ShowroomFilterControls.Sub) {
    $st = Get-ShowroomFilterState
    $subs = New-Object System.Collections.Generic.List[string]
    [void]$subs.Add('All')
    $script:ShowroomRows | Where-Object { $st.Cat -eq 'All' -or $_.Cat -eq $st.Cat } |
      ForEach-Object { if ($_.Sub -and -not $subs.Contains($_.Sub)) { [void]$subs.Add($_.Sub) } }
    $sorted = @($subs[0]) + @($subs | Select-Object -Skip 1 | Sort-Object)
    $prev = $script:ShowroomFilterControls.Sub.SelectedItem
    $script:SuppressShowroom = $true
    try {
      $script:ShowroomFilterControls.Sub.Items.Clear()
      foreach ($s in $sorted) { [void]$script:ShowroomFilterControls.Sub.Items.Add($s) }
      if ($prev -and $sorted -contains $prev) { $script:ShowroomFilterControls.Sub.SelectedItem = $prev }
      else { $script:ShowroomFilterControls.Sub.SelectedIndex = 0 }
    } finally { $script:SuppressShowroom = $false }
  }

  $rows = @(Get-FilteredShowroomRows)
  $missingN = @($rows | Where-Object { -not $_.HasPreview }).Count

  $script:Showroom3DAsked.Clear(); $script:Showroom3DWanted.Clear()
  if ($script:OU3DState -eq 'ready') { try { [OU3DHost]::CancelThumbs() } catch {} }
  # Load every card's thumbs (flat + 3D) now, in the background, with progress; cards are shown only when done
  $tm.Rows = $rows.Count
  $sw.Restart()
  $pre = Invoke-ShowroomPreload $rows
  $tm.PreloadMs = $sw.ElapsedMilliseconds
  $sw.Restart()
  foreach ($r in $rows) { if ($r.Slot3D -and (Get-ShowroomCachedThumb $r) -and $script:ShowroomThumbCache.ContainsKey((Get-Showroom3DThumbKey $r))) { [void]$script:Showroom3DAsked.Add([string]$r.ItemKey) } }
  $lblShowMissing.Text = ("{0} item(s) in this filter have no usable thumb" -f $missingN)
  $script:SuppressShowroom = $true
  try {
    # Create all cards first (pumping now and then), then add them in one layout pass
    $script:ShowroomCardMap = @{}
    $cards = New-Object System.Collections.Generic.List[System.Windows.Forms.Control]
    $i = 0
    foreach ($r in $rows) {
      $card = New-ShowroomCard $r
      $script:ShowroomCardMap[$r.ItemKey] = $card
      $cards.Add($card)
      if ($script:ShowroomSelected -eq $r.ItemKey) { Update-ShowroomCardChrome $card $true }
      $i++; Invoke-ShowroomPump 'Building cards' $i $rows.Count
    }
    $showCardFlow.SuspendLayout()
    try {
      $showCardFlow.Controls.Clear()
      if ($cards.Count) { $showCardFlow.Controls.AddRange($cards.ToArray()) }
    } finally { $showCardFlow.ResumeLayout($true) }
  } finally {
    $script:SuppressShowroom = $false
  }
  # Set the final title AFTER the card loop (its progress pump overwrites the title while cards are built)
  $lblShowTitle.Text = ("SHOWROOM - Installed ({0} items shown)" -f $rows.Count)
  $tm.CardsMs = $sw.ElapsedMilliseconds

  # Every card image comes from the preload above; nothing is queued for later (no lazy/hover/click thumb loads).
  # Auto-select: a new Search (selection cleared) or a rebuild with no / vanished selection shows the FIRST card
  # (preview + 3D). A user's own selection survives tab switches and pack-change rebuilds while the item is still shown.
  $selShown = $false
  if ($script:ShowroomSelected) { foreach ($r in $rows) { if ($r.ItemKey -eq $script:ShowroomSelected) { $selShown = $true; break } } }
  if ($rows.Count -and -not $selShown) {
    Select-ShowroomPack $rows[0].ItemKey
  } else {
    if (-not $rows.Count) { $script:ShowroomSelected = $null }
    Update-FixPreview
  }
  $extra = ''
  if ($pre -and $pre.Ms -gt 0) { $extra = (" | thumbs loaded in {0:N1}s" -f ($pre.Ms / 1000.0)) + $(if ($pre.Rendered) { (" ({0} 3D rendered)" -f $pre.Rendered) } else { '' }) + $(if ($pre.Cancelled) { ' - cancelled' } else { '' }) }
  Set-Status ("GALLERY - Showroom | {0} items | {1} missing thumbs | {2} checked{3}" -f $rows.Count, $missingN, $script:ShowroomChecked.Count, $extra)
}

function Invoke-ShowroomMakeSelected {
  # Card checkboxes select items for browse; Make builds pack contact sheets for unique source packs.
  if (-not $script:ShowroomChecked.Count) {
    [void][System.Windows.Forms.MessageBox]::Show('Check one or more Showroom item cards first.', 'Make previews')
    return
  }
  $packNames = @(Get-ShowroomCheckedPackNames | Sort-Object)
  if (-not $packNames.Count) {
    [void][System.Windows.Forms.MessageBox]::Show('Checked items have no source packs.', 'Make previews')
    return
  }
  $byName = @{}
  foreach ($r in $script:ShowroomRows) {
    if ($r -and $r.PackFile -and $r.File) { $byName[$r.PackFile] = $r.File }
  }
  New-Item -ItemType Directory -Force -Path $prevD | Out-Null
  $todo = @(); $same = 0; $gone = 0
  $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
  try { [void](Test-OU3DReady -Wait) } finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
  foreach ($nm in $packNames) {
    if (-not $byName.ContainsKey($nm)) { $gone++; continue }
    $srcItem = $byName[$nm]
    $src = $srcItem.FullName
    if (-not (Test-Path -LiteralPath $src)) { $gone++; continue }
    $out = Join-Path $prevD ("{0}.png" -f $nm)
    $flatFresh = (Test-Path -LiteralPath $out) -and (Get-Item -LiteralPath $out).LastWriteTime -gt (Get-Item -LiteralPath $src).LastWriteTime
    if ($flatFresh -and (Test-Pack3DFresh $src)) { $same++; continue }
    $todo += [pscustomobject]@{ File = $nm; FullName = $src; Flat = (-not $flatFresh) }
  }
  if (-not $todo.Count) {
    [void][System.Windows.Forms.MessageBox]::Show(("All {0} source pack(s) for the checked items already have contact sheets." -f $same), 'Make previews')
    Update-FixPreview; return
  }
  $btnFixMakePrev.Enabled = $false; $btnFixDelPrev.Enabled = $false
  $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
  Set-Status ("Making {0} pack contact sheet(s)..." -f $todo.Count)
  try {
    $null = @(Make-Previews $todo 6>&1 | ForEach-Object { "$_" })
  } catch {}
  finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
  $flatTodo = @($todo | Where-Object { $_.Flat })
  $made = @($flatTodo | Where-Object { Test-Path -LiteralPath (Join-Path $prevD ("{0}.png" -f $_.File)) }).Count
  $fail = $flatTodo.Count - $made
  $msg = "{0} pack contact sheet(s) made, {1} already up to date." -f $made, $same
  $msg += Get-Make3DSummary
  if ($fail) { $msg += "`n{0} pack(s) had no bike/rider textures or couldn't be previewed." -f $fail }
  if ($gone) { $msg += "`n{0} selected pack(s) are no longer installed." -f $gone }
  $script:CatalogDirty = $true   # PACK MANAGER Has preview column / filter
  Clear-ShowroomThumbs
  Refresh-ShowroomGrid
  Update-FixPreview
  [void][System.Windows.Forms.MessageBox]::Show($msg, 'Make previews')
}

function Invoke-ShowroomMakeMissing {
  # Packs (deduped) among filtered items that still lack a contact sheet PNG.
  $rows = @(Get-FilteredShowroomRows)
  $need = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($r in $rows) {
    if ($r.PackFile -and -not $r.PackHasSheet) { [void]$need.Add($r.PackFile) }
  }
  if (-not $need.Count) {
    [void][System.Windows.Forms.MessageBox]::Show('Every source pack in the current filter already has a contact sheet.', 'Make all missing')
    return
  }
  # Check one item per needed pack so Make selected can resolve packs
  $script:ShowroomChecked.Clear()
  foreach ($pf in $need) {
    $hit = @($rows | Where-Object { $_.PackFile -eq $pf } | Select-Object -First 1)
    if ($hit -and $hit[0]) { [void]$script:ShowroomChecked.Add($hit[0].ItemKey) }
  }
  Invoke-ShowroomMakeSelected
}



function Invoke-ShowroomReload {
  if (-not $script:ShowroomHasSearched) { Invoke-ShowroomSearch; return }
  Clear-ShowroomThumbs
  Refresh-ShowroomGrid
}

function Build-ShowroomFiltersRail {
  # Same filter set as PACK MANAGER left rail, minus Source (Showroom is Installed-only).
  # Dock Fill + BringToFront so filters sit under Showroom/Custom Packs Top buttons (same pattern as Build-FixFiltersRail).
  $panel = New-Object System.Windows.Forms.Panel
  $panel.Dock = 'Fill'
  $panel.AutoScroll = $true
  $panel.Padding = New-Object System.Windows.Forms.Padding(8)
  $panel.BackColor = [System.Drawing.Color]::Transparent
  $panel.Name = 'showroomFilterPanel'
  $leftRail.Controls.Add($panel)
  $panel.BringToFront()

  $y = 8
  $lbLock = New-Object System.Windows.Forms.Label
  $lbLock.Text = 'Source: Installed only'
  $lbLock.Location = New-Object System.Drawing.Point(8, $y)
  $lbLock.AutoSize = $true
  Set-OuLabel $lbLock -Muted
  $panel.Controls.Add($lbLock)
  $y += 24

  # Search box + [Search] [Clear] [...] at the top of the rail (visible without scrolling)
  $txtSearch = New-Object System.Windows.Forms.TextBox
  $txtSearch.Location = New-Object System.Drawing.Point(8, $y)
  $txtSearch.Width = 190
  $txtSearch.Name = 'txtShowroomSearch'
  Set-OuDarkInput $txtSearch
  Set-OuHeavySurface $txtSearch
  $panel.Controls.Add($txtSearch)
  try { $txtSearch.Add_HandleCreated({ param($sender, $e); Set-OuCueBanner $sender 'Search name / item' }) } catch { }
  $y += 28

  $btnSearchShow = New-Object System.Windows.Forms.Button
  $btnSearchShow.Text = 'Search'
  $btnSearchShow.Location = New-Object System.Drawing.Point(8, $y)
  $btnSearchShow.Size = New-Object System.Drawing.Size(100, 32)
  Set-OuPrimaryButton $btnSearchShow
  $panel.Controls.Add($btnSearchShow)

  $btnClearShow = New-Object System.Windows.Forms.Button
  $btnClearShow.Text = 'Clear'
  $btnClearShow.Location = New-Object System.Drawing.Point(112, $y)
  $btnClearShow.Size = New-Object System.Drawing.Size(54, 32)
  Set-OuSecondaryButton $btnClearShow
  $panel.Controls.Add($btnClearShow)

  $btnShowMore = New-Object System.Windows.Forms.Button
  $btnShowMore.Text = ''
  $btnShowMore.AccessibleName = 'More'
  $btnShowMore.Image = $script:IconMore
  $btnShowMore.Location = New-Object System.Drawing.Point(170, $y)
  $btnShowMore.Size = New-Object System.Drawing.Size(30, 32)
  $btnShowMore.Name = 'btnShowroomMore'
  Set-OuSecondaryButton $btnShowMore
  $panel.Controls.Add($btnShowMore)
  $y += 42

  $script:ShowroomMoreMenu = New-OuDarkMenu
  $miMakeMiss = Add-OuMenuItem $script:ShowroomMoreMenu 'Make all missing' 'MakeMissing' 'Make contact sheets for source packs in this filter that lack a pack PNG'
  $miReload = Add-OuMenuItem $script:ShowroomMoreMenu 'Reload thumbnails' 'Reload' 'Re-run the last Search and reload every thumbnail (same as Shift+click Search)'
  $miMakeMiss.Add_Click({ Invoke-ShowroomMakeMissing })
  $miReload.Add_Click({ Invoke-ShowroomReload })
  $btnShowMore.Add_Click({ param($sender, $e); $script:ShowroomMoreMenu.Show($sender, (New-Object System.Drawing.Point(0, $sender.Height))) })

  # Rider preview controls (number / hand guards / bar pad). Same shared state as the SETTINGS 'Rider preview' card
  # (Settings\rider.txt); preview only, the game save is never written.
  $rset = New-OURiderControls $panel 8 $y 'Showroom'
  $script:ShowroomNumberCheck = $rset.Show
  $script:ShowroomRiderSet = $rset
  Update-RiderControls
  $y = $rset.Bottom + 10

  function Add-ShowLabeledCombo([string]$label, [string[]]$items, [int]$top) {
    $lb = New-Object System.Windows.Forms.Label
    $lb.Text = $label
    $lb.Location = New-Object System.Drawing.Point(8, $top)
    $lb.AutoSize = $true
    Set-OuLabel $lb
    $panel.Controls.Add($lb)
    $cb = New-Object System.Windows.Forms.ComboBox
    $cb.DropDownStyle = 'DropDownList'
    $cb.Location = New-Object System.Drawing.Point(8, ($top + 18))
    $cb.Width = 190
    foreach ($i in $items) { [void]$cb.Items.Add($i) }
    if ($cb.Items.Count) { $cb.SelectedIndex = 0 }
    Set-OuDarkInput $cb
    Set-OuHeavySurface $cb
    $panel.Controls.Add($cb)
    $cb
  }

  $catItems = @('All') + @($script:CatOrder) + @('Unknown')
  $cmbCat = Add-ShowLabeledCombo 'Category' $catItems $y; $y += 52
  $cmbSub = Add-ShowLabeledCombo 'Subtype' @('All') $y; $y += 52
  $clsItems = @('All') + @($script:ClassOrder)
  $cmbCls = Add-ShowLabeledCombo 'Bike class' $clsItems $y; $y += 52
  $cmbSort = Add-ShowLabeledCombo 'Sort' @('By category','By pak name','Fewest notes first','Most notes first','Largest first') $y; $y += 52

  $mkChk = {
    param([string]$text, [int]$top)
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = $text
    $c.Location = New-Object System.Drawing.Point(8, $top)
    $c.AutoSize = $true
    $c.ForeColor = $script:Theme.Text
    $c.BackColor = [System.Drawing.Color]::Transparent
    $panel.Controls.Add($c)
    $c
  }
  $chkHasPrev = & $mkChk 'Has preview' $y; $y += 24
  $chkClashes = & $mkChk 'Clashes' $y; $y += 24
  $chkSolo = & $mkChk 'Clash-free only' $y; $y += 24

  # Rail contents follow the rail width (no clipping at 1024x674 / when the v-scrollbar shows)
  $syncW = {
    $sfc = $script:ShowroomFilterControls
    if (-not $sfc) { return }
    $p = $sfc.Panel
    $w = [Math]::Max(120, $p.ClientSize.Width - 16)
    foreach ($k in @('Cat','Sub','Cls','Sort','Search')) { if ($sfc[$k].Width -ne $w) { $sfc[$k].Width = $w } }
    $sfc.MoreBtn.Left = 8 + $w - $sfc.MoreBtn.Width
    $sfc.ClearBtn.Left = $sfc.MoreBtn.Left - 4 - $sfc.ClearBtn.Width
    $sfc.SearchBtn.Width = [Math]::Max(60, $sfc.ClearBtn.Left - 4 - 8)
  }

  $script:ShowroomFilterControls = @{
    Cat = $cmbCat; Sub = $cmbSub; Cls = $cmbCls; Sort = $cmbSort; Search = $txtSearch
    HasPrev = $chkHasPrev; Clashes = $chkClashes; Solo = $chkSolo; ShowNum = $chkShowNum
    SearchBtn = $btnSearchShow; ClearBtn = $btnClearShow; MoreBtn = $btnShowMore; MoreMenu = $script:ShowroomMoreMenu
    MakeMiss = $miMakeMiss; Reload = $miReload; Panel = $panel
  }
  $panel.Add_Resize($syncW)
  $panel.Add_ClientSizeChanged($syncW)
  & $syncW

  # Filters do NOT auto-repopulate - only Search / Reload (after a search) do
  $cmbCat.Add_SelectedIndexChanged({
    if ($script:SuppressShowroom) { return }
    if ($script:ShowroomFilterControls -and $script:ShowroomFilterControls.Sub) {
      $script:SuppressShowroom = $true
      try { $script:ShowroomFilterControls.Sub.SelectedIndex = 0 } finally { $script:SuppressShowroom = $false }
    }
  })
  $btnSearchShow.Add_Click({
    # Shift+click = force reload thumbnails (old Refresh button)
    if (([System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Shift) -eq [System.Windows.Forms.Keys]::Shift) { Invoke-ShowroomReload; return }
    Invoke-ShowroomSearch
  })
  $btnClearShow.Add_Click({ Clear-ShowroomGallery })
  # Enter in filter text box runs Search
  $txtSearch.Add_KeyDown({
    param($sender, $e)
    if ($e.KeyCode -eq 'Enter') { $e.SuppressKeyPress = $true; Invoke-ShowroomSearch }
  })
  Set-Tip $txtSearch 'Search pak / item names (Enter = Search)'
  Set-Tip $btnSearchShow 'Build Showroom item cards for Installed packs using the filters below (Shift+click = reload all thumbnails)'
  Set-Tip $btnClearShow 'Clear the center gallery (filters stay; click Search again to reload)'
  Set-Tip $btnShowMore 'More: Make all missing, Reload thumbnails'
  Set-Tip $chkSolo 'Only items that no other installed pack replaces'
  Set-Tip $lbLock 'Showroom always uses Installed packs (no Broken/Disabled toggle)'
}

function Show-ManageSub([string]$sub) {
  $script:ManageSub = $sub
  $pnlInstalled.Visible = $false
  $pnlShowroom.Visible = ($sub -eq 'Showroom')
  $pnlCustomPacks.Visible = ($sub -eq 'Custom Packs')
  if ($sub -eq 'Custom Packs') { Update-CustomPacksLayout }
  if ($script:ManageRailButtons) {
    foreach ($k in $script:ManageRailButtons.Keys) {
      if ($k -eq $sub) { Set-OuRailSelected $script:ManageRailButtons[$k] }
      else { Set-OuRailIdle $script:ManageRailButtons[$k] }
    }
  }
  if ($sub -eq 'Showroom') {
    Attach-FixPreviewHost $showPrevHost
    Init-ShowSplitters
    if (-not $script:ShowroomHasSearched) {
      # Empty until user clicks Search (avoids hang with many Installed packs)
      Clear-ShowroomGallery
    } elseif ($script:ShowroomDirty) {
      # Packs changed since the last Search: rebuild with the same filters/selection/checks, keep scroll if possible
      $sp = Get-OuScrollPos $showCardFlow
      Clear-ShowroomThumbs
      Refresh-ShowroomGrid
      Set-OuScrollPos $showCardFlow $sp
    } else {
      # Unchanged: cards, checks, selection and thumbs are still there; just put the shared preview back
      Update-FixPreview
      if ($script:ViewState.ContainsKey('ShowroomScroll')) { Set-OuScrollPos $showCardFlow $script:ViewState['ShowroomScroll'] }
      Set-Status ("GALLERY - Showroom | {0} items | {1} checked" -f $showCardFlow.Controls.Count, $script:ShowroomChecked.Count)
    }
  } else {
    # Return preview pane to PACK MANAGER host so it is not orphaned
    Attach-FixPreviewHost $fixSplit.Panel2
    Set-Status ("GALLERY - {0}" -f $sub)
  }
}

function Build-ManageRailForSub([string]$sub) {
  if ($script:CurrentPage -eq 'GALLERY') { Save-ViewState }
  $railKey = "GALLERY|$sub"
  if (Switch-LeftRail $railKey) {
    if ($script:RailCacheExtra.ContainsKey($railKey)) { $script:ManageRailButtons = $script:RailCacheExtra[$railKey] }
    Show-ManageSub $sub
    return
  }
  Clear-LeftRail
  # Top-docked nav host so Fill filter panel matches PACK MANAGER Header+Fill docking and stays visible.
  $navHost = New-Object System.Windows.Forms.Panel
  $navHost.Dock = 'Top'
  $navHost.Height = 110
  $navHost.Name = 'galleryNavHost'
  $navHost.BackColor = [System.Drawing.Color]::Transparent
  $leftRail.Controls.Add($navHost)

  $hdr = New-Object System.Windows.Forms.Label
  $hdr.Text = 'Filter'
  $hdr.Name = 'galleryFilterHdr'
  $hdr.Dock = 'Top'
  $hdr.Height = 28
  $hdr.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
  $hdr.Padding = New-Object System.Windows.Forms.Padding(10, 8, 0, 0)
  Set-OuLabel $hdr
  $navHost.Controls.Add($hdr)

  $script:ManageRailButtons = @{}
  # Custom Packs first, Showroom last + BringToFront => Showroom above Custom Packs
  foreach ($name in @('Custom Packs', 'Showroom')) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $name
    $b.Tag = $name
    $b.Dock = 'Top'
    $b.Height = 34
    $b.TextAlign = 'MiddleLeft'
    $b.Padding = New-Object System.Windows.Forms.Padding(12, 0, 0, 0)
    Set-OuRailIdle $b
    $navHost.Controls.Add($b)
    $b.BringToFront()
    $script:ManageRailButtons[$name] = $b
    $b.Add_Click({
      param($sender, $e)
      $was = $script:ManageSub
      Build-ManageRailForSub ([string]$sender.Tag)
      if ($script:ManageSub -ne $was) { Step-OuBackground }
    })
  }
  $hdr.BringToFront()
  # 'Filter' header belongs to the Showroom filters only; Custom Packs shows just the two nav items.
  if ($sub -ne 'Showroom') {
    $hdr.Visible = $false
    $navHost.Height = 82
  }

  if ($sub -eq 'Showroom') {
    Build-ShowroomFiltersRail
  }
  $script:RailCacheExtra[$railKey] = $script:ManageRailButtons
  Show-ManageSub $sub
}

function Build-ManageRail {
  if ($script:ManageSub -notin @('Custom Packs', 'Showroom')) { $script:ManageSub = 'Showroom' }
  Build-ManageRailForSub $script:ManageSub
}

# ==================== SETTINGS / README / VERSION ====================
function New-TextPage([string]$title) {
  $p = New-Object System.Windows.Forms.Panel
  $p.Dock = 'Fill'
  $p.Visible = $false
  Enable-OuGlass $p
  $t = New-Object System.Windows.Forms.Label
  $t.Text = $title
  $t.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
  $t.Dock = 'Top'
  $t.Height = 36
  Set-OuLabel $t
  $p.Controls.Add($t)
  $tb = New-Object System.Windows.Forms.TextBox
  $tb.Multiline = $true
  $tb.ScrollBars = 'Both'
  $tb.Dock = 'Fill'
  $tb.Font = New-Object System.Drawing.Font('Consolas', 9)
  $tb.WordWrap = $false
  Set-OuDarkInput $tb
  $p.Controls.Add($tb)
  $tb.BringToFront()
  $hostPanel.Controls.Add($p)
  @{ Panel = $p; Box = $tb; Title = $t }
}

# ==================== README (readable + toolbar) ====================
$pnlReadme = New-Object System.Windows.Forms.Panel
$pnlReadme.Dock = 'Fill'
$pnlReadme.Visible = $false
$pnlReadme.Name = 'pnlReadme'
Set-OuSeeThroughHost $pnlReadme
$hostPanel.Controls.Add($pnlReadme)

$readmeChrome = New-Object System.Windows.Forms.Panel
$readmeChrome.Dock = 'Top'
$readmeChrome.Height = 48
$readmeChrome.Name = 'readmeChrome'
Enable-OuGlass $readmeChrome ([int]$script:Theme.GlassAlphaHeavy)
$pnlReadme.Controls.Add($readmeChrome)

$lblReadmeTitle = New-Object System.Windows.Forms.Label
$lblReadmeTitle.Text = 'README'
$lblReadmeTitle.AutoSize = $true
$lblReadmeTitle.Location = New-Object System.Drawing.Point(12, 14)
$lblReadmeTitle.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$lblReadmeTitle.Name = 'lblReadmeTitle'
Set-OuLabel $lblReadmeTitle
$readmeChrome.Controls.Add($lblReadmeTitle)

$btnReadmeNotepad = New-ActionButton 'Open in Notepad' 140
$btnReadmeNotepad.Dock = 'None'
$btnReadmeNotepad.Size = New-Object System.Drawing.Size(140, 32)
$btnReadmeNotepad.Name = 'btnReadmeNotepad'

$readmeBtnHost = New-Object System.Windows.Forms.Panel
$readmeBtnHost.Dock = 'Right'
$readmeBtnHost.Width = 160
$readmeBtnHost.Padding = New-Object System.Windows.Forms.Padding(4, 8, 8, 8)
Set-OuSeeThroughHost $readmeBtnHost
$readmeChrome.Controls.Add($readmeBtnHost)

$readmeBtnRow = New-ButtonTable @($btnReadmeNotepad)
$readmeBtnRow.Dock = 'Fill'
$readmeBtnRow.Height = 32
$readmeBtnHost.Controls.Add($readmeBtnRow)

$readmeBody = New-Object System.Windows.Forms.Panel
$readmeBody.Dock = 'Fill'
$readmeBody.Name = 'readmeBody'
$readmeBody.Padding = New-Object System.Windows.Forms.Padding(8, 8, 8, 8)
Enable-OuGlass $readmeBody ([int]$script:Theme.GlassAlphaPreview)
$pnlReadme.Controls.Add($readmeBody)
$readmeBody.BringToFront()

$txtReadme = New-Object System.Windows.Forms.TextBox
$txtReadme.Multiline = $true
$txtReadme.ScrollBars = 'Both'
$txtReadme.Dock = 'Fill'
$txtReadme.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtReadme.WordWrap = $false
$txtReadme.ReadOnly = $true
$txtReadme.Name = 'txtReadme'
Set-OuDarkInput $txtReadme
$readmeBody.Controls.Add($txtReadme)
$txtReadme.BringToFront()

$btnReadmeNotepad.Add_Click({
  if (Test-Path -LiteralPath $readmePath) {
    Start-Process notepad.exe $readmePath
  } else {
    [void][System.Windows.Forms.MessageBox]::Show('README.txt not found.', 'README')
  }
})

# ==================== VERSION (About stamp) ====================
$pnlVersion = New-Object System.Windows.Forms.Panel
$pnlVersion.Dock = 'Fill'
$pnlVersion.Visible = $false
$pnlVersion.Name = 'pnlVersion'
Set-OuSeeThroughHost $pnlVersion
$hostPanel.Controls.Add($pnlVersion)

$versionFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$versionFlow.Dock = 'Fill'
$versionFlow.FlowDirection = 'TopDown'
$versionFlow.WrapContents = $false
$versionFlow.AutoScroll = $true
$versionFlow.Padding = New-Object System.Windows.Forms.Padding(6, 4, 6, 8)
$versionFlow.Name = 'versionFlow'
Set-OuSeeThroughHost $versionFlow
$pnlVersion.Controls.Add($versionFlow)

$script:VersionCardWidth = 720
$script:VersionUiDate = (Get-Item -LiteralPath $PSCommandPath -ErrorAction SilentlyContinue).LastWriteTime.ToString('yyyy-MM-dd')
if (-not $script:VersionUiDate) { $script:VersionUiDate = Get-Date -Format 'yyyy-MM-dd' }

function Sync-VersionCardWidths {
  if (-not $versionFlow -or $versionFlow.IsDisposed) { return }
  $w = [Math]::Max(420, $versionFlow.ClientSize.Width - 30)
  if ($w -le 0) { return }
  $script:VersionCardWidth = $w
  foreach ($c in @($versionFlow.Controls)) {
    if ($c -isnot [System.Windows.Forms.Control]) { continue }
    if ($c.Width -eq $w) { continue }
    try { $c.Width = $w } catch { }
  }
}
$versionFlow.Add_Resize({ Sync-VersionCardWidths })

$lblVersionPageTitle = New-Object System.Windows.Forms.Label
$lblVersionPageTitle.Text = 'Version'
$lblVersionPageTitle.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$lblVersionPageTitle.AutoSize = $false
$lblVersionPageTitle.Height = 32
$lblVersionPageTitle.Width = $script:VersionCardWidth
$lblVersionPageTitle.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
Set-OuLabel $lblVersionPageTitle
[void]$versionFlow.Controls.Add($lblVersionPageTitle)

$versionCard = New-Object System.Windows.Forms.Panel
$versionCard.Width = $script:VersionCardWidth
$versionCard.Height = 300
$versionCard.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
$versionCard.Name = 'versionAboutCard'
Set-OuSeeThroughHost $versionCard
[void]$versionFlow.Controls.Add($versionCard)

$versionChrome = New-Object System.Windows.Forms.Panel
$versionChrome.Dock = 'Top'
$versionChrome.Height = 36
$versionChrome.Name = 'versionAboutChrome'
Enable-OuGlass $versionChrome ([int]$script:Theme.GlassAlphaHeavy)
$versionCard.Controls.Add($versionChrome)

$lblAboutTitle = New-Object System.Windows.Forms.Label
$lblAboutTitle.Text = 'Open Unleashed Pak Fixer'
$lblAboutTitle.AutoSize = $true
$lblAboutTitle.Location = New-Object System.Drawing.Point(12, 8)
$lblAboutTitle.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
Set-OuLabel $lblAboutTitle
$versionChrome.Controls.Add($lblAboutTitle)

$versionBody = New-Object System.Windows.Forms.Panel
$versionBody.Dock = 'Fill'
$versionBody.Name = 'versionAboutBody'
$versionBody.Padding = New-Object System.Windows.Forms.Padding(12, 10, 12, 10)
Enable-OuGlass $versionBody ([int]$script:Theme.GlassAlphaPreview)
$versionCard.Controls.Add($versionBody)
$versionBody.BringToFront()

$lblConsoleVer = New-Object System.Windows.Forms.Label
$lblConsoleVer.Text = ('Version ' + $script:OU_Version)
$lblConsoleVer.AutoSize = $false
$lblConsoleVer.Location = New-Object System.Drawing.Point(12, 14)
$lblConsoleVer.Size = New-Object System.Drawing.Size(680, 24)
$lblConsoleVer.Anchor = 'Top,Left,Right'
$lblConsoleVer.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$lblConsoleVer.Name = 'lblConsoleVer'
Set-OuLabel $lblConsoleVer
$versionBody.Controls.Add($lblConsoleVer)

$lblUiWorking = New-Object System.Windows.Forms.Label
$lblUiWorking.AutoSize = $false
$lblUiWorking.Location = New-Object System.Drawing.Point(12, 44)
$lblUiWorking.Size = New-Object System.Drawing.Size(680, 70)
$lblUiWorking.Anchor = 'Top,Left,Right'
$lblUiWorking.Name = 'lblUiWorking'
Set-OuLabel $lblUiWorking -Muted
$versionBody.Controls.Add($lblUiWorking)

$lblVersionFileNote = New-Object System.Windows.Forms.Label
$lblVersionFileNote.AutoSize = $false
$lblVersionFileNote.Location = New-Object System.Drawing.Point(12, 122)
$lblVersionFileNote.Size = New-Object System.Drawing.Size(680, 22)
$lblVersionFileNote.Anchor = 'Top,Left,Right'
$lblVersionFileNote.Name = 'lblVersionFileNote'
Set-OuLabel $lblVersionFileNote -Muted
$versionBody.Controls.Add($lblVersionFileNote)

$btnOpenVersionTxt = New-ActionButton 'Open VERSION.txt' 150
$btnOpenVersionTxt.Dock = 'None'
$btnOpenVersionTxt.Size = New-Object System.Drawing.Size(150, 32)
$btnOpenVersionTxt.Location = New-Object System.Drawing.Point(12, 150)
$btnOpenVersionTxt.Anchor = 'Top,Left'
$btnOpenVersionTxt.Name = 'btnOpenVersionTxt'
$versionBody.Controls.Add($btnOpenVersionTxt)

$btnCheckUpdates = New-ActionButton 'Check for updates' 160
$btnCheckUpdates.Dock = 'None'
$btnCheckUpdates.Size = New-Object System.Drawing.Size(160, 32)
$btnCheckUpdates.Location = New-Object System.Drawing.Point(170, 150)
$btnCheckUpdates.Anchor = 'Top,Left'
$btnCheckUpdates.Name = 'btnCheckUpdates'
Set-OuPrimaryButton $btnCheckUpdates
$versionBody.Controls.Add($btnCheckUpdates)

$lblUpdateResult = New-Object System.Windows.Forms.Label
$lblUpdateResult.AutoSize = $false
$lblUpdateResult.Location = New-Object System.Drawing.Point(12, 192)
$lblUpdateResult.Size = New-Object System.Drawing.Size(500, 22)
$lblUpdateResult.Anchor = 'Top,Left,Right'
$lblUpdateResult.Name = 'lblUpdateResult'
$lblUpdateResult.Text = ''
Set-OuLabel $lblUpdateResult
$versionBody.Controls.Add($lblUpdateResult)

$btnUpdateDownload = New-ActionButton 'Open download page' 170
$btnUpdateDownload.Dock = 'None'
$btnUpdateDownload.Size = New-Object System.Drawing.Size(170, 30)
$btnUpdateDownload.Location = New-Object System.Drawing.Point(12, 218)
$btnUpdateDownload.Anchor = 'Top,Left'
$btnUpdateDownload.Name = 'btnUpdateDownload'
$btnUpdateDownload.Visible = $false
$versionBody.Controls.Add($btnUpdateDownload)

$versionBody.Add_Resize({
  param($s, $e)
  try {
    $w = [Math]::Max(200, $versionBody.ClientSize.Width - 24)
    $lblConsoleVer.Width = $w
    $lblUiWorking.Width = $w
    $lblVersionFileNote.Width = $w
    $lblUpdateResult.Width = $w
  } catch { }
})

function Update-VersionAbout {
  try {
    $mt = (Get-Item -LiteralPath $MyInvocation.MyCommand.Path -ErrorAction SilentlyContinue).LastWriteTime
  } catch { $mt = $null }
  if (-not $mt) {
    try { $mt = (Get-Item -LiteralPath $PSCommandPath -ErrorAction SilentlyContinue).LastWriteTime } catch { $mt = $null }
  }
  # Prefer live script path next to this UI file
  try {
    $uiItem = Get-Item -LiteralPath (Join-Path $here 'OU-UI.ps1') -ErrorAction SilentlyContinue
    if ($uiItem) { $mt = $uiItem.LastWriteTime }
  } catch { }
  if ($mt) { $script:VersionUiDate = $mt.ToString('yyyy-MM-dd') }
  else { $script:VersionUiDate = Get-Date -Format 'yyyy-MM-dd' }
  $lblConsoleVer.Text = ('Version ' + $script:OU_Version)
  $lblUiWorking.Text = ('Released {0}' -f $script:OU_VersionDate)
  if (Test-Path -LiteralPath $versionPath) {
    $lblVersionFileNote.Text = 'VERSION.txt is in the Pak Fixer folder.'
    $btnOpenVersionTxt.Visible = $true
    $btnOpenVersionTxt.Enabled = $true
  } else {
    $lblVersionFileNote.Text = 'VERSION.txt not found.'
    $btnOpenVersionTxt.Visible = $false
  }
  Sync-VersionCardWidths
}

function Load-VersionText {
  # Kept for compatibility; About stamp does not dump the file into a notepad.
  Update-VersionAbout
}

$btnOpenVersionTxt.Add_Click({
  if (Test-Path -LiteralPath $versionPath) {
    Start-Process explorer.exe "/select,$versionPath"
  } else {
    [void][System.Windows.Forms.MessageBox]::Show('VERSION.txt not found.', 'VERSION')
  }
})
Set-Tip $btnOpenVersionTxt 'Show VERSION.txt in Explorer'

# ---- Check for updates (GitHub Releases, background runspace, 10 s timeout) ----
$script:OuUpdPs = $null; $script:OuUpdIar = $null; $script:OuUpdUrl = $null
$script:OuUpdMock = $null   # test hook: @{ Ok=...; Tag=...; Url=...; Code=...; Msg=... } returned instead of calling GitHub
$script:OuUpdTimer = New-Object System.Windows.Forms.Timer
$script:OuUpdTimer.Interval = 200
$script:OuUpdTimer.Add_Tick({ if ($script:OuUpdIar -and $script:OuUpdIar.IsCompleted) { Complete-OuUpdateCheck } })

function Test-OuUpdateRepoSet { return ([string]$script:OU_UpdateRepo -match '^[\w.-]+/[\w.-]+$' -and $script:OU_UpdateRepo -ne 'OWNER/REPO') }

function Compare-OuVersion([string]$a, [string]$b) {
  # >0 when a is newer than b
  $pa = @(([string]$a -replace '^[vV]', '' -split '[^0-9]+') | Where-Object { $_ -ne '' } | ForEach-Object { [int64]$_ })
  $pb = @(([string]$b -replace '^[vV]', '' -split '[^0-9]+') | Where-Object { $_ -ne '' } | ForEach-Object { [int64]$_ })
  for ($i = 0; $i -lt [Math]::Max($pa.Count, $pb.Count); $i++) {
    $x = $(if ($i -lt $pa.Count) { $pa[$i] } else { 0 }); $y = $(if ($i -lt $pb.Count) { $pb[$i] } else { 0 })
    if ($x -ne $y) { return [Math]::Sign($x - $y) }
  }
  return 0
}

function Set-OuUpdateResult([string]$text, [string]$url) {
  $lblUpdateResult.Text = $text
  $script:OuUpdUrl = $url
  $btnUpdateDownload.Visible = [bool]$url
  Set-Status ('ABOUT - Version | ' + $text)
}

function Start-OuUpdateCheck {
  if ($script:OuUpdIar -and -not $script:OuUpdIar.IsCompleted) { return }
  if (-not (Test-OuUpdateRepoSet) -and -not $script:OuUpdMock) {
    Set-OuUpdateResult "Update checks aren't set up yet (no GitHub repo configured)." $null
    return
  }
  $btnCheckUpdates.Enabled = $false
  Set-OuUpdateResult 'Checking GitHub for updates...' $null
  $url = 'https://api.github.com/repos/{0}/releases/latest' -f $script:OU_UpdateRepo
  $ps = [powershell]::Create()
  [void]$ps.AddScript({
    param($url, $mock)
    if ($mock) { Start-Sleep -Milliseconds 300; return $mock }
    try {
      [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
      $r = Invoke-RestMethod -Uri $url -TimeoutSec 10 -UseBasicParsing -Headers @{ 'User-Agent' = 'OpenUnleashed-PakFixer'; 'Accept' = 'application/vnd.github+json' }
      return @{ Ok = $true; Tag = [string]$r.tag_name; Url = [string]$r.html_url }
    } catch {
      $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch { }
      return @{ Ok = $false; Code = $code; Msg = [string]$_.Exception.Message }
    }
  }).AddArgument($url).AddArgument($script:OuUpdMock)
  $script:OuUpdPs = $ps
  $script:OuUpdIar = $ps.BeginInvoke()
  $script:OuUpdTimer.Start()
}

function Complete-OuUpdateCheck {
  $script:OuUpdTimer.Stop()
  $res = $null
  try { $out = $script:OuUpdPs.EndInvoke($script:OuUpdIar); if ($out.Count) { $res = $out[$out.Count - 1] } } catch { $res = @{ Ok = $false; Code = 0; Msg = $_.Exception.Message } }
  try { $script:OuUpdPs.Dispose() } catch { }
  $script:OuUpdPs = $null; $script:OuUpdIar = $null
  $btnCheckUpdates.Enabled = $true
  if (-not $res) { Set-OuUpdateResult "Couldn't check for updates. Try again later." $null; return }
  if ($res.Ok -and $res.Tag) {
    $tag = ([string]$res.Tag) -replace '^[vV]', ''
    if ((Compare-OuVersion $tag $script:OU_Version) -gt 0) { Set-OuUpdateResult ("Version {0} is available (you have {1})." -f $tag, $script:OU_Version) ([string]$res.Url) }
    else { Set-OuUpdateResult ("You're up to date ({0})." -f $script:OU_Version) $null }
  } elseif ([int]$res.Code -eq 404) {
    Set-OuUpdateResult 'No releases found yet (or the GitHub repo was not found).' $null
  } elseif ([int]$res.Code -eq 403) {
    Set-OuUpdateResult 'GitHub is limiting requests right now. Try again in a few minutes.' $null
  } else {
    Set-OuUpdateResult "Couldn't reach GitHub. Check your internet connection and try again." $null
  }
}

$btnCheckUpdates.Add_Click({ Start-OuUpdateCheck })
$btnUpdateDownload.Add_Click({ if ($script:OuUpdUrl) { Start-Process $script:OuUpdUrl } })
Set-Tip $btnCheckUpdates 'Check GitHub Releases for a newer version (nothing is downloaded automatically)'
Set-Tip $btnUpdateDownload 'Open the release page in your browser'

# ---- ABOUT page: left rail README / Version ----
$script:AboutSub = 'README'
$script:AboutRailButtons = @{}
function Show-AboutSub([string]$sub) {
  if ($sub -notin @('README', 'Version')) { $sub = 'README' }
  $script:AboutSub = $sub
  $pnlReadme.Visible = ($sub -eq 'README')
  $pnlVersion.Visible = ($sub -eq 'Version')
  foreach ($k in @($script:AboutRailButtons.Keys)) {
    if ($k -eq $sub) { Set-OuRailSelected $script:AboutRailButtons[$k] } else { Set-OuRailIdle $script:AboutRailButtons[$k] }
  }
  if ($sub -eq 'README') { Load-ReadmeTextIfChanged; Set-Status 'ABOUT - README' }
  else { Update-VersionAbout; Set-Status ('ABOUT - Version ' + $script:OU_Version) }
}
function Build-AboutRail {
  Clear-LeftRail
  [void](Add-RailHeader 'ABOUT')
  $script:AboutRailButtons = @{}
  foreach ($n in @('README', 'Version')) {
    $b = Add-RailButton $n $n
    $script:AboutRailButtons[$n] = $b
    $b.Add_Click({ param($sender, $e); $was = $script:AboutSub; Show-AboutSub ([string]$sender.Tag); if ($script:AboutSub -ne $was) { Step-OuBackground } })
  }
  $script:RailCacheExtra['ABOUT'] = $script:AboutRailButtons
}

# ==================== SETTINGS (control panel) ====================
$pnlSettings = New-Object System.Windows.Forms.Panel
$pnlSettings.Dock = 'Fill'
$pnlSettings.Visible = $false
$pnlSettings.Name = 'pnlSettings'
Set-OuSeeThroughHost $pnlSettings
$hostPanel.Controls.Add($pnlSettings)

$settingsFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$settingsFlow.Dock = 'Fill'
$settingsFlow.FlowDirection = 'TopDown'
$settingsFlow.WrapContents = $false
$settingsFlow.AutoScroll = $true
$settingsFlow.Padding = New-Object System.Windows.Forms.Padding(6, 4, 6, 8)
$settingsFlow.Name = 'settingsFlow'
Set-OuSeeThroughHost $settingsFlow
$pnlSettings.Controls.Add($settingsFlow)

$script:SettingsCardWidth = 720
$script:PackFilesRoot = Join-Path $root 'Pack Files'
$script:ThemeDir = Join-Path $root 'Settings\Theme'
$script:SettingsAdvExpanded = $false

$script:SettingsSyncBusy = $false
function Sync-SettingsCardWidths {
  if ($script:SettingsSyncBusy) { return }
  if (-not $settingsFlow -or $settingsFlow.IsDisposed) { return }
  $w = [Math]::Max(420, $settingsFlow.ClientSize.Width - 30)
  if ($w -le 0) { return }
  $script:SettingsSyncBusy = $true
  try {
    $script:SettingsCardWidth = $w
    foreach ($c in @($settingsFlow.Controls)) {
      if ($c -isnot [System.Windows.Forms.Control]) { continue }
      if ($c.Width -eq $w) { continue }
      try { $c.Width = $w } catch { }
    }
  } finally {
    $script:SettingsSyncBusy = $false
  }
}
$settingsFlow.Add_Resize({ Sync-SettingsCardWidths })

function New-SettingsPathCard([string]$title, [string]$namePrefix) {
  $card = New-Object System.Windows.Forms.Panel
  $card.Width = $script:SettingsCardWidth
  $card.Height = 82
  $card.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
  $card.Name = ($namePrefix + 'Card')
  Set-OuSeeThroughHost $card

  $chrome = New-Object System.Windows.Forms.Panel
  $chrome.Dock = 'Top'
  $chrome.Height = 30
  $chrome.Name = ($namePrefix + 'Chrome')
  Enable-OuGlass $chrome ([int]$script:Theme.GlassAlphaHeavy)
  $card.Controls.Add($chrome)

  $lblTitle = New-Object System.Windows.Forms.Label
  $lblTitle.Text = $title
  $lblTitle.AutoSize = $true
  $lblTitle.Location = New-Object System.Drawing.Point(10, 6)
  $lblTitle.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
  Set-OuLabel $lblTitle
  $chrome.Controls.Add($lblTitle)

  $body = New-Object System.Windows.Forms.Panel
  $body.Dock = 'Fill'
  $body.Name = ($namePrefix + 'Body')
  Enable-OuGlass $body ([int]$script:Theme.GlassAlphaPreview)
  $card.Controls.Add($body)
  $body.BringToFront()

  $lblPath = New-Object System.Windows.Forms.Label
  $lblPath.AutoSize = $false
  $lblPath.Location = New-Object System.Drawing.Point(10, 10)
  $lblPath.Size = New-Object System.Drawing.Size(520, 34)
  $lblPath.Anchor = 'Top,Left,Right'
  $lblPath.Name = ($namePrefix + 'Path')
  Set-OuLabel $lblPath -Muted
  $body.Controls.Add($lblPath)

  $btnOpen = New-ActionButton 'Open folder' 110
  $btnOpen.Dock = 'None'
  $btnOpen.Size = New-Object System.Drawing.Size(110, 32)
  $btnOpen.Location = New-Object System.Drawing.Point(540, 8)
  $btnOpen.Anchor = 'Top,Right'
  $btnOpen.Name = ($namePrefix + 'Open')
  $body.Controls.Add($btnOpen)

  $body.Add_Resize({
    param($s, $e)
    try {
      $lblPath.Width = [Math]::Max(120, $body.ClientSize.Width - 140)
      $btnOpen.Left = [Math]::Max(120, $body.ClientSize.Width - 122)
    } catch { }
  })

  return @{ Card = $card; PathLabel = $lblPath; OpenButton = $btnOpen; Chrome = $chrome; Body = $body }
}

# Title
$lblSettingsTitle = New-Object System.Windows.Forms.Label
$lblSettingsTitle.Text = 'SETTINGS'
$lblSettingsTitle.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$lblSettingsTitle.AutoSize = $false
$lblSettingsTitle.Height = 32
$lblSettingsTitle.Width = $script:SettingsCardWidth
$lblSettingsTitle.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
Set-OuLabel $lblSettingsTitle
[void]$settingsFlow.Controls.Add($lblSettingsTitle)

# Top strip: game folder + Change…
$settingsGameCard = New-Object System.Windows.Forms.Panel
$settingsGameCard.Width = $script:SettingsCardWidth
$settingsGameCard.Height = 56
$settingsGameCard.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
$settingsGameCard.Name = 'settingsGameCard'
Enable-OuGlass $settingsGameCard ([int]$script:Theme.GlassAlphaHeavy)
[void]$settingsFlow.Controls.Add($settingsGameCard)

$lblSettingsGame = New-Object System.Windows.Forms.Label
$lblSettingsGame.Text = 'Game folder'
$lblSettingsGame.AutoSize = $true
$lblSettingsGame.Location = New-Object System.Drawing.Point(10, 16)
Set-OuLabel $lblSettingsGame
$settingsGameCard.Controls.Add($lblSettingsGame)

$txtSettingsGame = New-Object System.Windows.Forms.TextBox
$txtSettingsGame.ReadOnly = $true
$txtSettingsGame.Location = New-Object System.Drawing.Point(100, 13)
$txtSettingsGame.Size = New-Object System.Drawing.Size(480, 24)
$txtSettingsGame.Anchor = 'Top,Left,Right'
$txtSettingsGame.Name = 'txtSettingsGame'
Set-OuDarkInput $txtSettingsGame
$settingsGameCard.Controls.Add($txtSettingsGame)

$btnSettingsChange = New-Object System.Windows.Forms.Button
$btnSettingsChange.Text = 'Change...'
$btnSettingsChange.Size = New-Object System.Drawing.Size(100, 28)
$btnSettingsChange.Location = New-Object System.Drawing.Point(596, 12)
$btnSettingsChange.Anchor = 'Top,Right'
Set-OuSecondaryButton $btnSettingsChange
$settingsGameCard.Controls.Add($btnSettingsChange)
$settingsGameCard.Add_Resize({
  $txtSettingsGame.Width = [Math]::Max(160, $settingsGameCard.ClientSize.Width - 220)
  $btnSettingsChange.Left = [Math]::Max(260, $settingsGameCard.ClientSize.Width - 112)
})

# ---- Rider preview controls ----
# One shared state (Settings\rider.txt via Manage-OUPaks: RiderNumber, RiderName, ShowNumbers, BarPad, HandGuards) drives two
# identical control sets: the Showroom rail and the SETTINGS 'Rider preview' card. Preview only - save.json is never written.
# Blank number box = the save number (gray cue banner). A typed number applies on Enter, on leaving the box, or 0.9 s after typing stops.
if (-not ('OuCueBanner' -as [type])) {
  try {
    Add-Type -Namespace '' -Name 'OuCueBanner' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] public static extern System.IntPtr SendMessage(System.IntPtr hWnd, int msg, System.IntPtr wParam, string lParam);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] public static extern System.IntPtr SendMessage(System.IntPtr hWnd, int msg, System.Text.StringBuilder wParam, System.IntPtr lParam);
'@ -ErrorAction Stop
  } catch { }
}
$script:RiderCtlSets = New-Object System.Collections.ArrayList
$script:RiderCueText = ''
$script:SuppressRiderToggle = $false
$script:ShowroomNumberCheck = $null
$script:RiderNumPending = $null
$script:RiderNumTimer = New-Object System.Windows.Forms.Timer
$script:RiderNumTimer.Interval = 900
$script:RiderNumTimer.Add_Tick({
  $script:RiderNumTimer.Stop()
  $tb = $script:RiderNumPending; $script:RiderNumPending = $null
  if ($tb -and -not $tb.IsDisposed) { Invoke-RiderNumberCommit $tb -Typing }
})
function Set-OuCueBanner([System.Windows.Forms.TextBox]$tb, [string]$text) {
  # EM_SETCUEBANNER (wParam 1 = keep showing while focused): gray placeholder, not real text
  try { if ($tb -and -not $tb.IsDisposed -and $tb.IsHandleCreated -and ('OuCueBanner' -as [type])) { [void][OuCueBanner]::SendMessage($tb.Handle, 0x1501, [IntPtr]1, $text) } } catch { }
}
function Get-OuCueBanner([System.Windows.Forms.TextBox]$tb) {
  try { $sb = New-Object System.Text.StringBuilder 64; [void][OuCueBanner]::SendMessage($tb.Handle, 0x1502, $sb, [IntPtr]64); return $sb.ToString() } catch { return '' }
}
function New-OuRiderCheck([System.Windows.Forms.Control]$parent, [string]$text, [string]$name, [int]$x, [int]$y, [switch]$BoxRight) {
  $c = New-Object System.Windows.Forms.CheckBox
  $c.Text = $text
  $c.Name = $name
  $c.AutoSize = $true
  if ($BoxRight) { $c.CheckAlign = 'MiddleRight'; $c.TextAlign = 'MiddleLeft' }
  $c.ForeColor = $script:Theme.Text
  $c.BackColor = [System.Drawing.Color]::Transparent
  $c.Location = New-Object System.Drawing.Point($x, $y)
  $parent.Controls.Add($c)
  $c
}
function New-OURiderControls([System.Windows.Forms.Control]$parent, [int]$x, [int]$y, [string]$prefix) {
  # [ ] Show rider number [###]
  # [ ] Show handguards
  # Bar pad: Round [ ]  -  Crossbar [ ]
  # Rows 1 and 3 are FlowLayoutPanels so they re-flow if the rail / card font changes after build (no clipping, no h-scroll).
  $set = @{ Prefix = $prefix }
  $mkRow = {
    param([int]$top)
    $f = New-Object System.Windows.Forms.FlowLayoutPanel
    $f.AutoSize = $true; $f.AutoSizeMode = 'GrowAndShrink'; $f.WrapContents = $false
    $f.Margin = New-Object System.Windows.Forms.Padding(0); $f.Padding = New-Object System.Windows.Forms.Padding(0)
    $f.BackColor = [System.Drawing.Color]::Transparent
    $f.Location = New-Object System.Drawing.Point($x, $top)
    $parent.Controls.Add($f)
    $f
  }
  $row1 = & $mkRow $y
  $set.Show = New-OuRiderCheck $row1 'Show rider number' ("chk{0}RiderNumber" -f $prefix) 0 0
  $set.Show.Margin = New-Object System.Windows.Forms.Padding(0, 3, 4, 0)
  $tb = New-Object System.Windows.Forms.TextBox
  $tb.Name = ("txt{0}RiderNumber" -f $prefix)
  $tb.MaxLength = 3          # game range 0-999 (MxaRiderProfile.Number clamps to 0..999)
  $tb.Size = New-Object System.Drawing.Size(48, 23)
  $tb.Margin = New-Object System.Windows.Forms.Padding(0)
  $tb.ShortcutsEnabled = $true
  Set-OuDarkInput $tb
  $row1.Controls.Add($tb)
  $set.Num = $tb
  $set.HG = New-OuRiderCheck $parent 'Show handguards' ("chk{0}HandGuards" -f $prefix) $x ($y + 28)
  $row3 = & $mkRow ($y + 52)
  $mkLbl = {
    param([string]$t)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $t; $l.AutoSize = $true
    $l.Margin = New-Object System.Windows.Forms.Padding(0, 3, 0, 0); $l.Padding = New-Object System.Windows.Forms.Padding(0)
    Set-OuLabel $l
    $row3.Controls.Add($l)
    $l
  }
  # 'Round [ ]  -  Crossbar [ ]': text label + box-only checkbox (exact spacing; clicking the word picks that pad too)
  $lbPad = & $mkLbl 'Bar pad:'; $lbPad.Margin = New-Object System.Windows.Forms.Padding(0, 3, 3, 0)
  $lbRound = & $mkLbl 'Round'
  $set.Round = New-OuRiderCheck $row3 '' ("chk{0}BarPadRound" -f $prefix) 0 0
  $lbDash = & $mkLbl '-'; $lbDash.Margin = New-Object System.Windows.Forms.Padding(2, 3, 2, 0)
  $lbCross = & $mkLbl 'Crossbar'
  $set.Cross = New-OuRiderCheck $row3 '' ("chk{0}BarPadCrossbar" -f $prefix) 0 0
  $set.Round.AccessibleName = 'Bar pad Round'; $set.Cross.AccessibleName = 'Bar pad Crossbar'
  foreach ($c in @($set.Round, $set.Cross)) { $c.Margin = New-Object System.Windows.Forms.Padding(2, 4, 0, 0); $c.Padding = New-Object System.Windows.Forms.Padding(0) }
  $lbRound.Tag = $set.Round; $lbCross.Tag = $set.Cross
  foreach ($l in @($lbRound, $lbCross)) { $l.Cursor = [System.Windows.Forms.Cursors]::Hand; $l.Add_Click({ param($sender, $e); $b = $sender.Tag; if ($b -and -not $b.Checked) { $b.Checked = $true } }) }
  $set.Row1 = $row1; $set.Row3 = $row3
  $set.Bottom = $y + 52 + 22
  foreach ($c in @($set.Show, $set.Num, $set.HG, $set.Round, $set.Cross)) { $c.Tag = $set }

  $set.Show.Add_CheckedChanged({ param($sender, $e); if (-not $script:SuppressRiderToggle) { Invoke-RiderShowToggle ([bool]$sender.Checked) } })
  $tb.Add_KeyPress({ param($sender, $e); if (-not [char]::IsControl($e.KeyChar) -and ($e.KeyChar -lt [char]'0' -or $e.KeyChar -gt [char]'9')) { $e.Handled = $true } })
  $tb.Add_KeyDown({
    param($sender, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Return) { $e.SuppressKeyPress = $true; $e.Handled = $true; Invoke-RiderNumberCommit $sender }
  })
  $tb.Add_TextChanged({
    param($sender, $e)
    if ($script:SuppressRiderToggle) { return }
    $t = [string]$sender.Text; $d = ($t -replace '[^0-9]', ''); if ($d.Length -gt 3) { $d = $d.Substring(0, 3) }
    if ($d -ne $t) { $script:SuppressRiderToggle = $true; try { $sender.Text = $d; $sender.SelectionStart = $d.Length } finally { $script:SuppressRiderToggle = $false } }
    if ($sender.Focused) { $script:RiderNumPending = $sender; $script:RiderNumTimer.Stop(); $script:RiderNumTimer.Start() }   # debounce while typing
  })
  $tb.Add_Leave({ param($sender, $e); Invoke-RiderNumberCommit $sender })
  $tb.Add_HandleCreated({ param($sender, $e); Set-OuCueBanner $sender $script:RiderCueText })
  $set.HG.Add_CheckedChanged({ param($sender, $e); if (-not $script:SuppressRiderToggle) { Invoke-RiderHandGuardsSet ([bool]$sender.Checked) } })
  $padChanged = {
    param($sender, $e)
    if ($script:SuppressRiderToggle) { return }
    if (-not $sender.Checked) {
      # one bar pad is always on: unchecking the active one is refused (pick the other one instead)
      $script:SuppressRiderToggle = $true; try { $sender.Checked = $true } finally { $script:SuppressRiderToggle = $false }
      return
    }
    Invoke-RiderBarPadSet $(if ([string]$sender.Name -like '*Round') { 'fatbar' } else { 'crossbar' })
  }
  $set.Round.Add_CheckedChanged($padChanged)
  $set.Cross.Add_CheckedChanged($padChanged)

  Set-Tip $set.Show 'Draw the rider number on bike plates in the Showroom (cards, live 3D, full screen). Make Previews always includes it.'
  Set-Tip $tb 'Custom race number for previews (0-999). Blank = your in-game number (shown in gray). Enter or leave the box to apply.'
  Set-Tip $set.HG 'Draw hand guards on preview bikes. Starts from your in-game setting; preview only, the game save is not changed.'
  foreach ($ctl in @($set.Round, $lbRound)) { Set-Tip $ctl 'Round fat bar pad (in-game FAT BAR). Preview only.' }
  foreach ($ctl in @($set.Cross, $lbCross)) { Set-Tip $ctl 'Block crossbar pad (in-game CROSSBAR). Preview only.' }
  [void]$script:RiderCtlSets.Add($set)
  $set
}

# Rider preview card (SETTINGS): same controls as the Showroom rail + rider name + Reset to in-game.
$settingsRiderCard = New-Object System.Windows.Forms.Panel
$settingsRiderCard.Width = $script:SettingsCardWidth
$settingsRiderCard.Height = 158
$settingsRiderCard.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
$settingsRiderCard.Name = 'settingsRiderCard'
Enable-OuGlass $settingsRiderCard ([int]$script:Theme.GlassAlphaHeavy)
[void]$settingsFlow.Controls.Add($settingsRiderCard)

$lblRiderTitle = New-Object System.Windows.Forms.Label
$lblRiderTitle.Text = 'Rider preview'
$lblRiderTitle.AutoSize = $true
$lblRiderTitle.Location = New-Object System.Drawing.Point(10, 8)
$lblRiderTitle.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
Set-OuLabel $lblRiderTitle
$settingsRiderCard.Controls.Add($lblRiderTitle)

$lblRiderSub = New-Object System.Windows.Forms.Label
$lblRiderSub.Text = 'Showroom / 3D preview bikes only - the game save is never changed'
$lblRiderSub.AutoSize = $true
$lblRiderSub.Location = New-Object System.Drawing.Point(($lblRiderTitle.Right + 10), 11)
Set-OuLabel $lblRiderSub -Muted
$settingsRiderCard.Controls.Add($lblRiderSub)

$script:SettingsRiderSet = New-OURiderControls $settingsRiderCard 12 38 'Settings'
$chkRiderShow = $script:SettingsRiderSet.Show
$chkRiderShow.Name = 'chkRiderShow'
$txtRiderNum = $script:SettingsRiderSet.Num
$txtRiderNum.Name = 'txtRiderNum'

$lblRiderName = New-Object System.Windows.Forms.Label
$lblRiderName.Text = 'Name'
$lblRiderName.AutoSize = $true
$lblRiderName.Location = New-Object System.Drawing.Point(280, 41)
Set-OuLabel $lblRiderName
$settingsRiderCard.Controls.Add($lblRiderName)

$txtRiderName = New-Object System.Windows.Forms.TextBox
$txtRiderName.Location = New-Object System.Drawing.Point(324, 38)
$txtRiderName.Size = New-Object System.Drawing.Size(170, 23)
$txtRiderName.MaxLength = 24
$txtRiderName.Name = 'txtRiderName'
Set-OuDarkInput $txtRiderName
$settingsRiderCard.Controls.Add($txtRiderName)
$txtRiderName.Add_KeyDown({ param($sender, $e); if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Return) { $e.SuppressKeyPress = $true; $e.Handled = $true; Invoke-RiderNameCommit $sender } })
$txtRiderName.Add_Leave({ param($sender, $e); Invoke-RiderNameCommit $sender })
$txtRiderName.Add_HandleCreated({ param($sender, $e); Set-OuCueBanner $sender $script:RiderNameCue })

$btnRiderAuto = New-Object System.Windows.Forms.Button
$btnRiderAuto.Text = 'Reset to in-game'
$btnRiderAuto.Name = 'btnRiderReset'
$btnRiderAuto.Size = New-Object System.Drawing.Size(130, 28)
$btnRiderAuto.Location = New-Object System.Drawing.Point(($settingsRiderCard.ClientSize.Width - 142), 36)
$btnRiderAuto.Anchor = 'Top,Right'
Set-OuSecondaryButton $btnRiderAuto
$settingsRiderCard.Controls.Add($btnRiderAuto)

$lblRiderInfo = New-Object System.Windows.Forms.Label
$lblRiderInfo.AutoSize = $false
$lblRiderInfo.Location = New-Object System.Drawing.Point(10, 118)
$lblRiderInfo.Size = New-Object System.Drawing.Size(680, 34)
$lblRiderInfo.Anchor = 'Top,Left,Right'
$lblRiderInfo.Name = 'lblRiderInfo'
Set-OuLabel $lblRiderInfo -Muted
$settingsRiderCard.Controls.Add($lblRiderInfo)
$settingsRiderCard.Add_Resize({
  $lblRiderInfo.Width = [Math]::Max(200, $settingsRiderCard.ClientSize.Width - 20)
  $btnRiderAuto.Left = [Math]::Max(500, $settingsRiderCard.ClientSize.Width - 142)
})

$script:RiderNameCue = ''
function Update-RiderControls($r = $null) {
  # Push the shared rider state into every control set (rail + SETTINGS). Guarded by SuppressRiderToggle so no event loops.
  # A number box the user is typing in (focused or unapplied edit) is left alone.
  try {
    $ov = Get-OURiderOverride
    if (-not $r) { $r = Get-OURider -NoCacheWrite }
    $script:RiderCueText = [string]$r.DetectedNumber
    $script:RiderNameCue = [string]$r.DetectedName
    $numTxt = $(if ($ov.Number -ne 'auto') { [string]$ov.Number } else { '' })
    $script:SuppressRiderToggle = $true
    try {
      foreach ($s in @($script:RiderCtlSets)) {
        if (-not $s.Show -or $s.Show.IsDisposed) { $script:RiderCtlSets.Remove($s); continue }
        if ($s.Show.Checked -ne [bool]$ov.ShowNumbers) { $s.Show.Checked = [bool]$ov.ShowNumbers }
        if (-not $s.Num.Focused -and -not $s.Num.Modified -and $s.Num.Text -ne $numTxt) { $s.Num.Text = $numTxt }
        Set-OuCueBanner $s.Num $script:RiderCueText
        if ($s.HG.Checked -ne [bool]$r.HandGuards) { $s.HG.Checked = [bool]$r.HandGuards }
        if ($s.Round.Checked -ne [bool]$r.FatBar) { $s.Round.Checked = [bool]$r.FatBar }
        if ($s.Cross.Checked -ne (-not [bool]$r.FatBar)) { $s.Cross.Checked = (-not [bool]$r.FatBar) }
      }
      if ($txtRiderName -and -not $txtRiderName.IsDisposed) { Set-OuCueBanner $txtRiderName $script:RiderNameCue }
    } finally { $script:SuppressRiderToggle = $false }
  } catch { }
}
function Update-RiderToggleText { Update-RiderControls }
function Set-RiderToggleChecks([bool]$on) {
  $script:SuppressRiderToggle = $true
  try {
    foreach ($s in @($script:RiderCtlSets)) { if ($s.Show -and -not $s.Show.IsDisposed -and $s.Show.Checked -ne $on) { $s.Show.Checked = $on } }
  } finally { $script:SuppressRiderToggle = $false }
}
function Update-ShowroomThumbsForRider {
  # Re-request the 3D thumbs the cards already asked for; each card keeps its current image until the new one arrives
  # (cached on disk: Previews for numbers on, Previews\_nonum for off), so nothing blocks the UI.
  try {
    $asked = @($script:Showroom3DAsked)
    $script:Showroom3DAsked.Clear()
    if ($script:OU3DState -eq 'ready') { try { [OU3DHost]::CancelThumbs() } catch {} }
    foreach ($k in $asked) {
      $card = $script:ShowroomCardMap[$k]; if (-not $card -or $card.IsDisposed) { continue }
      foreach ($c in $card.Controls) { if ($c -is [System.Windows.Forms.PictureBox]) { Request-Showroom3DThumb $c; break } }
    }
  } catch {}
}
function Invoke-RiderShowToggle([bool]$on) {
  try {
    Set-OURiderShowNumbers $on
    Set-RiderToggleChecks $on
    $changed = $false
    if ($script:OU3DState -eq 'ready' -and ('OU3DHost' -as [type])) {
      $changed = [OU3DHost]::SetShowNumber($on)
      if ($script:Live3D) { try { [void][OU3DHost]::ApplyRiderToView($script:Live3D) } catch {} }
      if ($changed) { Update-ShowroomThumbsForRider }
    }
    Update-RiderCard
    Set-Status ($(if ($on) { 'Showroom: rider numbers on' } else { 'Showroom: rider numbers off (bare plates)' }))
  } catch {
    Set-Status ('Rider numbers: ' + $_.Exception.Message)
  }
}
function Invoke-RiderPreviewRefresh([string]$msg) {
  # Shared state changed: push to the 3D host (number + parts; stamps invalidate cached previews), live view, visible cards, all controls.
  try {
    $changed = $false
    if ($script:OU3DState -eq 'ready' -and ('OU3DHost' -as [type])) {
      $changed = [bool](Sync-OURider -Force)
      if ($script:Live3D) { try { [void][OU3DHost]::ApplyRiderToView($script:Live3D) } catch {} }
      if ($changed) { Update-ShowroomThumbsForRider }
    }
    Update-RiderCard
    if ($msg) { Set-Status ($msg + $(if ($changed) { ' - 3D previews re-rendering' } else { '' })) }
  } catch { Set-Status ('Rider preview: ' + $_.Exception.Message) }
}
function Invoke-RiderNumberCommit([System.Windows.Forms.TextBox]$tb, [switch]$Typing) {
  # Enter / leave / debounce. Blank = follow the save number. Digits only, 0-999 (game range).
  if (-not $tb -or $tb.IsDisposed) { return }
  if ($script:RiderNumPending -and $script:RiderNumPending -eq $tb) { $script:RiderNumTimer.Stop(); $script:RiderNumPending = $null }
  $d = ([string]$tb.Text -replace '[^0-9]', ''); if ($d.Length -gt 3) { $d = $d.Substring(0, 3) }
  if ($d) { $d = [string][int]$d }
  $want = $(if ($d) { $d } else { 'auto' })
  if (-not $Typing) {
    $tb.Modified = $false
    if ($tb.Text -ne $d) { $script:SuppressRiderToggle = $true; try { $tb.Text = $d } finally { $script:SuppressRiderToggle = $false } }
  }
  try {
    $ov = Get-OURiderOverride
    if ([string]$ov.Number -eq $want) { if (-not $Typing) { Update-RiderControls }; return }
    Set-OURiderOverride $want $ov.Name
  } catch { Set-Status ('Rider number: ' + $_.Exception.Message); return }
  Invoke-RiderPreviewRefresh ($(if ($want -eq 'auto') { 'Preview rider number: from game save' } else { "Preview rider number: #$want" }))
}
function Invoke-RiderNameCommit([System.Windows.Forms.TextBox]$tb) {
  if (-not $tb -or $tb.IsDisposed) { return }
  $m = ([string]$tb.Text).Trim() -replace '[\r\n=]', ' '
  $want = $(if ($m) { $m } else { 'auto' })
  $tb.Modified = $false
  try {
    $ov = Get-OURiderOverride
    if ([string]$ov.Name -eq $want) { return }
    Set-OURiderOverride $ov.Number $want
  } catch { Set-Status ('Rider name: ' + $_.Exception.Message); return }
  Invoke-RiderPreviewRefresh ($(if ($want -eq 'auto') { 'Rider name: from game save' } else { "Rider name: $want" }))
}
function Invoke-RiderHandGuardsSet([bool]$on) {
  # Same as the save -> no override (keeps following the save); different -> override. Preview only.
  try {
    $r = Get-OURider -NoCacheWrite
    Set-OUHandGuardsOverride $(if ($on -eq [bool]$r.SaveHandGuards) { $null } else { $on })
  } catch { Set-Status ('Hand guards: ' + $_.Exception.Message); return }
  Invoke-RiderPreviewRefresh ($(if ($on) { 'Preview: hand guards on' } else { 'Preview: hand guards off' }))
}
function Invoke-RiderBarPadSet([string]$pad) {
  try {
    $r = Get-OURider -NoCacheWrite; $fat = ($pad -eq 'fatbar')
    Set-OUBarPadOverride $(if ($fat -eq [bool]$r.SaveFatBar) { $null } else { $pad })
  } catch { Set-Status ('Bar pad: ' + $_.Exception.Message); return }
  Invoke-RiderPreviewRefresh ($(if ($fat) { 'Preview bar pad: Round' } else { 'Preview bar pad: Crossbar' }))
}
function Invoke-RiderReset {
  # Back to the in-game rider: number, name, bar pad and hand guards from the save; numbers shown.
  try {
    Save-OURiderOverride 'auto' 'auto' $true $null $null
    foreach ($s in @($script:RiderCtlSets)) { if ($s.Num -and -not $s.Num.IsDisposed) { $s.Num.Modified = $false; $s.Num.Text = '' } }
    if ($txtRiderName) { $txtRiderName.Modified = $false }
  } catch { Set-Status ('Rider reset: ' + $_.Exception.Message); return }
  Invoke-RiderPreviewRefresh 'Rider preview reset to your in-game settings'
}
function Update-RiderCard {
  try {
    $ov = Get-OURiderOverride; $r = Get-OURider
    Update-RiderControls $r
    if (-not $txtRiderName.Focused) { $txtRiderName.Text = $(if ($ov.Name -ne 'auto') { $ov.Name } else { '' }) }
    $det = if ($r.DetectedNumber -or $r.DetectedName) { ("{0} #{1}" -f $r.DetectedName, $r.DetectedNumber) } else { 'not found' }
    $from = if ($r.SavePath) { 'save.json' } elseif ($r.DetectedNumber) { 'cache' } else { 'game defaults' }
    $onOff = { param($b) if ($b) { 'on' } else { 'off' } }
    $show = if (-not $r.Number) { 'no number' } elseif ($ov.ShowNumbers) { ('#' + $r.Number) } else { ('#' + $r.Number + ' hidden') }
    $l1 = ("In-game ({0}): {1}, {2} bar pad, hand guards {3}" -f $from, $det, $(if ($r.SaveFatBar) { 'Round' } else { 'Crossbar' }), (& $onOff $r.SaveHandGuards))
    $l2 = ("Preview: {0} ({1}), {2} ({3}), hand guards {4} ({5})" -f $show, $r.NumberSource, $r.BarPad, $r.BarPadSource, (& $onOff $r.HandGuards), $r.HandGuardsSource)
    $lblRiderInfo.Text = $l1 + "`r`n" + $l2
  } catch { $lblRiderInfo.Text = ('Rider detect failed: ' + $_.Exception.Message) }
}
function Invoke-RiderApply([string]$num, [string]$name) {
  # Kept for callers/scripts: set number + name override and refresh previews.
  try { Set-OURiderOverride $num $name } catch { Set-Status ('Rider settings: ' + $_.Exception.Message); return }
  Invoke-RiderPreviewRefresh 'Saved rider settings'
}
$btnRiderAuto.Add_Click({ Invoke-RiderReset })
Set-Tip $btnRiderAuto 'Clear the preview overrides: number, name, bar pad and hand guards follow your Open Unleashed save again'
Set-Tip $txtRiderName 'Rider name (stored only; the game shows it on the rider, not the bike). Blank = from game save.'

# Folders: one row, three open buttons (path in each tooltip)
$settingsFoldersCard = New-Object System.Windows.Forms.Panel
$settingsFoldersCard.Width = $script:SettingsCardWidth
$settingsFoldersCard.Height = 52
$settingsFoldersCard.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
$settingsFoldersCard.Name = 'settingsFoldersCard'
Enable-OuGlass $settingsFoldersCard ([int]$script:Theme.GlassAlphaHeavy)
[void]$settingsFlow.Controls.Add($settingsFoldersCard)
$lblFoldersTitle = New-Object System.Windows.Forms.Label
$lblFoldersTitle.Text = 'Folders'
$lblFoldersTitle.AutoSize = $true
$lblFoldersTitle.Location = New-Object System.Drawing.Point(10, 16)
$lblFoldersTitle.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
Set-OuLabel $lblFoldersTitle
$settingsFoldersCard.Controls.Add($lblFoldersTitle)
$btnOpenRoot = New-ActionButton 'Pak Fixer'
$btnOpenPackFiles = New-ActionButton 'Pack Files'
$btnOpenTheme = New-ActionButton 'Theme'
$btnOpenRoot.Name = 'settingsRootOpen'; $btnOpenPackFiles.Name = 'settingsPackOpen'; $btnOpenTheme.Name = 'settingsThemeOpen'
$x = 100
foreach ($fb in @($btnOpenRoot, $btnOpenPackFiles, $btnOpenTheme)) {
  $fb.Dock = 'None'; $fb.Size = New-Object System.Drawing.Size(120, 32); $fb.Location = New-Object System.Drawing.Point($x, 10)
  $settingsFoldersCard.Controls.Add($fb); $x += 128
}
# Path labels kept (hidden) so Update-SettingsPanel can keep the tooltips current
$lblRootPath = New-Object System.Windows.Forms.Label
$lblPackFilesPath = New-Object System.Windows.Forms.Label
$lblThemePath = New-Object System.Windows.Forms.Label

# Advanced (collapsed)
$btnAdvToggle = New-Object System.Windows.Forms.Button
$btnAdvToggle.Text = 'Advanced  >  settings.txt'
$btnAdvToggle.Height = 32
$btnAdvToggle.Width = $script:SettingsCardWidth
$btnAdvToggle.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 6)
$btnAdvToggle.TextAlign = 'MiddleLeft'
$btnAdvToggle.Padding = New-Object System.Windows.Forms.Padding(10, 0, 0, 0)
Set-OuSecondaryButton $btnAdvToggle
[void]$settingsFlow.Controls.Add($btnAdvToggle)

$pnlAdv = New-Object System.Windows.Forms.Panel
$pnlAdv.Width = $script:SettingsCardWidth
$pnlAdv.Height = 220
$pnlAdv.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
$pnlAdv.Visible = $false
$pnlAdv.Name = 'settingsAdv'
Set-OuSeeThroughHost $pnlAdv
[void]$settingsFlow.Controls.Add($pnlAdv)

$advChrome = New-Object System.Windows.Forms.Panel
$advChrome.Dock = 'Top'
$advChrome.Height = 28
$advChrome.Name = 'settingsAdvChrome'
Enable-OuGlass $advChrome ([int]$script:Theme.GlassAlphaHeavy)
$pnlAdv.Controls.Add($advChrome)
$lblAdvTitle = New-Object System.Windows.Forms.Label
$lblAdvTitle.Text = 'settings.txt (power users)'
$lblAdvTitle.AutoSize = $true
$lblAdvTitle.Location = New-Object System.Drawing.Point(10, 5)
$lblAdvTitle.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
Set-OuLabel $lblAdvTitle
$advChrome.Controls.Add($lblAdvTitle)

$btnSaveSettings = New-ActionButton 'Save' 90
$btnReloadSettings = New-ActionButton 'Reload' 90
Set-OuPrimaryButton $btnSaveSettings
$advBtnRow = New-ButtonTable @($btnSaveSettings, $btnReloadSettings)
$advBtnRow.Dock = 'Bottom'
$advBtnRow.Height = 40
$pnlAdv.Controls.Add($advBtnRow)

$txtSettingsAdv = New-Object System.Windows.Forms.TextBox
$txtSettingsAdv.Multiline = $true
$txtSettingsAdv.ScrollBars = 'Both'
$txtSettingsAdv.Dock = 'Fill'
$txtSettingsAdv.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtSettingsAdv.WordWrap = $false
$txtSettingsAdv.Name = 'txtSettingsAdv'
Set-OuDarkInput $txtSettingsAdv
$pnlAdv.Controls.Add($txtSettingsAdv)
$txtSettingsAdv.BringToFront()

function Update-SettingsPanel {
  $g = Get-Game
  if ($g) { $txtSettingsGame.Text = $g }
  else { $txtSettingsGame.Text = '(not set - click Change...)' }
  $lblRootPath.Text = $root
  $lblPackFilesPath.Text = $script:PackFilesRoot
  $lblThemePath.Text = $script:ThemeDir
  Set-Tip $btnOpenRoot ('Open the Pak Fixer folder: ' + $root)
  Set-Tip $btnOpenPackFiles ('Open Pack Files (Broken / Disabled / Fixed / Originals): ' + $script:PackFilesRoot)
  Set-Tip $btnOpenTheme ('Open the Theme folder (background image): ' + $script:ThemeDir)
  Update-RiderCard
  Sync-SettingsCardWidths
}

function Get-OuFileStamp([string]$path) {
  try {
    if (-not (Test-Path -LiteralPath $path)) { return 'missing' }
    $fi = Get-Item -LiteralPath $path
    return ("{0}|{1}" -f $fi.LastWriteTimeUtc.Ticks, $fi.Length)
  } catch { return 'error' }
}
$script:SettingsTextStamp = $null
$script:ReadmeTextStamp = $null
function Load-SettingsText {
  if (Test-Path -LiteralPath $cfg) {
    $txtSettingsAdv.Text = Get-Content -LiteralPath $cfg -Raw -ErrorAction SilentlyContinue
  } else {
    $txtSettingsAdv.Text = "GameDataFolder=`n"
  }
  $txtSettingsAdv.Modified = $false
  $script:SettingsTextStamp = Get-OuFileStamp $cfg
}
function Load-SettingsTextIfChanged {
  # Keep unsaved edits and caret/scroll; reload only when settings.txt changed on disk (or never loaded).
  if ($txtSettingsAdv.Modified) { return }
  if ($script:SettingsTextStamp -and $script:SettingsTextStamp -eq (Get-OuFileStamp $cfg)) { return }
  Load-SettingsText
}
function Load-ReadmeText {
  if (Test-Path -LiteralPath $readmePath) {
    $txtReadme.Text = Get-Content -LiteralPath $readmePath -Raw -ErrorAction SilentlyContinue
  } else { $txtReadme.Text = '(README.txt not found)' }
  $script:ReadmeTextStamp = Get-OuFileStamp $readmePath
}
function Load-ReadmeTextIfChanged {
  # README is read-only here; reloading resets scroll, so only reload when the file changed.
  if ($script:ReadmeTextStamp -and $script:ReadmeTextStamp -eq (Get-OuFileStamp $readmePath)) { return }
  Load-ReadmeText
}
function Update-SettingsPanelKeepEdits {
  # Refresh paths / rider detection, but keep rider number/name the user typed and has not applied yet.
  $keep = @()
  foreach ($tb in @($txtRiderNum, $txtRiderName)) {
    if ($tb -and $tb.Modified) { $keep += @{ Box = $tb; Text = $tb.Text; Sel = $tb.SelectionStart } }
  }
  Update-SettingsPanel
  foreach ($k in $keep) {
    $k.Box.Text = $k.Text
    $k.Box.Modified = $true
    try { $k.Box.SelectionStart = [Math]::Min($k.Sel, $k.Text.Length) } catch { }
  }
}

function Invoke-ChangeGameFolder {
  try {
    & $fixer -ChangeFolder -ListOnly | Out-Null
    $g = Get-Game
    if ($g) { $script:game = $g }
    Update-GameBox
    Update-SettingsPanel
    Set-PackDataChanged
    if ($script:CurrentPage -eq 'PACK MANAGER') { Refresh-CatalogList }
  } catch {
    [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Change folder failed')
  }
}

function Open-SettingsFolder([string]$dir) {
  if (-not $dir) { return }
  if (-not (Test-Path -LiteralPath $dir)) {
    [void][System.IO.Directory]::CreateDirectory($dir)
  }
  Start-Process explorer.exe $dir
}

$btnSettingsChange.Add_Click({ Invoke-ChangeGameFolder })
$btnOpenRoot.Add_Click({ Open-SettingsFolder $root })
$btnOpenPackFiles.Add_Click({ Open-SettingsFolder $script:PackFilesRoot })
$btnOpenTheme.Add_Click({ Open-SettingsFolder $script:ThemeDir })

$btnAdvToggle.Add_Click({
  $script:SettingsAdvExpanded = -not $script:SettingsAdvExpanded
  $pnlAdv.Visible = $script:SettingsAdvExpanded
  if ($script:SettingsAdvExpanded) {
    $btnAdvToggle.Text = 'Advanced  v  settings.txt'
    Load-SettingsTextIfChanged
  } else {
    $btnAdvToggle.Text = 'Advanced  >  settings.txt'
  }
})

$btnSaveSettings.Add_Click({
  try {
    Set-Content -LiteralPath $cfg -Value $txtSettingsAdv.Text -Encoding ASCII
    $txtSettingsAdv.Modified = $false
    $script:SettingsTextStamp = Get-OuFileStamp $cfg
    $oldGame = $script:game
    $g = Get-Game
    if ($g) { $script:game = $g }
    if ([string]$script:game -ne [string]$oldGame) { Set-PackDataChanged }
    Update-GameBox
    Update-SettingsPanel
    Set-Status 'Saved settings.txt'
    [void][System.Windows.Forms.MessageBox]::Show('Saved Settings\settings.txt', 'Settings')
  } catch {
    [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Save failed')
  }
})
$btnReloadSettings.Add_Click({ Load-SettingsText; Set-Status 'Reloaded settings.txt' })

Set-Tip $btnSettingsChange 'Change the saved Open Unleashed game data folder (same as top bar)'
Set-Tip $btnOpenRoot 'Open the Pak Fixer root folder in Explorer'
Set-Tip $btnOpenPackFiles 'Open Pack Files (Broken / Disabled / Fixed / Originals) in Explorer'
Set-Tip $btnOpenTheme 'Open Settings\Theme (background image) in Explorer'
Set-Tip $btnAdvToggle 'Show or hide the raw settings.txt editor'
Set-Tip $btnSaveSettings 'Write the Advanced text box to Settings\settings.txt'
Set-Tip $btnReloadSettings 'Reload Settings\settings.txt into the Advanced editor'

function Build-SettingsRail {
  Clear-LeftRail
  [void](Add-RailHeader 'SETTINGS')
}

# ---------- shared manage helpers ----------
function Update-GameBox {
  $g = Get-Game
  if ($g) { $script:game = $g; $txtGame.Text = $g }
  else { $txtGame.Text = '(not set - click Change)' }
}

function Clear-Preview {
  if ($pic.Image) { $old = $pic.Image; $pic.Image = $null; $old.Dispose() }
  $lblNoPrev.Text = 'No preview available'
}

function Show-PreviewFor([string]$packName) {
  Clear-Preview
  $path = Find-PreviewPath $packName
  if (-not $path) { $lblNoPrev.Text = 'No preview available'; return }
  try {
    $bytes = [IO.File]::ReadAllBytes($path)
    $ms = New-Object IO.MemoryStream(,$bytes)
    $pic.Image = [System.Drawing.Image]::FromStream($ms)
    $ms.Dispose()
    $lblNoPrev.Text = $packName
  } catch {
    $lblNoPrev.Text = 'No preview available'
  }
}

function Refresh-PackList {
  $lst.BeginUpdate()
  try {
    $lst.Items.Clear()
    Clear-Preview
    Update-GameBox
    if (-not $game) {
      $lblCount.Text = '0 packs listed'
      Set-Status 'No game folder set - click Change'
      return
    }
    Set-Status 'Refreshing pack list...'
    [System.Windows.Forms.Application]::DoEvents()
    $tags = Get-Tags
    $inst = @(Installed)
    $brokenN = 0
    foreach ($p in $inst) {
      $tg = $tags[$p.Name]
      if (-not $tg) { $tg = '' }
      $item = New-Object System.Windows.Forms.ListViewItem($p.Name)
      [void]$item.SubItems.Add($tg)
      $item.Tag = $p.FullName
      if ($tg -match 'BROKEN') {
        $item.ForeColor = [System.Drawing.Color]::FromArgb(160, 30, 30)
        $brokenN++
      } elseif ($tg -match 'UNUSED') {
        $item.ForeColor = [System.Drawing.Color]::FromArgb(160, 100, 0)
      } elseif ($tg -match '^\[[0-9]') {
        $item.ForeColor = [System.Drawing.Color]::FromArgb(140, 120, 0)
      } else {
        $item.ForeColor = [System.Drawing.Color]::FromArgb(20, 120, 40)
      }
      [void]$lst.Items.Add($item)
    }
    $lblCount.Text = "$($inst.Count) packs listed"
    Set-Status ("{0} packs installed - {1} broken" -f $inst.Count, $brokenN)
  } catch {
    Set-Status ("Refresh failed: {0}" -f $_.Exception.Message)
    [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Refresh failed')
  } finally {
    $lst.EndUpdate()
  }
}

function Get-SelectedPackFiles {
  $out = @()
  foreach ($it in $lst.SelectedItems) {
    if ($it.Tag -and (Test-Path -LiteralPath ([string]$it.Tag))) {
      $out += Get-Item -LiteralPath ([string]$it.Tag)
    }
  }
  ,$out
}

$lst.Add_SelectedIndexChanged({
  if ($lst.SelectedItems.Count -eq 1) {
    Show-PreviewFor $lst.SelectedItems[0].Text
  } elseif ($lst.SelectedItems.Count -eq 0) {
    Clear-Preview
  } else {
    Clear-Preview
    $lblNoPrev.Text = ('{0} packs selected' -f $lst.SelectedItems.Count)
  }
})

$btnChange.Add_Click({ Invoke-ChangeGameFolder })

$btnRefresh.Add_Click({ Refresh-PackList })

$btnRemove.Add_Click({
  try {
    if (-not $game) { [void][System.Windows.Forms.MessageBox]::Show('Set the game folder first.'); return }
    $sel = @(Get-SelectedPackFiles)
    if (-not $sel.Count) {
      [void][System.Windows.Forms.MessageBox]::Show('Select one or more packs to remove.')
      return
    }
    if (-not (Wait-GameClosedGui)) { Set-Status 'Cancelled - game still running'; return }
    $n = 0
    foreach ($p in $sel) {
      if (Move-Safe $p $disD) {
        Set-Status "REMOVED: $($p.Name)"
        $n++
      }
    }
    Refresh-PackList
    Set-Status ("Removed {0} pack(s) to Pack Files\Disabled" -f $n)
  } catch {
    [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Remove failed')
  }
})

$btnAdd.Add_Click({
  try {
    if (-not $game) { [void][System.Windows.Forms.MessageBox]::Show('Set the game folder first.'); return }
    if (-not (Wait-GameClosedGui)) { Set-Status 'Cancelled - game still running'; return }

    $choice = [System.Windows.Forms.MessageBox]::Show(
      "Yes = pick .pak files from disk (copied into Pack Files\Disabled, then fixed and installed)`n`nNo = pick from packs already in Pack Files\Disabled`n`nCancel = abort",
      'Add packs',
      [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
      [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($choice -eq [System.Windows.Forms.DialogResult]::Cancel) { return }

    $sel = @()
    if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
      $ofd = New-Object System.Windows.Forms.OpenFileDialog
      $ofd.Filter = 'PAK packs (*.pak)|*.pak|All files (*.*)|*.*'
      $ofd.Multiselect = $true
      $ofd.Title = 'Select pack(s) to add'
      if ($ofd.ShowDialog() -ne 'OK') { return }
      foreach ($fp in $ofd.FileNames) {
        $name = Split-Path $fp -Leaf
        $dest = Join-Path $disD $name
        if (-not (Test-Path -LiteralPath $dest)) {
          Copy-Item -LiteralPath $fp -Destination $dest -Force
        }
        $sel += Get-Item -LiteralPath $dest
      }
    } else {
      $dis = @(Disabled)
      if (-not $dis.Count) {
        [void][System.Windows.Forms.MessageBox]::Show("No packs in Pack Files\Disabled.`nDrop .pak files there, or choose Yes to pick from disk.")
        return
      }
      $pickForm = New-Object System.Windows.Forms.Form
      $pickForm.Text = 'Pack Files\Disabled'
      $pickForm.Size = New-Object System.Drawing.Size(420, 480)
      $pickForm.StartPosition = 'CenterParent'
      Set-OuFormIcon $pickForm
      $clb = New-Object System.Windows.Forms.CheckedListBox
      $clb.Dock = 'Fill'
      $clb.CheckOnClick = $true
      foreach ($d in $dis) { [void]$clb.Items.Add($d.Name, $false) }
      $pickForm.Controls.Add($clb)
      $ok = New-Object System.Windows.Forms.Button
      $ok.Text = 'Add selected'
      $ok.Dock = 'Bottom'
      $ok.Height = 36
      $ok.DialogResult = 'OK'
      $pickForm.Controls.Add($ok)
      $pickForm.AcceptButton = $ok
      if ($pickForm.ShowDialog($form) -ne 'OK') { return }
      foreach ($i in $clb.CheckedIndices) { $sel += $dis[$i] }
    }

    if (-not $sel.Count) { return }
    $go = Confirm-ClashesGui $sel
    if ($go -eq 'none') { Set-Status 'Add cancelled'; return }
    if ($go -eq 'skip') { $sel = @(Filter-SkipClashes $sel) }
    $n = 0
    foreach ($p in $sel) {
      Set-Status "Fixing / adding $($p.Name)..."
      [System.Windows.Forms.Application]::DoEvents()
      $fixed = Fix-Pack $p
      if (-not $fixed) { continue }
      if (Move-Safe $fixed $game) {
        Set-Status "ADDED: $($fixed.Name)"
        $n++
      }
    }
    Refresh-PackList
    Set-Status ("Added {0} pack(s)" -f $n)
  } catch {
    [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Add failed')
  }
})

$btnFix.Add_Click({
  try {
    if (-not $game) { [void][System.Windows.Forms.MessageBox]::Show('Set the game folder first.'); return }
    $broken = @(Get-BrokenInstalled)
    if (-not $broken.Count) {
      [void][System.Windows.Forms.MessageBox]::Show('No broken packs installed.')
      Set-Status ("{0} packs installed - 0 broken" -f @(Installed).Count)
      return
    }
    $sel = @(Get-SelectedPackFiles)
    $targets = @()
    if ($sel.Count) {
      $brokenNames = @($broken | ForEach-Object { $_.Name.ToLower() })
      $targets = @($sel | Where-Object { $brokenNames -contains $_.Name.ToLower() })
      if (-not $targets.Count) {
        $r = [System.Windows.Forms.MessageBox]::Show(
          "None of the selected packs are broken.`n`nFix all $($broken.Count) broken pack(s) instead?",
          'Fix Broken',
          [System.Windows.Forms.MessageBoxButtons]::YesNo,
          [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($r -ne 'Yes') { return }
        $targets = $broken
      }
    } else {
      $r = [System.Windows.Forms.MessageBox]::Show(
        "No selection - fix all $($broken.Count) broken installed pack(s)?",
        'Fix Broken',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
      if ($r -ne 'Yes') { return }
      $targets = $broken
    }
    if (-not (Wait-GameClosedGui)) { Set-Status 'Cancelled - game still running'; return }
    $n = 0
    foreach ($p in $targets) {
      Set-Status "Fixing $($p.Name)..."
      [System.Windows.Forms.Application]::DoEvents()
      try {
        $r = Fix-Pack $p -Loud
        if ($r) { $n++ }
      } catch {
        [void][System.Windows.Forms.MessageBox]::Show("Couldn't fix $($p.Name): $($_.Exception.Message)")
      }
    }
    Refresh-PackList
    Set-Status ("Fixed {0} pack(s)" -f $n)
  } catch {
    [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Fix failed')
  }
})

# ---------- navigation ----------
$pages = @{
  'PACK MANAGER'  = $pnlFix
  'GALLERY'       = $pnlManage
  'SETTINGS'      = $pnlSettings
  'ABOUT'         = $pnlReadme
}
$script:CurrentPage = 'PACK MANAGER'

function Show-Page([string]$name) {
  if ($script:ShowroomPreloading) { return }   # Showroom Search is loading thumbs (nav is disabled meanwhile)
  # Pages and their rails are built once and kept; switching tabs only hides/shows them.
  # Data reloads only when $script:CatalogDirty / $script:ShowroomDirty say pack data changed (or a file changed on disk).
  if ($script:CurrentPage) { Save-ViewState }
  $script:CurrentPage = $name
  foreach ($k in $pages.Keys) { $pages[$k].Visible = ($k -eq $name) }
  if ($name -ne 'ABOUT') { $pnlVersion.Visible = $false }
  foreach ($k in $navButtons.Keys) {
    $nb = $navButtons[$k]
    if ($k -eq $name) { Set-OuNavSelected $nb } else { Set-OuNavIdle $nb }
  }
  switch ($name) {
    'PACK MANAGER' {
      if (-not (Switch-LeftRail 'PACK MANAGER')) { Build-FixFiltersRail }
      Attach-FixPreviewHost $fixSplit.Panel2
      Apply-SourceUI
      if ($script:CatalogDirty -or $script:CatalogBuiltSource -ne $script:CatalogSource) {
        Refresh-CatalogList -KeepShowroom
      } else {
        # Same rows, filters, checks, highlight, columns and scroll; just refresh tray/preview/status
        Update-SelectedTray
        Restore-CatalogTop
      }
    }
    'GALLERY' {
      Build-ManageRail
    }
    'SETTINGS' {
      if (-not (Switch-LeftRail 'SETTINGS')) { Build-SettingsRail }
      Update-SettingsPanelKeepEdits
      if ($script:SettingsAdvExpanded) { Load-SettingsTextIfChanged }
      if ($script:ViewState.ContainsKey('SettingsScroll')) { Set-OuScrollPos $settingsFlow $script:ViewState['SettingsScroll'] }
      Set-Status 'Settings'
    }
    'ABOUT' {
      if (Switch-LeftRail 'ABOUT') { if ($script:RailCacheExtra.ContainsKey('ABOUT')) { $script:AboutRailButtons = $script:RailCacheExtra['ABOUT'] } }
      else { Build-AboutRail }
      Show-AboutSub $script:AboutSub
    }
  }
}

foreach ($n in $navNames) {
  $navButtons[$n].Add_Click({
    param($sender, $e)
    $was = $script:CurrentPage
    Show-Page ([string]$sender.Tag)
    if ($script:CurrentPage -ne $was) { Step-OuBackground }
  })
}

$form.Add_Shown({
  Invalidate-OuGlass
  Update-GameBox
  Show-Page 'PACK MANAGER'
  Start-OuBgTimer   # idle prefetch of the next background photo
})

$form.Add_FormClosing({
  param($sender, $e)
  if ($script:ShowroomPreloading) { $e.Cancel = $true; $script:ShowroomPreloadCancel = $true; $script:ShowroomCloseAfterPreload = $true }
})

$form.Add_FormClosed({
  if ($script:ShowroomPreloadRs) { try { $script:ShowroomPreloadRs.Dispose() } catch {}; $script:ShowroomPreloadRs = $null }
  if ($script:OuBgTimer) { try { $script:OuBgTimer.Stop() } catch {} }
  if ($script:OuBgJob) { try { $script:OuBgJob.Ps.Stop(); $script:OuBgJob.Ps.Dispose() } catch {}; $script:OuBgJob = $null }
  if ($script:OuBgRs) { try { $script:OuBgRs.Dispose() } catch {}; $script:OuBgRs = $null }
  if ($script:OU3DPoll) { try { $script:OU3DPoll.Stop() } catch {} }
  if ($script:OU3DState -eq 'ready') { try { [OU3DHost]::CancelThumbs() } catch {} }
  Clear-Preview
  Clear-FixPreview
})

$form.Add_Resize({
  # Debounced: rebuild stretched bg cache + refresh glass after resize settles.
  Request-OuGlassRefresh -ForceBg
  if (-not $pnlInstalled.Visible) { return }
  $pad = 16
  $prevW = 260
  $lst.Width = [Math]::Max(200, $pnlInstalled.ClientSize.Width - $prevW - $pad * 2)
  $grpPrev.Left = $lst.Right + 12
  $grpPrev.Height = [Math]::Max(120, $lst.Height - 60)
  $btnRow.Top = $lst.Bottom + 10
  $lblCount.Top = $lst.Bottom + 4
  if ($selListHost) { $selListHost.Width = [Math]::Max(200, $selTray.ClientSize.Width - 20); Sync-SelectedListHeight }
})

function Test-ShowroomHoverLoads {
  # Test helper: fire MouseEnter/Hover/Move/Leave on every Showroom card and child; report handlers and loads triggered
  $bf = [Reflection.BindingFlags]'NonPublic,Instance'
  $sf = [Reflection.BindingFlags]'NonPublic,Static'
  $evProp = [System.ComponentModel.Component].GetProperty('Events', $bf)
  $keys = @(foreach ($n in 'EventMouseEnter','EventMouseHover','EventMouseMove','EventMouseLeave') { [System.Windows.Forms.Control].GetField($n, $sf).GetValue($null) })
  $mEnter = [System.Windows.Forms.Control].GetMethod('OnMouseEnter', $bf)
  $mHover = [System.Windows.Forms.Control].GetMethod('OnMouseHover', $bf)
  $mMove = [System.Windows.Forms.Control].GetMethod('OnMouseMove', $bf)
  $mLeave = [System.Windows.Forms.Control].GetMethod('OnMouseLeave', $bf)
  $st = $script:ShowroomLoadStats
  $before = "{0}|{1}|{2}|{3}" -f $st.UiDecode, $st.UiRead, $st.Req3D, $st.Preloads
  $q0 = $(try { if ('OU3DHost' -as [type]) { [OU3DHost]::QueueLength } else { 0 } } catch { 0 })
  $handlers = 0; $withImg = 0; $cards = 0
  $meaArgs = [object[]]::new(1); $meaArgs[0] = [System.Windows.Forms.MouseEventArgs]::new([System.Windows.Forms.MouseButtons]::None, 0, 10, 10, 0)
  $evArgs = [object[]]::new(1); $evArgs[0] = [EventArgs]::Empty
  $sw = [Diagnostics.Stopwatch]::StartNew()
  foreach ($card in @($showCardFlow.Controls)) {
    $cards++
    $all = @($card) + @($card.Controls)
    foreach ($c in $all) {
      $ev = $evProp.GetValue($c)
      foreach ($k in $keys) { if ($ev[$k]) { $handlers++ } }
      if ($c -is [System.Windows.Forms.PictureBox] -and $c.Image) { $withImg++ }
      $mEnter.Invoke($c, $evArgs)
      $mHover.Invoke($c, $evArgs)
      $mMove.Invoke($c, $meaArgs)
      $mLeave.Invoke($c, $evArgs)
    }
  }
  [System.Windows.Forms.Application]::DoEvents()
  $after = "{0}|{1}|{2}|{3}" -f $st.UiDecode, $st.UiRead, $st.Req3D, $st.Preloads
  $q1 = $(try { if ('OU3DHost' -as [type]) { [OU3DHost]::QueueLength } else { 0 } } catch { 0 })
  [pscustomobject]@{ Cards = $cards; WithImage = $withImg; Handlers = $handlers; Loads = $(if ($before -eq $after) { 0 } else { "$before->$after" }); Queue = "$q0->$q1"; Ms = $sw.ElapsedMilliseconds }
}

function Get-RowButtonTexts([System.Windows.Forms.TableLayoutPanel]$table) {
  $names = @()
  foreach ($c in $table.Controls) { if ($c -is [System.Windows.Forms.Button]) { $t = [string]$c.Text; if (-not $t) { $t = [string]$c.AccessibleName }; $names += $t } }
  return ($names -join ' | ')
}

if ($SmokeTest) {
  # ShowroomEagerThumbs = true: Search preloads all card thumbs (no hover loading)
  Update-GameBox
  Show-Page 'PACK MANAGER'
  $brokenN = @(Get-ChildItem -LiteralPath $brokenDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ieq '.pak' }).Count
  Write-Output ("SMOKE nav={0} catalogItems={1} brokenFiles={2} runEnabled={3} checked={4} status={5} source={6}" -f $navButtons.Count, $lstCatalog.Items.Count, $brokenN, $btnRunFixer.Enabled, $script:CheckedNames.Count, $statusLabel.Text, $script:CatalogSource)
  Write-Output ("SMOKE default source={0} bottomRow=[{1}] title={2} subtitleGone={3} manageBarGone={4} fixTopH={5}" -f $script:CatalogSource, (Get-RowButtonTexts $fixBtnRow), $lblFixTitle.Text, (-not (Get-Variable lblFixSub -ErrorAction SilentlyContinue)), (-not (Get-Variable manageBar -ErrorAction SilentlyContinue)), $fixTop.Height)
  # Filters shouldn't throw
  if ($script:FixFilterControls) {
    $script:FixFilterControls.Cat.SelectedIndex = [Math]::Min(1, $script:FixFilterControls.Cat.Items.Count - 1)
    Refresh-CatalogList
    $script:FixFilterControls.Cat.SelectedIndex = 0
    Refresh-CatalogList
  }
  # Source toggle smoke
  foreach ($src in @('Installed','Disabled','Broken')) {
    $script:CatalogSource = $src
    $script:CheckedNames.Clear()
    Apply-SourceUI
    Refresh-CatalogList
    Write-Output ("SMOKE source={0} items={1} bottomRow=[{2}] en: fixSel={3} addDisk={4} install={5} rem={6} open={7} refresh={8}" -f $src, $lstCatalog.Items.Count, (Get-RowButtonTexts $fixBtnRow), $btnFixSelected.Enabled, $btnMgrAddDisk.Enabled, $btnMgrAdd.Enabled, $btnMgrRemove.Enabled, $btnPmOpen.Enabled, $btnRefreshBroken.Enabled)
  }
  # Enable-rule smoke with a fake selection
  $script:CatalogSource = 'Installed'; $script:CheckedNames.Clear(); [void]$script:CheckedNames.Add('dummy.pak'); Apply-SourceUI
  Write-Output ("SMOKE enable Installed+sel rem={0} fix={1} addDisk={2}" -f $btnMgrRemove.Enabled, $btnMgrFix.Enabled, $btnMgrAddDisk.Enabled)
  $script:CatalogSource = 'Disabled'; Apply-SourceUI
  Write-Output ("SMOKE enable Disabled+sel add={0}" -f $btnMgrAdd.Enabled)
  $script:CatalogSource = 'Broken'; Apply-SourceUI
  Write-Output ("SMOKE enable Broken+sel run={0}" -f $btnRunFixer.Enabled)
  # PACK MANAGER declutter: header checkbox, Open menu, More filters, F5, source segment
  $script:CatalogSource = 'Installed'; $script:CheckedNames.Clear(); Apply-SourceUI; Refresh-CatalogList
  $hcs = @(Get-CatalogHeaderCheckState)
  Toggle-CatalogVisibleChecks; $hcs += Get-CatalogHeaderCheckState; $hcAll = @(Get-CheckedNames).Count
  if ($lstCatalog.Items.Count -gt 1) { $lstCatalog.Items[0].Checked = $false }
  $hcs += Get-CatalogHeaderCheckState
  Toggle-CatalogVisibleChecks; $hcs += Get-CatalogHeaderCheckState
  Toggle-CatalogVisibleChecks; $hcs += Get-CatalogHeaderCheckState
  Write-Output ("SMOKE headerCheck items={0} states={1} checkedAfterAll={2} after={3}" -f $lstCatalog.Items.Count, ($hcs -join '>'), $hcAll, $script:CheckedNames.Count)
  $miT = @(); foreach ($mi in $script:PmOpenMenu.Items) { if ($mi -is [System.Windows.Forms.ToolStripMenuItem]) { $miT += $mi.Text } }
  Write-Output ("SMOKE openMenu items=[{0}] darkRenderer={1} back={2}" -f ($miT -join ' | '), ($script:PmOpenMenu.Renderer -is [System.Windows.Forms.ToolStripProfessionalRenderer] -and ('OuDarkMenuColors' -as [type]) -ne $null), $script:PmOpenMenu.BackColor.ToArgb())
  Write-Output ("SMOKE openTargets game={0} broken={1} disabled={2} fixed={3} orig={4} list={5}" -f ((Get-PmOpenTarget 'Game') -eq $game), ((Get-PmOpenTarget 'Broken') -eq $brokenDir), ((Get-PmOpenTarget 'Disabled') -eq $disabledDir), ((Get-PmOpenTarget 'Fixed') -eq $fixedDir), ((Get-PmOpenTarget 'Originals') -eq $origDir), ((Get-PmOpenTarget 'List') -eq $listTxt))
  $fcM = $script:FixFilterControls
  $m0 = $script:PmMoreFiltersOpen; $t0 = $fcM.More.Text; Toggle-PmMoreFilters; $m1 = $script:PmMoreFiltersOpen; $t1 = $fcM.More.Text; Toggle-PmMoreFilters
  Write-Output ("SMOKE moreFilters collapsedAtStart={0} '{1}' -> open={2} '{3}' -> back={4} inPanel={5} soloText='{6}' searchVisible={7} catVisible={8}" -f (-not $m0), $t0, $m1, $t1, (-not $script:PmMoreFiltersOpen), ($fcM.Sub.Parent -eq $fcM.MorePanel -and $fcM.Solo.Parent -eq $fcM.MorePanel -and $fcM.Sort.Parent -eq $fcM.MorePanel), $fcM.Solo.Text, ($fcM.Search.Parent -ne $fcM.MorePanel), ($fcM.Cat.Parent -ne $fcM.MorePanel))
  $sc0 = [int]$script:CatalogScanCount; $f5 = Invoke-PmKey ([System.Windows.Forms.Keys]::F5); $sc1 = [int]$script:CatalogScanCount; $f6 = Invoke-PmKey ([System.Windows.Forms.Keys]::F6)
  Write-Output ("SMOKE f5 handled={0} scans={1}->{2} otherKeyIgnored={3} keyPreview={4} refreshTip='{5}' refreshIcon={6}" -f $f5, $sc0, $sc1, (-not $f6), $form.KeyPreview, $script:UiToolTip.GetToolTip($btnRefreshBroken), [bool]$btnRefreshBroken.Image)
  $sw = @(); foreach ($k in @('Installed','Broken','Disabled')) { $sw += $script:SourceButtons[$k].Width }
  $sy = @(); foreach ($k in @('Installed','Broken','Disabled')) { $sy += $script:SourceButtons[$k].Top }
  Write-Output ("SMOKE srcSeg widths={0} tops={1} oneRow={2} prevMore={3} prevMoreItems={4}" -f ($sw -join '/'), ($sy -join '/'), (@($sy | Select-Object -Unique).Count -eq 1), [bool]$btnFixDelPrev.Image, (@($script:PrevMoreMenu.Items | ForEach-Object { $_.Text }) -join '|'))
  # Checked collector flat FileInfos + highlight must not clear checks
  $script:CheckedNames.Clear()
  $takeNames = @($script:CatalogRows | Select-Object -First 3 | ForEach-Object { $_.Name })
  foreach ($tn in $takeNames) { if ($tn) { [void]$script:CheckedNames.Add($tn) } }
  $picked = @(Get-CheckedCatalogFiles)
  $flatOk = $true
  foreach ($pf in $picked) { if ($pf -is [System.Array]) { $flatOk = $false } }
  Write-Output ("SMOKE checkFlat want={0} count={1} flatOk={2} type0={3} checkBoxes={4}" -f $takeNames.Count, $picked.Count, $flatOk, $(if ($picked.Count) { $picked[0].GetType().Name } else { 'none' }), $lstCatalog.CheckBoxes)
  Write-Output ("SMOKE catalogCols={0}" -f (($lstCatalog.Columns | ForEach-Object { $_.Text }) -join '|'))
  $stParts = @()
  foreach ($g in @($script:CatalogRows | Group-Object Status)) { $stParts += ("{0}={1}" -f $g.Name, $g.Count) }
  Write-Output ("SMOKE statusCounts={0}" -f ($stParts -join "; "))
  # Clashes filter smoke (Status column Clash only; AND with other filters)
  if ($script:FixFilterControls -and $script:FixFilterControls.ContainsKey('Clashes')) {
    $script:CatalogSource = 'Installed'
    $script:CheckedNames.Clear()
    Apply-SourceUI
    $script:SuppressFilter = $true
    try {
      $script:FixFilterControls.HasPrev.Checked = $false
      $script:FixFilterControls.Solo.Checked = $false
      $script:FixFilterControls.Clashes.Checked = $false
      if ($script:FixFilterControls.Cat.Items.Count) { $script:FixFilterControls.Cat.SelectedIndex = 0 }
      $script:FixFilterControls.Search.Text = ''
    } finally { $script:SuppressFilter = $false }
    Refresh-CatalogList
    $allN = $lstCatalog.Items.Count
    $clashRowN = @($script:CatalogRows | Where-Object { $_.Status -eq 'Clash' }).Count
    $script:FixFilterControls.Clashes.Checked = $true
    Refresh-CatalogList
    $onN = $lstCatalog.Items.Count
    $allClash = $true
    foreach ($it in $lstCatalog.Items) {
      if ($it.SubItems.Count -gt 1 -and $it.SubItems[1].Text -ne 'Clash') { $allClash = $false; break }
    }
    $script:FixFilterControls.Clashes.Checked = $false
    Refresh-CatalogList
    $offN = $lstCatalog.Items.Count
    Write-Output ("SMOKE clashesFilter exists={0} text={1} all={2} clashRows={3} on={4} off={5} onlyClash={6} restored={7}" -f $true, $script:FixFilterControls.Clashes.Text, $allN, $clashRowN, $onN, $offN, $allClash, ($offN -eq $allN))
  } else {
    Write-Output "SMOKE clashesFilter exists=False"
  }
  # Simulate highlight change: should not wipe CheckedNames
  $before = $script:CheckedNames.Count
  $script:SuppressCheck = $true
  try { if ($lstCatalog.Items.Count) { $lstCatalog.Items[0].Selected = $true } } finally { $script:SuppressCheck = $false }
  Update-FixPreview
  Write-Output ("SMOKE highlightKeepsChecks before={0} after={1}" -f $before, $script:CheckedNames.Count)
  $script:CheckedNames.Clear()
  $script:CheckedNames.Clear(); Apply-SourceUI
  if ($lstCatalog.Items.Count) { $script:SuppressCheck = $true; try { $lstCatalog.Items[0].Checked = $true; if ($lstCatalog.Items.Count -gt 1) { $lstCatalog.Items[1].Checked = $true }; $lstCatalog.Items[0].Selected = $true } finally { $script:SuppressCheck = $false }; Sync-CheckedNamesFromList; Update-SelectedTray; $btnFixPrevNext.PerformClick() }
  Write-Output ("SMOKE preview pos='{0}' msg='{1}' img={2} makeEnabled={3}" -f $lblFixPrevPos.Text, $lblFixPrevMsg.Text, [bool]$picFix.Image, $btnFixMakePrev.Enabled)
  Write-Output ("SMOKE prevLayout bottomDock={0} btnFill={1} navCols={2} nameWhite={3} backFill={4} nextFill={5}" -f $fixPrevBottom.Dock, $fixPrevBtnRow.Dock, $fixPrevNav.ColumnCount, ($lblFixPrevPos.ForeColor.ToArgb() -eq $script:Theme.Text.ToArgb()), $btnFixPrevBack.Dock, $btnFixPrevNext.Dock)
  Write-Output ("SMOKE prevGlass outerHeavy={0} innerPreview={1} picBgImg={2} picBack={3}" -f $script:Theme.GlassAlphaHeavy, $script:Theme.GlassAlphaPreview, [bool]$picFix.BackgroundImage, $picFix.BackColor.Name)
  Write-Output ("SMOKE prevBottom rows={0} btnDock={1} order=Make>More>FS left={2}<{3}<{4}" -f $fixPrevBottom.RowCount, $fixPrevBtnRow.Dock, $btnFixMakePrev.Left, $btnFixDelPrev.Left, $btnFixFullScreen.Left)
  $pTop=$fixPrevPanel.PointToClient($fixPrevBtnRow.Parent.PointToScreen($fixPrevBtnRow.Location)).Y; $nTop=$fixPrevPanel.PointToClient($fixPrevNav.Parent.PointToScreen($fixPrevNav.Location)).Y; $lTop=$fixPrevPanel.PointToClient($lblFixPrevPos.Parent.PointToScreen($lblFixPrevPos.Location)).Y; Write-Output ("SMOKE prevLayout titleY={0} picY={1} btnRowY={2} posY={3} navY={4} bottomH={5}" -f $lblFixPrevTitle.Top, $picFix.Top, $pTop, $lTop, $nTop, $fixPrevBottom.Height)
  $pTop=$fixPrevPanel.PointToClient($fixPrevBtnRow.Parent.PointToScreen($fixPrevBtnRow.Location)).Y; $nTop=$fixPrevPanel.PointToClient($fixPrevNav.Parent.PointToScreen($fixPrevNav.Location)).Y; $lTop=$fixPrevPanel.PointToClient($lblFixPrevPos.Parent.PointToScreen($lblFixPrevPos.Location)).Y; Write-Output ("SMOKE prevOrderOK={0}" -f ($lblFixPrevTitle.Top -lt $picFix.Top -and $picFix.Top -lt $pTop -and $pTop -lt $lTop -and $lTop -lt $nTop -and $btnFixMakePrev.Left -lt $btnFixDelPrev.Left -and $btnFixDelPrev.Left -lt $btnFixFullScreen.Left))
  $names = @('top','navBar','leftRail','lstCatalog','picFix','fixPrevPanel','fixTop','selTray','fixBtnChrome','selListHost')
  $map = @{}
  foreach ($gc in $script:OuGlassHooked) { if ($gc.Name) { $map[$gc.Name] = $(if ($script:OuGlassAlpha.ContainsKey($gc)) { [int]$script:OuGlassAlpha[$gc] } else { -1 }) } }
  if ($script:OuGlassAlpha.ContainsKey($lstCatalog)) { $map['lstCatalog'] = [int]$script:OuGlassAlpha[$lstCatalog] }
  if ($script:OuGlassAlpha.ContainsKey($picFix)) { $map['picFix'] = [int]$script:OuGlassAlpha[$picFix] }
  if ($script:OuGlassAlpha.ContainsKey($selListHost)) { $map['selListHost'] = [int]$script:OuGlassAlpha[$selListHost] }
  $parts = @(); foreach ($n in $names) { $parts += ("{0}={1}" -f $n, $(if ($map.ContainsKey($n)) { $map[$n] } else { 'miss' })) }
  Write-Output ("SMOKE alphas {0} statusSolid={1}" -f ($parts -join ' '), ($status.BackColor.A -eq 255 -and $status.BackColor.ToArgb() -eq $script:Theme.PanelOpaque.ToArgb()))
  Write-Output ("SMOKE alphasOK155={0} alphasOK190={1} alphasOK238={2} selListHost={3} selTray={4} lstH={5}" -f (($map['leftRail'] -eq 155 -and $map['lstCatalog'] -eq 155 -and $map['picFix'] -eq 155 -and $map['selListHost'] -eq 155)), ($map['navBar'] -eq 190), ($map['top'] -eq 238 -and $map['fixTop'] -eq 238 -and $map['selTray'] -eq 238 -and $map['fixBtnChrome'] -eq 238 -and $map['fixPrevPanel'] -eq 238), $map['selListHost'], $map['selTray'], $lstSelected.Height)
  Write-Output ("SMOKE clearBg type={0} empty={1} isColor={2}" -f $script:OuClearBg.GetType().FullName, $script:OuClearBg.IsEmpty, ($script:OuClearBg -is [System.Drawing.Color]))
  try { $__b=New-Object Drawing.Bitmap 8,8; $__g=[Drawing.Graphics]::FromImage($__b); Draw-OuContentGlass $lstCatalog $__g (New-Object Drawing.Rectangle(0,0,8,8)) 238; $__g.Dispose(); $__b.Dispose(); Write-Output "SMOKE contentGlassClear=OK" } catch { Write-Output ("SMOKE contentGlassClear=FAIL {0}" -f $_.Exception.Message) }
  Write-Output ("SMOKE fullScreenBtn exists={0} enabled={1} hasIcon={2} textEmpty={3}" -f [bool]$btnFixFullScreen, $btnFixFullScreen.Enabled, [bool]$btnFixFullScreen.Image, [string]::IsNullOrEmpty($btnFixFullScreen.Text))
  Write-Output ("SMOKE fsIcons expandOn={0} expandOff={1} collapse={2} btnImgIsOn={3}" -f [bool]$script:FsIconExpandOn, [bool]$script:FsIconExpandOff, [bool]$script:FsIconCollapse, [object]::ReferenceEquals($btnFixFullScreen.Image, $script:FsIconExpandOn))
  Write-Output ("SMOKE fullScreenFn={0}" -f [bool](Get-Command Show-FixPreviewFullScreen -ErrorAction SilentlyContinue))
  $script:CheckedNames.Clear(); Update-SelectedTray
  Write-Output ("SMOKE filtersOK catalogItems={0} runEnabled={1}" -f $lstCatalog.Items.Count, $btnRunFixer.Enabled)
  Show-Page 'GALLERY'
  $srN = @($script:ShowroomRows).Count
  $cardN = $showCardFlow.Controls.Count
  $railNames = @($script:ManageRailButtons.Keys | Sort-Object)
  $hasPrevCtrl = [bool]($script:ShowroomFilterControls -and $script:ShowroomFilterControls.HasPrev)
  $prevParent = $(if ($fixPrevPanel.Parent) { $fixPrevPanel.Parent.Name } else { 'none' })
  Write-Output ("SMOKE showroomEmptyBeforeSearch rows={0} cards={1} hasSearched={2} eager={3} missingLbl='{4}'" -f $srN, $cardN, $script:ShowroomHasSearched, $script:ShowroomEagerThumbs, $lblShowMissing.Text)
  Write-Output ("SMOKE showroom sub={0} rows={1} cards={2} rail=[{3}] hasPrevCtrl={4} missingLbl='{5}' prevParent={6} selected={7}" -f $script:ManageSub, $srN, $cardN, ($railNames -join '|'), $hasPrevCtrl, $lblShowMissing.Text, $prevParent, $script:ShowroomSelected)
  # Search-gated: populate now
  Invoke-ShowroomSearch
  $srN = @($script:ShowroomRows).Count
  $cardN = $showCardFlow.Controls.Count
  Write-Output ("SMOKE showroomAfterSearch rows={0} cards={1} hasSearched={2}" -f $srN, $cardN, $script:ShowroomHasSearched)
  $ci = Test-ShowroomCardImages; $ps0 = Get-ShowroomPreviewState
  $first0 = $(if ($showCardFlow.Controls.Count) { [string]$showCardFlow.Controls[0].Tag } else { '' })
  Write-Output ("SMOKE showroomAutoLoad cards={0} noImage={1} noImageNoTexture={2} previewAfterSearch=[sel='{3}' firstCard={4} img={5} live3D={6}]" -f $ci.Cards, $ci.NoImage, $ci.NoImageNoTexture, $ps0.Selected, ($ps0.Selected -and $ps0.Selected -eq $first0), $ps0.Img, $ps0.Live3D)
  $cl = Test-ShowroomClickLoads 3
  $ps1 = Get-ShowroomPreviewState
  $mi = [System.Windows.Forms.Control].GetMethod('OnClick', [Reflection.BindingFlags]'Instance,NonPublic')
  if ($ps1.Selected -and $script:ShowroomCardMap[$ps1.Selected]) { foreach ($c in $script:ShowroomCardMap[$ps1.Selected].Controls) { if ($c -is [System.Windows.Forms.PictureBox]) { $a = [object[]]::new(1); $a[0] = [EventArgs]::Empty; [void]$mi.Invoke($c, $a); break } } }
  $ps2 = Get-ShowroomPreviewState
  Write-Output ("SMOKE showroomClick clicked={0} cardImagesChanged={1} thumbKeysAdded={2} req3d={3} queue={4} previewShown={5} afterReclick=[sel='{6}' img={7} live3D={8}]" -f $cl.Clicked, $cl.CardImagesChanged, $cl.ThumbKeysAdded, $cl.Req3D, $cl.Queue, $cl.PreviewShownOnClick, $ps2.Selected, $ps2.Img, $ps2.Live3D)
  # checkbox click selects + previews that card; unchecking leaves the preview
  $cbRes = Test-ShowroomCheckboxPreview
  Write-Output ("SMOKE showroomCheckbox key={0} checkedSelects={1} img={2} live3D={3} uncheckKeeps={4} restoredChecks={5}" -f $cbRes.Key, $cbRes.Selects, $cbRes.Img, $cbRes.Live3D, $cbRes.UncheckKeeps, $cbRes.Restored)
  $hv = Test-ShowroomHoverLoads
  $pl = $script:ShowroomLastPreload
  Write-Output ("SMOKE showroomPreload ms={0} flat={1} side3d={2} rendered={3} errors={4} engine={5} cardsWithImage={6}/{7} hoverHandlers={8} hoverLoads={9}" -f $pl.Ms, $pl.Flat, $pl.Side, $pl.Rendered, $pl.Errors, $pl.Engine3D, $hv.WithImage, $hv.Cards, $hv.Handlers, $hv.Loads)
  $sfc = $script:ShowroomFilterControls
  $want = @('Cat','Sub','Cls','Sort','Search','HasPrev','Clashes','Solo','SearchBtn','ClearBtn','MoreBtn','MakeMiss','Reload')
  $have = @(); foreach ($k in $want) { if ($sfc -and $sfc.ContainsKey($k) -and $sfc[$k]) { $have += $k } }
  $srcToggle = [bool]($leftRail.Controls | ForEach-Object { $_.Controls } | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Text -in @('Broken','Disabled') })
  $filterPanel = $null; foreach ($c in $leftRail.Controls) { if ($c.Name -eq 'showroomFilterPanel') { $filterPanel = $c; break } }
  $navHost = $null; foreach ($c in $leftRail.Controls) { if ($c.Name -eq 'galleryNavHost') { $navHost = $c; break } }
  Write-Output ("SMOKE showroomFilters keys=[{0}] want={1} have={2} srcToggle={3} panelH={4} panelVis={5} lockLbl={6} navH={7} leftChildren={8}" -f ($have -join '|'), $want.Count, $have.Count, $srcToggle, $(if ($filterPanel) { $filterPanel.Height } else { -1 }), $(if ($filterPanel) { $filterPanel.Visible } else { $false }), [bool]($filterPanel -and ($filterPanel.Controls | Where-Object { $_.Text -like 'Source: Installed*' })), $(if ($navHost) { $navHost.Height } else { -1 }), $leftRail.Controls.Count)
  # Custom Packs (renamed from Loadouts): Filter header only on Showroom; teaser panel on Custom Packs.
  # Own Visible flag (form is hidden during smoke, so .Visible reads False through parents)
  $__cpGetState = [System.Windows.Forms.Control].GetMethod('GetState', [System.Reflection.BindingFlags]'NonPublic, Instance')
  $__cpOwnVis = { param($c) if (-not $c) { 'none' } else { [bool]$__cpGetState.Invoke($c, @([int]2)) } }
  $__cpFindHdr = { $h = $null; foreach ($c in $leftRail.Controls) { if ($c.Name -eq 'galleryNavHost') { foreach ($k in $c.Controls) { if ($k.Name -eq 'galleryFilterHdr') { $h = $k } } } }; $h }
  $__cpHdrShow = & $__cpFindHdr
  Build-ManageRailForSub 'Custom Packs'
  [System.Windows.Forms.Application]::DoEvents()
  $__cpHdr = & $__cpFindHdr
  $__cpNav = $null; foreach ($c in $leftRail.Controls) { if ($c.Name -eq 'galleryNavHost') { $__cpNav = $c } }
  $__cpFilterVis = $false; foreach ($c in $leftRail.Controls) { if ($c.Name -eq 'showroomFilterPanel' -and (& $__cpOwnVis $c)) { $__cpFilterVis = $true } }
  $__cpBtns = @($script:ManageRailButtons.Keys | Sort-Object) -join '|'
  $__cpOverflow = 0; foreach ($k in $pnlCustomPacks.Controls) { if ($k.Right -gt $pnlCustomPacks.ClientSize.Width -or $k.Bottom -gt $pnlCustomPacks.ClientSize.Height -or $k.Left -lt 0 -or $k.Top -lt 0) { $__cpOverflow++ } }
  Write-Output ("SMOKE customPacks sub='{0}' panelVis={1} showroomVis={2} title='{3}' tag='{4}' bullets={5} status='{6}' hdrVisible={7} navH={8} filterPanelVis={9} rail=[{10}] overflow={11} client={12}x{13} hasLoadoutsText={14}" -f $script:ManageSub, (& $__cpOwnVis $pnlCustomPacks), (& $__cpOwnVis $pnlShowroom), $script:CustomPacksCtl.Title.Text, $script:CustomPacksCtl.Tag.Text, $script:CustomPacksCtl.Bullets.Count, $statusLabel.Text, (& $__cpOwnVis $__cpHdr), $(if ($__cpNav) { $__cpNav.Height } else { -1 }), $__cpFilterVis, $__cpBtns, $__cpOverflow, $pnlCustomPacks.ClientSize.Width, $pnlCustomPacks.ClientSize.Height, [bool]($statusLabel.Text -match 'Loadouts'))
  Build-ManageRailForSub 'Showroom'
  [System.Windows.Forms.Application]::DoEvents()
  $__cpHdr2 = & $__cpFindHdr
  Write-Output ("SMOKE customPacksBack sub='{0}' showroomVis={1} customVis={2} hdrVisibleBefore={3} hdrVisibleAfter={4}" -f $script:ManageSub, (& $__cpOwnVis $pnlShowroom), (& $__cpOwnVis $pnlCustomPacks), (& $__cpOwnVis $__cpHdrShow), (& $__cpOwnVis $__cpHdr2))
  if ($script:ShowroomFilterControls -and $script:ShowroomFilterControls.HasPrev) {
    $before = $showCardFlow.Controls.Count
    $script:SuppressShowroom = $true
    try { $script:ShowroomFilterControls.HasPrev.Checked = $true } finally { $script:SuppressShowroom = $false }
    Refresh-ShowroomGrid
    $on = $showCardFlow.Controls.Count
    $script:SuppressShowroom = $true
    try { $script:ShowroomFilterControls.HasPrev.Checked = $false } finally { $script:SuppressShowroom = $false }
    Refresh-ShowroomGrid
    $off = $showCardFlow.Controls.Count
    Write-Output ("SMOKE showroomHasPrev before={0} on={1} off={2} restored={3}" -f $before, $on, $off, ($off -eq $before))
  }
  $packN = @($script:ShowroomRows | Select-Object -ExpandProperty PackFile -Unique).Count
  $bikeN = @($script:ShowroomRows | Where-Object Kind -eq 'bike').Count
  $gearN = @($script:ShowroomRows | Where-Object Kind -eq 'gear').Count
  $thumbN = @($script:ShowroomRows | Where-Object HasPreview).Count
  Write-Output ("SMOKE showroomItems packs={0} items={1} bike={2} gear={3} hasThumb={4} cards={5}" -f $packN, $srN, $bikeN, $gearN, $thumbN, $cardN)
  $helmetTitles = @($script:ShowroomRows | Where-Object { $_.DisplayName -match 'Helmet' -or (@($_.Parts) -contains 'Helmet') } | Select-Object -ExpandProperty DisplayName -Unique)
  $goggleTitles = @($script:ShowroomRows | Where-Object { $_.DisplayName -match 'Goggle' -or (@($_.Parts) -contains 'Goggles') } | Select-Object -ExpandProperty DisplayName -Unique)
  $sampleTitles = @($script:ShowroomRows | Sort-Object DisplayName | Select-Object -First 6 | ForEach-Object { $_.DisplayName })
  Write-Output ("SMOKE showroomTitles sample=[{0}]" -f ($sampleTitles -join ' | '))
  Write-Output ("SMOKE showroomHelmetGoggle helmets={0} goggles={1} titles=[{2}]" -f $helmetTitles.Count, $goggleTitles.Count, ((@($helmetTitles + $goggleTitles) | Select-Object -First 8) -join ' | '))
  if ($showCardFlow.Controls.Count -gt 0) {
    $firstKey = [string]$showCardFlow.Controls[0].Tag
    Select-ShowroomPack $firstKey
    $selRow = Find-ShowroomRowByKey $script:ShowroomSelected
    $title = if ($selRow) { $selRow.DisplayName } else { $script:ShowroomSelected }
    $cardThumb = $false
    foreach ($ctl in $showCardFlow.Controls[0].Controls) {
      if ($ctl -is [System.Windows.Forms.PictureBox] -and $ctl.Image) { $cardThumb = $true; break }
    }
    Write-Output ("SMOKE showroomSelect key={0} title={1} prevImg={2} cardThumb={3} msg='{4}'" -f $script:ShowroomSelected, $title, [bool]$picFix.Image, $cardThumb, $lblFixPrevMsg.Text)
    # 3D: lazy compile (started by Search), live view on a bike item with a stock model, cached side/stack PNGs
    $sw3 = [Diagnostics.Stopwatch]::StartNew(); $ready3d = Test-OU3DReady -Wait; $waitMs = $sw3.ElapsedMilliseconds
    $slotRows = @($script:ShowroomRows | Where-Object { $_.Slot3D })
    $bikeRow = @($slotRows | Where-Object { Test-Row3D $_ } | Select-Object -First 1)[0]
    $liveTok = ''; $sideOk = $false; $rMs = -1; $sceneMs = -1
    if ($bikeRow) {
      Select-ShowroomPack $bikeRow.ItemKey
      $liveTok = $script:Live3DToken
      $sw3.Restart(); [void][OU3DHost]::Scene($bikeRow.PackPath, $bikeRow.Slot3D); $sceneMs = $sw3.ElapsedMilliseconds
      $sw3.Restart(); [void][OU3DHost]::EnsurePreviews($bikeRow.PackPath, $bikeRow.Slot3D, $false); $rMs = $sw3.ElapsedMilliseconds
      $sideOk = (Test-Path -LiteralPath ([OU3DHost]::SidePath($bikeRow.PackPath, $bikeRow.Slot3D))) -and (Test-Path -LiteralPath ([OU3DHost]::StackPath($bikeRow.PackPath, $bikeRow.Slot3D)))
    }
    Write-Output ("SMOKE 3d state={0} err='{1}' waitMs={2} slotRows={3} item={4} liveToken={5} sceneMs={6} previewMs={7} pngs={8}" -f $script:OU3DState, $script:OU3DError, $waitMs, $slotRows.Count, $(if ($bikeRow) { $bikeRow.Slot3D } else { '-' }), [bool]$liveTok, $sceneMs, $rMs, $sideOk)
    # Rider number toggle: flip off and on through the same handler the checkboxes use; restore the saved state after
    $togStart = [bool](Get-OURiderOverride).ShowNumbers
    Write-Output ("SMOKE numToggle start={0} railChk={1} cardChk={2} railText='{3}' hostShow={4} disp='{5}' rider='{6}'" -f $togStart, $(if ($script:ShowroomNumberCheck) { $script:ShowroomNumberCheck.Checked } else { 'none' }), $chkRiderShow.Checked, $(if ($script:ShowroomNumberCheck) { $script:ShowroomNumberCheck.Text } else { '' }), [OU3DHost]::ShowNumber, [OU3DHost]::DisplayNumber, [OU3DHost]::RiderNumber)
    if ($bikeRow) {
      foreach ($st in @((-not $togStart), $togStart)) {
        $sw3.Restart(); Invoke-RiderShowToggle $st; $togMs = $sw3.ElapsedMilliseconds
        $liveNum = $(if ($script:Live3D -and $script:Live3D.Scene) { 'view:' + $script:Live3D.Scene.RiderNumber } else { 'cached:' + [OU3DHost]::Scene($bikeRow.PackPath, $bikeRow.Slot3D).RiderNumber })   # live/fullscreen views share the cached scene
        $sw3.Restart(); [void][OU3DHost]::EnsurePreviews($bikeRow.PackPath, $bikeRow.Slot3D, $false, $st); $eMs = $sw3.ElapsedMilliseconds
        $tp = [OU3DHost]::SidePath($bikeRow.PackPath, $bikeRow.Slot3D, $st)
        Write-Output ("SMOKE numToggle set={0} toggleMs={1} hostShow={2} disp='{3}' liveScene='{4}' railChk={5} cardChk={6} saved={7} thumbFresh={8} thumbMs={9} thumbFile={10}" -f $st, $togMs, [OU3DHost]::ShowNumber, [OU3DHost]::DisplayNumber, $liveNum, $(if ($script:ShowroomNumberCheck) { $script:ShowroomNumberCheck.Checked } else { 'none' }), $chkRiderShow.Checked, (Get-OURiderOverride).ShowNumbers, [OU3DHost]::ThumbFresh($bikeRow.PackPath, $bikeRow.Slot3D), $eMs, ($tp.Substring($prevD.Length)))
      }
      Write-Output ("SMOKE numToggle makeAlwaysNumbered mainFresh={0} mainFile={1}" -f [OU3DHost]::IsFresh($bikeRow.PackPath, $bikeRow.Slot3D), ([OU3DHost]::StackPath($bikeRow.PackPath, $bikeRow.Slot3D)).Substring($prevD.Length))
      # Bar pad: save value -> host -> scenes/live view; only that pad drawn (no override toggling here: it would re-render the user's previews)
      $bpR = Get-OURider -NoCacheWrite; $bpSc = [OU3DHost]::Scene($bikeRow.PackPath, $bikeRow.Slot3D)
      $bpView = $(if ($script:Live3D -and $script:Live3D.Scene) { 'fat=' + $script:Live3D.Scene.FatBar + ',hg=' + $script:Live3D.Scene.HandGuards } else { 'none' })
      Write-Output ("SMOKE barPad rider={0} src='{1}' hg={2} hgSrc='{3}' hostFat={4} hostHg={5} sceneFat={6} sceneHg={7} view={8} modelFat={9} modelCross={10} modelHg={11} label='{12}' override='{13}' stamp={14}" -f $bpR.BarPad, $bpR.BarPadSource, $bpR.HandGuards, $bpR.HandGuardsSource, [OU3DHost]::FatBar, [OU3DHost]::HandGuards, $bpSc.FatBar, $bpSc.HandGuards, $bpView, $bpSc.Model.HasFatBar, $bpSc.Model.HasCrossbar, $bpSc.Model.HasHandGuards, (Get-OUBarPadText), $script:BarPadOverride, (Test-Path -LiteralPath ([OU3DHost]::PartsStampPath)))
      # Rider preview controls (Showroom rail + SETTINGS card). Sandboxed: temp rider.txt + temp PreviewDir, so the user's
      # running app, Settings\rider.txt and cached previews are untouched; restored in finally.
      $rcCfg0 = $script:RiderCfg; $rcPrev0 = [OU3DHost]::PreviewDir; $rcAsked0 = @($script:Showroom3DAsked)
      $rcStampT0 = @(foreach ($sp in @([OU3DHost]::StampPath, [OU3DHost]::PartsStampPath)) { if (Test-Path -LiteralPath $sp) { (Get-Item -LiteralPath $sp).LastWriteTimeUtc.Ticks } else { 0 } }) -join ','
      $rcCfgT0 = $(if (Test-Path -LiteralPath $rcCfg0) { (Get-Item -LiteralPath $rcCfg0).LastWriteTimeUtc.Ticks } else { 0 })
      $rcTmp = Join-Path $env:TEMP ('ou_ridercontrols_smoke_' + $PID)
      New-Item -ItemType Directory -Force -Path $rcTmp | Out-Null
      try {
        if (Test-Path -LiteralPath $rcCfg0) { Copy-Item -LiteralPath $rcCfg0 (Join-Path $rcTmp 'rider.txt') -Force }
        $script:RiderCfg = Join-Path $rcTmp 'rider.txt'; [OU3DHost]::PreviewDir = (Join-Path $rcTmp 'Previews')
        $script:Showroom3DAsked.Clear()
        Update-RiderCard
        $rcS = @($script:RiderCtlSets | Where-Object { $_.Prefix -eq 'Showroom' -and -not $_.Show.IsDisposed })[0]
        $rcT = @($script:RiderCtlSets | Where-Object { $_.Prefix -eq 'Settings' })[0]
        $rcFmt = { param($s) if (-not $s) { return 'none' }; "show={0} num='{1}' cue='{2}' max={3} hg={4} round={5} cross={6}" -f $s.Show.Checked, $s.Num.Text, (Get-OuCueBanner $s.Num), $s.Num.MaxLength, $s.HG.Checked, $s.Round.Checked, $s.Cross.Checked }
        Write-Output ("SMOKE riderCtl start rail=[{0}] settings=[{1}] sets={2} railShowIsShowroomCheck={3} settingsShowIsChkRiderShow={4}" -f (& $rcFmt $rcS), (& $rcFmt $rcT), $script:RiderCtlSets.Count, ($rcS.Show -eq $script:ShowroomNumberCheck), ($rcT.Show -eq $chkRiderShow))
        # Custom number typed on the rail (junk stripped -> digits), committed the way Enter / leave do
        $rcS.Num.Text = '4x2'; $rcSan = $rcS.Num.Text
        $sw3.Restart(); Invoke-RiderNumberCommit $rcS.Num; $rcNMs = $sw3.ElapsedMilliseconds
        Write-Output ("SMOKE riderCtl number sanitized='{0}' commitMs={1} file={2} hostNum='{3}' disp='{4}' settingsNum='{5}' scene='{6}' liveView='{7}'" -f $rcSan, $rcNMs, (Get-OURiderOverride).Number, [OU3DHost]::RiderNumber, [OU3DHost]::DisplayNumber, $rcT.Num.Text, [OU3DHost]::Scene($bikeRow.PackPath, $bikeRow.Slot3D).RiderNumber, $(if ($script:Live3D -and $script:Live3D.Scene) { $script:Live3D.Scene.RiderNumber } else { 'none' }))
        $rcS.Num.Text = '1234'; $rcLen = $rcS.Num.Text; $rcS.Num.Text = '42'
        # Hand guards off + crossbar from the SETTINGS card; rail follows; the only checked pad can't be unchecked
        $sw3.Restart(); $rcT.HG.Checked = $false; $rcT.Cross.Checked = $true; $rcPMs = $sw3.ElapsedMilliseconds
        $rcS.Cross.Checked = $false
        $rcOv = Get-OURiderOverride; $rcSc = [OU3DHost]::Scene($bikeRow.PackPath, $bikeRow.Slot3D)
        Write-Output ("SMOKE riderCtl parts ms={0} clamp4='{1}' rail=[{2}] settings=[{3}] fileBarPad={4} fileHg={5} varPad={6} varHg={7} hostFat={8} hostHg={9} sceneFat={10} sceneHg={11} live={12}" -f $rcPMs, $rcLen, (& $rcFmt $rcS), (& $rcFmt $rcT), $rcOv.BarPad, $rcOv.HandGuards, $script:BarPadOverride, $script:HandGuardsOverride, [OU3DHost]::FatBar, [OU3DHost]::HandGuards, $rcSc.FatBar, $rcSc.HandGuards, $(if ($script:Live3D -and $script:Live3D.Scene) { 'fat=' + $script:Live3D.Scene.FatBar + ',hg=' + $script:Live3D.Scene.HandGuards } else { 'none' }))
        # Render with the overrides (temp PreviewDir): #42, crossbar, no hand guards
        $sw3.Restart(); [void][OU3DHost]::EnsurePreviews($bikeRow.PackPath, $bikeRow.Slot3D, $true, $true); $rcRMs = $sw3.ElapsedMilliseconds
        $rcOut = @()
        foreach ($pp in @([OU3DHost]::SidePath($bikeRow.PackPath, $bikeRow.Slot3D, $true), [OU3DHost]::StackPath($bikeRow.PackPath, $bikeRow.Slot3D, $true))) {
          if (Test-Path -LiteralPath $pp) { $dst = Join-Path $rcTmp ('render_42_crossbar_nohg_' + [IO.Path]::GetFileName($pp)); Copy-Item -LiteralPath $pp $dst -Force; $rcOut += $dst }
        }
        Write-Output ("SMOKE riderCtl render ms={0} files={1} partsStamp='{2}' plateStamp='{3}'" -f $rcRMs, ($rcOut -join ';'), ((Get-Content -LiteralPath ([OU3DHost]::PartsStampPath) -Raw) -replace "`r?`n", ' '), ((Get-Content -LiteralPath ([OU3DHost]::StampPath) -Raw) -replace "`r?`n", ' '))
        # Persistence: the file as written + a fresh read (what a restart sees)
        $rcTxt = (Get-Content -LiteralPath $script:RiderCfg | Where-Object { $_ -notmatch '^#' }) -join ' '
        $script:BarPadOverride = $null; $script:HandGuardsOverride = $null
        $rc2 = Get-OURider -NoCacheWrite
        Write-Output ("SMOKE riderCtl persist file='{0}' reload num={1} ({2}) pad={3} ({4}) hg={5} ({6})" -f $rcTxt, $rc2.Number, $rc2.NumberSource, $rc2.BarPad, $rc2.BarPadSource, $rc2.HandGuards, $rc2.HandGuardsSource)
        # Back to the save value -> stored as auto (follows the save again); Settings show off -> rail follows; then Reset
        $rcS.HG.Checked = $true; $rcS.Round.Checked = $true
        $rcOv2 = Get-OURiderOverride
        $rcT.Show.Checked = $false; $rcRailOff = $rcS.Show.Checked; $rcHostShowOff = [OU3DHost]::ShowNumber
        $rcS.Num.Text = ''; Invoke-RiderNumberCommit $rcS.Num; $rcBlank = (Get-OURiderOverride).Number
        $rcS.Num.Text = '7'; Invoke-RiderNumberCommit $rcS.Num
        Invoke-RiderReset
        $rcOv3 = Get-OURiderOverride
        Write-Output ("SMOKE riderCtl sync backToSave pad={0} hg={1} settingsShowOff->rail={2} hostShow={3} blankNum={4} reset: file num={5} pad={6} hg={7} show={8} rail=[{9}] settings=[{10}] hostNum='{11}' hostFat={12} hostHg={13}" -f $(if ($rcOv2.BarPad) { $rcOv2.BarPad } else { 'auto' }), $(if ($null -eq $rcOv2.HandGuards) { 'auto' } else { $rcOv2.HandGuards }), $rcRailOff, $rcHostShowOff, $rcBlank, $rcOv3.Number, $(if ($rcOv3.BarPad) { $rcOv3.BarPad } else { 'auto' }), $(if ($null -eq $rcOv3.HandGuards) { 'auto' } else { $rcOv3.HandGuards }), $rcOv3.ShowNumbers, (& $rcFmt $rcS), (& $rcFmt $rcT), [OU3DHost]::RiderNumber, [OU3DHost]::FatBar, [OU3DHost]::HandGuards)
      } catch {
        Write-Output ("SMOKE riderCtl ERROR {0} @ {1}" -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber)
      } finally {
        try { [OU3DHost]::CancelThumbs() } catch {}
        $script:RiderCfg = $rcCfg0; [OU3DHost]::PreviewDir = $rcPrev0
        foreach ($k in $rcAsked0) { [void]$script:Showroom3DAsked.Add($k) }
        [void](Sync-OURider -Force); Update-RiderCard
        $rcStampT1 = @(foreach ($sp in @([OU3DHost]::StampPath, [OU3DHost]::PartsStampPath)) { if (Test-Path -LiteralPath $sp) { (Get-Item -LiteralPath $sp).LastWriteTimeUtc.Ticks } else { 0 } }) -join ','
        $rcCfgT1 = $(if (Test-Path -LiteralPath $rcCfg0) { (Get-Item -LiteralPath $rcCfg0).LastWriteTimeUtc.Ticks } else { 0 })
        Write-Output ("SMOKE riderCtl restored cfgUntouched={0} stampsUntouched={1} prevDir={2} hostNum='{3}' hostFat={4} hostHg={5} rail=[{6}] tmp={7}" -f ($rcCfgT0 -eq $rcCfgT1), ($rcStampT0 -eq $rcStampT1), ([OU3DHost]::PreviewDir -eq $rcPrev0), [OU3DHost]::RiderNumber, [OU3DHost]::FatBar, [OU3DHost]::HandGuards, (& $rcFmt $rcS), $rcTmp)
      }
    }
    # Multi-select identity smoke (future Custom Packs consumes these)
    $script:ShowroomChecked.Clear()
    $take = @($script:ShowroomRows | Select-Object -First 3)
    foreach ($t in $take) { [void]$script:ShowroomChecked.Add($t.ItemKey) }
    $checkedItems = @(Get-ShowroomCheckedItems)
    $idSample = @($checkedItems | ForEach-Object { "{0}/{1}/{2}" -f $_.PackFile, $_.Model, $_.Skin })
    Write-Output ("SMOKE showroomChecked n={0} packs={1} ids=[{2}]" -f $checkedItems.Count, @(Get-ShowroomCheckedPackNames).Count, ($idSample -join ' | '))
  }
  Show-Page 'SETTINGS'
  Write-Output ("SMOKE settings gameTxt='{0}' root='{1}' pack='{2}' theme='{3}' advVis={4} cards={5}" -f $txtSettingsGame.Text, $lblRootPath.Text, $lblPackFilesPath.Text, $lblThemePath.Text, $pnlAdv.Visible, ((@($btnOpenRoot, $btnOpenPackFiles, $btnOpenTheme) | ForEach-Object Text) -join '|'))
  $rs = Get-OURider -NoCacheWrite
  Write-Output ("SMOKE rider number={0} numSrc='{1}' name={2} nameSrc='{3}' save='{4}' hostNum='{5}' card='{6}'" -f $rs.Number, $rs.NumberSource, $rs.Name, $rs.NameSource, $rs.SavePath, $(try { [OU3DHost]::RiderNumber } catch { '?' }), $lblRiderInfo.Text)
  Write-Output ("SMOKE settingsGlass chrome={0} body={1} gameCard={2}" -f $script:OuGlassAlpha[$settingsFoldersCard], $script:OuGlassAlpha[$settingsFoldersCard], $script:OuGlassAlpha[$settingsGameCard])
  Write-Output ("SMOKE perf cacheFn={0} debounceFn={1} statusRefresh={2} childCascade={3}" -f [bool](Get-Command Ensure-OuFormBgCache -ErrorAction SilentlyContinue), [bool](Get-Command Request-OuGlassRefresh -ErrorAction SilentlyContinue), ($statusLabel.GetType().Name -eq "ToolStripStatusLabel"), ($false))
  Show-Page 'ABOUT'; Show-AboutSub 'README'
  Write-Output ("SMOKE readme title={0} notepad={1} buttons={2} chrome={3} body={4} textLen={5}" -f $lblReadmeTitle.Text, $btnReadmeNotepad.Text, $readmeBtnRow.Controls.Count, $script:OuGlassAlpha[$readmeChrome], $script:OuGlassAlpha[$readmeBody], $txtReadme.Text.Length)
  Show-Page 'ABOUT'; Show-AboutSub 'Version'
  Write-Output ("SMOKE version title={0} ver='{1}' date='{2}' openVis={3} chrome={4} body={5} updBtn='{6}' nav=[{7}] railBtns=[{8}]" -f $lblAboutTitle.Text, $lblConsoleVer.Text, $lblUiWorking.Text, $btnOpenVersionTxt.Visible, $script:OuGlassAlpha[$versionChrome], $script:OuGlassAlpha[$versionBody], $btnCheckUpdates.Text, ($navNames -join '|'), ((@($script:AboutRailButtons.Keys) | Sort-Object) -join '|'))
  Start-OuUpdateCheck; $sw = [Diagnostics.Stopwatch]::StartNew(); while ($script:OuUpdIar -and $sw.ElapsedMilliseconds -lt 15000) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 30 }; $u0 = $lblUpdateResult.Text
  foreach ($mk in @(@{ Ok = $true; Tag = 'v' + $script:OU_Version; Url = 'https://example.invalid/r' }, @{ Ok = $true; Tag = 'v9.9.9'; Url = 'https://example.invalid/r9' }, @{ Ok = $false; Code = 404; Msg = 'nf' }, @{ Ok = $false; Code = 0; Msg = 'offline' })) {
    $script:OuUpdMock = $mk; Start-OuUpdateCheck
    $sw = [Diagnostics.Stopwatch]::StartNew(); while ($script:OuUpdIar -and $sw.ElapsedMilliseconds -lt 5000) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 30 }
    Write-Output ("SMOKE update mock={0} result='{1}' download={2}" -f $(if ($mk.Ok) { $mk.Tag } else { $mk.Code }), $lblUpdateResult.Text, $btnUpdateDownload.Visible)
  }
  $script:OuUpdMock = $null; Set-OuUpdateResult '' $null
  Write-Output ("SMOKE update live repo={0} result='{1}'" -f $script:OU_UpdateRepo, $u0)
  Write-Output ("SMOKE perfStill cache={0} debounce={1} statusRefreshGone={2}" -f [bool](Get-Command Ensure-OuFormBgCache -EA SilentlyContinue), [bool](Get-Command Request-OuGlassRefresh -EA SilentlyContinue), (-not [bool]($status.GetType().GetMethod("Refresh"))))
  Show-Page 'PACK MANAGER'
  Write-Output ("SMOKE theme bgImage={0} accent={1} runBtn={2} glassHooked={3}" -f [bool]$form.BackgroundImage, $script:Theme.Accent.ToArgb(), $btnRunFixer.BackColor.ToArgb(), $script:OuGlassHooked.Count)
  Write-Output ("SMOKE theme2 glassAlpha={0} listFore={1} previewTitle={2} btnChrome={3}" -f $script:Theme.GlassAlpha, $lstCatalog.ForeColor.Name, $lblFixPrevTitle.ForeColor.Name, [bool]$fixBtnChrome)
  Write-Output ("SMOKE theme3 selectBg={0} checkedBg={1} accent={2} run={3} same={4} ownerDraw={5} checkBoxes={6}" -f $script:Theme.SelectBg.ToArgb(), $script:Theme.CheckedBg.ToArgb(), $script:Theme.Accent.ToArgb(), $btnRunFixer.BackColor.ToArgb(), ($script:Theme.SelectBg.ToArgb() -eq $btnRunFixer.BackColor.ToArgb() -and $script:Theme.CheckedBg.ToArgb() -eq $btnRunFixer.BackColor.ToArgb()), $lstCatalog.OwnerDraw, $lstCatalog.CheckBoxes)
  $gn = @(); $ha = @(); foreach ($gc in $script:OuGlassHooked) { $n = $(if ($gc.Name) { $gc.Name } else { $gc.GetType().Name }); $gn += $n; if ($script:OuGlassAlpha.ContainsKey($gc)) { $ha += ("{0}:{1}" -f $n, $script:OuGlassAlpha[$gc]) } }; Write-Output ("SMOKE theme4 glassAlpha={0} heavy={1} composite=formBgBlit hooked={2} panels={3} alphas={4}" -f $script:Theme.GlassAlpha, $script:Theme.GlassAlphaHeavy, $script:OuGlassHooked.Count, ($gn -join ","), ($ha -join ","))
  # Heavy-card coverage: how much of each glass panel is buried under opaque children
  foreach ($hn in @('leftRail','fixPrevPanel','selTray')) {
    $hp = $null; foreach ($gc in $script:OuGlassHooked) { if ($gc.Name -eq $hn) { $hp = $gc; break } }
    if (-not $hp) { Write-Output ("SMOKE heavyMiss name={0}" -f $hn); continue }
    $a = 0; if ($script:OuGlassAlpha.ContainsKey($hp)) { $a = [int]$script:OuGlassAlpha[$hp] }
    $area = [Math]::Max(1, $hp.ClientSize.Width * $hp.ClientSize.Height)
    $cov = 0
    foreach ($ch in $hp.Controls) {
      if (-not $ch.Visible) { continue }
      $opaque = $true
      try { if ($ch.BackColor.A -lt 255 -or $ch.BackColor.ToArgb() -eq [System.Drawing.Color]::Transparent.ToArgb()) { $opaque = $false } } catch { }
      if (-not $opaque) { continue }
      $cov += [Math]::Max(0, $ch.Width * $ch.Height)
    }
    $pct = [Math]::Min(100, [int](100.0 * $cov / $area))
    Write-Output ("SMOKE heavyDiag name={0} alpha={1} back={2} bgImg={3} size={4}x{5} opaqueChildCover~{6}% children={7}" -f $hn, $a, $hp.BackColor.Name, [bool]$hp.BackgroundImage, $hp.ClientSize.Width, $hp.ClientSize.Height, $pct, $hp.Controls.Count)
  }
  Write-Output ("SMOKE heavyVsLight light={0} heavy={1} heavyMoreOpaque={2}" -f $script:Theme.GlassAlpha, $script:Theme.GlassAlphaHeavy, ($script:Theme.GlassAlphaHeavy -gt $script:Theme.GlassAlpha))
  # ---- Tab state: leaving and returning keeps state, no rescans unless data changed ----
  Show-Page 'PACK MANAGER'
  $fc0 = $script:FixFilterControls
  $script:SuppressFilter = $true; try { $fc0.Search.Text = 'ktm' } finally { $script:SuppressFilter = $false }
  Update-CatalogView
  if ($lstCatalog.Items.Count) { $lstCatalog.Items[0].Selected = $true }
  $selB = @($lstCatalog.SelectedItems | ForEach-Object { [string]$_.Tag }) -join ','
  $nB = $lstCatalog.Items.Count; $scanB = [int]$script:CatalogScanCount; $colW = $lstCatalog.Columns[1].Width + 7; $lstCatalog.Columns[1].Width = $colW
  $srcB = $script:CatalogSource
  $cardsB = $showCardFlow.Controls.Count; $selShowB = $script:ShowroomSelected; $buildB = [int]$script:ShowroomBuildCount; $chkShowB = $script:ShowroomChecked.Count
  Show-Page 'GALLERY'
  $cardsG = $showCardFlow.Controls.Count; $buildG = [int]$script:ShowroomBuildCount; $selShowG = $script:ShowroomSelected; $sfcSame = [object]::ReferenceEquals($script:ShowroomFilterControls.Cat.Parent.Parent, $leftRail)
  Show-Page 'SETTINGS'
  $txtRiderNum.Text = '977'; $txtRiderNum.Modified = $true
  Show-Page 'ABOUT'; Show-AboutSub 'README'
  $txtReadme.SelectionStart = [Math]::Min(50, $txtReadme.Text.Length); $rdSel = $txtReadme.SelectionStart; $rdStamp = $script:ReadmeTextStamp
  Show-Page 'ABOUT'; Show-AboutSub 'Version'
  Show-Page 'SETTINGS'
  $riderKept = ($txtRiderNum.Text -eq '977')
  Show-Page 'ABOUT'; Show-AboutSub 'README'
  $rdKept = ($txtReadme.SelectionStart -eq $rdSel)
  Show-Page 'PACK MANAGER'
  $selA = @($lstCatalog.SelectedItems | ForEach-Object { [string]$_.Tag }) -join ','
  Write-Output ("SMOKE tabState pm sameCtl={0} search='{1}' items={2}/{3} scans={4}->{5} sel=[{6}]/[{7}] colW={8} source={9}/{10} railKey={11}" -f [object]::ReferenceEquals($fc0, $script:FixFilterControls), $script:FixFilterControls.Search.Text, $nB, $lstCatalog.Items.Count, $scanB, [int]$script:CatalogScanCount, $selB, $selA, ($lstCatalog.Columns[1].Width -eq $colW), $srcB, $script:CatalogSource, $script:LeftRailKey)
  Write-Output ("SMOKE tabState showroom cards={0}->{1} builds={2}->{3} selected={4} same={5} checked={6}/{7} railInLeft={8} dirty={9}" -f $cardsB, $cardsG, $buildB, $buildG, $selShowG, ($selShowB -eq $selShowG), $chkShowB, $script:ShowroomChecked.Count, $sfcSame, $script:ShowroomDirty)
  Write-Output ("SMOKE tabState settings riderKept={0} readmeKept={1} readmeStamp={2} railCache=[{3}]" -f $riderKept, $rdKept, ($rdStamp -eq $script:ReadmeTextStamp), ((@($script:RailCache.Keys) | Sort-Object) -join '|'))
  # Data change -> exactly one rescan on return, filters still kept
  Set-PackDataChanged
  $scan1 = [int]$script:CatalogScanCount; $build1 = [int]$script:ShowroomBuildCount
  Show-Page 'ABOUT'; Show-AboutSub 'Version'; Show-Page 'PACK MANAGER'
  $scan2 = [int]$script:CatalogScanCount
  Show-Page 'GALLERY'
  $build2 = [int]$script:ShowroomBuildCount
  Show-Page 'PACK MANAGER'; Show-Page 'GALLERY'
  Write-Output ("SMOKE tabState dirty catalogScans={0}->{1}->{2} showroomBuilds={3}->{4}->{5} searchKept='{6}' dirtyAfter={7}/{8}" -f $scan1, $scan2, [int]$script:CatalogScanCount, $build1, $build2, [int]$script:ShowroomBuildCount, $script:FixFilterControls.Search.Text, $script:CatalogDirty, $script:ShowroomDirty)
  # Undo smoke edits (no files written)
  $txtRiderNum.Modified = $false; Update-RiderCard
  Show-Page 'PACK MANAGER'
  $script:SuppressFilter = $true; try { $script:FixFilterControls.Search.Text = '' } finally { $script:SuppressFilter = $false }
  Update-CatalogView
  Write-Output ("SMOKE appIcon path={0} loaded={1} size={2} formIcon={3} formIconSize={4} appId={5} appIdHr={6}" -f $script:AppIconPath, [bool]$script:AppIcon, $(if ($script:AppIcon) { $script:AppIcon.Size } else { '-' }), [object]::ReferenceEquals($form.Icon, $script:AppIcon), $form.Icon.Size, $script:OuAppId, $script:OuAppIdResult)
  Write-Output ("SMOKE pagesOK game={0} catalogLoaded={1} gallery={2}" -f $txtGame.Text, $script:CatalogPacks.Count, ($pages.ContainsKey('GALLERY')))
  if ($brokenN -eq 0) {
    $fixOut = @(& $fixer -NoPrompt -InstallMode no -OnlyPacks @('__none__.pak') 2>&1 | ForEach-Object { "$_" })
    $res = $fixOut | Where-Object { $_ -like 'RESULT|*' } | Select-Object -Last 1
    Write-Output ("SMOKE FIXER_ONLYPACKS {0}" -f $(if ($res) { $res } else { 'NO_RESULT' }))
  }
  $form.Dispose()
  return
}

[void]$form.ShowDialog()
