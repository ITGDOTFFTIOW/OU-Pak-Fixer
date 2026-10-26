# Open Unleashed PAK Fixer
# Fixes old MX vs ATV Unleashed skin packs that show white/stock in Open Unleashed by
# patching each texture's aspect-ratio header (e.g. "1:0" -> "2:1").
# 1) Put packs in "Pack Files\Broken"  2) run FIX PAKS.bat
# Fixed copies go to "Pack Files\Fixed" (a copy stays there after install); originals go to "Pack Files\Originals".
# "Pack Manager\Installed Packs.txt" lists every custom pack in your game and what it replaces.
param([switch]$ChangeFolder,[switch]$ListOnly,[string[]]$UnusedReport,[string]$FixFile,[switch]$NoPrompt,[ValidateSet('ask','yes','no')]$InstallMode='ask',[string[]]$OnlyPacks)
$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$root    = (Resolve-Path (Join-Path $here '..\..')).Path
if(-not (Test-Path -LiteralPath (Join-Path $root 'FIX PAKS.bat'))){ throw "Pak Fixer root not found (expected FIX PAKS.bat). Scripts: $here" }
$broken  = Join-Path $root 'Pack Files\Broken'
$disD    = Join-Path $root 'Pack Files\Disabled'
$fixedD  = Join-Path $root 'Pack Files\Fixed'
$orig    = Join-Path $root 'Pack Files\Originals'
$cfg     = Join-Path $root 'Settings\settings.txt'
$listTxt = Join-Path $root 'Pack Manager\Installed Packs.txt'
foreach($p in $broken,$fixedD,$disD,$orig,(Split-Path $listTxt -Parent)){ New-Item -ItemType Directory -Force $p | Out-Null }

$STOCK = 'aud,common,env,fs01,fs02,fs03,fs04,fs05,fs06,fs07,fs08,fs09,fs10,fs11,fs12,fs13,mc01,mc02,mc03,mc04,mc05,mc06,mc07,mc08,mc09,mc10,mst,nat01,nat02,nat03,nat04,nat05,nat06,nat07,nat08,nat09,nat10,nat11,nat12,nat13,nat14,nat15,nat16,nat17,nat18,nat19,sm01,sm02,sm03,sx01,sx02,sx03,sx04,sx05,sx06,sx07,sx08,sx09,sx10,sx11,sx12,sx13,sx14,sx15,sx16,sx17,sx18,sx19,sx20,tex,ui'.Split(',') | ForEach-Object { "$_.pak" }

# ---------- find the game's data folder ----------
function Test-GameData($p){ $p -and (Test-Path -LiteralPath (Join-Path $p 'common.pak')) }
function Find-GameData {
  $libs=@()
  foreach($k in 'HKCU:\Software\Valve\Steam','HKLM:\SOFTWARE\WOW6432Node\Valve\Steam'){
    $v=(Get-ItemProperty -Path $k -ErrorAction SilentlyContinue); if($v.SteamPath){$libs+=$v.SteamPath}; if($v.InstallPath){$libs+=$v.InstallPath} }
  $libs+="${env:ProgramFiles(x86)}\Steam"
  foreach($s in @($libs)){ $vdf=Join-Path $s 'steamapps\libraryfolders.vdf'
    if(Test-Path -LiteralPath $vdf){ foreach($m in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw),'"path"\s+"([^"]+)"')){ $libs+=($m.Groups[1].Value -replace '\\\\','\') } } }
  foreach($l in ($libs | Select-Object -Unique)){ $c=Join-Path $l 'steamapps\common\MX vs. ATV Unleashed\data'; if(Test-GameData $c){ return $c } }
  $null }
function Pick-GameData {
  Add-Type -AssemblyName System.Windows.Forms
  $d=New-Object System.Windows.Forms.FolderBrowserDialog
  $d.Description='Pick your MX vs. ATV Unleashed "data" folder (the one with common.pak in it)'
  while($d.ShowDialog() -eq 'OK'){
    $p=$d.SelectedPath; if(-not (Test-GameData $p) -and (Test-GameData (Join-Path $p 'data'))){ $p=Join-Path $p 'data' }
    if(Test-GameData $p){ return $p }
    [System.Windows.Forms.MessageBox]::Show("That folder doesn't have common.pak in it. Pick the game's data folder.") | Out-Null }
  $null }
$game=$null
if(Test-Path -LiteralPath $cfg){ $line=Get-Content -LiteralPath $cfg | Where-Object { $_ -like 'GameDataFolder=*' } | Select-Object -First 1; if($line){ $game=$line.Substring(15) } }
if($ChangeFolder -or -not (Test-GameData $game)){
  $auto= if($ChangeFolder){$null}else{Find-GameData}
  if($auto){ $game=$auto }
  else { if(-not $ChangeFolder){ Write-Host "Couldn't find your game automatically. Pick its data folder in the window that opens..." }
         # OU-UI sets OU_PAKFIXER_NOPICK: never open a dialog from inside this script while the window app is running
         # (its paint handlers would run in this script's scope and fail). The app has its own Change picker.
         $picked= if($env:OU_PAKFIXER_NOPICK -and -not $ChangeFolder){ $null } else { Pick-GameData }; if($picked){ $game=$picked } elseif(-not (Test-GameData $game)){ $game=$null } }
  if($game){ Set-Content -LiteralPath $cfg -Value "GameDataFolder=$game" }
}
if($game){ if(-not $ListOnly){ Write-Host "Game data folder: $game"; Write-Host "(Wrong folder? Run Settings\CHANGE GAME FOLDER.bat)`n" } } else { Write-Host "No game folder set, so the installed-packs list will be skipped.`n" }
if($ChangeFolder -and -not ((Get-ChildItem -LiteralPath $broken -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ieq '.pak' }))){ }

# ---------- PAK helpers ----------
function Gcd($a,$b){ while($b){ $t=$b; $b=$a % $b; $a=$t }; $a }
function Read-Pak($path){ $b=[IO.File]::ReadAllBytes($path); if($b.Length -lt 4){return $null}; $n=[BitConverter]::ToInt32($b,0)
  if($n -le 0 -or $n -gt 20000 -or 4+$n*108 -gt $b.Length){return $null}; @{Bytes=$b;Count=$n;Base=4+$n*108} }
function FreeName($folder,$name){ $p=Join-Path $folder $name; if(-not (Test-Path -LiteralPath $p)){ return $p }
  $bn=[IO.Path]::GetFileNameWithoutExtension($name); $ext=[IO.Path]::GetExtension($name); $i=2
  do { $p=Join-Path $folder "$bn ($i)$ext"; $i++ } while(Test-Path -LiteralPath $p); $p }
# Open Unleashed only shows a custom pack when its file name sorts AFTER common.pak
# (OrdinalIgnoreCase). Names starting with $ or other symbols load under stock and stay invisible.
function Needs-LoadOrder($name){ [string]::Compare($name,'common.pak',[StringComparison]::OrdinalIgnoreCase) -lt 0 }
function Suggest-LoadOrderName($folder,$name){
  if(-not (Needs-LoadOrder $name)){ return $name }
  $ext=[IO.Path]::GetExtension($name); $bn=[IO.Path]::GetFileNameWithoutExtension($name)
  $bn = ($bn -replace '^[^A-Za-z0-9]+',''); if(-not $bn){ $bn='pack' }
  $cand = "$bn$ext"
  if(Needs-LoadOrder $cand){ $cand = "z_$bn$ext" }
  while(Needs-LoadOrder $cand){ $cand = "z_$cand" }
  Split-Path (FreeName $folder $cand) -Leaf
}
# returns number of broken textures; patches them in $pk.Bytes when -Fix
function Fix-Pak($pk,[switch]$Fix){ $b=$pk.Bytes; $c=0
  for($i=0;$i -lt $pk.Count;$i++){ $e=4+$i*108; $nm=[Text.Encoding]::ASCII.GetString($b,$e,100).Split([char]0)[0]
    if($nm -notmatch '(?i)\.dxt$'){continue}
    $h=$pk.Base+[BitConverter]::ToInt32($b,$e+100); if($h -lt 0 -or $h+32 -gt $b.Length){continue}
    $w=[BitConverter]::ToInt32($b,$h+16); $ht=[BitConverter]::ToInt32($b,$h+20)
    if($w -le 0 -or $ht -le 0 -or [BitConverter]::ToInt32($b,$h+28) -ne 0){continue}
    if($Fix){ $g=Gcd $w $ht; [BitConverter]::GetBytes([int]($w/$g)).CopyTo($b,$h+24); [BitConverter]::GetBytes([int]($ht/$g)).CopyTo($b,$h+28) }
    $c++ }
  $c }

# ---------- UNUSED files: names the game never loads (e.g. a typo like 'Spockets') ----------
# The stock file list comes from the game's own paks and is cached in stock-names.cache
# (rebuilt automatically when any stock pak changes).
$CACHE = Join-Path $here 'stock-names.cache'
function Load-OUStock { if(-not ('OUStock' -as [type])){ Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
public static class OUStock {
  public static string Norm(string p) { return p.Replace('/', '\\').Trim(); }
  static string Base(string p) { string f = p.Substring(p.LastIndexOfAny(new char[] { '\\', '/' }) + 1); int d = f.LastIndexOf('.'); return d > 0 ? f.Substring(0, d) : f; }
  static string Ext(string p) { string f = p.Substring(p.LastIndexOfAny(new char[] { '\\', '/' }) + 1); int d = f.LastIndexOf('.'); return d >= 0 ? f.Substring(d).ToLowerInvariant() : ""; }
  static string Dir(string p) { int s = p.LastIndexOf('\\'); return s >= 0 ? p.Substring(0, s) : ""; }
  public static bool IsRefFile(string name) { string l = name.ToLowerInvariant(); return l.EndsWith(".sub") || l.EndsWith(".dxm") || l.EndsWith("\\vehicles.dat") || l.EndsWith("\\riders.dat"); }
  static void Add(HashSet<string> r, string v) { v = v.Trim().Trim('"').Trim(); if (v.Length == 0) return; string e = Ext(v); string b = (e == ".dxt" || e == ".sub" || e == ".dxm") ? Base(v) : v.Substring(v.LastIndexOfAny(new char[] { '\\', '/' }) + 1); r.Add(b); }
  // .sub [Material Changes] right-hand sides, .dxm TextureMap_n, Vehicles.dat sub=, Riders.dat Uniform=/Bike*=
  public static void AddRefs(string name, string text, HashSet<string> refs) {
    string l = name.ToLowerInvariant(); bool sub = l.EndsWith(".sub"), dxm = l.EndsWith(".dxm"), dat = l.EndsWith(".dat"); bool inMC = false;
    foreach (string raw in text.Split('\n')) {
      string s = raw; int c = s.IndexOf(';'); if (c >= 0) s = s.Substring(0, c); s = s.Trim(); if (s.Length == 0) continue;
      if (s.StartsWith("[")) { inMC = s.Equals("[Material Changes]", StringComparison.OrdinalIgnoreCase); continue; }
      int eq = s.IndexOf('='); if (eq < 0) continue; string k = s.Substring(0, eq).Trim(), v = s.Substring(eq + 1);
      if (sub && inMC) Add(refs, v);
      else if (dxm && k.StartsWith("TextureMap_", StringComparison.OrdinalIgnoreCase)) Add(refs, v);
      else if (dat && (k.Equals("sub", StringComparison.OrdinalIgnoreCase) || k.Equals("Uniform", StringComparison.OrdinalIgnoreCase) || k.StartsWith("Bike", StringComparison.OrdinalIgnoreCase))) Add(refs, v);
    }
  }
  public static void ScanFile(string pak, HashSet<string> paths, HashSet<string> refs) {
    using (FileStream fs = File.OpenRead(pak)) {
      BinaryReader br = new BinaryReader(fs); if (fs.Length < 4) return; int n = br.ReadInt32(); if (n <= 0 || n > 200000 || 4L + n * 108L > fs.Length) return;
      byte[] h = br.ReadBytes(n * 108); long bas = 4L + n * 108L;
      for (int i = 0; i < n; i++) {
        string nm = Encoding.ASCII.GetString(h, i * 108, 100); int z = nm.IndexOf('\0'); if (z >= 0) nm = nm.Substring(0, z); if (nm.Length == 0) continue;
        paths.Add(Norm(nm));
        if (!IsRefFile(nm)) continue;
        int off = BitConverter.ToInt32(h, i * 108 + 100), size = BitConverter.ToInt32(h, i * 108 + 104);
        if (off < 0 || size <= 0 || size > 4000000 || bas + off + size > fs.Length) continue;
        fs.Seek(bas + off, SeekOrigin.Begin); AddRefs(nm, Encoding.ASCII.GetString(br.ReadBytes(size)), refs);
      }
    }
  }
  public static void PackRefs(byte[] b, int n, HashSet<string> refs) {
    int bas = 4 + n * 108;
    for (int i = 0; i < n; i++) {
      int e = 4 + i * 108; string nm = Encoding.ASCII.GetString(b, e, 100); int z = nm.IndexOf('\0'); if (z >= 0) nm = nm.Substring(0, z);
      if (!IsRefFile(nm)) continue; int off = BitConverter.ToInt32(b, e + 100), size = BitConverter.ToInt32(b, e + 104);
      if (off < 0 || size <= 0 || (long)bas + off + size > b.Length) continue;
      AddRefs(nm, Encoding.ASCII.GetString(b, bas + off, size), refs);
    }
  }
  public static bool IsUsed(HashSet<string> paths, HashSet<string> refs, HashSet<string> packRefs, string name) {
    string p = Norm(name); if (paths.Contains(p)) return true;
    string e = Ext(p); if (e == ".dxt" || e == ".dxm" || e == ".sub") { string b = Base(p); if (refs.Contains(b) || packRefs.Contains(b)) return true; }
    return false;
  }
  public static int Lev(string a, string b) {
    a = a.ToLowerInvariant(); b = b.ToLowerInvariant(); int[] prev = new int[b.Length + 1], cur = new int[b.Length + 1];
    for (int j = 0; j <= b.Length; j++) prev[j] = j;
    for (int i = 1; i <= a.Length; i++) { cur[0] = i; for (int j = 1; j <= b.Length; j++) { int c = a[i - 1] == b[j - 1] ? 0 : 1; cur[j] = Math.Min(Math.Min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + c); } int[] t = prev; prev = cur; cur = t; }
    return prev[b.Length];
  }
  // closest stock file in the same folder with the same extension (distance <= max on the base name), or null
  public static string Suggest(HashSet<string> paths, string name, int max) {
    string p = Norm(name), d = Dir(p), e = Ext(p), b = Base(p); string best = null; int bd = max + 1;
    foreach (string s in paths) {
      if (Ext(s) != e || !Dir(s).Equals(d, StringComparison.OrdinalIgnoreCase)) continue;
      string sb = Base(s); if (Math.Abs(sb.Length - b.Length) > max) continue;
      int v = Lev(sb, b); if (v < bd || (v == bd && best != null && string.CompareOrdinal(s, best) < 0)) { bd = v; best = s; }
    }
    return best;
  }
  // same as Suggest, but only when exactly one stock file is closest (safe to rename to)
  public static string SuggestUnique(HashSet<string> paths, string name, int max) {
    string p = Norm(name), d = Dir(p), e = Ext(p), b = Base(p); string best = null; int bd = max + 1, n = 0;
    foreach (string s in paths) {
      if (Ext(s) != e || !Dir(s).Equals(d, StringComparison.OrdinalIgnoreCase)) continue;
      string sb = Base(s); if (Math.Abs(sb.Length - b.Length) > max) continue;
      int v = Lev(sb, b); if (v < bd) { bd = v; best = s; n = 1; } else if (v == bd && best != null) n++;
    }
    return n == 1 ? best : null;
  }
  public static void LoadCache(string[] lines, HashSet<string> paths, HashSet<string> refs) {
    for (int i = 1; i < lines.Length; i++) { string l = lines[i]; if (l.Length < 3) continue; if (l[0] == 'P') paths.Add(l.Substring(2)); else if (l[0] == 'R') refs.Add(l.Substring(2)); }
  }
  public static void SaveCache(string file, string sig, HashSet<string> paths, HashSet<string> refs) {
    List<string> L = new List<string>(); L.Add(sig);
    foreach (string p in paths) L.Add("P\t" + p); foreach (string r in refs) L.Add("R\t" + r);
    File.WriteAllLines(file, L.ToArray(), new UTF8Encoding(false));
  }
}
'@ } }
$script:SI=$null
function Get-StockIndex { if($script:SI){ return $script:SI }
  Load-OUStock
  $files=@(Get-ChildItem -LiteralPath $game -File | Where-Object { $STOCK -contains $_.Name.ToLower() } | Sort-Object Name)
  $sig="SIG v1|$game|" + (($files | ForEach-Object { "$($_.Name.ToLower()):$($_.Length):$($_.LastWriteTimeUtc.Ticks)" }) -join ';')
  $paths=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $refs =New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $ok=$false
  if(Test-Path -LiteralPath $CACHE){ try { $L=[IO.File]::ReadAllLines($CACHE); if($L.Count -and $L[0] -eq $sig){ [OUStock]::LoadCache($L,$paths,$refs); $ok=$true } } catch {} }
  if(-not $ok){ foreach($f in $files){ try { [OUStock]::ScanFile($f.FullName,$paths,$refs) } catch {} }
    try { [OUStock]::SaveCache($CACHE,$sig,$paths,$refs) } catch {} }
  $script:SI=@{Paths=$paths;Refs=$refs;N=$files.Count}; $script:SI }
# every entry in the pack the game will never load: @{Index;Path;Sug;Uniq}
function Get-Unused($pk){ $out=New-Object System.Collections.Generic.List[object]; if(-not (Test-GameData $game)){ return $out }; $si=Get-StockIndex; if($si.N -le 0){ return $out }
  $pr=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase); [OUStock]::PackRefs($pk.Bytes,$pk.Count,$pr)
  for($i=0;$i -lt $pk.Count;$i++){ $nm=[Text.Encoding]::ASCII.GetString($pk.Bytes,4+$i*108,100).Split([char]0)[0]; if(-not $nm){continue}
    if($nm -match '(?i)(^|[\\/])(desktop|thumbs)\.[^\\/]*$'){continue}
    if([OUStock]::IsUsed($si.Paths,$si.Refs,$pr,$nm)){continue}
    $null=$out.Add(@{Index=$i;Path=$nm;Sug=[OUStock]::Suggest($si.Paths,$nm,3);Uniq=[bool]([OUStock]::SuggestUnique($si.Paths,$nm,3))}) }
  $out }
# rename unused entries to their single closest game file name (in $pk.Bytes). Never renames when the match isn't unique.
function Rename-Unused($pk){ $done=New-Object System.Collections.Generic.List[object]; $left=New-Object System.Collections.Generic.List[object]; $un=Get-Unused $pk
  if($un.Count){ $have=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    for($i=0;$i -lt $pk.Count;$i++){ [void]$have.Add([OUStock]::Norm([Text.Encoding]::ASCII.GetString($pk.Bytes,4+$i*108,100).Split([char]0)[0])) }
    foreach($u in $un){
      if(-not $u.Uniq){ $null=$left.Add(@{Path=$u.Path;Why=$(if($u.Sug){'more than one game file is just as close'}else{'no game file with a similar name'})}); continue }
      if($have.Contains($u.Sug)){ $null=$left.Add(@{Path=$u.Path;Why="the pack already has $(Split-Path $u.Sug -Leaf)"}); continue }
      if($u.Sug.Length -gt 99){ $null=$left.Add(@{Path=$u.Path;Why='name too long'}); continue }
      $nb=New-Object byte[] 100; $sb=[Text.Encoding]::ASCII.GetBytes($u.Sug); [Array]::Copy($sb,$nb,$sb.Length); [Array]::Copy($nb,0,$pk.Bytes,4+$u.Index*108,100)
      [void]$have.Add($u.Sug); $null=$done.Add(@{Old=$u.Path;New=$u.Sug}) } }
  @{Done=$done;Left=$left} }

# ---------- quiet modes used by MANAGE PACKS ----------
if($UnusedReport){ foreach($p in $UnusedReport){ $pk=Read-Pak $p; if($pk){ foreach($u in (Get-Unused $pk)){ "$(Split-Path $p -Leaf)|$($u.Path)|$($u.Sug)|$(if($u.Uniq){1}else{0})" } } }; return }
if($FixFile){ $pk=Read-Pak $FixFile; if(-not $pk){ "ERR|not a valid PAK"; return }
  $c=Fix-Pak $pk -Fix; $r=Rename-Unused $pk
  $oldName=Split-Path $FixFile -Leaf; $dir=Split-Path $FixFile -Parent
  $newName=Suggest-LoadOrderName $dir $oldName; $needRename= $newName -ne $oldName
  if($c -or $r.Done.Count -or $needRename){ try {
      Copy-Item -LiteralPath $FixFile -Destination (FreeName $orig $oldName) -ErrorAction Stop
      if($c -or $r.Done.Count){ [IO.File]::WriteAllBytes($FixFile,$pk.Bytes) }
      if($needRename){ Move-Item -LiteralPath $FixFile -Destination (Join-Path $dir $newName) -Force -ErrorAction Stop }
    } catch { "ERR|couldn't save the file (close the game and try again)"; return } }
  "HDR|$c"; foreach($x in $r.Done){ "REN|$($x.Old)|$($x.New)" }; if($needRename){ "RENFILE|$oldName|$newName" }; foreach($x in $r.Left){ "LEFT|$($x.Path)|$($x.Why)" }; return }

# ---------- is Open Unleashed running? ----------
function Game-Running { $roots=@(Join-Path $env:APPDATA 'mxa-launcher\clients'); if($game){ $roots+=(Split-Path -Parent $game) }
  foreach($pr in @(Get-Process -ErrorAction SilentlyContinue)){ if($pr.Name -eq 'MXvsATV'){ return $true }
    $pp=$null; try { $pp=$pr.Path } catch {}
    if($pp){ foreach($r in $roots){ if($r -and $pp.StartsWith($r.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){ return $true } } } }
  $false }
function Wait-GameClosed {
  if($NoPrompt){ if(Game-Running){ Write-Host "Open Unleashed is running - close it and try again."; return $false }; return $true }
  while(Game-Running){ $a=Read-Host "`nOpen Unleashed is running. Close it, then press Enter (or type C to cancel)"; if($a -match '^(c|cancel)$'){ return $false } }; $true }

# ---------- fix everything in Pack Files\Broken ----------
# InstallMode: ask (console Read-Host, default) | yes (install, no prompt) | no (skip install)
# -NoPrompt: never Read-Host; if InstallMode=ask, treated as no. Emits RESULT|... for the UI.
$files = if($ListOnly){ @() } else {
  $allBroken = @(Get-ChildItem -LiteralPath $broken -File | Where-Object { $_.Extension -ieq '.pak' })
  if($OnlyPacks -and @($OnlyPacks).Count){
    $want = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($n in @($OnlyPacks)){ if($n){ [void]$want.Add([IO.Path]::GetFileName($n)) } }
    $allBroken = @($allBroken | Where-Object { $want.Contains($_.Name) })
  }
  $allBroken
}
$nFixed=0; $nOk=0; $nSkipped=0; $nInstalled=0; $nInstallFail=0; $nDisabled=0; $ready=@(); $justFixed=@(); $placed=@()
if(-not $files){ if(-not $ListOnly){
  if($OnlyPacks -and @($OnlyPacks).Count){ Write-Host "No matching .pak files in 'Pack Files\Broken' for -OnlyPacks." }
  else { Write-Host "No .pak files in 'Pack Files\Broken' to fix." }
} }
else {
  foreach($f in $files){
    $pk=Read-Pak $f.FullName
    if(-not $pk){ Write-Host "SKIPPED (not a valid PAK, left in Pack Files\Broken): $($f.Name)"; $nSkipped++; continue }
    $count=Fix-Pak $pk -Fix; $rn=Rename-Unused $pk
    $outName=Suggest-LoadOrderName $fixedD $f.Name
    [IO.File]::WriteAllBytes((Join-Path $fixedD $outName),$pk.Bytes); $justFixed+=(Join-Path $fixedD $outName)
    Move-Item -LiteralPath $f.FullName -Destination (FreeName $orig $f.Name)
    if($count -or $rn.Done.Count -or ($outName -ne $f.Name)){ $what=@(); if($count){ $what+="$count texture(s)" }; if($rn.Done.Count){ $what+="$($rn.Done.Count) file name(s)" }; if($outName -ne $f.Name){ $what+='pack file name' }; Write-Host "FIXED $($what -join ' + '): $($f.Name)"; $nFixed++ } else { Write-Host "already OK (copied as-is): $($f.Name)"; $nOk++ }
    foreach($x in $rn.Done){ Write-Host "    renamed $(Split-Path $x.Old -Leaf) -> $(Split-Path $x.New -Leaf)" }
    if($outName -ne $f.Name){ Write-Host "    renamed pack $($f.Name) -> $outName (so it loads after common.pak)" }
    foreach($x in $rn.Left){ Write-Host "    UNUSED, not renamed: $(Split-Path $x.Path -Leaf) ($($x.Why))" }
  }
  Write-Host "`nDone. $nFixed fixed, $nOk already OK."
  $ready = @(Get-ChildItem -LiteralPath $fixedD -File | Where-Object { $_.Extension -ieq '.pak' })
  if($game -and $ready.Count){
    $mode = $InstallMode
    if($NoPrompt -and $mode -eq 'ask'){ $mode = 'no' }
    $doInstall = $false
    if($mode -eq 'yes'){ $doInstall = $true }
    elseif($mode -eq 'ask'){
      $ans = Read-Host "`nInstall the fixed pack(s) into your game now? [Y/n]"
      $doInstall = ($ans -notmatch '^(n|no)$')
    }
    if(-not $doInstall){
      # declined / skipped: move only the packs fixed in THIS run from Fixed to Disabled (unique name if taken)
      foreach($j in $justFixed){ if(Test-Path -LiteralPath $j){
        $leaf=Split-Path $j -Leaf
        try { $dst=FreeName $disD $leaf; Move-Item -LiteralPath $j -Destination $dst -ErrorAction Stop; $nDisabled++; $placed+=(Split-Path $dst -Leaf)
          if((Split-Path $dst -Leaf) -ne $leaf){ Write-Host "DISABLED: $leaf as $(Split-Path $dst -Leaf)" } else { Write-Host "DISABLED: $leaf" } }
        catch { Write-Host "COULDN'T MOVE $leaf to Disabled: $($_.Exception.Message)" } } }
      Write-Host "OK. Not installed. $nDisabled fixed pack(s) moved to 'Pack Files\Disabled' (add them later with Manage Packs)."
      $ready = @(Get-ChildItem -LiteralPath $fixedD -File | Where-Object { $_.Extension -ieq '.pak' })
    }
    if($doInstall){
      if(-not (Wait-GameClosed)){ Write-Host "OK. Nothing was installed. Your fixed packs are waiting in 'Pack Files\Fixed'." }
      else {
        # Only install packs fixed in THIS run (justFixed), not every file already sitting in Fixed
        $toInstall = @($justFixed | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | ForEach-Object { Get-Item -LiteralPath $_ })
        if(-not $toInstall.Count){ $toInstall = @($ready) }
        foreach($r in $toInstall){
          $destName=Suggest-LoadOrderName $game $r.Name
          try { Copy-Item -LiteralPath $r.FullName -Destination (Join-Path $game $destName) -Force -ErrorAction Stop
            if($destName -ne $r.Name){ Write-Host "INSTALLED: $($r.Name) as $destName (loads after common.pak)" } else { Write-Host "INSTALLED: $($r.Name)" }
            $nInstalled++; $placed+=$destName }
          catch { Write-Host "COULDN'T INSTALL $($r.Name) (close the game and run again): $($_.Exception.Message)"; $nInstallFail++ } }
      }
    }
  } elseif($ready.Count){ Write-Host "Copy everything in 'Pack Files\Fixed' into your game's data folder." }
}
if($NoPrompt -and -not $ListOnly -and -not $UnusedReport -and -not $FixFile){
  foreach($pn in $placed){ "PLACED|$pn" }
  "RESULT|FIXED|$nFixed|OK|$nOk|SKIPPED|$nSkipped|INSTALLED|$nInstalled|FAIL|$nInstallFail|READY|$(@($ready).Count)|DISABLED|$nDisabled"
}

# ---------- Installed Packs.txt: every custom pack in the game folder and what it replaces ----------
function Pretty($s){ ($s -replace '_',' ').Trim() }
if($game){
  $installed = Get-ChildItem -LiteralPath $game -File | Where-Object { $_.Extension -ieq '.pak' -and ($STOCK -notcontains $_.Name.ToLower()) } | Sort-Object Name
  $owners=@{}   # item label -> packs that replace it
  $rows=New-Object System.Collections.Generic.List[object]   # @{Text; Label}  (Label empty = plain line)
  $allUn=New-Object System.Collections.Generic.List[object]   # @{Pack;Path;Sug}
  $allLo=New-Object System.Collections.Generic.List[object]   # @{Pack;New}
  $unl=@{}
  function Row($t,$l=''){ $u=[bool]($l -and $unl.ContainsKey($l)); $rows.Add(@{Text=$t;Label=$l;Pack=$null;Un=$u;Sug=$(if($u){$unl[$l]}else{$null})}) }
  function Ranges($ns){ $ns=@($ns | Sort-Object -Unique); $out=@(); $i=0
    while($i -lt $ns.Count){ $j=$i; while($j+1 -lt $ns.Count -and $ns[$j+1] -eq $ns[$j]+1){$j++}
      $out+= if($j -gt $i){"$($ns[$i])-$($ns[$j])"}else{"$($ns[$i])"}; $i=$j+1 }; $out -join ',' }
  $CHECK=[string][char]0x2713
  foreach($p in $installed){
    $pk=Read-Pak $p.FullName
    $bad=0; $un=New-Object System.Collections.Generic.List[object]; if($pk){ $bad=Fix-Pak $pk; $un=Get-Unused $pk }
    $lo=Needs-LoadOrder $p.Name
    if($lo){ $allLo.Add(@{Pack=$p.Name;New=(Suggest-LoadOrderName $game $p.Name)}) }
    $unIdx=@{}; foreach($u in $un){ $unIdx[$u.Index]=$u.Sug; $allUn.Add(@{Pack=$p.Name;Path=$u.Path;Sug=$u.Sug}) }
    $labUn=@{}; $labUsed=@{}
    $rows.Add(@{Text="";Label="";Pack=$p.Name;Bad=$bad;UnN=$un.Count;Lo=$lo})
    if(-not $pk){ Row "  (couldn't read this file)"; Row ""; continue }
    $bikes=[ordered]@{}; $gear=[ordered]@{}; $models=[ordered]@{}; $other=[ordered]@{}
    for($i=0;$i -lt $pk.Count;$i++){
      $nm=[Text.Encoding]::ASCII.GetString($pk.Bytes,4+$i*108,100).Split([char]0)[0]; if(-not $nm){continue}
      $file=[IO.Path]::GetFileNameWithoutExtension($nm) -replace '(?i)_AI$',''; $ext=[IO.Path]::GetExtension($nm).ToLower()
      if($file -match '(?i)^(desktop|thumbs)$'){continue}
      if($ext -eq '.dxm'){ $lab="model: $(Pretty $file)"; $models[$lab]=Pretty $file }
      elseif($nm -match '(?i)\\Veh\\Tex\\'){
        if($file -match '(?i)^(.+?)_(Plastics|Sprockets|Spockets|Rims?|Frame|Seat|Graphics|Decals?|Numbers?|Tires?|Pipe|Engine|Fork|Swingarm|Body)(_.*)?$'){ $item=Pretty $matches[1]; $part=$matches[2] } else { $item=Pretty $file; $part='' }
        $lab= if($part){"bike: $item $part"}else{"bike: $item"}
        if(-not $bikes.Contains($item)){ $bikes[$item]=[ordered]@{} }; $bikes[$item][$lab]=$part }
      elseif($nm -match '(?i)\\Rider\\Tex\\'){ $lab="gear: $(Pretty $file)"; $gear[$lab]=Pretty $file }
      else { $o=$nm -replace '^(?i)Data\\',''; $lab="file: $o"; $other[$lab]=$o }
      if($unIdx.ContainsKey($i)){ if(-not $labUn.ContainsKey($lab)){ $labUn[$lab]=$unIdx[$i] }; continue }   # unused files can't clash
      $labUsed[$lab]=1
      if(-not $owners.ContainsKey($lab)){ $owners[$lab]=New-Object System.Collections.Generic.List[string] }
      if(-not $owners[$lab].Contains($p.Name)){ $owners[$lab].Add($p.Name) }
    }
    $unl=@{}; foreach($k in $labUn.Keys){ if(-not $labUsed.ContainsKey($k)){ $unl[$k]=$labUn[$k] } }
    if($bikes.Count){ Row "  Bikes:"; foreach($b in $bikes.Keys){ $parts=$bikes[$b]
        if($parts.Count -eq 1 -and -not @($parts.Values)[0]){ Row $b @($parts.Keys)[0] }
        else { Row $b; foreach($l in $parts.Keys){ if($parts[$l]){ Row "    $($parts[$l])" $l } else { Row "    (whole bike texture)" $l } } } } }
    if($gear.Count){ Row "  Rider gear:"; foreach($l in $gear.Keys){ Row $gear[$l] $l } }
    if($models.Count){ Row "  Models:"; foreach($l in $models.Keys){ Row $models[$l] $l } }
    if($other.Count){ Row "  Other files:"; foreach($l in $other.Keys){ Row $other[$l] $l } }
    if(-not ($bikes.Count + $gear.Count + $models.Count + $other.Count)){ Row "  (no readable contents)" }
    Row ""
  }
  # ---------- clashes: each item replaced by 2+ installed packs gets its own number ----------
  $num=@{}; $n=0
  $clashing=@($owners.Keys | Where-Object { $owners[$_].Count -ge 2 } | Sort-Object)
  foreach($l in $clashing){ $n++; $num[$l]=$n }
  $lines=@("CUSTOM PACKS INSTALLED IN YOUR GAME","Folder: $game","Updated: $(Get-Date -Format 'yyyy-MM-dd h:mm tt')","$(@($installed).Count) custom pack(s) installed","")
  $lines+="CLASHES (items replaced by more than one pack, so only one version will show up in game)"
  if($n){
    $lines+="  Each clashing item has its own [number]. Find the same [number] in the pack list below."
    foreach($l in $clashing){ $lines+="  [$($num[$l])] $l"; $lines+="        " + (($owners[$l] | Sort-Object) -join '  //  ') }
    $lines+="  To fix a clash, remove one of the packs with MANAGE PACKS.bat." }
  else { $lines+="  None. No two installed packs replace the same thing." }
  $lines+="","UNUSED FILES (inside a pack, but the game never loads them, usually a typo in the file name)"
  if($allUn.Count){ foreach($u in $allUn){ $lines+="  $($u.Pack)  //  $($u.Path)  //  " + $(if($u.Sug){"did you mean $(Split-Path $u.Sug -Leaf)?"}else{"no similar game file"}) }
    $lines+="  MANAGE PACKS option 4 renames these when there's exactly one close game file name." }
  else { $lines+="  None." }
  $lines+="","LOAD ORDER (custom packs must sort AFTER common.pak or Open Unleashed keeps showing stock)"
  if($allLo.Count){ foreach($u in $allLo){ $lines+="  $($u.Pack)  //  sorts before common.pak  //  will be renamed to $($u.New)" }
    $lines+="  MANAGE PACKS option 4 renames these (classic `$` prefix packs just lose the `$`)." }
  else { $lines+="  None. Every custom pack sorts after common.pak." }
  $lines+="","------------------------------------------------------------",""
  $lines+="Tags:  [$CHECK] good   [n] clashes (see CLASHES above)   [BROKEN] still needs fixing (MANAGE PACKS option 4)   [UNUSED] has files the game never loads",""
  foreach($r in $rows){
    if($r.Pack){ $ns=@($owners.Keys | Where-Object { $num.ContainsKey($_) -and $owners[$_].Contains($r.Pack) } | ForEach-Object { $num[$_] })
      $t=@(); if($ns.Count){ $t+="[$(Ranges $ns)]" } elseif(-not $r.Bad -and -not $r.UnN -and -not $r.Lo){ $t+="[$CHECK]" }; if($r.Bad -or $r.UnN -or $r.Lo){ $t+="[BROKEN]" }; if($r.UnN){ $t+="[UNUSED]" }
      $lines+="=== $($t -join ' ') $($r.Pack) ==="
      $why=@(); if($r.Bad){ $why+="$($r.Bad) texture(s) still need fixing" }; if($r.UnN){ $why+="$($r.UnN) file(s) unused, see UNUSED FILES" }; if($r.Lo){ $why+="file name sorts before common.pak (won't show in game; see LOAD ORDER)" }; if($why.Count){ $lines+="  ($($why -join ', '))" }; continue }
    if($r.Text -match '^(===|  \S)' -or $r.Text -eq ''){ $lines+=$r.Text; continue }
    $mark= if($r.Label -and $num.ContainsKey($r.Label)){ "[$($num[$r.Label])] " } else { '' }
    $note=''; if($r.Un){ $mark+="[UNUSED] "; $note= if($r.Sug){ "  (game has no such file; did you mean $(Pretty ([IO.Path]::GetFileNameWithoutExtension($r.Sug)))?)" } else { "  (game has no such file)" } }
    if($r.Text.StartsWith('    ')){ $lines+="        - $mark$($r.Text.Trim())$note" } else { $lines+="    - $mark$($r.Text)$note" } }
  Set-Content -LiteralPath $listTxt -Value $lines -Encoding UTF8
  Write-Host "Updated 'Installed Packs.txt' ($(@($installed).Count) custom pack(s) installed, $n clashing item(s), $($allUn.Count) unused file(s), $($allLo.Count) load-order rename(s) needed)."
}
