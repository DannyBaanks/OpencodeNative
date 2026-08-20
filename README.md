# OpencodeNative iOS — Greenfield Experiment

Proyecto experimental para investigar qué partes de un runtime tipo OpenCode pueden ejecutarse **nativamente en iOS** usando Swift.

## Pregunta Experimental

> ¿Hasta dónde puede llegar un runtime de agente escrito en Swift y ejecutándose dentro de un iPhone, sin depender de otro ordenador?

## Estado Actual: FASE 1-7 COMPLETADAS

| Fase | Componente | Estado |
|---|---|---|
| FASE 0 | Investigación entorno | ✅ Completada |
| FASE 1 | Skeleton Swift / Xcode project | ✅ Completada |
| FASE 2 | Workspace abstraction | ✅ Completada |
| FASE 3 | Persistence (JSONL) | ✅ Completada |
| FASE 4 | ModelProvider (API remota) | ✅ Completada |
| FASE 5 | Agent Loop | ✅ Completada |
| FASE 6 | Tools (read/write/list/search/etc) | ✅ Completada |
| FASE 7 | SwiftUI mínima | ✅ Completada |
| FASE 8 | Tests | ⏳ Pendiente |
| FASE 9 | GitHub Actions + iloader | ✅ Workflow creado |
| FASE 10 | Informe final | ⏳ Pendiente |

## Arquitectura

```
┌─────────────────────────────────────────────────────────────┐
│                     OpencodeNative App                      │
├─────────────────────────────────────────────────────────────┤
│  SwiftUI UI                                                 │
│    ├── ContentView (chat + tool calls + workspace picker)   │
│    ├── SettingsView (config)                                │
│    └── CapabilitiesView (matriz de capacidades iOS)         │
├─────────────────────────────────────────────────────────────┤
│  Core Runtime                                               │
│    ├── AgentLoop (user→model→tools→result→model→response)   │
│    ├── ModelProvider (RemoteModelProvider + stub CoreML)    │
│    ├── ToolExecutor (FileSystemToolExecutor)                │
│    │    ├── read_file    ✅                                  │
│    │    ├── write_file   ✅                                  │
│    │    ├── list_directory ✅                                │
│    │    ├── search_files ✅                                  │
│    │    ├── file_info    ✅                                  │
│    │    ├── create_directory ✅                              │
│    │    ├── delete_file  ✅                                  │
│    │    └── move_file    ✅                                  │
│    ├── Workspace (IOSWorkspace - sandboxed FileManager)     │
│    └── Persistence (IOSPersistence - JSONL en App Support)  │
├─────────────────────────────────────────────────────────────┤
│  iOS Platform                                               │
│    ├── FileManager (App Support, Documents, tmp)            │
│    ├── URLSession / NWListener (network)                    │
│    ├── UserDefaults / JSON / JSONL (persistence)            │
│    ├── WKWebView (opcional, para JS/WASM)                   │
│    └── CoreML (stub para modelos on-device)                 │
└─────────────────────────────────────────────────────────────┘
```

## Matriz de Capacidades iOS (Resumen)

| Capability | iOS | Restricción Principal |
|---|---|---|
| **Filesystem (read/write/list/create/move/delete)** | ✅ | Solo sandbox (App Support, Documents, tmp) |
| **Search files (glob)** | ✅ | Implementado en Swift, glob patterns |
| **File watching** | ⚠️ | DispatchSource limitado a directorios propios |
| **Security bookmarks** | ⚠️ | Requiere user picker + entitlement |
| **Process execution** | ❌ | **IMPOSIBLE** - sandbox prohíbe fork/exec |
| **Shell/bash/git/python** | ❌ | **IMPOSIBLE** - no hay terminal/PTY |
| **Compile code** | ❌ | **IMPOSIBLE** - sin toolchain |
| **Model API remoto** | ✅ | URLSession, requiere red + API key |
| **Model CoreML on-device** | ✅ | CoreML, modelos <2GB, solo inference |
| **Persistence (JSON/JSONL)** | ✅ | App Support, ilimitado |
| **Network (localhost)** | ✅ | NWListener en 127.0.0.1 |
| **Network (externo)** | ✅ | URLSession + ATS |
| **WKWebView JS/WASM** | ✅ | Solo JS, sin filesystem directo |
| **Code signing** | ❌ Windows | Requiere macOS (GitHub Actions) |

## Conclusión Experimental (Preliminar)

**Un runtime tipo OpenCode SÍ puede ejecutarse nativamente en iOS para:**

1. ✅ **Filesystem completo dentro del sandbox**
2. ✅ **Agent loop completo** (async/await nativo)
3. ✅ **Tools declaradas explícitamente** (8 tools de filesystem)
4. ✅ **Model providers via API remota** (OpenAI-compatible)
5. ✅ **Persistencia local completa** (JSON + JSONL audit trail)
6. ✅ **UI nativa SwiftUI** con tool calls visibles

**NO puede (sin backend externo):**

1. ❌ **Ejecutar código arbitrario** (shell, python, git, compiladores)
2. ❌ **Terminal real / PTY**
3. ❌ **Operaciones fuera del sandbox**
4. ❌ **Code signing en Windows** (requiere macOS)

## Requisitos

- **macOS** con Xcode 15+ (para compilar)
- **GitHub Actions** (macOS runners) para CI/CD
- **Apple ID** + **SideStore** / **AltStore** para instalar en device
- **iOS 16.0+** en device

## Compilación Local (macOS)

```bash
# 1. Instalar XcodeGen
brew install xcodegen

# 2. Generar proyecto Xcode
cd OpencodeNative
xcodegen generate

# 3. Abrir en Xcode
open OpencodeNative.xcodeproj

# 4. Build para device (Requiere signing)
# Product → Build (⌘B)
# Product → Archive → Distribute App → Ad Hoc / Development
```

## Compilación via GitHub Actions (Recomendado)

El workflow `.github/workflows/ios-build.yml` hace:

1. **build job**: Compila unsigned IPA en macOS runner
2. **test job**: Validación de sintaxis Swift
3. **sign job** (opcional): Firma con iloader si configuras secrets
4. **capability-report job**: Genera matriz de capacidades

### Secrets requeridos para signing automático:
- `APPLE_ID`: Tu Apple ID
- `TEAM_ID`: Tu Team ID de Apple Developer

### Para firmar manualmente con iloader:

```bash
# 1. Descargar unsigned IPA de GitHub Actions artifacts
# 2. Instalar iloader
pip3 install --user iloader

# 3. Firmar
python3 -m iloader sign \
  --apple-id "tu@email.com" \
  --team-id "ABC123DEFG" \
  OpencodeNative-unsigned.ipa \
  -o OpencodeNative-signed.ipa

# 4. Instalar con SideStore en el iPhone
```

## Instalación en Device

1. **SideStore** (recomendado, gratis, 7 días / renovable)
   - Instalar SideStore en iPhone via AltStore o Web
   - Abrir SideStore → + → Seleccionar IPA firmada
   
2. **AltStore** (gratis, 7 días)
   - Instalar AltStore en Mac/PC + iPhone
   - AltStore → My Apps → + → Seleccionar IPA

3. **Apple Configurator 2** (Mac, requiere USB)
   - Conectar iPhone → Apps → + → Seleccionar IPA

## Estructura del Proyecto

```
OpencodeNative/
├── .github/workflows/ios-build.yml    # GitHub Actions CI/CD
├── .iesyroot                          # Marker raíz proyecto
├── project.yml                        # XcodeGen config
├── Info.plist                         # Config app
├── Assets.xcassets/                   # App icon
├── LocalPacks/                        # Packs embebidos (futuro)
├── Sources/
│   ├── OpencodeNativeApp.swift        # Entry point
│   ├── Core/                          # (reserved)
│   ├── Workspace/
│   │   └── Workspace.swift            # IOSWorkspace + protocolo
│   ├── Persistence/
│   │   └── Persistence.swift          # IOSPersistence + JSONL
│   ├── Model/
│   │   └── ModelProvider.swift        # RemoteModelProvider + CoreML stub
│   ├── Agent/
│   │   └── AgentLoop.swift            # Agent loop + context
│   ├── Tools/
│   │   └── FileSystemTools.swift      # 8 tools filesystem
│   └── UI/
│       ├── ContentView.swift          # Chat + workspace picker + settings
│       └── ChatViewModel.swift        # ViewModel + integración runtime
```

## Próximos Pasos (FASE 8-10)

- [ ] Tests unitarios para cada capability
- [ ] Test de integración: agente lee → modifica → verifica archivo
- [ ] Implementar CoreML provider real (llama.cpp quantizado)
- [ ] Git via libgit2 compilado para iOS (opcional)
- [ ] Documentar limitaciones encontradas en tests reales
- [ ] Generar informe final FASE 10

## Licencia

Experimental - Sin licencia definida aún.

---

**Nota**: Este es un experimento de investigación. No es un clon de OpenCode. El objetivo es descubrir **qué es posible** en iOS nativamente, documentando cada limitación encontrada con evidencia de código.