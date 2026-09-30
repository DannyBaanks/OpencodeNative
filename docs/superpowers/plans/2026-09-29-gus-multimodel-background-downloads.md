# GUS Multi-Model and Background Downloads Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users download and retain three pinned GUS models, choose one verified model at a time, and keep an initiated download alive while iOS suspends the app or the screen is locked.

**Architecture:** Add a fixed three-entry manifest catalog and a persistent background `URLSession` service that stages, hashes, and atomically installs artifacts. The app delegate restores URLSession events; the UI and local provider use the selected verified manifest. All models receive the same `GUSMobileRole.mobile.systemPrompt` and retain the current no-tools, local-only boundary.

**Tech Stack:** Swift 5, SwiftUI, UIKit app lifecycle callback, Foundation background URLSession, CryptoKit, XCTest, Python manifest verifier, GitHub Actions/XcodeGen.

**Spec:** `docs/superpowers/specs/2026-09-29-gus-multimodel-background-download-design.md`

## Global Constraints

- Support only the three manifest entries and exact pinned revisions, filenames, byte counts, SHA-256 digests, licenses, and attribution in the spec.
- Do not include GGUF files in Git, the app bundle, IPA, or routine CI artifacts.
- Downloads start only after an explicit user action; no arbitrary model URL or GGUF import.
- Only a size- and SHA-256-verified model can be selected or loaded; load one model at a time.
- All three models use the same `GUSMobileRole.mobile.systemPrompt`; preserve `toolCalls == false`, 2K default context, local-only inference, and no cloud fallback.
- Background URLSession supports suspension/system termination callbacks, not a user force-quit guarantee. UI must disclose that limitation and show recovery state.
- No new iOS permissions, filesystem grants, tools, or product-code authority.

## Review Focus

- Unknown model IDs and changed manifest URLs must be rejected; manifest tests and the Python verifier pin the full catalog.
- A wrong-sized or wrong-digest model must never become selectable; manager fixture tests cover both and interrupted-stage recovery.
- A redirect to an unapproved host or non-200 response must fail closed; transfer tests cover redirect/response checks.
- Re-launch with a live task must restore model association and progress; manager tests cover task reconciliation and orphaned stages.
- Switching/deleting models must not load multiple model weights or silently fall back; selection/provider tests cover missing, invalid, and active-model changes.

---

### Task 1: Pin and verify the approved model catalog

**Files:**
- Modify: `Sources/Model/GUSModelManifest.swift`
- Modify: `scripts/verify-gus-model-manifest.py`
- Modify: `Tests/GUSModelManifestTests.swift`
- Modify: `docs/MODEL_NOTICE.md`

**Interfaces:**
- `GUSModelManifest` gains stable `id`, repository/model identity, and license URL fields while preserving its fixed artifact metadata.
- `GUSModelManifest.all: [GUSModelManifest]` returns the three spec entries; lookup by ID returns nil for unknown IDs.

- [x] Add assertions for all three exact IDs, source revisions/URLs, filenames, byte counts, SHA-256, licenses, and attribution; assert unknown IDs are absent.
- [x] Update the Python verifier to compare all three entries and fail if GGUF weights appear in tracked/app-bundled files.
- [x] Confirm the old implementation lacks the catalog API (Swift execution blocked locally; CI must verify compile/test) and that the verifier fails on missing pinned metadata, revision, or attribution.
- [x] Implement the catalog and update model notice with Qwen and HuggingFaceTB/mfuntowicz provenance.
- [x] Run Python manifest verifier (PASS); Swift XCTest BLOCKED locally because this host has no Xcode/Swift, queued for macOS CI and `python3 scripts/verify-gus-model-manifest.py`; require both to pass.

### Task 2: Implement persistent background transfer and verified installation

**Files:**
- Modify: `Sources/Model/GUSModelDownloadManager.swift`
- Modify: `Tests/GUSModelDownloadManagerTests.swift`

**Interfaces:**
- `GUSModelDownloadManager` exposes per-ID states, `startDownload(modelID:)`, `cancelDownload(modelID:)`, `deleteModel(modelID:)`, `selectModel(modelID:)`, and `refresh() async`.
- One stable background session identifier and one active transfer are shared across model IDs; completion promotes only the associated model's staged file.

- [ ] Add fixture tests for valid install, wrong size, wrong digest, HTTP error, untrusted redirect, cancellation, retry, recovery of interrupted stages, and independent deletion.
- [ ] Add a transfer/session seam so tests can simulate task restoration and byte progress without downloading model weights.
- [ ] Replace the ephemeral `AsyncBytes` task with a delegate-backed background `URLSession`; persist only model ID/task bookkeeping and reconcile it using `getAllTasks`.
- [ ] Move each completed temporary download immediately to a model-specific staging path, stream SHA-256 from disk, enforce exact byte count, then atomically promote and exclude from backup.
- [ ] Reverify existing and staged files during refresh; preserve and reverify the legacy Qwen path before adoption; delete invalid stages.
- [ ] Run focused manager XCTest and verify invalid fixtures never expose a ready URL.

### Task 3: Restore background URLSession events through app lifecycle

**Files:**
- Modify: `App/IysCodeMovilApp.swift`
- Modify: `Sources/Model/GUSModelDownloadManager.swift`
- Modify: `Tests/GUSModelDownloadManagerTests.swift`

**Interfaces:**
- The app delegate stores iOS's background-session completion handler and forwards the session identifier to `GUSModelDownloadManager`.
- The manager recreates the stable URLSession and calls the stored completion handler only after delegate-delivered events finish.

- [ ] Add tests for matching/unknown session identifiers, event completion ordering, and restored task-to-model association.
- [ ] Adopt `UIApplicationDelegateAdaptor` and connect `application(_:handleEventsForBackgroundURLSession:completionHandler:)` to the transfer service.
- [ ] Reconstruct progress from task byte counts after relaunch and expose an interrupted/retry state when iOS cancelled a force-quit transfer.
- [ ] Run focused lifecycle/manager tests and ensure the app still initializes without a pending background callback.

### Task 4: Select/load one verified model and share GUS role

**Files:**
- Modify: `Sources/Model/GUSLocalModelProvider.swift`
- Modify: `Sources/Backend/NativeSwiftBackend.swift`
- Modify: `Tests/GUSLocalModelProviderTests.swift`
- Modify: `Tests/GUSModelSelectionTests.swift`
- Modify: `Tests/GUSMobileRoleTests.swift`

**Interfaces:**
- Provider initialization receives the selected `GUSModelManifest` and its verified local URL.
- The same `GUSMobileRole.mobile.systemPrompt` is supplied for every model; selected model identity changes only model file/name, not role, tool boundary, or fallback behavior.

- [ ] Add tests that each manifest maps to its own file and the same role prompt, with tools disabled and no remote fallback.
- [ ] Add selection tests that missing, downloading, corrupt, or deleted models cannot start local inference and do not silently select another model.
- [ ] Route backend loading to the selected verified file and ensure the previous model is unloaded before another model loads.
- [ ] Run provider, selection, and role tests; require explicit selection and verified state.

### Task 5: Add the three-model download and selection UI

**Files:**
- Modify: `Sources/UI/GUSModelDownloadView.swift`
- Modify: existing sandbox/model selection view discovered during implementation
- Modify: `README.md`, `docs/USAGE.md`, `docs/MODEL_NOTICE.md`

**Interfaces:**
- Each card is keyed by manifest ID and renders `Not downloaded`, `Downloading`, `Verifying`, `Ready`, or recoverable error.
- Only a ready model exposes Select; downloads expose progress/cancel/retry; installed models expose individual Delete.

- [ ] Add view-state coverage for all cards, active selection, independent installed models, errors, and deletion confirmation where the current test harness permits it.
- [ ] Render model size, quantization, license/provenance links, SHA-256, download status/progress, and per-model actions.
- [ ] Explain that downloads continue while iOS suspends the app or the device is locked, but force-quit cancels them and they may need retry.
- [ ] Update usage and README setup to explain explicit download, storage needs, shared prompt, attribution, and local-only behavior.
- [ ] Run the relevant UI/model tests and check accessibility labels for model actions.

### Task 6: Verify and deliver through GitHub Actions

**Files:**
- Modify: `.github/workflows/ios-build.yml` only if needed for the new verifier/tests

- [ ] Run all focused XCTest targets and the manifest verifier locally; do not claim physical-device background behavior from simulator tests.
- [ ] Confirm no GGUF is included in the IPA or checked into Git and that the build workflow does not download GGUF artifacts.
- [ ] Commit coherent implementation changes, push the feature branch, and run the iOS GitHub Actions workflow on that branch.
- [ ] Inspect the workflow result and fix any compile/test failures until CI is green; report the run URL and remaining iPhone-only checks.

## Execution Gate

Implementation method is direct execution in the existing isolated worktree. CI on the feature branch is authorized by the user's request. Physical iPhone validation remains a separate follow-up because this environment cannot observe lock-screen or force-quit behavior on Danny's device.
