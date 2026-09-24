#!/usr/bin/env node
import { execSync, spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";

// Eleccion de IP LAN: las interfaces link-local (169.254.*) y virtuales
// (Bluetooth, Hyper-V, WSL) aparecen primeras en networkInterfaces(); el
// pairing apuntaria a una IP inalcanzable para el iPhone. Se prefiere una
// IPv4 privada enrutable (RFC1918) y se avisa si no hay ninguna.
export function isPrivateRoutableIPv4(ip) {
  const parts = ip.split(".").map(Number);
  if (parts.length !== 4 || parts.some((n) => Number.isNaN(n) || n < 0 || n > 255)) return false;
  if (parts[0] === 192 && parts[1] === 168) return true;
  if (parts[0] === 10) return true;
  if (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) return true;
  return false;
}

export function bestLanIPv4(addresses) {
  const nonLocal = addresses.filter((ip) => !ip.startsWith("169.254."));
  return nonLocal.find(isPrivateRoutableIPv4) ?? nonLocal[0] ?? "127.0.0.1";
}

function lanIPv4() {
  const addresses = [];
  for (const entries of Object.values(os.networkInterfaces())) {
    for (const entry of entries ?? []) {
      if (entry.family === "IPv4" && !entry.internal) addresses.push(entry.address);
    }
  }
  return bestLanIPv4(addresses);
}

// `--host` ausente = LAN como siempre. `--host tailscale` resuelve la IPv4 del
// Tailnet (`tailscale ip -4`); cualquier otro valor se usa literal (IP o
// MagicDNS). Las IPs Tailscale (100.64/10 CGNAT) NO son RFC1918, asi que el
// WARNING de alcance LAN no aplica en ese modo.
export function resolvePairingHost(explicitHost, exec = execSync) {
  if (!explicitHost) return { host: lanIPv4(), tailscale: false };
  if (explicitHost !== "tailscale") return { host: explicitHost, tailscale: false };
  let output;
  try {
    output = exec("tailscale ip -4", { encoding: "utf8" });
  } catch {
    throw new Error("could not resolve Tailscale IPv4 (is tailscale up? check `tailscale status`)");
  }
  const ip = String(output).split(/\s+/).find((t) => /^\d+\.\d+\.\d+\.\d+$/.test(t));
  if (!ip) throw new Error("could not resolve Tailscale IPv4 (is tailscale up? check `tailscale status`)");
  return { host: ip, tailscale: true };
}

export function parseLinkOptions(args, env = process.env) {
  const command = args[0] ?? "link";
  if (command !== "link") throw new Error("usage: opencodenative link [--runtime opencode|openisy] [--openisy-root PATH] [--port 4096] [--directory PATH] [--host LAN|tailscale|IP]");

  const values = new Map();
  const valid = new Set(["--runtime", "--openisy-root", "--port", "--directory", "--host"]);
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
    host: values.get("--host"),
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

  const { host, tailscale } = resolvePairingHost(options.host);
  const lanReachable = tailscale || isPrivateRoutableIPv4(host);
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
  console.log(`server    http://${host}:${options.port}${tailscale ? "  (via Tailscale, cifrado por WireGuard)" : ""}`);
  if (!lanReachable) {
    console.log("");
    console.log("WARNING: no private-routable IPv4 (RFC1918) was found on this");
    console.log("machine. The printed pairing host is likely UNREACHABLE from the");
    console.log("iPhone. Connect both devices to the same Wi-Fi/LAN and retry.");
  }
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
