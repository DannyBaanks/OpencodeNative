# OpencodeNative

> OpenCode TUI compatibility harness for iOS — documents exactly why the real
> OpenCode TUI cannot run on iOS, and provides a native Swift agent runtime as
> an alternative.

[![iOS Build](https://github.com/DannyBaanks/OpencodeNative/actions/workflows/ios-build.yml/badge.svg)](https://github.com/DannyBaanks/OpencodeNative/actions/workflows/ios-build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-iOS%2016.0+-lightgrey.svg)](https://developer.apple.com/ios/)
[![Swift](https://img.shields.io/badge/Swift-5.0-orange.svg)](https://swift.org)

---

## What is this?

This project answers a single question: **can the real OpenCode TUI run on iOS?**

The answer is **no**. This repo documents *exactly why* with evidence from the
actual OpenCode repository, and provides a native Swift agent runtime that
demonstrates the subset of capabilities iOS *does* support.

### Attribution

OpenCode is &copy; anomalyco and contributors, licensed MIT.
This project is **not affiliated** with OpenCode. The name is used solely to
describe the compatibility target. See [`docs/OPENCODE_COMPAT.md`](docs/OPENCODE_COMPAT.md#10-atribución) for full attribution.

---

## Verdict

| | |
|---|---|
| **OpenCode TUI compat** | `BLOCKED` — PTY/TTY, spawn/exec, Bun runtime absent on iOS |
| **Native Swift runtime** | Working — agent loop, 8 filesystem tools, persistence, LLM provider |
| **CI tests** | 26 tests passing on iOS Simulator |

**The first hard blocker is PTY/TTY** — OpenCode's TUI renderer (`@opentui`)
requires raw terminal access that iOS simply does not expose. This is not a
bug in this project; it is the platform boundary.

---

## Architecture

```
iPhone
  |
OpencodeNative (iOS app)
  |
  +-- Compatibility Harness (Sources/Host/)
  |     OpenCodeRuntimeContract   static OpenCode requirements (with evidence)
  |     IOSCapabilityMatrix       runtime-probed iOS capabilities
  |     CompatibilityReport       reconciles contract vs. matrix
  |     OpenCodeBootAttempt       documents boot failure
  |
  +-- Native Swift Runtime (not OpenCode)
        AgentLoop                 async multi-turn agent
        FileSystemTools           8 sandbox filesystem tools
        ScriptedModelProvider     offline deterministic demo provider
        RemoteModelProvider       OpenAI-compatible LLM API
        IOSWorkspace              sandbox filesystem
        IOSPersistence            JSON + JSONL audit trail
        ConsoleView               TUI-first console UI
```

---

## Quick Start

### Requirements

- macOS with Xcode 15+ (iOS builds require macOS)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

### Build & Run

```bash
brew install xcodegen
xcodegen generate
open OpencodeNative.xcodeproj
# Product → Build (⌘R) → Run on iOS Simulator
```

### Run Tests

```bash
xcodebuild test \
  -scheme OpencodeNative \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

---

## Slash Commands

| Command | Description |
|---|---|
| `/help` | List available commands |
| `/boot` | Run the OpenCode boot attempt (compatibility check) |
| `/matrix` | Show the full capability matrix sheet |
| `/demo` | Run the scripted agent demo (no API key needed) |
| `/provider scripted` | Switch to offline demo provider |
| `/provider remote` | Switch to remote LLM provider |
| `/clear` | Clear the console transcript |

---

## Project Structure

```
App/
  OpencodeNativeApp.swift              @main entry point

Sources/
  Host/                                Compatibility harness
    OpenCodeRuntimeContract.swift      Static OpenCode requirements + evidence
    IOSCapabilityMatrix.swift          Runtime-probed iOS capabilities
    CompatibilityReport.swift          Contract vs. matrix reconciliation
    OpenCodeBootAttempt.swift          Boot attempt transcript
  Agent/
    AgentLoop.swift                    Async multi-turn agent runtime
  Model/
    ModelProvider.swift                Remote LLM provider (OpenAI-compat)
    ScriptedModelProvider.swift        Offline deterministic provider
  Workspace/
    Workspace.swift                    iOS sandbox filesystem
  Persistence/
    Persistence.swift                  JSON + JSONL audit trail
  Tools/
    FileSystemTools.swift              8 filesystem tools
    GlobMatcher.swift                  Pure Swift glob matcher
  UI/
    SessionViewModel.swift             Transcript + commands + agent
    ConsoleView.swift                  TUI-first console view

Tests/
  GlobMatcherTests.swift               Glob pattern matching
  HostTests.swift                      Capability matrix + compatibility report
  CoreEndToEndTests.swift              Workspace + persistence + tools + agent E2E

docs/
  OPENCODE_COMPAT.md                   Full compatibility report with evidence
  IOS_LIMITATIONS.md                   iOS capability documentation
  USAGE.md                             Demo instructions + verification
```

---

## CI/CD

The GitHub Actions workflow (`.github/workflows/ios-build.yml`) runs on every push:

| Job | Description |
|---|---|
| **build** | Builds unsigned IPA for iOS device |
| **test** | Runs all unit tests on iOS Simulator |
| **capability-report** | Generates capability matrix artifact |
| **sign** | *(optional)* Signs IPA with iloader — requires `ENABLE_ILOADER_SIGN=true` var + `APPLE_ID`/`TEAM_ID` secrets |

---

## Documentation

| Document | Description |
|---|---|
| [`docs/OPENCODE_COMPAT.md`](docs/OPENCODE_COMPAT.md) | Full compatibility report with evidence from OpenCode repository |
| [`docs/IOS_LIMITATIONS.md`](docs/IOS_LIMITATIONS.md) | Honest iOS capability documentation |
| [`docs/USAGE.md`](docs/USAGE.md) | Demo instructions, slash commands, verification without Xcode |
| [`EXPERIMENT_REPORT.md`](EXPERIMENT_REPORT.md) | Final experiment report |

---

## License

This project is licensed under the MIT License — see [`LICENSE`](LICENSE) for details.

OpenCode (`anomalyco/opencode`) is referenced under its MIT license.
This project is not affiliated with or endorsed by the OpenCode team.
