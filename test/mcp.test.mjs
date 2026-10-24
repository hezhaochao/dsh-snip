/**
 * dsh-snip — MCP 协议层测试。
 *
 * 拉起 mcp/server.mjs（隔离 USERPROFILE）：握手、工具清单、last_screenshot
 * （预置 last.json）、take_screenshot 真实抓屏（Windows）与非法参数。
 */
import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { mkdtempSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import os from "node:os";
import path from "node:path";

const SERVER = fileURLToPath(new URL("../mcp/server.mjs", import.meta.url));
const IS_WINDOWS = process.platform === "win32";

function makeFakeHome(record) {
  const home = mkdtempSync(path.join(os.tmpdir(), "dsh-snip-test-"));
  const dir = path.join(home, ".dsh", "dsh-snip");
  mkdirSync(dir, { recursive: true });
  if (record) writeFileSync(path.join(dir, "last.json"), JSON.stringify(record));
  return home;
}

function startServer(fakeHome) {
  const child = spawn(process.execPath, [SERVER], {
    stdio: ["pipe", "pipe", "pipe"],
    env: { ...process.env, HOME: fakeHome, USERPROFILE: fakeHome },
  });
  const pending = new Map();
  let nextId = 1;
  const rl = createInterface({ input: child.stdout, terminal: false });
  rl.on("line", (line) => {
    const trimmed = line.trim();
    if (!trimmed) return;
    let msg;
    try {
      msg = JSON.parse(trimmed);
    } catch {
      return;
    }
    if (msg.id !== undefined && pending.has(msg.id)) {
      const resolve = pending.get(msg.id);
      pending.delete(msg.id);
      resolve(msg);
    }
  });
  let stderrBuf = "";
  child.stderr.on("data", (chunk) => {
    stderrBuf += chunk;
  });
  function request(method, params) {
    const id = nextId++;
    const message = { jsonrpc: "2.0", id, method };
    if (params !== undefined) message.params = params;
    const promise = new Promise((resolve, reject) => {
      pending.set(id, resolve);
      setTimeout(() => {
        if (pending.has(id)) {
          pending.delete(id);
          reject(new Error(`请求超时: ${method}\nstderr: ${stderrBuf.slice(-400)}`));
        }
      }, 120_000);
    });
    child.stdin.write(JSON.stringify(message) + "\n");
    return promise;
  }
  function notify(method, params) {
    const message = { jsonrpc: "2.0", method };
    if (params !== undefined) message.params = params;
    child.stdin.write(JSON.stringify(message) + "\n");
  }
  async function close() {
    try {
      child.kill();
    } catch {}
  }
  return { request, notify, close };
}

async function handshake(server) {
  const init = await server.request("initialize", {
    protocolVersion: "2024-11-05",
    capabilities: {},
    clientInfo: { name: "snip-test", version: "0.0.0" },
  });
  server.notify("notifications/initialized");
  return init;
}

test("MCP 握手与工具清单", async () => {
  const server = startServer(makeFakeHome(null));
  try {
    const init = await handshake(server);
    assert.equal(init.result.protocolVersion, "2024-11-05");
    assert.equal(init.result.serverInfo.name, "dsh-snip");
    const list = await server.request("tools/list");
    assert.deepEqual(
      list.result.tools.map((t) => t.name).sort(),
      ["last_screenshot", "take_screenshot"],
    );
  } finally {
    await server.close();
  }
});

test("last_screenshot：成功路径与文件缺失路径", async (t) => {
  if (!IS_WINDOWS) {
    t.skip("需要 Windows");
    return;
  }
  // 成功路径：预置记录指向真实存在的文件
  const home1 = makeFakeHome(null);
  const realPng = path.join(home1, "real-snippet.png");
  writeFileSync(realPng, "png-bytes");
  const server1 = startServer(
    makeFakeHome({ ok: true, path: realPng, width: 320, height: 240, t: Date.now() }),
  );
  try {
    await handshake(server1);
    const call = await server1.request("tools/call", { name: "last_screenshot", arguments: {} });
    const payload = JSON.parse(call.result.content[0].text);
    assert.equal(call.result.isError, undefined, `不应报错: ${payload.error || ""}`);
    assert.equal(payload.ok, true);
    assert.equal(payload.width, 320);
    assert.ok(existsSync(payload.path));
  } finally {
    await server1.close();
  }

  // 缺失路径：记录指向已删除的文件 → 诚实报错
  const home2 = makeFakeHome(
    { ok: true, path: path.join(home1, "gone.png"), width: 100, height: 100, t: Date.now() },
  );
  const server2 = startServer(home2);
  try {
    await handshake(server2);
    const call = await server2.request("tools/call", { name: "last_screenshot", arguments: {} });
    const payload = JSON.parse(call.result.content[0].text);
    assert.equal(call.result.isError, true);
    assert.ok(payload.error.includes("清理"), `应说明文件已被清理，实际: ${payload.error}`);
  } finally {
    await server2.close();
  }
});

test("take_screenshot：真实抓屏（Windows 交互桌面）", async (t) => {
  if (!IS_WINDOWS) {
    t.skip("需要 Windows");
    return;
  }
  const home = makeFakeHome(null);
  const server = startServer(home);
  try {
    await handshake(server);
    const call = await server.request("tools/call", {
      name: "take_screenshot",
      arguments: { region: "0,0,400,300" },
    });
    const payload = JSON.parse(call.result.content[0].text);
    assert.equal(payload.ok, true, `截图应成功: ${payload.error || ""}`);
    assert.equal(payload.width, 400);
    assert.ok(existsSync(payload.path), "PNG 应存在");

    const bad = await server.request("tools/call", {
      name: "take_screenshot",
      arguments: { region: "not-a-rect" },
    });
    assert.equal(bad.result.isError, true);
  } finally {
    await server.close();
  }
});
