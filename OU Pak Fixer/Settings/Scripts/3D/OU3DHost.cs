// OU3DHost.cs - Pak Fixer glue for the 3D renderer (OURender.cs + OULiveView.cs). C# 5 / .NET 4.x.
// One background worker thread does all model/texture loading and preview rendering, so the WinForms UI thread
// never blocks: card thumbnails (ThumbAsync), live Showroom scenes (SceneAsync) and Make previews (MakeForPakAsync).
// Preview files: Pack Manager\Previews\<pak>__<Item>__stack.png (side over 3/4 front) and __side.png (side only).
// Rider number on the plates: SetRider(number, name). Previews older than Previews\_rider_plate.txt (rewritten when the
// number changes) count as stale, so cached thumbnails / Make Previews re-render with the new number.
// ShowNumber (Showroom 'Show numbers' toggle): off = bare plates in the Showroom (card thumbs + live/fullscreen view).
// Thumbs then use Previews\_nonum\ (separate cache, so toggling back and forth is instant once rendered).
// Make Previews (MakeForPak / EnsurePreviews / SidePath / StackPath) always renders the numbered, in-game look.
// Bar pad / hand guards (SetBarParts, from the save's MXA.Rider.FatBar / MXA.Rider.HandGuards): only the rider's pad is drawn
// everywhere. Previews\_bike_parts.txt is rewritten when the choice changes; every preview older than it counts as stale.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

public sealed class OU3DJob {
  public volatile bool Done; public int Made, Fresh, Failed; public long Ms; public string Errors = ""; public List<string> Slots = new List<string>();
}

public static class OU3DHost {
  public static string GameData = "", PreviewDir = ""; public static volatile string LastError = "";
  public static int PreviewW = 800, PreviewH = 500, MaxScenes = 6;
  static OUAssets stock; static readonly object stockGate = new object(), renderGate = new object(), qGate = new object();
  sealed class Job { public string Key; public Action Run; }
  static readonly LinkedList<Job> hi = new LinkedList<Job>(), lo = new LinkedList<Job>();
  static readonly HashSet<string> pending = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
  static Thread worker;
  static readonly List<KeyValuePair<string, OUBikeScene>> scenes = new List<KeyValuePair<string, OUBikeScene>>();
  static readonly Regex slotRx = new Regex(@"_Plastics(_\d+)?$", RegexOptions.IgnoreCase);

  public static void Init(string gameData, string previewDir) {
    lock (stockGate) { GameData = gameData ?? ""; PreviewDir = previewDir ?? ""; stock = null; }
    lock (scenes) scenes.Clear();
    // previews are judged against the existing stamp until the host calls SetRider (which rewrites it only on a change)
    stampUtc = DateTime.MinValue; try { var sp = StampPath; if (sp.Length > 0 && File.Exists(sp)) stampUtc = File.GetLastWriteTimeUtc(sp); } catch { }
    // no parts stamp yet = previews made before bar-pad support (both pads drawn): stale until SetBarParts writes one
    partsUtc = DateTime.MaxValue; try { var pp = PartsStampPath; if (pp.Length > 0 && File.Exists(pp)) partsUtc = File.GetLastWriteTimeUtc(pp); } catch { }
  }
  // ---- handlebar parts (bar pad + hand guards) ----
  public static bool FatBar { get { return OUBikeParts.FatBarOn; } }
  public static bool HandGuards { get { return OUBikeParts.HandGuardsOn; } }
  public static string BarPadName { get { return OUBikeParts.FatBarOn ? "Round (fat bar)" : "Block (crossbar)"; } }
  static DateTime partsUtc = DateTime.MaxValue;
  public static string PartsStampPath { get { return string.IsNullOrEmpty(PreviewDir) ? "" : Path.Combine(PreviewDir, "_bike_parts.txt"); } }
  // Returns true if what the bikes show changed (cards should re-request their thumbs; the live view is updated here).
  public static bool SetBarParts(bool fatBar, bool handGuards) {
    bool changed = fatBar != OUBikeParts.FatBarOn || handGuards != OUBikeParts.HandGuardsOn;
    OUBikeParts.FatBarOn = fatBar; OUBikeParts.HandGuardsOn = handGuards;
    lock (scenes) { foreach (var kv in scenes) kv.Value.SetParts(fatBar, handGuards); }
    string p = PartsStampPath;
    if (p.Length > 0) {
      try {
        string want = "fatbar=" + (fatBar ? 1 : 0) + "\r\nhandguards=" + (handGuards ? 1 : 0) + "\r\n", have = File.Exists(p) ? File.ReadAllText(p) : null;
        if (have != want) { Directory.CreateDirectory(PreviewDir); File.WriteAllText(p, want); changed = true; }
        partsUtc = File.GetLastWriteTimeUtc(p);
      } catch { }
    }
    return changed;
  }
  // ---- rider number / name ----
  // RiderNumber = the rider's number (what Make Previews draws). OURiderPlate.Number = what the Showroom shows now
  // (RiderNumber, or "" while ShowNumber is off); new and cached scenes follow OURiderPlate.Number.
  static volatile string riderNum = "";
  static volatile bool showNumber = true;
  public static string RiderNumber { get { return riderNum; } }
  public static string RiderName { get { return OURiderPlate.Name; } }
  public static bool ShowNumber { get { return showNumber; } }
  public static string DisplayNumber { get { return OURiderPlate.Number; } }
  static DateTime stampUtc = DateTime.MinValue;
  public static string StampPath { get { return string.IsNullOrEmpty(PreviewDir) ? "" : Path.Combine(PreviewDir, "_rider_plate.txt"); } }
  public static string NoNumDir { get { return string.IsNullOrEmpty(PreviewDir) ? "" : Path.Combine(PreviewDir, "_nonum"); } }
  // Returns true if the rider number or what the Showroom shows changed (cards should re-request their thumbs).
  public static bool SetRider(string number, string name) { return SetRider(number, name, showNumber); }
  public static bool SetRider(string number, string name, bool show) {
    string n = OURiderPlate.Clean(number), nm = (name ?? "").Trim();
    bool numChanged = n != riderNum;
    riderNum = n; showNumber = show; OURiderPlate.Name = nm;
    bool dispChanged = ApplyDisplay();
    WriteStamp();
    return numChanged || dispChanged;
  }
  // Showroom toggle only (no file writes). Returns true if what the Showroom shows changed.
  public static bool SetShowNumber(bool show) { showNumber = show; return ApplyDisplay(); }
  static bool ApplyDisplay() {
    string d = showNumber ? riderNum : "";
    if (d == OURiderPlate.Number) return false;
    OURiderPlate.Number = d;
    lock (scenes) { foreach (var kv in scenes) kv.Value.SetRiderNumber(d); }
    return true;
  }
  // stamp file content = rider number; rewritten (mtime bumped) only when it differs from what the previews were made with
  static void WriteStamp() {
    string p = StampPath; if (p.Length == 0) return;
    try {
      string want = "number=" + riderNum + "\r\nname=" + OURiderPlate.Name + "\r\n", have = File.Exists(p) ? File.ReadAllText(p) : null;
      string wantNum = "number=" + riderNum + "\r\n";
      if (have == null || !have.StartsWith(wantNum, StringComparison.Ordinal)) { Directory.CreateDirectory(PreviewDir); File.WriteAllText(p, want); }
      else if (have != want) { var t = File.GetLastWriteTimeUtc(p); File.WriteAllText(p, want); File.SetLastWriteTimeUtc(p, t); }   // name only: no re-render
      stampUtc = File.GetLastWriteTimeUtc(p);
    } catch { }
  }
  public static void ApplyRiderToView(OULiveView v) {
    if (v == null || v.IsDisposed) return; var sc = v.Scene; if (sc == null) return;
    if (sc.RiderNumber != OURiderPlate.Number) sc.SetRiderNumber(OURiderPlate.Number);
    if (!sc.PartsMatch(OUBikeParts.FatBarOn, OUBikeParts.HandGuardsOn)) sc.SetParts(OUBikeParts.FatBarOn, OUBikeParts.HandGuardsOn);
    v.MarkDirty(); v.Invalidate();
  }
  public static OUAssets Stock() {
    lock (stockGate) {
      if (stock == null) {
        if (string.IsNullOrEmpty(GameData) || !File.Exists(Path.Combine(GameData, "common.pak"))) throw new FileNotFoundException("common.pak not found in the game folder");
        stock = OURender3D.Stock(GameData, null);
      }
      return stock;
    }
  }
  // TOC + .sub index (the only stock work that is not per bike). Call off the UI thread.
  public static int Warm() { return OUSubIndex.Build(Stock()).Count; }
  public static bool IsSlotName(string baseName) { return !string.IsNullOrEmpty(baseName) && slotRx.IsMatch(baseName) && !baseName.EndsWith("_AI", StringComparison.OrdinalIgnoreCase); }
  public static bool HasModel(string slot) {
    try { return IsSlotName(slot) && OUSubIndex.FindSubs(Stock(), slot).Count > 0; } catch { return false; }
  }
  // *_Plastics / *_Plastics_NN textures in the pak that have a stock bike model
  public static List<string> SlotsInPak(string pak) {
    var r = new List<string>(); var st = Stock();
    foreach (var kv in OUAssets.ReadPakToc(pak)) {
      string full = kv.Key.Replace('/', '\\'); if (!full.EndsWith(".dxt", StringComparison.OrdinalIgnoreCase)) continue;
      string n = Path.GetFileNameWithoutExtension(full.Substring(full.LastIndexOf('\\') + 1));
      if (!IsSlotName(n)) continue;
      bool dup = false; foreach (var x in r) if (x.Equals(n, StringComparison.OrdinalIgnoreCase)) { dup = true; break; }
      if (!dup && OUSubIndex.FindSubs(st, n).Count > 0) r.Add(n);
    }
    return r;
  }
  // Numbered (in-game look, Make Previews) files live in PreviewDir; bare-plate Showroom thumbs in PreviewDir\_nonum.
  // With no rider number both looks are the same, so the main files are used.
  static bool Bare(bool numbered) { return !numbered && riderNum.Length > 0; }
  public static string SidePath(string pak, string slot) { return SidePath(pak, slot, true); }
  public static string StackPath(string pak, string slot) { return StackPath(pak, slot, true); }
  public static string SidePath(string pak, string slot, bool numbered) { return Path.Combine(Bare(numbered) ? NoNumDir : PreviewDir, OURender3D.PreviewName(Path.GetFileName(pak), slot, "side")); }
  public static string StackPath(string pak, string slot, bool numbered) { return Path.Combine(Bare(numbered) ? NoNumDir : PreviewDir, OURender3D.PreviewName(Path.GetFileName(pak), slot, "stack")); }
  public static bool IsFresh(string pak, string slot) { return IsFresh(pak, slot, true); }
  public static bool IsFresh(string pak, string slot, bool numbered) {
    string a = SidePath(pak, slot, numbered), b = StackPath(pak, slot, numbered);
    if (!File.Exists(a) || !File.Exists(b)) return false;
    var t = File.GetLastWriteTimeUtc(pak); if (!Bare(numbered) && stampUtc > t) t = stampUtc;   // rider number changed after the pak
    if (partsUtc == DateTime.MaxValue) return false; if (partsUtc > t) t = partsUtc;   // bar pad / hand guards changed after the pak
    return File.GetLastWriteTimeUtc(a) > t && File.GetLastWriteTimeUtc(b) > t;
  }
  public static bool AllFresh(string pak) { foreach (var s in SlotsInPak(pak)) if (!IsFresh(pak, s)) return false; return true; }

  // Model (cached per .sub by OURender) + only the textures that model uses, taken from the pak (stock for the rest).
  public static OUBikeScene Scene(string pak, string slot) {
    string key = pak + "|" + slot + "|" + File.GetLastWriteTimeUtc(pak).Ticks;
    lock (scenes) for (int i = 0; i < scenes.Count; i++) if (scenes[i].Key == key) {
      var hit = scenes[i]; scenes.RemoveAt(i); scenes.Add(hit);
      if (hit.Value.RiderNumber != OURiderPlate.Number) hit.Value.SetRiderNumber(OURiderPlate.Number);
      if (!hit.Value.PartsMatch(OUBikeParts.FatBarOn, OUBikeParts.HandGuardsOn)) hit.Value.SetParts(OUBikeParts.FatBarOn, OUBikeParts.HandGuardsOn);
      return hit.Value; }
    var sc = BuildScene(pak, slot);
    lock (scenes) { scenes.Add(new KeyValuePair<string, OUBikeScene>(key, sc)); while (scenes.Count > MaxScenes) scenes.RemoveAt(0); }
    return sc;
  }
  static OUBikeScene BuildScene(string pak, string slot) {
    var st = Stock(); var model = OURender3D.ModelForSlot(st, slot);
    var pa = new OUAssets(); pa.AddPak(pak);
    var ov = new Dictionary<string, byte[]>(StringComparer.OrdinalIgnoreCase);
    foreach (var m in model.Materials) { var b = pa.Get(m + ".dxt"); if (b != null) ov[m] = b; }
    return new OUBikeScene(model, st, ov);
  }
  // Render stack + side PNGs if missing/stale. Returns true if rendered, false if already fresh.
  // numbered = true: in-game look (rider number), Make Previews. false: bare plates (Showroom with numbers off).
  public static bool EnsurePreviews(string pak, string slot, bool force) { return EnsurePreviews(pak, slot, force, true); }
  public static bool EnsurePreviews(string pak, string slot, bool force, bool numbered) {
    lock (renderGate) {
      if (!force && IsFresh(pak, slot, numbered)) return false;
      string st = StackPath(pak, slot, numbered), sd = SidePath(pak, slot, numbered), tst = st + ".tmp", tsd = sd + ".tmp";
      Directory.CreateDirectory(Path.GetDirectoryName(st));
      string plate = numbered ? riderNum : "";
      var sc = Scene(pak, slot);
      // the cached scene shows what the Showroom shows; a different look gets its own scene so the live view never flickers
      if (sc.RiderNumber != plate) { sc = BuildScene(pak, slot); sc.SetRiderNumber(plate); }
      sc.SetParts(OUBikeParts.FatBarOn, OUBikeParts.HandGuardsOn);   // previews always show the rider's bar pad
      OURender3D.SavePreviews(sc, tst, tsd, PreviewW, PreviewH, Color.Transparent);
      Swap(tst, st); Swap(tsd, sd);
      return true;
    }
  }
  static void Swap(string tmp, string dst) { if (File.Exists(dst)) File.Delete(dst); File.Move(tmp, dst); }

  public static OU3DJob MakeForPak(string pak) {
    var j = new OU3DJob(); var sw = System.Diagnostics.Stopwatch.StartNew();
    try {
      j.Slots = SlotsInPak(pak);
      foreach (var s in j.Slots) {
        try { if (EnsurePreviews(pak, s, false)) j.Made++; else j.Fresh++; }
        catch (Exception ex) { j.Failed++; j.Errors += (j.Errors.Length > 0 ? "; " : "") + s + ": " + Inner(ex).Message; }
      }
    } catch (Exception ex) { j.Failed++; j.Errors += (j.Errors.Length > 0 ? "; " : "") + Inner(ex).Message; }
    j.Ms = sw.ElapsedMilliseconds; j.Done = true; return j;
  }
  // Same on the worker thread; poll job.Done (the UI pumps messages meanwhile).
  public static OU3DJob MakeForPakAsync(string pak) {
    var j = new OU3DJob();
    Enqueue(true, null, () => {
      var r = MakeForPak(pak); j.Slots = r.Slots; j.Made = r.Made; j.Fresh = r.Fresh; j.Failed = r.Failed; j.Errors = r.Errors; j.Ms = r.Ms; j.Done = true;
    }, () => { j.Done = true; });
    return j;
  }

  // Card thumbnail: side-only 3D image (rendered + cached in Previews if missing), scaled to maxW x maxH, set on the
  // PictureBox if its Tag is unchanged. Failure leaves the current (flat) image alone. Newest request runs first.
  public static void ThumbAsync(PictureBox pb, string pak, string slot, int maxW, int maxH) {
    if (pb == null || pb.IsDisposed) return;
    string tag = pb.Tag == null ? "" : pb.Tag.ToString();
    Enqueue(false, "thumb|" + tag + "|" + slot, () => {
      if (pb.IsDisposed) return;
      Bitmap bm = null;
      bool numbered = showNumber;   // card thumbs follow the Showroom 'Show numbers' toggle
      try { EnsurePreviews(pak, slot, false, numbered); bm = LoadScaled(SidePath(pak, slot, numbered), maxW, maxH); }
      catch (Exception ex) { LastError = slot + ": " + Inner(ex).Message; return; }
      var b2 = bm;
      if (!Post(pb, () => {
        if (pb.IsDisposed || (pb.Tag == null ? "" : pb.Tag.ToString()) != tag) { b2.Dispose(); return; }
        pb.Image = b2;
      })) b2.Dispose();
    }, null);
  }
  // Thumb for the current toggle already on disk and fresh? (lets the UI show it straight away)
  public static bool ThumbFresh(string pak, string slot) { try { return IsFresh(pak, slot, showNumber); } catch { return false; } }
  public static void CancelThumbs() { lock (qGate) { foreach (var j in lo) if (j.Key != null) pending.Remove(j.Key); lo.Clear(); } }

  // Live Showroom view: build the scene on the worker, hand it to the view if the view still wants this token.
  public static void SceneAsync(OULiveView v, string pak, string slot, string token) {
    if (v == null) return;
    v.Tag = token; v.Scene = null; v.Message = "Loading 3D model..."; v.Invalidate();
    Enqueue(true, null, () => {
      OUBikeScene sc = null; string err = null;
      try { sc = Scene(pak, slot); } catch (Exception ex) { err = Inner(ex).Message; LastError = slot + ": " + err; }
      Post(v, () => {
        if (v.IsDisposed || !object.Equals(v.Tag, token)) return;
        if (sc != null) { v.Message = ""; v.Scene = sc; } else { v.Message = "3D model unavailable: " + err; v.Invalidate(); }
      });
    }, null);
  }

  public static Bitmap LoadScaled(string png, int maxW, int maxH) {
    using (var ms = new MemoryStream(File.ReadAllBytes(png))) using (var src = Image.FromStream(ms)) {
      double s = 1; if (maxW > 0 && maxH > 0) s = Math.Min(1.0, Math.Min(maxW / (double)src.Width, maxH / (double)src.Height));
      int w = Math.Max(1, (int)Math.Round(src.Width * s)), h = Math.Max(1, (int)Math.Round(src.Height * s));
      var bm = new Bitmap(w, h, PixelFormat.Format32bppArgb);
      using (var g = Graphics.FromImage(bm)) { g.InterpolationMode = InterpolationMode.HighQualityBicubic; g.PixelOffsetMode = PixelOffsetMode.HighQuality; g.DrawImage(src, 0, 0, w, h); }
      return bm;
    }
  }

  static Exception Inner(Exception e) { while (e.InnerException != null) e = e.InnerException; return e; }
  // Run a on c's UI thread. If c has no window handle yet (just created / not shown), defer until HandleCreated.
  static bool Post(Control c, Action a) {
    if (c == null || c.IsDisposed) return false;
    try {
      if (c.IsHandleCreated) { c.BeginInvoke(a); return true; }
      int fired = 0; EventHandler h = null;
      h = delegate(object s, EventArgs e) {
        c.HandleCreated -= h;
        if (Interlocked.Exchange(ref fired, 1) == 0) { try { c.BeginInvoke(a); } catch { } }
      };
      c.HandleCreated += h;
      if (c.IsHandleCreated) h(c, EventArgs.Empty);   // created while subscribing
      return true;
    } catch { return false; }
  }
  static void Enqueue(bool high, string key, Action run, Action onDrop) {
    lock (qGate) {
      if (key != null) { if (pending.Contains(key)) { if (onDrop != null) onDrop(); return; } pending.Add(key); }
      (high ? hi : lo).AddLast(new Job { Key = key, Run = run });
      if (worker == null) { worker = new Thread(Loop); worker.IsBackground = true; worker.Name = "OU3D worker"; worker.Priority = ThreadPriority.BelowNormal; worker.Start(); }
      Monitor.Pulse(qGate);
    }
  }
  static void Loop() {
    while (true) {
      Job j;
      lock (qGate) {
        while (hi.Count == 0 && lo.Count == 0) Monitor.Wait(qGate);
        if (hi.Count > 0) { j = hi.First.Value; hi.RemoveFirst(); } else { j = lo.Last.Value; lo.RemoveLast(); }   // thumbs: newest first
        if (j.Key != null) pending.Remove(j.Key);
      }
      try { j.Run(); } catch (Exception ex) { LastError = Inner(ex).Message; }
    }
  }
  public static int QueueLength { get { lock (qGate) return hi.Count + lo.Count; } }
}
