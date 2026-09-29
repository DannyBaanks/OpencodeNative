# GUS Smol Auxiliary Experiment

**Status:** Approved for experimental implementation; physical-device validation still pending.

## Goal

Add an opt-in experiment in which SmolLM2-360M produces a small, structured
intent hint for Qwen2.5-0.5B. Qwen remains the only user-facing responder. The
experiment measures whether the hint helps without giving Smol authority over
tools, permissions, files, or actions.

## User evidence and constraints

- The user reports that Qwen responds coherently on the physical iPhone.
- In two screenshots, Smol's response repeats the same phrase many times. The
  screenshots establish repetition, but do not establish whether the cause is
  sampling, prompt format, stop handling, or another runtime issue.
- The local-model screen already offers independently downloaded, hash-verified
  Qwen2.5-0.5B and SmolLM2-360M artifacts.
- Normal GUS must remain unchanged unless a person explicitly enables the
  experiment. This is an experimental feature, not a claim that dual residency
  is stable on every iPhone.
- No remote provider, model-weight modification, or new iOS permission is part
  of this feature.

## Design

### User experience and activation

Add a clearly labeled **Dual-Smol (experimental)** control in the existing GUS
local-model screen. It is off by default and can be enabled only when the
approved Qwen2.5-0.5B and SmolLM2-360M artifacts are both installed and verified.
If either artifact is missing, explain which one is needed and link to its
existing download control. Keep the currently selected normal model and its
behavior unchanged when the experiment is off.

When enabled, show an experimental status indicator in the GUS composer/session
so the person can tell that Smol is participating. Provide a direct way to turn
the experiment off. Do not silently switch to another installed model.

### Runtime flow

1. Qwen uses the existing `GUSLocalModelProvider`. Smol uses a dedicated
   internal auxiliary runner backed by its own `LlamaCppInferenceEngine` and
   the existing verified Smol URL/manifest. The runner bypasses the normal GUS
   provider prompt/tool wrapper so it cannot receive authority instructions or
   tool formatting.
2. For each user turn, the coordinator gives Smol only one fixed classifier
   instruction and the latest user message. It does not pass the full
   conversation history, tool schemas, capability catalog, file contents,
   credentials, or GUS authority/policy instructions.
3. Smol must return a strict, compact JSON object containing only integer
   `version: 1` and one fixed `intent` enum (`greeting`, `question`, `task`,
   `ambiguous`, `other`). The UTF-8 response is capped at 96 bytes and
   generation at 32 tokens. No free-form plan or tool call is accepted.
4. Swift validates the complete response, schema, enum, and output length. It
   also detects repeated output. Malformed, oversized, repetitive, or timed-out
   results are discarded. A user cancellation cancels the whole turn; Smol is
   not allowed to continue Qwen after the user has stopped the request.
5. Qwen receives the normal conversation plus the validated intent as an
   explicitly untrusted hint. Qwen remains responsible for the user-facing
   answer. The normal Swift permission and tool path remains authoritative.
6. If Smol fails any check, Qwen continues with the original prompt. The UI
   exposes a short diagnostic state such as “Smol skipped; Qwen continued”; it
   does not display the raw Smol output as an answer.

The initial implementation keeps both engines loaded while the opt-in
experiment is active and invokes them sequentially, never concurrently. If
Smol fails to load, clean up its partial engine and retain Qwen-only mode. The
app cannot guarantee that iOS will not terminate it under memory pressure; if
that happens, no success or stability claim is made. Physical-device
validation remains necessary.

### Safety and privacy boundaries

- Smol's dedicated runner receives no GUS authority/policy instructions or
  tool definitions and cannot emit executable tool requests.
- The intent hint cannot grant, deny, or broaden a permission, select a
  workspace, authorize a mutation, or claim an operation completed.
- No shell, process, arbitrary network, or additional filesystem access is
  added.
- Inputs and outputs stay on-device. Diagnostics contain fixed status
  categories only; they do not persist prompt, response text, raw output length,
  or tool data.
- Turning the experiment off cancels in-flight auxiliary work and releases the
  Smol engine. Qwen-only operation remains available.

### Error handling

- Smol load failure: leave the experiment unavailable, retain Qwen-only use,
  and show a concise error.
- Smol generation timeout, malformed JSON, unsupported schema, repeated
  output, or output over the hard cap: discard the hint and continue with
  Qwen-only input for that turn; surface the reason without raw model text.
  Explicit user cancellation stops the complete turn and unload/reload cleanup
  remains responsible for releasing the engines.
- Qwen failure: preserve the existing GUS error behavior; Smol does not answer
  as a fallback.
- App restart: do not assume both models are resident. Recheck verified files
  and reload only if the experimental setting is still enabled.

## Alternatives considered

1. **Smol answers the user, Qwen is optional.** Rejected because the supplied
   device evidence shows repeated user-facing output.
2. **Shadow mode with no effect on Qwen's prompt.** Safest for initial
   measurement, but it does not test whether the models cooperate. It can be a
   follow-up if the structured hint proves unreliable.
3. **Hot-swap one engine at a time.** Lower peak residency may be possible, but
   it adds reload latency and lifecycle complexity. Defer until the resident,
   sequential prototype has device measurements.

## Acceptance criteria

- Default remains Qwen-only; no model behavior changes unless explicitly
  enabled.
- Experiment activation requires both approved artifacts to be installed and
  verified.
- Smol output is constrained, validated, repetition-checked, and never shown
  as the assistant's answer.
- Qwen is always the user-facing model; on any auxiliary failure it receives
  the original prompt and continues alone.
- Smol cannot call tools or affect Swift permission decisions.
- The two engines are never asked to infer concurrently.
- Turning the experiment off cancels/unloads Smol and returns to Qwen-only mode.
- CI may verify compilation and deterministic coordinator behavior, but only a
  physical-device run can establish memory, stability, thermal, and quality
  results. No such results are implied by this specification.

## Out of scope

- Training, fine-tuning, or changing either model's weights.
- Replacing Qwen as the primary responder.
- Parallel inference, dynamic arbitrary model selection, or any new provider.
- Giving Smol direct tool, workspace, permission, or approval authority.
- Claiming iPhone 12 viability before measured device evidence.
