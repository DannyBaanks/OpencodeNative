# GUS Local Qwen Download Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an explicit, verified download of the one approved Qwen GGUF and run GUS locally inside the iOS sandbox without adding authority or sending inference data remotely.

**Architecture:** A fixed model manifest and an app-owned downloader stage the pinned Hugging Face artifact, verify exact size and SHA-256, then atomically install it in private app storage. A native llama.cpp provider consumes only that verified file; the existing scripted and remote providers stay separate. GUS uses one shared role and the app's visible approval flow remains the authority for every modifying tool.

**Tech Stack:** Swift 5, SwiftUI, CryptoKit, URLSession, llama.cpp XCFramework built with Metal from a pinned source commit, XcodeGen, GitHub Actions macOS runners, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-28-gus-local-qwen-download-design.md`

## Global Constraints

- Support only Qwen/Qwen1.5-1.8B-Chat-GGUF Q4_K_M from revision `07800fcba6d5d1df3dfa36e3763374a2c0d9f91b`.
- Require exactly 1,217,752,928 bytes and SHA-256 `702e983c77883426806a2af75d34ab3e462e1b822f9dc23b49e02280c24b2b18` before loading.
- Use llama.cpp commit `842b1880415d6f508f03b789e5ce70194def7bfd`; no app subprocess, shell, or CLI.
- Set app deployment target to iOS 16.4; explain the loss of iOS 16.0–16.3 support in release notes.
- Do not bundle the GGUF in the app, IPA, Git history, or routine Actions artifact.
- Keep scripted demo and remote provider behavior separate; local inference never falls back to a cloud provider.
- Do not add native capabilities, arbitrary model import, arbitrary URLs, broader filesystem grants, or new iOS permissions.
- Use the real visible app approval for every modifying tool; absence, denial, cancellation, mismatch, and stale approvals fail closed.
- Preserve model attribution and license; never use Qwen outputs to improve another LLM.
- Do not push. CI and iPhone validation remain pending until the user authorizes a branch workflow/install path.

## Review Focus

- Truncated, oversized, wrong-digest, or interrupted model downloads must never become loadable; tests cover invalid size/hash and cancellation.
- Redirects outside the exact reviewed Hugging Face storage-host allowlist must fail; tests cover an unapproved redirect.
- Model deletion, app restart, and an incomplete staging file must not produce a false **Ready** state; tests cover manifest state recovery and removal.
- A local runtime failure must not send the conversation to an API provider; tests assert the selected provider remains local after errors.
- Qwen 1.5's chat template/tool-call output must be characterized before GUS local is allowed to request native tools; unsupported or malformed calls are treated as assistant text or rejected, never executed.
- Prompt injection from files and attempts to write/delete must not bypass app approvals; tests verify deny/no mutation and missing-approval fail-closed behavior.

---

### Task 1: Shared GUS role and real approvals in every native agent route

**Files:**
- Create: `Sources/Agent/GUSMobileRole.swift`
- Modify: `Sources/Backend/NativeSwiftBackend.swift`
- Modify: `Sources/UI/SessionViewModel.swift`
- Modify: `Sources/UI/ConsoleView.swift`
- Test: `Tests/GUSMobileRoleTests.swift`
- Test: `Tests/SessionApprovalTests.swift`

**Interfaces:**
- `GUSMobileRole.mobile.systemPrompt: String` is the sole role prompt used by both native routes.
- `SessionViewModel.pendingPermission: PermissionRequest?` exposes one active destructive-tool request to `ConsoleView`.
- `SessionViewModel.respondToPermission(requestID:decision:)` resolves only the matching outstanding request; mismatch/absence resolves as deny.

- [ ] **Step 1: Add failing role and approval tests.** Verify both routes provide the same GUS role, no prompt grants new tools, missing handlers deny, and an unapproved write/delete never mutates the temporary workspace.
- [ ] **Step 2: Run the focused iOS XCTest scheme and confirm those assertions fail against current code.**
- [ ] **Step 3: Add the shared role and connect both native loops to it.** Keep role text advisory; do not modify `NativeCapabilityCatalog` or add tool definitions.
- [ ] **Step 4: Replace `SessionViewModel`'s automatic `.allowOnce` with a pending request.** Add explicit Approve once / Deny controls to `ConsoleView`; tie response to request ID and deny on cancellation, disconnect, and missing UI.
- [ ] **Step 5: Run `GUSMobileRoleTests` and `SessionApprovalTests`; verify denial leaves the fixture unchanged and approval performs only the requested operation.**

### Task 2: Pinned model manifest and safe download manager

**Files:**
- Create: `Sources/Model/GUSModelManifest.swift`
- Create: `Sources/Model/GUSModelDownloadManager.swift`
- Modify: `Sources/Model/ModelProvider.swift` only if a shared model error/state is required
- Test: `Tests/GUSModelManifestTests.swift`
- Test: `Tests/GUSModelDownloadManagerTests.swift`

**Interfaces:**
- `GUSModelManifest.qwen15Q4KM` contains immutable source URL, revision, exact filename, byte count, SHA-256, license, and attribution.
- `GUSModelDownloadState`: `.notDownloaded`, `.downloading(progress: Double)`, `.verifying`, `.ready(URL)`, `.failed(GUSModelDownloadError)`.
- `@MainActor final class GUSModelDownloadManager: ObservableObject` exposes `@Published private(set) var state`, `startDownload()`, `cancelDownload()`, `deleteModel()`, and `verifyInstalledModel() async`.
- Inject a `GUSModelTransfer` protocol and app-support directory so tests can supply small fixture responses without downloading the 1.22 GB file.

- [ ] **Step 1: Add manifest tests for the exact HF revision, filename, byte count, and digest.** Add downloader tests for valid fixture, wrong digest, wrong size, interruption, cancellation, and unapproved redirect.
- [ ] **Step 2: Run focused XCTest and confirm new cases fail.**
- [ ] **Step 3: Implement a user-started HTTPS transfer with an exact source URL and exact redirect-host allowlist.** Enforce maximum bytes during transfer and write only to an app-private staging file.
- [ ] **Step 4: Implement incremental CryptoKit SHA-256 verification and exact-size validation.** Atomically promote only a verified file; delete the partial/staged file on cancel or failure. Exclude installed model files from device backups.
- [ ] **Step 5: Implement recovery state from disk, explicit deletion, insufficient-space reporting, and retry.** A partial file never reports `.ready`.
- [ ] **Step 6: Run focused XCTest and verify all invalid fixtures are rejected before a model URL is exposed.**

### Task 3: Reproducible native llama.cpp iOS framework and provider

**Files:**
- Create: `scripts/build-llama-xcframework.sh`
- Create: `Sources/Model/LlamaCppInferenceEngine.swift`
- Create: `Sources/Model/GUSLocalModelProvider.swift`
- Modify: `project.yml`
- Modify: `.github/workflows/ios-build.yml`
- Test: `Tests/GUSLocalModelProviderTests.swift`

**Interfaces:**
- `protocol LocalInferenceEngine: Sendable` provides async `load(modelURL:contextTokens:)`, async `generate(messages:options:)`, and async `cancel()`.
- `GUSLocalModelProvider` conforms to `ModelProvider`, has stable ID `gus-local`, declares `localOnly: true`, supports system prompts, and exposes only the fixed model after `GUSModelDownloadManager` verifies it.
- The tool-call parser is pinned to the GGUF's Qwen 1.5 chat template and has no authority; it can only produce a candidate call for the existing capability broker and visible approval gate.
- The framework preparation script checks out exact llama.cpp commit `842b1880415d6f508f03b789e5ce70194def7bfd` and runs the upstream XCFramework build targets for iOS device and simulator with Metal; it never builds or invokes the CLI.

- [ ] **Step 1: Add provider tests using a fake `LocalInferenceEngine`.** Verify local-only capability metadata, system prompt/message conversion, cancellation, and error propagation without remote fallback.
- [ ] **Step 2: Run focused XCTest and confirm tests fail before implementation.**
- [ ] **Step 3: Add parser characterization fixtures for Qwen 1.5's template:** plain text, one valid candidate tool call, malformed JSON, unknown tool, multiple calls, and prompt-injection text that resembles a tool call. If pinned llama.cpp does not parse the format consistently, local GUS starts in guidance-only mode and cannot submit tool calls; do not switch to an unreviewed model/template.
- [ ] **Step 4: Add the pinned framework preparation script and XcodeGen framework linkage.** Ensure the framework is generated before `xcodegen generate` in CI and is not committed as an opaque binary.
- [ ] **Step 5: Add the narrow Swift/C bridge to llama.cpp and implement the local inference engine.** Load only a URL returned by the verified model manager; cap the default context at 2K and allow 4K only as an experimental profile.
- [ ] **Step 6: Raise project/app/test deployment targets to iOS 16.4 and document the iOS 16.0–16.3 compatibility change.**
- [ ] **Step 7: Run provider/parser XCTest and macOS CI compile for simulator and generic iOS device; report any framework/compiler failures rather than claiming success.**

### Task 4: Provider selection, model download UI, and license notice

**Files:**
- Modify: `Sources/Model/SandboxModelProviders.swift`
- Modify: `Sources/Backend/WorkbenchStore.swift`
- Modify: `Sources/Backend/NativeSwiftBackend.swift`
- Modify: `Sources/UI/ConnectionView.swift`
- Create: `Sources/UI/GUSModelDownloadView.swift`
- Modify: `project.yml`
- Create: `docs/MODEL_NOTICE.md`
- Test: `Tests/GUSModelSelectionTests.swift`

**Interfaces:**
- `SandboxModelProvider` includes `gus-local` as an explicit local option that requires no API key.
- The download view binds `GUSModelDownloadManager.state`; actions call only `startDownload`, `cancelDownload`, and `deleteModel`.
- `WorkbenchStore.startSandbox(providerID:apiKey:)` selects local GUS without loading or sending provider API keys; selecting remote providers follows existing behavior.

- [ ] **Step 1: Add selection tests for absent, downloading, verified, deleted, and failed model states.** Assert choosing GUS local never constructs `RemoteModelProvider` and never silently selects a cloud model.
- [ ] **Step 2: Run focused XCTest and confirm selection tests fail.**
- [ ] **Step 3: Add the explicit GUS local option and route it to the local provider without changing existing provider IDs or credentials.**
- [ ] **Step 4: Add a download screen showing model, Q4_K_M, exact size, pinned commit/source link, license, SHA-256, progress, cancel/retry/delete, and storage/error states.** No automatic download on app launch.
- [ ] **Step 5: Add the required license text and Notice attribution in app/repository distribution metadata.** Clearly identify Qwen model ownership, HF repository, pinned GGUF uploader, and non-commercial license.
- [ ] **Step 6: Run selection tests and verify remote provider flows remain unchanged.**

### Task 5: CI, IPA artifact, and model-free packaging checks

**Files:**
- Modify: `.github/workflows/ios-build.yml`
- Modify: `README.md`
- Modify: `docs/USAGE.md`
- Test: `Tests/GUSModelDownloadManagerTests.swift`

- [ ] **Step 1: Add CI validation that the pinned manifest values match the approved revision/size/hash and that no `.gguf` is staged in the app bundle.**
- [ ] **Step 2: Add CI steps to build llama.cpp XCFramework from the pinned source before XcodeGen, run unit tests, build the unsigned IPA, and report IPA size.** Do not fetch Qwen weights in CI.
- [ ] **Step 3: Run the workflow on an authorized feature branch.** Verify the workflow log, test result, framework source commit, unsigned IPA artifact, and absence of GGUF data in the IPA.
- [ ] **Step 4: Document local GUS setup, the explicit on-device download, source/license, storage requirement, and the fact that prompts remain on-device in local mode.**

### Task 6: Physical iPhone 12 evaluation

**Files:**
- Create: `docs/GUS_IPHONE12_EVALUATION.md`
- Evidence: CI run URL/log, IPA hash/size, app version, iPhone model/iOS, captured memory and latency observations

- [ ] **Step 1: Install the authorized development-signed build on iPhone 12/iOS 18.7.8.** The current workflow creates an unsigned IPA; use only the user's authorized signing/install route.
- [ ] **Step 2: Verify first install has no model and performs no model request until the user taps Download.** Record displayed source/revision and the exact installed model digest.
- [ ] **Step 3: Run a short 2K local response, cancellation, background/foreground, and memory-pressure checks.** Confirm no remote model traffic during local inference.
- [ ] **Step 4: Run one separate 4K experimental measurement; retain or remove the option based on observed memory/latency.** Do not claim 32K support.
- [ ] **Step 5: Exercise a disposable workspace write and delete: approve one operation and verify its result; deny the next and verify no mutation.** Include a file containing adversarial instructions and confirm it is treated as data.
- [ ] **Step 6: Record every unavailable observation as BLOCKED.** Do not call GUS local supported until physical-device evidence satisfies the spec.

## Execution gate

The plan assumes direct, sequential implementation in the existing isolated
worktree. No push is included. GitHub Actions and device validation are later
gates and require an authorized way to publish/run the branch and install the
development build. The model's ability to produce useful tool calls is an
explicit acceptance criterion; prompt text alone is not evidence of safe
tool-use behavior.
