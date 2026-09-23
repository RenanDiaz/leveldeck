# SPEC — LevelDeck

> Deriva de `INTENT.md`. Si algo aquí contradice el intent, manda el intent.
> Estado: borrador v1.2 (entrada con la misma prioridad que la salida desde la Fase 1)

## 1. Resumen

Dos apps nativas en Swift y SwiftUI que se comunican por la red local:

- **Agente macOS:** app de barra de menú que lee y controla el audio del sistema con CoreAudio y expone un servicio en la red local.
- **Cliente iOS:** app que descubre la Mac por Bonjour, se empareja una sola vez y muestra faders sincronizados en tiempo real.

Sin servidores externos, sin cuentas y sin dependencias de terceros.

## 2. Decisiones sobre las preguntas abiertas del intent

| Pregunta | Decisión para v1 | Estado |
|---|---|---|
| Volumen por aplicación | Fuera de v1. Se evalúa después (ver §10). | Provisional |
| Emparejamiento | Código QR mostrado en la Mac y escaneado desde el iPhone. | Provisional |
| Widget / Centro de Control | Fuera de v1 (ver §10). | Provisional |
| Estilo de interfaz | Mixer con dos faders verticales (Salida, Entrada) y selector de dispositivo. | Provisional |

## 3. Plataformas y requisitos

- macOS 14+ e iOS 17+ (permite usar el framework Observation y APIs modernas de SwiftUI).
- Swift 5.10+ o Swift 6 con concurrencia estricta.
- Sin dependencias externas: solo CoreAudio, Network, Security, SwiftUI, AVFoundation (cámara para el QR) y ServiceManagement.

## 4. Estructura del repositorio

```
leveldeck/
├── INTENT.md
├── SPEC.md
├── project.yml        # XcodeGen: fuente de verdad del proyecto y los targets
├── Configs/           # xcconfig compartido; Local.xcconfig (Team ID) fuera de git
├── LevelDeckAgent/    # target macOS (app de barra de menú)
├── LevelDeck/         # target iOS
└── Packages/
    ├── LevelDeckKit/     # Swift Package compartido
    │   ├── Protocol/  # modelos de mensajes (Codable), versión del protocolo
    │   ├── Transport/ # wrappers de Network.framework, framing, TLS-PSK
    │   └── Pairing/   # formato del QR, almacenamiento en Keychain
    └── LevelDeckAgentKit/  # Swift Package solo macOS, usado por el agente
        ├── AgentAudio/     # AudioControlling y AudioModel (lógica de estado, sin CoreAudio)
        └── AgentCoreAudio/ # CoreAudioController: implementación real sobre CoreAudio
```

La lógica de protocolo y transporte vive en `LevelDeckKit` y se prueba de forma aislada. La lógica de audio del agente vive en `LevelDeckAgentKit`: `AgentAudio` se prueba con un mock de `AudioControlling` y `AgentCoreAudio` se verifica a mano contra el hardware.

El proyecto de Xcode se genera con `xcodegen generate` a partir de `project.yml` y no se versiona (`*.xcodeproj` está en `.gitignore`). No hay `.xcworkspace`: el paquete local se referencia desde `project.yml`. Bundle IDs: `com.renandiaz.LevelDeckAgent` (macOS) y `com.renandiaz.LevelDeck` (iOS).

## 5. Agente macOS

### 5.1 Comportamiento

- Vive en la barra de menú (`MenuBarExtra`), sin ícono en el Dock (`LSUIElement = YES`).
- Se registra como login item con `SMAppService.mainApp` (con opción en el menú para desactivarlo).
- El menú (estilo ventana, `.menuBarExtraStyle(.window)`) muestra: sliders de volumen de salida y entrada con mute, estado del servicio, dispositivos emparejados, "Emparejar nuevo dispositivo…" y Salir.

### 5.2 Servicio de audio (`AudioController`)

Wrapper sobre CoreAudio, detrás de un protocolo (`AudioControlling`) para poder usar mocks en los tests.

| Capacidad | API de CoreAudio |
|---|---|
| Dispositivo de salida/entrada por defecto | `kAudioHardwarePropertyDefaultOutputDevice` / `DefaultInputDevice` (leer y escribir) |
| Lista de dispositivos | `kAudioHardwarePropertyDevices` y filtrar por streams de salida/entrada (`kAudioDevicePropertyStreams` con el scope correspondiente) |
| Volumen de salida | `kAudioHardwareServiceDeviceProperty_VirtualMainVolume`, scope output |
| Volumen de entrada | igual con scope input; si no es configurable, usar `kAudioDevicePropertyVolumeScalar` por canal |
| Mute | `kAudioDevicePropertyMute` |
| Cambios externos | `AudioObjectAddPropertyListenerBlock` sobre volumen, mute, dispositivo por defecto y lista de dispositivos |

Reglas:

- El volumen se expresa como `Float` normalizado en el rango 0.0–1.0.
- Salida y entrada son simétricas: toda la API de `AudioControlling` se parametriza por `Scope`.
- Antes de exponer un control, verificar con `AudioObjectIsPropertySettable`. Algunos dispositivos (HDMI, ciertas interfaces USB) no permiten cambiar el volumen. En ese caso el control se reporta como `settable: false` y el cliente lo muestra deshabilitado.
- La configurabilidad del volumen y del mute se evalúa por separado (hay micrófonos con volumen y sin mute, y al revés). Internamente el agente lleva `volumeSettable` y `muteSettable`; el protocolo solo expone `settable` (volumen) hasta la Fase 4, que agrega `muteSettable`.
- Puede no haber dispositivo por defecto para un scope (p. ej. un Mac mini sin micrófono). El agente lo modela como canal ausente y el menú muestra "Sin dispositivo". Cómo se representa en el protocolo se decide en la Fase 2.
- Al cambiar el dispositivo por defecto, re-suscribir los listeners al nuevo dispositivo.
- Cualquier cambio, venga del cliente o de fuera, produce un único evento de estado que se envía a todos los clientes conectados.

### 5.3 Servicio de red (`RemoteServer`)

- `NWListener` en un puerto dinámico, anunciado por Bonjour como `_leveldeck._tcp` con el nombre de la Mac.
- Transporte: TCP + TLS 1.3 con pre-shared key (PSK) y WebSocket encima (`NWProtocolWebSocket`) para tener framing de mensajes gratis.
- Una conexión sin PSK válida no pasa el handshake. No hay canal sin cifrar, salvo durante el emparejamiento (§7).
- Soporta varios clientes simultáneos.

## 6. Cliente iOS

### 6.1 Pantallas

1. **Descubrimiento:** lista de Macs encontradas con `NWBrowser`. Las ya emparejadas se conectan automáticamente. Las no emparejadas ofrecen "Emparejar" y abren la cámara.
2. **Mixer:** dos faders verticales grandes (Salida, Entrada), cada uno con botón de mute y un indicador del dispositivo activo. Al tocar el nombre del dispositivo se abre un selector.
3. **Ajustes:** Macs emparejadas (con opción de olvidar), versión.

### 6.2 Comportamiento del fader

- Mientras el usuario arrastra, el cliente es la fuente de verdad: los eventos de estado entrantes para ese control se ignoran hasta ~300 ms después de soltar. Esto evita saltos.
- Los envíos se limitan a un máximo de 30 por segundo y siempre se envía el valor final al soltar.
- Feedback háptico ligero en 0 %, en 100 % y al activar o desactivar el mute.
- Si la conexión se pierde, los faders se muestran deshabilitados con un indicador de "Reconectando…" y el cliente reintenta con backoff (1 s, 2 s, 4 s, con máximo de 10 s).

### 6.3 Requisitos de Info.plist

Se agregan en la fase que los usa (red local y Bonjour en la Fase 2; cámara en la Fase 3), no antes.

- `NSLocalNetworkUsageDescription`: texto explicando que se usa para encontrar la Mac.
- `NSBonjourServices`: `_leveldeck._tcp`.
- `NSCameraUsageDescription`: para escanear el QR de emparejamiento.

## 7. Emparejamiento

1. En la Mac: "Emparejar nuevo dispositivo…" genera una clave aleatoria de 32 bytes (`SecRandomCopyBytes`) y un ID del agente, y muestra un QR con `{ v, agentId, serviceName, key }` en base64url. La ventana expira a los 2 minutos.
2. En el iPhone: se escanea el QR y se guarda la clave en el Keychain, asociada al `agentId`.
3. El iPhone conecta usando esa clave como PSK. Si el handshake es exitoso, la Mac registra el dispositivo (nombre e ID) y guarda la clave en su Keychain.
4. A partir de ahí, todas las conexiones usan TLS-PSK con esa clave. Cada iPhone emparejado tiene su propia clave.
5. Revocar un dispositivo desde el menú de la Mac borra su clave, y cualquier conexión activa de ese dispositivo se cierra.

La clave nunca viaja por la red: el QR es el canal fuera de banda.

## 8. Protocolo

Mensajes JSON sobre WebSocket. Todos incluyen `type` y el payload va plano, al mismo nivel que `type`. El protocolo tiene versión (`v: 1`), que solo viaja en `hello` y `state`: el handshake la negocia, y los comandos no la repiten.

### Cliente → Agente

| type | payload | Efecto |
|---|---|---|
| `hello` | `{ v, deviceName }` | Primer mensaje. El agente responde con `state`. |
| `setVolume` | `{ scope: "output"\|"input", value: 0.0–1.0 }` | Cambia el volumen del dispositivo por defecto. |
| `setMute` | `{ scope, muted: Bool }` | Cambia el mute. |
| `setDefaultDevice` | `{ scope, deviceId: String }` | Cambia el dispositivo por defecto. |

### Agente → Cliente

| type | payload |
|---|---|
| `state` | Snapshot completo (ver abajo). Se envía tras `hello` y ante cualquier cambio. |
| `error` | `{ code, message }`. Códigos: `unsupportedVersion`, `notSettable`, `deviceNotFound`, `invalidValue`. |

```json
{
  "type": "state",
  "v": 1,
  "output": { "deviceId": "…", "deviceName": "MacBook Pro Speakers",
              "volume": 0.62, "muted": false, "settable": true },
  "input":  { "deviceId": "…", "deviceName": "MacBook Pro Microphone",
              "volume": 0.80, "muted": false, "settable": true },
  "devices": {
    "output": [{ "id": "…", "name": "…" }],
    "input":  [{ "id": "…", "name": "…" }]
  }
}
```

El `deviceId` es el UID del dispositivo (`kAudioDevicePropertyDeviceUID`), no el `AudioObjectID`, porque el UID es estable entre reinicios.

Un `setVolume` con `value` fuera de 0.0–1.0 (o `NaN`) es inválido: no se recorta. `LevelDeckKit` se niega a codificarlo y lo rechaza al decodificar, y el agente responde `error` con `invalidValue`. Un `type` desconocido o un campo faltante también son errores de decodificación.

Se envía siempre el snapshot completo, no diffs. El payload es pequeño y así se evita todo un tipo de bugs de sincronización. Durante un arrastre, los envíos de `state` se agrupan (coalescing) a un máximo de 30 por segundo.

## 9. Fases

Cada fase termina con algo que se puede usar y probar.

**Fase 0 — Esqueleto.** Workspace, dos targets, paquete `LevelDeckKit` con los modelos del protocolo y sus tests de codificación y decodificación.
*Listo cuando:* `xcodegen generate` funciona, compilan ambos targets con `xcodebuild` y pasan los tests de `LevelDeckKit` (`scripts/verify.sh`, que también corre en CI sobre `macos-15`).

**Fase 1 — Audio en la Mac.** `AudioController` con volumen y mute de salida y de entrada, parametrizado por `Scope`, más listeners. El menú muestra un slider con mute por cada scope que refleja y controla el sistema.
*Listo cuando:*
- el menú muestra sliders de salida y entrada con mute, y controlan el sistema;
- los cambios externos (teclado, Ajustes del Sistema) mueven los sliders;
- cambiar el dispositivo por defecto re-suscribe los listeners;
- un dispositivo no configurable deshabilita su slider sin fallar;
- la lógica de estado se prueba con un mock de `AudioControlling` y pasa en CI; la verificación con hardware real es un checklist manual en el PR.

**Fase 2 — Conexión local (sin seguridad, solo en desarrollo).** `RemoteServer` con Bonjour y WebSocket en claro detrás de un flag de debug. El cliente iOS descubre, conecta y muestra los faders de salida y entrada sincronizados.
*Listo cuando:* los cambios en cualquiera de los dos lados se reflejan en el otro en menos de 100 ms en la red local.

**Fase 3 — Emparejamiento y TLS-PSK.** QR, Keychain, TLS-PSK y revocación. Se elimina el modo en claro de los builds de release.
*Listo cuando:* un iPhone sin emparejar no puede conectar, uno emparejado conecta automáticamente y uno revocado queda desconectado.

**Fase 4 — Mixer completo.** Mute en el cliente iOS, selector de dispositivo, manejo de `settable: false` y `muteSettable` en el protocolo y el cliente, y varios clientes simultáneos.
*Listo cuando:* los dos faders y el selector funcionan, y conectar un monitor HDMI sin control de volumen deshabilita el fader sin romper nada.

**Fase 5 — Pulido.** Reconexión con backoff, supresión de eco durante el arrastre, hápticos, login item y opción de desactivarlo.
*Listo cuando:* dormir y despertar la Mac, o apagar y encender el Wi-Fi del iPhone, recupera la conexión sin intervención.

## 10. Después de v1

- **Volumen por aplicación.** Requiere un driver de audio virtual (tipo HAL plug-in / AudioServerPlugIn) que capture el audio de cada app. Alternativas: escribir uno propio (alto costo y firma más compleja), integrarse con BackgroundMusic (open source) o controlar SoundSource si expone automatización. Hacer un spike antes de decidir.
- **Widget / Centro de Control (iOS 18+).** Los Control Widgets ejecutan App Intents de corta duración y no pueden mantener una conexión abierta. Cada acción tendría que conectar, hacer el handshake TLS, enviar y cerrar. Hay que medir si la latencia resultante es aceptable.
- **Mac → Mac o iPad.** El cliente es SwiftUI, así que portarlo a iPad es casi gratis.

## 11. Pruebas

- **LevelDeckKit:** tests unitarios de codificación del protocolo, formato del QR y lógica de throttle y coalescing.
- **AudioController:** detrás de `AudioControlling`. Tests con mock para la lógica de estado y una verificación manual contra el hardware real (CoreAudio no se puede mockear de forma útil a bajo nivel).
- **Integración:** test que levanta `RemoteServer` en loopback con una PSK de prueba y verifica el ciclo completo `hello` → `setVolume` → `state`.
- **Checklist manual por fase,** basado en los criterios de "Listo cuando".

## 12. Distribución

Instalación directa desde Xcode en mis dispositivos. Con Apple ID gratuito, la firma de iOS caduca a los 7 días. Con cuenta de desarrollador de pago se puede usar TestFlight o firma de un año. El agente de macOS se firma localmente y no necesita notarización para uso propio.
