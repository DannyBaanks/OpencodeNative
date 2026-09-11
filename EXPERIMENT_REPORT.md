# Experiment Report: OpenCode TUI on iOS

**Date:** 2026-08-20
**Author:** OpencodeNative Contributors
**Status:** Complete

---

## Objective

Can the **real OpenCode TUI** (the distributed binary, not a reimplementation)
run inside a native iOS runtime via a compatibility harness, so that OpenCode
operates on an iOS environment and discovers it is running on iOS?

**Evidence before narrative.** No claim is made without evidence from the actual
OpenCode repository or documented iOS platform facts.

---

## Method

1. **Inspect** the OpenCode repository (`anomalyco/opencode@dev`) to extract
   the static runtime contract: what the TUI binary requires from its host.
2. **Probe** iOS capabilities at runtime to determine what the platform actually
   exposes.
3. **Reconcile** contract vs. platform to produce a per-capability verdict.
4. **Attempt boot** and document the result.

---

## Findings

### OpenCode TUI Runtime Contract

Extracted from `package.json`, `install` script, and dependency declarations:

| Requirement | Source |
|---|---|
| Native binary for host ABI | `install` script (combo selector) |
| Bun 1.3.x runtime | `package.json` `packageManager` |
| PTY/TTY (raw terminal) | `@lydell/node-pty`, `@opentui/*` |
| spawn/exec | `cross-spawn` |
| node:fs + watch + glob | `@effect/platform-node`, `@parcel/watcher` |
| SQLite (Bun variant) | `@effect/sql-sqlite-bun` |
| tree-sitter native | `tree-sitter-bash`, `tree-sitter-powershell` |
| TLS + WebSocket + mDNS | `ws`, `bonjour-service` |
| POSIX environment | `install` reads `$SHELL`, `$HOME`, edits `.zshrc` |

### iOS Platform Capabilities

| Capability | iOS Status |
|---|---|
| PTY/TTY | **Impossible** — no public API |
| spawn/exec | **Impossible** — `Process`/`NSTask` absent |
| Bun runtime | **Does not exist** for iOS |
| OpenCode binary for iOS | **Does not exist** — `install` rejects `ios-*` |
| Filesystem (sandbox) | **Available** — `FileManager` in App Support/Documents/tmp |
| SQLite | **Available** — system SQLite via C API |
| TLS + WebSocket | **Available** — `URLSession` + `URLSessionWebSocketTask` |
| LLM API remote | **Available** — `URLSession` async/await |

### Verdict

**BLOCKED** — The first hard blocker by evaluation order is **nativeExecutable** (no iOS binary distributed). The first fundamental runtime capability blocker (assuming an iOS build existed) is **PTY/TTY**.

OpenCode's TUI renderer (`@opentui`) requires raw terminal access that iOS does not expose. Without PTY, the TUI cannot initialize its screen. This is not a bug in the harness; it is the platform boundary.

**Second hard blocker:** spawn/exec. The `bash` tool (OpenCode's default agent tool) requires `cross-spawn` → `Process()`, which does not exist on iOS.

**Third hard blocker:** Bun runtime. OpenCode requires Bun 1.3.x which has no iOS target.

No OpenCode binary exists for iOS. Even if one did, PTY/TTY, spawn/exec, and Bun runtime would still prevent it from running.

---

## What Was Built

Since the real TUI cannot run, the experiment provides:

### Compatibility Harness (`Sources/Host/`)

Documents exactly *why* OpenCode cannot run on iOS:

- `OpenCodeRuntimeContract` — static contract with evidence citations
- `IOSCapabilityMatrix` — runtime-probed iOS capabilities
- `CompatibilityReport` — contract vs. matrix reconciliation
- `OpenCodeBootAttempt` — boot attempt transcript (does not simulate what it
  cannot prove)

### Native Swift Runtime (not OpenCode)

Demonstrates what iOS *can* do:

- **AgentLoop** — async multi-turn agent with tool calls
- **8 filesystem tools** — read, write, list, move, delete, create, search, info
- **ScriptedModelProvider** — offline deterministic demo (no API key needed)
- **RemoteModelProvider** — OpenAI-compatible LLM API
- **IOSWorkspace** — sandbox filesystem (App Support/Documents/tmp)
- **IOSPersistence** — JSON conversations + JSONL audit trail
- **SessionAdapter + ActiveSessionView** — native iOS workbench connected to the Swift agent loop or the official OpenCode server (ahora vive en `Sources/Backend/WorkbenchStore.swift`)
- **OpenCodeRemoteClient** — HTTP/SSE client for real remote OpenCode sessions, tools, permissions and abort
- **ConsoleView** — compatibility/debug console with slash commands

### Tests

29 unit tests across 4 test files:

- `GlobMatcherTests` — glob pattern matching (7 tests)
- `HostTests` — capability matrix, compatibility report, boot attempt (5 tests)
- `CoreEndToEndTests` — workspace, persistence, tools, permissions, recursive delete, continuity, agent E2E (14 tests)
- `RemotePairingTests` — desktop pairing URL validation and defaults (3 tests)

GitHub Actions is configured to run the suite on an iOS Simulator after the updated copy is pushed.

---

## Bugs Found and Fixed

During development, the following real bugs were discovered and fixed:

1. **`ModelProvider.parseResponse`** — assigned JSON `String` to
   `ToolCall.arguments` (`[String:String]`). Added `decodeArguments()` helper.

2. **`AgentLoop` tool_call_id** — used new UUID instead of `toolCall.id`,
   breaking multi-turn OpenAI API calls.

3. **JSONL persistence** — `.prettyPrinted` encoder produced multi-line JSON
   in `.jsonl` files. `loadEvents` split by newline and silently failed to
   decode every line. Fixed with separate compact encoder.

4. **Swiftmodule collision** — both app and test targets produced
   `OpencodeNative.swiftmodule` to the same output directory. Fixed by
   creating `OpencodeNativeCore` static framework target.

---

## Post-Experiment Maintenance Addendum (2026-09-11)

Cross-platform hardening pass, verified on Windows with Swift 6.3.3
(`swiftc -swift-version 5 -typecheck` over the full Foundation tier:
**0 errors, 0 warnings**; UI/Backend + tests parse clean; bridge Node
tests 6/6):

5. **`Security` import gate** — `Persistence.swift` and `PairingStore.swift`
   imported `Security` unconditionally without using it (removed);
   `KeychainHelper.swift` now uses `#if canImport(Security)`.

6. **Honest Keychain fallback** — hosts without the `Security` framework
   (Windows/Linux dev machines) get a `KeychainHelper` whose every operation
   throws `KeychainError.unavailable` instead of silently storing secrets
   in memory or on disk. Nothing fakes the Keychain.

7. **`FoundationNetworking` on the remote client** — `OpenCodeRemoteClient`
   now imports it under `#if canImport(...)` (same pattern as
   `ModelProvider`).

8. **SSE stream on Windows** — `URLSession.bytes(for:)` does not exist in
   Windows FoundationNetworking (Swift 6.3.3, probe-verified), so
   `events()` terminates with `OpenCodeRemoteError.unsupportedOnThisHost`
   there. iOS/macOS/Linux keep the real streaming path.

9. **Codable semantics made explicit** — `WorkspaceCapabilities` and
   `ToolParameters` declared `let` properties with inline defaults, which
   the synthesized `Decodable` **silently ignored** (verified with a
   runtime probe: `{"listDirectory": false}` decoded back to `true`).
   Converted to explicit memberwise initializers with default parameters:
   decode now actually honors JSON values; call sites unchanged.

10. **Inference fix** — `providers()` compactMap closure return type
    annotated (`-> ProviderInfo?`); Swift 6.3.3 could not infer it.

11. **Dead code removed** — unused `startTime` (AgentLoop), redundant
    `configToSave` copy, and a no-op Keychain round-trip in
    `loadConfiguration()` whose result was discarded (`Configuration`
    has no `apiKeys` by design: secrets only live in the Keychain).

12. **CI artifact mojibake** — the `capability-report` job heredoc in
    `ios-build.yml` contained U+FFFD replacement characters and broken
    emoji, and its 10-space indentation turned the generated
    `CAPABILITY_MATRIX.md` into a single Markdown code block. Regenerated
    clean UTF-8 with `sed` de-indentation.

13. **Docs mojibake repaired** — `README.md` and this report carried
    double-encoded UTF-8 (`â€”`, `â†'`, `âŒ˜`, `Ã³`) in 40+ places;
    all restored to `—`/`→`/`⌘`/`ó`. Broken anchor link
    `#10-atribuci�n` → `#10-attribution`.

---

## Conclusion

**Partial — Blocked** (criterion B from the experiment brief):

> OpenCode TUI real does not start, and the experiment demonstrates exactly
> which iOS capabilities prevent compatibility.

The experiment successfully maps the compatibility boundary between OpenCode's
runtime requirements and iOS's platform capabilities. The harness documents
this boundary with evidence, and the native runtime demonstrates the subset
of functionality that iOS does support.

---

## Attribution

OpenCode is &copy; anomalyco and contributors, licensed MIT.
This project is not affiliated with OpenCode.
See [`docs/OPENCODE_COMPAT.md`](docs/OPENCODE_COMPAT.md#10-attribution) for full attribution.
