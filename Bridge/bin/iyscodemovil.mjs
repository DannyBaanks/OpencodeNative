#!/usr/bin/env node
import { execSync, spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";

const RUNTIMES = {
    opencode: {
        label: "OpenCode",
        check: () => true,
        args: (port, dir) => ["serve", "--hostname", "0.0.0.0", "--port", String(port), "--mdns"],
        executable: "opencode",
        shell: process.platform === "win32",
        cwd: (dir) => dir,
        env: (env, username, password) => ({ ...env, OPENCODE_SERVER_USERNAME: username, OPENCODE_SERVER_PASSWORD: password }),
    },
    openisy: {
        label: "OpenISy",
        check: () => existsSync(path.join(process.env.OPENISY_ROOT ?? "", "packages", "opencode", "src", "index.ts")),
        args: (port, dir) => ["--cwd", path.join(process.env.OPENISY_ROOT ?? "", "packages", "opencode"), "src/index.ts", "serve", "--hostname", "0.0.0.0", "--port", String(port), "--mdns"],
        executable: "bun",
        shell: false,
        cwd: (dir) => dir,
        env: (env, username, password) => ({ ...env, OPENCODE_SERVER_USERNAME: username, OPENCODE_SERVER_PASSWORD: password }),
    },
    crush: { label: "Crush", check: () => false, args: () => [], executable: "crush", shell: false, cwd: (dir) => dir, env: () => ({}), notImplemented: "Crush server mode not yet available." },
    codex: { label: "Codex", check: () => false, args: () => [], executable: "codex", shell: false, cwd: (dir) => dir, env: () => ({}), notImplemented: "Codex server mode not yet available." },
    "claude-code": { label: "Claude Code", check: () => false, args: () => [], executable: "claude-code", shell: false, cwd: (dir) => dir, env: () => ({}), notImplemented: "Claude Code server mode not yet available." },
    gemini: { label: "Gemini", check: () => false, args: () => [], executable: "gemini", shell: false, cwd: (dir) => dir, env: () => ({}), notImplemented: "Gemini CLI server mode not yet available." },
};

export function isPrivateRoutableIPv4(ip) { const parts = ip.split(".").map(Number); if (parts.length !== 4 || parts.some((n) => Number.isNaN(n) || n < 0 || n > 255)) return false; if (parts[0] === 192 && parts[1] === 168) return true; if (parts[0] === 10) return true; if (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) return true; return false; }

export function bestLanIPv4(addresses) { const nonLocal = addresses.filter((ip) => !ip.startsWith("169.254.")); return nonLocal.find(isPrivateRoutableIPv4) ?? nonLocal[0] ?? "127.0.0.1"; }

function lanIPv4() { const addresses = []; for (const entries of Object.values(os.networkInterfaces())) { for (const entry of entries ?? []) { if (entry.family === "IPv4" && !entry.internal) addresses.push(entry.address); } } return bestLanIPv4(addresses); }

export function resolvePairingHost(explicitHost, exec = execSync) { if (!explicitHost) return { host: lanIPv4(), tailscale: false }; if (explicitHost !== "tailscale") return { host: explicitHost, tailscale: false }; let output; try { output = exec("tailscale ip -4", { encoding: "utf8" }); } catch { throw new Error("could not resolve Tailscale IPv4"); } const ip = String(output).split(/\s+/).find((t) => /^\d+\.\d+\.\d+\.\d+$/.test(t)); if (!ip) throw new Error("could not resolve Tailscale IPv4"); return { host: ip, tailscale: true }; }

export function parseLinkOptions(args, env = process.env) { const command = args[0] ?? "link"; if (command !== "link") throw new Error("usage: iyscodemovil link [--runtime opencode|openisy|crush|codex|claude-code|gemini] [--port 4096] [--directory PATH] [--host LAN|tailscale|IP]"); const values = new Map(); const valid = new Set(["--runtime", "--port", "--directory", "--host"]); for (let i = 1; i < args.length; i += 2) { const name = args[i]; const value = args[i + 1]; if (!valid.has(name)) throw new Error(`unknown option: ${name}`); if (!value || value.startsWith("--")) throw new Error(`missing value for ${name}`); values.set(name, value); } const runtime = values.get("--runtime") ?? "opencode"; if (!RUNTIMES[runtime]) throw new Error(`unsupported runtime: ${runtime}. Available: ${Object.keys(RUNTIMES).join(", ")}`); const rt = RUNTIMES[runtime]; if (rt.notImplemented) throw new Error(rt.notImplemented); if (!rt.check()) throw new Error(`${rt.label} not available. Make sure it's installed and in PATH.`); const port = Number(values.get("--port") ?? "4096"); if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error(`invalid port: ${port}`); return { runtime, rt, port, directory: path.resolve(values.get("--directory") ?? process.cwd()), host: values.get("--host"), }; }

export function runtimeCommand(options, env = process.env) { const rt = RUNTIMES[options.runtime]; return { executable: rt.executable, args: rt.args(options.port, options.directory), cwd: rt.cwd(options.directory), shell: rt.shell, env: rt.env(env, "iyscode", ""), }; }

export function childEnvironment(env, username, password, runtimeEnv = {}) { return { ...env, ...runtimeEnv, OPENCODE_SERVER_USERNAME: username, OPENCODE_SERVER_PASSWORD: password }; }

export function main(args = process.argv.slice(2), env = process.env) { let options, runtime; try { options = parseLinkOptions(args, env); runtime = runtimeCommand(options, env); } catch (error) { console.error(error.message); return 2; } const { host, tailscale } = resolvePairingHost(options.host); const lanReachable = tailscale || isPrivateRoutableIPv4(host); const username = "iyscode"; const password = randomBytes(24).toString("base64url"); runtime.env = childEnvironment(env, username, password, RUNTIMES[options.runtime]?.env(env, username, password) ?? {}); const query = new URLSearchParams({ host, port: String(options.port), username, password, directory: options.directory }); const pairing = `iyscodemovil://pair?${query.toString()}`; console.log(""); console.log("iyscode native / desktop link"); console.log("────────────────────────────────────────"); console.log(`runtime   ${RUNTIMES[options.runtime].label}`); console.log(`project   ${options.directory}`); console.log(`server    http://${host}:${options.port}${tailscale ? "  (via Tailscale)" : ""}`); if (!lanReachable) { console.log(""); console.log("WARNING: no private-routable IPv4 (RFC1918) was found."); console.log("Connect both devices to the same Wi-Fi/LAN and retry."); } console.log(""); console.log("paste this into the iPhone app:"); console.log(""); console.log(pairing); console.log(""); console.log("Keep this terminal open. Ctrl+C stops the link."); console.log("────────────────────────────────────────"); console.log(""); const child = spawn(runtime.executable, runtime.args, { cwd: runtime.cwd, env: runtime.env, stdio: "inherit", shell: runtime.shell }); child.on("error", (error) => { console.error(`failed to start ${RUNTIMES[options.runtime].label}: ${error.message}`); process.exitCode = 1; }); child.on("exit", (code, signal) => { if (signal && process.platform !== "win32") process.kill(process.pid, signal); else process.exitCode = code ?? 0; }); for (const signal of ["SIGINT", "SIGTERM"]) { process.on(signal, () => child.kill(signal)); } return child; } if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) { const result = main(); if (typeof result === "number") process.exitCode = result; }
