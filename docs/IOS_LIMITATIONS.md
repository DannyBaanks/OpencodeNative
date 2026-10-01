# iOS — Limitaciones reales (no se simulan)

> Capacidades iOS verificadas durante este experimento. **No se finge ninguna
> capacidad inexistente**. Lo que no puede hacerse se marca como tal.

## A. Nodos bloqueantes para el OpenCode TUI REAL

| Capability | Estado iOS | Por qué |
|---|---|---|
| PTY/TTY | **Imposible** | No hay API `openpty`/`posix_openpt` expuesta en iOS SDK. El sandbox prohíbe raw TTY sobre stdin/stdout. Sin PTY, `@lydell/node-pty` y el renderer `@opentui` no operan. |
| spawn/exec de procesos | **Imposible** | `Process`/`NSTask` no existen en el SDK iOS. El sandbox prohíbe `fork`/`execve`/`posix_spawn` de binarios arbitrarios (solo el ejecutable principal firmado del bundle se ejecuta). |
| Runtime Bun | **Imposible** | Bun publica builds para `linux/darwin/win × {x64,arm64}`; no hay target Bun `ios-arm64`. JavaScriptCore/WKWebView ejecutan JS puro pero no implementan `bun:*`/`node:*`/`net:*`/PTY. |
| Binario OpenCode para iOS | **No existe** | El script `install` de OpenCode solo admite `linux/darwin/win × {x64,arm64}`; cualquier otro combo → `unsupported OS/Arch` + exit 1. |
| tree-sitter nativo | **Imposible sin Mac** | tree-sitter es C++; los bindings npm requieren compilación. No hay toolchain en iOS. |
| Entorno POSIX (SHELL/HOME/EDITOR) | **Imposible** | iOS no tiene shell ni `$HOME` POSIX ni `.zshrc`. |
| Compilar/correr código nativo en device | **Imposible** | Sin toolchain ni ejecución de procesos. |

## B. Capacidades iOS efectivamente disponibles (sin simular)

| Capability | Cómo se expone en este runtime |
|---|---|
| Filesystem sandbox | `FileManager` en App Support / Documents / tmp. Ver `Sources/Workspace`. |
| File watching | `DispatchSource.makeFileSystemObjectSource` solo para paths del sandbox. |
| Security-scoped bookmarks | `UIDocumentPickerViewController` + `URL.startAccessingSecurityScopedResource`. No usado aún en el harness. |
| SQLite | SQLite del sistema vía C API / GRDB / SQLite.swift / CoreData. |
| Red TLS | `URLSession` + ATS. |
| WebSocket | `URLSessionWebSocketTask`. |
| localhost server | `Network.NWListener` en `127.0.0.1`. |
| LLM API remoto | `URLSession` a cualquier API OpenAI-compatible. |
| Keychain | `SecItem*` (hardware-backed). No usado para API keys todavía. |

## C. Lo que el runtime nativo alternativo (no OpenCode) hace

- 14 tools de filesystem para miniagente: lectura/listado/metadatos, `read_file_range`, búsqueda por archivo y por líneas (`search_files`/`search_text`), escritura completa, edición exacta (`edit_file`), reemplazo por rango (`replace_lines`), append, copia, creación de carpetas, move/rename y borrado.
- Todas las mutaciones (`write_file`, `edit_file`, `replace_lines`, `append_file`, `copy_file`, `create_directory`, `move_file`, `delete_file`) pasan por una aprobación visible nueva para cada operación, incluso si antes se eligió permitir siempre.
- El agente queda confinado al workspace activo; las rutas siguen pasando por `Workspace` y no obtienen shell ni ejecución de procesos.
- GUS local puede proponer una única tool del catálogo del turno mediante un formato etiquetado y validado fail-closed. JSON malformado, tools no anunciadas, campos extra o tipos incorrectos se quedan como texto y no se ejecutan.
- Agente async con loop, multi-turn tool calls, persistencia JSONL.
- Provider LLM remoto, GUS local **o** provider scripteado offline para demo/tests.

## D. Qué se DELIBERADAMENTE queda fuera (no es falta de control)

- Imitar la terminal/PTY de OpenCode con escapes ANSI fake — fuera; no simula lo inexistente.
- "Bash tool" sin PTY — no se entrega como fake; el miniagente móvil trabaja con la superficie de filesystem y las capacidades nativas explícitamente proyectadas por la app.
- Compilar libgit2 o tree-sitter para iOS — fuera del alcance de este experimento.
- App móvil convencional con chips/bubbles — reemplazada por consola TUI-first.

## E. Addendum: sandbox del iPhone

- El runtime puede usar una carpeta externa seleccionada por el usuario en el
  picker de Archivos. iSyCode guarda el bookmark entregado por iOS en Keychain y conserva
  el acceso solo mientras el workspace nativo está abierto; el usuario puede
  cambiar o revocar la carpeta.
- El agente queda confinado a esa raíz. El acceso no se extiende a carpetas
  vecinas, datos privados de otras apps ni al sistema. File Provider I/O se
  coordina con `NSFileCoordinator`; todas las mutaciones de archivos continúan sujetas a
  una aprobación visible por operación.
- Si se usa un modelo remoto, el contenido de archivos que el agente lea puede
  viajar al proveedor configurado. La UI lo informa antes de conceder acceso.
- Con GUS local, la inferencia y los tool-calls permanecen en el dispositivo; una tool solo recibe la autoridad que la app ya expuso para ese turno y el workspace activo.
- No hay permiso general para leer la pantalla, automatizar taps o controlar
  otras apps. La vía soportada para acciones entre apps es la superficie que
  cada app exponga mediante App Intents, Atajos o el picker/hoja Compartir.
