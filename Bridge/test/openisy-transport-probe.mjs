import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdir, rm } from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import process from "node:process";

const openisyRoot = process.env.OPENISY_ROOT;
if (!openisyRoot) throw new Error("OPENISY_ROOT is required");

const project = path.resolve(process.env.OPENCODENATIVE_PROJECT ?? path.join(os.tmpdir(), "opencodenative-openisy-probe"));
await mkdir(project, { recursive: true });
const port = await freePort();
const bridge = spawn(process.execPath, [
  path.resolve("Bridge/bin/opencodenative.mjs"),
  "link",
  "--runtime", "openisy",
  "--openisy-root", openisyRoot,
  "--directory", project,
  "--port", String(port),
], { cwd: process.cwd(), env: process.env, stdio: ["ignore", "pipe", "pipe"] });

let stdout = "";
let stderr = "";
bridge.stdout.on("data", (chunk) => { stdout += chunk; });
bridge.stderr.on("data", (chunk) => { stderr += chunk; });

let sessionID;
let sseAbort;
try {
  const pairing = await waitFor(() => stdout.match(/opencodenative:\/\/pair\?[^\s]+/)?.[0], 60_000, "pairing URL");
  const pairingURL = new URL(pairing);
  const username = pairingURL.searchParams.get("username");
  const password = pairingURL.searchParams.get("password");
  assert.equal(pairingURL.searchParams.get("directory"), project);
  const base = `http://127.0.0.1:${port}`;
  const headers = {
    Accept: "application/json",
    Authorization: `Basic ${Buffer.from(`${username}:${password}`).toString("base64")}`,
    "Content-Type": "application/json",
    "x-opencode-directory": project,
  };

  const health = await waitFor(async () => {
    try {
      const response = await fetch(`${base}/global/health`, { headers });
      if (!response.ok) return undefined;
      return response.json();
    } catch {
      return undefined;
    }
  }, 60_000, "OpenISy health");
  assert.equal(health.healthy, true);

  sseAbort = new AbortController();
  const events = [];
  const sseResponse = await fetch(`${base}/event`, { headers, signal: sseAbort.signal });
  assert.equal(sseResponse.status, 200);
  assert.match(sseResponse.headers.get("content-type") ?? "", /^text\/event-stream/);
  const consumeSse = collectSse(sseResponse, events).catch((error) => {
    if (error.name !== "AbortError") throw error;
  });
  await waitFor(() => events.some((event) => event.type === "server.connected"), 10_000, "SSE server.connected");

  const before = await request(`${base}/session`, { headers });
  assert.equal(Array.isArray(before), true);
  const created = await request(`${base}/session`, {
    method: "POST",
    headers,
    body: JSON.stringify({ title: "OpencodeNative transport probe" }),
  });
  sessionID = created.id;
  assert.match(sessionID, /^ses_/);

  const listed = await request(`${base}/session`, { headers });
  assert.equal(listed.some((session) => session.id === sessionID), true);
  await waitFor(
    () => events.some((event) => JSON.stringify(event).includes(sessionID)),
    10_000,
    "session-correlated SSE event",
  );

  const promptResponse = await fetch(`${base}/session/${sessionID}/prompt_async`, {
    method: "POST",
    headers,
    body: JSON.stringify({ parts: [{ type: "text", text: "Reply only with OPENISY_NATIVE_TRANSPORT_OK." }] }),
  });
  assert.equal(promptResponse.status, 204);
  await waitFor(async () => {
    const messages = await request(`${base}/session/${sessionID}/message`, { headers });
    return messages.some((message) => message.info?.sessionID === sessionID && message.info?.role === "user");
  }, 15_000, "persisted prompt message");
  await new Promise((resolve) => setTimeout(resolve, 1_000));
  const terminalEvent = events.find((event) =>
    (event.type === "session.idle" || event.type === "session.error") && event.properties?.sessionID === sessionID,
  );
  const messages = await request(`${base}/session/${sessionID}/message`, { headers });
  const assistantMessage = messages.find((message) => message.info?.sessionID === sessionID && message.info?.role === "assistant");

  const abortResponse = await fetch(`${base}/session/${sessionID}/abort`, { method: "POST", headers });
  assert.equal(abortResponse.status, 200);

  const permissionResponse = await fetch(`${base}/session/${sessionID}/permissions/per_transport_probe`, {
    method: "POST",
    headers,
    body: JSON.stringify({ response: "reject" }),
  });
  assert.equal(permissionResponse.status, 404);

  console.log(JSON.stringify({
    runtime: "OpenISy",
    health,
    session_list: 200,
    session_create: 200,
    session_id: sessionID,
    prompt_async: promptResponse.status,
    prompt_terminal_event: terminalEvent?.type ?? "NOT_DEMONSTRATED",
    assistant_record_created: Boolean(assistantMessage),
    assistant_part_count: assistantMessage?.parts?.length ?? 0,
    event_stream: sseResponse.status,
    session_event_correlated: true,
    abort: abortResponse.status,
    permission_endpoint: permissionResponse.status,
    permission_runtime_request: "NOT_DEMONSTRATED",
    event_types: [...new Set(events.map((event) => event.type))],
  }, null, 2));

  await fetch(`${base}/session/${sessionID}`, { method: "DELETE", headers });
  sseAbort.abort();
  await Promise.race([consumeSse, new Promise((resolve) => setTimeout(resolve, 3_000))]);
} finally {
  sseAbort?.abort();
  if (bridge.exitCode === null) {
    const exited = new Promise((resolve) => bridge.once("exit", resolve));
    bridge.kill("SIGTERM");
    await Promise.race([
      exited,
      new Promise((_, reject) => setTimeout(() => reject(new Error(`bridge did not stop; stderr=${stderr.slice(-2000)}`)), 15_000)),
    ]);
  }
  const closed = await waitFor(() => portClosed(port), 10_000, "OpenISy listener shutdown");
  assert.equal(closed, true, `OpenISy listener ${port} remained open`);
  if (!process.env.OPENCODENATIVE_PROJECT) await rm(project, { recursive: true, force: true });
}

async function request(url, init) {
  const response = await fetch(url, init);
  const body = await response.text();
  assert.equal(response.ok, true, `${response.status} ${url}: ${body}`);
  return body ? JSON.parse(body) : undefined;
}

async function collectSse(response, events) {
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffered = "";
  while (true) {
    const { value, done } = await reader.read();
    if (done) return;
    buffered += decoder.decode(value, { stream: true }).replaceAll("\r\n", "\n");
    let boundary;
    while ((boundary = buffered.indexOf("\n\n")) >= 0) {
      const block = buffered.slice(0, boundary);
      buffered = buffered.slice(boundary + 2);
      const data = block.split("\n").filter((line) => line.startsWith("data:")).map((line) => line.slice(5).trim()).join("\n");
      if (data) events.push(JSON.parse(data));
    }
  }
}

async function waitFor(probe, timeout, label) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const value = await probe();
    if (value) return value;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`timeout waiting for ${label}; exit=${bridge.exitCode}; stdout=${stdout.slice(-2000)}; stderr=${stderr.slice(-2000)}`);
}

async function freePort() {
  const server = net.createServer();
  await new Promise((resolve, reject) => server.once("error", reject).listen(0, "127.0.0.1", resolve));
  const address = server.address();
  await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  return address.port;
}

async function portClosed(port) {
  return new Promise((resolve) => {
    const socket = net.connect({ host: "127.0.0.1", port });
    socket.once("connect", () => { socket.destroy(); resolve(false); });
    socket.once("error", () => resolve(true));
    socket.setTimeout(2_000, () => { socket.destroy(); resolve(true); });
  });
}
