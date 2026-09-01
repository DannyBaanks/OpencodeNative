import assert from "node:assert/strict";
import { mkdir, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { childEnvironment, parseLinkOptions, runtimeCommand } from "../bin/opencodenative.mjs";

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
