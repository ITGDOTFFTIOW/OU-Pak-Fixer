[Console]::OutputEncoding=[Text.Encoding]::UTF8
# Open Unleashed Pack Manager - turn custom packs on/off and fix broken installed packs.
$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$root    = (Resolve-Path (Join-Path $here '..\..')).Path
if(-not (Test-Path -LiteralPath (Join-Path $root 'FIX PAKS.bat'))){ throw "Pak Fixer root not found (expected FIX PAKS.bat). Scripts: $here" }
$fixer   = Join-Path $here 'Fix-OUPaks.ps1'
$disD    = Join-Path $root 'Pack Files\Disabled'
$orig    = Join-Path $root 'Pack Files\Originals'
$cfg     = Join-Path $root 'Settings\settings.txt'
$prevD   = Join-Path $root 'Pack Manager\Previews'
$loadD   = Join-Path $root 'Pack Manager\Loadouts'
$listTxt = Join-Path $root 'Pack Manager\Installed Packs.txt'
foreach($p in $disD,$orig,$prevD,$loadD,(Split-Path $listTxt -Parent)){ New-Item -ItemType Directory -Force $p | Out-Null }
$STOCK = 'aud,common,env,fs01,fs02,fs03,fs04,fs05,fs06,fs07,fs08,fs09,fs10,fs11,fs12,fs13,mc01,mc02,mc03,mc04,mc05,mc06,mc07,mc08,mc09,mc10,mst,nat01,nat02,nat03,nat04,nat05,nat06,nat07,nat08,nat09,nat10,nat11,nat12,nat13,nat14,nat15,nat16,nat17,nat18,nat19,sm01,sm02,sm03,sx01,sx02,sx03,sx04,sx05,sx06,sx07,sx08,sx09,sx10,sx11,sx12,sx13,sx14,sx15,sx16,sx17,sx18,sx19,sx20,tex,ui'.Split(',') | ForEach-Object { "$_.pak" }
function Get-Game { if(Test-Path -LiteralPath $cfg){ $l=Get-Content -LiteralPath $cfg | ? { $_ -like 'GameDataFolder=*' } | select -First 1; if($l){ $g=$l.Substring(15); if(Test-Path -LiteralPath (Join-Path $g 'common.pak')){ return $g } } }; $null }
function Refresh-List { & $fixer -ListOnly | Out-Null }
$game=Get-Game
# When dot-sourced by OU-UI.ps1, skip the interactive menu and allow a missing game folder (UI can set it).
$script:OuAsLibrary = ($MyInvocation.InvocationName -eq '.')
if(-not $game){ & $fixer -ListOnly; $game=Get-Game; if(-not $game -and -not $script:OuAsLibrary){ Write-Host "No game folder set. Run Settings\CHANGE GAME FOLDER.bat first."; return } }

function Count-Broken($path){ $b=[IO.File]::ReadAllBytes($path); if($b.Length -lt 4){return -1}; $n=[BitConverter]::ToInt32($b,0)
  if($n -le 0 -or $n -gt 20000 -or 4+$n*108 -gt $b.Length){return -1}; $base=4+$n*108; $c=0
  for($i=0;$i -lt $n;$i++){ $e=4+$i*108; $nm=[Text.Encoding]::ASCII.GetString($b,$e,100).Split([char]0)[0]; if($nm -notmatch '(?i)\.dxt$'){continue}
    $h=$base+[BitConverter]::ToInt32($b,$e+100); if($h -lt 0 -or $h+32 -gt $b.Length){continue}
    if([BitConverter]::ToInt32($b,$h+16) -gt 0 -and [BitConverter]::ToInt32($b,$h+20) -gt 0 -and [BitConverter]::ToInt32($b,$h+28) -eq 0){$c++} }; $c }
function Fix-InPlace($path){ $b=[IO.File]::ReadAllBytes($path); $n=[BitConverter]::ToInt32($b,0); $base=4+$n*108
  for($i=0;$i -lt $n;$i++){ $e=4+$i*108; $nm=[Text.Encoding]::ASCII.GetString($b,$e,100).Split([char]0)[0]; if($nm -notmatch '(?i)\.dxt$'){continue}
    $h=$base+[BitConverter]::ToInt32($b,$e+100); if($h -lt 0 -or $h+32 -gt $b.Length){continue}
    $w=[BitConverter]::ToInt32($b,$h+16); $ht=[BitConverter]::ToInt32($b,$h+20)
    if($w -le 0 -or $ht -le 0 -or [BitConverter]::ToInt32($b,$h+28) -ne 0){continue}
    $x=$w;$y=$ht; while($y){$t=$y;$y=$x % $y;$x=$t}
    [BitConverter]::GetBytes([int]($w/$x)).CopyTo($b,$h+24); [BitConverter]::GetBytes([int]($ht/$x)).CopyTo($b,$h+28) }
  [IO.File]::WriteAllBytes($path,$b) }
function Save-Original($path){ $name=Split-Path $path -Leaf; $p=Join-Path $orig $name
  if(Test-Path -LiteralPath $p){ $bn=[IO.Path]::GetFileNameWithoutExtension($name); $ext=[IO.Path]::GetExtension($name); $i=2; do{ $p=Join-Path $orig "$bn ($i)$ext"; $i++ } while(Test-Path -LiteralPath $p) }
  Copy-Item -LiteralPath $path -Destination $p }
function Installed { @(Get-ChildItem -LiteralPath $game -File | ? { $_.Extension -ieq '.pak' -and ($STOCK -notcontains $_.Name.ToLower()) } | sort Name) }
function Disabled  { @(Get-ChildItem -LiteralPath $disD -File | ? { $_.Extension -ieq '.pak' } | sort Name) }
function Get-Tags { Refresh-List; $t=@{}; $txt=$listTxt
  if(Test-Path -LiteralPath $txt){ foreach($l in (Get-Content -LiteralPath $txt -Encoding UTF8)){ if($l -match '^=== ((?:\[[^\]]+\] )+)(.+) ===$'){ $t[$matches[2]]=$matches[1].Trim() } } }; $t }
function Pick($items,$verb,$tags=@{}){
  if(-not $items.Count){ Write-Host "  (nothing here)"; return @() }
  for($i=0;$i -lt $items.Count;$i++){ $tg=$tags[$items[$i].Name]; Write-Host ("  {0,3}. {1}{2}" -f ($i+1),$(if($tg){"$tg "}else{""}),$items[$i].Name) }
  $a=Read-Host "`nNumbers to $verb (e.g. 1,3,5 or 2-4), A for all, Enter to cancel"
  if(-not $a){ return @() }; if($a -match '^(a|all)$'){ return $items }
  $sel=@(); foreach($part in $a -split ','){ $part=$part.Trim()
    if($part -match '^(\d+)-(\d+)$'){ $sel+= [int]$matches[1]..[int]$matches[2] } elseif($part -match '^\d+$'){ $sel+=[int]$part } }
  @($sel | ? { $_ -ge 1 -and $_ -le $items.Count } | select -Unique | % { $items[$_-1] }) }
function Get-Labels($path){ $L=New-Object System.Collections.Generic.List[string]
  try { $fs=[IO.File]::OpenRead($path); $br=New-Object IO.BinaryReader($fs); $n=$br.ReadInt32()
    if($n -gt 0 -and $n -lt 20000){ for($i=0;$i -lt $n;$i++){ $nm=[Text.Encoding]::ASCII.GetString($br.ReadBytes(100)).Split([char]0)[0]; $null=$br.ReadBytes(8); if(-not $nm){continue}
      $file=[IO.Path]::GetFileNameWithoutExtension($nm) -replace '(?i)_AI$',''; $ext=[IO.Path]::GetExtension($nm).ToLower(); if($file -match '(?i)^(desktop|thumbs)$'){continue}
      $pf=($file -replace '_',' ').Trim()
      $lab= if($ext -eq '.dxm'){"model: $pf"} elseif($nm -match '(?i)\\Veh\\Tex\\'){"bike: $pf"} elseif($nm -match '(?i)\\Rider\\Tex\\'){"gear: $pf"} else {"file: " + ($nm -replace '^(?i)Data\\','')}
      if(-not $L.Contains($lab)){ $L.Add($lab) } } } } finally { if($fs){$fs.Close()} }
  ,$L }
# ---------- Showroom item inventory (per bike/gear from Veh\Tex / Rider\Tex) ----------
# One Showroom item = Kind + Model + Skin, with all part textures under that key.
# MakeSheet contact sheets stay pack-level; this is the per-item data path for a future card UI.
$script:ShowroomBikeModels = @(
  'CRF450R','CRF450','CRF250R','CRF250','CRF150R','CRF150','CR125R','CR250R','CR500',
  'KX450F','KX250F','KX250','KX125','KX100','KX85','KX65',
  'RMZ450','RMZ250','RM250','RM125','RM85','RM65',
  'YZ450F','YZ250F','YZF450','YZF250','YZF500','YZ250','YZ125','YZ85',
  'YFZ450','LTZ400','TRX450','DVX400','KFX450','PWRSPORT'
) | Sort-Object { $_.Length } -Descending

$script:ShowroomBikeParts = @(
  'Plastics','Sprockets','Swingarm','Radiator','Exhaust','Numberplate','Number','Fender',
  'Forks','Fork','Wheels','Wheel','Tires','Tire','Seat','Frame','Disc','Rotor','Chain','Brake'
) | Sort-Object { $_.Length } -Descending

$script:ShowroomGearParts = @(
  'ChestProtector','Chest','Shoulder','Elbow','Knee','Goggles','Helmet','Jersey','Pants',
  'Boots','Gloves','Suit','Neck','Mask','Cap','Visor','Socks','Belt','Body'
) | Sort-Object { $_.Length } -Descending

function Get-ShowroomPreferredThumb([string]$kind, [string[]]$parts) {
  if ($kind -eq 'bike') {
    foreach ($p in @('Plastics','Fender','Seat','Frame','Sprockets')) {
      if ($parts -contains $p) { return $p }
    }
  } else {
    foreach ($p in @('Jersey','Suit','Body','Helmet','Pants','Goggles','Chest','Gloves','Boots')) {
      if ($parts -contains $p) { return $p }
    }
  }
  if ($parts -and $parts.Count) { return $parts[0] }
  $null
}

function Parse-ShowroomTextureName {
  param(
    [Parameter(Mandatory)][string]$BaseName,
    [Parameter(Mandatory)][ValidateSet('bike','gear')][string]$Kind
  )
  $base = ($BaseName -replace '(?i)_AI$','').Trim()
  if (-not $base) { return $null }

  $partList = if ($Kind -eq 'bike') { $script:ShowroomBikeParts } else { $script:ShowroomGearParts }
  $part = $null
  $body = $base
  foreach ($p in $partList) {
    if ($base -match ("(?i)^(.+)_" + [regex]::Escape($p) + '$')) {
      $body = $matches[1]
      $part = $p
      # canonical casing from list
      foreach ($c in $partList) { if ($c -ieq $p) { $part = $c; break } }
      break
    }
  }

  # Gear without a trailing part token: THQ_Helmet_01 / Thor_Jersey_01 (part in the middle)
  if ($Kind -eq 'gear' -and -not $part) {
    foreach ($p in $partList) {
      if ($base -match ("(?i)^(.+)_" + [regex]::Escape($p) + "_(\d{1,3})$")) {
        $brand = $matches[1]
        $variant = $matches[2]
        foreach ($c in $partList) { if ($c -ieq $p) { $part = $c; break } }
        return [pscustomobject]@{
          Kind = 'gear'; Model = $brand; Skin = $variant; Part = $part
          GroupKey = ("gear|{0}|{1}|{2}" -f $brand, $variant, $part); ParseNote = 'brand_part_variant'
        }
      }
      if ($base -match ("(?i)^(.+)_" + [regex]::Escape($p) + '$')) {
        $brand = $matches[1]
        foreach ($c in $partList) { if ($c -ieq $p) { $part = $c; break } }
        return [pscustomobject]@{
          Kind = 'gear'; Model = $brand; Skin = ''; Part = $part
          GroupKey = ("gear|{0}||{1}" -f $brand, $part); ParseNote = 'brand_part'
        }
      }
    }
    # fallback: first token brand, rest skin
    $tok = @($base -split '_')
    if ($tok.Count -ge 2) {
      return [pscustomobject]@{
        Kind = 'gear'; Model = $tok[0]; Skin = ($tok[1..($tok.Count-1)] -join '_'); Part = 'Other'
        GroupKey = ("gear|{0}|{1}|Other" -f $tok[0], ($tok[1..($tok.Count-1)] -join '_')); ParseNote = 'gear_fallback'
      }
    }
    return [pscustomobject]@{
      Kind = 'gear'; Model = $base; Skin = ''; Part = 'Other'
      GroupKey = ("gear|{0}||Other" -f $base); ParseNote = 'gear_opaque'
    }
  }

  # Gear with trailing part token: one card per part
  if ($Kind -eq 'gear') {
    if (-not $part) { $part = 'Other' }
    $tok = @($body -split '_' | Where-Object { $_ })
    $skin = ''
    $model = $body
    if ($tok.Count -ge 2 -and $tok[-1] -match '^\d{1,3}$') {
      $skin = $tok[-1]
      $model = ($tok[0..($tok.Count-2)] -join '_')
    } elseif ($tok.Count -ge 1) {
      $model = $tok[0]
      if ($tok.Count -ge 2) { $skin = ($tok[1..($tok.Count-1)] -join '_') }
    }
    return [pscustomobject]@{
      Kind = 'gear'; Model = $model; Skin = $skin; Part = $part
      GroupKey = ("gear|{0}|{1}|{2}" -f $model, $skin, $part); ParseNote = 'gear_trailing_part'
    }
  }

  if ($Kind -eq 'bike') {
    if (-not $part) { $part = 'Other' }
    $tokens = [System.Collections.Generic.List[string]]::new()
    foreach ($t in @($body -split '_')) { if ($t) { [void]$tokens.Add($t) } }
    $model = $null; $modelIdx = -1
    # Longest known model matching a token or joined prefix
    for ($i = 0; $i -lt $tokens.Count; $i++) {
      for ($len = [Math]::Min(3, $tokens.Count - $i); $len -ge 1; $len--) {
        $cand = ($tokens[$i..($i + $len - 1)] -join '_')
        foreach ($m in $script:ShowroomBikeModels) {
          if ($cand -ieq $m) {
            $model = $m; $modelIdx = $i; $modelLen = $len
            break
          }
        }
        if ($model) { break }
      }
      if ($model) { break }
    }
    if (-not $model -and $tokens.Count) {
      $model = $tokens[0]
      $modelIdx = 0
      $modelLen = 1
    }
    $before = @()
    $after = @()
    if ($modelIdx -gt 0) { $before = @($tokens[0..($modelIdx - 1)]) }
    $afterStart = $modelIdx + $modelLen
    if ($afterStart -lt $tokens.Count) { $after = @($tokens[$afterStart..($tokens.Count - 1)]) }
    $skinTok = @($before + $after)
    $skin = if ($skinTok.Count) { $skinTok -join '_' } else { '' }
    return [pscustomobject]@{
      Kind = 'bike'; Model = $model; Skin = $skin; Part = $part
      GroupKey = ("bike|{0}|{1}" -f $model, $skin); ParseNote = $(if ($part -eq 'Other') { 'bike_unknown_part' } else { 'bike_ok' })
    }
  }

  $null
}

function Get-ShowroomItems {
  <#
    .SYNOPSIS
      Inventory bike/gear Showroom items inside one or more .pak files from Veh\Tex / Rider\Tex names.
    .OUTPUTS
      PackFile, PackPath, Kind, Model, Skin, Parts[], PreferredThumbPart, PreferredThumbPath,
      TexturePaths[], Entries[] (Path, BaseName, Part, Offset, Length, WidthHint), GroupKey, Notes
  #>
  param(
    [Parameter(Mandatory)][object[]]$Pak
  )
  $files = @()
  foreach ($p in @($Pak)) {
    if ($p -is [System.IO.FileInfo]) { $files += $p }
    elseif ($p -is [string] -and (Test-Path -LiteralPath $p)) { $files += Get-Item -LiteralPath $p }
    elseif ($p -and $p.PSObject.Properties['FullName']) { $files += Get-Item -LiteralPath $p.FullName }
  }

  $all = New-Object System.Collections.ArrayList
  foreach ($f in $files) {
    $groups = @{}  # GroupKey -> accumulator
    # TOC-only read (fast): offsets/lengths enough for later on-demand decode
    try {
      $fs = [IO.File]::Open($f.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    } catch { continue }
    try {
      if ($fs.Length -lt 4) { continue }
      $hdr = New-Object byte[] 4
      if ($fs.Read($hdr, 0, 4) -ne 4) { continue }
      $n = [BitConverter]::ToInt32($hdr, 0)
      if ($n -le 0 -or $n -gt 20000) { continue }
      $tocLen = 4 + $n * 108
      if ($tocLen -gt $fs.Length) { continue }
      $b = New-Object byte[] $tocLen
      $fs.Position = 0
      $got = 0
      while ($got -lt $tocLen) {
        $r = $fs.Read($b, $got, $tocLen - $got)
        if ($r -le 0) { break }
        $got += $r
      }
      if ($got -lt $tocLen) { continue }
    } finally {
      $fs.Dispose()
    }
    $bas = 4 + $n * 108

    for ($i = 0; $i -lt $n; $i++) {
      $e = 4 + $i * 108
      $nm = [Text.Encoding]::ASCII.GetString($b, $e, 100)
      $z = $nm.IndexOf([char]0); if ($z -ge 0) { $nm = $nm.Substring(0, $z) }
      if (-not $nm -or $nm -notmatch '(?i)\.dxt$') { continue }
      $low = $nm.ToLowerInvariant().Replace('/', '\')
      $kind = $null
      if ($low.Contains('\rider\tex\')) { $kind = 'gear' }
      elseif ($low.Contains('\veh\tex\')) { $kind = 'bike' }
      else { continue }

      $base = [IO.Path]::GetFileNameWithoutExtension($nm)
      if ($base -match '(?i)_AI$') { continue }

      $off = $bas + [BitConverter]::ToInt32($b, $e + 100)
      $len = [BitConverter]::ToInt32($b, $e + 104)
      $wHint = 0; $hHint = 0

      $parsed = Parse-ShowroomTextureName -BaseName $base -Kind $kind
      if (-not $parsed) { continue }

      $key = [string]$parsed.GroupKey
      if (-not $groups.ContainsKey($key)) {
        $groups[$key] = [ordered]@{
          PackFile = $f.Name
          PackPath = $f.FullName
          Kind = $parsed.Kind
          Model = $parsed.Model
          Skin = $parsed.Skin
          Parts = New-Object System.Collections.Generic.List[string]
          TexturePaths = New-Object System.Collections.Generic.List[string]
          Entries = New-Object System.Collections.Generic.List[object]
          GroupKey = $key
          Notes = New-Object System.Collections.Generic.List[string]
        }
        if ($parsed.ParseNote -and $parsed.ParseNote -ne 'bike_ok' -and $parsed.ParseNote -ne 'brand_part_variant') {
          [void]$groups[$key].Notes.Add($parsed.ParseNote)
        }
      }
      $g = $groups[$key]
      if ($parsed.Part -and -not $g.Parts.Contains($parsed.Part)) { [void]$g.Parts.Add($parsed.Part) }
      if (-not $g.TexturePaths.Contains($nm)) { [void]$g.TexturePaths.Add($nm) }
      $ent = [pscustomobject]@{
        Path     = [string]$nm
        BaseName = [string]$base
        Part     = [string]$parsed.Part
        Offset   = [int]$off
        Length   = [int]$len
        Width    = [int]$wHint
        Height   = [int]$hHint
      }
      [void]$g.Entries.Add($ent)
    }

    foreach ($key in @($groups.Keys | Sort-Object)) {
      $g = $groups[$key]
      $parts = @($g.Parts.ToArray())
      $pref = Get-ShowroomPreferredThumb -kind $g.Kind -parts ([string[]]@($parts))
      $prefPath = $null
      if ($pref) {
        $hit = @($g.Entries | Where-Object { $_.Part -eq $pref } | Select-Object -First 1)
        if ($hit) { $prefPath = $hit[0].Path }
      }
      if (-not $prefPath -and $g.TexturePaths.Count) { $prefPath = $g.TexturePaths[0]; if (-not $pref) { $pref = 'Other' } }

      if ($g.Kind -eq 'bike' -and ($parts -notcontains 'Plastics')) {
        [void]$g.Notes.Add('missing_Plastics')
      }
      if ($g.Kind -eq 'bike' -and ($parts -contains 'Sprockets') -and ($parts.Count -eq 1)) {
        [void]$g.Notes.Add('sprockets_only')
      }

      if ($g.Kind -eq 'gear') {
        $bits = @($g.Model)
        if ($g.Skin) { $bits += $g.Skin }
        if ($parts.Count -eq 1) { $bits += $parts[0] }
        elseif ($pref) { $bits += $pref }
        $disp = ($bits -join ' ')
      } else {
        $disp = if ($g.Skin) { "{0} {1}" -f $g.Model, $g.Skin } else { [string]$g.Model }
      }
      $row = [pscustomobject]@{
        PackFile           = [string]$g.PackFile
        PackPath           = [string]$g.PackPath
        Kind               = [string]$g.Kind
        Model              = [string]$g.Model
        Skin               = [string]$g.Skin
        Parts              = @($parts)
        PreferredThumbPart = $pref
        PreferredThumbPath = $prefPath
        TexturePaths       = @($g.TexturePaths.ToArray())
        Entries            = @($g.Entries.ToArray())
        GroupKey           = [string]$g.GroupKey
        Notes              = @($g.Notes.ToArray())
        DisplayName        = [string]$disp
      }
      [void]$all.Add($row)

    }
  }
  @($all)
}

function Get-ShowroomItemsFromInstalled {
  param([string[]]$NameMatch)
  $packs = @(Installed)
  if ($NameMatch -and $NameMatch.Count) {
    $packs = @($packs | Where-Object {
      $n = $_.Name
      @($NameMatch | Where-Object { $n -match $_ }).Count -gt 0
    })
  }
  Get-ShowroomItems -Pak $packs
}

function Check-Clashes($sel){   # returns $true if OK to add
  $un=@(& $fixer -ListOnly -UnusedReport @($sel | % { $_.FullName }))
  if($un.Count){ Write-Host "`n  NOTE - these files are never loaded by the game (the rest of each pack still works):"
    foreach($l in $un){ $f=$l.Split('|'); $s= if($f[3] -eq '1'){ " -> will be renamed to $(Split-Path $f[2] -Leaf)" } elseif($f[2]){ " (did you mean $(Split-Path $f[2] -Leaf)? rename it by hand)" } else { " (no similar game file)" }
      Write-Host "    $($f[0]): $(Split-Path $f[1] -Leaf)$s" } }
  $have=@{}; foreach($p in (Installed)){ $have[$p.Name]=Get-Labels $p.FullName }
  $found=$false
  for($a=0;$a -lt $sel.Count;$a++){ $mine=Get-Labels $sel[$a].FullName
    $against=@($have.Keys | Sort-Object | % { ,@($_,$have[$_],'installed') }) + @(for($b=0;$b -lt $a;$b++){ ,@($sel[$b].Name,(Get-Labels $sel[$b].FullName),'also being added') })
    $hits=@(); foreach($o in $against){ $same=@($mine | ? { $o[1].Contains($_) }); if($same.Count){ $hits+=,@($o[0],$o[2],$same) } }
    if($hits.Count){ if(-not $found){ Write-Host "`n  CLASH WARNING - only one version of each item will show up in game:" }; $found=$true
      Write-Host "`n  $($sel[$a].Name) clashes with:"
      foreach($h in $hits){ Write-Host "    $($h[0]) ($($h[1]))"; $h[2] | Select -First 6 | % { Write-Host "        - $_" }; if($h[2].Count -gt 6){ Write-Host "        ...and $($h[2].Count-6) more" } } } }
  if(-not $found){ return 'all' }
  $ans=Read-Host "`n  Add them anyway? Y = add all, S = skip the clashing ones, N = cancel [y/s/N]"
  switch -regex ($ans){ '^(y|yes)$' {'all'} '^(s|skip)$' {'skip'} default {'none'} } }
# unused-file report from the fixer: pack name -> list of @(pack, path, suggestion, unique)
function Unused-Map($files){ $map=@{}; $files=@($files); if($files.Count){ foreach($l in @(& $fixer -ListOnly -UnusedReport @($files | % { $_.FullName }))){ $f=$l.Split('|'); if(-not $map.ContainsKey($f[0])){ $map[$f[0]]=@() }; $map[$f[0]]+=,$f } }; $map }
# fix one pack in place: texture headers + unused renames + load-order pack rename (original saved in 'Pack Files\Originals')
# returns the FileInfo after any pack rename, or $null on error
function Fix-Pack($p,[switch]$Loud){ $out=@(& $fixer -ListOnly -FixFile $p.FullName); $h=0; $ren=@(); $left=@(); $renFile=$null; $err=$null
  foreach($l in $out){ $f=$l.Split('|'); switch($f[0]){ 'HDR' { $h=[int]$f[1] } 'REN' { $ren+=,$f } 'RENFILE' { $renFile=$f } 'LEFT' { $left+=,$f } 'ERR' { $err=$f[1] } } }
  if($err){ Write-Host "  COULDN'T FIX $($p.Name): $err"; return $null }
  if($h -or $ren.Count -or $renFile){ $w=@(); if($h){ $w+="$h texture(s)" }; if($ren.Count){ $w+="$($ren.Count) file name(s)" }; if($renFile){ $w+='pack file name' }; Write-Host "  FIXED: $($p.Name) ($($w -join ' + '); original saved in 'Pack Files\Originals')" }
  elseif($Loud -and -not $left.Count -and -not (Needs-LoadOrder $p.Name)){ Write-Host "  nothing to fix: $($p.Name)" }
  foreach($r in $ren){ Write-Host "      renamed $(Split-Path $r[1] -Leaf) -> $(Split-Path $r[2] -Leaf)" }
  if($renFile){ Write-Host "      renamed pack $($renFile[1]) -> $($renFile[2]) (so it loads after common.pak)" }
  foreach($r in $left){ Write-Host "      STILL UNUSED: $(Split-Path $r[1] -Leaf) - needs renaming by hand ($($r[2]))" }
  if($renFile){ $np=Join-Path (Split-Path $p.FullName -Parent) $renFile[2]; if(Test-Path -LiteralPath $np){ return (Get-Item -LiteralPath $np) } }
  $p }
function Needs-LoadOrder($name){ [string]::Compare($name,'common.pak',[StringComparison]::OrdinalIgnoreCase) -lt 0 }
function Suggest-LoadOrderName($folder,$name){
  if(-not (Needs-LoadOrder $name)){ return $name }
  $ext=[IO.Path]::GetExtension($name); $bn=[IO.Path]::GetFileNameWithoutExtension($name)
  $bn = ($bn -replace '^[^A-Za-z0-9]+',''); if(-not $bn){ $bn='pack' }
  $cand = "$bn$ext"
  if(Needs-LoadOrder $cand){ $cand = "z_$bn$ext" }
  while(Needs-LoadOrder $cand){ $cand = "z_$cand" }
  $p=Join-Path $folder $cand; if(-not (Test-Path -LiteralPath $p)){ return $cand }
  $bn2=[IO.Path]::GetFileNameWithoutExtension($cand); $ext2=[IO.Path]::GetExtension($cand); $i=2
  do { $p=Join-Path $folder "$bn2 ($i)$ext2"; $i++ } while(Test-Path -LiteralPath $p)
  Split-Path $p -Leaf
}
# When moving into the game folder, auto-rename so the pack sorts after common.pak.
function Move-Safe($src,$destDir){
  $intoGame = $false; try { $intoGame = ([IO.Path]::GetFullPath($destDir).TrimEnd('\') -eq [IO.Path]::GetFullPath($game).TrimEnd('\')) } catch {}
  $destName = if($intoGame){ Suggest-LoadOrderName $destDir $src.Name } else { $src.Name }
  try {
    Move-Item -LiteralPath $src.FullName -Destination (Join-Path $destDir $destName) -Force -ErrorAction Stop
    if($destName -ne $src.Name){ Write-Host "  (renamed to $destName so it loads after common.pak)" }
    $true
  } catch { Write-Host "  COULDN'T MOVE $($src.Name) - close the game and try again."; $false } }

# ---------- is Open Unleashed running? ----------
function Game-Running { $roots=@(Join-Path $env:APPDATA 'mxa-launcher\clients'); if($game){ $roots+=(Split-Path -Parent $game) }
  foreach($pr in @(Get-Process -ErrorAction SilentlyContinue)){ if($pr.Name -eq 'MXvsATV'){ return $true }
    $pp=$null; try { $pp=$pr.Path } catch {}
    if($pp){ foreach($r in $roots){ if($r -and $pp.StartsWith($r.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){ return $true } } } }
  $false }
function Wait-GameClosed { while(Game-Running){ $a=Read-Host "`nOpen Unleashed is running. Close it, then press Enter (or type C to cancel)"; if($a -match '^(c|cancel)$'){ Write-Host "  Cancelled. Nothing was changed."; return $false } }; $true }

function Load-Preview { if(-not ('OUPreview' -as [type])){ Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;
public static class OUPreview {
  static int I(byte[] b, int o) { return BitConverter.ToInt32(b, o); }
  static void Rgb(int c, out int r, out int g, out int bl) { r = ((c >> 11) & 31) * 255 / 31; g = ((c >> 5) & 63) * 255 / 63; bl = (c & 31) * 255 / 31; }
  static int Argb(int a, int r, int g, int bl) { return (a << 24) | (r << 16) | (g << 8) | bl; }
  // .dxt layout: 24-byte header (+4 format 0x26=DXT1 / 0x36=DXT5, +12 mips, +16 w, +20 h),
  // then one record per mip: int32 w, int32 h, int32 size, size bytes of data. Largest mip is used.
  public static Bitmap Decode(byte[] b, int off, int len, out string info) {
    info = "unreadable";
    if (off < 0 || len < 36 || (long)off + len > b.Length) return null;
    int fmt = I(b, off + 4); bool d1;
    if (fmt == 0x26) d1 = true; else if (fmt == 0x36) d1 = false; else { info = "format 0x" + fmt.ToString("X") + " not supported"; return null; }
    int end = off + len, p = off + 24, bw = 0, bh = 0, bp = -1;
    while (p + 12 <= end) {
      int w = I(b, p), h = I(b, p + 4), s = I(b, p + 8);
      if (s < 0 || (long)p + 12 + s > end) break;
      if (w > 0 && h > 0 && w <= 8192 && h <= 8192) {
        long need = (long)Math.Max(1, (w + 3) / 4) * Math.Max(1, (h + 3) / 4) * (d1 ? 8 : 16);
        if (s >= need && (long)w * h > (long)bw * bh) { bw = w; bh = h; bp = p + 12; }
      }
      p += 12 + s;
    }
    if (bp < 0) { info = "no image data"; return null; }
    int[] px = new int[bw * bh]; int bx = (bw + 3) / 4, by = (bh + 3) / 4, bs = d1 ? 8 : 16;
    int[] col = new int[4]; int[] al = new int[8];
    for (int y = 0; y < by; y++) for (int x = 0; x < bx; x++) {
      int o = bp + (y * bx + x) * bs; long abits = 0;
      if (!d1) {
        al[0] = b[o]; al[1] = b[o + 1];
        if (al[0] > al[1]) { for (int i = 1; i < 7; i++) al[i + 1] = ((7 - i) * al[0] + i * al[1]) / 7; }
        else { for (int i = 1; i < 5; i++) al[i + 1] = ((5 - i) * al[0] + i * al[1]) / 5; al[6] = 0; al[7] = 255; }
        for (int i = 0; i < 6; i++) abits |= ((long)b[o + 2 + i]) << (8 * i);
        o += 8;
      }
      int c0 = b[o] | (b[o + 1] << 8), c1 = b[o + 2] | (b[o + 3] << 8);
      int r0, g0, b0, r1, g1, b1; Rgb(c0, out r0, out g0, out b0); Rgb(c1, out r1, out g1, out b1);
      col[0] = Argb(255, r0, g0, b0); col[1] = Argb(255, r1, g1, b1);
      if (c0 > c1 || !d1) { col[2] = Argb(255, (2 * r0 + r1) / 3, (2 * g0 + g1) / 3, (2 * b0 + b1) / 3); col[3] = Argb(255, (r0 + 2 * r1) / 3, (g0 + 2 * g1) / 3, (b0 + 2 * b1) / 3); }
      else { col[2] = Argb(255, (r0 + r1) / 2, (g0 + g1) / 2, (b0 + b1) / 2); col[3] = 0; }
      uint bits = BitConverter.ToUInt32(b, o + 4);
      for (int i = 0; i < 16; i++) {
        int xx = x * 4 + (i & 3), yy = y * 4 + (i >> 2); if (xx >= bw || yy >= bh) continue;
        int c = col[(int)((bits >> (2 * i)) & 3)];
        if (!d1) c = (c & 0xFFFFFF) | (al[(int)((abits >> (3 * i)) & 7)] << 24);
        px[yy * bw + xx] = c;
      }
    }
    Bitmap bm = new Bitmap(bw, bh, PixelFormat.Format32bppArgb);
    BitmapData bd = bm.LockBits(new Rectangle(0, 0, bw, bh), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
    Marshal.Copy(px, 0, bd.Scan0, px.Length); bm.UnlockBits(bd);
    info = bw + "x" + bh + " " + (d1 ? "DXT1" : "DXT5"); return bm;
  }
  class Tile { public string Name; public string Info; public Bitmap Img; }
  // returns "OK|<tiles>|<skipped>" or "NONE|<skipped>" or "ERR|<reason>"
  public static string MakeSheet(string pak, string outPng, string title) {
    byte[] b = File.ReadAllBytes(pak);
    if (b.Length < 4) return "ERR|not a valid PAK";
    int n = I(b, 0); if (n <= 0 || n > 20000 || 4L + n * 108L > b.Length) return "ERR|not a valid PAK";
    int bas = 4 + n * 108; List<Tile> gear = new List<Tile>(), bikes = new List<Tile>(); List<string> skipped = new List<string>();
    for (int i = 0; i < n; i++) {
      int e = 4 + i * 108; string name = Encoding.ASCII.GetString(b, e, 100); int z = name.IndexOf('\0'); if (z >= 0) name = name.Substring(0, z);
      if (!name.EndsWith(".dxt", StringComparison.OrdinalIgnoreCase)) continue;
      string low = name.ToLowerInvariant().Replace('/', '\\');
      bool isGear = low.Contains("\\rider\\tex\\"), isBike = low.Contains("\\veh\\tex\\"); if (!isGear && !isBike) continue;
      string fn = name.Substring(name.LastIndexOfAny(new char[] { '\\', '/' }) + 1); fn = fn.Substring(0, fn.Length - 4);
      if (fn.EndsWith("_AI", StringComparison.OrdinalIgnoreCase)) continue;
      int off = bas + I(b, e + 100), len = I(b, e + 104);
      string info; Bitmap bm = null;
      try { bm = Decode(b, off, len, out info); } catch (Exception ex) { info = "decode error: " + ex.Message; }
      if (bm == null) { skipped.Add(fn + " (" + info + ")"); continue; }
      if (bm.Width < 64 || bm.Height < 64) { bm.Dispose(); continue; }
      Tile t = new Tile(); t.Name = fn; t.Info = (isGear ? "rider gear  " : "bike  ") + info; t.Img = bm;
      if (isGear) gear.Add(t); else bikes.Add(t);
    }
    List<Tile> tiles = new List<Tile>(gear); tiles.AddRange(bikes);
    if (tiles.Count == 0) return "NONE|" + string.Join("; ", skipped.ToArray());
    int cols = Math.Min(4, tiles.Count), rows = (tiles.Count + cols - 1) / cols;
    int pad = 10, boxW = 400, boxH = 300, capH = 40, titleH = 64, cellW = boxW + 10, cellH = boxH + capH + 10;
    int W = pad + cols * (cellW + pad), H = titleH + rows * (cellH + pad) + pad;
    using (Bitmap sheet = new Bitmap(W, H, PixelFormat.Format24bppRgb))
    using (Graphics g = Graphics.FromImage(sheet))
    using (Font fT = new Font("Segoe UI", 16, FontStyle.Bold), fS = new Font("Segoe UI", 9), fN = new Font("Segoe UI", 9, FontStyle.Bold))
    using (SolidBrush orange = new SolidBrush(Color.FromArgb(255, 140, 0)), grey = new SolidBrush(Color.FromArgb(190, 190, 190)), cell = new SolidBrush(Color.FromArgb(45, 45, 45)), mid = new SolidBrush(Color.FromArgb(128, 128, 128)))
    using (StringFormat sf = new StringFormat(StringFormatFlags.NoWrap)) {
      sf.Trimming = StringTrimming.EllipsisCharacter;
      g.Clear(Color.FromArgb(25, 25, 25)); g.InterpolationMode = InterpolationMode.HighQualityBicubic; g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
      g.DrawString(title, fT, orange, new RectangleF(pad, 6, W - 2 * pad, 32), sf);
      g.DrawString(tiles.Count + " texture(s): rider gear first, then bike. These are the flat texture sheets inside the pack, not in-game renders.", fS, grey, new RectangleF(pad, 40, W - 2 * pad, 20), sf);
      for (int k = 0; k < tiles.Count; k++) {
        Tile t = tiles[k]; int x = pad + (k % cols) * (cellW + pad), y = titleH + (k / cols) * (cellH + pad);
        g.FillRectangle(cell, x, y, cellW, cellH);
        double sc = Math.Min(1.0, Math.Min((double)boxW / t.Img.Width, (double)boxH / t.Img.Height));
        int tw = Math.Max(1, (int)Math.Round(t.Img.Width * sc)), th = Math.Max(1, (int)Math.Round(t.Img.Height * sc));
        int ix = x + 5 + (boxW - tw) / 2, iy = y + 5 + (boxH - th) / 2;
        g.FillRectangle(mid, ix, iy, tw, th);
        g.DrawImage(t.Img, new Rectangle(ix, iy, tw, th));
        g.DrawString(t.Name, fN, Brushes.White, new RectangleF(x + 5, y + boxH + 8, boxW, 18), sf);
        g.DrawString(t.Info, fS, grey, new RectangleF(x + 5, y + boxH + 26, boxW, 18), sf);
        t.Img.Dispose();
      }
      sheet.Save(outPng, ImageFormat.Png);
    }
    return "OK|" + tiles.Count + "|" + string.Join("; ", skipped.ToArray());
  }
}
'@ } }
# ---------- 3D bike previews (Settings\Scripts\3D: OURender.cs + OULiveView.cs + OU3DHost.cs) ----------
# Compiled once per session, lazily, in a background runspace (types land in this AppDomain), so the UI never blocks on Add-Type.
# Any failure leaves OU3DState='failed' and everything falls back to the flat previews.
$script:OU3DDir   = Join-Path $here '3D'
$script:OU3DState = ''      # '' | loading | ready | failed
$script:OU3DError = ''
$script:OU3DPs = $null; $script:OU3DAr = $null
if ($null -eq $script:OU3DPump) { $script:OU3DPump = $false }   # UI sets $true: waits pump WinForms messages
$script:Last3DMade = 0; $script:Last3DFail = 0; $script:Last3DErr = ''
function Start-OU3D {
  if ($script:OU3DState) { return }
  try {
    if (-not $game) { throw 'No game folder set (needs common.pak for the stock bike models).' }
    $files = @('OURender.cs','OULiveView.cs','OU3DHost.cs' | ForEach-Object { Join-Path $script:OU3DDir $_ })
    foreach ($f in $files) { if (-not (Test-Path -LiteralPath $f)) { throw "Missing $f" } }
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript({
      param($files, $gameDir, $prevDir)
      $ErrorActionPreference = 'Stop'
      if (-not ('OU3DHost' -as [type])) { Add-Type -ReferencedAssemblies System.Drawing, System.Windows.Forms -Path $files }
      [OU3DHost]::Init($gameDir, $prevDir)
      [void][OU3DHost]::Warm()
    }).AddArgument($files).AddArgument($game).AddArgument($prevD)
    $script:OU3DPs = $ps
    $script:OU3DAr = $ps.BeginInvoke()
    $script:OU3DState = 'loading'
  } catch { $script:OU3DState = 'failed'; $script:OU3DError = $_.Exception.Message }
}
# ---------- Rider name + number (Showroom / 3D previews put the number on the bike plates) ----------
# Auto-detect from the Open Unleashed save: %USERPROFILE%\AppData\LocalLow\DefaultCompany\MXvsATV\Save\save.json
#   ints."MXA.Rider.Number" (race number) and strings."MXA.Rider.Name" (rider name; fallback strings."MXA.Network.Name").
#   ints."MXA.Rider.FatBar" (bar pad: 1 = FAT BAR round pad, 0 = CROSSBAR block pad; game default 1) and
#   ints."MXA.Rider.HandGuards" (1 = on; game default 0). Same keys/defaults as the game (MXA.Runtime MxaRiderProfile).
#   Only that pad (and hand guards if on) is drawn on Showroom / preview bikes. $script:BarPadOverride ('fatbar' | 'crossbar'
#   | $null = from the save) and $script:HandGuardsOverride ($true | $false | $null = from the save) mirror rider.txt;
#   set them with Set-OUBarPadOverride / Set-OUHandGuardsOverride (persisted). Preview only: save.json is never written.
# Override: Settings\rider.txt  (RiderNumber=auto|<0-999>, RiderName=auto|<text>, ShowNumbers=on|off, BarPad=auto|round|crossbar,
#   HandGuards=auto|on|off). Last detected value: Settings\rider.cache.
# ShowNumbers = the Showroom 'Show numbers' toggle (default on). Make Previews always draws the number (in-game look).
# (rider.txt is separate from settings.txt because Fix-OUPaks rewrites settings.txt.)
$script:RiderCfg   = Join-Path $root 'Settings\rider.txt'
$script:RiderCache = Join-Path $root 'Settings\rider.cache'
$script:RiderSync  = $null   # last applied state (save/cfg mtimes + result), so repeated calls are cheap
$script:BarPadOverride = $null
$script:HandGuardsOverride = $null
function ConvertTo-OUBarPadKey($pad) {
  $v = [string]$pad
  if ($v -match '^(?i)(fat|fatbar|round|1|true)$') { return 'fatbar' }
  if ($v -match '^(?i)(cross|crossbar|block|0|false)$') { return 'crossbar' }
  $null
}
function ConvertTo-OUOnOff($v) {
  if ($null -eq $v) { return $null }
  if ($v -is [bool]) { return $v }
  $t = [string]$v
  if ($t -match '^(?i)(on|1|true|yes)$') { return $true }
  if ($t -match '^(?i)(off|0|false|no)$') { return $false }
  $null
}
function Set-OUBarPadOverride($pad) {
  # 'fatbar' / 'round' | 'crossbar' / 'block' | $null or 'auto' = from the game save. Saved to rider.txt; applies on the next Sync-OURider.
  $ov = Get-OURiderOverride
  Save-OURiderOverride $ov.Number $ov.Name $ov.ShowNumbers (ConvertTo-OUBarPadKey $pad) $ov.HandGuards
}
function Set-OUHandGuardsOverride($on) {
  # $true / 'on' | $false / 'off' | $null or 'auto' = from the game save. Saved to rider.txt; applies on the next Sync-OURider.
  $ov = Get-OURiderOverride
  Save-OURiderOverride $ov.Number $ov.Name $ov.ShowNumbers $ov.BarPad (ConvertTo-OUOnOff $on)
}
function Get-OURiderSavePaths {
  $lo = Join-Path $env:USERPROFILE 'AppData\LocalLow\DefaultCompany\MXvsATV\Save'
  @((Join-Path $lo 'save.json'), (Join-Path $lo 'save.json.bak'))
}
function Read-OUKeyFile([string]$path) {
  $h = @{}
  if ($path -and (Test-Path -LiteralPath $path)) {
    foreach ($l in (Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction SilentlyContinue)) {
      if ($l -match '^\s*([A-Za-z0-9_]+)\s*=(.*)$') { $h[$matches[1]] = $matches[2].Trim() }
    }
  }
  $h
}
function Get-OURiderOverride {
  $h = Read-OUKeyFile $script:RiderCfg
  $n = [string]$h['RiderNumber']; $m = [string]$h['RiderName']
  if (-not $n) { $n = 'auto' }; if (-not $m) { $m = 'auto' }
  $show = -not ([string]$h['ShowNumbers'] -match '^(?i)(off|0|false|no)$')
  $pad = ConvertTo-OUBarPadKey $h['BarPad']; $hg = ConvertTo-OUOnOff $h['HandGuards']
  $script:BarPadOverride = $pad; $script:HandGuardsOverride = $hg
  [pscustomobject]@{ Number = $n; Name = $m; ShowNumbers = $show; BarPad = $pad; HandGuards = $hg }
}
function Set-OURiderShowNumbers([bool]$on) {
  $ov = Get-OURiderOverride
  Set-OURiderOverride $ov.Number $ov.Name $on
}
function Set-OURiderOverride([string]$number, [string]$name, $showNumbers = $null) {
  # Number / name / show toggle; keeps the BarPad / HandGuards overrides already in rider.txt.
  $ov = Get-OURiderOverride
  if ($null -eq $showNumbers) { $showNumbers = $ov.ShowNumbers }
  Save-OURiderOverride $number $name $showNumbers $ov.BarPad $ov.HandGuards
}
function Save-OURiderOverride([string]$number, [string]$name, $showNumbers, $barPad, $handGuards) {
  $showTxt = $(if ([bool]$showNumbers) { 'on' } else { 'off' })
  if (-not $number) { $number = 'auto' }; if (-not $name) { $name = 'auto' }
  $number = $number.Trim(); $name = ($name.Trim() -replace '[\r\n=]', ' ')
  if ($number -ne 'auto') { $d = ($number -replace '[^0-9]', ''); if ($d.Length -gt 3) { $d = $d.Substring(0, 3) }; if ($d -ne '0') { $d = $d.TrimStart('0') }; if (-not $d) { $d = 'auto' }; $number = $d }
  if ($number -ne 'auto') { $nv = 0; if ([int]::TryParse($number, [ref]$nv) -and $nv -gt 999) { $number = '999' } }
  $padKey = ConvertTo-OUBarPadKey $barPad; $padTxt = $(if ($padKey -eq 'fatbar') { 'round' } elseif ($padKey -eq 'crossbar') { 'crossbar' } else { 'auto' })
  $hgOn = ConvertTo-OUOnOff $handGuards; $hgTxt = $(if ($null -eq $hgOn) { 'auto' } elseif ($hgOn) { 'on' } else { 'off' })
  $txt = "# Rider shown on Showroom / preview bikes (preview only; the game save is never changed). auto = read from the Open Unleashed save.`r`n# ShowNumbers = Showroom number toggle (on/off). BarPad = auto|round|crossbar. HandGuards = auto|on|off.`r`nRiderNumber=$number`r`nRiderName=$name`r`nShowNumbers=$showTxt`r`nBarPad=$padTxt`r`nHandGuards=$hgTxt`r`n"
  [IO.File]::WriteAllText($script:RiderCfg, $txt, (New-Object Text.UTF8Encoding($false)))
  $script:BarPadOverride = $padKey; $script:HandGuardsOverride = $hgOn
  $script:RiderSync = $null
}
# Detected (save) values only: Number, Name, Path, Saved. $null when no readable save.
function Get-OURiderFromSave {
  foreach ($p in (Get-OURiderSavePaths)) {
    if (-not (Test-Path -LiteralPath $p)) { continue }
    try {
      $j = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) | ConvertFrom-Json
      if ($j.format -and [string]$j.format -ne 'open-unleashed-save') { continue }
      $num = ''; $nm = ''; $fat = $null; $hg = $null
      if ($j.ints) {
        $v = $j.ints.'MXA.Rider.Number'; if ($null -ne $v) { $num = [string][int]$v }
        $v = $j.ints.'MXA.Rider.FatBar'; if ($null -ne $v) { $fat = ([int]$v -ne 0) }
        $v = $j.ints.'MXA.Rider.HandGuards'; if ($null -ne $v) { $hg = ([int]$v -ne 0) }
      }
      if ($j.strings) { $nm = [string]$j.strings.'MXA.Rider.Name'; if (-not $nm) { $nm = [string]$j.strings.'MXA.Network.Name' } }
      if (-not $num -and -not $nm -and $null -eq $fat -and $null -eq $hg) { continue }
      return [pscustomobject]@{ Number = $num; Name = $nm.Trim(); Path = $p; Saved = [string]$j.saved; FatBar = $fat; HandGuards = $hg }
    } catch { continue }
  }
  $null
}
# Effective rider: override > save > last cache. Source strings say where each value came from.
function Get-OURider([switch]$NoCacheWrite) {
  $ov = Get-OURiderOverride; $det = Get-OURiderFromSave; $cache = Read-OUKeyFile $script:RiderCache
  if ($det -and -not $NoCacheWrite) {
    $want = "Number=$($det.Number)`r`nName=$($det.Name)`r`nSource=$($det.Path)`r`nSaved=$($det.Saved)`r`n"
    if ($null -ne $det.FatBar) { $want += "FatBar=$([int][bool]$det.FatBar)`r`n" }
    if ($null -ne $det.HandGuards) { $want += "HandGuards=$([int][bool]$det.HandGuards)`r`n" }
    try { $have = if (Test-Path -LiteralPath $script:RiderCache) { [IO.File]::ReadAllText($script:RiderCache) } else { '' }
          if ($have -ne $want) { [IO.File]::WriteAllText($script:RiderCache, $want, (New-Object Text.UTF8Encoding($false))) } } catch { }
  }
  $num = ''; $numSrc = 'none'; $nm = ''; $nmSrc = 'none'
  if ($ov.Number -ne 'auto') { $num = $ov.Number; $numSrc = 'Settings override' }
  elseif ($det -and $det.Number) { $num = $det.Number; $numSrc = 'game save' }
  elseif ($cache['Number']) { $num = $cache['Number']; $numSrc = 'cached (save not found)' }
  if ($ov.Name -ne 'auto') { $nm = $ov.Name; $nmSrc = 'Settings override' }
  elseif ($det -and $det.Name) { $nm = $det.Name; $nmSrc = 'game save' }
  elseif ($cache['Name']) { $nm = $cache['Name']; $nmSrc = 'cached (save not found)' }
  # Bar pad / hand guards: override > save > cache > game defaults (fat bar on, hand guards off)
  $sFat = $true; $sFatSrc = 'game default'; $sHg = $false; $sHgSrc = 'game default'
  if ($det -and $null -ne $det.FatBar) { $sFat = [bool]$det.FatBar; $sFatSrc = 'from save' }
  elseif ($cache['FatBar'] -match '^[01]$') { $sFat = ($cache['FatBar'] -eq '1'); $sFatSrc = 'cached' }
  if ($det -and $null -ne $det.HandGuards) { $sHg = [bool]$det.HandGuards; $sHgSrc = 'from save' }
  elseif ($cache['HandGuards'] -match '^[01]$') { $sHg = ($cache['HandGuards'] -eq '1'); $sHgSrc = 'cached' }
  $fat = $sFat; $fatSrc = $sFatSrc; $hg = $sHg; $hgSrc = $sHgSrc
  if ($ov.BarPad) { $fat = ($ov.BarPad -eq 'fatbar'); $fatSrc = 'override' }
  if ($null -ne $ov.HandGuards) { $hg = [bool]$ov.HandGuards; $hgSrc = 'override' }
  [pscustomobject]@{ Number = $num; NumberSource = $numSrc; Name = $nm; NameSource = $nmSrc; ShowNumbers = [bool]$ov.ShowNumbers
    FatBar = $fat; BarPad = $(if ($fat) { 'Round' } else { 'Crossbar' }); BarPadSource = $fatSrc; HandGuards = $hg; HandGuardsSource = $hgSrc
    SaveFatBar = $sFat; SaveFatBarSource = $sFatSrc; SaveHandGuards = $sHg; SaveHandGuardsSource = $sHgSrc
    SavePath = $(if ($det) { $det.Path } else { '' }); DetectedNumber = $(if ($det) { $det.Number } else { [string]$cache['Number'] })
    DetectedName = $(if ($det) { $det.Name } else { [string]$cache['Name'] }) }
}
# Push the effective rider into the 3D renderer. Cheap when nothing changed (mtime check). Returns $true if the plate number changed.
function Get-OUBarPadText {
  # e.g. 'Bar pad: Round (from save)' for the Showroom rail
  $r = $null; if ($script:RiderSync -and $script:RiderSync.Rider) { $r = $script:RiderSync.Rider } else { $r = Get-OURider -NoCacheWrite }
  if (-not $r) { return 'Bar pad: Round (game default)' }
  'Bar pad: {0} ({1})' -f $r.BarPad, $r.BarPadSource
}
function Sync-OURider([switch]$Force) {
  if (-not ('OU3DHost' -as [type])) { return $false }
  $stamp = ''
  foreach ($p in @((Get-OURiderSavePaths)[0], $script:RiderCfg)) { if (Test-Path -LiteralPath $p) { $stamp += [string](Get-Item -LiteralPath $p).LastWriteTimeUtc.Ticks + '|' } else { $stamp += '-|' } }
  if (-not $Force -and $script:RiderSync -and $script:RiderSync.Stamp -eq $stamp) { return $false }
  $r = Get-OURider
  $changed = $false
  try { $changed = [OU3DHost]::SetRider([string]$r.Number, [string]$r.Name, [bool]$r.ShowNumbers) } catch { }
  try { if ([OU3DHost]::SetBarParts([bool]$r.FatBar, [bool]$r.HandGuards)) { $changed = $true } } catch { }
  $script:RiderSync = [pscustomobject]@{ Stamp = $stamp; Rider = $r }
  $changed
}
function Test-OU3DReady([switch]$Wait, [int]$TimeoutMs = 60000) {
  if ($script:OU3DState -eq 'failed') { return $false }
  if ($script:OU3DState -ne 'ready') {
    if (-not $script:OU3DState) { Start-OU3D; if ($script:OU3DState -eq 'failed') { return $false } }
    if (-not $script:OU3DAr.IsCompleted) {
      if (-not $Wait) { return $false }
      $sw = [Diagnostics.Stopwatch]::StartNew()
      while (-not $script:OU3DAr.IsCompleted -and $sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if ($script:OU3DPump) { [System.Windows.Forms.Application]::DoEvents() }
        Start-Sleep -Milliseconds 15
      }
      if (-not $script:OU3DAr.IsCompleted) { return $false }
    }
    try {
      [void]$script:OU3DPs.EndInvoke($script:OU3DAr)
      if ($script:OU3DPs.Streams.Error.Count) { throw $script:OU3DPs.Streams.Error[0].Exception }
      if (-not ('OU3DHost' -as [type])) { throw 'OU3DHost type not visible after compile' }
      $script:OU3DState = 'ready'
    } catch {
      $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
      $script:OU3DState = 'failed'; $script:OU3DError = $e.Message
    } finally { try { $script:OU3DPs.Dispose() } catch {}; $script:OU3DPs = $null; $script:OU3DAr = $null }
    if ($script:OU3DState -ne 'ready') { return $false }
  }
  # Game folder can change from the UI Settings page
  try { if ($game -and [OU3DHost]::GameData -ne $game) { [OU3DHost]::Init($game, $prevD); $script:RiderSync = $null } } catch {}
  # Rider number on the plates (re-reads the save only when it or Settings\rider.txt changed)
  try { [void](Sync-OURider) } catch {}
  $true
}
function Test-Pack3DFresh([string]$pakPath) {
  # True when nothing 3D needs (re)making: fresh previews, no bike slots, or 3D unavailable.
  if ($script:OU3DState -ne 'ready') { return $true }
  try { return [OU3DHost]::AllFresh($pakPath) } catch { return $true }
}
function Save-Pack3DPreviews([string]$pakPath) {
  # Renders <pak>__<Item>__stack.png + __side.png for each *_Plastics slot with a stock model. Returns the OU3DJob or $null.
  $script:Last3DMade = 0; $script:Last3DFail = 0; $script:Last3DErr = ''
  if (-not (Test-OU3DReady -Wait)) { $script:Last3DErr = $script:OU3DError; return $null }
  try {
    if ($script:OU3DPump) {
      $j = [OU3DHost]::MakeForPakAsync($pakPath)
      while (-not $j.Done) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 15 }
    } else { $j = [OU3DHost]::MakeForPak($pakPath) }
    $script:Last3DMade = $j.Made; $script:Last3DFail = $j.Failed; $script:Last3DErr = $j.Errors
    return $j
  } catch { $script:Last3DFail = 1; $script:Last3DErr = $_.Exception.Message; return $null }
}
function Get-Pack3DPreviewFiles([string]$packName) {
  if (-not $packName -or -not (Test-Path -LiteralPath $prevD)) { return @() }
  $pre = [IO.Path]::GetFileNameWithoutExtension($packName) + '__'
  @(Get-ChildItem -LiteralPath $prevD -File -ErrorAction SilentlyContinue | Where-Object { $_.Name.StartsWith($pre, [StringComparison]::OrdinalIgnoreCase) -and $_.Name -match '(?i)__(stack|side)\.png$' })
}
function Make-Previews($sel){ Load-Preview; $made=0; $same=0; $m3=0; $f3=0
  $use3d = Test-OU3DReady -Wait
  if(-not $use3d -and $script:OU3DError){ Write-Host "  (3D previews unavailable: $($script:OU3DError))" }
  foreach($p in $sel){ $out=Join-Path $prevD "$($p.File).png"; $src=Get-Item -LiteralPath $p.FullName
    $flatFresh = (Test-Path -LiteralPath $out) -and (Get-Item -LiteralPath $out).LastWriteTime -gt $src.LastWriteTime
    $need3d = $use3d -and -not (Test-Pack3DFresh $p.FullName)
    if($flatFresh -and -not $need3d){ Write-Host "  already up to date: $($p.File)"; $same++; continue }
    if(-not $flatFresh){
    Write-Host "  working on $($p.File)..." -NoNewline
    try { $r=[OUPreview]::MakeSheet($p.FullName,$out,$p.File) } catch { $r="ERR|$($_.Exception.InnerException.Message)$($_.Exception.Message)" }
    $f=$r.Split('|')
    if($f[0] -eq 'OK'){ Write-Host " done ($($f[1]) texture(s))"; $made++; if($f[2]){ Write-Host "      skipped: $($f[2])" } }
    elseif($f[0] -eq 'NONE'){ Write-Host " no bike or rider gear textures to show"; if($f[1]){ Write-Host "      skipped: $($f[1])" } }
    else { Write-Host " COULDN'T MAKE A PREVIEW: $($f[1])" } }
    if($need3d){ Write-Host "  3D bike previews for $($p.File)..." -NoNewline
      $j = Save-Pack3DPreviews $p.FullName
      $m3 += $script:Last3DMade; $f3 += $script:Last3DFail
      if($j){ Write-Host (" {0} made ({1} ms)" -f $j.Made, $j.Ms) } else { Write-Host " skipped" }
      if($script:Last3DErr){ Write-Host "      3D problems: $($script:Last3DErr)" } } }
  Write-Host "`n  $made preview(s) made, $same already up to date, $m3 3D bike preview(s) made$(if($f3){", $f3 3D failed"}). Saved in 'Pack Manager\Previews'."
  $script:LastMake3D = $m3; $script:LastMake3DFail = $f3
  # no longer open Previews folder after Make-Previews
}

# ---------- loadouts ----------
function Loadouts { @(Get-ChildItem -LiteralPath $loadD -File | ? { $_.Extension -ieq '.txt' } | sort Name) }
function Read-Loadout($f){ @(Get-Content -LiteralPath $f.FullName -Encoding UTF8 | % { $_.Trim() } | ? { $_ -and -not $_.StartsWith('#') -and ($STOCK -notcontains $_.ToLower()) } | select -Unique) }
function Save-Loadout { $inst=Installed
  $nm=Read-Host "`n  Name for this loadout (e.g. Spider-Man setup), Enter to cancel"; $nm=($nm -replace '[\\/:*?"<>|]','').Trim()
  if(-not $nm){ Write-Host "  Cancelled."; return }
  $path=Join-Path $loadD "$nm.txt"
  if(Test-Path -LiteralPath $path){ $a=Read-Host "  '$nm' already exists. Replace it? [y/N]"; if($a -notmatch '^(y|yes)$'){ Write-Host "  Cancelled."; return } }
  $lines=@("# Open Unleashed loadout: $nm","# Saved $(Get-Date -Format 'yyyy-MM-dd h:mm tt'). One pack file name per line.") + @($inst | % { $_.Name })
  Set-Content -LiteralPath $path -Value $lines -Encoding UTF8
  Write-Host "  SAVED '$nm' with $($inst.Count) pack(s)."; if(-not $inst.Count){ Write-Host "  (It's empty, so loading it turns every custom pack off.)" } }
function Load-Loadout { $lo=Loadouts; if(-not $lo.Count){ Write-Host "`n  No loadouts saved yet."; return }
  Write-Host "`nLoadouts:"; $pick=@(Pick $lo 'load (pick one)'); if(-not $pick.Count){ return }; $f=$pick[0]
  $want=Read-Loadout $f; $name=$f.BaseName
  if(-not (Wait-GameClosed)){ return }
  Write-Host "`n  Loading '$name' ($($want.Count) pack(s))..."
  $off=0; $on=0; $kept=0; $missing=@()
  foreach($p in (Installed)){ if($want -notcontains $p.Name){ if(Move-Safe $p $disD){ Write-Host "  removed: $($p.Name)"; $off++ } } }
  $nowIn=@(Installed | % { $_.Name }); $dis=Disabled
  foreach($w in $want){
    if($nowIn -contains $w){ $kept++; continue }
    $p=$dis | ? { $_.Name -ieq $w } | select -First 1
    if(-not $p){ $missing+=$w; continue }
    $fixed=Fix-Pack $p; if(-not $fixed){ continue }
    if(Move-Safe $fixed $game){ Write-Host "  ADDED: $($fixed.Name)"; $on++ } }
  Refresh-List
  Write-Host "`n  '$name' loaded: $on added, $off removed, $kept were already in the game."
  if($missing.Count){ Write-Host "  NOT FOUND in the game or 'Pack Files\Disabled' (put them in 'Pack Files\Disabled' and load again):"; $missing | % { Write-Host "    - $_" } }
  $cl=@(Get-Content -LiteralPath ($listTxt) -Encoding UTF8 | ? { $_ -match '^  \[\d+\] ' }).Count
  if($cl){ Write-Host "  Note: $cl clashing item(s) in this loadout. Details: option 1 or Installed Packs.txt." } }
function List-Loadouts { $lo=Loadouts; if(-not $lo.Count){ Write-Host "`n  No loadouts saved yet."; return }
  $inG=@(Installed | % { $_.Name }); $inD=@(Disabled | % { $_.Name })
  foreach($f in $lo){ $w=Read-Loadout $f; Write-Host "`n  $($f.BaseName)  ($($w.Count) pack(s))"
    foreach($x in $w){ $st= if($inG -contains $x){'in game'} elseif($inD -contains $x){'disabled'} else {'MISSING'}; Write-Host ("      [{0}] {1}" -f $st,$x) }
    if(-not $w.Count){ Write-Host "      (empty: no custom packs)" } } }
function Loadout-Menu { while($true){
  Write-Host "`n----- LOADOUTS (saved sets of packs) -----"
  Write-Host "  1. Save the packs installed now as a loadout"
  Write-Host "  2. Load a loadout (swaps your installed packs to match it)"
  Write-Host "  3. List loadouts"
  Write-Host "  4. Delete loadouts"
  Write-Host "  5. Back"
  switch(Read-Host "`nChoose"){
    '1' { Save-Loadout }
    '2' { Load-Loadout }
    '3' { List-Loadouts }
    '4' { $lo=Loadouts; if(-not $lo.Count){ Write-Host "`n  No loadouts saved yet." } else { Write-Host "`nLoadouts:"; foreach($f in (Pick $lo 'delete')){ Remove-Item -LiteralPath $f.FullName; Write-Host "  DELETED: $($f.BaseName)" } } }
    '5' { return }
    default { } } } }

if(-not $script:OuAsLibrary){ while($true){
  $inst=Installed; $dis=Disabled
  $um=Unused-Map $inst
  $broken=@($inst | ? { (Count-Broken $_.FullName) -gt 0 -or $um.ContainsKey($_.Name) -or (Needs-LoadOrder $_.Name) })
  Write-Host "`n===== OPEN UNLEASHED PACK MANAGER ====="
  Write-Host "Game folder: $game"
  Write-Host "Installed custom packs: $($inst.Count)   Disabled: $($dis.Count)   Installed but broken: $($broken.Count)`n"
  Write-Host "  1. Show installed packs"
  Write-Host "  2. Remove packs from the game (moves them to 'Pack Files\Disabled')"
  Write-Host "  3. Add packs to the game (from 'Pack Files\Disabled', fixed automatically)"
  Write-Host "  4. Fix broken packs that are already installed (headers + unused names + load order)"
  Write-Host "  5. Make previews (pictures of each pack's textures, saved in 'Pack Manager\Previews')"
  Write-Host "  6. Loadouts (save and swap whole sets of packs)"
  Write-Host "  7. Run the fixer (fix packs in Pack Files\Broken, same as FIX PAKS.bat)"
  Write-Host "  8. Change game folder (same setting the fixer uses)"
  Write-Host "  9. Quit"
  $c=Read-Host "`nChoose"
  switch($c){
    '1' { Write-Host ""; Refresh-List; $txt=$listTxt
          if(-not $inst.Count){ Write-Host "  (no custom packs installed)" }
          else { $all=Get-Content -LiteralPath $txt -Encoding UTF8
            $all | ? { $_ -match '^Tags:' } | % { Write-Host ("  " + ($_ -replace '\(see CLASHES above\)','(details: option 1 or Installed Packs.txt)') + "`n") }
            $all | ? { $_ -match '^=== (.+) ===$' } | % { Write-Host "  $($matches[1])" }
            if($all -match '^\s+\[\d+\] '){ Write-Host "`n  Clashing items are listed at the top of 'Installed Packs.txt' (in Pack Manager)." } } }
    '2' { if(-not (Wait-GameClosed)){ continue }; $tags=Get-Tags; Write-Host "`nInstalled packs:"; $txt=$listTxt; Get-Content -LiteralPath $txt -Encoding UTF8 | ? { $_ -match '^Tags:' } | % { Write-Host ("  " + ($_ -replace '\(see CLASHES above\)','(details: option 1 or Installed Packs.txt)') + "`n") }; foreach($p in (Pick $inst 'remove' $tags)){ if(Move-Safe $p $disD){ Write-Host "  REMOVED: $($p.Name)" } }; Refresh-List }
    '3' { if(-not (Wait-GameClosed)){ continue }; Write-Host "`nDisabled packs (you can also drop new .pak files into 'Pack Files\Disabled' first):"
          $sel=@(Pick $dis 'add'); $go='all'
          if($sel.Count){ $go=Check-Clashes $sel }
          if($go -eq 'none'){ Write-Host "  Cancelled. Nothing was added."; $sel=@() }
          elseif($go -eq 'skip'){ $instNow=New-Object System.Collections.Generic.List[string]; foreach($ip in (Installed)){ foreach($x in (Get-Labels $ip.FullName)){ $instNow.Add($x) } }; $keep=@(); $taken=New-Object System.Collections.Generic.List[string]
            foreach($p in $sel){ $l=Get-Labels $p.FullName; if(@($l | ? { $instNow.Contains($_) -or $taken.Contains($_) }).Count){ Write-Host "  skipped (clashes): $($p.Name)" } else { $keep+=$p; $l | % { $taken.Add($_) } } }
            $sel=$keep }
          foreach($p in $sel){ $fixed=Fix-Pack $p; if(-not $fixed){ continue }
            if(Move-Safe $fixed $game){ Write-Host "  ADDED: $($fixed.Name)" } }; Refresh-List }
    '4' { if(-not $broken.Count){ Write-Host "`nNo broken packs installed." } elseif(Wait-GameClosed) { Write-Host "`nBroken installed packs and why:"
            foreach($p in $broken){ $why=@(); $c=Count-Broken $p.FullName; if($c -gt 0){ $why+="$c texture(s) need their header fixed" }
              foreach($u in @($um[$p.Name])){ if(-not $u){continue}; $why+= "unused file $(Split-Path $u[1] -Leaf) " + $(if($u[3] -eq '1'){"(will be renamed to $(Split-Path $u[2] -Leaf))"} elseif($u[2]){"(needs renaming by hand; did you mean $(Split-Path $u[2] -Leaf)?)"} else {"(needs renaming by hand; no similar game file)"}) }
              if(Needs-LoadOrder $p.Name){ $why+="name sorts before common.pak (will be renamed to $(Suggest-LoadOrderName $game $p.Name))" }
              Write-Host "  $($p.Name)"; $why | % { Write-Host "      - $_" } }
            Write-Host ""
            foreach($p in (Pick $broken 'fix' (Get-Tags))){ try { [void](Fix-Pack $p -Loud) } catch { Write-Host "  COULDN'T FIX $($p.Name) - close the game and try again." } }; Refresh-List } }
    '5' { $items=@(); foreach($p in $inst){ $items+=[pscustomobject]@{Name=$p.Name;FullName=$p.FullName;File=$p.Name} }
          foreach($p in $dis){ $items+=[pscustomobject]@{Name="$($p.Name)   (in 'Pack Files\Disabled')";FullName=$p.FullName;File=$p.Name} }
          Write-Host "`nPacks to preview (installed first, then 'Pack Files\Disabled'):"
          $sel=@(Pick $items 'preview'); if($sel.Count){ Write-Host ""; Make-Previews $sel } }
    '6' { Loadout-Menu }
    '7' { if(Wait-GameClosed){ & $fixer; Refresh-List; Write-Host "`n  Back in MANAGE PACKS." } }
    '8' { & $fixer -ChangeFolder -ListOnly | Out-Null; $g=Get-Game; if($g){ $game=$g; Write-Host "
Game folder is now: $game" } }
    '9' { return }
    default { }
  }
}
} # end interactive menu (skipped when dot-sourced by OU-UI)
