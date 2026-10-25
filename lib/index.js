/**
 * dsh-snip — 宿主半边
 *
 * 一行 cordis 条目做四件事（全部 fail-open）：
 *   1. 注册本地路由 POST /dsh-snip/start：拉起 PowerShell 框选截图（STA），
 *      PNG 落盘 + 图片进剪贴板，等待用户拖选完成（或 ESC 取消）后返回
 *   2. 挂载 MCP 桥接，模型拿到 last_screenshot 工具
 *   3. 静态审计客户端产物
 *   4. inject webServer（本地路由）
 */
import { spawn } from "node:child_process";
import { appendFileSync, createHash, existsSync, mkdirSync, openSync, readFileSync, renameSync, rmSync, writeFileSync, unlinkSync } from "node:fs";
import { fileURLToPath } from "node:url";
import os from "node:os";
import path from "node:path";
import { platform } from "node:process";

const PACKAGE_ID = "dsh-snip";
const ROUTE_PREFIX = "/dsh-snip";
const IS_WINDOWS = platform === "win32";
const SNIP_TIMEOUT_MS = 120_000;

export const name = "snip-button";
export const inject = ["webServer"];

function snipFile(name) {
  return fileURLToPath(new URL(`../scripts/${name}`, import.meta.url));
}

function snipDir() {
  return path.join(os.homedir(), ".dsh", "dsh-snip");
}

/* ── 交互层 exe：预热编译 + 快速启动路径 ─────────────────────
 * 旧链路「powershell.exe 冷启动 + WinForms 程序集加载 + CodeDom 编译」要 3-5s
 * 才能出遮罩；改为挂载时后台把 scripts/snip-overlay.cs 编译成 exe（csc.exe 是
 * .NET Framework 4.x 自带），点击后直接启动 exe，<1s 出遮罩。
 * exe 名按源码内容哈希：升级/改动自动失效重编。 */
function overlayExePath() {
  try {
    const cs = readFileSync(snipFile("snip-overlay.cs"));
    const hash = createHash("sha256").update(cs).digest("hex").slice(0, 16);
    return path.join(snipDir(), `snip-overlay-${hash}.exe`);
  } catch {
    return null;
  }
}

function findCsc() {
  const windir = process.env.WINDIR || "C:\\Windows";
  for (const part of ["Microsoft.NET/Framework64", "Microsoft.NET/Framework"]) {
    const p = path.join(windir, part, "v4.0.30319", "csc.exe");
    if (existsSync(p)) return p;
  }
  return null;
}

function warmOverlayExe(log, diag) {
  try {
    if (!IS_WINDOWS) return;
    const exe = overlayExePath();
    const cs = snipFile("snip-overlay.cs");
    if (!exe || existsSync(exe)) {
      diag.overlay = existsSync(exe) ? "ready" : "cs-missing";
      return;
    }
    const csc = findCsc();
    if (!csc) {
      diag.overlay = "csc-missing";
      log("找不到 csc.exe，交互层将在首次点击时由 PowerShell 兜底编译");
      return;
    }
    const tmp = `${exe}.${process.pid}.tmp`;
    const child = spawn(
      csc,
      ["/nologo", "/target:exe", "/platform:anycpu", `/out:${tmp}`,
        "/r:System.dll", "/r:System.Drawing.dll", "/r:System.Windows.Forms.dll", cs],
      { stdio: "ignore", windowsHide: true },
    );
    child.on("error", (error) => {
      diag.overlay = `warmup-failed: ${String(error)}`;
      log(`交互层预热失败（首次点击会用 PowerShell 兜底）：${String(error)}`);
    });
    child.on("close", (code) => {
      if (code === 0) {
        try { renameSync(tmp, exe); } catch { /* 并发重命名失败=另一边已就绪 */ }
        diag.overlay = "ready";
        log("交互层预热完成，截图按钮可直接启动 exe");
      } else {
        try { unlinkSync(tmp); } catch { /* ignore */ }
        diag.overlay = `compile-failed code=${code}`;
        log(`交互层预热编译失败（code=${code}），首次点击会用 PowerShell 兜底`);
      }
      writeMountDiag(diag);
    });
    diag.overlay = "warming";
  } catch (error) {
    diag.overlay = `warmup-error: ${String(error)}`;
  }
}

function lastJsonFile() {
  // 与 snip.ps1 的落盘位置一致：%USERPROFILE%\.dsh\dsh-snip\last.json
  const home = process.env.USERPROFILE || os.homedir();
  return path.join(home, ".dsh", "dsh-snip", "last.json");
}

function readLast() {
  try {
    const file = lastJsonFile();
    if (!existsSync(file)) return null;
    return JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

function appendRouteLog(line) {
  try {

    appendFileSync(path.join(snipDir(), "route.log"), `${new Date().toISOString()} ${line}
`);
  } catch {
    /* 日志失败不影响功能 */
  }
}

function sendJson(res, status, obj) {
  try {
    res.writeHead(status, {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-cache, no-store",
    });
    res.end(JSON.stringify(obj));
  } catch {
    /* 客户端断开时忽略 */
  }
}

function auditClientBundle(log) {
  try {
    const bundle = readFileSync(fileURLToPath(new URL("./client.js", import.meta.url)), "utf8");
    const problems = [];
    if (!bundle.includes(`id: "${PACKAGE_ID}"`) && !bundle.includes(`id:"${PACKAGE_ID}"`)) {
      problems.push("bundle id 不匹配");
    }
    if (!bundle.includes("__ModuleLoader__.load")) problems.push("不是模块加载器 bundle");
    if (!bundle.includes("return module.exports")) problems.push("工厂没有交出 exports");
    if (!bundle.includes("conversation.input.right")) problems.push("没有声明目标插槽");
    if (!/exports\.apply\s*=/.test(bundle)) problems.push("没有导出 apply");
    if (problems.length > 0) {
      log(`客户端产物 lib/client.js 检查未通过（按钮可能不出现）：${problems.join("；")}`);
      return;
    }
    log(`客户端产物 lib/client.js 就绪（${Buffer.byteLength(bundle, "utf8")} 字节，静态检查通过）`);
  } catch (error) {
    log(`客户端产物 lib/client.js 不可读（按钮不会出现）：${String(error)}`);
  }
}

/**
 * 分离式启动截图：立即返回，不占住 HTTP 响应。
 * 用户拖选可能耗时很久，webServer 对长响应的行为不可控（实测返回过空体），
 * 所以改为「启动即答 + run.json 状态轮询」。
 * 优先直接启动预热好的交互层 exe（<1s 出遮罩）；exe 未就绪时兜底走 PowerShell。
 */
function startSnipDetached(log, diag, hideWindow = true) {
  if (!IS_WINDOWS) {
    return { started: false, error: "截图功能仅支持 Windows。" };
  }
  try {
    const dir = snipDir();
    mkdirSync(dir, { recursive: true });
    // 宿主侧先声明 running（脚本只在退出路径写 run.json，进行中要靠这条）
    try {
      writeFileSync(path.join(dir, "run.json"), JSON.stringify({ status: "running", t: Date.now() }));
    } catch {
      /* ignore */
    }
    const stderrFd = openSync(path.join(dir, "snip-stderr.log"), "w");

    const exe = overlayExePath();
    if (exe && existsSync(exe)) {
      // 快速路径：无控制台窗口，exe 自己写 run.json/last.json/stdout JSON
      const exeArgs = hideWindow ? [] : ["-NoHide"];
      const child = spawn(exe, exeArgs, {
        stdio: ["ignore", "ignore", stderrFd],
        windowsHide: true,
      });
      child.on("error", (error) => log(`截图交互层启动失败：${String(error)}`));
      diag.snipSpawned = "exe";
      return { started: true };
    }

    const args = ["-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-File", snipFile("snip.ps1")];
    if (!hideWindow) args.push("-NoHide");
    // ⚠️ 不能加 detached: true —— Windows 上 DETACHED_PROCESS 会让控制台版
    // PowerShell 拿不到控制台而瞬间退出（二分实测），遮罩永远出不来。
    const child = spawn("powershell.exe", args, {
      stdio: ["ignore", "ignore", stderrFd],
      windowsHide: true,
    });
    child.on("error", (error) => log(`截图进程启动失败：${String(error)}`));
    diag.snipSpawned = "powershell";
    return { started: true };
  } catch (error) {
    return { started: false, error: String(error) };
  }
}

function readJsonFile(file) {
  try {
    if (!existsSync(file)) return null;
    return JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

/** 读运行状态：running / done / cancelled / failed / idle。超过 150s 的 running 视为超时。 */
function readRunState() {
  const run = readJsonFile(path.join(snipDir(), "run.json"));
  if (!run || !run.status) return { status: "idle" };
  if (run.status === "running" && Date.now() - (run.t || 0) > 150_000) {
    return { status: "failed", error: "截图超时（150 秒无完成信号）" };
  }
  return run;
}

async function mountMcpBridge(ctx, log, diag) {
  try {
    const bridge = await import("@deepseek-ai/dsh-mcp-client");
    const connection = ctx.plugin(bridge, {
      serverName: "snip",
      transport: "stdio",
      command: process.execPath,
      args: [fileURLToPath(new URL("../mcp/server.mjs", import.meta.url))],
      env: { ELECTRON_RUN_AS_NODE: "1" },
      toolCallTimeoutMs: 30_000,
      failOnStartupError: false,
    });
    await connection;
    diag.mcp = "ok";
    log("MCP 工具已挂载（last_screenshot）");
  } catch (error) {
    diag.mcp = `failed: ${String(error)}`;
    log(`MCP 桥接挂载失败（截图按钮不受影响）：${String(error)}`);
  }
}

/** 把挂载诊断写到 ~/.dsh/dsh-snip/mount.json：宿主内部不可观测，这里留一个可读痕迹。 */
function writeMountDiag(diag) {
  try {
    const dir = path.join(os.homedir(), ".dsh", "dsh-snip");
    mkdirSync(dir, { recursive: true });
    writeFileSync(path.join(dir, "mount.json"), JSON.stringify({ ...diag, t: Date.now() }, null, 2));
  } catch {
    /* 诊断写不进去就算了 */
  }
}

export function apply(ctx) {
  // diag 必须在 try 之外声明：try 块内声明的变量对 catch 块不可见
  //（真机踩坑：之前 catch 里引用 try 内的 diag → ReferenceError，掩盖了真正的错误）。
  const diag = {
    t0: Date.now(),
    platform: platform,
    webServer: Boolean(ctx?.webServer && typeof ctx.webServer.register === "function"),
    mcp: "pending",
    overlay: "pending",
  };
  try {
    const candidate = ctx?.logger;
    const sink = typeof candidate === "function" ? candidate(PACKAGE_ID) : candidate;
    const log = (message) => {
      try {
        if (sink && typeof sink.info === "function") sink.info(`[${PACKAGE_ID}] ${message}`);
        else console.info(`[${PACKAGE_ID}] ${message}`);
      } catch {
        /* 连日志都不能抛 */
      }
    };

    auditClientBundle(log);
    warmOverlayExe(log, diag);   // 后台预热编译交互层 exe，不阻塞挂载

    if (ctx?.webServer && typeof ctx.webServer.register === "function") {
      ctx.effect(() =>
        ctx.webServer.register({
          kind: "prefix",
          path: ROUTE_PREFIX,
          handler: async (req, res) => {
            try {
              const url = new URL(req.url ?? "/", "http://local");
              const rest = url.pathname.replace(/\/+$/, "");
              appendRouteLog(`${req.method} ${url.pathname}`);
              if (rest === `${ROUTE_PREFIX}/start` && req.method === "POST") {
                // 请求体可选 {"hideWindow":bool}：截图时是否隐藏 DSH 窗口（客户端右键切换）
                let raw = "";
                req.on("data", (c) => {
                  raw += c;
                  if (raw.length > 8192) req.destroy();
                });
                req.on("end", () => {
                  try {
                    let hideWindow = true;   // 默认隐藏（默认不把 DSH 自己截进去）
                    try {
                      const body = raw ? JSON.parse(raw) : null;
                      if (body && typeof body.hideWindow === "boolean") hideWindow = body.hideWindow;
                    } catch {
                      /* 无 body / 非 JSON → 走默认 */
                    }
                    const state = readRunState();
                    if (state.status === "running") {
                      sendJson(res, 200, { ok: true, started: true, alreadyRunning: true });
                      return;
                    }
                    const result = startSnipDetached(log, diag, hideWindow);
                    if (!result.started) {
                      sendJson(res, 200, { ok: false, error: result.error });
                      return;
                    }
                    sendJson(res, 200, { ok: true, started: true, hideWindow });
                  } catch (error) {
                    sendJson(res, 500, { ok: false, error: String(error) });
                  }
                });
                return;
              }
              if (rest === `${ROUTE_PREFIX}/status`) {
                sendJson(res, 200, { ok: true, state: readRunState() });
                return;
              }
              if (rest === `${ROUTE_PREFIX}/last`) {
                const last = readJsonFile(path.join(snipDir(), "last.json"));
                if (last) sendJson(res, 200, { ok: true, last });
                else sendJson(res, 200, { ok: false, error: "还没有截图记录" });
                return;
              }
              if (rest === `${ROUTE_PREFIX}/clear` && (req.method === "POST" || req.method === "PUT")) {
                try {
                  rmSync(path.join(snipDir(), "last.json"), { force: true });
                } catch {
                  /* ignore */
                }
                sendJson(res, 200, { ok: true, cleared: true });
                return;
              }
              sendJson(res, 404, { ok: false, error: "not found" });
            } catch (error) {
              sendJson(res, 500, { ok: false, error: String(error) });
            }
          },
        }),
        "dsh-snip: snip route",
      );
      log(`本地路由已注册：POST ${ROUTE_PREFIX}/start（立即应答）+ GET /status`);
    } else {
      log("宿主未提供 webServer 服务，截图按钮不可用");
    }

    writeMountDiag(diag);
    // 注意：这里绝不 await —— apply 保持同步（cordis 加载器对返回 Promise 的 apply
    // 的处理与桌宠等已验证插件不同步，疑似导致宿主条目不挂载，真机排查结论）。
    mountMcpBridge(ctx, log, diag).then(() => writeMountDiag(diag)).catch(() => {});
  } catch (error) {
    diag.mcp = `apply-level failure: ${String(error)}`;
    writeMountDiag(diag);
  }
}

// 注意：不要加 default 导出 —— cordis 加载器优先读 default，会丢失 inject/name 声明
// （真机踩坑：default 导出导致宿主条目挂载时 inject 为空，ctx.webServer 直接抛错）。
