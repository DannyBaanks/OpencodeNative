# GUS Smol Auxiliary Experiment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in Dual-Smol experiment where verified SmolLM2 supplies a bounded intent hint and Qwen2.5-0.5B remains the only user-facing responder.

**Architecture:** Add a focused local-model coordinator that owns separate Qwen and Smol providers, validates Smol's fixed JSON intent result, and delegates every actual answer/tool request to Qwen. NativeSwiftBackend owns lifecycle and falls back to its existing selected single model if the auxiliary model cannot load; the UI persists the opt-in setting and surfaces experiment/fallback status.

**Tech Stack:** Swift 5, SwiftUI, llama.cpp bridge, existing `ModelProvider`, `GUSModelDownloadManager`, `WorkbenchEvent`, and `WorkbenchStore`.

**Spec:** `docs/superpowers/specs/2026-09-29-gus-smol-auxiliary-experiment-design.md`

## Global Constraints

- The experiment is off by default and requires the verified Qwen2.5-0.5B and SmolLM2-360M artifacts.
- Qwen is always the user-facing model; Smol may only return JSON with `version: 1` and one fixed intent enum.
- Smol generation is capped at 32 tokens and 96 UTF-8 bytes; reject malformed, unknown, repeated, or oversized output.
- Smol receives only the latest user message and no history, tools, file contents, credentials, or capability catalog.
- Smol cannot invoke tools or affect Swift permission decisions; coordinator invokes models sequentially, never concurrently.
- Auxiliary failure falls back to Qwen with the original prompt; Qwen failure remains an error.
- Do not change the normal selected model or behavior while the experiment is off.
- Do not modify, discard, or stage existing unrelated local changes in `NativeSwiftBackend.swift`, `GUSLocalModelProvider.swift`, `NativeCapabilityToolExecutor.swift`, `FileSystemTools.swift`, `GUSToolPermissions.swift`, `GUSLocalToolCallParser.swift`, or `docs/gus_dual_model/`.
- Do not add or run tests or local builds in this implementation unless the user asks; record that physical-device memory, stability, thermal, and quality validation remains required.

## Review Focus

- Repetitive or malformed Smol JSON must be rejected and Qwen must receive the original prompt. Validate by tracing the strict parser and fallback path; a physical-device example remains required for model-output quality.
- Missing or corrupt verified GGUF must keep the ordinary model usable. Validate the backend load/error branch and existing manifest verification path.
- Cancellation or disabling during an auxiliary inference must cancel and unload Smol without leaving Qwen unusable. Validate lifecycle paths by inspection and later iPhone exercise.
- Tool-bearing Qwen requests must reach only the existing Qwen/executor route; Smol must never receive tool definitions. Validate call graph and provider arguments by inspection.
- iOS memory termination cannot be prevented by the app. Report device measurements as unverified until observed on the user's iPhone.

---

## File Map

- Create `Sources/Model/GUSDualModelCoordinator.swift`: strict intent schema/parser, repetition/size validation, sequential Smol-then-Qwen orchestration, status callback, cancellation, and unload.
- Create `Sources/Model/GUSAuxiliaryModelRunner.swift`: raw, isolated Smol inference using a dedicated `LlamaCppInferenceEngine`, without the normal GUS authority/tool prompt wrapper.
- Create `Sources/Model/GUSDualModelExperimentSettings.swift`: shared UserDefaults key and typed read/write access for the opt-in state.
- Modify `Sources/Backend/NativeSwiftBackend.swift`: construct the experimental pair only when enabled and both verified URLs exist; preserve the existing selected single-model route as fallback; unload both providers on lifecycle end.
- Modify `Sources/Backend/WorkbenchBackend.swift`: add a short auxiliary-model-status event for non-sensitive UI diagnostics.
- Modify `Sources/Backend/WorkbenchStore.swift`: consume that event and expose a reload method used when the user applies the experiment toggle.
- Modify `Sources/UI/GUSModelDownloadView.swift`: add the opt-in control, availability explanation, explicit apply/reload action, and an off switch that reloads/unloads Smol.
- Modify `Sources/UI/ComposerView.swift`: show a small persistent experimental badge while the dual coordinator is active.
- Modify `Sources/UI/ConnectionView.swift` only if required to pass the existing WorkbenchStore action into the model view; do not change unrelated sandbox setup.

## Tasks

### Task 1: Define the experimental coordinator and strict intent protocol

**Files:**
- Create: `Sources/Model/GUSDualModelCoordinator.swift`
- Create: `Sources/Model/GUSAuxiliaryModelRunner.swift`
- Create: `Sources/Model/GUSDualModelExperimentSettings.swift`
- Do not touch: `Sources/Model/GUSLocalModelProvider.swift` (it has pre-existing local edits; compose around it instead).

**Interfaces:**
- `GUSDualModelIntent: String, Codable, Sendable` has exactly `greeting`, `question`, `task`, `ambiguous`, and `other`.
- `GUSDualModelCoordinator: ModelProvider` is initialized with a Qwen `GUSLocalModelProvider`, a `GUSAuxiliaryModelRunner`, and an async status callback.
- `GUSAuxiliaryModelRunner` directly wraps `LlamaCppInferenceEngine`; it must not call `GUSLocalModelProvider.generate` because that path appends the app authority/tool prompt.
- Its auxiliary decoder accepts only a JSON object containing exactly `version` and `intent`, requires `version == 1`, limits UTF-8 output to 96 bytes, rejects duplicate keys/trailing content, and rejects malformed/repeated output.
- Coordinator generation calls the runner with only the last user message; the runner uses temperature `0` and `maxTokens: 32`; then the coordinator calls Qwen sequentially with the original messages plus a clearly labeled untrusted intent hint. Any auxiliary error calls Qwen with the original messages.
- The isolated Smol input is a short fixed classifier instruction plus the latest user message; Smol receives no other conversation messages or authority rules.
- The Qwen hint is appended to the latest user message as clearly labeled untrusted metadata containing only the validated enum. The coordinator delegates the original `tools` unchanged only to Qwen.
- Coordinator identity/capabilities remain compatible with `gus-local` and the Qwen primary so the existing sandbox permission mode and model selection keep working.
- The coordinator's `cancel()` cancels the current auxiliary operation and both engines as needed; `unload()` cancels and unloads both providers.
- `GUSDualModelExperimentSettings.enabledKey` is the one shared UserDefaults key `gus.dualSmolExperimentalEnabled`; its helper reads/writes that Boolean.
- The auxiliary deadline is 20 seconds. On timeout, cancel Smol through its existing engine cancellation path, discard its result, and continue with Qwen's original request.

- [x] Implement the fixed enum, strict decoder, output limits, and rejection reasons in `GUSDualModelCoordinator.swift`.
- [x] Implement sequential orchestration and Qwen-only fallback without passing tool definitions to Smol.
- [x] Implement shared opt-in setting access in `GUSDualModelExperimentSettings.swift`.
- [x] Implement `GUSAuxiliaryModelRunner` using a dedicated `LlamaCppInferenceEngine` and only the fixed classifier instruction plus the latest user message.
- [x] Inspect cancellation and unload paths for both providers and ensure no parallel inference path exists. Static review only; not device-validated.

### Task 2: Integrate model loading and lifecycle in the native backend

**Files:**
- Modify: `Sources/Backend/NativeSwiftBackend.swift`
- Use: `Sources/Model/GUSModelDownloadManager.swift` existing verified `modelURL(id:)` API.

**Interfaces:**
- When the setting is off, preserve existing `selectedManifest` / `selectedModelURL` behavior exactly.
- When on, require verified URLs for IDs `qwen25-05b-q4km` and `smollm2-360m-q4km`; create separate 2K providers and load them sequentially.
- If auxiliary setup fails, release any partially loaded auxiliary engine, restore the normal selected single-model provider, and expose a short fallback status.
- `releaseActiveModel()` handles the coordinator by cancelling/unloading both engines and continues to handle the existing single provider.
- Expose a read-only `isDualSmolActive` state so `WorkbenchStore` can distinguish a successfully loaded pair from a safe fallback without parsing display text.

- [x] Add the experimental branch to `reloadSandboxModel()` without changing the setting-off branch.
- [x] Add pair cleanup to `releaseActiveModel()` and `disconnect()` while preserving existing backend dirty work.
- [x] Confirm a missing model or failed Smol load preserves Qwen/single-model use and never changes `selectedModelID`. Static review only; not device-validated.

### Task 3: Surface experimental and fallback status

**Files:**
- Modify: `Sources/Backend/WorkbenchBackend.swift`
- Modify: `Sources/Backend/WorkbenchStore.swift`
- Modify: `Sources/Backend/NativeSwiftBackend.swift`

**Interfaces:**
- Add `WorkbenchEvent.auxiliaryModelStatus(GUSDualModelStatus)` with only fixed, non-sensitive status cases.
- Coordinator emits status categories only; never include input, output, prompts, or keys.
- `WorkbenchStore` maps the event to a concise system timeline event for the currently active session.

- [x] Add and handle the status event.
- [x] Emit status for accepted hint, rejected/repetitive output, timeout/cancel, and load fallback without persisting raw model text.
- [x] Ensure status events do not alter turn success, Qwen output, or tool approval behavior. Static review only; not device-validated.

### Task 4: Add opt-in UI and apply/off lifecycle

**Files:**
- Modify: `Sources/UI/GUSModelDownloadView.swift`
- Modify: `Sources/Backend/WorkbenchStore.swift`
- Modify: `Sources/UI/ConnectionView.swift` only if dependency injection requires it.
- Modify: `Sources/UI/ComposerView.swift`

**Interfaces:**
- The UI labels the feature `Dual-Smol · experimental`, defaults off, and enables activation only when both exact model IDs are in `.ready` state.
- The user explicitly applies a toggle change by reloading the active native sandbox; applying off cancels and unloads Smol.
- `WorkbenchStore.setDualSmolEnabled(_ enabled: Bool) async -> Bool` persists the proposed setting, reloads the active sandbox, and restores/reloads the prior safe state if activation fails.
- If no native sandbox is active, persist the opt-in for the next sandbox start; if one is active, reload it immediately and return `false` if the pair did not load.
- If either model is absent, show its name and keep its existing verified download button available.
- Preserve the ordinary active-model selection and avoid adding a new provider or permission surface.

- [x] Add availability and opt-in controls to the existing GUS model screen.
- [x] Implement `WorkbenchStore.setDualSmolEnabled(_ enabled: Bool) async -> Bool`; apply the preference through the current native backend, and restore the prior setting/runtime on load failure.
- [x] Add a visible composer badge while active and a concise timeline status if Smol is skipped or Qwen continues alone.
- [x] Review VoiceOver labels and ensure experimental state is not presented as a guarantee of device stability.

### Task 5: End-to-end implementation review and device handoff

**Files:**
- Review all files listed above; the isolated runner is also a new source file.

- [x] Inspect the diff to confirm all existing local changes remain present and unstaged unless they are part of the requested feature.
- [x] Trace all spec acceptance criteria against implementation; do not claim iPhone stability from simulator or CI. Static review only.
- [x] Hand off an exact physical-device procedure: install the authorized IPA; download/verify both models; test Qwen-only; enable Dual-Smol; send fixed prompts including greeting, ambiguity, and a repetition-prone prompt; confirm Qwen alone answers if Smol output is rejected; disable the experiment and confirm Smol unloads.
- [x] Report build, CI, and device-validation state truthfully; leave CI/device checks unclaimed until actually performed.

**Implementation review result:** code paths are connected and statically inspected. Per the workspace instruction, no local tests/builds were run. CI compilation and all physical-device outcomes remain unverified and are not implied by these checkboxes.
