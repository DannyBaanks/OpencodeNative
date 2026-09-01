import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import path from "node:path";
import process from "node:process";

const bridge = spawn(process.execPath, [path.resolve("Bridge/bin/opencodenative.mjs"), "link"], {
  cwd: process.cwd(),
  env: process.env,
  stdio: ["ignore", "pipe", "pipe"],
});
let stdout = "";
let stderr = "";
bridge.stdout.on("data", (chunk) => { stdout += chunk; });
bridge.stderr.on("data", (chunk) => { stderr += chunk; });

try {
  const pairing = await waitFor(() => stdout.match(/opencodenative:\/\/pair\?[^\s]+/)?.[0], 15_000);
  const url = new URL(pairing);
  const authorization = `Basic ${Buffer.from(`${url.searchParams.get("username")}:${url.searchParams.get("password")}`).toString("base64")}`;
  const health = await waitFor(async () => {
    try {
      const response = await fetch("http://127.0.0.1:4096/global/health", {
        headers: { Authorization: authorization, "x-opencode-directory": process.cwd() },
      });
      if (!response.ok) return undefined;
      return response.json();
    } catch {
      return undefined;
    }
  }, 30_000);
  assert.equal(health.healthy, true);
  console.log(JSON.stringify({ runtime: "official OpenCode", command: "opencodenative link", health }, null, 2));
} finally {
  if (bridge.exitCode === null && process.platform === "win32") {
    spawnSync("taskkill", ["/PID", String(bridge.pid), "/T", "/F"], { stdio: "ignore" });
  } else if (bridge.exitCode === null) {
    bridge.kill("SIGTERM");
  }
  await Promise.race([
    new Promise((resolve) => bridge.once("exit", resolve)),
    new Promise((_, reject) => setTimeout(() => reject(new Error(`official bridge did not stop; stderr=${stderr.slice(-2000)}`)), 15_000)),
  ]);
}

async function waitFor(probe, timeout) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const value = await probe();
    if (value) return value;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`probe timeout; stderr=${stderr.slice(-2000)}`);
}
