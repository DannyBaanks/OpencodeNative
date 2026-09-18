import assert from "node:assert/strict";
import { mkdir, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { bestLanIPv4, childEnvironment, isPrivateRoutableIPv4, parseLinkOptions, runtimeCommand } from "../bin/opencodenative.mjs";

test("default runtime remains official opencode", () => {
  const options = parseLinkOptions(["link"], {});
  const command = runtimeCommand(options, "win32");
  assert.equal(options.runtime, "opencode");
  assert.equal(command.executable, "opencode");
  assert.deepEqual(command.args, ["serve", "--hostname", "0.0.0.0", "--port", "4096", "--mdns"]);
  assert.equal(command.shell, true);
});

test("OpenISy runtime uses Bun and preserves paths with spaces", async () => {
  const root = path.join(os.tmpdir(), `OpenISy Root ${process.pid}`);
  const entry = path.join(root, "packages", "opencode", "src", "index.ts");
  await mkdir(path.dirname(entry), { recursive: true });
  await writeFile(entry, "");
  try {
    const options = parseLinkOptions([
      "link",
      "--runtime", "openisy",
      "--openisy-root", root,
      "--directory", path.join(root, "Project With Spaces"),
      "--port", "5096",
    ], {});
    const command = runtimeCommand(options, "win32");
    assert.equal(command.executable, "bun");
    assert.equal(command.shell, false);
    assert.equal(command.cwd, path.resolve(root, "Project With Spaces"));
    assert.deepEqual(command.args, [
      "--cwd", path.join(root, "packages", "opencode"), "src/index.ts",
      "serve", "--hostname", "0.0.0.0", "--port", "5096", "--mdns",
    ]);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("OPENISY_ROOT supplies the private OpenISy repository", () => {
  const options = parseLinkOptions(["link", "--runtime", "openisy"], { OPENISY_ROOT: "relative-openisy" });
  assert.equal(options.openisyRoot, path.resolve("relative-openisy"));
});

test("child environment includes ephemeral server credentials", () => {
  const env = childEnvironment({ EXISTING: "kept" }, "opencode", "secret");
  assert.equal(env.EXISTING, "kept");
  assert.equal(env.OPENCODE_SERVER_USERNAME, "opencode");
  assert.equal(env.OPENCODE_SERVER_PASSWORD, "secret");
});

test("invalid command, runtime, port, and incomplete OpenISy config fail explicitly", () => {
  assert.throws(() => parseLinkOptions(["connect"], {}), /usage:/);
  assert.throws(() => parseLinkOptions(["link", "--runtime", "other"], {}), /unsupported runtime/);
  assert.throws(() => parseLinkOptions(["link", "--port", "0"], {}), /invalid port/);
  assert.throws(() => parseLinkOptions(["link", "--runtime", "openisy"], {}), /OpenISy requires/);
  assert.throws(() => parseLinkOptions(["link", "--unknown", "value"], {}), /unknown option/);
});

test("missing OpenISy entrypoint fails before spawning", () => {
  const options = parseLinkOptions(["link", "--runtime", "openisy", "--openisy-root", os.tmpdir()], {});
  assert.throws(() => runtimeCommand(options), /OpenISy entrypoint not found/);
});

test("bestLanIPv4 prefers a private routable address over link-local adapters", () => {
  // Esta maquina: Bluetooth/Wi-Fi extra/Ethernet en 169.254.* antes que el
  // Wi-Fi real 192.168.* — el pairing apuntaria a una IP inalcanzable.
  assert.equal(bestLanIPv4(["169.254.85.244", "192.168.1.102"]), "192.168.1.102");
  assert.equal(bestLanIPv4(["169.254.1.2", "10.0.0.5"]), "10.0.0.5");
  assert.equal(bestLanIPv4(["172.20.1.9", "192.168.0.7"]), "172.20.1.9");
  // Solo link-local: ninguna es alcanzable desde el iPhone; localhost es el
  // fallback honesto y el CLI imprime el WARNING correspondiente.
  assert.equal(bestLanIPv4(["169.254.1.2"]), "127.0.0.1");
  assert.equal(bestLanIPv4([]), "127.0.0.1");
});

test("isPrivateRoutableIPv4 covers RFC1918 and rejects junk", () => {
  assert.equal(isPrivateRoutableIPv4("192.168.1.102"), true);
  assert.equal(isPrivateRoutableIPv4("10.1.2.3"), true);
  assert.equal(isPrivateRoutableIPv4("172.31.255.1"), true);
  assert.equal(isPrivateRoutableIPv4("172.15.0.1"), false);
  assert.equal(isPrivateRoutableIPv4("169.254.1.2"), false);
  assert.equal(isPrivateRoutableIPv4("8.8.8.8"), false);
  assert.equal(isPrivateRoutableIPv4("nope"), false);
});
