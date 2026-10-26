# Test-OURender.ps1 - PC smoke test for the native 3D renderer (PowerShell 5.1, no Python).
# powershell -ExecutionPolicy Bypass -File Test-OURender.ps1 [-GameData "...\MX vs. ATV Unleashed\data"] [-Pak some.pak] [-Out $env:TEMP\ou3d]
param(
  [string]$GameData = 'C:\Program Files (x86)\Steam\steamapps\common\MX vs. ATV Unleashed\data',
  [string]$Pak = '',
  [string]$Out = (Join-Path $env:TEMP 'ou3d_test'),
  [string[]]$Slots = @('KTM250SX_01_Plastics'),
  [string]$Number = ''   # rider number for the bike plates (blank = none)
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$sw = [Diagnostics.Stopwatch]::StartNew()
if (-not ('OURender3D' -as [type])) {
  Add-Type -ReferencedAssemblies System.Drawing, System.Windows.Forms -Path (Join-Path $here 'OURender.cs'), (Join-Path $here 'OULiveView.cs')
}
"Add-Type compile: {0} ms" -f $sw.ElapsedMilliseconds
if ($Number) { [OURiderPlate]::Number = $Number; "Rider number on plates: {0}" -f $Number }
$sw.Restart(); $stock = [OURender3D]::Stock($GameData, $null)
"common.pak TOC: {0} ms" -f $sw.ElapsedMilliseconds
$sw.Restart(); $idx = [OUSubIndex]::Build($stock)
"sub index: {0} slots in {1} ms" -f $idx.Count, $sw.ElapsedMilliseconds
$report = foreach ($k in ($idx.Keys | Sort-Object)) {
  $status = 'ok'; $ms = 0; $warn = ''
  try { $t = [Diagnostics.Stopwatch]::StartNew(); $sc = [OURender3D]::SceneForSlot($stock, $k, $null)
        $bm = [OURender3D]::RenderView($sc, 'right', 400, 250, 2, [Drawing.Color]::FromArgb(28,29,34)); $ms = $t.ElapsedMilliseconds
        $bm.Save((Join-Path $Out ("all_" + $k + "_side.png")), [Drawing.Imaging.ImageFormat]::Png); $bm.Dispose()
        $warn = (@($sc.Model.Warnings) + @($sc.GreyMaterials | % { "grey:$_" })) -join '; '
        if ($warn) { $status = 'partial' } }
  catch { $status = 'FAIL'; $warn = $_.Exception.InnerException.Message; if (-not $warn) { $warn = $_.Exception.Message } }
  [pscustomobject]@{ Slot = $k; Sub = ($idx[$k] -join ','); Status = $status; Ms = $ms; Notes = $warn }
}
$report | Format-Table -AutoSize | Out-String -Width 400
$report | Export-Csv -NoTypeInformation (Join-Path $Out 'supported_slots.csv')
foreach ($s in $Slots) {
  $tex = $null; if ($Pak) { $tex = [OUBikeScene]::TexturesFromPak($Pak) }
  $sc = [OURender3D]::SceneForSlot($stock, $s, $tex)
  $name = if ($Pak) { $Pak } else { 'stock.pak' }
  $ms = [OURender3D]::SavePreviews($sc, (Join-Path $Out ([OURender3D]::PreviewName($name, $s, 'stack'))), (Join-Path $Out ([OURender3D]::PreviewName($name, $s, 'side'))), 800, 500, [Drawing.Color]::Transparent)
  "SavePreviews {0}: {1} ms" -f $s, $ms
  $buf = New-Object OURenderBuffers
  foreach ($sz in @(@(400,300),@(800,500))) { foreach ($ss in 1,2) {
    [void]$sc.RenderPixels(0, 12, 1, $sz[0], $sz[1], $ss, $false, [Drawing.Color]::Transparent, $buf)
    $t = [Diagnostics.Stopwatch]::StartNew(); for ($i = 0; $i -lt 24; $i++) { [void]$sc.RenderPixels($i * 15, 12, 1, $sz[0], $sz[1], $ss, $false, [Drawing.Color]::Transparent, $buf) }
    "live {0}x{1} ss{2}: {3:N1} ms/frame" -f $sz[0], $sz[1], $ss, ($t.Elapsed.TotalMilliseconds / 24) } }
}
"Output: $Out"
