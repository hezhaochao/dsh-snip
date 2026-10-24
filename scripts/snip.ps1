# dsh-snip — 框选截图工具（Windows，必须以 -STA 启动）
#
# 两种模式：
#   交互模式（默认）：全屏半透明遮罩 + 橡皮筋拖框选区，ESC 取消；
#     截图 PNG 落盘 + 写入剪贴板（图片），并记录到 ~/.dsh/dsh-snip/last.json
#   测试模式：-Rect "x,y,w,h" 直接截指定区域，不出遮罩（自动化测试/脚本用）
#
# 可选 -NoHide：默认会暂时隐藏 DSH 自己的窗口（沿父进程链找到 DeepSeek Harness，
# ShowWindow 隐藏，截完恢复并抢回前台）——避免截图里全是 DSH 对话框。
#
# 输出：单个 JSON 对象（stdout，非 ASCII 转 \uXXXX）。
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

function Out-Json($object) {
  $json = $object | ConvertTo-Json -Compress -Depth 4
  $sb = New-Object System.Text.StringBuilder
  foreach ($ch in $json.ToCharArray()) {
    if ([int]$ch -gt 127) {
      [void]$sb.Append(('\u' + ([int]$ch).ToString('x4')))
    } else {
      [void]$sb.Append($ch)
    }
  }
  Write-Output $sb.ToString()
}

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

function Fail($message) {
  Out-Json @{ ok = $false; error = [string]$message }
  exit 0
}

# ── 输出路径 ─────────────────────────────────────────────────
$dir = Join-Path $env:USERPROFILE '.dsh\dsh-snip'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
if (-not $Out) {
  $Out = Join-Path $dir ("snip-" + [DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff') + ".png")
}
$lastJson = Join-Path $dir 'last.json'

# ── 找到 DSH 主窗口（沿父进程链） ─────────────────────────────
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
  } else {
    # ── 交互式框选：全屏遮罩 ──────────────────────────────────
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.StartPosition = 'Manual'
    $form.Location = New-Object System.Drawing.Point($vs.X, $vs.Y)
    $form.Size = New-Object System.Drawing.Size($vs.Width, $vs.Height)
    $form.TopMost = $true
    $form.ShowInTaskbar = $false
    $form.Cursor = [System.Windows.Forms.Cursors]::Cross
    $form.KeyPreview = $true
    $form.Opacity = 0.35
    $form.BackColor = [System.Drawing.Color]::FromArgb(20, 22, 28)

    $script:startPt = [System.Drawing.Point]::Empty
    $script:curPt = [System.Drawing.Point]::Empty
    $script:dragging = $false
    $script:cancelled = $false

    $form.add_KeyDown({
      param($s, $e)
      if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
        $script:cancelled = $true
        $form.Close()
      }
    })
    $form.add_MouseDown({
      param($s, $e)
      if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:dragging = $true
        $script:startPt = $e.Location
        $script:curPt = $e.Location
      }
    })
    $form.add_MouseMove({
      param($s, $e)
      if ($script:dragging) {
        $script:curPt = $e.Location
        $form.Invalidate()
      }
    })
    $form.add_MouseUp({
      param($s, $e)
      if ($script:dragging -and $e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:dragging = $false
        $form.Close()
      }
    })
    $form.add_Paint({
      param($s, $e)
      if ($script:dragging) {
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(120, 160, 220), 2)
        $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(40, 120, 160, 220))
        $rx = [Math]::Min($script:startPt.X, $script:curPt.X)
        $ry = [Math]::Min($script:startPt.Y, $script:curPt.Y)
        $rw = [Math]::Abs($script:curPt.X - $script:startPt.X)
        $rh = [Math]::Abs($script:curPt.Y - $script:startPt.Y)
        $e.Graphics.FillRectangle($brush, $rx, $ry, $rw, $rh)
        $e.Graphics.DrawRectangle($pen, $rx, $ry, $rw, $rh)
        $pen.Dispose(); $brush.Dispose()
      }
    })

    [void]$form.ShowDialog()
    $form.Dispose()

    if ($script:cancelled) {
      Out-Json @{ ok = $false; cancelled = $true; error = '已取消（ESC）' }
      exit 0
    }
    $x = [Math]::Min($script:startPt.X, $script:curPt.X)
    $y = [Math]::Min($script:startPt.Y, $script:curPt.Y)
    $w = [Math]::Abs($script:curPt.X - $script:startPt.X)
    $h = [Math]::Abs($script:curPt.Y - $script:startPt.Y)
    if ($w -lt 4 -or $h -lt 4) {
      Out-Json @{ ok = $false; cancelled = $true; error = '选区太小（单击未拖动）' }
      exit 0
    }
  }

  if ($w -le 0 -or $h -le 0) { Fail "无效区域 ${w}x${h}" }
  if ($w -lt 4 -or $h -lt 4) { Fail "区域太小（至少 4x4）" }

  # ── 抓屏 ────────────────────────────────────────────────────
  Start-Sleep -Milliseconds 150     # 等遮罩/窗口消失后的最终一帧
  $bmp = New-Object System.Drawing.Bitmap($w, $h)
  try {
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try { $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size($w, $h))) }
    finally { $g.Dispose() }
    $bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)

    # 图片进剪贴板（STA 由启动参数保证）
    try { [System.Windows.Forms.Clipboard]::SetImage($bmp) } catch { }
  } finally { $bmp.Dispose() }

  $info = Get-Item -LiteralPath $Out
  $record = @{
    ok = $true; path = $info.FullName; x = $x; y = $y; width = $w; height = $h
    bytes = $info.Length; t = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
  }
  $lastText = Escape-JsonAscii ($record | ConvertTo-Json -Compress -Depth 3)
  [IO.File]::WriteAllText($lastJson, $lastText, (New-Object System.Text.UTF8Encoding $false))
  Out-Json $record
} finally {
  if ($hidden -ne [IntPtr]::Zero) {
    try {
      [void][SnipNative.Win]::ShowWindow($hidden, 5)   # SW_SHOW
      [void][SnipNative.Win]::SetForegroundWindow($hidden)
    } catch { }
  }
}
