# Especificación: Codex App Server remoto para ISyCodeMovil

**Estado:** aprobado; implementación parcial y experimental
**Fecha:** 2026-09-27
**Alcance:** primer adapter funcional de Codex, como hito inicial de la hoja de ruta de CLIs.

## Objetivo

Permitir que ISyCodeMovil se conecte desde iOS a una instancia de Codex que corre
en la computadora del usuario, inicie y reanude conversaciones, envíe prompts,
muestre la respuesta mientras llega, permita cancelar y responda solicitudes de
aprobación. Codex debe seguir ejecutándose en la computadora; la app no ejecuta
el CLI ni herramientas de shell en iOS.

## Diseño aprobado

- Usar `codex app-server` con JSON-RPC como protocolo de Codex. No presentar el
  App Server como si implementara la API HTTP de OpenCode.
- El Bridge del host inicia y supervisa el App Server. El adapter de iOS se
  comunica con el endpoint WebSocket del App Server y traduce el protocolo a los
  modelos de `WorkbenchBackend` que consume la app.
- Usar un token de capacidad aleatorio, específico para el pairing, con el
  mecanismo de autenticación WebSocket del App Server. El secreto se entrega
  mediante el flujo de pairing y se guarda en el almacenamiento seguro de iOS;
  no se registra en logs ni se presenta en mensajes de error.
- Marcar esta integración como **experimental**. El transporte WebSocket remoto
  del App Server está señalado por Codex como experimental y no apto para uso de
  producción. La v1 se limita a una red local confiable o VPN/Tailscale. No debe
  anunciarse como acceso seguro por Internet público.

## Flujo principal

1. En el host, el Bridge detecta Codex, inicia `codex app-server` con listener
   WebSocket y autenticación por capability token, y supervisa su salida y
   disponibilidad.
2. El Bridge crea el pairing con host, puerto, workspace y token. El enlace debe
   identificar `codex` explícitamente y validar campos duplicados, esquema,
   host y rango de puerto antes de conectar.
3. En iOS, el usuario escanea/abre el pairing. `WorkbenchBackendFactory` crea
   `CodexRemoteBackend` configurado con ese pairing; no usa credenciales Basic de
   OpenCode ni rutas HTTP de OpenCode.
4. El cliente abre WebSocket, completa `initialize` y mantiene el canal JSON-RPC
   para solicitudes, respuestas y notificaciones. Los IDs de petición se
   correlacionan y los errores de protocolo se convierten en errores legibles.
5. El backend enumera o crea un thread, lo asocia con el proyecto seleccionado,
   carga su historial y transmite el turno actual a la timeline.
6. Al desconectarse, se cancela el stream y se cierran los recursos. La
   reconexión reutiliza el pairing guardado y reanuda el thread seleccionado si
   el servidor todavía lo ofrece.

## Capacidades v1

| Capacidad | Comportamiento esperado |
| --- | --- |
| Conexión | Conectar, mostrar estado/error y desconectar del App Server. |
| Threads | Listar threads accesibles, iniciar thread y reanudar uno existente. |
| Conversación | Enviar texto y mostrar texto incremental, razonamiento solo si el protocolo y la UI permiten distinguirlo, y estado de finalización/error. |
| Cancelación | Interrumpir el turno activo y reflejar su finalización. |
| Aprobaciones | Mostrar solicitudes de aprobación que Codex envíe y contestarlas conservando la distinción entre aprobación de comando y cambios de archivo. |
| Selección de modelo | Usar el modelo por defecto de Codex en v1; mostrarlo con claridad. La selección manual queda fuera salvo que el protocolo instalado la soporte de forma comprobada y no requiera cambios de UI. |
| Historial | Convertir los elementos de thread que la app entienda a eventos de timeline; conservar IDs para evitar duplicados durante streaming y carga de historial. |

El adapter debe declarar explícitamente como no disponibles las operaciones que
no se implementen. La pantalla no debe sugerir que Codex soporta funciones solo
porque las ofrezca otro backend.

## Fuera de alcance de v1

- Compatibilidad REST de OpenCode, ejecución de comandos arbitrarios en shell,
  edición/lectura directa de archivos remotos, explorador de archivos, diff,
  configuración de providers, catálogo de agentes/comandos y cambio de modelo
  desde iOS.
- Exponer el App Server en Internet público o añadir un proxy TLS propio al
  Bridge en esta entrega.
- Migrar todos los backends a un contrato común nuevo. Esa tarea pertenece al
  hito M1 y debe ser una decisión separada si la implementación de Codex la
  necesita.
- Implementar Claude Code, Gemini, Crush o el CLI propio.

## Conversión de permisos

El App Server entrega solicitudes de aprobación como peticiones JSON-RPC
iniciadas por el servidor. El cliente debe responder a la petición original y
preservar su tipo, identificador y opciones. La UI actual modela `allow once`,
`allow always` y `deny`; no se debe convertir `allow always` en una autorización
persistente si Codex solo ofrece una aprobación acotada al turno, ni descartar
opciones de aprobación que Codex exponga. Antes de implementar, confirmar con la
versión del protocolo disponible qué respuestas acepta cada clase de solicitud.
Si la UI no puede expresar esas respuestas sin cambiar su significado, la
solicitud se muestra como incompatible y no se responde automáticamente.

## Emparejamiento y secretos

- No reutilizar `username/password` como nombres o semántica del token de Codex.
  El modelo de pairing debe poder representar token, transporte y workspace con
  campos explícitos, sin romper los pairings OpenCode existentes.
- Guardar el token en Keychain o en el mecanismo seguro ya usado por la app; al
  olvidar el pairing, eliminar también el secreto.
- No incluir el token en logs, telemetría, errores, historial, query analytics
  ni mensajes de depuración. Si el formato de enlace lleva el secreto en query,
  evitar persistir o registrar la URL completa y documentar su sensibilidad.
- Rechazar pairing incompleto, parámetros duplicados, host inválido, puerto
  fuera de rango y esquemas de transporte no admitidos. Mostrar una advertencia
  visible de que v1 requiere LAN/VPN.

## Compatibilidad y fallos

- Detectar incompatibilidad de versión/protocolo durante `initialize` y mostrar
  un error accionable con las versiones observadas, sin volcar secretos.
- Tratar cierre de WebSocket, timeout, rechazo de autenticación, respuesta
  JSON-RPC inválida y detención del proceso host como estados de conexión
  distintos para diagnóstico.
- El historial cargado y el stream en vivo no deben duplicar el prompt ni los
  bloques de respuesta. Un thread remoto debe mapear a un único `Session` local.
- Si Codex no está instalado o no inicia, el Bridge debe devolver un error claro
  y no crear un pairing que parezca funcional.

## Criterios de aceptación

1. El Bridge inicia el App Server compatible con la versión local de Codex y
   expone el endpoint solamente en el alcance de red previsto por la
   configuración; requiere el capability token.
2. Un pairing Codex válido conecta desde iOS, y un pairing inválido o sin token
   falla sin filtrar el secreto.
3. La app puede listar/reanudar threads y crear uno nuevo, enviar un prompt,
   recibir texto incremental y cargar el historial sin duplicados.
4. Cancelar interrumpe el turno actual; la UI deja de marcar la sesión como
   activa.
5. Las solicitudes de aprobación compatibles se muestran antes de contestarse
   y se envía la respuesta exacta aceptada por Codex. Los tipos no compatibles
   quedan pendientes con explicación, sin autoaprobarse.
6. La UI no habilita capacidades fuera del alcance v1 y marca la conexión como
   experimental, restringida a LAN/VPN.
7. Desconectar, reconectar y olvidar pairing gestionan el thread y el secreto
   según lo especificado.

## Riesgos y decisiones de implementación

- El transporte remoto WebSocket del App Server es experimental. La
  implementación debe aislar el protocolo detrás de `CodexRemoteBackend` para
  poder reemplazar el transporte si Codex publica un protocolo estable.
- El esquema JSON-RPC puede cambiar entre versiones. La versión instalada
  durante el reconocimiento fue Codex CLI 0.155.1; la implementación debe
  verificar el protocolo disponible al iniciar, no asumir que todos los hosts
  tienen esa versión.
- El listener WebSocket no equivale a TLS. La seguridad de red de v1 depende de
  LAN confiable o VPN y del token de capacidad.
- Hace falta revisar el almacenamiento actual de pairing: hoy el flujo de la
  app convierte pairings remotos al modelo `OpenCodePairing`. La integración
  Codex requiere persistencia tipada o una ampliación que no altere pairings
  existentes.

## Auto-revisión

- El documento separa el protocolo Codex del transporte OpenCode y mantiene el
  Bridge como responsable de iniciar procesos en el host.
- El alcance incluye el ciclo interactivo aprobado y acota capacidades que hoy
  no tienen equivalencia demostrada en la app.
- El punto de aprobaciones conserva una condición explícita: verificar la
  semántica exacta del protocolo antes de mapear botones existentes.
- Se documentan el estado experimental, el límite LAN/VPN y el tratamiento del
  token.
- No se inicia implementación ni se modifica código en esta etapa.
