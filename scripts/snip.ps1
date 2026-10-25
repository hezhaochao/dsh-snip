# dsh-snip — 截图脚本（Windows，-STA）
#
# 本脚本只剩两个职责：
#   1. -Rect "x,y,w,h"：静默截取指定区域，不出遮罩（MCP take_screenshot / 自动化测试用）
#   2. 交互模式兜底：正常链路由宿主(lib/index.js)在插件挂载时预热编译好
#      scripts/snip-overlay.cs → ~/.dsh/dsh-snip/snip-overlay-<hash>.exe，点击按钮
#      直接启动 exe（<1s 出遮罩）。若 exe 还没就绪，走本脚本的兜底：用 csc.exe
#      现编一份再启动（首次约 1-2s）。交互逻辑全部在 snip-overlay.cs（独立 exe）。
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

# ── 找到 DSH 主窗口（沿父进程链），暂时隐藏（仅 -Rect 用；交互层 exe 自己处理）──
function Find-DshWindow {
  try {
    $pid0 = $PID
    for ($i = 0; $i -lt 6; $i++) {
      $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $pid0" -ErrorAction Stop
      if (-not $proc) { return [IntPtr]::Zero }
      $parentPid = [int]$proc.ParentProcessId
      $parent = Get-Process -Id $parentPid -ErrorAction SilentlyContinue
      if ($parent -and $parent.ProcessName -match 'DeepSeek|Harness|ZCode|dsh') {
        return $parent.MainWindowHandle
      }
      $pid0 = $parentPid
      if ($pid0 -le 4) { return [IntPtr]::Zero }
    }
  } catch { }
  return [IntPtr]::Zero
}

$hidden = [IntPtr]::Zero
if (-not $NoHide -and $Rect) {
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
  # ── 交互模式：启动独立 exe（宿主已预热编译；缺失则 csc 现编）──────────
  if (-not $Rect) {
    $cs = Join-Path $PSScriptRoot 'snip-overlay.cs'
    if (-not (Test-Path -LiteralPath $cs)) { Fail "缺少 snip-overlay.cs（安装不完整）" }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $csHash = [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($cs))).Replace('-', '').Substring(0, 16) } finally { $sha.Dispose() }
    $exe = Join-Path $dir ("snip-overlay-" + $csHash + ".exe")
    if (-not (Test-Path -LiteralPath $exe)) {
      $csc = @("$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
               "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe") |
             Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
      if (-not $csc) { Fail "找不到 csc.exe（需要 .NET Framework 4.x）" }
      $tmp = Join-Path $dir ("snip-overlay-" + $csHash + "." + $PID + ".tmp.exe")
      $null = & $csc /nologo /target:exe /platform:anycpu /out:$tmp /r:System.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll $cs 2>&1
      if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tmp)) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Fail "交互层编译失败（csc=$csc）"
      }
      Move-Item -LiteralPath $tmp -Destination $exe -Force
    }
    # exe 自己处理 DSH 窗口隐藏/恢复、抓屏、遮罩、裁剪、剪贴板、run.json/last.json、JSON 输出
    & $exe
    exit $LASTEXITCODE
  }

  # ── 静默模式：-Rect 直接抓屏 ──────────────────────────────────
  $parts = $Rect -split ','
  if ($parts.Count -lt 4) { Fail "-Rect 需要 x,y,w,h 四个数字" }
  $x = [int]$parts[0]; $y = [int]$parts[1]; $w = [int]$parts[2]; $h = [int]$parts[3]
  if ($w -le 0 -or $h -le 0) { Fail "无效区域 ${w}x${h}" }
  if ($w -lt 4 -or $h -lt 4) { Fail "区域太小（至少 4x4）" }

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
} finally {
  if ($hidden -ne [IntPtr]::Zero) {
    try {
      [void][SnipNative.Win]::ShowWindow($hidden, 5)   # SW_SHOW
      [void][SnipNative.Win]::SetForegroundWindow($hidden)
    } catch { }
  }
}
