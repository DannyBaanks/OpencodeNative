# Codex App Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Habilitar conversaciones remotas experimentales de Codex desde iOS mediante `codex app-server` JSON-RPC, con pairing por capability token y alcance limitado a VPN cifrada Tailscale.

**Architecture:** El Bridge detecta y supervisa el proceso Codex App Server con WebSocket autenticado. En iOS, un pairing Codex tipado alimenta un cliente JSON-RPC aislado y `CodexRemoteBackend` adapta threads, turns, notificaciones y aprobaciones al contrato que consume `WorkbenchStore`. Las operaciones que Codex v1 no ofrece quedan explícitamente deshabilitadas.

**Tech Stack:** Node.js Bridge, `codex app-server`, WebSocket, JSON-RPC, Swift/Foundation, `URLSessionWebSocketTask`, Keychain, SwiftUI.

**Spec:** `docs/superpowers/specs/2026-09-27-codex-app-server-design.md`

**Evidence rule:** installed Codex contract > assumptions in this roadmap.
Protocol/CLI details are tied to the locally inspected Codex CLI 0.155.1; the
Bridge derives its advertised profile from the installed schema and iOS
intersects that profile with the operations it implements.

## Global Constraints

- El Bridge del host inicia y supervisa el App Server.
- Usar `codex app-server` con JSON-RPC como protocolo de Codex.
- Usar un token de capacidad aleatorio, específico para el pairing.
- Marcar esta integración como **experimental**.
- Codex v1 se limita a una VPN cifrada Tailscale seleccionada explícitamente.
- Para el WebSocket directo `ws://` de Codex, exigir Tailscale/VPN cifrada; no permitir acceso desde LAN plana en v1.
- No enlazar a `0.0.0.0` como camino predeterminado; enlazar a la IP Tailscale/VPN seleccionada.
- Elegir transporte y autenticación solo después de inspeccionar la instalación local y su schema.
- Construir las capabilities de Codex desde el perfil real del protocolo y fallar cerrado si no coincide.
- No reutilizar `username/password` como nombres o semántica del token de Codex.
- No incluir el token en logs, telemetría, errores, historial, query analytics ni mensajes de depuración.
- No habilitar REST de OpenCode, shell arbitrario, explorador de archivos, diff, providers, catálogo de agentes/comandos ni cambio de modelo desde iOS.

## Review Focus

No agregar ni ejecutar tests. El usuario autoriza compilación/typecheck y smoke operativo mínimo del transporte, sin ejecutar suites.

- Pairing ausente o con parámetros duplicados, host inválido, puerto fuera de rango o token vacío: rechazar antes de abrir la conexión.
- Credencial rechazada, inicialización/protocolo incompatible, timeout y cierre WebSocket: mostrar estado accionable sin revelar token.
- Notificaciones de otro thread o duplicadas entre historial y streaming: no alterar la sesión seleccionada ni duplicar timeline.
- Aprobaciones de comando y de cambios de archivo: conservar tipo, request ID y opciones; no traducir semánticas incompatibles.
- Pairings OpenCode ya guardados al migrar el almacenamiento: conservar su reconexión y borrar el secreto Codex al olvidar el pairing.
- Codex: rechazar antes de bind toda interfaz que no sea la IP Tailscale seleccionada; no usar LAN plana, exposición pública o loopback.

---

## Evidencia local previa a implementación

**Codex CLI 0.155.1 — inspección local del 2026-09-27**

| Elemento | Clasificación | Evidencia |
| --- | --- | --- |
| `codex app-server` disponible | DEMONSTRATED | `codex --version` → `codex-cli 0.155.1`; `codex app-server --help` enumera el comando. |
| WebSocket remoto | DEMONSTRATED | `--listen` acepta `ws://IP:PORT`; listener no loopback documenta `--ws-auth`. |
| Auth capability-token | DEMONSTRATED | `--ws-auth capability-token` y `--ws-token-file` / `--ws-token-sha256` aparecen en `--help`. |
| Auth header | DEMONSTRATED | Documentación oficial indica presentar el token como `Authorization: Bearer <token>` en el handshake WebSocket, antes de `initialize`. |
| TLS/listener seguro | NOT_DEMONSTRATED | El listener documentado es `ws://`; el CLI local no anuncia listener `wss://`. Documentación oficial exige TLS para conexiones no locales. |
| Schemas locales | DEMONSTRATED | `codex app-server generate-json-schema --experimental --out <dir>` genera el bundle del protocolo instalado. |
| Initialize/initialized | DEMONSTRATED | Bundle incluye `initialize`, `InitializeParams/Response` y notificación cliente `initialized`. El servidor devuelve `userAgent`; no declara un campo de versión negociada. |
| Threads/turns | DEMONSTRATED | Schema incluye `thread/list`, `thread/start`, `thread/resume`, `thread/read`, `turn/start`, `turn/interrupt`. |
| Streaming | DEMONSTRATED | Schema incluye `item/agentMessage/delta`, `item/started`, `item/completed` y `turn/completed`. |
| Aprobaciones | DEMONSTRATED | Hay requests diferentes `item/commandExecution/requestApproval` y `item/fileChange/requestApproval`; cada una declara respuestas y opciones propias. |
| Capability discovery remoto durante initialize | NOT_DEMONSTRATED | Initialize no devuelve una lista de métodos/capacidades. Bridge deriva un perfil del schema local; iOS intersecta ese perfil con su lista implementada. El servidor todavía puede rechazar una llamada. |
| Mismo CLI/schema en hosts remotos distintos | INFERRED | Cada Bridge debe repetir discovery en el host donde corre; no se presupone que coincida con esta máquina. |

**Límite de transporte seleccionado: DIRECT sobre VPN cifrada.** La instalación
local demuestra WebSocket remoto y autenticación capability-token nativa, pero
solo ofrece `ws://`, no TLS. Por eso el listener se enlaza a una IP Tailscale/VPN
explícitamente seleccionada, nunca a LAN plana ni Internet público. Si el host
objetivo no ofrece ambos flags, un túnel VPN seleccionado o el schema mínimo,
Bridge falla cerrado; no abre un listener sin auth ni cambia a `0.0.0.0`/proxy.

## Mapa de archivos

- `Bridge/bin/iyscodemovil.mjs`: discovery CLI/schema, selección de IP Tailscale, verifier SHA-256, pairing y supervisión/cierre del proceso.
- `Sources/Remote/CodexPairing.swift` (nuevo): modelo y parser del pairing WebSocket específico de Codex.
- `Sources/Remote/CodexPairingStore.swift` (nuevo): metadata no secreta de Codex y secreto separado en Keychain.
- `Sources/Remote/PairingStore.swift`: se mantiene sin cambios para preservar el registro OpenCode actual.
- `Sources/Backend/WorkbenchBackend.swift`: contrato de conexión remota y declaración de capacidades.
- `Sources/Backend/WorkbenchBackendFactory.swift`: selección y construcción del backend Codex.
- `Sources/Backend/Remote/CodexAppServerClient.swift` (nuevo): transporte WebSocket JSON-RPC, correlación de IDs, notificaciones y solicitudes iniciadas por el servidor.
- `Sources/Backend/Remote/CodexRemoteBackend.swift`: ciclo de vida thread/turn, traducción de historial/eventos y errores, respuesta a aprobaciones compatibles.
- `Sources/Backend/WorkbenchStore.swift`: persistencia/reconexión por tipo, modelo por defecto Codex y filtrado de capacidades no disponibles.
- `Sources/UI/ProjectSessionViews.swift`, `Sources/UI/ActiveSessionView.swift` y `Sources/UI/TimelineViews.swift`: affordances no soportadas y estado experimental, solo donde se necesiten para respetar las capacidades declaradas.
- `docs/REMOTE.md`, `docs/ROADMAP_CLIS.md`: pairing Codex, límite LAN/VPN, capacidades v1 y estado real del hito.

## Tareas

### Task 1: Descubrir, elegir transporte/auth y lanzar Codex desde el Bridge

**Files:**
- Modify: `Bridge/bin/iyscodemovil.mjs`

**Interfaces:**
- Consume: opciones existentes `--runtime`, `--port`, `--directory`, `--host`; `codex app-server --help` de la instalación local.
- Produces: diagnóstico de discovery sin secretos; runtime ligado a la IP Tailscale/VPN seleccionada, con auth demostrada y perfil compacto de capabilities derivado del schema local; pairing transitorio con endpoint, directorio, versión/perfil y token.

- [x] Consultar `codex --version`, `codex app-server --help` y generar schema experimental en directorio temporal antes de fijar argumentos; detectar sin asumir flags ni métodos.
- [x] Clasificar listen/bind, auth, initialize, thread/turn, cancelación, approvals, requests entrantes y notifications como `DEMONSTRATED`, `INFERRED` o `NOT_DEMONSTRATED`.
- [x] Seleccionar DIRECT solo si el CLI instalado demuestra WebSocket remoto y capability-token; de lo contrario salir antes de abrir puerto. No implementar proxy como fallback automático.
- [x] Resolver host primero y ligar `--listen ws://<IP Tailscale/VPN cifrada seleccionada>:<port>`; rechazar LAN plana, host público y loopback para pairing remoto, y no usar `0.0.0.0`.
- [x] Crear token aleatorio nuevo por invocación, calcular SHA-256 y pasar solo su digest no reversible con `--ws-auth capability-token --ws-token-sha256 <hex>`; no crear archivo ni incluir el token crudo en argv. No reutilizar variables Basic de OpenCode.
- [x] Extraer del schema el perfil mínimo de métodos/eventos que el adapter podría implementar y anunciarlo con la versión no secreta; sin schema no se anuncian capabilities.
- [x] Generar pairing Codex transitorio separado del pairing OpenCode. La impresión explícita de onboarding en stdout es el único lugar donde aparece la URL/token; errores y logs nunca incluirán token ni URL completa.
- [x] Mostrar `ws://<host>:<port>` y aviso experimental Tailscale/VPN; reenviar SIGINT/SIGTERM y eliminar el schema temporal al terminar.

### Task 2: Tipar y persistir pairings remotos sin romper OpenCode

**Files:**
- Create: `Sources/Remote/CodexPairing.swift`
- Create: `Sources/Remote/CodexPairingStore.swift`
- Modify: `Sources/Backend/WorkbenchBackend.swift`
- Modify: `Sources/Backend/WorkbenchBackendFactory.swift`
- Modify: `Sources/Backend/NativeSwiftBackend.swift`
- Modify: `Sources/Backend/Remote/OpenCodeRemoteBackend.swift`
- Modify: `Sources/Backend/Remote/CrushRemoteBackend.swift`
- Modify: `Sources/Backend/Remote/ClaudeCodeRemoteBackend.swift`
- Modify: `Sources/Backend/Remote/GeminiRemoteBackend.swift`
- Modify: `Sources/Backend/WorkbenchStore.swift`

**Interfaces:**
- Produces: `CodexPairing` con `host: String`, `port: Int`, `token: String` y `directory: String`; parser `init?(url: URL)` o equivalente que valide `codex://pair` y no acepte parámetros duplicados.
- Produces: `BackendPairing: Sendable` con casos `.openCode(OpenCodePairing)`, `.codex(CodexPairing)` y `.remote(RemotePairing)`; `WorkbenchBackend.connectRemote(pairing: BackendPairing)` permite pasar el pairing seleccionado sin convertir token Codex a Basic Auth.
- Produces: metadata Codex no secreta (backend, host, puerto, directorio, perfil y versión) fuera de Keychain; token solo en Keychain. La URL no es el registro persistente. Los registros OpenCode existentes siguen decodificando sin migración destructiva.

- [x] Definir el tipo de pairing Codex y validar esquema `codex`, host no vacío, puerto `1...65535`, token no vacío y ausencia de query items duplicados.
- [x] Cambiar el contrato a `connectRemote(pairing: BackendPairing)`; actualizar Native, OpenCode, Crush, Claude Code y Gemini para consumir o rechazar su caso correspondiente, preservando el formato OpenCode actual. Eliminar solo los bloques de métodos/estado duplicados preexistentes en `OpenCodeRemoteBackend.swift`, porque redeclaran miembros y bloquean la compilación.
- [x] Actualizar `WorkbenchBackendFactory` para construir `CodexRemoteBackend` configurado con el pairing Codex; no construirlo sin credenciales ni con `RemotePairing.authHeaders`.
- [x] Dejar `PairingStore` OpenCode sin cambios; añadir `CodexPairingStore` que guarde metadata no secreta en preferencias, token con clave Keychain dedicada y borre ambos al olvidar pairing.
- [x] Actualizar `WorkbenchStore.connectRemote`, `reconnectStoredPairing`, `reconnect` y `forgetPairing` para parsear, persistir y reconectar el backend seleccionado sin registrar la URL/token.

### Task 3: Implementar cliente JSON-RPC WebSocket

**Files:**
- Create: `Sources/Backend/Remote/CodexAppServerClient.swift`

**Interfaces:**
- Produces: actor `CodexAppServerClient` inicializado con endpoint, token y perfil declarado; funciones para `connect`, `request(method:params:)`, `respond(id:result:)`, `disconnect` y stream tipado de notificaciones/requests entrantes.
- Consumes: pairing validado de Task 2; `URLSessionWebSocketTask`; tipos JSON `Codable`/`Sendable` locales.

- [x] Validar los tipos de envelope JSON-RPC definidos por el schema local; enviar `initialize` con `clientInfo`, validar respuesta y versión `userAgent`, luego emitir `initialized`.
- [x] Implementar envelope JSON-RPC con IDs correlacionados, respuestas de éxito/error y lectura continua de frames WebSocket.
- [x] Enviar el capability token en `Authorization: Bearer <token>` durante handshake WebSocket; no interpolarlo en URL, logs ni errores.
- [x] Aceptar solicitudes JSON-RPC iniciadas por el servidor y permitir responder con el mismo ID, sin confundirlas con notificaciones.
- [x] Traducir autenticación rechazada, timeout, cierre de socket, frame inválido e incompatibilidad de initialize a errores localizados sin incluir secretos.
- [x] Hacer `disconnect` idempotente y detener el loop de lectura para liberar tareas/socket.

### Task 4: Implementar solo las capabilities demostradas de threads, turns e historial

**Files:**
- Modify: `Sources/Backend/Remote/CodexRemoteBackend.swift`
- Modify: `Sources/Backend/WorkbenchBackend.swift`
- Modify: `Sources/Backend/WorkbenchStore.swift`

**Interfaces:**
- Consumes: `CodexAppServerClient` de Task 3.
- Produces: `CodexRemoteBackend` que cumple `WorkbenchBackend`, declara capabilities v1 y maneja thread actual, historial, turno y cancelación.

- [x] Construir la matrix efectiva como intersección `perfil Bridge ∩ perfil implementado en iOS`; si faltan métodos/eventos requeridos o no coincide el protocol profile, fallar cerrado.
- [x] Listar threads solo si el perfil incluye `thread/list`; convertirlos a `Session` ligado al workspace del pairing.
- [x] Habilitar create/resume/select solo si el perfil incluye `thread/start` y `thread/resume`; conservar IDs y asociación thread ↔ Session.
- [x] Habilitar `sendPrompt` solo si están demostrados `turn/start` y las notificaciones que se mapearán; enviar turno y traducir únicamente eventos representables a `WorkbenchEvent`.
- [x] Habilitar `loadHistory` solo si `thread/read` está en perfil; deduplicar por IDs contra el stream.
- [x] Habilitar `abort` solo si están `turn/interrupt` y la notificación de finalización asociada.
- [x] Hacer que las operaciones no soportadas (archivos, shell, diff, providers, configuración y comandos) devuelvan un error explícito y que sus capabilities sean falsas.
- [x] No permitir seleccionar un modelo distinto en v1; exponer el default Codex de forma clara en `WorkbenchStore`.
- [x] En el flujo Codex de `WorkbenchStore`, no llamar a providers/config/comandos ni cargar explorador/diff/shell; dejar colecciones vacías y ocultar sus controles para evitar errores espurios.

### Task 5: Traducir aprobaciones y presentar capacidades en iOS

**Files:**
- Modify: `Sources/Backend/Remote/CodexRemoteBackend.swift`
- Modify: `Sources/Backend/WorkbenchBackend.swift`
- Modify: `Sources/Backend/WorkbenchStore.swift`
- Modify: `Sources/UI/ProjectSessionViews.swift`
- Modify: `Sources/UI/ActiveSessionView.swift`
- Modify: `Sources/UI/TimelineViews.swift`

**Interfaces:**
- Consumes: stream de solicitudes entrantes y método `respond(id:result:)` de `CodexAppServerClient`; declaración de capabilities v1.
- Produces: presentación de approval antes de responder, con tipo, detalle y opciones originales del protocolo.

- [x] Mapear `item/commandExecution/requestApproval` y `item/fileChange/requestApproval` a approvals separados, conservando request ID, tipo, detalle y opciones del schema.
- [x] Exponer `accept`, `acceptForSession`, `decline` o `cancel` solo si la acción visible coincide exactamente. Cambiar copy de autorización persistente a “para esta sesión” al mapear `acceptForSession`; no ofrecer enmiendas de policy que la UI no puede mostrar.
- [x] Si el perfil no anuncia los requests/responses necesarios, esa clase de approval queda unsupported. Si llega un request que la UI no puede representar, mantenerlo pendiente con explicación y no autoaprobar.
- [x] Al responder, contestar al request JSON-RPC original con la opción seleccionada y limpiar el estado pendiente solo cuando el backend confirme la respuesta.
- [x] Ocultar o deshabilitar en superficies iOS las acciones fuera de capabilities Codex v1, sin afectar OpenCode u otros backends.
- [x] Mostrar indicador **Experimental — LAN/VPN** al conectar Codex y en estado de conexión; no presentar el WebSocket como TLS.

### Task 6: Documentar operación y límites del adapter

**Files:**
- Modify: `docs/REMOTE.md`
- Modify: `docs/ROADMAP_CLIS.md`

- [x] Documentar instalación/requisitos de Codex, comando de pairing, autenticación, ubicación de workspace, LAN/VPN y cómo revocar/olvidar pairing.
- [x] Documentar capacidades disponibles/no disponibles de Codex v1 y cómo actuar ante incompatibilidad de protocolo, autenticación o proceso detenido.
- [x] Actualizar el estado del roadmap solo para hitos efectivamente implementados; dejar los hitos pendientes sin marcar como completos.
- [x] Revisar el diff del plan implementado para confirmar que no se filtren tokens en URL logs, stdout de diagnóstico, errores ni documentación.

## Auto-revisión del plan

**Límite de esta implementación:** el cliente valida la forma del envelope
JSON-RPC y valida los campos usados por cada operación; no incorpora validadores
completos generados para cada payload del schema. El build y la integración
final en Xcode aún requieren un host macOS.

- El Bridge, pairing, transporte, lifecycle del backend, approvals/UI y documentación tienen tareas asignadas.
- Las dependencias siguen el orden de interfaces: Bridge/pairing → cliente JSON-RPC → backend → aprobaciones/UI → docs.
- Se identificó la interfaz inconsistente actual entre `WorkbenchBackend.connectRemote(OpenCodePairing)` y los stubs que reciben `RemotePairing`; Task 2 normaliza este punto antes del adapter.
- Se mantiene el pairing OpenCode ya almacenado y su flujo HTTP/Basic; el token Codex usa un modelo y transporte separados.
- No se agregaron tareas para otros CLIs ni para la migración global a un contrato de adapters; eso permanece fuera de la especificación Codex v1.
- No se agregan ni ejecutan tests. La autorización adjunta permite build/typecheck y smoke mínimo, sin invocar suites.
- Codex CLI local 0.155.1 demuestra transporte/auth DIRECT, pero no TLS. La documentación oficial pide TLS para no-local; por eso el plan restringe `ws://` a VPN cifrada, no LAN plana.
- `initialize` devuelve `userAgent` y plataforma, no una capability list; Bridge deriva el perfil del schema y iOS falla cerrado ante incompatibilidad.
- El `userAgent` observado en el smoke incluye `0.155.1`; iOS compara la versión del pairing con la respuesta de initialize y falla cerrado ante discrepancia.
