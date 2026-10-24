# dsh-snip — 截图脚本真实 E2E（仅限 Windows，需要交互桌面）
#
# -Rect 模式（不出遮罩）验证：抓屏、PNG 落盘、last.json 记录、剪贴板图片；
# 以及取消/参数错误路径。隔离 USERPROFILE，不碰真实数据。
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$snip = Join-Path $repoRoot 'scripts\snip.ps1'

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
Add-Type -AssemblyName System.Drawing | Out-Null

$fakeHome = Join-Path $env:TEMP ("dsh-snip-test-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $fakeHome | Out-Null
$env:USERPROFILE = $fakeHome

$failures = 0
function Assert-True([bool]$cond, [string]$name) {
  if ($cond) { Write-Output "PASS $name" }
  else { Write-Output "FAIL $name"; $script:failures++ }
}

function Invoke-Snip([string]$extraArgs) {
  $outPng = Join-Path $fakeHome ("snip-" + [Guid]::NewGuid().ToString('N').Substring(0, 6) + ".png")
  $raw = & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $snip -Out $outPng @($extraArgs -split ' ' | Where-Object { $_ })
  return @{ json = ((($raw | Out-String).Trim()) | ConvertFrom-Json); png = $outPng }
}

# ── 1. 正常区域截图 ──────────────────────────────────────────
$r = Invoke-Snip "-Rect 10,20,320,240"
Assert-True ($r.json.ok -and $r.json.width -eq 320 -and $r.json.height -eq 240) "抓屏返回尺寸 320x240"
Assert-True (Test-Path -LiteralPath $r.png) "PNG 已落盘"
$actual = [System.Drawing.Image]::FromFile($r.png)
Assert-True ($actual.Width -eq 320 -and $actual.Height -eq 240) "PNG 实际尺寸一致（$($actual.Width)x$($actual.Height)）"
$actual.Dispose()

# ── 2. last.json 记录 ────────────────────────────────────────
$lastFile = Join-Path $fakeHome '.dsh\dsh-snip\last.json'
Assert-True (Test-Path -LiteralPath $lastFile) "last.json 已写入"
$last = (Get-Content -LiteralPath $lastFile -Raw | ConvertFrom-Json)
Assert-True ($last.path -eq $r.json.path -and $last.width -eq 320) "last.json 内容与返回一致"

# ── 3. 剪贴板里有图片（子进程 SetImage，系统级可见） ──────────
Start-Sleep -Milliseconds 400
$clipImg = $null
try {
  Add-Type -AssemblyName System.Windows.Forms | Out-Null
  $clipImg = [System.Windows.Forms.Clipboard]::GetImage()
} catch { }
Assert-True ($null -ne $clipImg -and $clipImg.Width -eq 320) "剪贴板可取回截图图片（$($clipImg.Width)x$($clipImg.Height)）"

# ── 4. 参数错误路径 ──────────────────────────────────────────
$r2 = Invoke-Snip "-Rect 0,0,2,2"
Assert-True (-not $r2.json.ok -and $r2.json.error) "过小区域报错"
$r3 = Invoke-Snip "-Rect bad-input"
Assert-True (-not $r3.json.ok -and $r3.json.error) "非法 -Rect 报错"

# ── 清理 ────────────────────────────────────────────────────
Remove-Item -Recurse -Force $fakeHome -ErrorAction SilentlyContinue

Write-Output ""
if ($failures -gt 0) {
  Write-Output "SNIP E2E RESULT: $failures 项失败"
  exit 1
}
Write-Output "SNIP E2E RESULT: 全部通过"
