#!/usr/bin/env node
/**
 * dsh-snip — MCP stdio 服务器（零依赖、裸 JSON-RPC 实现）
 *
 * 给模型一个工具（mcp__snip__last_screenshot）：读最近一次截图的信息
 * （PNG 路径 + 尺寸），配合视觉工具即可"看"截图内容。
 * 另有 take_screenshot：用 -Rect 模式静默截指定区域（无遮罩交互）。
 */
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { existsSync, readFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const PLUGIN_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const SNIP_PS1 = path.join(PLUGIN_ROOT, "scripts", "snip.ps1");
const VERSION = "0.1.0";
const IS_WINDOWS = process.platform === "win32";
const TOOL_TIMEOUT_MS = 120_000;

function lastJsonFile() {
  return path.join(os.homedir(), ".dsh", "dsh-snip", "last.json");
}

function runSnipPs1(rect) {
  return new Promise((resolve) => {
    if (!IS_WINDOWS) {
      resolve({ ok: false, error: "截图仅支持 Windows。" });
      return;
    }
    const args = ["-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-File", SNIP_PS1];
    if (rect) args.push("-Rect", rect, "-NoHide");
    const child = spawn("powershell.exe", args, { windowsHide: true });
    let stdout = "";
    let stderr = "";
    let settled = false;
    const finish = (r) => {
      if (settled) return;
      settled = true;
      clearTimeout(killer);
      resolve(r);
    };
    const killer = setTimeout(() => {
      try {
        child.kill();
      } catch {}
      finish({ ok: false, error: "截图超时" });
    }, TOOL_TIMEOUT_MS);
    child.stdout.on("data", (c) => (stdout += c));
    child.stderr.on("data", (c) => (stderr += c));
    child.on("error", (e) => finish({ ok: false, error: String(e) }));
    child.on("close", (code) => {
      const t = stdout.trim();
      if (!t) {
        finish({ ok: false, error: `截图脚本无输出（code=${code}）${stderr ? ": " + stderr.trim().slice(0, 300) : ""}` });
        return;
      }
      try {
        const parsed = JSON.parse(t);
        if (code !== 0 && parsed.ok !== false) parsed.ok = false;
        finish(parsed);
      } catch {
        finish({ ok: false, error: `输出不是 JSON：${t.slice(0, 300)}` });
      }
    });
  });
}

const obj = (properties, required = []) => ({
  type: "object",
  properties,
  required,
  additionalProperties: false,
});

const TOOLS = [
  {
    name: "last_screenshot",
    description:
      "Get the most recent snipped screenshot: PNG file path and dimensions. Pair with a vision tool to read what is on it (the user just pressed 📸 截图 and may want analysis).",
    inputSchema: obj({}),
  },
  {
    name: "take_screenshot",
    description:
      "Silently capture a screen region to a PNG file (no selection overlay, image also copied to clipboard). Windows only. Use for your own observation; for the user's interactive snip they press 📸 截图 themselves.",
    inputSchema: obj(
      {
        region: {
          type: "string",
          description: "Region as 'x,y,w,h' in physical screen pixels, e.g. '0,0,1280,720'.",
        },
      },
      ["region"],
    ),
  },
];

async function callTool(name, args) {
  const a = args ?? {};
  if (!IS_WINDOWS) return err("截图功能仅支持 Windows。");
  if (name === "last_screenshot") {
    const file = lastJsonFile();
    if (!existsSync(file)) return err("还没有截图记录（用户还没按过 📸 截图）");
    try {
      const last = JSON.parse(readFileSync(file, "utf8"));
      if (!last || last.ok === false || !last.path) return err("最近一次截图记录无效");
      if (!existsSync(last.path)) return err("截图文件已被清理：" + last.path);
      return ok({ ok: true, path: last.path, width: last.width, height: last.height, time: last.t });
    } catch (error) {
      return err(String(error));
    }
  }
  if (name === "take_screenshot") {
    const rect = String(a.region || "").trim();
    if (!/^\s*-?\d+\s*,\s*-?\d+\s*,\s*\d+\s*,\s*\d+\s*$/.test(rect)) {
      return err("region 需要 x,y,w,h 格式，例如 '0,0,1280,720'");
    }
    const r = await runSnipPs1(rect);
    return r.ok ? ok(r) : err(r.error || "截图失败");
  }
  return err(`未知工具：${name}`);
}

function ok(payload) {
  return { content: [{ type: "text", text: JSON.stringify(payload ?? { ok: true }) }] };
}

function err(message) {
  return { content: [{ type: "text", text: JSON.stringify({ ok: false, error: String(message) }) }], isError: true };
}

/* ────────────────────────── JSON-RPC 骨架 ────────────────────────── */

function writeMessage(message) {
  try {
    process.stdout.write(JSON.stringify(message) + "\n");
  } catch {}
}

function reply(id, result) {
  writeMessage({ jsonrpc: "2.0", id, result });
}

function replyError(id, code, message) {
  writeMessage({ jsonrpc: "2.0", id, error: { code, message } });
}

const serverInfo = { name: "dsh-snip", version: VERSION };

async function dispatch(message) {
  const { id, method, params } = message;
  switch (method) {
    case "initialize":
      reply(id, { protocolVersion: "2024-11-05", capabilities: { tools: {} }, serverInfo });
      return;
    case "ping":
      reply(id, {});
      return;
    case "tools/list":
      reply(id, { tools: TOOLS });
      return;
    case "tools/call": {
      try {
        reply(id, await callTool(params?.name ?? "", params?.arguments));
      } catch (error) {
        reply(id, err(`工具执行异常：${String(error)}`));
      }
      return;
    }
    default:
      if (id !== undefined && id !== null && method && !method.startsWith("notifications/")) {
        replyError(id, -32601, `Method not found: ${method}`);
      }
  }
}

function main() {
  process.stderr.write("[dsh-snip] ready\n");
  const rl = createInterface({ input: process.stdin, terminal: false });
  rl.on("line", (line) => {
    const trimmed = line.trim();
    if (!trimmed) return;
    let message;
    try {
      message = JSON.parse(trimmed);
    } catch {
      process.stderr.write(`[dsh-snip] 丢弃非 JSON 行：${trimmed.slice(0, 120)}\n`);
      return;
    }
    Promise.resolve(dispatch(message)).catch((error) => {
      process.stderr.write(`[dsh-snip] dispatch 异常：${String(error)}\n`);
      if (message && message.id !== undefined && message.id !== null) {
        replyError(message.id, -32603, "Internal error");
      }
    });
  });
  rl.on("close", () => process.exit(0));
}

main();
