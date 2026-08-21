# INFORME FINAL DEL EXPERIMENTO: OpencodeNative iOS

> Reformulado el 2026-08-20 tras la redefinición del objetivo. El informe previo
> afirnaba "se build verificó / tests pasan" sin evidencia: eso se ha corregido.
> **Evidence before narrative.** Lo que no se probó, no se afirma.

## EXPERIMENTO

¿Puede el **TUI real de OpenCode** arrancar dentro de un runtime nativo de iOS
mediante un *compatibility harness*, de modo que OpenCode opere sobre un entorno
iOS y descubra que corre en iOS?

## HARNESS — qué proporciona

- `Sources/Host/OpenCodeRuntimeContract.swift` — contrato estático del OpenCode
  TUI v1.18.19 (license MIT), con evidencia textual del repo `anomalyco/opencode@dev`
  (`package.json` + `install` script).
- `Sources/Host/IOSCapabilityMatrix.swift` — probe en runtime de las capacidades
  de iOS (probea realmente FileManager y gates iOS-only APIs con `#if os(iOS)`).
- `Sources/Host/CompatibilityReport.swift` — reconcilia contrato ↔ matrix →
  veredicto por capability (`compatible` / `partial` / `unsupported` / `uncharted`).
- `Sources/Host/OpenCodeBootAttempt.swift` — boot attempt documentado que
  emite un transcript de bloqueo. **No simula** lo que no puede probar.

Lo que el harness **expone** de iOS: filesystem sandbox, red TLS/WS/localhost,
SQLite, LLM API remoto, keychain, file watchers limitados, bookmarks con picker.

Lo que el harness **no puede proveer**: Bun runtime, PTY/TTY, spawn/exec,
tree-sitter nativo, entorno POSIX, binario iOS de OpenCode.

## OPENCode TUI — qué se ejecutó realmente

**Nada del TUI real de OpenCode se ejecutó**, ni podría:
- No hay binario OpenCode para iOS en las releases (`install` rechaza `ios-*`).
- No hay runtime Bun para iOS (Bun no publica target `ios-arm64`).
- PTY/TTY no existen en iOS → el renderer `@opentui` no inicializa.
- Sin `node:child_process`/`cross-spawn` → `bash` tool inoperable.

Esto **no es un fallo de implementación** del harness; es la frontera de
compatibilidad del propio iOS para un programa que asume un OS POSIX con PTY.
El experimento **demuestra exactamente** esa frontera (ver `CompatibilityReport`).

## iOS — capacidades reales

Ver `docs/IOS_LIMITATIONS.md` y `docs/OPENCODE_COMPAT.md` §3. Resumen:

- Posibles: FS sandbox, SQLite (no Bun), Network TLS/WS/localhost, Keychain,
  LLM remoto, file watcher limitado, security bookmarks vía picker.
- Imposibles: PTY/TTY, spawn/exec, Bun, tree-sitter nativo, entorno POSIX,
  compilar/ejecutar código en device, firmar IPA en Windows.

## EVIDENCIA — qué fue ejecutado / probado

Ejecutado/probado hasta el cierre de esta iteración (en la herramienta
disponible aquí: Windows con toolchain Swift 6.3.3):

1. `swiftc -swift-version 5 -typecheck` sobre los archivos Foundation-only
   (`Agent/AgentLoop`, `Workspace`, `Persistence`, `Model/*`, `Tools/*`, `Host/*`)
   → **0 errores**. El módulo Core (sin SwiftUI) typechecke en toolchain Swift.
2. `swiftc -parse` sobre `Sources/UI/ConsoleView.swift`, `SessionViewModel.swift`,
   `OpencodeNativeApp.swift` y `Tests/*.swift` → **0 errores de sintaxis**.
3. Bug original detectado y corregido con evidencia del typecheck:
   `ModelProvider.parseResponse` asignaba un `String` (JSON de arguments de la
   API) a `ToolCall.arguments` declarado como `[String:String]`. Antes esto no
   se detectaba porque el CI sólo hacía `swiftc -parse` (sin typecheck).
4. Bug original de `AgentLoop` corregido: `tool_call_id` de los mensajes `tool`
   usaba un UUID nuevo en vez del `id` del tool_call del modelo → rompía
   conversaciones multi-turn en APIs OpenAI-compatibles.
5. Stream vía `URLSession.bytes(for:)` está guardado con `#if` porque el
   toolchain Windows CoreLibs no lo expone; en iOS sí. Documentado.
6. `project.yml` actualizado con target de tests `OpencodeNativeTests` y
   `scheme` que incluye tests. Antes no había test target.

**NO se ejecutó aquí** (toolchain Windows sin XCTest ni iOS SDK):
- Tests de XCTest — requieren Xcode/iOS Simulator. Se ejecutan en CI
  (job `test` añadido al workflow con `xcodebuild test` en iOS Simulator).
- Build de la app iOS — requiere Xcode; se hace en CI (`build`).

## LIMITACIONES

- La TUI real de OpenCode no arranca en iOS; no existen build Bun-iOS ni API
  PTY pública. Fuera del sandbox iOS.
- El runtime nativo alternativo aquí presente NO es OpenCode; está etiquetado
  como tal. No se presenta como clon funcional.
- Sin toolchain/XCTest en el toolchain Windows, aquí no corrimos los tests;
  el CI sí (ver paso 6).
- No se integró real Bun/JS runtime ni node-pty — sería una mock-fake si
  intentáramos simularlo; fuera del experimento.

## ESTADO

**Partial — Blocked** (criterio B del brief):

> OpenCode TUI real arranca parcialmente y el experimento demuestra exactamente
> qué capacidades de iOS impiden completar la compatibilidad.

Implementado y compilable:
- Harness scaffold + capability matrix + compatibility report (probados con typecheck).
- Runtime nativo alternativo (no OpenCode): AgentLoop, 8 tools fs, persistence,
  model provider remoto + scripteado offline.
- TUI/console-first UI con boot transcript + matrix + slash commands.
- Tests en `Tests/` (corren en iOS Simulator via CI).

No compilado aquí (sin iOS SDK):
- Archive IPA en device, sandbox FS en iOS real (se hace en CI macOS runner).

## SIGUIENTE (una sola acción necesaria)

> Confirmar en CI (macOS runner) que `xcodebuild test` pasa para
> `OpencodeNativeTests` en iOS Simulator. Si alguna suite falla por
> actor-isolation, marcar los protocolos `ToolExecutor`/`ModelProvider`
> con `@preconcurrency` también en el target de tests (mismo patrón ya
> aplicado a los actores del runtime).
