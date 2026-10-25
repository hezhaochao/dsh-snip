# dsh-snip 📸 快速截图

[![Test](https://github.com/hezhaochao/dsh-snip/actions/workflows/test.yml/badge.svg)](./actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows-0078D6)]()
[![DSH](https://img.shields.io/badge/DeepSeek%20Harness-0.2.x-4d93f8)](https://github.com/deepseek-ai/deepseek-harness)

一个 [DeepSeek Harness（DSH）](https://github.com/deepseek-ai/deepseek-harness)插件：
输入框旁的「📸 截图」按钮——像豆包一样一键框选截图，**不用再开本地截图工具**。
截完图片自动进剪贴板，Ctrl+V 直接贴进对话；模型还能用 MCP 工具读最近的截图帮你分析。

## 用法

1. 点输入框旁的「📸 截图」按钮
2. DSH 窗口**自动暂时隐藏**（不会截到自己），屏幕变暗
3. 拖框选区（ESC 取消）→ 松手完成
4. DSH 窗口自动恢复，提示「✅ 已进剪贴板——Ctrl+V 粘贴到输入框」
5. 粘贴后模型就能看到图（配合视觉模型/视觉插件）

## 组成

```
客户端 lib/client.js
  「📸 截图」按钮（conversation.input.right 插槽）→ POST /dsh-snip/start
宿主 lib/index.js
  本地路由 POST /dsh-snip/start（等待拖选完成/取消/超时）+ GET /last
  + 挂载 MCP 桥接（模型工具）
PowerShell scripts/snip.ps1（-STA）
  交互层 = Add-Type 运行时编译的 C# 遮罩窗体（DLL 按源码哈希缓存，二次启动零编译）
  ——事件热路径全部在编译代码里，PowerShell 只负责抓屏/裁剪/落盘
  全屏冻结底图 + 窗口吸附高亮（EnumWindows + DWM 扩展边框）+ 橡皮筋选框
  （选区外压暗、蓝框、白色手柄、实时尺寸）+ 确认工具条 + ESC 取消
  → CopyFromScreen 抓屏 → PNG 落盘 ~/.dsh/dsh-snip/ + 图片写剪贴板
  → 记录 last.json（路径/尺寸/时间）
MCP mcp/server.mjs
  last_screenshot   最近一次截图的 PNG 路径与尺寸（配视觉工具"看图"）
  take_screenshot   静默截指定区域（x,y,w,h，无遮罩，模型自助观察屏幕用）
```

## 设计借鉴

交互层重写前调研了主流开源实现，借鉴其**设计思路**（全部原创实现，未复制任何代码）：

| 项目 | 许可 | 借鉴点 |
|---|---|---|
| [ShareX](https://github.com/ShareX/ShareX) | GPL-3.0 | 全屏无边框窗体、Win32/DWM 窗口吸附思路 |
| [Greenshot](https://github.com/greenshot/greenshot) | GPL-3.0 | `OptimizedDoubleBuffer` 双缓冲三件套、预渲染压暗背景 |
| [xland/ScreenCapture](https://github.com/xland/ScreenCapture) | MIT | 微信式交互取向、单文件轻量化 |
| [Flameshot](https://github.com/flameshot-org/flameshot) | GPL-3.0 | 选区交互 UX |

v0.1.5 及之前把事件处理写在 PowerShell 脚本块里，每个 MouseMove 都要过一遍解释器，
实测就是"左键失灵、拖选卡顿"的根源——这也是上面这些成熟工具全部用编译代码做
事件循环的原因。v0.1.6 起交互层改为运行时编译的 C#。

## 安装

```bash
dsh plugin --profile <你的 profile> add github:hezhaochao/dsh-snip
```

安装后**完全退出 DSH（含托盘）再重启**。要求 Windows 10/11。

## 为什么完成后还要按一次 Ctrl+V

DSH 的对话输入是网页环境，浏览器安全沙箱不允许插件替用户模拟粘贴。
这是与豆包（原生应用可自动插入）唯一的差别——截图本身已经进了剪贴板，
Ctrl+V 是你的最后一个动作。

## 给模型的两个 MCP 工具（`mcp__snip__<名>`）

| 工具 | 作用 |
|---|---|
| `last_screenshot` | 最近一次截图的 PNG 路径 + 尺寸——配视觉工具即可"看"你刚截的图并分析 |
| `take_screenshot` | 模型自助静默截屏（指定 x,y,w,h 区域），用于观察屏幕状态；无遮罩、不抢焦点 |

## 隐私与行为

- 截图 PNG 只存在本机 `~/.dsh/dsh-snip/`；`last.json` 只记最近一次的路径与尺寸
- 不上传、不联网；截图后想删就手动删目录，或不管它（PNG 不进任何历史）
- 框选期间 DSH 窗口被暂时隐藏（截完自动恢复并抢回前台）；找不到窗口时静默跳过
- 截图有 120 秒超时兜底（拖选太久不选会自动结束）

## 兼容性

- 声明 `engines.dsh: ">=0.2.0-rc.1 <0.3.0-0"`，已在 **v0.2.1-rc.3**（当前最新版）上
  完成安装 / 配置树组合 / 卸载验证
- 多显示器支持（遮罩覆盖整个虚拟屏）；高 DPI 下坐标为物理像素
- 非 Windows：按钮安装后仍会出现，点击返回明确的平台错误

## 开发与测试

```bash
git clone https://github.com/hezhaochao/dsh-snip.git
cd dsh-snip
npm test             # MCP 协议层（隔离 USERPROFILE）
npm run test:snip    # 截图脚本真实 E2E：-Rect 抓屏/PNG 尺寸/last.json/剪贴板图片（仅 Windows）
```

`.ps1` 必须保持 **UTF-8 with BOM**（PowerShell 5.1 编码坑，真机踩过）。

本地真机验证插件挂载：

```bash
dsh plugin --profile zz-test add link:"<本仓库绝对路径>"
dsh --profile zz-test --dump-config   # 应能看到 id: snip-button 条目
```

## 已知限制

- 框选遮罩期间其他显示器同属一个虚拟屏，跨屏拖选没问题；遮罩底图是启动瞬间的冻结画面
- 窗口吸附基于顶层窗口枚举，识别不到子面板/网页内部元素（QQ/微信的"智能选区"同样只到窗口级）
- 个别全屏独占游戏上遮罩可能被压到下面——这类场景本就不适合网页式截图
- `take_screenshot` 抓屏包含遮罩以外的一切内容，请勿用于窥探他人屏幕
- 首次启动遮罩需要编译一次 C#（约 1-2 秒），之后走 `~/.dsh/dsh-snip/` 里的 DLL 缓存

## 许可

[MIT](./LICENSE) © hezhaochao
