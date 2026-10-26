// OURender.cs - native 3D bike renderer for Open Unleashed Pak Fixer.
// C# 5 / .NET Framework 4.x, System.Drawing only (PowerShell 5.1 Add-Type compatible).
//   Add-Type -ReferencedAssemblies System.Drawing -Path OURender.cs
// Port of render_bike.py (box proof renderer). Classes:
//   OUAssets      - case-insensitive leaf-name lookup over stock .pak files (TOC only, lazy reads) and folders
//   OUDxt         - .dxt (DXT1/DXT5/PAL8) / PNG -> OUTexture
//   OUDxg         - .dxg v5 parser (nodes, material strings, triangle-strip meshes)
//   OUSub         - .sub parser ([Objects] MCF, [Material Changes], [SubObjectN]) + .mcf SLTFile
//   OUSubIndex    - Plastics slot -> .sub lookup (scans every stock .sub, prefers MX_S_*)
//   OUBikeModel   - assembled, world-space model (load once, render many)
//   OUBikeScene   - model + textures (stock + overrides from a pak / file); Render(yaw,pitch,zoom,w,h)
//   OURender3D    - static helpers: RenderBike, MakeStackedPreview, SavePreviews, Views
//   OURiderPlate  - runtime rider-number texture (NameDefault stand-in) from the stock mxplate fonts
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

public sealed class OUAssets {
  sealed class Entry { public string Pak; public string Dir; public string FullName; public long Off; public int Len; }
  readonly Dictionary<string, List<Entry>> map = new Dictionary<string, List<Entry>>(StringComparer.OrdinalIgnoreCase);
  readonly object gate = new object();
  public List<string> Sources = new List<string>();

  // MX vs ATV Unleashed .pak: int32 count; count x { char name[100]; int32 offset; int32 size }; data. offset is relative to 4+count*108.
  public static List<KeyValuePair<string, long[]>> ReadPakToc(string path) {
    var res = new List<KeyValuePair<string, long[]>>();
    using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)) {
      var br = new BinaryReader(fs);
      if (fs.Length < 4) return res;
      int n = br.ReadInt32();
      if (n <= 0 || n > 200000 || 4L + n * 108L > fs.Length) return res;
      byte[] toc = br.ReadBytes(n * 108);
      long bas = 4L + n * 108L;
      for (int i = 0; i < n; i++) {
        int e = i * 108, z = 0; while (z < 100 && toc[e + z] != 0) z++;
        string nm = Encoding.ASCII.GetString(toc, e, z);
        long off = bas + BitConverter.ToUInt32(toc, e + 100); int len = BitConverter.ToInt32(toc, e + 104);
        if (len < 0 || off + len > fs.Length) continue;
        res.Add(new KeyValuePair<string, long[]>(nm, new long[] { off, len }));
      }
    }
    return res;
  }
  static string Leaf(string p) { int i = Math.Max(p.LastIndexOf('\\'), p.LastIndexOf('/')); return i >= 0 ? p.Substring(i + 1) : p; }
  void Add(string leaf, Entry e) { List<Entry> l; if (!map.TryGetValue(leaf, out l)) { l = new List<Entry>(); map[leaf] = l; } l.Add(e); }
  // Earlier-added sources win. Within one source, entries under Veh\ are preferred over others with the same leaf name.
  public int AddPak(string path) {
    int c = 0;
    foreach (var kv in ReadPakToc(path)) { Add(Leaf(kv.Key), new Entry { Pak = path, FullName = kv.Key, Off = kv.Value[0], Len = (int)kv.Value[1] }); c++; }
    Sources.Add(path); return c;
  }
  public int AddDir(string dir) {
    int c = 0; if (!Directory.Exists(dir)) return 0;
    foreach (var f in Directory.GetFiles(dir, "*", SearchOption.AllDirectories)) { Add(Path.GetFileName(f), new Entry { Dir = dir, FullName = f, Len = -1 }); c++; }
    Sources.Add(dir); return c;
  }
  Entry Pick(string leaf) {
    List<Entry> l; if (!map.TryGetValue(leaf, out l) || l.Count == 0) return null;
    string src = l[0].Pak ?? l[0].Dir;
    foreach (var e in l) { if ((e.Pak ?? e.Dir) != src) break; if (e.FullName.IndexOf("veh", StringComparison.OrdinalIgnoreCase) >= 0) return e; }
    return l[0];
  }
  public bool Has(string leaf) { return Pick(leaf) != null; }
  public string PathOf(string leaf) { var e = Pick(leaf); return e == null ? null : (e.Pak != null ? e.Pak + "::" + e.FullName : e.FullName); }
  public byte[] Get(string leaf) {
    var e = Pick(leaf); if (e == null) return null;
    if (e.Pak == null) return File.ReadAllBytes(e.FullName);
    lock (gate) {
      using (var fs = new FileStream(e.Pak, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)) {
        fs.Position = e.Off; var b = new byte[e.Len]; int r = 0; while (r < e.Len) { int k = fs.Read(b, r, e.Len - r); if (k <= 0) break; r += k; } return b;
      }
    }
  }
  public List<string> Names(string extension) {
    var r = new List<string>();
    foreach (var k in map.Keys) if (k.EndsWith(extension, StringComparison.OrdinalIgnoreCase)) r.Add(k);
    r.Sort(StringComparer.OrdinalIgnoreCase); return r;
  }
  // Copy every model file (.dxg/.sub/.mcf) to a cache folder (optional; AddDir(cache) then loads without touching the pak).
  public int ExtractModels(string cacheDir) {
    Directory.CreateDirectory(cacheDir); int c = 0;
    foreach (var ext in new[] { ".dxg", ".sub", ".mcf" })
      foreach (var n in Names(ext)) { var p = Path.Combine(cacheDir, n); if (!File.Exists(p)) { var b = Get(n); if (b != null) { File.WriteAllBytes(p, b); c++; } } }
    return c;
  }
}

public sealed class OUTexture {
  public int W, H; public byte[] Px; public bool HasAlphaCut; // Px = RGBA bytes, row-major, top row first
  public static OUTexture FromRgba(int w, int h, byte[] px) {
    var t = new OUTexture { W = w, H = h, Px = px };
    for (int i = 3; i < px.Length; i += 4) if (px[i] < 128) { t.HasAlphaCut = true; break; }
    return t;
  }
}

public static class OUDxt {
  static void Rgb(int c, out int r, out int g, out int b) { r = ((c >> 11) & 31) * 255 / 31; g = ((c >> 5) & 63) * 255 / 63; b = (c & 31) * 255 / 31; }
  public static OUTexture Load(byte[] d) {
    if (d == null || d.Length < 8) return null;
    if (d[0] == 0x89 && d[1] == 0x50 && d[2] == 0x4E && d[3] == 0x47) return FromImage(d);
    return Decode(d);
  }
  public static OUTexture FromImage(byte[] d) {
    using (var ms = new MemoryStream(d)) using (var src = new Bitmap(ms)) return FromBitmap(src);
  }
  public static OUTexture FromBitmap(Bitmap src) {
    int w = src.Width, h = src.Height;
    using (var bm = new Bitmap(w, h, PixelFormat.Format32bppArgb)) {
      using (var g = Graphics.FromImage(bm)) { g.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceCopy; g.DrawImage(src, 0, 0, w, h); }
      var bd = bm.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
      var raw = new byte[w * h * 4];
      for (int y = 0; y < h; y++) Marshal.Copy(new IntPtr(bd.Scan0.ToInt64() + (long)y * bd.Stride), raw, y * w * 4, w * 4);
      bm.UnlockBits(bd);
      for (int i = 0; i < raw.Length; i += 4) { byte t = raw[i]; raw[i] = raw[i + 2]; raw[i + 2] = t; } // BGRA -> RGBA
      return OUTexture.FromRgba(w, h, raw);
    }
  }
  // .dxt: int ver; int fmt (0x26 DXT1, 0x36 DXT5, 0x37/0x38 PAL8); int palCount; [palCount*4 BGRA]; int mips; int W; int H; mips x {w,h,size,data}
  public static OUTexture Decode(byte[] d) {
    int fmt = BitConverter.ToInt32(d, 4), palc = BitConverter.ToInt32(d, 8), o = 12;
    if (palc < 0 || palc > 256) return null;
    int palOff = o; o += 4 * palc;
    if (o + 12 > d.Length) return null;
    int nm = BitConverter.ToInt32(d, o); o += 12;
    int bw = 0, bh = 0, bp = -1, bs = 0;
    for (int i = 0; i < nm && o + 12 <= d.Length; i++) {
      int w = BitConverter.ToInt32(d, o), h = BitConverter.ToInt32(d, o + 4), s = BitConverter.ToInt32(d, o + 8);
      if (s < 0 || (long)o + 12 + s > d.Length) break;
      if (w > 0 && h > 0 && w <= 8192 && h <= 8192 && (long)w * h >= (long)bw * bh) { bw = w; bh = h; bp = o + 12; bs = s; }
      o += 12 + s;
    }
    if (bp < 0) return null;
    var px = new byte[bw * bh * 4];
    if (fmt == 0x37 || fmt == 0x38) {
      if (palc == 0 || bs < bw * bh) return null;
      int m = Math.Min(bw, bh), bits = 0; while ((1 << bits) < m) bits++;
      for (int y = 0; y < bh; y++) for (int x = 0; x < bw; x++) {
        int sx = x & (m - 1), sy = y & (m - 1), idx = 0;
        for (int i = 0; i < bits; i++) idx |= (((sx >> i) & 1) << (2 * i)) | (((sy >> i) & 1) << (2 * i + 1));
        idx += (bw > bh ? x / m : y / m) * m * m;
        int p = palOff + 4 * d[bp + idx], q = (y * bw + x) * 4;
        px[q] = d[p + 2]; px[q + 1] = d[p + 1]; px[q + 2] = d[p]; px[q + 3] = d[p + 3];
      }
      return OUTexture.FromRgba(bw, bh, px);
    }
    bool d1; if (fmt == 0x26) d1 = true; else if (fmt == 0x36) d1 = false; else return null;
    int bx = Math.Max(1, (bw + 3) / 4), by = Math.Max(1, (bh + 3) / 4), bsz = d1 ? 8 : 16;
    if ((long)bx * by * bsz > bs) return null;
    int[] cr = new int[4], cg = new int[4], cb = new int[4], ca = new int[4], al = new int[8];
    for (int y = 0; y < by; y++) for (int x = 0; x < bx; x++) {
      int ob = bp + (y * bx + x) * bsz; ulong abits = 0;
      if (!d1) {
        al[0] = d[ob]; al[1] = d[ob + 1];
        if (al[0] > al[1]) { for (int i = 1; i < 7; i++) al[i + 1] = ((7 - i) * al[0] + i * al[1]) / 7; }
        else { for (int i = 1; i < 5; i++) al[i + 1] = ((5 - i) * al[0] + i * al[1]) / 5; al[6] = 0; al[7] = 255; }
        for (int i = 0; i < 6; i++) abits |= ((ulong)d[ob + 2 + i]) << (8 * i);
        ob += 8;
      }
      int c0 = d[ob] | (d[ob + 1] << 8), c1 = d[ob + 2] | (d[ob + 3] << 8);
      Rgb(c0, out cr[0], out cg[0], out cb[0]); Rgb(c1, out cr[1], out cg[1], out cb[1]);
      ca[0] = ca[1] = ca[2] = ca[3] = 255;
      if (c0 > c1 || !d1) {
        cr[2] = (2 * cr[0] + cr[1]) / 3; cg[2] = (2 * cg[0] + cg[1]) / 3; cb[2] = (2 * cb[0] + cb[1]) / 3;
        cr[3] = (cr[0] + 2 * cr[1]) / 3; cg[3] = (cg[0] + 2 * cg[1]) / 3; cb[3] = (cb[0] + 2 * cb[1]) / 3;
      } else {
        cr[2] = (cr[0] + cr[1]) / 2; cg[2] = (cg[0] + cg[1]) / 2; cb[2] = (cb[0] + cb[1]) / 2;
        cr[3] = cg[3] = cb[3] = 0; ca[3] = 0;
      }
      uint bits = BitConverter.ToUInt32(d, ob + 4);
      for (int i = 0; i < 16; i++) {
        int xx = x * 4 + (i & 3), yy = y * 4 + (i >> 2); if (xx >= bw || yy >= bh) continue;
        int s = (int)((bits >> (2 * i)) & 3), q = (yy * bw + xx) * 4;
        px[q] = (byte)cr[s]; px[q + 1] = (byte)cg[s]; px[q + 2] = (byte)cb[s];
        px[q + 3] = (byte)(d1 ? ca[s] : al[(int)((abits >> (3 * i)) & 7)]);
      }
    }
    return OUTexture.FromRgba(bw, bh, px);
  }
}

public sealed class OUDxgNode { public string Name; public double[] M = new double[16]; public int Parent; }
public sealed class OUDxgMesh { public int MatIdx; public string Material; public ushort[] Ind; public float[] Pos, Nrm, UV; public int[] Bone; }
public sealed class OUDxg {
  public List<OUDxgNode> Nodes = new List<OUDxgNode>(); public List<string> Strs = new List<string>(); public List<OUDxgMesh> Meshes = new List<OUDxgMesh>();
  static string Z(byte[] d, int o, int n) { int z = 0; while (z < n && d[o + z] != 0) z++; return Encoding.ASCII.GetString(d, o, z); }
  public static OUDxg Parse(byte[] d) {
    var r = new OUDxg();
    int nn = BitConverter.ToInt32(d, 8);
    if (nn < 0 || 12L + 224L * nn > d.Length) throw new InvalidDataException("bad dxg node count");
    for (int i = 0; i < nn; i++) {
      int o = 12 + 224 * i; var nd = new OUDxgNode { Name = Z(d, o, 128), Parent = BitConverter.ToInt32(d, o + 220) };
      for (int k = 0; k < 16; k++) nd.M[k] = BitConverter.ToSingle(d, o + 128 + 4 * k);
      r.Nodes.Add(nd);
    }
    int p = 12 + 224 * nn; int ns = BitConverter.ToInt32(d, p); p += 4;
    if (ns < 0 || (long)p + 64L * ns > d.Length) throw new InvalidDataException("bad dxg string count");
    for (int i = 0; i < ns; i++) r.Strs.Add(Z(d, p + 64 * i, 64)); p += 64 * ns;
    int k2 = p;
    while (k2 < d.Length - 22) {
      if (BitConverter.ToUInt32(d, k2 + 4) == 0x47 && BitConverter.ToUInt32(d, k2 + 8) == 1) {
        int idx = BitConverter.ToInt32(d, k2), nv = BitConverter.ToUInt16(d, k2 + 18), ni = BitConverter.ToUInt16(d, k2 + 20);
        int q = k2 + 22; long end = (long)q + 2L * ni + 36L * nv;
        if (end > d.Length) { k2++; continue; }
        var m = new OUDxgMesh { MatIdx = idx, Material = (idx >= 0 && idx < r.Strs.Count) ? r.Strs[idx] : "?", Ind = new ushort[ni], Pos = new float[nv * 3], Nrm = new float[nv * 3], UV = new float[nv * 2], Bone = new int[nv] };
        for (int i = 0; i < ni; i++) m.Ind[i] = BitConverter.ToUInt16(d, q + 2 * i); q += 2 * ni;
        for (int i = 0; i < nv * 3; i++) m.Pos[i] = BitConverter.ToSingle(d, q + 4 * i); q += 12 * nv;
        for (int i = 0; i < nv * 3; i++) m.Nrm[i] = BitConverter.ToSingle(d, q + 4 * i); q += 12 * nv;
        for (int i = 0; i < nv * 2; i++) m.UV[i] = BitConverter.ToSingle(d, q + 4 * i); q += 8 * nv;
        for (int i = 0; i < nv; i++) m.Bone[i] = (int)BitConverter.ToSingle(d, q + 4 * i); q += 4 * nv;
        r.Meshes.Add(m); k2 = q;
      } else k2++;
    }
    return r;
  }
  public static List<int> StripTris(ushort[] ind) {
    var t = new List<int>();
    for (int i = 0; i + 2 < ind.Length; i++) {
      int a = ind[i], b = ind[i + 1], c = ind[i + 2];
      if (a == b || b == c || a == c) continue;
      if (i % 2 == 0) { t.Add(a); t.Add(b); t.Add(c); } else { t.Add(b); t.Add(a); t.Add(c); }
    }
    return t;
  }
}

public sealed class OUSubObject { public string Slt; public string Placement = "Bike"; }
public sealed class OUSub {
  public string Name, Mcf; public Dictionary<string, string> Remap = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
  public List<string> BaseMaterials = new List<string>(); public List<OUSubObject> SubObjects = new List<OUSubObject>();
  public static OUSub Parse(string name, byte[] data) {
    var s = new OUSub { Name = name }; string sec = null; OUSubObject cur = null;
    foreach (var raw in Encoding.Default.GetString(data).Split('\n')) {
      string line = raw; int sc = line.IndexOf(';'); if (sc >= 0) line = line.Substring(0, sc); line = line.Trim();
      if (line.Length == 0) continue;
      if (line.StartsWith("[") && line.EndsWith("]")) {
        sec = line.Substring(1, line.Length - 2).Trim(); cur = null;
        if (sec.StartsWith("subobject", StringComparison.OrdinalIgnoreCase)) { cur = new OUSubObject(); s.SubObjects.Add(cur); }
        continue;
      }
      int eq = line.IndexOf('='); if (eq < 0) continue;
      string k = line.Substring(0, eq).Trim(), v = line.Substring(eq + 1).Trim();
      if (sec == null) continue;
      if (sec.Equals("Material Changes", StringComparison.OrdinalIgnoreCase)) s.Remap[k] = v;
      else if (sec.Equals("Base Materials", StringComparison.OrdinalIgnoreCase) && k.Equals("Material", StringComparison.OrdinalIgnoreCase)) s.BaseMaterials.Add(v);
      else if (sec.Equals("Objects", StringComparison.OrdinalIgnoreCase) && k.Equals("MCF", StringComparison.OrdinalIgnoreCase)) s.Mcf = v;
      else if (cur != null) { if (k.Equals("SLT", StringComparison.OrdinalIgnoreCase)) cur.Slt = v; else if (k.Equals("Placement", StringComparison.OrdinalIgnoreCase)) cur.Placement = v; }
    }
    s.SubObjects.RemoveAll(x => string.IsNullOrEmpty(x.Slt));
    return s;
  }
  public string Map(string mat) { string v; return Remap.TryGetValue(mat, out v) ? v : mat; }
  // .mcf -> SLTFile=bike.Slt -> base model bike.dxg
  public static string BaseDxgFromMcf(byte[] mcf) {
    if (mcf == null) return null;
    var m = Regex.Match(Encoding.Default.GetString(mcf), @"(?im)^\s*SLTFile\s*=\s*([^\r\n;]+)");
    if (!m.Success) return null;
    return Path.GetFileNameWithoutExtension(m.Groups[1].Value.Trim()) + ".dxg";
  }
  public IEnumerable<string> TargetMaterials() { var h = new HashSet<string>(StringComparer.OrdinalIgnoreCase); foreach (var b in BaseMaterials) h.Add(Map(b)); foreach (var v in Remap.Values) h.Add(v); return h; }
}

public static class OUSubIndex {
  // Lower score = better. MX_S_* (stock MX race bike) first, then other MX_*, then bare THQ subs; MXS_/SMX_ (supermoto/sx variants) and UI last.
  public static int Score(string sub) {
    string n = sub.ToUpperInvariant();
    if (n.StartsWith("MX_S_")) return 0;
    if (n.StartsWith("MX_")) return 1;
    if (n.StartsWith("MXS_") || n.StartsWith("SMX_") || n.StartsWith("UI")) return 3;
    return 2;
  }
  static readonly Dictionary<OUAssets, Dictionary<string, List<string>>> cache = new Dictionary<OUAssets, Dictionary<string, List<string>>>();
  // slot (e.g. KTM250SX_01_Plastics) -> candidate .sub names, best first
  public static Dictionary<string, List<string>> Build(OUAssets a) {
    lock (cache) {
      Dictionary<string, List<string>> r; if (cache.TryGetValue(a, out r)) return r;
      r = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
      foreach (var sn in a.Names(".sub")) {
        OUSub s; try { s = OUSub.Parse(sn, a.Get(sn)); } catch { continue; }
        foreach (var t in s.TargetMaterials()) {
          if (t.IndexOf("_Plastics", StringComparison.OrdinalIgnoreCase) < 0) continue;
          List<string> l; if (!r.TryGetValue(t, out l)) { l = new List<string>(); r[t] = l; }
          if (!l.Contains(sn)) l.Add(sn);
        }
      }
      foreach (var l in r.Values) l.Sort((x, y) => { int c = Score(x).CompareTo(Score(y)); return c != 0 ? c : string.Compare(x, y, StringComparison.OrdinalIgnoreCase); });
      cache[a] = r; return r;
    }
  }
  public static List<string> FindSubs(OUAssets a, string plasticsSlot) {
    List<string> l; return Build(a).TryGetValue(plasticsSlot, out l) ? l : new List<string>();
  }
}

public sealed class OUMesh { public string Material; public double[] P, N; public float[] UV; public int[] T; public int Part; }
// Optional handlebar parts, same rules as Open Unleashed (MXA.Runtime MxaBikeParts / MxaBikeModel.SetParts):
//   sub-object SLT name contains 'handguards' / 'crossbar' / 'fatbar' (e.g. Bike_HandGuards, Bike_Crossbar, bike_fatbar_pad).
//   Crossbar block pad shows unless the model has a fat-bar pad and the rider picked FAT BAR; fat-bar (round) pad shows only
//   when FAT BAR is picked; hand guards only when on. Rider choice: save.json ints MXA.Rider.FatBar (default 1) and
//   MXA.Rider.HandGuards (default 0). FatBar / HandGuards below = what new scenes start with (set by the host).
public static class OUBikeParts {
  public const int Other = 0, HandGuards = 1, Crossbar = 2, FatBar = 3;
  public static volatile bool FatBarOn = true, HandGuardsOn = false;
  public static int KindOf(string slt) {
    slt = slt ?? "";
    if (slt.IndexOf("handguards", StringComparison.OrdinalIgnoreCase) >= 0) return HandGuards;
    if (slt.IndexOf("crossbar", StringComparison.OrdinalIgnoreCase) >= 0) return Crossbar;
    if (slt.IndexOf("fatbar", StringComparison.OrdinalIgnoreCase) >= 0) return FatBar;
    return Other;
  }
  public static bool Shown(int kind, bool modelHasFatBar, bool handGuards, bool fatBar) {
    switch (kind) {
      case Crossbar: return !(modelHasFatBar && fatBar);
      case FatBar: return fatBar;
      case HandGuards: return handGuards;
      default: return true;
    }
  }
}
public sealed class OUBikeModel {
  public string SubName, BaseDxg; public List<OUMesh> Meshes = new List<OUMesh>(); public List<string> Warnings = new List<string>();
  public double[] AllP; public double[] Center = new double[3]; public double Radius;
  public bool HasFatBar, HasHandGuards, HasCrossbar;   // optional handlebar parts in this model (OUBikeParts)
  public HashSet<string> Materials = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
  public int TriCount { get { int c = 0; foreach (var m in Meshes) c += m.T.Length / 3; return c; } }

  static readonly Dictionary<string, OUBikeModel> cache = new Dictionary<string, OUBikeModel>(StringComparer.OrdinalIgnoreCase);
  public static OUBikeModel LoadCached(OUAssets a, string subName) {
    string key = a.GetHashCode() + "|" + subName;
    lock (cache) { OUBikeModel m; if (cache.TryGetValue(key, out m)) return m; }
    var mm = Load(a, subName);
    lock (cache) { cache[key] = mm; } return mm;
  }
  static double[] Mul(double[] A, double[] B) { var C = new double[16]; for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) { double s = 0; for (int k = 0; k < 4; k++) s += A[i * 4 + k] * B[k * 4 + j]; C[i * 4 + j] = s; } return C; }
  static double[] World(List<OUDxgNode> nodes, int ni) {
    var M = new double[] { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }; int guard = 0;
    while (ni >= 0 && ni < nodes.Count && guard++ < 256) { M = Mul(M, nodes[ni].M); ni = nodes[ni].Parent; }
    return M;
  }
  static void Xf(double[] M, float[] src, int i, double[] P, double[] N, float[] nsrc) {
    double x = src[i * 3], y = src[i * 3 + 1], z = src[i * 3 + 2];
    P[i * 3] = x * M[0] + y * M[4] + z * M[8] + M[12]; P[i * 3 + 1] = x * M[1] + y * M[5] + z * M[9] + M[13]; P[i * 3 + 2] = x * M[2] + y * M[6] + z * M[10] + M[14];
    x = nsrc[i * 3]; y = nsrc[i * 3 + 1]; z = nsrc[i * 3 + 2];
    double nx = x * M[0] + y * M[4] + z * M[8], ny = x * M[1] + y * M[5] + z * M[9], nz = x * M[2] + y * M[6] + z * M[10];
    double l = Math.Max(Math.Sqrt(nx * nx + ny * ny + nz * nz), 1e-9); N[i * 3] = nx / l; N[i * 3 + 1] = ny / l; N[i * 3 + 2] = nz / l;
  }
  void Add(OUSub sub, string mat, double[] P, double[] N, float[] UV, List<int> T) { Add(sub, mat, P, N, UV, T, OUBikeParts.Other); }
  void Add(OUSub sub, string mat, double[] P, double[] N, float[] UV, List<int> T, int part) {
    mat = sub.Map(mat); var keep = new List<int>(T.Count);
    for (int i = 0; i < T.Count; i += 3) {
      int a = T[i] * 3, b = T[i + 1] * 3, c = T[i + 2] * 3;
      double ax = P[b] - P[a], ay = P[b + 1] - P[a + 1], az = P[b + 2] - P[a + 2], bx = P[c] - P[a], by = P[c + 1] - P[a + 1], bz = P[c + 2] - P[a + 2];
      double cx = ay * bz - az * by, cy = az * bx - ax * bz, cz = ax * by - ay * bx;
      if (Math.Sqrt(cx * cx + cy * cy + cz * cz) > 2e-7) { keep.Add(T[i]); keep.Add(T[i + 1]); keep.Add(T[i + 2]); }
    }
    if (keep.Count == 0) return;
    Meshes.Add(new OUMesh { Material = mat, P = P, N = N, UV = UV, T = keep.ToArray(), Part = part }); Materials.Add(mat);
    if (part == OUBikeParts.FatBar) HasFatBar = true; else if (part == OUBikeParts.HandGuards) HasHandGuards = true; else if (part == OUBikeParts.Crossbar) HasCrossbar = true;
  }
  public static OUBikeModel Load(OUAssets a, string subName) {
    var subData = a.Get(subName); if (subData == null) throw new FileNotFoundException(subName);
    var sub = OUSub.Parse(subName, subData);
    var m = new OUBikeModel { SubName = subName };
    string baseName = sub.Mcf != null ? OUSub.BaseDxgFromMcf(a.Get(sub.Mcf)) : null;
    if (baseName == null || !a.Has(baseName)) { if (sub.Mcf != null) m.Warnings.Add("mcf/base model not found for " + sub.Mcf + ", using bike.dxg"); baseName = "bike.dxg"; }
    m.BaseDxg = baseName;
    var B = OUDxg.Parse(a.Get(baseName));
    var byName = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
    for (int i = 0; i < B.Nodes.Count; i++) if (!byName.ContainsKey(B.Nodes[i].Name)) byName[B.Nodes[i].Name] = i;
    var seen = new HashSet<string>();  // LOD0 = meshes before the first repeated material
    var worldCache = new Dictionary<int, double[]>();
    foreach (var bm in B.Meshes) {
      if (seen.Contains(bm.Material)) break; seen.Add(bm.Material);
      int nv = bm.Bone.Length; var P = new double[nv * 3]; var N = new double[nv * 3];
      for (int i = 0; i < nv; i++) { double[] W; if (!worldCache.TryGetValue(bm.Bone[i], out W)) { W = World(B.Nodes, bm.Bone[i]); worldCache[bm.Bone[i]] = W; } Xf(W, bm.Pos, i, P, N, bm.Nrm); }
      m.Add(sub, bm.Material, P, N, bm.UV, OUDxg.StripTris(bm.Ind));
    }
    foreach (var so in sub.SubObjects) {
      string f = so.Slt + ".dxg"; var data = a.Get(f);
      if (data == null) { m.Warnings.Add("missing subobject " + f); continue; }
      int ni; var M = byName.TryGetValue(so.Placement ?? "Bike", out ni) ? World(B.Nodes, ni) : new double[] { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
      OUDxg r; try { r = OUDxg.Parse(data); } catch (Exception ex) { m.Warnings.Add(f + ": " + ex.Message); continue; }
      int part = OUBikeParts.KindOf(so.Slt);   // crossbar / fat-bar pad / hand guards: drawn per the rider's choice (OUBikeScene)
      foreach (var sm in r.Meshes) {
        // "namedefault" = runtime rider-number decal; kept in the model, drawn only when the scene has a number (OURiderPlate)
        int nv = sm.Bone.Length; var P = new double[nv * 3]; var N = new double[nv * 3];
        for (int i = 0; i < nv; i++) Xf(M, sm.Pos, i, P, N, sm.Nrm);
        m.Add(sub, sm.Material, P, N, sm.UV, OUDxg.StripTris(sm.Ind), part);
      }
    }
    if (m.Meshes.Count == 0) throw new InvalidDataException("no geometry for " + subName);
    // unique referenced points, bbox centre, radius
    var pts = new List<double>(); 
    double[] mn = { double.MaxValue, double.MaxValue, double.MaxValue }, mx = { double.MinValue, double.MinValue, double.MinValue };
    foreach (var me in m.Meshes) {
      var used = new bool[me.P.Length / 3]; foreach (int t in me.T) used[t] = true;
      for (int i = 0; i < used.Length; i++) if (used[i]) for (int k = 0; k < 3; k++) { double v = me.P[i * 3 + k]; pts.Add(v); if (v < mn[k]) mn[k] = v; if (v > mx[k]) mx[k] = v; }
    }
    m.AllP = pts.ToArray();
    for (int k = 0; k < 3; k++) m.Center[k] = (mn[k] + mx[k]) / 2;
    double rad = 0; for (int i = 0; i < m.AllP.Length; i += 3) { double dx = m.AllP[i] - m.Center[0], dy = m.AllP[i + 1] - m.Center[1], dz = m.AllP[i + 2] - m.Center[2]; rad = Math.Max(rad, Math.Sqrt(dx * dx + dy * dy + dz * dz)); }
    m.Radius = rad;
    return m;
  }
}

public sealed class OUCamera {
  public double[] Eye = new double[3], F = new double[3], R = new double[3], U = new double[3], L = new double[3]; public double T, Asp, OffX, OffY;
}

// Model + textures. Thread-safe for concurrent Render calls (each call allocates its own buffers unless a OURenderBuffers is passed).
public sealed class OUBikeScene {
  public OUBikeModel Model; public Dictionary<string, OUTexture> Tex = new Dictionary<string, OUTexture>(StringComparer.OrdinalIgnoreCase);
  public List<string> GreyMaterials = new List<string>();
  readonly Dictionary<string, double> liveDist = new Dictionary<string, double>();
  public static double Fov = 24.0, Margin = 0.04;

  // overrides: material name -> raw .dxt/.png bytes (e.g. from the pak being previewed). Everything else from stock assets.
  public OUBikeScene(OUBikeModel model, OUAssets stock, IDictionary<string, byte[]> overrides) {
    Model = model; stockRef = stock;
    foreach (var mat in model.Materials) {
      if (IsNumberMat(mat)) continue;   // filled by SetRiderNumber
      byte[] b = null;
      if (overrides != null) foreach (var kv in overrides) if (kv.Key.Equals(mat, StringComparison.OrdinalIgnoreCase)) { b = kv.Value; break; }
      if (b == null && stock != null) b = stock.Get(mat + ".dxt");
      OUTexture t = null; try { t = OUDxt.Load(b); } catch { }
      if (t != null) Tex[mat] = t; else GreyMaterials.Add(mat);
    }
    SetRiderNumber(OURiderPlate.Number);
    FatBar = OUBikeParts.FatBarOn; HandGuards = OUBikeParts.HandGuardsOn;
  }
  readonly OUAssets stockRef;
  // Handlebar parts drawn (see OUBikeParts). Safe to change between renders.
  public volatile bool FatBar = true, HandGuards = false;
  public void SetParts(bool fatBar, bool handGuards) { FatBar = fatBar; HandGuards = handGuards; }
  public bool PartsMatch(bool fatBar, bool handGuards) { return FatBar == fatBar && HandGuards == handGuards; }
  public string RiderNumber { get; private set; }
  public static bool IsNumberMat(string mat) { return mat != null && mat.Equals("namedefault", StringComparison.OrdinalIgnoreCase); }
  // Put the rider number on the plates ("" / null = no number decals, like before). Safe to call between renders.
  public void SetRiderNumber(string number) {
    string n = OURiderPlate.Clean(number); OUTexture t = null;
    if (n.Length > 0) { try { t = OURiderPlate.Texture(stockRef, n); } catch { t = null; } }
    // copy-and-swap so a render running on another thread keeps a consistent texture set
    var nt = new Dictionary<string, OUTexture>(StringComparer.OrdinalIgnoreCase);
    foreach (var kv in Tex) if (!IsNumberMat(kv.Key)) nt[kv.Key] = kv.Value;
    if (t != null) foreach (var mat in Model.Materials) if (IsNumberMat(mat)) nt[mat] = t;
    Tex = nt;
    RiderNumber = t != null ? n : "";
  }
  // texture overrides from a .pak: every *.dxt keyed by file name without extension
  public static Dictionary<string, byte[]> TexturesFromPak(string pakPath) {
    var r = new Dictionary<string, byte[]>(StringComparer.OrdinalIgnoreCase);
    var a = new OUAssets(); a.AddPak(pakPath);
    foreach (var n in a.Names(".dxt")) r[Path.GetFileNameWithoutExtension(n)] = a.Get(n);
    return r;
  }

  public OUCamera Camera(double yaw, double pitch, int W, int H, bool tight, double zoom) {
    var cam = new OUCamera(); var c = Model.Center; var P = Model.AllP;
    double ya = yaw * Math.PI / 180, pa = pitch * Math.PI / 180;
    double[] d = { Math.Sin(ya) * Math.Cos(pa), Math.Sin(pa), Math.Cos(ya) * Math.Cos(pa) };
    double[] f = { -d[0], -d[1], -d[2] };
    double[] r = { f[2], 0, -f[0] }; // cross((0,1,0), f)
    double rl = Math.Sqrt(r[0] * r[0] + r[2] * r[2]); if (rl < 1e-9) { r[0] = 1; r[2] = 0; rl = 1; } r[0] /= rl; r[2] /= rl;
    double[] u = { f[1] * r[2] - f[2] * r[1], f[2] * r[0] - f[0] * r[2], f[0] * r[1] - f[1] * r[0] };
    double t = Math.Tan(Fov * Math.PI / 360), asp = (double)W / H;
    cam.F = f; cam.R = r; cam.U = u; cam.T = t; cam.Asp = asp;
    double dist; double offx = 0, offy = 0;
    if (tight) {
      double lo = Model.Radius * 0.5, hi = Model.Radius * 50;
      for (int it = 0; it < 60; it++) { double mid = (lo + hi) / 2, ex, ey, zmin; Ext(P, c, d, f, r, u, t, asp, mid, out ex, out ey, out zmin, out offx, out offy); if (zmin > 0.05 && Math.Max(ex, ey) / 2 < 1 - 2 * Margin) hi = mid; else lo = mid; }
      double a1, a2, a3; Ext(P, c, d, f, r, u, t, asp, hi, out a1, out a2, out a3, out offx, out offy);
      dist = hi;
    } else {
      // live/rotating: distance fixed for every yaw (max of tight fits over 36 yaws at this pitch/aspect), no recentring -> no pumping while spinning
      string key = Math.Round(pitch, 1) + "|" + Math.Round(asp, 3);
      lock (liveDist) {
        if (!liveDist.TryGetValue(key, out dist)) {
          dist = 0;
          for (int k = 0; k < 36; k++) { var cc = Camera(k * 10, pitch, W, H, true, 1); double dd = 0; for (int q = 0; q < 3; q++) { double v = cc.Eye[q] - c[q]; dd += v * v; } dist = Math.Max(dist, Math.Sqrt(dd)); }
          liveDist[key] = dist;
        }
      }
      offx = offy = 0;
    }
    dist /= Math.Max(zoom, 0.05);
    for (int q = 0; q < 3; q++) cam.Eye[q] = c[q] + d[q] * dist;
    cam.OffX = offx; cam.OffY = offy;
    double[] L = new double[3]; double ll = 0;
    for (int q = 0; q < 3; q++) { L[q] = -f[q] * 0.55 + u[q] * 0.6 + r[q] * -0.35; ll += L[q] * L[q]; }
    ll = Math.Sqrt(ll); for (int q = 0; q < 3; q++) L[q] /= ll; cam.L = L;
    return cam;
  }
  static void Ext(double[] P, double[] c, double[] d, double[] f, double[] r, double[] u, double t, double asp, double dist, out double ex, out double ey, out double zmin, out double ox, out double oy) {
    double ex0 = c[0] + d[0] * dist, ey0 = c[1] + d[1] * dist, ez0 = c[2] + d[2] * dist;
    double xmn = double.MaxValue, xmx = double.MinValue, ymn = double.MaxValue, ymx = double.MinValue; zmin = double.MaxValue;
    for (int i = 0; i < P.Length; i += 3) {
      double rx = P[i] - ex0, ry = P[i + 1] - ey0, rz = P[i + 2] - ez0;
      double z = rx * f[0] + ry * f[1] + rz * f[2]; if (z < zmin) zmin = z;
      double xs = (rx * r[0] + ry * r[1] + rz * r[2]) / (z * t * asp), ys = (rx * u[0] + ry * u[1] + rz * u[2]) / (z * t);
      if (xs < xmn) xmn = xs; if (xs > xmx) xmx = xs; if (ys < ymn) ymn = ys; if (ys > ymx) ymx = ys;
    }
    ex = xmx - xmn; ey = ymx - ymn; ox = (xmx + xmn) / 2; oy = (ymx + ymn) / 2;
  }

  // Render. tight=true reproduces render_bike.py framing (bike fills frame); tight=false = fixed framing for rotation.
  // ss = supersampling factor (2 for previews, 1 for live drag). bg = Color.Transparent or a solid colour.
  public Bitmap Render(double yaw, double pitch, double zoom, int width, int height, int ss, bool tight, Color bg) {
    var buf = new OURenderBuffers(); return Render(yaw, pitch, zoom, width, height, ss, tight, bg, buf);
  }
  public Bitmap Render(double yaw, double pitch, double zoom, int width, int height, int ss, bool tight, Color bg, OURenderBuffers buf) {
    int[] px = RenderPixels(yaw, pitch, zoom, width, height, ss, tight, bg, buf);
    var bm = new Bitmap(width, height, PixelFormat.Format32bppArgb);
    var bd = bm.LockBits(new Rectangle(0, 0, width, height), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
    for (int y = 0; y < height; y++) Marshal.Copy(px, y * width, new IntPtr(bd.Scan0.ToInt64() + (long)y * bd.Stride), width);
    bm.UnlockBits(bd); return bm;
  }
  // returns ARGB ints (straight alpha), width*height
  public int[] RenderPixels(double yaw, double pitch, double zoom, int width, int height, int ss, bool tight, Color bg, OURenderBuffers buf) {
    if (ss < 1) ss = 1; int W = width * ss, H = height * ss, WH = W * H;
    buf.Ensure(WH);
    var zb = buf.Z; var tid = buf.Tid; var bA = buf.A; var bB = buf.B;
    var Tex = this.Tex;   // snapshot (SetRiderNumber swaps the dictionary)
    bool fb = FatBar, hg = HandGuards, hasFat = Model.HasFatBar;   // snapshot (SetParts)
    for (int i = 0; i < WH; i++) { zb[i] = float.PositiveInfinity; tid[i] = -1; }
    var cam = Camera(yaw, pitch, W, H, tight, zoom);
    var meshes = Model.Meshes; int nm = meshes.Count; var starts = new int[nm + 1];
    for (int i = 0; i < nm; i++) starts[i + 1] = starts[i] + meshes[i].T.Length / 3;
    double[] e = cam.Eye, f = cam.F, r = cam.R, u = cam.U; double t = cam.T, asp = cam.Asp;
    for (int mi = 0; mi < nm; mi++) {
      var m = meshes[mi]; int nv = m.P.Length / 3;
      OUTexture tex; Tex.TryGetValue(m.Material, out tex);
      if (tex == null && IsNumberMat(m.Material)) continue;   // no rider number -> decal not drawn
      if (m.Part != OUBikeParts.Other && !OUBikeParts.Shown(m.Part, hasFat, hg, fb)) continue;   // unselected bar pad / hand guards
      var S = buf.Scratch(nv * 3);
      for (int i = 0; i < nv; i++) {
        double rx = m.P[i * 3] - e[0], ry = m.P[i * 3 + 1] - e[1], rz = m.P[i * 3 + 2] - e[2];
        double z = rx * f[0] + ry * f[1] + rz * f[2];
        double x = (rx * r[0] + ry * r[1] + rz * r[2]) / (z * t * asp) - cam.OffX, y = (rx * u[0] + ry * u[1] + rz * u[2]) / (z * t) - cam.OffY;
        S[i * 3] = (x + 1) * W / 2; S[i * 3 + 1] = (1 - y) * H / 2; S[i * 3 + 2] = z;
      }
      bool hasA = tex != null && tex.HasAlphaCut;
      var T = m.T; var UV = m.UV;
      for (int ti = 0; ti < T.Length / 3; ti++) {
        int i0 = T[ti * 3], i1 = T[ti * 3 + 1], i2 = T[ti * 3 + 2];
        double z0 = S[i0 * 3 + 2], z1 = S[i1 * 3 + 2], z2 = S[i2 * 3 + 2];
        if (Math.Min(z0, Math.Min(z1, z2)) <= 0.01) continue;
        double x0 = S[i0 * 3], y0 = S[i0 * 3 + 1], x1 = S[i1 * 3], y1 = S[i1 * 3 + 1], x2 = S[i2 * 3], y2 = S[i2 * 3 + 1];
        int minx = Math.Max((int)Math.Floor(Math.Min(x0, Math.Min(x1, x2))), 0), maxx = Math.Min((int)Math.Ceiling(Math.Max(x0, Math.Max(x1, x2))), W - 1);
        int miny = Math.Max((int)Math.Floor(Math.Min(y0, Math.Min(y1, y2))), 0), maxy = Math.Min((int)Math.Ceiling(Math.Max(y0, Math.Max(y1, y2))), H - 1);
        if (minx > maxx || miny > maxy) continue;
        double den = (y1 - y2) * (x0 - x2) + (x2 - x1) * (y0 - y2);
        if (Math.Abs(den) < 1e-12) continue;
        double iz0 = 1 / z0, iz1 = 1 / z1, iz2 = 1 / z2, idn = 1 / den;
        double u0 = 0, v0 = 0, u1 = 0, v1 = 0, u2 = 0, v2 = 0;
        if (hasA) { u0 = UV[i0 * 2]; v0 = UV[i0 * 2 + 1]; u1 = UV[i1 * 2]; v1 = UV[i1 * 2 + 1]; u2 = UV[i2 * 2]; v2 = UV[i2 * 2 + 1]; }
        int gid = starts[mi] + ti;
        for (int py = miny; py <= maxy; py++) {
          double Y = py + 0.5; int row = py * W;
          for (int pxx = minx; pxx <= maxx; pxx++) {
            double X = pxx + 0.5;
            double a = ((y1 - y2) * (X - x2) + (x2 - x1) * (Y - y2)) * idn;
            if (a < 0) continue;
            double b = ((y2 - y0) * (X - x2) + (x0 - x2) * (Y - y2)) * idn;
            if (b < 0 || 1 - a - b < 0) continue;
            double c = 1 - a - b;
            double pa = a * iz0, pb = b * iz1, pc = c * iz2, s = pa + pb + pc;
            pa /= s; pb /= s; double zz = 1 / s;
            int idx = row + pxx;
            if (!(zz < zb[idx])) continue;
            if (hasA) {
              double pcc = 1 - pa - pb;
              double uu = pa * u0 + pb * u1 + pcc * u2, vv = pa * v0 + pb * v1 + pcc * v2;
              uu -= Math.Floor(uu); vv -= Math.Floor(vv);
              int tx = ((int)(uu * tex.W)) % tex.W, ty = ((int)(vv * tex.H)) % tex.H;
              if (tex.Px[(ty * tex.W + tx) * 4 + 3] < 128) continue;
            }
            zb[idx] = (float)zz; bA[idx] = (float)pa; bB[idx] = (float)pb; tid[idx] = gid;
          }
        }
      }
    }
    // deferred shading
    var meshOf = buf.MeshOf(starts[nm]);
    for (int mi = 0; mi < nm; mi++) for (int k = starts[mi]; k < starts[mi + 1]; k++) meshOf[k] = mi;
    var col = buf.Col; double[] L = cam.L;
    var texs = new OUTexture[nm]; for (int mi = 0; mi < nm; mi++) { OUTexture tx; Tex.TryGetValue(meshes[mi].Material, out tx); texs[mi] = tx; }
    Parallel.For(0, H, py => {
      for (int pxx = 0; pxx < W; pxx++) {
        int idx = py * W + pxx; int g = tid[idx];
        if (g < 0) { col[idx] = 0; continue; }
        int mi = meshOf[g]; var m = meshes[mi]; int ti = g - starts[mi];
        int i0 = m.T[ti * 3], i1 = m.T[ti * 3 + 1], i2 = m.T[ti * 3 + 2];
        double a = bA[idx], b = bB[idx], c = 1 - a - b;
        double uu = a * m.UV[i0 * 2] + b * m.UV[i1 * 2] + c * m.UV[i2 * 2], vv = a * m.UV[i0 * 2 + 1] + b * m.UV[i1 * 2 + 1] + c * m.UV[i2 * 2 + 1];
        double nx = a * m.N[i0 * 3] + b * m.N[i1 * 3] + c * m.N[i2 * 3], ny = a * m.N[i0 * 3 + 1] + b * m.N[i1 * 3 + 1] + c * m.N[i2 * 3 + 1], nz = a * m.N[i0 * 3 + 2] + b * m.N[i1 * 3 + 2] + c * m.N[i2 * 3 + 2];
        double nl = Math.Max(Math.Sqrt(nx * nx + ny * ny + nz * nz), 1e-9); nx /= nl; ny /= nl; nz /= nl;
        double nf = nx * f[0] + ny * f[1] + nz * f[2];
        if (nf > 0) { nx = -nx; ny = -ny; nz = -nz; nf = -nf; }
        double br, bgc, bb; var tex = texs[mi];
        if (tex != null) {
          int tw = tex.W, th = tex.H; var tp = tex.Px;
          double x = (uu - Math.Floor(uu)) * tw - 0.5, y = (vv - Math.Floor(vv)) * th - 0.5;
          double fx0 = Math.Floor(x), fy0 = Math.Floor(y); double fx = x - fx0, fy = y - fy0;
          int xa = ((int)fx0 % tw + tw) % tw, ya = ((int)fy0 % th + th) % th, xb = (xa + 1) % tw, yb = (ya + 1) % th;
          int o00 = (ya * tw + xa) * 4, o01 = (ya * tw + xb) * 4, o10 = (yb * tw + xa) * 4, o11 = (yb * tw + xb) * 4;
          double w00 = (1 - fx) * (1 - fy), w01 = fx * (1 - fy), w10 = (1 - fx) * fy, w11 = fx * fy;
          br = (tp[o00] * w00 + tp[o01] * w01 + tp[o10] * w10 + tp[o11] * w11) / 255.0;
          bgc = (tp[o00 + 1] * w00 + tp[o01 + 1] * w01 + tp[o10 + 1] * w10 + tp[o11 + 1] * w11) / 255.0;
          bb = (tp[o00 + 2] * w00 + tp[o01 + 2] * w01 + tp[o10 + 2] * w10 + tp[o11 + 2] * w11) / 255.0;
        } else { br = 0.45; bgc = 0.45; bb = 0.47; }
        double diff = nx * L[0] + ny * L[1] + nz * L[2]; if (diff < 0) diff = 0; if (diff > 1) diff = 1;
        double rim = 1 - Math.Abs(nf); if (rim < 0) rim = 0; rim = rim * rim * rim * 0.12;
        double k = 0.38 + 0.72 * diff;
        int R = Clamp255(br * k + rim), G = Clamp255(bgc * k + rim), B = Clamp255(bb * k + rim);
        col[idx] = (255 << 24) | (R << 16) | (G << 8) | B;
      }
    });
    // resolve: premultiplied box downsample (alpha = coverage), then optional solid background
    var outp = new int[width * height]; int n2 = ss * ss;
    bool solid = bg.A > 0; int bga = bg.A, bgr = bg.R, bgg = bg.G, bgb = bg.B;
    Parallel.For(0, height, oy => {
      for (int ox = 0; ox < width; ox++) {
        double sr = 0, sg = 0, sb = 0; int cnt = 0;
        for (int yy = 0; yy < ss; yy++) { int row = (oy * ss + yy) * W + ox * ss; for (int xx = 0; xx < ss; xx++) { int cc = col[row + xx]; if ((cc >> 24) == 0) continue; cnt++; sr += (cc >> 16) & 255; sg += (cc >> 8) & 255; sb += cc & 255; } }
        int pr, pg, pb, pa;
        if (cnt == 0) { pr = pg = pb = 0; pa = 0; }
        else if (cnt == n2 && ss == 1) { int cc = col[oy * W + ox]; outp[oy * width + ox] = cc; if (!solid) continue; pr = (cc >> 16) & 255; pg = (cc >> 8) & 255; pb = cc & 255; pa = 255; }
        else {
          // float32 path in python: colour/255 averaged then *255+0.5
          pr = Clamp255Raw(sr / cnt); pg = Clamp255Raw(sg / cnt); pb = Clamp255Raw(sb / cnt); pa = (int)((double)cnt / n2 * 255 + 0.5);
        }
        if (solid) {
          // alpha-composite over bg (like PIL alpha_composite)
          double fa = pa / 255.0, ba = bga / 255.0, oa = fa + ba * (1 - fa);
          if (oa <= 0) { outp[oy * width + ox] = 0; continue; }
          int rr = Clamp255Raw((pr * fa + bgr * ba * (1 - fa)) / oa), gg = Clamp255Raw((pg * fa + bgg * ba * (1 - fa)) / oa), bbb = Clamp255Raw((pb * fa + bgb * ba * (1 - fa)) / oa);
          outp[oy * width + ox] = ((int)(oa * 255 + 0.5) << 24) | (rr << 16) | (gg << 8) | bbb;
        } else outp[oy * width + ox] = (pa << 24) | (pr << 16) | (pg << 8) | pb;
      }
    });
    return outp;
  }
  static int Clamp255(double v) { if (v < 0) v = 0; if (v > 1) v = 1; return (int)(v * 255 + 0.5); }
  static int Clamp255Raw(double v) { int i = (int)(v + 0.5); return i < 0 ? 0 : (i > 255 ? 255 : i); }
}

public sealed class OURenderBuffers {
  public float[] Z = new float[0], A = new float[0], B = new float[0]; public int[] Tid = new int[0], Col = new int[0];
  double[] scratch = new double[0]; int[] meshOf = new int[0];
  public void Ensure(int n) { if (Z.Length < n) { Z = new float[n]; A = new float[n]; B = new float[n]; Tid = new int[n]; Col = new int[n]; } }
  public double[] Scratch(int n) { if (scratch.Length < n) scratch = new double[n]; return scratch; }
  public int[] MeshOf(int n) { if (meshOf.Length < n) meshOf = new int[n]; return meshOf; }
}

public static class OURender3D {
  // named views (yaw, pitch): yaw 0 = front, 90 = right side
  public static readonly Dictionary<string, double[]> Views = new Dictionary<string, double[]>(StringComparer.OrdinalIgnoreCase) {
    { "right", new double[] { 90, 4 } }, { "left", new double[] { -90, 4 } }, { "34fr", new double[] { 40, 14 } }, { "34fl", new double[] { -40, 14 } },
    { "34rr", new double[] { 140, 14 } }, { "front", new double[] { 0, 6 } }, { "rear", new double[] { 180, 6 } } };

  static readonly Dictionary<string, OUAssets> stockCache = new Dictionary<string, OUAssets>(StringComparer.OrdinalIgnoreCase);
  // Stock assets: optional model cache folder first, then common.pak from the game data folder.
  public static OUAssets Stock(string gameDataFolder, string modelCacheDir) {
    string key = (gameDataFolder ?? "") + "|" + (modelCacheDir ?? "");
    lock (stockCache) {
      OUAssets a; if (stockCache.TryGetValue(key, out a)) return a;
      a = new OUAssets();
      if (!string.IsNullOrEmpty(modelCacheDir) && Directory.Exists(modelCacheDir)) a.AddDir(modelCacheDir);
      if (!string.IsNullOrEmpty(gameDataFolder)) { var cp = Path.Combine(gameDataFolder, "common.pak"); if (File.Exists(cp)) a.AddPak(cp); }
      stockCache[key] = a; return a;
    }
  }
  // Plastics slots (e.g. KTM250SX_01_Plastics) present in a pak that have a renderable stock model
  public static List<string> BikeSlotsInPak(OUAssets stock, string pakPath) {
    var r = new List<string>();
    foreach (var kv in OUAssets.ReadPakToc(pakPath)) {
      string n = Path.GetFileNameWithoutExtension(kv.Key.Replace('\\', '/').Substring(kv.Key.Replace('\\', '/').LastIndexOf('/') + 1));
      if (!kv.Key.EndsWith(".dxt", StringComparison.OrdinalIgnoreCase) || !n.EndsWith("_Plastics", StringComparison.OrdinalIgnoreCase)) continue;
      if (OUSubIndex.FindSubs(stock, n).Count > 0 && !r.Contains(n)) r.Add(n);
    }
    return r;
  }
  // first candidate .sub that loads
  public static OUBikeModel ModelForSlot(OUAssets stock, string plasticsSlot) {
    string err = "no .sub maps " + plasticsSlot;
    foreach (var s in OUSubIndex.FindSubs(stock, plasticsSlot)) {
      try { var m = OUBikeModel.LoadCached(stock, s); if (m.Materials.Contains(plasticsSlot)) return m; err = s + " does not use " + plasticsSlot; }
      catch (Exception ex) { err = s + ": " + ex.Message; }
    }
    throw new InvalidOperationException(err);
  }
  public static OUBikeScene SceneForSlot(OUAssets stock, string plasticsSlot, IDictionary<string, byte[]> texOverrides) {
    return new OUBikeScene(ModelForSlot(stock, plasticsSlot), stock, texOverrides);
  }
  // Requested one-call API. texOverrides: material -> .dxt/.png bytes (null = stock skin).
  public static Bitmap RenderBike(OUAssets stock, string plasticsSlot, IDictionary<string, byte[]> texOverrides, double yawDeg, double pitchDeg, double zoom, int width, int height) {
    return SceneForSlot(stock, plasticsSlot, texOverrides).Render(yawDeg, pitchDeg, zoom, width, height, 2, true, Color.Transparent);
  }
  public static Bitmap RenderView(OUBikeScene sc, string view, int w, int h, int ss, Color bg) { var v = Views[view]; return sc.Render(v[0], v[1], 1, w, h, ss, true, bg); }
  // Side profile on top, 3/4 front-right below, one image (w x 2h).
  public static Bitmap MakeStackedPreview(OUBikeScene sc, int w, int h, Color bg) {
    using (var a = RenderView(sc, "right", w, h, 2, bg)) using (var b = RenderView(sc, "34fr", w, h, 2, bg)) return Stack(a, b);
  }
  // top over bottom, pixel copy (no GDI+ scaling/DPI effects)
  public static Bitmap Stack(Bitmap top, Bitmap bottom) {
    int w = Math.Max(top.Width, bottom.Width), h = top.Height + bottom.Height;
    var st = new Bitmap(w, h, PixelFormat.Format32bppArgb);
    var d = st.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
    int y0 = 0;
    foreach (var src in new[] { top, bottom }) {
      var s = src.LockBits(new Rectangle(0, 0, src.Width, src.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
      var row = new int[src.Width];
      for (int y = 0; y < src.Height; y++) {
        Marshal.Copy(new IntPtr(s.Scan0.ToInt64() + (long)y * s.Stride), row, 0, src.Width);
        Marshal.Copy(row, 0, new IntPtr(d.Scan0.ToInt64() + (long)(y0 + y) * d.Stride), src.Width);
      }
      src.UnlockBits(s); y0 += src.Height;
    }
    st.UnlockBits(d); return st;
  }
  // Writes <stackPath> (side over 3/4 front) and <sidePath> (side only). Returns ms taken.
  public static long SavePreviews(OUBikeScene sc, string stackPath, string sidePath, int w, int h, Color bg) {
    var sw = System.Diagnostics.Stopwatch.StartNew();
    using (var side = RenderView(sc, "right", w, h, 2, bg)) using (var fr = RenderView(sc, "34fr", w, h, 2, bg)) {
      if (!string.IsNullOrEmpty(stackPath)) using (var st = Stack(side, fr)) st.Save(stackPath, ImageFormat.Png);
      if (!string.IsNullOrEmpty(sidePath)) side.Save(sidePath, ImageFormat.Png);
    }
    return sw.ElapsedMilliseconds;
  }
  // File-name-safe preview names: <pak>__<Item>__stack.png / __side.png
  public static string PreviewName(string pakFile, string slot, string kind) {
    string item = slot.EndsWith("_Plastics", StringComparison.OrdinalIgnoreCase) ? slot.Substring(0, slot.Length - 9) : slot;
    return Path.GetFileNameWithoutExtension(pakFile) + "__" + item + "__" + kind + ".png";
  }
}

// Rider number decal (game: Veh\Tex\NameDefault is generated at runtime; the bike's 'namedefault' meshes float just above the
// plates). Digits from stock Font\ENG\mxplate (1 digit) / mxplate_2 (2) / mxplate_3 (3): shape in alpha only, no outline.
// NameDefault layout (V = rows of the 256x512 stand-in): every MX/ATV model maps its decals to one 0.25-high row:
//   V 0.48-0.75 : 250/450/500-class plates and ATVs (white plates)  -> black digits (mxplate*)
//   V 0.72-1.00 : 125/250F-class plates (rm125, yz125, 125sx, crf250, kx250f, rmz250, yzf250; black plates) -> white digits one row lower
// Black-digit band fitted on the box to the in-game customise screen (V 0.5255-0.7175 of the black ink, centred U 0.5).
public static class OURiderPlate {
  public const int TW = 256, TH = 512;
  public static double Band0 = 0.5255, Band1 = 0.7175, CentreU = 0.5, RowStep = 0.25;
  // lower (125/250F-class) row: those stock plates are black, so white digits (the game ships the same glyphs white as mxplate_black*)
  public static Color LowerRowColor = Color.White;
  // number / name every new OUBikeScene starts with (set by the host from the game save or the Settings override)
  public static volatile string Number = "", Name = "";
  static readonly Dictionary<string, OUTexture> cache = new Dictionary<string, OUTexture>();
  // digits only, at most 3, no leading zeros ("" = no number)
  public static string Clean(string n) {
    if (n == null) return ""; var sb = new StringBuilder(); foreach (char c in n) if (c >= '0' && c <= '9') sb.Append(c);
    string s = sb.ToString().TrimStart('0'); if (s.Length == 0 && sb.Length > 0) s = "0"; if (s.Length > 3) s = s.Substring(0, 3); return s;
  }
  public static string FontFor(string num) { return num.Length <= 1 ? "mxplate" : (num.Length == 2 ? "mxplate_2" : "mxplate_3"); }
  public static Dictionary<char, float[]> ParseCel(byte[] d) {
    var r = new Dictionary<char, float[]>(); int o = 0;
    Func<float, bool> ok = v => v == 0f || (v > 1e-4f && v <= 1.0001f);
    while (o + 20 <= d.Length) {
      uint c = BitConverter.ToUInt32(d, o); float u0 = BitConverter.ToSingle(d, o + 4), v0 = BitConverter.ToSingle(d, o + 8), u1 = BitConverter.ToSingle(d, o + 12), v1 = BitConverter.ToSingle(d, o + 16);
      if (c >= 32 && c < 127 && ok(u0) && ok(v0) && ok(u1) && ok(v1) && u1 > u0 && v1 > v0) { if (!r.ContainsKey((char)c)) r[(char)c] = new[] { u0, v0, u1, v1 }; o += 20; } else o++;
    }
    return r;
  }
  public static OUTexture Texture(OUAssets a, string number) {
    string num = Clean(number); if (num.Length == 0 || a == null) return null;
    string key = a.GetHashCode() + "|" + num + "|" + LowerRowColor.ToArgb();
    lock (cache) { OUTexture t; if (cache.TryGetValue(key, out t)) return t; }
    var tex = Build(a, num);
    lock (cache) cache[key] = tex; return tex;
  }
  static double Sinc(double x) { if (Math.Abs(x) < 1e-9) return 1; x *= Math.PI; return Math.Sin(x) / x; }
  static double Lanczos(double x) { return (x > -3 && x < 3) ? Sinc(x) * Sinc(x / 3) : 0; }
  // PIL-style separable Lanczos-3 resize of one channel (values 0..255)
  static double[] Resize(double[] src, int sw, int sh, int dw, int dh) {
    var tmp = new double[dw * sh]; Pass(src, sw, sh, dw, true, tmp); var dst = new double[dw * dh]; Pass(tmp, dw, sh, dh, false, dst); return dst;
  }
  static void Pass(double[] s, int sw, int sh, int dn, bool horiz, double[] d) {
    int sn = horiz ? sw : sh, other = horiz ? sh : sw; double scale = (double)sn / dn, fs = Math.Max(scale, 1.0), support = 3 * fs;
    for (int i = 0; i < dn; i++) {
      double centre = (i + 0.5) * scale; int lo = Math.Max(0, (int)(centre - support + 0.5)), hi = Math.Min(sn, (int)(centre + support + 0.5));
      var w = new double[Math.Max(0, hi - lo)]; double ws = 0;
      for (int k = lo; k < hi; k++) { w[k - lo] = Lanczos((k - centre + 0.5) / fs); ws += w[k - lo]; }
      if (ws != 0) for (int k = 0; k < w.Length; k++) w[k] /= ws;
      for (int j = 0; j < other; j++) {
        double acc = 0;
        for (int k = lo; k < hi; k++) acc += w[k - lo] * (horiz ? s[j * sw + k] : s[k * sw + j]);
        if (horiz) d[j * dn + i] = acc; else d[i * sw + j] = acc;
      }
    }
  }
  static OUTexture Build(OUAssets a, string num) {
    string font = FontFor(num);
    var ft = OUDxt.Load(a.Get(font + ".dxt")); var cel = a.Get(font + ".cel");
    if (ft == null || cel == null) throw new FileNotFoundException("plate font " + font + " not found in stock assets");
    var gl = ParseCel(cel); int fw = ft.W, fh = ft.H;
    var cells = new List<int[]>();
    foreach (char ch in num) { float[] g; if (!gl.TryGetValue(ch, out g)) continue;
      int x0 = (int)Math.Round(g[0] * fw), y0 = (int)Math.Round(g[1] * fh), x1 = (int)Math.Round(g[2] * fw), y1 = (int)Math.Round(g[3] * fh); cells.Add(new[] { x0, y0, x1, y1 }); }
    var px = new byte[TW * TH * 4];
    for (int i = 0; i < TW * TH; i++) { px[i * 4] = px[i * 4 + 1] = px[i * 4 + 2] = 0; px[i * 4 + 3] = 0; }
    // lower row colour (premultiplied-safe: transparent texels carry the row colour so bilinear shading has no fringe)
    int lrow0 = (int)(0.75 * TH); var lc = LowerRowColor;
    for (int y = lrow0; y < TH; y++) for (int x = 0; x < TW; x++) { int q = (y * TW + x) * 4; px[q] = lc.R; px[q + 1] = lc.G; px[q + 2] = lc.B; }
    if (cells.Count == 0) return OUTexture.FromRgba(TW, TH, px);
    // scale from the first glyph's ink rows (as num_tex.make_nd ink_band='black')
    var c0 = cells[0]; int ch0 = c0[3] - c0[1], ink0 = -1, ink1 = -1;
    for (int y = 0; y < ch0; y++) { bool any = false; for (int x = c0[0]; x < c0[2]; x++) { int q = ((c0[1] + y) * fw + x) * 4; if (ft.Px[q + 3] > 128 && Math.Max(ft.Px[q], Math.Max(ft.Px[q + 1], ft.Px[q + 2])) < 100) { any = true; break; } } if (any) { if (ink0 < 0) ink0 = y; ink1 = y + 1; } }
    if (ink0 < 0) { ink0 = 0; ink1 = ch0; }
    double sc = (Band1 - Band0) * TH / (ink1 - ink0), top = Band0 * TH - ink0 * sc; int gh = (int)Math.Round(ch0 * sc);
    var glyphs = new List<double[]>(); var widths = new List<int>(); double tot = 0;
    foreach (var c in cells) {
      int w = c[2] - c[0], h = c[3] - c[1]; var A = new double[w * h];
      for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) A[y * w + x] = ft.Px[((c[1] + y) * fw + c[0] + x) * 4 + 3];
      int dw = Math.Max(1, (int)Math.Round(w * sc)); glyphs.Add(Resize(A, w, h, dw, gh)); widths.Add(dw); tot += dw;
    }
    for (int row = 0; row < 2; row++) {
      double x = CentreU * TW - tot / 2; int oy = (int)Math.Round(top + row * RowStep * TH);
      for (int gi = 0; gi < glyphs.Count; gi++) {
        int ox = (int)Math.Round(x), dw = widths[gi]; var G = glyphs[gi];
        for (int y = 0; y < gh; y++) { int ty = oy + y; if (ty < 0 || ty >= TH) continue;
          for (int xx = 0; xx < dw; xx++) { int tx = ox + xx; if (tx < 0 || tx >= TW) continue;
            double al = G[y * dw + xx] / 255.0; if (al <= 0) continue; if (al > 1) al = 1;
            int q = (ty * TW + tx) * 4; double da = px[q + 3] / 255.0, oa = al + da * (1 - al);
            px[q + 3] = (byte)Math.Min(255, (int)(oa * 255 + 0.5)); } }
        x += dw;
      }
    }
    return OUTexture.FromRgba(TW, TH, px);
  }
  public static Bitmap ToBitmap(OUTexture t) {
    var bm = new Bitmap(t.W, t.H, PixelFormat.Format32bppArgb); var raw = new int[t.W * t.H];
    for (int i = 0; i < raw.Length; i++) raw[i] = (t.Px[i * 4 + 3] << 24) | (t.Px[i * 4] << 16) | (t.Px[i * 4 + 1] << 8) | t.Px[i * 4 + 2];
    var bd = bm.LockBits(new Rectangle(0, 0, t.W, t.H), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
    for (int y = 0; y < t.H; y++) Marshal.Copy(raw, y * t.W, new IntPtr(bd.Scan0.ToInt64() + (long)y * bd.Stride), t.W);
    bm.UnlockBits(bd); return bm;
  }
}
