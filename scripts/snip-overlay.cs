// dsh-snip — 快速截图交互层（独立进程，原创 MIT 实现）
//
// 设计借鉴（仅思路，代码原创）：
//   Greenshot CaptureForm —— SetStyle(OptimizedDoubleBuffer|AllPaintingInWmPaint|UserPaint)
//                            + 预渲染压暗背景，每帧只是两张位图 blit
//   ShareX RegionCaptureForm —— 全屏无边框窗体 + 顶层窗口枚举/DWM 窗口吸附
//
// 交互：悬停自动高亮窗口（左键点一下=整窗选中，QQ 式）/ 拖拽自由框选
//       （选区外压暗、蓝框、白色手柄、实时尺寸）/ 松手出确认工具条
//       / 回车或双击确认 / 点工具条或选区外重新框选 / ESC 取消
//
// 编译（宿主挂载时预热，或 snip.ps1 兜底现编）：
//   csc /nologo /target:exe /platform:anycpu /r:System.dll /r:System.Drawing.dll
//       /r:System.Windows.Forms.dll snip-overlay.cs
// 运行：snip-overlay.exe [-Out <png 路径>] [-NoHide]
// 输出：stdout 单行 JSON（非 ASCII 转 \uXXXX）；状态落盘 run.json / last.json
//
// 为什么是独立 exe：旧链路「powershell.exe 启动(1-2s) + WinForms 程序集加载 +
// CodeDom 编译(1-2s)」让点击到遮罩出现要 3-5 秒；预热好的 exe 冷启动 <1s。
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace DshSnip {
  internal class SnipResult {
    public bool Confirmed;
    public bool Cancelled;
    public int X;
    public int Y;
    public int Width;
    public int Height;   // 虚拟屏物理像素坐标
  }

  internal class OverlayForm : Form {
    private enum Mode { Idle, Dragging, Selected }

    private Bitmap bg;      // 冻结画面（调用方持有，窗体只读）
    private Bitmap dim;     // 预渲染的压暗画面：每帧 DrawImageUnscaled 一次即可
    private int vsX, vsY;
    private Mode mode = Mode.Idle;
    private Point startPt, curPt;               // 客户区坐标
    private Rectangle selRect = Rectangle.Empty; // 客户区坐标
    private Rectangle hover = Rectangle.Empty;   // 窗口吸附高亮（客户区坐标）
    private Rectangle btnOk = Rectangle.Empty, btnCancel = Rectangle.Empty;
    private int hoverBtn = 0;                    // 0 无 / 1 确认 / 2 取消
    private Rectangle hoverAtDown = Rectangle.Empty;  // 按下瞬间的吸附框：MouseUp 判定"点一下=选中窗口"要用
    public SnipResult result = new SnipResult();
    private Font fontTip, fontLabel, fontBtn;
    private static readonly Color Accent = Color.FromArgb(255, 45, 130, 240);

    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lparam);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hwnd, out RECT r);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out RECT r, int size);
    private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lparam);
    [StructLayout(LayoutKind.Sequential)]
    internal struct RECT { public int L; public int T; public int R; public int B; }
    private const int GWL_EXSTYLE = -20;
    private const int WS_EX_TRANSPARENT = 0x20;
    private const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;
    private const int DWMWA_CLOAKED = 14;

    private Point hitScreen;
    private Rectangle hitRect;

    public OverlayForm(Bitmap background, int x, int y, int w, int h) {
      bg = background;
      vsX = x; vsY = y;
      // Greenshot 同款三件套：消除重绘白闪/撕裂
      SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint, true);

      FormBorderStyle = FormBorderStyle.None;
      StartPosition = FormStartPosition.Manual;
      Location = new Point(x, y);
      Size = new Size(w, h);
      TopMost = true;
      ShowInTaskbar = false;
      Cursor = Cursors.Cross;
      KeyPreview = true;

      fontTip = new Font("Microsoft YaHei", 11f);
      fontLabel = new Font("Microsoft YaHei", 9f);
      fontBtn = new Font("Microsoft YaHei", 10f);

      // 预渲染压暗背景（一次）：每帧只剩两张位图 blit + 矢量小元素
      dim = new Bitmap(w, h);
      using (Graphics g = Graphics.FromImage(dim)) {
        g.DrawImageUnscaled(bg, 0, 0);
        using (SolidBrush b = new SolidBrush(Color.FromArgb(96, 10, 12, 18))) {
          g.FillRectangle(b, 0, 0, w, h);
        }
      }
    }

    private static Rectangle NormRect(Point a, Point b) {
      return Rectangle.FromLTRB(
        Math.Min(a.X, b.X), Math.Min(a.Y, b.Y),
        Math.Max(a.X, b.X), Math.Max(a.Y, b.Y));
    }

    // 鼠标下的顶层窗口可见边框（DWM 扩展边框=不含阴影，和 QQ/微信观感一致）。
    // 不能用 WindowFromPoint——全屏遮罩自己就是最顶层窗口，它永远只会返回遮罩自身；
    // 正确做法（Greenshot 同款）：按 Z 序枚举顶层窗口做命中测试，跳过自身和不可交互窗口。
    private Rectangle WindowUnder(Point screen) {
      try {
        hitScreen = screen;
        hitRect = Rectangle.Empty;
        EnumWindows(delegate(IntPtr h, IntPtr lp) {
          if (h == Handle) return true;
          if (!IsWindowVisible(h)) return true;
          int ex = GetWindowLong(h, GWL_EXSTYLE);
          if ((ex & WS_EX_TRANSPARENT) != 0) return true;
          RECT cloak;
          if (DwmGetWindowAttribute(h, DWMWA_CLOAKED, out cloak, Marshal.SizeOf(typeof(RECT))) == 0 && cloak.L != 0) return true;
          RECT rc;
          int hr = DwmGetWindowAttribute(h, DWMWA_EXTENDED_FRAME_BOUNDS, out rc, Marshal.SizeOf(typeof(RECT)));
          if (hr != 0 && !GetWindowRect(h, out rc)) return true;
          Rectangle r = Rectangle.FromLTRB(rc.L, rc.T, rc.R, rc.B);
          if (r.Width < 20 || r.Height < 20) return true;
          if (r.Contains(screen)) {
            r.Offset(-vsX, -vsY);
            // 桌面/全屏窗口不吸（吸了等于没有）
            if (r.Width >= ClientSize.Width - 4 && r.Height >= ClientSize.Height - 4) return true;
            hitRect = r;
            return false;   // Z 序第一个命中的就是最上层窗口，停止枚举
          }
          return true;
        }, IntPtr.Zero);
        return hitRect;
      } catch { return Rectangle.Empty; }
    }

    protected override void OnPaint(PaintEventArgs e) {
      Graphics g = e.Graphics;
      g.SmoothingMode = SmoothingMode.AntiAlias;
      g.DrawImageUnscaled(dim, 0, 0);

      Rectangle r = Rectangle.Empty;
      if (mode == Mode.Dragging) r = NormRect(startPt, curPt);
      else if (mode == Mode.Selected) r = selRect;

      if (!r.IsEmpty && r.Width >= 2 && r.Height >= 2) {
        // 选区内恢复原亮度：clip 后直接贴原始冻结图（比反向画 4 个压暗矩形快）
        g.SetClip(r);
        g.DrawImageUnscaled(bg, 0, 0);
        g.ResetClip();
        using (Pen pen = new Pen(Accent, 2f)) { g.DrawRectangle(pen, r); }
        DrawHandles(g, r);
        DrawSizeLabel(g, r);
      } else {
        if (mode == Mode.Idle && !hover.IsEmpty) {
          using (Pen pen = new Pen(Accent, 2f)) {
            pen.DashStyle = DashStyle.Dash;
            g.DrawRectangle(pen, hover);
          }
        }
        if (mode == Mode.Idle) {
          string tip = "自动识别窗口 · 按住左键拖拽框选（点一下=选中整窗） · ESC 取消";
          SizeF sz = g.MeasureString(tip, fontTip);
          float lx = (ClientSize.Width - sz.Width) / 2f;
          using (SolidBrush bb = new SolidBrush(Color.FromArgb(190, 24, 26, 34)))
          using (SolidBrush fb = new SolidBrush(Color.FromArgb(255, 235, 240, 250))) {
            g.FillRectangle(bb, lx, 18f, sz.Width + 24f, sz.Height + 10f);
            g.DrawString(tip, fontTip, fb, lx + 12f, 23f);
          }
        }
      }

      if (mode == Mode.Selected) DrawToolbar(g);
    }

    private void DrawHandles(Graphics g, Rectangle r) {
      int hs = 8;
      int mx = r.Left + r.Width / 2;
      int my = r.Top + r.Height / 2;
      Point[] pts = new Point[] {
        new Point(r.Left, r.Top), new Point(mx, r.Top), new Point(r.Right, r.Top),
        new Point(r.Left, my), new Point(r.Right, my),
        new Point(r.Left, r.Bottom), new Point(mx, r.Bottom), new Point(r.Right, r.Bottom)
      };
      using (SolidBrush hb = new SolidBrush(Color.White)) {
        for (int i = 0; i < pts.Length; i++) {
          g.FillRectangle(hb, pts[i].X - hs / 2, pts[i].Y - hs / 2, hs, hs);
        }
      }
    }

    private void DrawSizeLabel(Graphics g, Rectangle r) {
      string label = r.Width + " x " + r.Height;
      SizeF sz = g.MeasureString(label, fontLabel);
      float lx = Math.Min(r.Left, ClientSize.Width - sz.Width - 12f);
      float ly = r.Top > sz.Height + 10f ? r.Top - sz.Height - 6f : r.Bottom + 6f;
      using (SolidBrush bb = new SolidBrush(Color.FromArgb(200, 24, 26, 34)))
      using (SolidBrush fb = new SolidBrush(Color.FromArgb(255, 120, 190, 255))) {
        g.FillRectangle(bb, lx, ly, sz.Width + 10f, sz.Height + 4f);
        g.DrawString(label, fontLabel, fb, lx + 5f, ly + 2f);
      }
    }

    private void LayoutButtons() {
      int bw = 84, bh = 32, gap = 10, pad = 8;
      int total = bw * 2 + gap;
      int bx = selRect.Right - total;
      int by = selRect.Bottom + pad;
      if (by + bh > ClientSize.Height - 4) by = selRect.Top - bh - pad;
      // 上下都放不下（窗口贴满屏幕高）：贴屏幕底部内侧，宁可压住选区也不能出屏
      if (by < 4) by = ClientSize.Height - bh - 4;
      if (bx < 4) bx = 4;
      if (bx + total > ClientSize.Width - 4) bx = ClientSize.Width - 4 - total;
      btnOk = new Rectangle(bx, by, bw, bh);
      btnCancel = new Rectangle(bx + bw + gap, by, bw, bh);
    }

    private void DrawToolbar(Graphics g) {
      DrawButton(g, btnOk, "确认", hoverBtn == 1, true);
      DrawButton(g, btnCancel, "取消", hoverBtn == 2, false);
    }

    private void DrawButton(Graphics g, Rectangle r, string text, bool hot, bool primary) {
      Color back = primary ? Color.FromArgb(45, 130, 240) : Color.FromArgb(70, 74, 88);
      if (hot) back = ControlPaint.Light(back, 0.2f);
      using (GraphicsPath path = new GraphicsPath()) {
        int d = 12;
        path.AddArc(r.Left, r.Top, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Top, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.Left, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        using (SolidBrush b = new SolidBrush(back)) { g.FillPath(b, path); }
        using (SolidBrush fb = new SolidBrush(Color.White)) {
          using (StringFormat sf = new StringFormat()) {
            sf.Alignment = StringAlignment.Center;
            sf.LineAlignment = StringAlignment.Center;
            g.DrawString(text, fontBtn, fb, (RectangleF)r, sf);
          }
        }
      }
    }

    protected override void OnMouseDown(MouseEventArgs e) {
      base.OnMouseDown(e);
      if (e.Button != MouseButtons.Left) return;
      Point p = e.Location;
      if (mode == Mode.Selected) {
        if (btnOk.Contains(p)) { Confirm(); return; }
        if (btnCancel.Contains(p)) { result.Cancelled = true; Close(); return; }
        if (selRect.Contains(p)) return;  // 选区内：留给双击确认，不要误重选
        // 点在选区/工具条外：重新框选（QQ 式）
      }
      mode = Mode.Dragging;
      startPt = p;
      curPt = p;
      selRect = Rectangle.Empty;
      hoverAtDown = hover;
      hover = Rectangle.Empty;
      hoverBtn = 0;
      Cursor = Cursors.Cross;
      Invalidate();
    }

    protected override void OnMouseMove(MouseEventArgs e) {
      base.OnMouseMove(e);
      Point p = e.Location;
      if (mode == Mode.Dragging) {
        if (p != curPt) { curPt = p; Invalidate(); }
      } else if (mode == Mode.Selected) {
        int hb = btnOk.Contains(p) ? 1 : (btnCancel.Contains(p) ? 2 : 0);
        if (hb != hoverBtn) {
          hoverBtn = hb;
          Cursor = hb > 0 ? Cursors.Hand : Cursors.Cross;
          Invalidate();
        }
      } else {
        Rectangle h = WindowUnder(PointToScreen(p));
        if (h != hover) { hover = h; Invalidate(); }
      }
    }

    protected override void OnMouseUp(MouseEventArgs e) {
      base.OnMouseUp(e);
      if (mode != Mode.Dragging || e.Button != MouseButtons.Left) return;
      Rectangle r = NormRect(startPt, curPt);
      if (r.Width < 10 || r.Height < 10) {
        // 误触/点击：QQ 式——按下瞬间悬停的窗口还在就整窗选中，否则回到待选
        if (!hoverAtDown.IsEmpty) {
          selRect = hoverAtDown;
          mode = Mode.Selected;
          LayoutButtons();
        } else {
          mode = Mode.Idle;
        }
      } else {
        selRect = r;
        mode = Mode.Selected;
        LayoutButtons();
      }
      Invalidate();
    }

    protected override void OnMouseDoubleClick(MouseEventArgs e) {
      base.OnMouseDoubleClick(e);
      if (mode == Mode.Selected && e.Button == MouseButtons.Left && selRect.Contains(e.Location)) {
        Confirm();
      }
    }

    protected override void OnKeyDown(KeyEventArgs e) {
      base.OnKeyDown(e);
      if (e.KeyCode == Keys.Escape) {
        result.Cancelled = true;
        Close();
      } else if (e.KeyCode == Keys.Enter && mode == Mode.Selected) {
        Confirm();
      }
    }

    private void Confirm() {
      result.Confirmed = true;
      result.X = selRect.X + vsX;
      result.Y = selRect.Y + vsY;
      result.Width = selRect.Width;
      result.Height = selRect.Height;
      Close();
    }

    protected override void OnShown(EventArgs e) {
      base.OnShown(e);
      Activate();
    }

    protected override void OnFormClosed(FormClosedEventArgs e) {
      base.OnFormClosed(e);
      if (dim != null) { dim.Dispose(); dim = null; }
      if (fontTip != null) { fontTip.Dispose(); fontTip = null; }
      if (fontLabel != null) { fontLabel.Dispose(); fontLabel = null; }
      if (fontBtn != null) { fontBtn.Dispose(); fontBtn = null; }
    }
  }

  internal static class Program {
    [DllImport("user32.dll")] private static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern uint SendInput(uint n, INPUT[] inputs, int size);
    // 必须 CharSet.Unicode：默认绑定到 ANSI 版 Process32FirstA，UTF-16 进程名会被读成乱码，
    // "DeepSeek/Harness" 永远匹配不上，隐藏静默失效（真机踩过）
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern bool Process32First(IntPtr snap, ref PROCESSENTRY32 pe);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern bool Process32Next(IntPtr snap, ref PROCESSENTRY32 pe);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] private static extern int GetCurrentProcessId();

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT {
      public uint type;          // 1 = INPUT_KEYBOARD
      public KEYBDINPUT ki;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT {
      public ushort wVk;
      public ushort wScan;
      public uint dwFlags;
      public uint time;
      public IntPtr dwExtraInfo;
    }

    private const ushort VK_CONTROL = 0x11;
    private const ushort VK_V = 0x56;
    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const uint INPUT_KEYBOARD = 1;
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct PROCESSENTRY32 {
      public int dwSize;
      public int cntUsage;
      public int th32ProcessID;
      public IntPtr th32DefaultHeapID;
      public int th32ModuleID;
      public int cntThreads;
      public int th32ParentProcessID;
      public int pcPriClassBase;
      public int dwFlags;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
      public string szExeFile;
    }

    private static string dir;
    private static string lastJson;

    [STAThread]
    private static int Main(string[] args) {
      try { Console.OutputEncoding = Encoding.UTF8; } catch { }
      string outPath = null;
      bool noHide = false;
      for (int i = 0; i < args.Length; i++) {
        if (string.Equals(args[i], "-Out", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length) {
          outPath = args[++i];
        } else if (string.Equals(args[i], "-NoHide", StringComparison.OrdinalIgnoreCase)) {
          noHide = true;
        }
      }

      dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".dsh", "dsh-snip");
      lastJson = Path.Combine(dir, "last.json");
      try { Directory.CreateDirectory(dir); } catch { }
      if (string.IsNullOrEmpty(outPath)) {
        outPath = Path.Combine(dir, "snip-" + DateTime.Now.ToString("yyyyMMdd-HHmmss-fff") + ".png");
      }
      WriteState("running", null);

      try {
        SetProcessDPIAware();
        IntPtr hidden = IntPtr.Zero;
        try {
          if (!noHide) hidden = HideDshWindow();

          // 冻结屏幕：先抓一张全屏作为遮罩的背景图（视觉上屏幕被冻住）
          Rectangle vs = SystemInformation.VirtualScreen;
          Bitmap frozen = new Bitmap(vs.Width, vs.Height);
          using (Graphics g = Graphics.FromImage(frozen)) {
            g.CopyFromScreen(vs.X, vs.Y, 0, 0, frozen.Size);
          }

          OverlayForm form = new OverlayForm(frozen, vs.X, vs.Y, vs.Width, vs.Height);
          form.ShowDialog();
          SnipResult r = form.result;
          form.Dispose();

          if (r.Cancelled || !r.Confirmed) {
            frozen.Dispose();
            WriteState("cancelled", null);
            Emit("{\"ok\":false,\"cancelled\":true,\"error\":\"\u5df2\u53d6\u6d88\uff08ESC / \u53d6\u6d88\u6309\u94ae\uff09\"}");
            return 0;
          }

          int rx = Math.Max(0, Math.Min(r.X - vs.X, frozen.Width - 4));
          int ry = Math.Max(0, Math.Min(r.Y - vs.Y, frozen.Height - 4));
          int rw = Math.Min(r.Width, frozen.Width - rx);
          int rh = Math.Min(r.Height, frozen.Height - ry);
          if (rw < 4 || rh < 4) {
            frozen.Dispose();
            WriteState("cancelled", null);
            Emit("{\"ok\":false,\"cancelled\":true,\"error\":\"\u9009\u533a\u592a\u5c0f\"}");
            return 0;
          }

          Bitmap bmp = frozen.Clone(new Rectangle(rx, ry, rw, rh), System.Drawing.Imaging.PixelFormat.Format32bppArgb);
          frozen.Dispose();
          long bytes;
          try {
            bmp.Save(outPath, System.Drawing.Imaging.ImageFormat.Png);
            try { Clipboard.SetImage(bmp); } catch { }
          } finally {
            bmp.Dispose();
          }
          bytes = new FileInfo(outPath).Length;

          string record = "{\"ok\":true,\"path\":\"" + JEsc(outPath) + "\",\"x\":" + r.X + ",\"y\":" + r.Y
            + ",\"width\":" + rw + ",\"height\":" + rh + ",\"bytes\":" + bytes
            + ",\"t\":" + NowMs() + "}";
          try { File.WriteAllText(lastJson, record, new UTF8Encoding(false)); } catch { }
          // 先恢复 DSH 前台，再让客户端感知 done（客户端会把焦点放回输入框），
          // 最后延时发 Ctrl+V —— QQ 式"截完直接贴进输入框"
          if (hidden != IntPtr.Zero) {
            try {
              ShowWindow(hidden, 5);          // SW_SHOW
              SetForegroundWindow(hidden);
            } catch { }
          }
          WriteState("done", null);
          Emit(record);
          if (hidden != IntPtr.Zero) {
            Thread.Sleep(800);                // 留给客户端轮询(0.6s)把焦点放回输入框
            try {
              SetForegroundWindow(hidden);
              SendCtrlV();
            } catch { }
          }
          return 0;
        } finally {
          if (hidden != IntPtr.Zero) {
            try {
              ShowWindow(hidden, 5);          // SW_SHOW（幂等兜底）
              SetForegroundWindow(hidden);
            } catch { }
          }
        }
      } catch (Exception ex) {
        try { WriteState("failed", JEsc(ex.Message)); } catch { }
        Emit("{\"ok\":false,\"error\":\"" + JEsc(ex.Message) + "\"}");
        return 0;
      }
    }

    // 沿父进程链找 DSH 主窗口并暂时隐藏（避免把 DSH 自己截进去），返回窗口句柄。
    // Electron 宿主有多层同名进程（helper 不带窗口），名字匹配的祖先里取最靠根的
    // 那个有可见窗口的——那才是主进程的主窗口。名字匹配不上就什么都不藏（fail-open），
    // 绝不能拿链条上的随机祖先（bash/explorer）下手。
    private static IntPtr HideDshWindow() {
      try {
        Dictionary<int, int> parent = new Dictionary<int, int>();
        Dictionary<int, string> names = new Dictionary<int, string>();
        IntPtr snap = CreateToolhelp32Snapshot(0x2, 0);   // TH32CS_SNAPPROCESS
        if (snap == IntPtr.Zero || snap == (IntPtr)(-1)) return IntPtr.Zero;
        PROCESSENTRY32 pe = new PROCESSENTRY32();
        pe.dwSize = Marshal.SizeOf(typeof(PROCESSENTRY32));
        if (Process32First(snap, ref pe)) {
          do {
            parent[(int)pe.th32ProcessID] = (int)pe.th32ParentProcessID;
            names[(int)pe.th32ProcessID] = pe.szExeFile;
          } while (Process32Next(snap, ref pe));
        }
        CloseHandle(snap);

        int pid = GetCurrentProcessId();
        IntPtr best = IntPtr.Zero;
        for (int i = 0; i < 8; i++) {
          if (!parent.ContainsKey(pid)) break;
          int pp = parent[pid];
          if (pp <= 4) break;
          string nm = names.ContainsKey(pp) ? names[pp] : "";
          if (IsDshName(nm)) {
            try {
              Process p = Process.GetProcessById(pp);
              IntPtr h = p.MainWindowHandle;
              if (h != IntPtr.Zero && IsWindowVisible(h)) {
                best = h;   // 越靠根越像主进程，覆盖前面的候选
              }
            } catch { }
          }
          pid = pp;
        }
        if (best != IntPtr.Zero) {
          ShowWindow(best, 0);             // SW_HIDE
          Thread.Sleep(350);               // 等窗口真正消失并重绘
        }
        return best;
      } catch { }
      return IntPtr.Zero;
    }

    private static bool IsDshName(string nm) {
      if (string.IsNullOrEmpty(nm)) return false;
      string l = nm.ToLowerInvariant();
      return l.Contains("deepseek") || l.Contains("harness") || l.Contains("zcode") || l.Contains("dsh");
    }

    // 真实键盘输入（SendInput）：把截图贴进 DSH 输入框。合成 JS 事件不可信会被网页忽略，
    // 必须走系统级输入
    private static void SendCtrlV() {
      INPUT[] inputs = new INPUT[4];
      inputs[0].type = INPUT_KEYBOARD; inputs[0].ki.wVk = VK_CONTROL;
      inputs[1].type = INPUT_KEYBOARD; inputs[1].ki.wVk = VK_V;
      inputs[2].type = INPUT_KEYBOARD; inputs[2].ki.wVk = VK_V; inputs[2].ki.dwFlags = KEYEVENTF_KEYUP;
      inputs[3].type = INPUT_KEYBOARD; inputs[3].ki.wVk = VK_CONTROL; inputs[3].ki.dwFlags = KEYEVENTF_KEYUP;
      SendInput(4, inputs, Marshal.SizeOf(typeof(INPUT)));
    }

    private static long NowMs() {
      return (long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalMilliseconds;
    }

    private static void WriteState(string status, string errorJsonEscaped) {
      try {
        string text = "{\"status\":\"" + status + "\",\"t\":" + NowMs();
        if (!string.IsNullOrEmpty(errorJsonEscaped)) text += ",\"error\":\"" + errorJsonEscaped + "\"";
        text += "}";
        File.WriteAllText(Path.Combine(dir, "run.json"), text, new UTF8Encoding(false));
      } catch { }
    }

    // 非 ASCII 转 \uXXXX，与旧 snip.ps1 的输出契约一致
    private static string JEsc(string s) {
      if (string.IsNullOrEmpty(s)) return "";
      StringBuilder sb = new StringBuilder(s.Length);
      foreach (char ch in s) {
        if (ch > 127) sb.Append("\\u").Append(((int)ch).ToString("x4"));
        else if (ch == '"') sb.Append("\\\"");
        else if (ch == '\\') sb.Append("\\\\");
        else sb.Append(ch);
      }
      return sb.ToString();
    }

    private static void Emit(string json) {
      Console.WriteLine(json);
    }
  }
}
