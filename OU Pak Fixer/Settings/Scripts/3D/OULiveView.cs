// OULiveView.cs - WinForms control: live rotating 3D bike for the Showroom preview panel.
// Needs OURender.cs. Add-Type -ReferencedAssemblies System.Drawing,System.Windows.Forms -TypeDefinition ((gc OURender.cs -Raw) + (gc OULiveView.cs -Raw))
// Usage (PowerShell):  $v = New-Object OULiveView; $v.Dock='Fill'; $panel.Controls.Add($v); $v.Scene = [OURender3D]::SceneForSlot($stock,'KTM250SX_01_Plastics',$tex)
// Auto-rotates on a timer; left-drag rotates (yaw/pitch); wheel zooms; double-click resets. Rendering runs on a worker thread; the UI thread only blits.
using System;
using System.Drawing;
using System.Threading;
using System.Windows.Forms;

public class OULiveView : Control {
  OUBikeScene scene; readonly object gate = new object(); Bitmap frame; readonly OURenderBuffers buf = new OURenderBuffers();
  readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
  int busy; bool dirty = true; DateTime lastTick = DateTime.Now, lastInteract = DateTime.MinValue; Point dragFrom; bool dragging;
  public double Yaw = 90, Pitch = 12, Zoom = 1, AutoRotateDegPerSec = 24; public bool AutoRotate = true;
  public double LastFrameMs; public int LastSS = 1; public string Message = ""; public bool Paused;
  public OULiveView() {
    SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
    BackColor = Color.FromArgb(28, 29, 34); ForeColor = Color.Gainsboro;
    timer.Interval = 33; timer.Tick += OnTick; timer.Start();
  }
  public OUBikeScene Scene { get { return scene; } set { scene = value; Yaw = 90; Pitch = 12; Zoom = 1; dirty = true; Bitmap old; lock (gate) { old = frame; frame = null; } if (old != null) old.Dispose(); Invalidate(); } }
  // re-render the current view (e.g. after the scene's rider number changed)
  public void MarkDirty() { dirty = true; }
  void OnTick(object s, EventArgs e) {
    var now = DateTime.Now; double dt = (now - lastTick).TotalSeconds; lastTick = now;
    if (scene == null || !Visible || Paused) return;
    var f = FindForm(); if (f != null && f.WindowState == FormWindowState.Minimized) return;
    if (AutoRotate && !dragging && (now - lastInteract).TotalSeconds > 1.5) { Yaw = (Yaw + AutoRotateDegPerSec * dt) % 360; dirty = true; }
    if (!dirty && LastSS == 1 && !dragging && (now - lastInteract).TotalSeconds > 0.3) dirty = true; // refine a still frame to ss2
    if (dirty) Kick();
  }
  void Kick() {
    if (scene == null || Width < 8 || Height < 8) return;
    if (Interlocked.CompareExchange(ref busy, 1, 0) != 0) return;  // one render in flight; newest state picked up next tick
    dirty = false;
    double yaw = Yaw, pitch = Pitch, zoom = Zoom; int w = Width, h = Height; var sc = scene;
    bool moving = dragging || (now() - lastInteract).TotalSeconds < 0.3 || (AutoRotate && !dragging);
    // supersample when it is cheap enough (<= ~35 ms at ss2), always ss1 while dragging
    int ss = dragging ? 1 : ((moving && LastFrameMs * (LastSS == 1 ? 3.2 : 1) > 35) ? 1 : 2);
    ThreadPool.QueueUserWorkItem(_ => {
      Bitmap bm = null; var sw = System.Diagnostics.Stopwatch.StartNew();
      try { bm = sc.Render(yaw, pitch, zoom, w, h, ss, false, Color.Transparent, buf); }
      catch (Exception ex) { Message = ex.Message; }
      LastFrameMs = sw.Elapsed.TotalMilliseconds; LastSS = ss;
      Bitmap old = null; lock (gate) { if (bm != null) { if (object.ReferenceEquals(sc, scene)) { old = frame; frame = bm; } else old = bm; } }
      if (old != null) old.Dispose();
      Interlocked.Exchange(ref busy, 0);
      try { if (IsHandleCreated && !IsDisposed) BeginInvoke((MethodInvoker)Invalidate); } catch { }
    });
  }
  static DateTime now() { return DateTime.Now; }
  protected override void OnPaint(PaintEventArgs e) {
    var g = e.Graphics; g.Clear(BackColor);
    lock (gate) { if (frame != null) g.DrawImage(frame, new Rectangle(0, 0, frame.Width, frame.Height)); }
    if (scene == null || Message.Length > 0) TextRenderer.DrawText(g, scene == null ? "No 3D model" : Message, Font, ClientRectangle, ForeColor, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.WordBreak);
  }
  protected override void OnResize(EventArgs e) { base.OnResize(e); dirty = true; }
  protected override void OnMouseDown(MouseEventArgs e) { base.OnMouseDown(e); if (e.Button == MouseButtons.Left) { dragging = true; dragFrom = e.Location; Capture = true; } }
  protected override void OnMouseMove(MouseEventArgs e) {
    base.OnMouseMove(e); if (!dragging) return;
    Yaw = (Yaw + (e.X - dragFrom.X) * 0.5) % 360; Pitch = Math.Max(-10, Math.Min(70, Pitch + (e.Y - dragFrom.Y) * 0.3));
    dragFrom = e.Location; lastInteract = DateTime.Now; dirty = true; Kick();
  }
  protected override void OnMouseUp(MouseEventArgs e) { base.OnMouseUp(e); dragging = false; Capture = false; lastInteract = DateTime.Now; dirty = true; }
  protected override void OnMouseWheel(MouseEventArgs e) { base.OnMouseWheel(e); Zoom = Math.Max(0.5, Math.Min(4, Zoom * Math.Pow(1.12, e.Delta / 120.0))); lastInteract = DateTime.Now; dirty = true; Kick(); }
  protected override void OnMouseEnter(EventArgs e) { base.OnMouseEnter(e); Focus(); }
  protected override void OnDoubleClick(EventArgs e) { base.OnDoubleClick(e); Yaw = 90; Pitch = 12; Zoom = 1; lastInteract = DateTime.Now; dirty = true; }
  protected override void Dispose(bool disposing) { if (disposing) { timer.Stop(); timer.Dispose(); lock (gate) { if (frame != null) frame.Dispose(); frame = null; } } base.Dispose(disposing); }
}
