# Usage

> The app runs the **OpenCode boot attempt** (compatibility check) plus a
> **native Swift agent runtime** (not OpenCode) that operates
> `user → agent → tools → workspace → result` on iOS.

---

## A. Run on Simulator or Device

1. Generate the project and open in Xcode:

   ```bash
   brew install xcodegen
   xcodegen generate
   open OpencodeNative.xcodeproj
   ```

2. Run on iOS Simulator (⌘R). On launch you'll see the boot attempt transcript:

   ```
   opencode-native — compatibility harness v0.2.0
   opencode-boot> probing host: iOS
   opencode-boot> target: OpenCode TUI v1.18.19 (license MIT)
   opencode-boot> generating capability matrix ...
   opencode-boot> [UNSUPPORTED]   PTY + TTY raw mode (render TUI ANSI)
   ...
   opencode-boot> BLOCKED at first hard blocker: PTY + TTY raw mode
   opencode-boot> OpenCode TUI cannot initialize on this host. NOT simulated.
   ```

3. Type `/demo` to run the scripted agent demo (no API key needed):

   ```
   $ /demo
   ```

   Output: list → write `notes.txt` → read → write 2 lines → read → final.

4. Other commands: `/matrix` (capability sheet), `/boot` (re-run boot attempt),
   `/provider scripted|remote` (switch provider), `/clear`, `/help`.

---

## B. Connect to a Remote LLM (Optional)

1. Create `~/Application Support/OpencodeNative/config.json`:

   ```json
   {
     "apiKeys": { "remote": "sk-..." },
     "defaultModelName": "gpt-4o-mini",
     "defaultModelProvider": "remote"
   }
   ```

2. In the app: `/provider remote`, then type your prompt.

Default base URL: `https://api.openai.com/v1`.

---

## C. Run Tests

```bash
# macOS with Xcode
xcodebuild test \
  -scheme OpencodeNative \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

CI runs this automatically on every push.

### Test Suites

| Suite | Coverage |
|---|---|
| `GlobMatcherTests` | Glob patterns (`*`, `?`, `**/`) |
| `CapabilityMatrixTests` | Capability probe on non-iOS host |
| `CompatibilityReportTests` | Entries match OpenCode requirements |
| `OpenCodeBootAttemptTests` | Boot transcript content |
| `WorkspaceTests` | Create, read, list, move, delete, path traversal |
| `PersistenceTests` | Conversation save/load, JSONL events, config |
| `ToolsDefinitionTests` | 8 tools present, write marked destructive |
| `AgentEndToEndTests` | Scripted agent writes `notes.txt` end-to-end |

---

## D. Verify Without Xcode (Windows / Linux)

Syntax and typecheck only (no test execution):

```powershell
# Foundation-only sources (no SwiftUI)
swiftc -swift-version 5 -typecheck `
  Sources/Agent/AgentLoop.swift `
  Sources/Workspace/Workspace.swift `
  Sources/Persistence/Persistence.swift `
  Sources/Model/ModelProvider.swift `
  Sources/Model/ScriptedModelProvider.swift `
  Sources/Tools/GlobMatcher.swift `
  Sources/Tools/FileSystemTools.swift `
  Sources/Host/OpenCodeRuntimeContract.swift `
  Sources/Host/IOSCapabilityMatrix.swift `
  Sources/Host/CompatibilityReport.swift `
  Sources/Host/OpenCodeBootAttempt.swift

# UI files (syntax check)
swiftc -parse Sources/UI/ConsoleView.swift Sources/UI/SessionViewModel.swift

# Test files
swiftc -parse Tests/*.swift
```

No output = OK. XCTest is not available on Windows; use Xcode / iOS Simulator.

---

## E. What Is NOT Simulated

- Fake terminal / PTY — does not exist on iOS, not faked
- Fake shell / Process — does not exist on iOS, not faked
- "OpenCode runs on iOS" — it does not; the boot attempt documents why
- Code signing on Windows — requires macOS (GitHub Actions or local Xcode)
