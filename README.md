# OpencodeNative — OpenCode TUI Compatibility Harness for iOS

> Experimento de compatibilidad: puede el **TUI real de OpenCode**
> arrancar sobre un runtime nativo de iOS vía una capa de compatibilidad.
> **Evidence before narrative.** Ninguna afirmación se sostiene sin evidencia.

## ⚠️ IMPORTANTE — atribución

OpenCode es © anomalyco y contribuidores, licencia MIT (ver `docs/OPENCODE_COMPAT.md` §10).
Este proyecto **NO es OpenCode** y **no está afiliado** al equipo de OpenCode.
OpenCodeNative es un *experimento de compatibilidad* que importa el runtime de OpenCode
como objeto de estudio, no como producto.

No uses OpenCode en el nombre de tu proyecto derivado sin aclarar que no es oficial.

---

## Estado actual

**Veredicto experimental: `BLOCKED` — el TUI real de OpenCode NO arranca en iOS.**

| | |
|---|---|
| **Compat con OpenCode TUI** | `BLOCKED` — ver `docs/OPENCODE_COMPAT.md` |
| **Primera causa de bloqueo** | PTY/TTY + spawn/exec + runtime Bun ausentes en iOS |
| **Runtime nativo alternativo** | `Partial` — `AgentLoop` Swift + 8 tools fs + provider (scripted / remote) |
| **Tests** | 8 suites en `Tests/` (corren en iOS Simulator vía CI) |

No existe tal cosa como "OpenCode funcionando en iOS". Lo que existe es:
- un *compatibility harness* que documenta exactamente por qué no,
- un *runtime nativo alternativo* (no OpenCode) que opera el flujo
  `usuario → agente → tools → workspace sandbox → resultado` dentro de iOS.



## ¿De qué va este repo?

```
iPhone
   │
OpenCodeNative (app iOS)
   │
native iOS runtime  ─── compatibility harness ─── capability matrix
   │
Reports: PTY/TTY/spawn/Bun no existen en iOS → TUI real no arranca
   │
Alternativa: agent runtime Swift (no OpenCode) sobre sandbox iOS
```

**No es una "app de chat parecida a OpenCode".** Las UI son una consola
TUI-first que muestra el boot attempt documentado y, por separado, ejecuta
el runtime alternativo nativo etiquetado claramente como tal.



## Estructura

```
Sources/
├── OpencodeNativeApp.swift        Entry (SwiftUI)
├── Host/                          Capa de compatibilidad + matrix
│   ├── OpenCodeRuntimeContract.swift   Gunks de OpenCode (evidence)
│   ├── IOSCapabilityMatrix.swift       Probe runtime experiencias iOS
│   ├── CompatibilityReport.swift       Reconcilia contrato ↔ matrix
│   └── OpenCodeBootAttempt.swift       Boot attempt documentado
├── Agent/AgentLoop.swift          Runtime alternativo nativo (no OpenCode)
├── Model/ModelProvider.swift      LLM remoto (OpenAI-compatible)
├── Model/ScriptedModelProvider.swift  Offline demo sin API key
├── Workspace/Workspace.swift      FS sandbox iOS
├── Persistence/Persistence.swift  JSON + JSONL audit trail
├── Tools/
│   ├── FileSystemTools.swift      8 tools fs
│   └── GlobMatcher.swift          glob matcher puro (public)
└── UI/
    ├── SessionViewModel.swift     Transcripts + boot + agent events
    └── ConsoleView.swift          Consola TUI monospace

Tests/
├── GlobMatcherTests.swift
├── HostTests.swift                CapabilityReport + BootAttempt
└── CoreEndToEndTests.swift        WS / Persistence / Tools / Agent E2E

docs/
├── OPENCODE_COMPAT.md             Contrato + matrix + veredicto
├── IOS_LIMITATIONS.md             Capacidades iOS exactas
└── USAGE.md                        Cómo usar / demo
```



## Compilación (mismo pipeline que antes, revisado)

- macOS + Xcode 15+ (no puede compilarse iOS en Windows/Linux).

```bash
brew install xcodegen
xcodegen generate
open OpencodeNative.xcodeproj
# Product → Build (⌘B) → run on iOS Simulator
# Product → Test  (⌘U) → run the OpencodeNativeTests bundle on the simulator
```

### CI (`.github/workflows/ios-build.yml`)

- `build`: unsigned IPA para iOS device (macos runner) — como antes.
- `test`: **`xcodebuild test` en iOS Simulator** (no más "syntax check only").
  Ejecuta los tests del target `OpencodeNativeTests`.
- `capability-report`: genera `CAPABILITY_MATRIX.md`.



## Tests rápidos en local

- iOS Simulator (macOS): `xcodebuild test -scheme OpencodeNative -destination 'platform=iOS Simulator,name=iPhone 15'`.
- En Windows / toolchain sin XCTest/Xcode: solo se puede `swiftc -parse` los `.swift`.
  El repo se valida así desde PowerShell: ver `docs/USAGE.md` §"Verificación sin Xcode".



## Documentación

- `docs/OPENCODE_COMPAT.md` — análisis completo del contrato OpenCode + matrix iOS.
- `docs/IOS_LIMITATIONS.md` — capacidades iOS exactas y qué no se simula.
- `docs/USAGE.md` — demo reproduible + comandos slash del TUI.



## Licencia

- Código propio de este repo: experimental, sin licencia formal.
- OpenCode (anomalyco) referenciado: MIT; ver `docs/OPENCODE_COMPAT.md` §10.
