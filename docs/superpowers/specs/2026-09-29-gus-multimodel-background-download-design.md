# GUS Móvil: selector de tres modelos y descargas en segundo plano

**Estado:** diseño para revisión del usuario  
**Repositorio:** ISyCode Móvil  
**Base:** commit `80c293af4a8327d347e5603ff9c99881fd515060`

## Objetivo

Permitir que el usuario descargue, conserve, seleccione y compare tres modelos
locales aprobados para GUS sin incluir los pesos en el IPA. Una descarga iniciada
por el usuario debe continuar cuando iOS suspenda la app, cambie a otra app o
bloquee la pantalla. El catálogo debe fijar fuente, revisión, tamaño, hash,
licencia y atribución para cada GGUF.

Los tres modelos usan el mismo `GUSMobileRole.mobile.systemPrompt`. Cambiar el
modelo no cambia el rol, sus instrucciones ni las capacidades disponibles. GUS
sigue siendo orientación local; los tool calls siguen desactivados y el prompt
no es la frontera de seguridad. Los permisos, aprobaciones y límites los impone
el harness de la app.

## Catálogo fijado

Cada descriptor es una entrada de código revisada; no hay entrada de URL,
importación libre de GGUF ni resolución de `main` en tiempo de ejecución.

| ID estable | Modelo y cuantización | Fuente / revisión fijada | Archivo | Bytes exactos | SHA-256 | Licencia |
| --- | --- | --- | --- | ---: | --- | --- |
| `qwen15-18b-q4km` | Qwen1.5-1.8B-Chat Q4_K_M | [Qwen GGUF](https://huggingface.co/Qwen/Qwen1.5-1.8B-Chat-GGUF/tree/07800fcba6d5d1df3dfa36e3763374a2c0d9f91b), `07800fcba6d5d1df3dfa36e3763374a2c0d9f91b` | `qwen1_5-1_8b-chat-q4_k_m.gguf` | 1,217,752,928 | `702e983c77883426806a2af75d34ab3e462e1b822f9dc23b49e02280c24b2b18` | Tongyi Qianwen Research License, no comercial |
| `qwen25-05b-q4km` | Qwen2.5-0.5B-Instruct Q4_K_M | [Qwen GGUF](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/tree/9217f5db79a29953eb74d5343926648285ec7e67), `9217f5db79a29953eb74d5343926648285ec7e67` | `qwen2.5-0.5b-instruct-q4_k_m.gguf` | 491,400,032 | `74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db` | Apache 2.0 |
| `smollm2-360m-q4km` | SmolLM2-360M-Instruct Q4_K_M | [GGUF de mfuntowicz](https://huggingface.co/mfuntowicz/SmolLM2-360M-Instruct-Q4_K_M-GGUF/tree/de67c694b3fa2c6e9b45b50f286b2555c5dee2a8), `de67c694b3fa2c6e9b45b50f286b2555c5dee2a8` | `smollm2-360m-instruct-q4_k_m.gguf` | 270,590,528 | `8856952e27c65a87618f8347d1d06328c3953af04e8327b6dd1fab6670358fd0` | Apache 2.0 |

The SmolLM2 row must identify HuggingFaceTB as the model family and
`mfuntowicz` as the GGUF uploader/converter, not as the model author. Before
implementation, confirm these exact file records, licenses, and hashes against
the pinned Hugging Face revisions and update the existing model notice and CI
manifest verifier. The fixed manifest is the source of truth in the app.

## User experience

1. The GUS model screen presents three cards with model name, quantization,
   download size, license/provenance links, SHA-256, and one of `Not downloaded`,
   `Downloading`, `Verifying`, `Ready`, or a recoverable error.
2. The user explicitly downloads any listed model. Only one model transfer runs
   at a time. Other installed models remain available; the user can remove each
   one separately to reclaim storage.
3. A model becomes selectable only after its exact size and SHA-256 pass. GUS
   loads only the user's selected, verified model, one at a time, to avoid
   stacking model memory on the iPhone.
4. The selected model ID is a non-secret preference. If that model is missing,
   invalid, or still downloading, GUS reports the state; it never silently
   switches models or falls back to a cloud provider.
5. If iOS cancels a transfer because the user force-quit the app, the next
   launch shows an interrupted/retry state. The app may resume from valid
   `URLSession` resume data; otherwise it restarts from byte zero and reports
   that behavior rather than claiming that transfer continued.

## Shared GUS behavior

- All local models are loaded through the same `GUSLocalModelProvider` behavior
  and receive `GUSMobileRole.mobile.systemPrompt` as their GUS role.
- Do not fork, tune, or silently append per-model instructions. Model identity
  may be shown in status/diagnostics, but must not alter the role's policy.
- Preserve `toolCalls == false`, 2K context default, no API-key configuration,
  local-only inference, and no remote fallback for all three.
- Add tests that prove each model uses the same role and that tool-looking text
  from any local model is never converted into a capability call.
- A shared prompt does not imply equal model quality or equal compliance. User
  evaluation should compare behavior, not treat a prompt as enforced security.

## Transfer architecture

Replace the current ephemeral, in-process byte stream with one stable background
`URLSession` download session. The session identifier is constant across app
launches. A delegate owns task-to-model association, byte progress, HTTP status,
redirect/final-host checks, completion, and errors. Only a request generated
from a compiled-in manifest can be started.

The app's SwiftUI entry point adopts `UIApplicationDelegateAdaptor`. The app
delegate hands iOS's `handleEventsForBackgroundURLSession` callback to the model
transfer service, restores the session by its stable identifier, and calls the
system completion handler only after pending events have been processed.
Restoration reconciles the saved model ID and task state with
`URLSession.getAllTasks`; progress is reconstructed from task byte counts where
possible. Do not rely on a view task or a live Swift concurrency task to own the
network transfer.

On successful download, move the temporary URLSession file immediately into a
model-specific staging filename in the app's existing user-visible
`Documents/ISyCode/GUS/Models` area. Stream SHA-256 from disk (never load a GGUF
into `Data` in memory), enforce the exact manifest byte count, and atomically
promote to the final model filename only after both checks pass. A staged file
left by process termination is reverified at next launch before promotion; an
invalid stage is deleted. Exclude model files from device backup. Preserve
discovery of the existing Qwen1.5 file and reverify it before adoption.

Background `URLSession` transfers support the desired app suspension and device
lock behavior, and iOS may relaunch a system-terminated app to deliver events.
They do **not** survive a user force-quit from the app switcher: iOS cancels
those transfers and will not relaunch the app until the user opens it again.
Network availability, storage pressure, Low Data Mode, and iOS scheduling can
also delay completion. UI copy must describe these limits plainly.

## Components and likely files

- `Sources/Model/GUSModelManifest.swift`: immutable three-model manifest
  catalog and stable IDs.
- `Sources/Model/GUSModelDownloadManager.swift`: selected model, per-model
  installed state, one background transfer, restoration, verification,
  cancellation, retry, and per-model deletion.
- `App/IysCodeMovilApp.swift`: app-delegate adaptor for background URLSession
  event handoff.
- `Sources/UI/GUSModelDownloadView.swift`: three model cards and persistent
  progress/retry/delete/select states.
- `Sources/Model/GUSLocalModelProvider.swift` and
  `Sources/Backend/NativeSwiftBackend.swift`: load the selected verified model
  while keeping one shared GUS role and unchanged tool boundary.
- `Tests/GUSModelManifestTests.swift`,
  `Tests/GUSModelDownloadManagerTests.swift`,
  `Tests/GUSLocalModelProviderTests.swift`,
  `Tests/GUSModelSelectionTests.swift`, and
  `scripts/verify-gus-model-manifest.py`: pin, switching, restoration, and
  verification coverage.
- `docs/MODEL_NOTICE.md`, `README.md`, and the iPhone evaluation matrix:
  provenance, licenses, download semantics, limitations, and reproducible
  comparison procedure.

## Safety and failure handling

- A discovered file is never assumed valid: verify byte count and SHA-256 on
  app launch and before loading, for all model IDs.
- Never load, promote, or retain a truncated, oversized, wrong-digest, or
  failed-transfer artifact. Keep staged and installed files separated.
- A download error, denied storage, task cancellation, or missing file remains
  a local GUS state. Do not trigger network inference through another provider.
- Only the built-in allowlisted model URL and reviewed redirect hosts are
  considered. A model response is untrusted data; the app does not execute
  metadata as code. Validate the final response and artifact hash before use.
- Persist only stable model IDs, transfer bookkeeping, and safe progress. Do
  not put prompts, conversation text, credentials, or user file contents in
  transfer task descriptions, logs, or request headers.
- Downloads remain an explicit user action. No model transfer is started on
  install, app launch, provider selection, or by GUS itself.

## Validation plan

### CI / simulator

- Verify all three exact manifest URLs, revisions, file names, byte counts,
  SHA-256 values, source attributions, and license links.
- Exercise successful download/verification for each manifest using tiny
  fixtures; wrong size, wrong hash, untrusted redirect/final host, HTTP error,
  insufficient storage, cancellation, interrupted-stage recovery, and retry.
- Assert discovery/persistence of multiple installed models, explicit active
  selection, single-model load behavior, and shared system prompt/tool boundary.
- Exercise background-session state reconstruction through an injectable
  transfer/session seam; do not claim simulator tests prove iPhone lock or
  force-quit behavior.
- Confirm IPA still excludes all GGUF files and README screenshots/build remain
  green in GitHub Actions.

### Physical iPhone

On Danny's iPhone 12 / iOS 18.7.8, after a CI build is installed:

1. Start each model once over Wi-Fi; lock the screen and separately switch to
   another app. Record whether progress continues, completion is delivered,
   SHA-256 passes, and the verified file is rediscovered after relaunch.
2. Force-quit once to document the expected iOS cancellation, relaunch, and
   inspect retry/resume behavior without asserting guaranteed byte resume.
3. Load each model separately with the shared GUS role; record response,
   latency, peak memory, and any termination. Repeat short prompts and adversarial
   requests against the shared role. Do not mark tool execution as supported.
4. Verify deleting one model leaves the other verified models intact and that
   a mismatched/corrupt file is rejected before llama.cpp loads it.

## Non-goals

- Training, fine-tuning, distilling, evaluating models to improve another model,
  or creating training examples from Qwen outputs.
- Bundling GGUF weights in Git, the app bundle, the IPA, or routine CI artifacts.
- User-supplied model URLs, arbitrary GGUF import, shell/process execution,
  additional iOS capabilities, GUS tool-call execution, or host-side inference.
- Promising background progress after a user force-quits the app or while iOS
  removes the app's execution opportunity.
