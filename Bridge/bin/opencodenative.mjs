#!/usr/bin/env node
import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";

function lanIPv4() {
  for (const entries of Object.values(os.networkInterfaces())) {
    for (const entry of entries ?? []) {
      if (entry.family === "IPv4" && !entry.internal) return entry.address;
    }
  }
  return "127.0.0.1";
}

export function parseLinkOptions(args, env = process.env) {
  const command = args[0] ?? "link";
  if (command !== "link") throw new Error("usage: opencodenative link [--runtime opencode|openisy] [--openisy-root PATH] [--port 4096] [--directory PATH]");

  const values = new Map();
  const valid = new Set(["--runtime", "--openisy-root", "--port", "--directory"]);
  for (let i = 1; i < args.length; i += 2) {
    const name = args[i];
    const value = args[i + 1];
    if (!valid.has(name)) throw new Error(`unknown option: ${name}`);
    if (!value || value.startsWith("--")) throw new Error(`missing value for ${name}`);
    values.set(name, value);
  }

  const runtime = values.get("--runtime") ?? "opencode";
  if (runtime !== "opencode" && runtime !== "openisy") throw new Error(`unsupported runtime: ${runtime}`);
  const port = Number(values.get("--port") ?? "4096");
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error(`invalid port: ${port}`);
  const openisyRoot = values.get("--openisy-root") ?? env.OPENISY_ROOT;
  if (runtime === "openisy" && !openisyRoot) throw new Error("OpenISy requires --openisy-root PATH or OPENISY_ROOT");
  if (runtime === "opencode" && values.has("--openisy-root")) throw new Error("--openisy-root requires --runtime openisy");

  return {
    runtime,
    port,
    directory: path.resolve(values.get("--directory") ?? process.cwd()),
    openisyRoot: openisyRoot ? path.resolve(openisyRoot) : undefined,
  };
}

export function runtimeCommand(options, platform = process.platform) {
  const serverArgs = ["serve", "--hostname", "0.0.0.0", "--port", String(options.port), "--mdns"];
  if (options.runtime === "opencode") {
    return { executable: "opencode", args: serverArgs, cwd: options.directory, shell: platform === "win32" };
  }

  const packageDirectory = path.join(options.openisyRoot, "packages", "opencode");
  const entry = path.join(packageDirectory, "src", "index.ts");
  if (!existsSync(entry)) throw new Error(`OpenISy entrypoint not found: ${entry}`);
  return {
    executable: "bun",
    args: ["--cwd", packageDirectory, "src/index.ts", ...serverArgs],
    cwd: options.directory,
    shell: false,
  };
}

export function childEnvironment(env, username, password) {
  return {
    ...env,
    OPENCODE_SERVER_USERNAME: username,
    OPENCODE_SERVER_PASSWORD: password,
  };
}

export function main(args = process.argv.slice(2), env = process.env) {
  let options;
  let runtime;
  try {
    options = parseLinkOptions(args, env);
    runtime = runtimeCommand(options);
  } catch (error) {
    console.error(error.message);
    return 2;
  }

  const host = lanIPv4();
  const username = "opencode";
  const password = randomBytes(24).toString("base64url");
  const query = new URLSearchParams({
    host,
    port: String(options.port),
    username,
    password,
    directory: options.directory,
  });
  const pairing = `opencodenative://pair?${query.toString()}`;

  console.log("");
  console.log("opencode native / desktop link");
  console.log("────────────────────────────────────────");
  if (options.runtime === "openisy") console.log("runtime   OpenISy");
  console.log(`project   ${options.directory}`);
  console.log(`server    http://${host}:${options.port}`);
  console.log("");
  console.log("paste this into the iPhone app:");
  console.log("");
  console.log(pairing);
  console.log("");
  console.log("Keep this terminal open. Ctrl+C stops the link.");
  console.log("────────────────────────────────────────");
  console.log("");

  const child = spawn(runtime.executable, runtime.args, {
    cwd: runtime.cwd,
    env: childEnvironment(env, username, password),
    stdio: "inherit",
    shell: runtime.shell,
  });

  child.on("error", (error) => {
    console.error(`failed to start ${options.runtime}: ${error.message}`);
    if (options.runtime === "openisy") console.error("Make sure Bun is installed and OPENISY_ROOT points to the OpenISy repository.");
    else console.error("Make sure `opencode` is installed and available in PATH.");
    process.exitCode = 1;
  });
  child.on("exit", (code, signal) => {
    if (signal && process.platform !== "win32") process.kill(process.pid, signal);
    else process.exitCode = code ?? 0;
  });
  for (const signal of ["SIGINT", "SIGTERM"]) {
    process.on(signal, () => child.kill(signal));
  }
  return child;
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  const result = main();
  if (typeof result === "number") process.exitCode = result;
}
