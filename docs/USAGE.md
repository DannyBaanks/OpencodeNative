# Uso — demo reproduible

> La app corre el **boot attempt del OpenCode TUI** (compat) + un **runtime nativo
> alternativo** (no OpenCode) que opera `usuario → agente → tools → workspace → resultado`
> dentro de iOS. Lo segundo es lo único que arranca, y está etiquetado como tal.

## A. En el simulador iOS o device

1. Genera el proyecto (XcodeGen) y abre con Xcode 15+.
   ```bash
   brew install xcodegen
   xcodegen generate
   open OpencodeNative.xcodeproj
   ```
2. Run en iOS Simulator (⌘R). Al arrancar verás el transcript del boot attempt:
   ```
   opencode-native — compatibility harness v0.2.0
   opencode-boot> probing host: iOS
   opencode-boot> target: OpenCode TUI v1.18.19 (license MIT)
   opencode-boot> generating capability matrix …
   opencode-boot> [UNSUPPORTED]   Executable nativo para el ABI del host
   opencode-boot> [UNSUPPORTED]   Runtime JavaScript compatible Bun 1.3.x
   opencode-boot> [UNSUPPORTED]   PTY + TTY raw mode (render TUI ANSI)
   …
   opencode-boot> BLOCKED at first hard blocker: PTY + TTY raw mode (render TUI ANSI)
   opencode-boot> OpenCode TUI cannot initialize on this host. NOT simulated.
   ```
3. Ejecuta `/demo` en la línea para correr el runtime alternativo (scripteado):
   ```
   $ /demo
   ```
   Verás flow: list → write `notes.txt` → read → write 2 líneas → read → final.
   El archivo `notes.txt` queda escrito en `~/Application Support/OpencodeNative/workspace/`.

4. `/matrix` vuelve a volcar la capability matrix. `/boot` re-ejecuta el boot attempt.
   `/provider scripted|remote` cambia entre provider scripteado y remote.
   `/clear` limpia el transcript. `/help` lista comandos.

## B. Conexión a un LLM remoto real (opcional)

- No hay UI de settings aún para API key. Para usar `RemoteModelProvider`, añadir manualmente:
  - Crea/edita `~/Application Support/OpencodeNative/config.json` con:
    ```json
    { "apiKeys": { "remote": "sk-..." }, "defaultModelName": "gpt-4o-mini", "defaultModelProvider": "remote" }
    ```
  - En la app: `/provider remote`, luego escribe tu prompt.
  - Se usa la base URL `https://api.openai.com/v1` por defecto (configurable compilando).

> La clave de OpenAI puede no usarse para ejecutar el demo; el provider scripteado es suficiente.

## C. Tests

- En macOS Simulator: `xcodebuild test -scheme OpencodeNative -destination 'platform=iOS Simulator,name=iPhone 15'`.
- CI: el job `test` de `.github/workflows/ios-build.yml` ya hace esto.

### Suites cubiertas

- `GlobMatcherTests` — matcher glob (`*`, `?`, `**/`).
- `CapabilityMatrixTests` — probe en host no-iOS returns `notApplicable`.
- `CompatReportTests` — entries = requisitos de OpenCode; no false blocker claim en host no-iOS.
- `OpenCodeBootAttemptTests` — transcript contains "OpenCode TUI …".
- `WorkspaceTests`, `PersistenceTests`, `ToolsDefinitionTests`.
- `AgentEndToEndTests` — scripted agent escribe `notes.txt` y el loop completa.

## D. Verificación sin Xcode (Windows / Linux, sólo sintaxis+typecheck)

```powershell
# En la raíz del repo (Swift toolchain presente):
swiftc -swift-version 5 -typecheck `
  Sources/Agent/AgentLoop.swift `
  Sources/Workspace/Workspace.swift `
  Sources/Persistence/Persistence.swift `
  Sources/Model/ModelProvider.swift `
  Sources/Model/ScriptedModelProvider.swift `
  Sources/Tools/GlobMatcher.swift `
  Sources/Tools/FileSystemTools.swift `
  Sources/Host/OpenCodeRuntimeContract.swift `
  Sources/Host/IOSCapabilityMatrix.swift `
  Sources/Host/CompatibilityReport.swift `
  Sources/Host/OpenCodeBootAttempt.swift
# Sin salida = OK (los archivos Foundation-only typechecks en Windows).

swiftc -parse Sources/UI/ConsoleView.swift Sources/UI/SessionViewModel.swift Sources/OpencodeNativeApp.swift
swiftc -parse Tests/*.swift
# Sin salida = OK sintaxis UI y tests.

# XCTest no se distribuye con el toolchain de Windows; para ejecutar tests
# se requiere Xcode / iOS Simulator (lo hace el CI).
```

## E. Limitaciones NUNCA fingidas

Ver `docs/IOS_LIMITATIONS.md`. Nada de:
- fake terminal, fake shell, fake Process.
- "OpenCode corre en iOS" sin evidencia.

## F. Booteo de OpenCode en iOS — qué esperar

- **No arranca.** El boot attempt del `OpenCodeBootAttempt` lo documenta.
- En el TUI de la app verás el primer *hard blocker* explícito.
- La *matriz* swarm completa está en la sheet `/matrix`.
