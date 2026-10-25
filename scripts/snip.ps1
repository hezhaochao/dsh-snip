# dsh-snip — 框选截图工具（Windows，必须以 -STA 启动）
#
# 交互模式（默认）：微信/QQ 式框选。
#   遮罩窗体为 Add-Type 运行时编译的 C#（事件热路径不经过 PowerShell 解释器，
#   这是流畅度的关键——PS 脚本块处理 MouseMove 会把消息队列拖垮，实测"左键失灵"）。
#   设计借鉴（仅思路，代码为原创实现）：
#     Greenshot CaptureForm —— SetStyle(OptimizedDoubleBuffer|AllPaintingInWmPaint|UserPaint)
#                              + 预渲染压暗背景，每帧只是两张位图 blit
#     ShareX RegionCaptureForm —— 全屏无边框窗体 + WindowFromPoint/DWM 窗口吸附
#   交互：悬停自动高亮窗口（左键点一下=整窗选中，QQ 式）/ 拖拽自由框选
#         （选区外压暗、蓝框、白色手柄、实时尺寸）/ 松手出确认工具条
#         / 回车或双击确认 / 点工具条外重新框选 / ESC 取消
# 测试模式：-Rect "x,y,w,h" 直接截指定区域，不出遮罩（自动化测试/脚本用）。
# 可选 -NoHide：默认暂时隐藏 DSH 主窗口（避免把 DSH 截进去），截完恢复。
#
# 输出：单个 JSON 对象（stdout，非 ASCII 转 \uXXXX）；状态落盘 run.json。
# 注意：必须保存为 UTF-8 with BOM；必须 STA（Clipboard::SetImage 的要求）。
param(
  [string]$Rect = "",
  [string]$Out = "",
  [switch]$NoHide
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

Add-Type -AssemblyName System.Windows.Forms | Out-Null
Add-Type -AssemblyName System.Drawing | Out-Null

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace SnipNative {
  public static class Win {
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int nIndex);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  }
}
'@

[void][SnipNative.Win]::SetProcessDPIAware()

$dir = Join-Path $env:USERPROFILE '.dsh\dsh-snip'
New-Item -ItemType Directory -Force -Path $dir | Out-Null

function Escape-JsonAscii([string]$json) {
  $sb = New-Object System.Text.StringBuilder
  foreach ($ch in $json.ToCharArray()) {
    if ([int]$ch -gt 127) {
      [void]$sb.Append(('\u' + ([int]$ch).ToString('x4')))
    } else {
      [void]$sb.Append($ch)
    }
  }
  return $sb.ToString()
}

function Write-RunState([string]$status, $extra) {
  try {
    $obj = @{ status = $status; t = [DateTimeOffset]::Now.ToUnixTimeMilliseconds() }
    if ($extra) { foreach ($k in $extra.Keys) { $obj[$k] = $extra[$k] } }
    $text = Escape-JsonAscii ($obj | ConvertTo-Json -Compress -Depth 4)
    [IO.File]::WriteAllText((Join-Path $dir 'run.json'), $text, (New-Object System.Text.UTF8Encoding $false))
  } catch { }
}

function Out-Json($object) {
  $json = $object | ConvertTo-Json -Compress -Depth 4
  $text = Escape-JsonAscii $json
  Write-Output $text
}

function Fail($message) {
  Write-RunState 'failed' @{ error = [string]$message }
  Out-Json @{ ok = $false; error = [string]$message }
  exit 0
}

# ── 输出路径 ─────────────────────────────────────────────────
if (-not $Out) {
  $Out = Join-Path $dir ("snip-" + [DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff') + ".png")
}
$lastJson = Join-Path $dir 'last.json'

# ── 找到 DSH 主窗口（沿父进程链），暂时隐藏 ───────────────────
function Find-DshWindow {
  try {
    $pid0 = $PID
    for ($i = 0; $i -lt 6; $i++) {
      $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $pid0" -ErrorAction Stop
      if (-not $proc) { return [IntPtr]::Zero }
      $parentPid = [int]$proc.ParentProcessId
      $parent = Get-Process -Id $parentPid -ErrorAction SilentlyContinue
      if ($parent -and $parent.ProcessName -match 'DeepSeek|Harness') {
        return $parent.MainWindowHandle
      }
      $pid0 = $parentPid
      if ($pid0 -le 4) { return [IntPtr]::Zero }
    }
  } catch { }
  return [IntPtr]::Zero
}

$hidden = [IntPtr]::Zero
if (-not $NoHide) {
  $hwnd = Find-DshWindow
  if ($hwnd -ne [IntPtr]::Zero) {
    try {
      [void][SnipNative.Win]::ShowWindow($hwnd, 0)   # SW_HIDE
      $hidden = $hwnd
      Start-Sleep -Milliseconds 350                   # 等窗口真正消失并重绘
    } catch { }
  }
}

try {
  # ── 区域来源 ────────────────────────────────────────────────
  $x = 0; $y = 0; $w = 0; $h = 0
  if ($Rect) {
    $parts = $Rect -split ','
    if ($parts.Count -lt 4) { Fail "-Rect 需要 x,y,w,h 四个数字" }
    $x = [int]$parts[0]; $y = [int]$parts[1]; $w = [int]$parts[2]; $h = [int]$parts[3]
    if ($w -le 0 -or $h -le 0) { Fail "无效区域 ${w}x${h}" }
    if ($w -lt 4 -or $h -lt 4) { Fail "区域太小（至少 4x4）" }
  }

  if ($Rect) {
    # ── 静默模式：直接抓屏 ──────────────────────────────────
    Start-Sleep -Milliseconds 150
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    try {
      $g = [System.Drawing.Graphics]::FromImage($bmp)
      try { $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size($w, $h))) }
      finally { $g.Dispose() }
      $bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
      try { [System.Windows.Forms.Clipboard]::SetImage($bmp) } catch { }
    } finally { $bmp.Dispose() }

    $info = Get-Item -LiteralPath $Out
    $record = @{
      ok = $true; path = $info.FullName; x = $x; y = $y; width = $w; height = $h
      bytes = $info.Length; t = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
    }
    Write-RunState 'done' @{ path = $info.FullName; width = $w; height = $h }
    [IO.File]::WriteAllText($lastJson, (Escape-JsonAscii ($record | ConvertTo-Json -Compress -Depth 3)), (New-Object System.Text.UTF8Encoding $false))
    Out-Json $record
    return
  }

  # ════════════ 交互模式：微信/QQ 式框选 ════════════
  $script:vs = [System.Windows.Forms.SystemInformation]::VirtualScreen

  # 1) 冻结屏幕：先抓一张全屏作为遮罩的背景图（视觉上屏幕被冻住）
  $script:frozen = New-Object System.Drawing.Bitmap($script:vs.Width, $script:vs.Height)
  $fg = [System.Drawing.Graphics]::FromImage($frozen)
  try { $fg.CopyFromScreen($script:vs.X, $script:vs.Y, 0, 0, $script:frozen.Size) }
  finally { $fg.Dispose() }

  # 2) 编译（或从缓存加载）C# 遮罩层。
  #    事件热路径在编译代码里，PowerShell 只负责调用——这是"左键失灵/拖选卡顿"的根治点。
  #    DLL 按源码哈希缓存：首次编译约 1-2s，之后 LoadFrom 秒开。
  $cs = @'
// dsh-snip 框选遮罩层（原创 MIT 实现）
// 设计借鉴：Greenshot CaptureForm（双缓冲三件套 + 预压暗背景）、
//           ShareX RegionCaptureForm（全屏窗体 + Win32/DWM 窗口吸附）
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace DshSnip {
  public class SnipResult {
    public bool Confirmed;
    public bool Cancelled;
    public int X;
    public int Y;
    public int Width;
    public int Height;   // 虚拟屏物理像素坐标
  }

  public static class Entry {
    public static SnipResult Run(Bitmap background, int vsX, int vsY, int vsW, int vsH) {
      OverlayForm form = new OverlayForm(background, vsX, vsY, vsW, vsH);
      form.ShowDialog();
      SnipResult r = form.result;
      form.Dispose();
      return r;
    }
  }

  internal class OverlayForm : Form {
    private enum Mode { Idle, Dragging, Selected }

    private Bitmap bg;      // 冻结画面（PS 侧持有，窗体只读）
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
      // Greenshot 同款三件套：消除重绘白闪/撕裂（v0.1.5 里靠反射开 DoubleBuffered，这里直接生效）
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
}
'@

  $sha = [System.Security.Cryptography.SHA256]::Create()
  $csHash = [BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($cs))).Replace('-', '').Substring(0, 16)
  $sha.Dispose()
  $overlayDll = Join-Path $dir ("snip-overlay-" + $csHash + ".dll")
  if (Test-Path -LiteralPath $overlayDll) {
    try { Add-Type -Path $overlayDll } catch { Remove-Item -LiteralPath $overlayDll -Force -ErrorAction SilentlyContinue }
  }
  if (-not ('DshSnip.Entry' -as [type])) {
    # 必须写 UTF-8 with BOM 的 .cs 再 CompileAssemblyFromFile：
    # CodeDom 内部落临时文件的编码不可控，无 BOM 时 csc 按 GBK 误读中文注释，
    # 多字节序列会吞掉后面的 ASCII（实测把大括号吞了，报出一堆错位语法错）
    $cp = New-Object System.CodeDom.Compiler.CompilerParameters
    $cp.ReferencedAssemblies.AddRange(@('System.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll'))
    $cp.OutputAssembly = $overlayDll
    $cp.GenerateExecutable = $false
    $cp.GenerateInMemory = $false
    $cp.IncludeDebugInformation = $false
    $csFile = Join-Path $env:TEMP ("dsh-snip-overlay-" + $csHash + ".cs")
    [IO.File]::WriteAllText($csFile, $cs, (New-Object System.Text.UTF8Encoding $true))
    $prov = New-Object Microsoft.CSharp.CSharpCodeProvider
    $res = $prov.CompileAssemblyFromFile($cp, $csFile)
    if ($res.Errors.HasErrors) {
      $errs = @($res.Errors | Where-Object { -not $_.IsWarning } | Select-Object -First 4 | ForEach-Object { "line $($_.Line): $($_.ErrorText)" }) -join ' | '
      Fail "遮罩层编译失败：$errs"
    }
    # 手工 CodeDom 只落盘不加载（Add-Type 才会自动加载），必须显式载入
    Add-Type -Path $overlayDll
  }

  # 3) 跑遮罩：事件循环完全在编译代码里，PS 在这一行阻塞等结果
  $res = [DshSnip.Entry]::Run($frozen, $vs.X, $vs.Y, $vs.Width, $vs.Height)

  if ($res.Cancelled -or -not $res.Confirmed) {
    $frozen.Dispose()
    Write-RunState 'cancelled' $null
    Out-Json @{ ok = $false; cancelled = $true; error = '已取消（ESC / 取消按钮）' }
    return
  }

  # ── 从冻结画面裁剪选区 ──────────────────────────────────────
  $rx = [Math]::Max(0, [Math]::Min($res.X - $vs.X, $frozen.Width - 4))
  $ry = [Math]::Max(0, [Math]::Min($res.Y - $vs.Y, $frozen.Height - 4))
  $rw = [Math]::Min($res.Width, $frozen.Width - $rx)
  $rh = [Math]::Min($res.Height, $frozen.Height - $ry)
  if ($rw -lt 4 -or $rh -lt 4) {
    $frozen.Dispose()
    Write-RunState 'cancelled' $null
    Out-Json @{ ok = $false; cancelled = $true; error = '选区太小' }
    return
  }
  $cap = New-Object System.Drawing.Rectangle($rx, $ry, $rw, $rh)
  $bmp = $frozen.Clone($cap, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $frozen.Dispose()
  try {
    $bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
    try { [System.Windows.Forms.Clipboard]::SetImage($bmp) } catch { }
  } finally { $bmp.Dispose() }

  $info = Get-Item -LiteralPath $Out
  $record = @{
    ok = $true; path = $info.FullName; x = $res.X; y = $res.Y; width = $rw; height = $rh
    bytes = $info.Length; t = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
  }
  Write-RunState 'done' @{ path = $info.FullName; width = $rw; height = $rh }
  [IO.File]::WriteAllText($lastJson, (Escape-JsonAscii ($record | ConvertTo-Json -Compress -Depth 3)), (New-Object System.Text.UTF8Encoding $false))
  Out-Json $record
} finally {
  if ($hidden -ne [IntPtr]::Zero) {
    try {
      [void][SnipNative.Win]::ShowWindow($hidden, 5)   # SW_SHOW
      [void][SnipNative.Win]::SetForegroundWindow($hidden)
    } catch { }
  }
}
