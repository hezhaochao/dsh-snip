# dsh-snip — 粘贴执行器：把剪贴板里的截图贴进 DSH 输入框（QQ 式自动粘贴的最后一环）
#
# 由宿主在收到客户端上报的输入框坐标后拉起。独立进程做输入模拟：
#   1. powershell.exe 是系统自带二进制，行为画像远比临时编译的 exe 干净，
#      不容易被 Defender 行为启发式误杀（exe 做 SendInput 真机踩过）
#   2. 交互层 exe 落盘 done 后立即退出，不再驻留
# 流程：切 DSH 前台 → 原生点击输入框（窗口隐藏/恢复会丢 DOM 焦点，必须真实点击）
#       → 真实 Ctrl+V（SendInput/keybd_event，合成 JS 事件不可信会被网页忽略）
# 输入框坐标来自 paste-hint.json（客户端完成时上报，宿主落盘）；只信 8 秒内的坐标。
$ErrorActionPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DshPaste {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr h, bool fAltTab);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
}
'@

$dir = Join-Path $env:USERPROFILE '.dsh\dsh-snip'
$hintFile = Join-Path $dir 'paste-hint.json'
$log = Join-Path $dir 'paste-debug.log'
function Log([string]$msg) {
  try { [IO.File]::AppendAllText($log, ("[" + [DateTime]::Now.ToString('HH:mm:ss.fff') + "] " + $msg + "`r`n"), (New-Object System.Text.UTF8Encoding $false)) } catch { }
}
Log "start"
if (-not (Test-Path -LiteralPath $hintFile)) { Log "no hint file"; exit 0 }
$hint = $null
try { $hint = Get-Content -LiteralPath $hintFile -Raw | ConvertFrom-Json } catch { }
if (-not $hint -or -not $hint.x -or -not $hint.y) { Log "hint invalid"; exit 0 }
$age = [DateTimeOffset]::Now.ToUnixTimeMilliseconds() - [long]$hint.t
if ($age -gt 8000 -or $age -lt -2000) { Log ("hint stale age=" + $age); exit 0 }   # 过期坐标不可信（窗口可能已移动）
Log ("hint ok (" + $hint.x + "," + $hint.y + ")")

# 找 DSH 主窗口：带可见主窗口的宿主进程（Electron 多层进程里只有主进程有窗口）
$proc = Get-Process | Where-Object {
  $_.MainWindowHandle -ne 0 -and $_.ProcessName -match '(?i)zcode|deepseek|harness|dsh'
} | Select-Object -First 1
if (-not $proc) { Log "dsh window not found"; exit 0 }
$h = $proc.MainWindowHandle
if ($h -eq [IntPtr]::Zero -or -not [DshPaste]::IsWindowVisible($h)) { Log "dsh window invisible"; exit 0 }
Log ("dsh window " + $h)

# 1) 切前台
[DshPaste]::SwitchToThisWindow($h, $true)
[DshPaste]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 350
Log "switched"

# 2) 原生点击输入框（拿到键盘焦点）
[DshPaste]::SetCursorPos([int]$hint.x, [int]$hint.y) | Out-Null
Start-Sleep -Milliseconds 120
[DshPaste]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)    # LEFTDOWN
Start-Sleep -Milliseconds 60
[DshPaste]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)    # LEFTUP
Start-Sleep -Milliseconds 250
Log "clicked"

# 3) 真实 Ctrl+V
[DshPaste]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)    # CTRL down
[DshPaste]::keybd_event(0x56, 0, 0, [UIntPtr]::Zero)    # V down
Start-Sleep -Milliseconds 40
[DshPaste]::keybd_event(0x56, 0, 2, [UIntPtr]::Zero)    # V up
[DshPaste]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero)    # CTRL up
Log "ctrl+v sent"
exit 0
