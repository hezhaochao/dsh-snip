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
import { existsSync, readFileSync } from "node:fs";
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

/** 运行截图脚本（交互模式等待用户拖选；超时兜底）。 */
function runSnip(log) {
  return new Promise((resolve) => {
    if (!IS_WINDOWS) {
      resolve({ ok: false, error: "截图功能仅支持 Windows。" });
      return;
    }
    const started = Date.now();
    const args = ["-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-File", snipFile("snip.ps1")];
    const child = spawn("powershell.exe", args, { windowsHide: true });
    let stdout = "";
    let stderr = "";
    let settled = false;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(killer);
      resolve(result);
    };
    const killer = setTimeout(() => {
      try {
        child.kill();
      } catch {
        /* ignore */
      }
      finish({ ok: false, error: `截图超时（${Math.round((Date.now() - started) / 1000)}s）` });
    }, SNIP_TIMEOUT_MS);
    child.stdout.on("data", (c) => {
      stdout += c;
    });
    child.stderr.on("data", (c) => {
      stderr += c;
    });
    child.on("error", (error) => finish({ ok: false, error: `无法启动截图脚本：${String(error)}` }));
    child.on("close", (code) => {
      const trimmed = stdout.trim();
      if (!trimmed) {
        finish({ ok: false, error: `截图脚本无输出（code=${code}）${stderr ? `: ${stderr.trim().slice(0, 300)}` : ""}` });
        return;
      }
      try {
        const parsed = JSON.parse(trimmed);
        if (code !== 0 && parsed.ok !== false) parsed.ok = false;
        finish(parsed);
      } catch {
        finish({ ok: false, error: `截图脚本输出不是 JSON：${trimmed.slice(0, 300)}` });
      }
    });
  });
}

async function mountMcpBridge(ctx, log) {
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
    log("MCP 工具已挂载（last_screenshot）");
  } catch (error) {
    log(`MCP 桥接挂载失败（截图按钮不受影响）：${String(error)}`);
  }
}

export function apply(ctx) {
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

    if (ctx?.webServer && typeof ctx.webServer.register === "function") {
      ctx.effect(() =>
        ctx.webServer.register({
          kind: "prefix",
          path: ROUTE_PREFIX,
          handler: async (req, res) => {
            try {
              const url = new URL(req.url ?? "/", "http://local");
              const rest = url.pathname.replace(/\/+$/, "");
              if (rest === `${ROUTE_PREFIX}/start` && req.method === "POST") {
                // 等待用户拖选（或 ESC），完成/取消/超时后返回
                const result = await runSnip(log);
                sendJson(res, 200, result);
                return;
              }
              if (rest === `${ROUTE_PREFIX}/last`) {
                const last = readLast();
                if (last) sendJson(res, 200, { ok: true, last });
                else sendJson(res, 200, { ok: false, error: "还没有截图记录" });
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
      log(`本地路由已注册：POST ${ROUTE_PREFIX}/start`);
    } else {
      log("宿主未提供 webServer 服务，截图按钮不可用");
    }

    mountMcpBridge(ctx, log);
  } catch {
    /* 整体失败也必须让 apply 静默成功 */
  }
}

export default { apply };
