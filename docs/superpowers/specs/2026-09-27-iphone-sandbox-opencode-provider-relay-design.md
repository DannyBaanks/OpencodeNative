# iPhone Sandbox with OpenCode Provider Relay

**Status:** Approved architecture; implementation in progress. The user approved the hybrid architecture, OpenCode-only provider source, per-session parallel runs, Keychain/API-key relay behavior, and Native iOS Capability Fabric on 2026-09-27. The host/TUI repo owns the host contract; this repo consumes it and does not modify it.

## Goal

Keep iSyCode Móvil's native agent and filesystem tools inside the iPhone sandbox while letting that agent use providers and models configured through OpenCode on the paired computer. Keep the user's provider API keys in the iOS Keychain, support OpenCode OAuth where available, stream model responses through the computer, and make run/stop state independent for every conversation.

## Non-goals

- Do not support OpenISy as a separate runtime or provider source.
- Do not move the iPhone workspace, filesystem tools, permission prompts, or native agent loop to the computer.
- Do not expose a provider's raw OAuth credential to iOS.
- Do not execute shell, filesystem, or other agent tools on the host as part of model inference.
- Do not change the existing OpenCode Bridge pairing or protocol in this project as part of this feature.
- Do not imply that a discovered provider is connected, authorized, or permitted.

## Architecture

### Responsibility split

**iSyCode Móvil (iPhone)**

- Owns the native `AgentLoop`, session transcript, local workspace, local tools, and tool approval round-trips.
- Stores user-entered provider API keys in iOS Keychain through the existing persistence layer.
- Displays the provider/model catalog and OAuth/API-key connection state reported by the host.
- Sends model requests to the paired host over authenticated HTTPS and renders the returned stream.
- Routes returned tool-call requests to local tools; host output never directly invokes a tool.

**ISyCode host with OpenCode adapter (computer)**

- Owns the OpenCode provider/model catalog, OAuth initiation/callback, OAuth credential storage, and provider-specific inference adapters.
- Stores OAuth provider credentials only in OpenCode's host-side auth store.
- For API-key providers, accepts the iOS Keychain key only over authenticated HTTPS for an inference request, uses it in memory, and discards it after the request. It must not persist or log that key.
- Streams model output and tool-call proposals back to the phone. It has no access to the iPhone filesystem and executes no proposed tools.
- Validates the paired mobile credential's scopes and any provider/model grants for every catalog, OAuth, and inference operation.

The TUI/host repository owns the versioned HTTP contract and host implementation. This repository consumes that contract. Coordinate and review the contract with the host owner before either side implements new routes. No host/TUI files are modified by this design task.

### Provider and model discovery

The host adapts OpenCode's provider inventory and authentication capabilities into a versioned mobile-host schema. The mobile app uses host data rather than a baked-in provider list. A provider is displayed as connected only when OpenCode reports it connected or an API key is available in the phone's Keychain, as appropriate to its auth mode. The host must mark models usable for streamed chat and tool calling; unsupported models remain visible as unavailable or are omitted from the selectable list.

NVIDIA API is the initial/recommended provider in the sandbox. Its OpenAI-compatible API base is `https://integrate.api.nvidia.com/v1`. Fetch available model IDs from NVIDIA's model endpoint through the supported provider adapter; do not hardcode a model ID. Until a key is configured and at least one model is verified, show NVIDIA as the selected setup choice and disable sending with a clear connect-key state.

Provider setup behavior:

1. Providers with a supported OpenCode OAuth method show **Connect** and launch the host-provided authorization flow.
2. Providers without a usable OAuth method show an API-key form. The key is stored in iOS Keychain.
3. NVIDIA is shown first and selected as the default sandbox provider until the user chooses another provider.
4. Model selection is based on the host's live provider/model response. Persist only provider/model identifiers and non-secret preferences outside Keychain.

### OAuth lifecycle

The mobile-host contract should represent provider auth methods and an authorization attempt as explicit state. The host starts the provider-specific OAuth flow through OpenCode, returns only the URL/instructions and an opaque attempt identifier, and completes any callback/token exchange on the host. The phone opens the system browser/auth session and polls the host attempt status over HTTPS. The host reports success, cancellation, expiry, or failure without returning access/refresh tokens. Host-owned state and OpenCode's auth store remain authoritative.

OAuth implementations differ by provider. The adapter must only offer methods OpenCode actually supports and must preserve each method's redirect, PKCE/state, manual-code, and expiry requirements. No generic callback behavior may be assumed for every provider.

### Inference relay

The host exposes a model-only streaming operation. It accepts the authenticated mobile request, provider ID, model ID, conversation messages, tool schemas, and—only for API-key authentication—the provider key in a sensitive request header. It invokes the selected OpenCode provider/model adapter directly. It must not use an OpenCode remote session endpoint for this operation because that would execute the OpenCode agent and its tools on the computer.

The host streams typed events such as response-start, text/reasoning delta, tool-call delta/completion, usage, completion, and error. Every event carries the mobile session ID and request/run ID. The phone appends assistant output to the matching session, executes tool calls locally with its existing approval flow, and sends tool results in the next model request. Cancellation addresses the run ID and session ID and must stop only that inference request.

The phone sends only the conversation and tool context required for the model call. Any file content the local agent read and included in that context crosses the HTTPS relay and is disclosed to the selected provider. Raw workspace access and unrelated files stay on the iPhone.

## Proposed versioned host contract additions

Exact route names and schemas are a proposal for host-owner review, not a claim that these routes already exist. Keep the established `/v1` prefix unless the host owner chooses a breaking version.

| Capability | Proposed operation | Requirements |
|---|---|---|
| Provider catalog | `GET /v1/providers` | List OpenCode providers, auth methods, connection status, and safe model capabilities; no credentials. |
| OAuth methods | `GET /v1/providers/{provider_id}/auth-methods` | Return only methods supported by the active OpenCode host. |
| OAuth start | `POST /v1/providers/{provider_id}/auth/start` | Create an expiring, state-protected attempt and return browser URL/instructions plus opaque attempt ID. |
| OAuth status/callback | `GET /v1/providers/auth/{attempt_id}` and host-owned callback handling | Expose pending/success/cancelled/expired/error; complete token exchange and storage on host. Never return provider tokens. |
| API-key validation/catalog | `POST /v1/providers/{provider_id}/models` | Validate a key transiently and return safe model metadata; do not persist/log the key. |
| Model stream | `POST /v1/inference/stream` | Authenticated, scoped, cancellable stream; API key only in a redacted sensitive header and memory. No host-side tools. |
| Stream cancellation | `POST /v1/inference/{run_id}/cancel` | Cancel only a run owned by the authenticated mobile client. |

All operations require an authenticated mobile pairing credential. Suggested independent scopes are provider catalog read, OAuth management, API-key model discovery, inference generation, and cancellation. The host—not the phone—enforces runtime/provider/model/workspace/action grants. Status and health responses must not disclose provider credentials.

### API key storage and transport

- Key entry is sent directly into the iOS Keychain; it must not pass through `UserDefaults`, app logs, analytics, crash reports, or clipboard history.
- The key is sent to the host only for requests that require it, in a dedicated sensitive header over HTTPS. It must not appear in URLs, query strings, pairing links, event streams, or error text.
- Host request logging and tracing must redact the sensitive header. Provider adapters keep the value in memory only for the outbound call and discard references when complete/cancelled.
- The app requires a trusted HTTPS host for remote pairing/inference. Plain HTTP is allowed only for loopback development.
- OAuth secrets are stored host-side in OpenCode's auth storage and never copied into iOS Keychain.

## Per-session execution and UI state

The current composer reads one global `ActiveSessionState.isProcessing`, and `WorkbenchStore.sendPrompt`/`cancelCurrentRun` use the currently selected session/backend. This makes one conversation's run appear as another conversation's Stop button and can target the wrong session.

The replacement design:

- Track active runs by `(backend identity, session ID, run ID)`, with independent status/error/cancellation state.
- Capture the selected session ID and backend at send time. Every backend send and abort operation receives the explicit session ID/run ID; do not infer it from mutable “currently selected” state.
- The composer derives its icon, text-field enabled state, and stop action from the open session only. A running session shows Stop; a different idle session shows Send and can begin its own run.
- Keep one active run per session by default; different sessions may run concurrently when the backend supports it.
- Preserve session IDs on all stream events. Route events into the selected timeline only when IDs match; background session events update that session's status/summary and are recovered from history when selected.
- Switching conversations never cancels a run. Stopping or receiving completion/error clears only the matching run/session state.
- Apply the same session isolation to the native iPhone sandbox. Keep workspace access local; serialize or detect conflicting workspace mutations so simultaneous sessions cannot silently overwrite stale file contents.
- Backends that cannot safely support multiple runs must report that capability, and the UI must queue or explain the limitation rather than showing a false Stop state.

## UI scope

- Sandbox provider selector with NVIDIA API as the initial choice, connection status, model picker, and a Settings entry to manage provider connections.
- OAuth-capable providers have a **Connect** action and visible pending/cancelled/connected/error states.
- API-key providers have a masked key field, explicit save/replace/remove controls, and a connected state that never reveals the key.
- Provider and model selection stays visible in the composer, matching the existing terminal/premium themes.
- Session list rows show a running indicator per session. Each session composer shows its own Send or Stop action.
- Explain that model prompts and any included file excerpts are sent through the paired PC to the selected provider; local tools still operate only in the iPhone sandbox.

## Error handling and lifecycle

- Expired/revoked mobile pairing: stop relay attempts and request re-pairing.
- Untrusted TLS, host unreachable, rate limit, unavailable provider, invalid key, unsupported model/tool calling, OAuth denial/expiry, and provider errors receive distinct safe UI states.
- Retry is limited to idempotent catalog/status calls. Do not silently replay a generation request after an ambiguous network failure.
- App backgrounding must not confuse run state: persist session/run metadata without secrets, reconnect the stream, and reconcile with host/run status or session history. The host is authoritative for active relay runs; the phone is authoritative for local tool execution/approval state.
- On logout/forget-provider, clear the selected provider's iOS Keychain API key and ask the host to revoke/remove OAuth auth when supported.

## Milestones

1. **Session isolation:** explicit session/run IDs in WorkbenchStore, backend send/abort, stream events, and composer state; validate two concurrent remote sessions and native sandbox behavior.
2. **Contract coordination:** host-owner review of provider schema, auth state machine, sensitive API-key handling, model-only stream events, cancellation, TLS, and grants. Add schemas/examples to the host-owned contract before client integration.
3. **OpenCode provider host adapter:** provider/model catalog and OAuth initiation/callback/status using OpenCode's supported methods; host-side OAuth credentials; no host tools in model relay.
4. **Keychain and NVIDIA setup:** provider settings UI, secure save/remove, NVIDIA as default, live model discovery, safe validation errors.
5. **iPhone sandbox relay:** model-only streamed generation integrated with local AgentLoop/tool approvals; per-session cancellation and recovery.
6. **Hardening and release:** verify supported provider capabilities, TLS and log redaction, session concurrency, OAuth cancellation/reconnect, and CI build before publishing.

## Acceptance criteria

- A model request made by the iPhone sandbox is streamed through the authenticated HTTPS host to a selected OpenCode provider, without creating a remote OpenCode agent session or invoking host tools.
- OAuth provider tokens remain on the host. API keys remain stored in iOS Keychain and are only transiently transmitted over HTTPS for a required host call; neither type appears in logs.
- NVIDIA is the initial sandbox provider and available model IDs are discovered live after key validation.
- iPhone filesystem reads/writes and tool approvals remain local and session-specific.
- While session A is running, session B shows Send and can start its own run. Each session shows its own running state, and Stop in B cannot cancel A. Completion, errors, and streamed content are routed only to their originating session.
- Concurrent sandbox sessions cannot silently overwrite conflicting file edits.
- The mobile app consumes only the host-owner reviewed contract and does not duplicate authorization decisions.

## Risks and open design checks

- OpenCode provider adapters may expose different auth and tool-calling capabilities. The host catalog must report capabilities and only advertise verified flows.
- The host owner must confirm that provider credentials can be accessed through a supported OpenCode adapter interface without unsafe direct reads of private state.
- A model-only provider invocation path may require a host adapter separate from OpenCode's public session API. It must preserve provider compatibility without importing session tools into the host relay.
- API keys sent transiently to the host are protected in transit and at rest on the phone, but the host process can access them in memory while servicing the request. Log redaction and TLS are release blockers.
- Concurrent sessions can target the same files. Workspace coordination/conflict behavior must be resolved before enabling simultaneous local file mutations.
- Provider/model context is sent off-device. The UI disclosure must appear before first use and remain accessible from provider settings.


## Native iOS Capability Discovery and Fabric

The phone is the authority boundary for Apple-device capabilities. Model output is data: it can create a typed proposal, but it cannot directly access UIKit, Foundation file URLs, Keychain, or Apple frameworks. Native operations pass through `NativeCapabilityBroker`, which checks capability availability, entitlement/setup, the current OS authorization state, effect policy, and any required explicit approval before calling a native adapter. The adapter returns a bounded result and a privacy-safe receipt. Host/OpenCode relay remains inference-only and cannot invoke this broker.

Design the inventory around user-useful capabilities, then resolve each operation through the narrowest official Apple surface. Classify the implementation as direct framework/API, App Intent or configured Shortcut, system UI/picker/composer, URL/deep link, or unavailable to third-party apps. Never infer that an app has a public API because it exists on iOS; e.g. Notes may need a supported Shortcut/system surface rather than a nonexistent public CRUD framework. Do not use private APIs. Modules report what they can actually implement on this device/configuration; `NativeCapabilityRegistry` composes those module results instead of treating a wishlist as operational tools.

The shared descriptor records a stable capability ID, implementation surface, availability, authorization state, entitlement/setup requirement, user-presence requirement, effect class, and input/output schema. Effect classes are `READ`, `WRITE`, `PRESENT_UI`, `SENSITIVE_READ`, `SENSITIVE_WRITE`, `DEVICE_ACTION`, and `EXTERNAL_SIDE_EFFECT`. Discovery is not authorization; authorization is not model permission; model permission never suppresses an Apple system prompt. Only context-relevant tools are projected into a model turn.

### First vertical slice

- **App Intents / Shortcuts:** expose only real typed ISyCode actions through App Intents/App Shortcuts. Support launching only individually configured user-owned shortcuts through Apple's documented URL integration. The app cannot claim to enumerate all shortcuts. The user configures/approves names or identifiers, external effects pass local approval policy, and launching may present Shortcuts UI.
- **Keychain:** retain provider API-key behavior. Add secret existence/store/replace/delete only where the app needs them; do not expose `secret.read` to the model. Provider credentials are app-owned Keychain values, never other apps' Keychain entries, and never model context.
- **Files:** retain the app sandbox and current user-picked folder bookmark. Any additional files or folders require the system picker and security-scoped URLs, minimal supported bookmark persistence, and coordinated access. The Files app does not grant broad Files access.
- **Notifications:** request authorization in context, then schedule/cancel local notifications for app-defined semantic events. The model may suggest wording but cannot choose policy or bypass authorization.
- **Settings catalog:** report `available`, `authorized`, `denied`, `restricted`, `needs setup`, or `unsupported` separately. “Available” never means “granted.”

The product inventory remains capability-first. Each entry names its user outcome, official mechanism, state probe, entitlement/usage-description requirements, approval class, and limitations. An unimplemented but officially possible operation is `needs setup` or absent from the executable tool projection; reserve `unsupported` for surfaces unavailable to this app/platform, not merely work that has not been built. Discovery can show future/research candidates as non-executable and must never expose them as tools.

The first slice does not request Calendar, Contacts, Photos library, Camera, Microphone, Speech, Location, HealthKit, HomeKit, Bluetooth, or motion permissions on launch. Later modules use the same typed broker: EventKit operations request only needed access; Contacts fetch only necessary fields; Photos prefers the system picker; camera/audio require visible invocation and current Apple permissions; location requests foreground access in context; share/open URL/compose use system UI and policy validation. HomeKit, Bluetooth, HealthKit, motion and other entitlement-gated APIs remain opt-in until a concrete use case and privacy review exist. BackgroundTasks are a supported opportunity, not an unrestricted daemon guarantee; durable run IDs and reconciliation are required for future long work.

### Policy, discovery, and receipts

Approval follows effect class rather than framework. Current sandbox reads use the existing grant; file writes retain explicit approval; sensitive reads require OS permission and local policy; shortcuts require a user-configured allowlist and any action approval; URL targets are validated; message composition presents Apple UI and is not reported as delivered; camera/microphone require OS permission plus visible user action. External side effects fail closed without approval. A model cannot fabricate capability state or permission.

Receipts record tool ID, request ID, authorization state, approval decision, effect class, success/failure, safe metadata, and timestamp. They must omit Keychain/OAuth secrets, media bytes, contact dumps, and unnecessary location precision. The host relay cannot call native tools. Capability tools are projected only when relevant to the user task; the full catalog is not sent with every model request.

### Directed witnesses

Automated tests cover registry state distinctions, model permission vs OS authorization, effect approval, fabricated-grant rejection, host/native boundary, secret redaction, picker bookmark scope, notification denial, shortcut allowlist/denial, and session/run recovery. Real-device witnesses are required for Apple permission prompts and system surfaces. Simulator results must be labeled simulator-only; no system-permission behavior may be claimed from simulator evidence alone.

### Expanded milestones

1. Session isolation and native Capability Fabric contracts: typed descriptors, broker/policy/receipts, shortcut/App Intent seam, Keychain secret boundary, existing Files grant integration, notification adapter and status UI.
2. Host contract coordination for provider discovery, OAuth, model-only inference streaming, and cancellation. This mobile repo does not edit host routes or legacy Bridge behavior.
3. OpenCode provider catalog/OAuth and NVIDIA/API-key setup when the host contract is implemented.
4. Native sandbox model relay through the host while all native capabilities execute locally.
5. Incremental capability modules: Calendar/Reminders, Contacts, Photos, Camera/Mic/Speech, Location, Share/URL, and MessageUI.
6. Hardening, real-device permission witnesses, CI, and release.
