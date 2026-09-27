# iSyCode Móvil para iPhone

### Tu entorno de desarrollo y tus agentes, en el bolsillo.

iSyCode Móvil es una app nativa para iPhone que se conecta a herramientas de desarrollo que ya corren en tu computadora. También incluye un sandbox Swift para probar agentes y trabajar con archivos que tú le concedas desde **Archivos**.

> **En corto:** el iPhone muestra el chat, el streaming y las aprobaciones; el runtime conectado ejecuta el trabajo. El sandbox local es otra opción para experimentar directamente en el teléfono.

[![iOS Build](https://github.com/DannyBaanks/iSyCodeMovil/actions/workflows/ios-build.yml/badge.svg?branch=main)](https://github.com/DannyBaanks/iSyCodeMovil/actions/workflows/ios-build.yml)
[Descargar para iPhone](#instalar-en-tu-iphone) · [Conectar OpenCode](#conectar-opencode) · [Qué puede hacer](#qué-puedes-hacer)

---

## Así se ve

Esta pantalla de inicio se captura automáticamente en un **iPhone Simulator de GitHub Actions** con datos limpios; no es una captura de un dispositivo personal. Desde aquí puedes conectar un host o abrir la tarjeta **Entorno de prueba** para entrar al sandbox.

![Pantalla de conexión y acceso al sandbox, generada por CI](docs/screenshots/connect.png)

El workflow genera la captura y la publica como el artefacto **IysCodeMovil-ci-screenshots**.

---

## Empieza en tres pasos

### 1. Descarga la app

1. Abre [Actions → iOS Build](https://github.com/DannyBaanks/iSyCodeMovil/actions/workflows/ios-build.yml).
2. Entra a la última corrida verde de `main`.
3. En **Artifacts**, descarga `IysCodeMovil-unsigned` y extrae el `.ipa`.

El CI compila una app sin firmar. Para instalarla en un iPhone, fírmala con tu Apple ID usando [iloader](https://iloader.app/), [SideStore](https://sidestore.io/) o [AltStore](https://altstore.io/). Con una cuenta Apple gratuita, la firma suele caducar a los siete días; vuelve a firmar la app cuando iOS lo pida.

### 2. Elige cómo conectarte

- **Una computadora con OpenCode:** usa el Bridge de abajo y pega en la app el enlace `iyscodemovil://...` que imprime.
- **Una computadora con Codex:** usa el modo experimental de Codex por Tailscale; revisa sus límites en [Conectar Codex](docs/REMOTE.md#experimental-codex-app-server).
- **Probar en el iPhone:** en la pantalla de conexión elige **Usar sandbox**. No requiere emparejamiento ni una clave para abrir el demo offline.

### 3. Empieza a trabajar

Abre una sesión, escribe un mensaje y sigue la respuesta en el chat. En los runtimes remotos, los comandos, cambios de archivos y permisos los administra el runtime de la computadora. En el sandbox, el acceso empieza dentro del contenedor de iOS; puedes conceder una carpeta desde Archivos.

---

## Conectar OpenCode

Necesitas Node.js 18 o posterior, OpenCode instalado en la computadora y el iPhone en una red que pueda alcanzar esa computadora.

En una terminal, entra a la carpeta del proyecto que quieres abrir y ejecuta:

```bash
npx --yes github:DannyBaanks/IysCodeMovil#main link
```

El Bridge inicia `opencode serve`, genera una credencial temporal y muestra un enlace de emparejamiento. Copia el enlace completo y pégalo en iSyCode Móvil. Mantén el proceso del Bridge abierto mientras uses la sesión.

Para conectar OpenISy en vez de OpenCode:

```bash
npx --yes github:DannyBaanks/IysCodeMovil#main link \
  --runtime openisy \
  --openisy-root "/ruta/a/OpenISy"
```

### ¿Estás fuera de casa?

Usa una VPN privada como Tailscale entre el iPhone y la computadora. El Bridge OpenCode incluido usa HTTP con autenticación Basic; úsalo solo en una red de confianza o dentro de una VPN cifrada. **No expongas el puerto 4096 directamente a Internet.**

Detalles y transporte: [guía de conexión remota](docs/REMOTE.md).

---

## Sandbox del iPhone

El sandbox ejecuta un agente Swift nativo en el contenedor privado de iOS. Puedes:

- Probar el flujo demo sin conectarte a Internet ni configurar un modelo.
- Conectar una API compatible para usar un modelo remoto.
- Conceder una carpeta desde Archivos con el selector oficial de iOS; el permiso puede revocarse en Settings.
- Ver y aprobar operaciones que cambian archivos antes de ejecutarlas.
- Adjuntar archivos seleccionados mediante la interfaz de iOS.

Las claves API configuradas por la app se guardan en el Keychain. Si eliges un modelo en la nube, el contenido que envíes y los archivos que el agente lea pueden salir del teléfono hacia ese proveedor.

### Modelos del sandbox

El catálogo incluye NVIDIA NIM, xAI, OpenAI API, Google Gemini y OpenRouter. Los modelos disponibles dependen de la cuenta y de lo que anuncie el endpoint `/models` de cada proveedor. La suscripción de ChatGPT **no** incluye crédito de OpenAI API.

Para empezar, abre **Proveedores** en el selector del sandbox, elige un proveedor y agrega su clave. La app la conserva en el Keychain de ese iPhone.

---

## Qué está listo y qué sigue experimental

| Conexión | Estado | Qué ofrece |
| --- | --- | --- |
| Sandbox local | Disponible | Agente Swift, archivos dentro del contenedor o una carpeta concedida, catálogo de API providers y permisos por operación. |
| OpenCode remoto | Disponible | Sesiones reales, streaming, historial, ejecución remota y solicitudes de permiso de OpenCode. |
| OpenISy remoto | Disponible mediante Bridge | Usa el contrato compatible con el servidor headless de OpenCode. |
| Codex App Server | Experimental | Chat, streaming, continuidad de thread e interrupt; solo cubre el perfil descrito en la guía. |
| Crush, Claude Code, Gemini CLI | No disponibles como runtimes remotos | Hay nombres/adaptadores planificados, pero no se deben tratar como conectores funcionales todavía. |
| Host móvil `/v1` | Emparejamiento y estado básicos | El contrato actual cubre health, pairing, heartbeat e inventario; todavía no ofrece sesiones remotas ni MCP. |
| Servidor MCP de ChatGPT | No disponible aún | Requiere un endpoint remoto y un contrato del host; la app iOS no puede instalarlo por sí sola. |

### Límites de iOS

El TUI real de OpenCode no corre dentro del iPhone: iOS no ofrece el PTY/TTY, `spawn/exec` ni Bun que necesita. La app es una interfaz nativa para runtimes que corren en una computadora, además de un runtime Swift propio para el sandbox local. No puede leer los datos privados de otras apps ni automatizar libremente sus pantallas.

Más detalle con evidencia: [compatibilidad de OpenCode en iOS](docs/OPENCODE_COMPAT.md) · [limitaciones de iOS](docs/IOS_LIMITATIONS.md).

---

## Si algo no funciona

| Lo que ves | Qué revisar |
| --- | --- |
| `Could not connect to the server` | En el iPhone no uses `127.0.0.1` para llegar a tu computadora: usa la IP de LAN o Tailscale que muestra el Bridge. Confirma que siga ejecutándose. |
| El enlace no abre la app | Copia el enlace completo `iyscodemovil://...`; si hace falta, pégalo en la pantalla de conexión. |
| `Rate limited` | El proveedor rechazó temporalmente llamadas por cuota o frecuencia. Espera el tiempo indicado, revisa la cuota de esa API y evita reenviar el mismo mensaje varias veces. |
| La app no instala | Revisa que el IPA esté firmado y que confiaste en tu Apple ID en Ajustes → General → VPN y administración de dispositivos. |
| El sandbox no ve mi carpeta | Selecciónala desde el picker de Archivos dentro de la app. iOS no permite navegar libremente por todas las carpetas del teléfono. |
| Codex muestra `initialize` o desconecta | Asegúrate de usar una versión de Codex compatible con el perfil del Bridge. Detalles y límites: [guía experimental de Codex](docs/REMOTE.md#experimental-codex-app-server). |

---

## Compilar desde el código

Necesitas macOS, Xcode y [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
xcodegen generate
open IysCodeMovil.xcodeproj
```

En Xcode, elige un iPhone Simulator o un dispositivo conectado y presiona **Run**. También puedes compilar desde terminal:

```bash
xcodebuild -scheme IysCodeMovil \
  -destination 'generic/platform=iOS Simulator' \
  build
```

Cada push a `main` compila la app, corre las pruebas en iOS Simulator y genera capturas de las pantallas para este README.

---

## Para contribuir

- [Roadmap de runtimes CLI](docs/ROADMAP_CLIS.md)
- [Uso detallado](docs/USAGE.md)
- [Contrato del Bridge remoto](docs/REMOTE.md)
- [Reporte de compatibilidad](docs/OPENCODE_COMPAT.md)

El proyecto está bajo licencia MIT; consulta [LICENSE](LICENSE). iSyCode Móvil no está afiliado con OpenCode, Codex, Anthropic, Google, xAI, NVIDIA, OpenRouter ni OpenAI.
