# OpenCode TUI — iOS Compatibility Report

> Evidence before narrative. Every claim here is backed by a specific line in the
> real OpenCode repository (`github.com/anomalyco/opencode`, branch `dev`) or by a
> documented iOS platform fact. Probabilities and opinions are not used; only what
> the code says and what iOS exposes are.

## 1. EXPERIMENTO

> ¿Podemos ejecutar **el TUI real de OpenCode** dentro de un runtime nativo de iOS
> mediante un *compatibility harness*, para que OpenCode opere sobre un entorno iOS
> y descubra que está corriendo en iOS?

El objeto de compatibilidad es **el binario/TUI distribuido oficialmente por OpenCode**,
no una reescritura. Este documento define qué requiere ese binario y qué puede
proporcionar iOS.



## 2. OPENCODE TUI — Qué es (evidencia de directorio)

Inspección del repositorio `anomalyco/opencode@dev`:

| Hecho | Evidencia (archivo del repo OpenCode) |
|---|---|
| Licencia | `LICENSE` — MIT. Permite modificación y redistribución reteniendo el copyright. |
| Lenguaje / runtime | `package.json` raíz: `"packageManager": "bun@1.3.14"`, `"private": true, "type": "module"`, monorepo de TypeScript con Bun (`bunfig.toml`, `bun.lock`). |
| TUI framework | Obra sobre `@opentui/core`, `@opentui/keymap`, `@opentui/solid` (catalog v0.4.5) — SolidJS sobre un renderer terminal. |
| Distribución | `install` script: descarga un único binario precompilado `opencode-{os}-{arch}[-baseline][-musl].{zip|tar.gz}` desde GitHub Releases. |
| Targets soportados por el instalador | Script `install`, selector de `combo`: solo `linux-x64`, `linux-arm64`, `darwin-x64`, `darwin-arm64`, `windows-x64`. Cualquier otro combo → `unsupported OS/Arch` + exit 1. |
| Binario CLI | `packages/opencode/package.json`: `"bin": { "opencode": "./bin/opencode" }`, `"version": "1.18.19"`. |
| PTY | `package.json` raíz catálogo: `"@lydell/node-pty": "1.2.0-beta.12"`, y `"postinstall": "bun run --cwd packages/core fix-node-pty"` → requiere construir node-pty nativo. |
| Subprocess | `"cross-spawn": "7.0.6"`. |
| FS / plataforma Node | `"@effect/platform-node": "4.0.0-beta.83"`, `"@parcel/watcher": "2.5.1"`, `"chokidar": "4.0.3"`. |
| SQLite Bun | `"@effect/sql-sqlite-bun": "4.0.0-beta.83"`, y `imports #db` con `bun: ./src/storage/db.bun.ts`. |
| tree-sitter (nativos) | `"tree-sitter-bash": "0.25.0"`, `"tree-sitter-powershell": "0.25.10"`, `"web-tree-sitter": "0.25.10"`. Listados en `trustedDependencies` del raíz (requieren build nativo). |
| Red / WS | `"ws": "8.21.0"`, `"bonjour-service": "1.3.0"` (mDNS), `@octokit/rest`, multitud de `@ai-sdk/*`. |
| Entorno POSIX | `install` lee `$SHELL`, `$HOME`, `$XDG_CONFIG_HOME`, `$TMPDIR`, `$PATH` y edita `.bashrc/.zshrc/...`. |
| Trusted natives | raíz `trustedDependencies`: `esbuild`, `node-pty`, `protobufjs`, `tree-sitter`, `tree-sitter-bash`, `tree-sitter-powershell`, `web-tree-sitter`, `electron` — todos requieren toolchain en build time. |

### Runtime contract del TUI de OpenCode (deducido)

Para que el binario de OpenCode arranque, el host debe exponer:

| # | Capability requerida | Fuente en OpenCode |
|---|---|---|
| C1 | Ejecutable nativo firmado para el ABI del host | `install` (selector de combo) |
| C2 | Runtime JavaScript compatible Bun 1.3.x | `package.json` `packageManager` + `@types/bun` |
| C3 | PTY (raw mode + escapes ANSI) | `@lydell/node-pty`, TUI `@opentui/*` |
| C4 | spawn/exec de procesos | `cross-spawn` |
| C5 | APIs `node:fs` + `fs.watch` + glob | `@effect/platform-node`, `@parcel/watcher`, `chokidar`, `minimatch`, `glob` |
| C6 | SQLite estilo Bun | `@effect/sql-sqlite-bun`, `#db` bun |
| C7 | Módulos nativos tree-sitter | `tree-sitter-*` en `trustedDependencies` |
| C8 | Red TLS + WebSocket + mDNS | `ws`, `bonjour-service`, `@octokit/rest`, `@ai-sdk/*` |
| C9 | Entorno POSIX (`$SHELL`, `$HOME`, `$XDG_CONFIG_HOME`, `$EDITOR`) | script `install` |
| C10 | TTY real (stdin/stdout/stderr con raw mode) | `@opentui/keymap`, render ANSI |



## 3. iOS — Qué expone y qué no (evidencia de plataforma)

Verificado contra el SDK iOS/Apple documentado y contra el sandbox:

| Capability iOS | Estado | Evidencia / Nota |
|---|---|---|
| Ejecutable arbitrario / spawn | **Imposible** | `Process`/`NSTask` NO están en el SDK iOS. El sandbox prohíbe `fork`/`execve`/`posix_spawn` de binarios arbitrarios. Solo el principal ejecutable firmado del bundle puede correr. |
| PTY / TTY | **Imposible** | Ninguna API pública en iOS expone PTY (`openpty`/`posix_openpt`) ni TTY crudo para stdin/stdout. Sin TTY, el renderer `@opentui` no puede dibujar. |
| Bun runtime en iOS | **No existe** | Bun publica builds para `linux/darwin/win x64+arm64` (ver `bunfig`/CI). No hay target `ios-arm64`. JavaScriptCore existe pero no implementa APIs `bun:*`/`node:*`. |
| tree-sitter nativo en iOS | **No existe prebuilt** | tree-sitter es C++; sus bindings JS requieren compilación por toolchain. iOS no trae toolchain. Cross-compilar + firmar cada módulo es un proyecto aparte. |
| Filesystem (sandbox) | **Posible** | `FileManager` en App Support / Documents / tmp. No se accede fuera del contenedor salvo via `UIDocumentPickerViewController` + security-scoped bookmarks. |
| File watching | **Limitado** | `DispatchSource.makeFileSystemObjectSource` solo para paths del sandbox. No equivalente a `@parcel/watcher` integral. |
| SQLite | **Posible (no-Bun)** | iOS trae SQLite del sistema; accesible vía C API, `GRDB`/`SQLite.swift`. No es la variante Bun.`@effect/sql-sqlite-bun`. |
| Red TLS / WS / localhost | **Posible** | `URLSession`, `URLSessionWebSocketTask`, `Network.framework` (`NWListener`, `NWConnection`). ATS exige HTTPS añadiendo excepciones. |
| mDNS (`bonjour-service`) | **Limitado** | `NetService`/`NWBrowser` existen; no equivalente exacto al módulo npm. |
| Entorno POSIX | **Ausente** | No hay `$SHELL`, `$HOME` POSIX, ni `.zshrc`. `setenv` funciona dentro del proceso pero sin shell cabe pensar. |
| LLM API remoto | **Posible** | `URLSession` async/await. No depende del host OpenCode; puede usarse desde runtime Swift alternativo. |
| Code signing | **Mac requerido** | Solo macOS (Xcode/`codesign`). El unsigned IPA se construye en GitHub Actions (macOS runner). |



## 4. COMPATIBILITY MATRIX — OpenCode req ↔ iOS

Legend: **POSIBLE** / **PARCIAL** (native alternative exists) / **IMPOSIBLE**.

| Req | Cap. iOS | Estado | Harness strategy |
|---|---|---|---|
| C1 Binario iOS | None | **IMPOSIBLE** | No se distribuye binario iOS. Un binario `darwin-arm64` no corre en iOS (ABI/ld/sandbox distintos). |
| C2 Runtime Bun | JavaScriptCore/WKWebView | **IMPOSIBLE** | JS puro sin APIs `bun:`/`node:`/`net:`/PTY. WCWebView no ejecuta el binario compilado Bun. |
| C3 PTY/TTY | None | **IMPOSIBLE** | No hay PTY. El renderer `@opentui` no puede operar. **HARD BLOCKER.** |
| C4 spawn/exec | None | **IMPOSIBLE** | No `node:child_process`. Sin `bash` tool real. **HARD BLOCKER.** |
| C5 `node:fs` + watch + glob | `FileManager` sandbox | **PARCIAL** | Solo sandbox. Sin `node:fs` per se; reimplementación Swift (ver `Sources/Workspace`, `Sources/Tools`). |
| C6 SQLite Bun | SQLite iOS | **PARCIAL** | SQLite del sistema vía Swift; no el paquete Bun. Persistencia reimplementada en `Sources/Persistence`. |
| C7 tree-sitter | None prebuilt | **IMPOSIBLE** | Sin parsers nativos. No hay syntax highlighting/AST real en iOS sin compilar tree-sitter para iOS. |
| C8 TLS/WS/localhost | URLSession + Network.fw | **POSIBLE** | Equivalente funcional disponible. |
| C9 Entorno POSIX | None | **IMPOSIBLE** | Sin shell/HOME/EDITOR. |
| C10 TTY real | None | **IMPOSIBLE** | Sin TTY crudo. **HARD BLOCKER.** |



## 5. VEREDICTO — Primer arranque

Resultado de un intento de boot en iOS:

- **C1**: No existe binario OpenCode para iOS. El instalador rechaza `ios-*`.
- **C2**: No existe Bun para iOS. El binario OpenCode está compilado *con* Bun; incluso suponiendo un cross-build Bun-iOS hipotético:
- **C3 + C10**: el TUI requiere **PTY/TTY** provistos por `@lydell/node-pty` y renderizados por `@opentui` con escapes ANSI. iOS no expone PTY ni TTY crudo. Sin estas APIs la TUI de OpenCode **no puede inicializar su pantalla**. Este es el **bloqueador histórico y sin solución** dentro del sandbox público de iOS.
- **C4**: la herramienta `bash` (que OpenCode expone como su tool por defecto del agente `build`) necesita `cross-spawn` ⇒ `Process()`, inexistente en iOS.

No se simula. Se documenta. **El TUI real de OpenCode no arranca en iOS.**

**Estado: BLOCKED — raíz: PTY/TTY + spawn/exec ausentes en iOS** combinadas
con la no-existencia de build Bun-iOS ni binario OpenCode iOS prebuilt.



## 6. HARNESS — Qué provee el runtime nativo de iOS del experimento

Dado el bloqueo, el experimento construye un runtime nativo Swift que **expone
las capacidades de iOS que sí existen** (C5/C6/C8) tras una capa de compatibilidad:
no pretende ser OpenCode, sino un *runtime alternativo nativo de iOS* que opera
sobre el mismo concepto (user → agent → tools → workspace sandbox → resultado).

| Cap. expuesta | Implementación Swift |
|---|---|
| Workspace sandbox | `Sources/Workspace/IOSWorkspace.swift` |
| Persistencia JSON/JSONL audit | `Sources/Persistence/IOSPersistence.swift` |
| Model provider LLM remoto | `Sources/Model/RemoteModelProvider.swift` |
| Tools de filesystem (8) | `Sources/Tools/FileSystemTools.swift` |
| Agent loop async | `Sources/Agent/AgentLoop.swift` |
| Probe de capability matrix en runtime | `Sources/Host/IOSCapabilityMatrix.swift` |
| Contrato declarado de OpenCode (evidence) | `Sources/Host/OpenCodeRuntimeContract.swift` |
| Reporte de compatibilidad | `Sources/Host/CompatibilityReport.swift` |
| Boot attempt documentado | `Sources/Host/OpenCodeBootAttempt.swift` |

Estos **no** son OpenCode; son la prueba práctica de qué parte del patrón puede
correr nativo en iOS.



## 7. CRITERIO DE TERMINADO DEL EXPERIMENTO

Resultados válidos definidos en el brief:

A) *OpenCode TUI real arranca y opera* — **NO alcanzado** (C3+C4+C10 imposibles).
B) *OpenCode TUI real arranca parcialmente y se documenta la capability exacta
   que impide completar* — **Alcanzado parcialmente**: el experimento demuestra que
   el *primer paso* (inicializar el TUI) ya es imposible por PTY/TTY + spawn/exec;
   el `OpenCodeBootAttempt` produce la evidencia de bloqueo en cada capability.



## 8. NOT ACCEPTED as Results

- "App that looks like OpenCode" — explicitly rejected.
- "Fake TUI" — `Sources/Host` does not create a TUI; it documents compatibility.
- "Fake shell/compiler" — does not simulate what does not exist.
- "Bun-iOS" without demonstration — out of scope.



## 9. OPEN ISSUES

`https://github.com/anomalyco/opencode/issues` — canal oficial para trackear
posibles vías (e.g. builds experimentales iOS) que, de existir, actualizarían
este documento.



## 10. ATTRIBUTION

OpenCode is &copy; anomalyco and contributors, licensed MIT
(`packages/opencode/package.json` → `"license": "MIT"`).
This project is not affiliated with OpenCode.
The name "OpencodeNative" clearly attributes the compatibility target.
OpenCode is used solely to describe the compatibility objective.
