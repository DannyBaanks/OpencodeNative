#!/usr/bin/env node
import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import os from "node:os";
import process from "node:process";

const args = process.argv.slice(2);
const command = args[0] ?? "link";

function arg(name, fallback) {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
}

function lanIPv4() {
  for (const entries of Object.values(os.networkInterfaces())) {
    for (const entry of entries ?? []) {
      if (entry.family === "IPv4" && !entry.internal) return entry.address;
    }
  }
  return "127.0.0.1";
}

if (command !== "link") {
  console.error("usage: opencodenative link [--port 4096] [--directory PATH]");
  process.exit(2);
}

const port = Number(arg("--port", "4096"));
const directory = arg("--directory", process.cwd());
const host = lanIPv4();
const username = "opencode";
const password = randomBytes(24).toString("base64url");
const query = new URLSearchParams({
  host,
  port: String(port),
  username,
  password,
  directory,
});
const pairing = `opencodenative://pair?${query.toString()}`;

console.log("");
console.log("opencode native / desktop link");
console.log("────────────────────────────────────────");
console.log(`project   ${directory}`);
console.log(`server    http://${host}:${port}`);
console.log("");
console.log("paste this into the iPhone app:");
console.log("");
console.log(pairing);
console.log("");
console.log("Keep this terminal open. Ctrl+C stops the link.");
console.log("────────────────────────────────────────");
console.log("");

const child = spawn(
  "opencode",
  ["serve", "--hostname", "0.0.0.0", "--port", String(port), "--mdns"],
  {
    cwd: directory,
    env: {
      ...process.env,
      OPENCODE_SERVER_USERNAME: username,
      OPENCODE_SERVER_PASSWORD: password,
    },
    stdio: "inherit",
    shell: process.platform === "win32",
  },
);

child.on("error", (error) => {
  console.error(`failed to start opencode: ${error.message}`);
  console.error("Make sure `opencode` is installed and available in PATH.");
  process.exit(1);
});
child.on("exit", (code, signal) => {
  if (signal) process.kill(process.pid, signal);
  process.exit(code ?? 0);
});
for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => child.kill(signal));
}
