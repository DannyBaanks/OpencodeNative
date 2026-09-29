# GUS Móvil + Qwen local — preflight iPhone 12

**Dictamen: GO para diseñar/implementar el proveedor y descarga bajo demanda; BLOCKED para compilar esta rama y validar en el teléfono hasta que se pueda ejecutar Actions y hacer la prueba física.**

Este documento registra lo que se confirmó antes de tocar el runtime, el modelo o
los permisos. No afirma que Qwen funcione en iOS ni en un iPhone.

## Estado inspeccionado

| Elemento | Evidencia | Estado |
| --- | --- | --- |
| Worktree de trabajo | `codex/gus-ios-iphone12-handoff`, HEAD `3649e706c76674bac9692906e76f1efaaf196189` | Limpio al comenzar |
| Base del producto | `3649e706c76674bac9692906e76f1efaaf196189` | Coincide con el handoff |
| Worktree previo de GUS | `/home/danny/.codex/worktrees/isycode-movil-gus-role`, detached en `bb46249` | Inspeccionado; queda intacto |
| Modelo | `Qwen/Qwen1.5-1.8B-Chat-GGUF`, Q4_K_M, 1,217,752,928 bytes | Archivo local y SHA-256 verificados |
| SHA-256 | `702e983c77883426806a2af75d34ab3e462e1b822f9dc23b49e02280c24b2b18` | Coincide con el handoff |
| Inferencia Linux | llama.cpp `842b1880415d6f508f03b789e5ce70194def7bfd`; 2K: 1.22 s / 2,091 MiB; 4K: 1.41 s / 2,475 MiB | Evidencia reportada; no representa iOS |
| iPhone objetivo | iPhone 12, iOS 18.7.8, confirmado por el usuario | Sin conexión física observable desde este entorno |
| Herramientas Apple locales | `xcodebuild`, `xcrun` y `swift` no están disponibles; entorno Linux x86_64 | No se puede compilar localmente; no impide compilar en Actions |
| CI/IPA | Workflow `.github/workflows/ios-build.yml` compila en `macos-latest`; IPA unsigned se crea allí | No ejecutado para esta rama; el handoff prohíbe hacer push |

## Hallazgos de arquitectura y permisos

- El producto declara iOS 16.0 en `project.yml`. El script oficial de
  `llama.cpp` fijado en el handoff declara iOS mínimo 16.4 y activa Metal. El
  iPhone objetivo con iOS 18.7.8 cumple ese mínimo, pero elevar el mínimo del
  producto excluiría iOS 16.0–16.3 para el resto de usuarios. Documentar ese
  impacto antes de aplicarlo.
- `NativeSwiftBackend.installLoop` envía solicitudes de permiso a la interfaz y
  espera una decisión asociada a la solicitud. El `NativeCapabilityToolExecutor`
  exige `allowOnce`/`allowAlways` antes de ejecutar capacidades nativas y el
  broker verifica disponibilidad y autorización del sistema.
- `SessionViewModel.initRuntime` tiene otra ruta de agente con prompt distinto
  y un handler que concede `allowOnce` automáticamente. Esa ruta no es apta para
  evaluar GUS con aprobaciones reales hasta reemplazar el bypass por una espera
  explícita que falle cerrada. Este trabajo no debe ampliar las capacidades.
- El worktree previo contiene un borrador de `GUSMobileRole` conectado solo a
  `NativeSwiftBackend`, además de un test nuevo. No se copió ni se modificó.
- El repositorio no contiene el GGUF ni una integración `llama.cpp`/XCFramework.
  El diseño acordado descarga el archivo desde Hugging Face bajo demanda en el
  iPhone; el IPA y los artefactos de CI no llevarán los pesos.

## Plan de implementación

1. En un host macOS con Xcode, generar el proyecto y confirmar que el XCFramework
   se integra y compila con Metal para dispositivo y simulador. Fijar el commit
   `842b1880415d6f508f03b789e5ce70194def7bfd`; no invocar CLI ni `Process`.
2. Centralizar el rol/system prompt para que los dos caminos que puedan iniciar
   una sesión usen la misma definición. La ruta de consola debe pasar por la
   aprobación visible del harness; sin handler o ante cancelación, denegar.
3. Agregar Qwen como una opción local explícita y una descarga bajo demanda
   desde el commit fijo `07800fcba6d5d1df3dfa36e3763374a2c0d9f91b` de Hugging
   Face. El modelo se guarda solo en el contenedor privado de la app y el IPA
   permanece sin los pesos. Mantener separados el demo offline y providers
   remotos; la inferencia local nunca envía prompts, archivos ni telemetría.
4. Priorizar contexto 2K. Ofrecer 4K solo como perfil experimental después de
   medir memoria real en el iPhone. No ofrecer 32K con KV FP16: la estimación del
   handoff es ~6 GiB para KV por sí solo.
5. No guardar ni empaquetar el peso en Git, IPA o artefactos rutinarios de CI.
   Hacer que la app descargue una URL fijada e inmutable tras una acción
   explícita, limite el tamaño, valide SHA-256 y promueva el archivo de forma
   atómica. Mostrar licencia/atribución exacta, commit y tamaño antes de
   descargar; incluir licencia y `Notice` en app y documentación.
6. Resolver explícitamente el deployment target: el XCFramework elegido exige
   iOS 16.4, frente al 16.0 actual. Confirmar el impacto y registrar el cambio
   en notas antes de subir el mínimo; no ocultarlo en un script.
7. Ejecutar CI desde una rama publicada/permitida, registrar logs, tests, hash,
   tamaño de IPA y tamaño del modelo. La CI del simulador no cuenta como prueba
   del teléfono.
8. Instalar en el iPhone 12 y observar carga, inferencia, cancelación,
   memoria/presión, latencia y ausencia de tráfico remoto. Mantener 2K como
   opción conservadora; 4K y cualquier KV cuantizado necesitan mediciones
   propias. Marcar como BLOCKED todo paso sin dispositivo o evidencia.

## Bloqueos de verificación pendientes

- Publicar/ejecutar el workflow sobre la rama aislada (nunca sobre `main`);
  el handoff actual prohíbe hacer push.
- Disponer del iPhone 12 con iOS 18.7.8 y un método autorizado para instalar la
  build de desarrollo.
- Revisar el cambio de mínimo iOS 16.0 → 16.4 y el mecanismo final para obtener
  y distribuir el GGUF con sus notices.

Hasta cumplir estas condiciones, no integrar pesos ni afirmar que el modelo
local está soportado en iPhone.
