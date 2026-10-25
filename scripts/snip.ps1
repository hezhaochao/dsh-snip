# dsh-snip — 框选截图工具（Windows，必须以 -STA 启动）
#
# 交互模式（默认）：微信/QQ 式框选——先把屏幕"冻结"为背景图，拖拽实时框选
#   （选区外压暗、蓝框、实时宽高），松手后弹出「确认/取消」工具条，
#   回车确认 / ESC 取消 / 双击确认。误触点击（<10px）自动忽略。
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

  # 2) 全屏无边框窗体：背景 = 冻结画面
  $form = New-Object System.Windows.Forms.Form
  $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
  $form.StartPosition = 'Manual'
  $form.Location = New-Object System.Drawing.Point($script:vs.X, $script:vs.Y)
  $form.Size = New-Object System.Drawing.Size($script:vs.Width, $script:vs.Height)
  $form.TopMost = $true
  $form.ShowInTaskbar = $false
  $form.Cursor = [System.Windows.Forms.Cursors]::Cross
  $form.KeyPreview = $true
  $form.BackgroundImage = $frozen
  $form.BackgroundImageLayout = 'None'

  $script:startPt = [System.Drawing.Point]::Empty
  $script:curPt = [System.Drawing.Point]::Empty
  $script:dragging = $false
  $script:confirmed = $false
  $script:cancelled = $false
  $script:selRect = [System.Drawing.Rectangle]::Empty   # 最终选区（窗体坐标 = 虚拟屏坐标）

  $form.add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
      $script:cancelled = $true
      $form.Close()
    } elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter -and -not $script:selRect.IsEmpty) {
      $script:confirmed = $true
      $form.Close()
    }
  })
  $form.add_MouseDown({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
      $script:dragging = $true
      $script:startPt = $e.Location
      $script:curPt = $e.Location
      $script:selRect = [System.Drawing.Rectangle]::Empty
      $form.Invalidate()
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
      $rx = [Math]::Min($script:startPt.X, $script:curPt.X)
      $ry = [Math]::Min($script:startPt.Y, $script:curPt.Y)
      $rw = [Math]::Abs($script:curPt.X - $script:startPt.X)
      $rh = [Math]::Abs($script:curPt.Y - $script:startPt.Y)
      if ($rw -ge 10 -and $rh -ge 10) {
        $script:selRect = New-Object System.Drawing.Rectangle($rx, $ry, $rw, $rh)
        $s.Invalidate()
        & $script:ShowConfirmBar $script:selRect $s
      } else {
        # 误触（拖拽太小）：忽略，继续等待真正的框选
        $script:selRect = [System.Drawing.Rectangle]::Empty
        $s.Invalidate()
      }
    }
  })

  $form.add_MouseDoubleClick({
    param($s, $e)
    if (-not $script:selRect.IsEmpty) {
      $script:confirmed = $true
      $form.Close()
    }
  })
  $form.add_Paint({
    param($s, $e)
    try {
      $g = $e.Graphics
      $r = $script:selRect
      if (-not $script:dragging -and ($r.IsEmpty -or $r.Width -lt 2 -or $r.Height -lt 2)) {
        $tip = "按住左键拖拽框选截图区域 · ESC 取消"
        $font = New-Object System.Drawing.Font('Microsoft YaHei', 11)
        $sz = $g.MeasureString($tip, $font)
        $lx = [int](($s.ClientSize.Width - $sz.Width) / 2)
        $bg = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(190, 24, 26, 34))
        $fgb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 235, 240, 250))
        $g.FillRectangle($bg, $lx, 18, $sz.Width + 24, $sz.Height + 10)
        $g.DrawString($tip, $font, $fgb, ($lx + 12), 23)
        $font.Dispose(); $bg.Dispose(); $fgb.Dispose()
        return
      }
      $rx = [Math]::Min($script:startPt.X, $script:curPt.X)
      $ry = [Math]::Min($script:startPt.Y, $script:curPt.Y)
      $rw = [Math]::Abs($script:curPt.X - $script:startPt.X)
      $rh = [Math]::Abs($script:curPt.Y - $script:startPt.Y)
      if ($rw -lt 2 -or $rh -lt 2) { return }
      $r = New-Object System.Drawing.Rectangle($rx, $ry, $rw, $rh)
      $dark = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(110, 10, 12, 18))
      $vw = $s.ClientSize.Width; $vh = $s.ClientSize.Height
      $g.FillRectangle($dark, 0, 0, $vw, $r.Top)
      $g.FillRectangle($dark, 0, $r.Bottom, $vw, $vh - $r.Bottom)
      $g.FillRectangle($dark, 0, $r.Top, $r.Left, $r.Height)
      $g.FillRectangle($dark, $r.Right, $r.Top, $vw - $r.Right, $r.Height)
      $dark.Dispose()
      $pen = New-Object System.Drawing.Pen($script:ACCENT, 2)
      $g.DrawRectangle($pen, $r)
      $pen.Dispose()
      $label = [string]$r.Width + " x " + $r.Height
      $font2 = New-Object System.Drawing.Font('Microsoft YaHei', 9)
      $sz = $g.MeasureString($label, $font2)
      $lx = [Math]::Min($r.Left, $vw - $sz.Width - 12)
      $ly = if ($r.Top -gt $sz.Height + 10) { $r.Top - $sz.Height - 6 } else { $r.Bottom + 6 }
      $bg2 = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(200, 24, 26, 34))
      $fgb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 120, 190, 255))
      $g.FillRectangle($bg2, $lx, $ly, $sz.Width + 10, $sz.Height + 4)
      $g.DrawString($label, $font2, $fgb, ($lx + 5), ($ly + 2))
      $font2.Dispose(); $bg2.Dispose(); $fgb.Dispose()
    } catch {
      # 绘制失败绝不能拖垮整个遮罩窗体
      try { $e.Graphics.Clear([System.Drawing.Color]::FromArgb(200, 10, 12, 18)) } catch { }
    }
  })

  # QQ 式确认工具条：存为 script 变量，事件处理器里用 & $script:ShowConfirmBar 调用
  $script:ShowConfirmBar = {
    param([System.Drawing.Rectangle]$r, [System.Windows.Forms.Form]$owner)
    $bar = New-Object System.Windows.Forms.Form
    $bar.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $bar.StartPosition = 'Manual'
    $bar.TopMost = $true
    $bar.ShowInTaskbar = $false
    $bar.Size = New-Object System.Drawing.Size(132, 36)
    $bar.BackColor = [System.Drawing.Color]::FromArgb(24, 26, 34)
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = '确认'
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $ok.FlatStyle = 'Flat'
    $ok.ForeColor = [System.Drawing.Color]::White
    $ok.BackColor = [System.Drawing.Color]::FromArgb(45, 130, 240)
    $ok.Size = New-Object System.Drawing.Size(60, 28)
    $ok.Location = New-Object System.Drawing.Point(6, 4)
    $bar.Controls.Add($ok)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = '取消'
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancel.FlatStyle = 'Flat'
    $cancel.ForeColor = [System.Drawing.Color]::White
    $cancel.BackColor = [System.Drawing.Color]::FromArgb(70, 74, 88)
    $cancel.Size = New-Object System.Drawing.Size(60, 28)
    $cancel.Location = New-Object System.Drawing.Point(68, 4)
    $bar.Controls.Add($cancel)
    $bx = $r.Right - $bar.Width
    $by = $r.Bottom + 6
    if ($bx -lt $script:vs.X + 4) { $bx = $script:vs.X + 4 }
    if ($by + $bar.Height -gt $script:vs.Y + $script:vs.Height - 4) { $by = $r.Top - $bar.Height - 6 }
    $bar.Location = New-Object System.Drawing.Point($bx, $by)
    $result = $bar.ShowDialog($owner)
    $bar.Dispose()
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
      $script:confirmed = $true
      $owner.Close()
    } else {
      $script:cancelled = $true
      $owner.Close()
    }
  }

  $form.Add_Shown({ $form.Activate() })
  [void]$form.ShowDialog()
  $form.Dispose()

  if ($script:cancelled -or -not $script:confirmed -or $script:selRect.IsEmpty) {
    Write-RunState 'cancelled' $null
    Out-Json @{ ok = $false; cancelled = $true; error = '已取消（ESC / 取消按钮）' }
    return
  }

  # ── 从冻结画面裁剪选区 ──────────────────────────────────────
  $r = $script:selRect
  $cap = New-Object System.Drawing.Rectangle($r.X, $r.Y, [Math]::Min($r.Width, $script:frozen.Width), [Math]::Min($r.Height, $script:frozen.Height))
  $bmp = $script:frozen.Clone($cap, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $script:frozen.Dispose()
  try {
    $bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
    try { [System.Windows.Forms.Clipboard]::SetImage($bmp) } catch { }
  } finally { $bmp.Dispose() }

  $info = Get-Item -LiteralPath $Out
  $record = @{
    ok = $true; path = $info.FullName; x = $vs.X + $r.X; y = $vs.Y + $r.Y; width = $r.Width; height = $r.Height
    bytes = $info.Length; t = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
  }
  Write-RunState 'done' @{ path = $info.FullName; width = $r.Width; height = $r.Height }
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
