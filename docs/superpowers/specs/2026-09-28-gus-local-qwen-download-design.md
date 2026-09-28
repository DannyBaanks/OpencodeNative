# GUS local Qwen download and sandbox safety

**Status:** Design for user review  
**Product:** ISyCode Móvil  
**Base reviewed:** `3649e706c76674bac9692906e76f1efaaf196189`

## Goal

Offer GUS as an explicit on-device model option without placing 1.22 GB of model
weights in each IPA. The user explicitly downloads the one reviewed GGUF from
its immutable Hugging Face revision. The application verifies the artifact
before loading it. Inference runs locally and does not send prompts, workspace
files, or inference telemetry to a provider.

The goal is a safe file-work assistant. The model is untrusted input to the
harness and receives no authority merely because it is local or uses the GUS
role. The existing remote providers and offline scripted demo remain separate
and unchanged in behavior.

## Fixed model provenance

The first supported model is one compile-time manifest entry, not a model
picker or arbitrary import:

| Field | Value |
| --- | --- |
| Model | Qwen/Qwen1.5-1.8B-Chat-GGUF |
| GGUF | `qwen1_5-1_8b-chat-q4_k_m.gguf` |
| Hugging Face revision | `07800fcba6d5d1df3dfa36e3763374a2c0d9f91b` |
| Download | `https://huggingface.co/Qwen/Qwen1.5-1.8B-Chat-GGUF/resolve/07800fcba6d5d1df3dfa36e3763374a2c0d9f91b/qwen1_5-1_8b-chat-q4_k_m.gguf` |
| Exact byte count | `1,217,752,928` |
| SHA-256 | `702e983c77883426806a2af75d34ab3e462e1b822f9dc23b49e02280c24b2b18` |
| License | Tongyi Qianwen Research License Agreement; non-commercial terms |
| Source attribution | Qwen model repository on Hugging Face; the pinned file commit lists `JustinLin610` as its uploader |

Hugging Face hosts the repository and its revision; it is not described as the
model author. The app and README identify Qwen and the model license, link the
exact GGUF file/revision, and retain the required license and Notice. The
project remains open source and non-commercial as the user has stated. The app
must not use this model's outputs to train, fine-tune, distill, evaluate for
improvement, or create training data for another language model. A future
independently developed model must not be improved using Qwen outputs.

## User experience

1. A **GUS local** option appears alongside existing providers. The screen
   shows the model identity, quantization, exact download size, pinned source,
   license, and required free storage before download.
2. The user taps **Download model**. Nothing downloads on install or app start.
   The user can see progress and cancel. A cancelled or failed transfer is
   never loadable; the user can retry. Insufficient-space and checksum errors
   are shown clearly.
3. Only after byte-count and SHA-256 verification does the app atomically
   promote the staged file to the app's private model directory and show
   **Ready**. The app may offer **Delete model** to reclaim storage.
4. The user explicitly selects **GUS local** to run the local provider. If the
   model is absent or invalid, the app offers download/recovery and does not
   silently fall back to a remote provider.
5. The initial context profile is 2K. 4K stays experimental until measured on
   the iPhone 12. 32K with FP16 KV is not offered for this device. No claim of
   iPhone support is made before an observed physical-device run.

## Download and storage boundary

- A small, fixed model manifest in app code owns the source URL, revision,
  filename, exact byte count, digest, attribution, and license metadata.
- The downloader uses HTTPS with normal certificate validation. It accepts
  only the fixed Hugging Face file route and explicitly reviewed Hugging Face
  object-storage redirect hosts; it rejects arbitrary URLs, hosts, and
  user-selected GGUFs. Changes to the redirect allowlist require a reviewed
  code change.
- The transfer is user-initiated and handled by the app's model manager using
  Apple networking APIs. It is not exposed as a GUS tool and adds no general
  network, filesystem, process, or iOS-settings capability to the agent.
- Download into a staging file under the app container. Enforce a maximum
  byte count while receiving, compute SHA-256 incrementally without loading the
  1.22 GB file into RAM, compare exact size and digest, then atomically move to
  the final location. Delete staging data on cancellation, mismatch, or
  unrecoverable failure. Never open an unverified file with llama.cpp.
- Exclude the model from device backups. Keep prompts, workspace content,
  conversations, and model outputs local during local inference. Model download
  contacts only the fixed Hugging Face distribution endpoint and is disclosed
  in the download UI.
- The app bundle and IPA contain the runtime and app code, not Qwen weights.
  CI validates the manifest and downloader with small fixtures; it does not
  download or upload the 1.22 GB model as an Actions artifact.

## Runtime and provider boundaries

- Use a native llama.cpp iOS library built from the reviewed commit
  `842b1880415d6f508f03b789e5ce70194def7bfd`; do not launch `llama-cli`, shell,
  `Process`, or any executable.
- Build the XCFramework for iOS device and simulator with Metal. That pinned
  build script sets minimum iOS 16.4. The app currently targets 16.0. The
  product minimum will be raised to 16.4 in this feature; this intentionally
  drops iOS 16.0–16.3 while covering the user's iPhone 12 on iOS 18.7.8.
- Add local inference as an explicit `ModelProvider` implementation. Keep
  scripted demo and API-backed providers in their existing paths. A local model
  error must stay a local error; never retry the prompt against a cloud model.
- Keep context 2K as the recommended iPhone 12 profile. A 4K profile requires
  physical measurement and remains experimental. Do not expose 32K FP16 KV on
  the iPhone 12. Any quantized KV alternative needs its own physical test.

## GUS role, tools, and approvals

- Store GUS's system prompt/role once and make every in-app native agent route
  use that same definition. The prompt must state the actual harness boundary
  and treat file, message, and tool output as untrusted data, never as policy.
- The native capability catalog and tool inventory do not expand in this work.
  GUS can use only tools already registered for the current session and
  workspace grant. Model discovery is not permission.
- Preserve workspace containment. File operations use relative paths inside
  the active, user-authorized workspace; reject traversal and symlink escapes.
  No shell, arbitrary process execution, arbitrary network, or access to
  Keychain values is added.
- Writes, overwrites, moves, and deletes must be gated by the existing visible
  app approval flow for each operation. A denied, cancelled, stale, or missing
  approval fails closed. iOS permissions remain independently enforced.
- Replace the `SessionViewModel` demo's automatic `.allowOnce` response before
  evaluating GUS. It must wait for an actual visible approval decision or deny;
  no scripted approval is allowed in the physical evaluation build.
- The model's system prompt is advisory. The Swift tool executor and workspace
  guard remain the security boundary even if the model ignores its prompt or a
  workspace file contains prompt injection.

## CI and test strategy

- The unsigned IPA from GitHub Actions excludes the GGUF and its size is
  reported after the runtime is integrated. No model weights go into Git, the
  app bundle, or routine Actions artifacts.
- CI pins the llama.cpp source, generates/builds the Xcode project on macOS,
  tests app code, and verifies the model-manifest constants. Downloader tests
  use mocked/small responses to cover good digest, wrong digest, wrong size,
  rejected redirect/host, cancellation, retry, and insufficient storage.
- CI results and simulator tests do not prove iPhone inference. Physical tests
  on iPhone 12/iOS 18.7.8 record model load, short response, 2K latency, peak
  process memory/termination pressure, cancellation, background/foreground
  behavior, and network observation. A separate 4K run decides whether 4K can
  remain experimental or be removed. Any unavailable observation is BLOCKED.
- The manual device test uses disposable content. It verifies that the chosen
  model is the pinned file, that write/delete approvals round-trip through the
  app, that denial performs no mutation, and that local inference produces no
  provider traffic.

## Acceptance criteria

1. A fresh install contains no GGUF and does not download it automatically.
2. Only the single pinned Qwen GGUF can be downloaded by this feature; there is
   no model URL field or arbitrary GGUF import path.
3. A corrupt, truncated, oversized, redirected-to-unapproved-host, or
   wrong-digest response cannot become an installed model or be loaded.
4. GUS local is clearly separate from cloud providers and never silently falls
   back to one. The scripted demo remains usable offline.
5. All GUS routes share the reviewed role and real app approvals. Denied or
   absent approval results in no file mutation or native side effect.
6. Existing registered tool scope and iOS permission requirements remain
   unchanged. No private API or executable process is introduced.
7. The license and exact source attribution are visible in the app and in the
   repository's model notice. No Qwen outputs are used to improve another LLM.
8. CI compiles the model-free IPA. The report distinguishes CI/simulator
   results from observed iPhone 12 results and never calls GUS supported before
   the physical test passes.
