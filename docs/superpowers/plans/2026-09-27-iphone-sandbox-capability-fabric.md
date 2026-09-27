# Native iOS Capability Fabric and Sandbox Relay Implementation Plan

> **For agentic workers:** Follow the execution workflow and verify each task before marking it done.

**Goal:** Evolve the native iPhone sandbox into a typed capability broker while keeping inference on the OpenCode host and all native execution on iPhone.

**Architecture:** Add a shared capability registry/state model, effect-based broker/policy, privacy-safe receipts, and context-scoped native tool adapters. Retain the current local workspace and Keychain. App Intents/Shortcuts are typed seams; the Shortcuts URL launches only a user-configured shortcut. Notifications use UserNotifications after contextual authorization. The host remains inference-only; no host repo or legacy Bridge edits.

**Tech Stack:** Swift 5, SwiftUI, AppIntents (iOS 16+), UserNotifications, Security/Keychain, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-09-27-iphone-sandbox-opencode-provider-relay-design.md`

## Global constraints

- iOS deployment target remains 16.0.
- Never give the model raw UIKit/Foundation/framework authority, provider secrets, or a general capability bypass.
- Maintain separate availability, authorization, model permission, and Apple OS prompt states.
- Only user-selected security-scoped URLs expand Files access. Preserve coordinated IO and approval for writes.
- Do not request sensitive system permissions at launch.
- Do not modify `/home/danny/Development/ISyCo` or legacy Bridge routes.
- Provider OAuth/inference relay is blocked on the host-owned versioned contract; ship no fake-ready UI for missing routes.
- Real device permission witnesses are required for permission claims; simulator evidence is labeled.

## Task 1: Capability model, broker, and receipts

**Files:** `Sources/NativeCapabilities/NativeCapability.swift` (new), `Tests/NativeCapabilityTests.swift` (new).

**Interfaces:** `NativeCapabilityDescriptor`, `NativeCapabilityAvailability`, `NativeAuthorizationState`, `NativeEffectClass`, `NativeCapabilityProposal`, `NativeCapabilityReceipt`, `NativeCapabilityBroker`, `NativeCapabilityPolicy`. Broker accepts an explicit current-state provider and approval decision; it rejects unsupported, unauthorized, unapproved, or fabricated state. Receipt safe metadata is allowlisted and cannot carry arbitrary secret/content fields.

**Steps:**
1. Add tests for discovery != authorization, model approval != OS permission, denied state rejection, external side effects fail closed, and receipt metadata allowlist.
2. Run the focused XCTest target and verify expected failures.
3. Implement the minimal model and broker.
4. Re-run focused and full XCTest suite.

**Expected:** broker decisions are deterministic and no native operation can execute based only on catalog discovery.

## Task 2: Native action and Shortcuts seams

**Files:** `App/NativeAppIntents.swift` (new), `App/IysCodeMovilApp.swift`, `Info.plist`, `Sources/NativeCapabilities/ShortcutRegistry.swift` (new), tests.

**Interfaces:** typed App Intent actions for opening the sandbox/current project and showing the active run only where an existing operation is available. `ShortcutRegistry` stores only user-configured name/opaque local ID references, never enumerates the full Shortcuts collection. `shortcut.run` accepts only an allowlisted reference and launches Apple’s documented URL scheme; it reports that system UI may appear and does not claim shortcut completion/delivery.

**Steps:** write tests for unconfigured/denied shortcut, configured shortcut URI encoding, and no arbitrary URL scheme; run RED; implement; run GREEN; add App Shortcuts; build app.

**Expected:** Shortcuts invocation cannot select an arbitrary shortcut or URL supplied by model text. App Intent actions map to real typed app operations.

## Task 3: Keychain and provider secret boundary

**Files:** `Sources/Persistence/KeychainHelper.swift`, provider settings/model code as needed, `Tests/NativeCapabilityTests.swift`.

**Interfaces:** retain existing provider key load/save/delete for app-owned inference setup. Add `secret.exists/store/replace/delete` only if required by UI or adapter; do not expose plaintext read as an agent tool. Provider API keys stay in Keychain and are attached only to a future authenticated HTTPS inference request over the host contract.

**Steps:** tests assert presence checks reveal no value, deletes are idempotent, and receipts/model-facing output do not contain secret values; implement only required APIs; run suite.

**Expected:** no secret value reaches conversation, receipt, logs, UserDefaults, or host status.

## Task 4: Files picker capability state

**Files:** `Sources/Workspace/Workspace.swift`, `Sources/Backend/WorkbenchStore.swift`, `Sources/UI/ProjectSessionViews.swift`, tests.

**Interfaces:** the existing folder picker and Keychain bookmark are reflected by broker state. Keep the private sandbox as default; folder name is presentation metadata only. External grant operations use the existing security-scoped bookmark, lease, and coordinated reads/writes. Optional file picker additions use `fileImporter` and never accept model-provided URLs.

**Steps:** add tests around state projection and revoked/stale bookmark behavior; implement wiring without broadening scope; run suite and iOS build.

**Expected:** catalog displays granted user-selected folder separately from the always-available private sandbox; model paths remain relative to the authorized workspace.

## Task 5: Notifications capability

**Files:** `Sources/NativeCapabilities/LocalNotificationCapability.swift` (new), UI settings/status view, tests.

**Interfaces:** `notification.schedule/cancel/showLocal` adapter; query current authorization state; request authorization only from a contextual user action; semantic event policy decides whether worker-finished/blocked/approval/reconnect events merit notification. Model supplies bounded title/body proposal only. Approval precedes scheduling where policy requires.

**Steps:** test policy and denied/not-determined/authorized projection; implement adapter behind `canImport(UserNotifications)`; run suite/build; record simulator/device witness limits.

**Expected:** denied permission produces a truthful denied state and no scheduled notification; no prompt on launch.

## Task 6: Capability catalog in Settings and relevant tool projection

**Files:** new `Sources/UI/NativeCapabilitySettingsView.swift`, `Sources/UI/ProjectSessionViews.swift`, AgentLoop/tool wiring if scoped projections are supported, tests.

**Interfaces:** local catalog shows Available, Authorized, Denied, Restricted, Needs setup, Unsupported, and safe detail. The current model turn receives only context-relevant tools; future capability modules must register through the same broker. No complete catalog is sent to every prompt.

**Steps:** test state labels and task-to-tool projection; implement SwiftUI settings link; verify VoiceOver labels and existing theme.

**Expected:** users can distinguish installed framework support from OS grant and app policy permission.

## Task 7: Provider relay and session isolation integration

**Files:** `Sources/Backend/WorkbenchStore.swift`, `Sources/Backend/Remote/OpenCodeRemoteBackend.swift`, `Sources/Remote/MobileHostAPI.swift`, UI composer, tests; mobile repo only.

**Dependencies:** host owner must implement/review the `/v1` provider/auth/inference-stream/cancel contract first. Until then, client must report routes unavailable and preserve the current Bridge. Explicitly bind send/stream/cancel to session/run IDs; local native capability execution remains on phone.

**Steps:** add concurrency regression tests before changing shared run state; coordinate exact request/event schemas against host contract; implement; validate two simultaneous sessions and cancellation routing on a real host.

**Expected:** session A Stop cannot affect B; host has no native capability API and performs inference only.

## Task 8: Verification and rollout

Run the iOS CI build/test workflow, inspect app permissions/plist and secret redaction. Add a directed witness table for App Intents exposure, selected Shortcuts launch/denial, Keychain boundary, Files scope, notification denial, external effect approval, host/native separation, and background/relaunch. Mark every unperformed physical-device case outstanding; do not claim simulator evidence as real-device proof.

## Review focus

- Security boundary: no model-provided URLs, framework authority, or secret reads.
- Native broker does not confuse availability, OS authorization, approval, and execution.
- Files grants are narrow and coordinated; no picker implies entire Files access.
- Notification/shortcut side effects require correct local approval and honest completion semantics.
- iOS 16 availability and target membership for App Intents.
- User-visible Settings labels accurately distinguish state.
- No edits to host/TUI or legacy Bridge.
