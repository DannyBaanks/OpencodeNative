# IysCode Movil

> **IysCode Movil** — OpenCode TUI compatibility harness for iOS, rebranded and made backend-agnostic.

**The question:** *can the real IysCode TUI run on iOS?*
**The answer:** **no** — PTY/TTY, spawn/exec, Bun runtime are absent on iOS.
**This repo** documents exactly why with evidence, and provides a native Swift agent runtime as an alternative.

---

## Architecture

```
IysCodeMovil (iOS app)
├── NativeSwiftBackend        # Sandbox local, 8 filesystem tools, Grok/OpenAI via Keychain
├── RemoteBackend (protocol)  # Common interface for all remote backends
│   ├── OpenCodeRemoteBackend # OpenCode / OpenISy (implemented)
│   ├── CrushRemoteBackend    # Stub (charmbracelet/crush)
│   ├── CodexRemoteBackend    # Stub (openai/codex)
│   ├── ClaudeCodeRemoteBackend # Stub (anthropic/claude-code)
│   └── GeminiRemoteBackend   # Stub (google/gemini)
├── WorkbenchBackendFactory   # Creates backend from pairing URL
└── WorkbenchStore            # ObservableObject, subscribes to backend events
```

**Bridge CLI (Node):** `iyscodemovil link --runtime opencode|openisy|crush|codex|claude-code|gemini`

---

## Runtime Modes

| Mode | Backend | Use Case |
|------|---------|----------|
| **Native** | `NativeSwiftBackend` | Offline demo, Grok 4.7 via SpaceXAI key, 8 fs tools |
| **Remote OpenCode** | `OpenCodeRemoteBackend` | Pair with `opencode serve` on desktop |
| **Remote OpenISy** | `OpenCodeRemoteBackend` | Pair with OpenISy server (Bun) |
| **Remote Crush** | `CrushRemoteBackend` | *Stub — not yet implemented* |
| **Remote Codex** | `CodexRemoteBackend` | *Stub — not yet implemented* |
| **Remote Claude Code** | `ClaudeCodeRemoteBackend` | *Stub — not yet implemented* |
| **Remote Gemini** | `GeminiRemoteBackend` | *Stub — not yet implemented* |

---

## Quick Start

### iOS App (XcodeGen)
```bash
# Requires: xcodegen, xcodebuild
xcodegen
open IysCodeMovil.xcodeproj
# Build & run on device/simulator (iOS 16+)
```

### Desktop Link (Bridge CLI)
```bash
# Install
npm i -g github:DannyBaanks/IysCodeMovil#main

# Link OpenCode (default)
iyscodemovil link --runtime opencode --port 4096
# -> prints iyscodemovil://pair?... -> paste into iOS app

# Link OpenISy
iyscodemovil link --runtime openisy --openisy-root ~/OpenISy --port 4096
```

### Pairing URL Format
```
iyscodemovil://pair?scheme=http&host=192.168.1.50&port=4096&username=iyscode&password=...&directory=/path/to/project
```

---

## Compatibility Report (iOS 16+)

| Capability | Verdict | Evidence |
|------------|---------|----------|
| PTY/TTY | BLOCKED | iOS denies `posix_openpt` |
| Process spawn/exec | BLOCKED | No `fork`/`exec` in sandbox |
| Bun/Node runtime | BLOCKED | No JIT, no V8 |
| Raw terminal (OpenTUI) | BLOCKED | No `ioctl(TIOCSTI)` |
| Filesystem (sandbox) | WORKS | 8 tools via `IOSWorkspace` |
| Keychain secrets | WORKS | `IOSPersistence` + Keychain |
| WebSocket/SSE | WORKS | `URLSession.bytes(for:)` |
| MDNS/Bonjour | WORKS | `NWBrowser` |
| Background execution | LIMITED | 30s background task only |

**Full report:** [`docs/OPENCODE_COMPAT.md`](docs/OPENCODE_COMPAT.md)

---

## Extending with New Backends

1. **Create backend** in `Sources/Backend/Remote/YourBackend.swift` conforming to `RemoteBackend`
2. **Add to factory** in `WorkbenchBackendFactory.makeBackend(from:)`
3. **Add runtime** in `Bridge/bin/iyscodemovil.mjs` `RUNTIMES` object
4. **Test** with `iyscodemovil link --runtime your-backend`

```swift
// Minimal stub template
@MainActor
public final class YourRemoteBackend: WorkbenchBackend, RemoteBackend {
    public let remoteType: RemoteBackendType = .yourType
    // ... implement RemoteBackend protocol
}
```

---

## License

MIT — see [`LICENSE`](LICENSE).

IysCode is (c) Danny Baanks. Not affiliated with OpenCode, Crush, Codex, Anthropic, Google, or OpenAI.
