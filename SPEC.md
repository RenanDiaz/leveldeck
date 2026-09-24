# SPEC — LevelDeck

> Deriva de `INTENT.md`. Si algo aquí contradice el intent, manda el intent.
> Estado: **Parte I (v1)** — v1.7, implementada hasta la Fase 5 (reconexión, hápticos, login item y challenge-response del `hello`; incluye la lectura del Keychain de la Mac en dos pasos de la v1.6.1). **Parte II (v2)** — borrador 2.0 en revisión (§13–§21): tiras por dispositivo, protocolo v4, app universal, auditoría de diseño y spike de volumen por app.

## 1. Resumen

Dos apps nativas en Swift y SwiftUI que se comunican por la red local:

- **Agente macOS:** app de barra de menú que lee y controla el audio del sistema con CoreAudio y expone un servicio en la red local.
- **Cliente iOS:** app que descubre la Mac por Bonjour, se empareja una sola vez y muestra faders sincronizados en tiempo real.

Sin servidores externos, sin cuentas y sin dependencias de terceros.

## 2. Decisiones sobre las preguntas abiertas del intent

| Pregunta | Decisión para v1 | Estado |
|---|---|---|
| Volumen por aplicación | Fuera de v1. Spike con go/no-go en la v2 (§20). | Provisional |
| Emparejamiento | Código QR mostrado en la Mac y escaneado desde el iPhone; la clave del QR es la PSK del handshake TLS (§7). | Decidido (Fase 3) |
| Widget / Centro de Control | Fuera de v1 (ver §10). | Provisional |
| Estilo de interfaz | Mixer con dos faders verticales (Salida, Entrada) y selector de dispositivo. En la v2 pasa a una tira por dispositivo (§13). | Provisional |

## 3. Plataformas y requisitos

- macOS 14+ e iOS 17+ (permite usar el framework Observation y APIs modernas de SwiftUI).
- Swift 5.10+ o Swift 6 con concurrencia estricta.
- Sin dependencias externas: solo CoreAudio, Network, Security, CryptoKit (HMAC del `hello`, §8), SwiftUI, AVFoundation (cámara para el QR), CoreImage (generar el QR) y ServiceManagement.
- Idiomas: inglés (idioma de desarrollo y de respaldo) y español, en ambas apps, con String Catalogs (`Localizable.xcstrings` e `InfoPlist.xcstrings` por target). Reglas:
  - `LevelDeckKit` no genera textos de interfaz. Expone problemas tipados (`NetworkIssue` para la red, `ErrorCode` del protocolo) y cada app arma su mensaje localizado.
  - Nunca se muestra el `localizedDescription` de un error del sistema (mezcla una frase localizada con detalle técnico en inglés) ni el `message` de un `error` del protocolo. El detalle técnico solo aparece en builds Debug, sin traducir y marcado como tal.
  - `scripts/check-localizations.py` (parte de `verify.sh`) falla si un texto que el compilador extrae de las apps no tiene traducción al español, o si los bundles no incluyen `es.lproj`.

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
    │   ├── Sync/      # throttle de envíos, supresión de eco del fader, medición de RTT, backoff
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
- Se registra como login item con `SMAppService.mainApp` (con opción en el menú para desactivarlo):
  - Se registra solo una vez, en el primer arranque de un build Release (flag en `UserDefaults`). Si el usuario lo desactiva, no se vuelve a activar. En Debug no se registra solo: registraría el `.app` de DerivedData, que cambia de ruta; el interruptor funciona igual.
  - El menú tiene el interruptor "Abrir al iniciar sesión". El estado se relee al abrir el menú, porque puede cambiar desde Ajustes del Sistema.
  - Si macOS pide aprobación (`.requiresApproval`), el menú lo dice y ofrece "Abrir ajustes de ítems de inicio…" (`SMAppService.openSystemSettingsLoginItems()`). Un fallo al registrar se muestra con un texto localizado; el detalle, solo en Debug.
- Al despertar la Mac (`NSWorkspace.didWakeNotification`) reinicia el listener, que vuelve a anunciarse por Bonjour, y re-suscribe los listeners de CoreAudio (`AudioModel.restart`). Al cambiar la red (`NWPathMonitor`: la ruta vuelve a estar disponible o cambian las interfaces) solo reinicia el listener. Las sesiones activas no se tocan (§5.3).
- El menú (estilo ventana, `.menuBarExtraStyle(.window)`) muestra: sliders de volumen de salida y entrada con mute, estado del servicio, dispositivos emparejados (con indicador de conectado y botón para revocar), "Emparejar nuevo dispositivo…" (abre la ventana del QR, §7), "Abrir al iniciar sesión" y Salir.

### 5.2 Servicio de audio (`AudioController`)

Wrapper sobre CoreAudio, detrás de un protocolo (`AudioControlling`) para poder usar mocks en los tests.

| Capacidad | API de CoreAudio |
|---|---|
| Dispositivo de salida/entrada por defecto | `kAudioHardwarePropertyDefaultOutputDevice` / `DefaultInputDevice` (leer y escribir) |
| Lista de dispositivos | `kAudioHardwarePropertyDevices`, filtrando por streams en el scope (`kAudioDevicePropertyStreams`) y sin los ocultos (`kAudioDevicePropertyIsHidden`) |
| UID → dispositivo | `kAudioHardwarePropertyTranslateUIDToDevice` (para `setDefaultDevice`) |
| Volumen de salida | `kAudioHardwareServiceDeviceProperty_VirtualMainVolume`, scope output |
| Volumen de entrada | igual con scope input; si no es configurable, usar `kAudioDevicePropertyVolumeScalar` por canal |
| Mute | `kAudioDevicePropertyMute` |
| Cambios externos | `AudioObjectAddPropertyListenerBlock` sobre volumen, mute, dispositivo por defecto y lista de dispositivos |

`AudioControlling` expone, por `Scope`: `channel`, `setVolume`, `setMute`, `devices`, `setDefaultDevice` y la observación de cambios.

Reglas:

- El volumen se expresa como `Float` normalizado en el rango 0.0–1.0.
- Salida y entrada son simétricas: toda la API de `AudioControlling` se parametriza por `Scope`.
- Antes de exponer un control, verificar con `AudioObjectIsPropertySettable`. Algunos dispositivos (HDMI, ciertas interfaces USB) no permiten cambiar el volumen. En ese caso el control se reporta como no configurable y el cliente lo muestra deshabilitado.
- La configurabilidad del volumen y del mute se evalúa por separado (hay micrófonos con volumen y sin mute, pantallas con mute y sin volumen). El agente y el protocolo llevan `volumeSettable` y `muteSettable`; cada control se deshabilita por su cuenta, sin afectar al otro.
- La lista de un scope incluye los dispositivos con al menos un stream en ese scope que no estén ocultos (`kAudioDevicePropertyIsHidden`; si el dispositivo no expone la propiedad, cuenta como visible). Los virtuales (BlackHole, los de Zoom y Teams) aparecen si cumplen eso. Va ordenada por nombre. Un dispositivo oculto no se lista aunque sea el activo: el fader muestra su nombre y el selector no marca ninguno.
- `setDefaultDevice` traduce el UID con `kAudioHardwarePropertyTranslateUIDToDevice`. UID desconocido, oculto o sin streams en el scope → `deviceNotFound` (p. ej. se desconectó entre que el cliente vio la lista y lo eligió); el agente relee la lista para que el siguiente `state` la corrija. Elegir el que ya está activo no hace nada. Solo se cambia el default de salida o entrada: el de sonidos del sistema (`DefaultSystemOutputDevice`) se deja a macOS.
- La lista y el canal se leen por separado: si una lectura falla, conserva su último valor y la otra se aplica igual. Al desconectar el activo, la HAL puede fallar un instante al leer el default viejo, y la lista tiene que actualizarse de todas formas.
- Un cambio en `kAudioHardwarePropertyDevices` (conectar o desconectar audífonos, interfaces o monitores) se avisa para ambos scopes. Si desaparece el activo, el que elija macOS llega por el listener del dispositivo por defecto.
- Puede no haber dispositivo por defecto para un scope (p. ej. un Mac mini sin micrófono). El agente lo modela como canal ausente y el menú muestra "Sin dispositivo". En el protocolo, el canal va presente con valor `null` (ver §8).
- Al cambiar el dispositivo por defecto, re-suscribir los listeners al nuevo dispositivo.
- Si `coreaudiod` se reinicia, todos los listeners quedan inválidos: `kAudioHardwarePropertyServiceRestarted` los vuelve a suscribir y relee ambos scopes. Al despertar la Mac se hace lo mismo (§5.1).
- Cualquier cambio, venga del cliente o de fuera, produce un único evento de estado que se envía a todos los clientes conectados.

### 5.3 Servicio de red (`RemoteServer`)

- `NWListener` en un puerto dinámico, anunciado por Bonjour como `_leveldeck._tcp` con el nombre de la Mac y un registro TXT `id=<agentId>`. El iPhone elige la clave por el `agentId`, no por el nombre (que puede cambiar o llevar sufijo).
- Transporte: TCP + TLS con pre-shared key (PSK) y WebSocket encima (`NWProtocolWebSocket`, `wss://`) para tener framing de mensajes gratis.
- Una conexión sin PSK válida no pasa el handshake. No hay canal sin cifrar: el emparejamiento (§7) también ocurre sobre TLS-PSK, con la clave que llegó por el QR.
- Soporta varios clientes simultáneos.
- Keepalive de TCP en ambos extremos (5 s de inactividad, 3 sondas cada 2 s): una conexión cuyo otro lado desapareció sin cerrar (la Mac se durmió, se apagó el Wi-Fi) se da por muerta en ~11 s. Así el iPhone empieza a reconectar y la Mac no lista clientes fantasma.
- Si el listener falla, se reintenta con el mismo backoff del cliente (§6.2). `LevelDeckServer.restartListener()` lo recrea a pedido (al despertar o cambiar de red, §5.1).
- El transporte (parámetros de Network.framework, framing, servidor, cliente y browser) vive en `LevelDeckKit`. Las apps solo eligen un valor de `TransportSecurity`, en un único archivo por app (`AgentTransport`, `AppTransport`).

**TLS-PSK (Fase 3).** Verificado contra la API de Network.framework antes de construir:

- Network.framework no negocia PSK externas en TLS 1.3: ahí las PSK son solo de reanudación de sesión. Las PSK externas van con los ciphersuites PSK de TLS 1.2 (RFC 4279/5487). `TransportSecurity.tlsPSK` fija la versión en TLS 1.2 (`sec_protocol_options_set_min/max_tls_protocol_version`) y agrega `TLS_PSK_WITH_AES_128_GCM_SHA256` (0x00A8, el que usa el sample de Apple). Sin ECDHE no hay forward secrecy: si alguien captura tráfico y después obtiene la clave de ese dispositivo, puede descifrarlo. Aceptado para la amenaza que cubrimos (otro dispositivo en la red local sin la clave); se anota en §10.
- Una clave por dispositivo: el servidor agrega todas las PSK con `sec_protocol_options_add_pre_shared_key(key, identity)`, una por dispositivo emparejado (más la pendiente durante el emparejamiento). En TLS 1.2 PSK el cliente manda su identidad en el `ClientKeyExchange` y el servidor elige la clave con ella; identidad desconocida o clave distinta abortan el handshake. La identidad es el `deviceId` que la Mac asignó al emparejar (§7). Que el servidor elige bien entre varias claves lo prueba el test de dos clientes con claves distintas conectados a la vez (§11).
- Reanudación de sesión y tickets desactivados en ambos extremos (`sec_protocol_options_set_tls_resumption_enabled/tickets_enabled(false)`): cada conexión hace el handshake PSK completo. Con reanudación, un cliente del mismo proceso que ya tuvo una sesión válida con ese host:puerto la reanuda sin probar la clave (lo detectaron los tests de rechazo en loopback), y un dispositivo revocado podría reentrar mientras su ticket viva. La seguridad no depende de que el reinicio del listener cambie el puerto.
- El conjunto de PSK se fija al crear el listener. Cuando cambia (empieza o termina un emparejamiento, se revoca un dispositivo), `LevelDeckServer.update(security:)` reinicia el listener con el conjunto nuevo: puerto nuevo, mismo nombre Bonjour. Las sesiones ya aceptadas son independientes del listener y siguen vivas; los clientes resuelven el servicio Bonjour en cada conexión, así que el cambio de puerto no los afecta. Con esto no dependemos de ningún comportamiento no documentado de selección dinámica de claves.
- Network.framework no expone la identidad PSK negociada de una conexión, así que el servidor la aprende del `hello`, que lleva `deviceId` (§8). Hasta la Fase 4 era una declaración sin verificar: un dispositivo emparejado podía declararse como otro y sobrevivir a su propia revocación en caliente (su conexión activa figuraba como la del otro y no se cerraba). Desde la Fase 5 (protocolo v3) el `deviceId` se demuestra con un challenge-response: al abrirse la sesión el agente manda un `nonce` aleatorio y el `hello` responde con el HMAC de ese `nonce` hecho con la clave del `deviceId` declarado (§8). El servidor lo verifica contra el conjunto de PSK vigente, así que un dispositivo revocado o un QR vencido tampoco pasan. Solo quien tiene la clave de un dispositivo puede presentarse como él.

**Transporte en claro (solo desarrollo).** `TransportSecurity.insecurePlaintext` (TCP + WebSocket sin cifrar) existe únicamente si está definido el flag de compilación `LEVELDECK_INSECURE_TRANSPORT`:

- Desde la Fase 3 las apps no lo usan en ninguna configuración: siempre TLS-PSK. El flag queda solo en `LevelDeckKit`, con `.when(configuration: .debug)`, para inspeccionar el protocolo en tests (`PlaintextSmokeTests`). Sin cámara (simulador), el emparejamiento se hace pegando el código que la ventana del QR muestra como texto en builds Debug.
- Si el flag aparece en un build sin `DEBUG`, un `#error` corta la compilación.
- `scripts/verify.sh` comprueba que la marca del transporte en claro está en el build Debug del paquete (control positivo) y no aparece en las apps Release.

## 6. Cliente iOS

### 6.1 Pantallas

1. **Descubrimiento:** lista de Macs encontradas con `NWBrowser`. Las ya emparejadas (el `agentId` del TXT coincide con una entrada del Keychain) se marcan y se conectan automáticamente: la última usada si está, si no la primera. Las no emparejadas ofrecen "Emparejar" y abren la cámara (pantalla de emparejamiento, §7).
2. **Mixer:** dos faders verticales grandes (Salida, Entrada), cada uno con botón de mute y un indicador del dispositivo activo. Al tocar el nombre del dispositivo se abre un selector (sheet con la lista de ese scope y el activo marcado); la lista cambia en vivo mientras está abierto. Elegir uno manda `setDefaultDevice` y cierra el sheet; no hay cambio optimista: el dispositivo nuevo se ve cuando llega el `state`. Un volumen o mute no configurable se muestra deshabilitado, con una nota que dice cuál. Los errores del agente se muestran como aviso transitorio (unos segundos): el mixer ya se resincronizó con el último `state`.
3. **Ajustes:** Macs emparejadas (con fecha y opción de olvidar, que borra la clave del iPhone), versión y protocolo. Olvidar en el iPhone no revoca en la Mac: la Mac sigue listando el dispositivo hasta que se revoque desde su menú.

### 6.2 Comportamiento del fader

Las dos primeras reglas se implementan desde la Fase 2 (`SendThrottle`, `EchoGate` y `MixerState` en `LevelDeckKit/Sync`).

- Mientras el usuario arrastra, el cliente es la fuente de verdad: los eventos de estado entrantes para ese control se ignoran hasta ~300 ms después de soltar. Esto evita saltos, también cuando otro cliente mueve el mismo control. Solo se retiene el volumen de ese fader: el resto del `state` (mute, nombre, configurabilidad, lista de dispositivos, el otro canal) se aplica igual. Al vencer la ventana se aplica el último volumen recibido durante ella, para no quedar desincronizado.
- Si cambia el dispositivo por defecto a mitad del arrastre (o durante la retención), manda el agente y el arrastre queda invalidado: el cliente descarta el envío pendiente y no manda más `setVolume` hasta el próximo toque. Si no, seguiría escribiendo en el dispositivo nuevo (p. ej. otro cliente cambió a audífonos y este los pondría a 100 %).
- Los envíos se limitan a un máximo de 30 por segundo y siempre se envía el valor final al soltar. El primer valor sale de inmediato; los intermedios se agrupan y sale el más reciente.
- Feedback háptico ligero en 0 %, en 100 % y al activar o desactivar el mute.
- Solo por acciones propias: un volumen o un mute que llega de otro cliente o de la Mac no vibra. Quedarse en el borde no repite el háptico; salir y volver, sí (`FaderBoundary`).
- Si la conexión se pierde, los faders se muestran deshabilitados con un indicador de "Reconectando…" y el cliente reintenta con backoff: 1 s, 2 s, 4 s, 8 s y luego 10 s fijos (`Backoff`, `ReconnectPolicy`). El contador se reinicia al conectar. Cada intento vuelve a resolver el servicio Bonjour, así que un cambio de puerto o de red no lo afecta.
  - No reintenta cuando reintentar no sirve: `notPaired`, `unsupportedVersion` o un handshake TLS rechazado (la Mac no reconoce la clave). Esos quedan en "Desconectado" con su mensaje.
  - Con la conexión abierta, el `challenge` y el primer `state` tienen que llegar en 5 s; si no, la conexión se cierra y cuenta como intento fallido ("La Mac no respondió…"). Cubre un agente colgado o de otra versión del protocolo.
  - Al pasar a segundo plano, el cliente cierra la conexión y pausa los reintentos. Al volver al frente, reconecta de inmediato sin esperar el backoff (`reconnectNow`) y reinicia el browser de Bonjour si había fallado.
  - El reloj del backoff se inyecta, para probar los intervalos sin esperar de verdad (§11).

### 6.3 Requisitos de Info.plist

Se agregan en la fase que los usa (red local y Bonjour en la Fase 2; cámara en la Fase 3). Los tres van traducidos en `InfoPlist.xcstrings`.

- `NSLocalNetworkUsageDescription`: texto explicando que se usa para encontrar la Mac.
- `NSBonjourServices`: `_leveldeck._tcp`.
- `NSCameraUsageDescription`: para escanear el QR de emparejamiento.

## 7. Emparejamiento

Toda la lógica vive en `LevelDeckKit/Pairing` (`PairingCode`, `PresharedKey`, `PairingManager` en la Mac, `PairedAgents` en el iPhone, stores de Keychain y en memoria). Las apps solo muestran el QR, escanean y llaman al manager.

### 7.1 Flujo

1. En la Mac: "Emparejar nuevo dispositivo…" llama a `PairingManager.beginPairing`, que genera una clave aleatoria de 32 bytes (`SecRandomCopyBytes`) y un `deviceId` nuevo (UUID) para el futuro iPhone, mete esa clave en el listener (§5.3) y abre una ventana con el QR. El QR contiene `leveldeck-pair:` + base64url de `{ v: 1, agentId, agentName, deviceId, key }`. La ventana muestra el contador y expira a los 2 minutos.
2. En el iPhone: la pantalla de emparejamiento escanea el QR (AVFoundation, `NSCameraUsageDescription`), valida `v` y guarda `{ agentId, agentName, deviceId, key }` en el Keychain (`PairedAgents.pair`).
3. El iPhone conecta de inmediato con TLS-PSK (identidad `deviceId`, clave `key`). La Mac abre la sesión con `challenge { nonce }` y el iPhone responde `hello { v, deviceName, deviceId, proof }`, con `proof` = HMAC del `nonce` con `key` (§8). Si el handshake es exitoso, la prueba es válida y el `deviceId` es el pendiente, la Mac registra el dispositivo (`deviceId`, nombre, fecha) y guarda la clave en su Keychain. La ventana del QR muestra la confirmación y se cierra con "Listo". El iPhone cierra esa primera conexión y la pantalla de descubrimiento conecta como con cualquier Mac emparejada.
4. A partir de ahí, todas las conexiones usan TLS-PSK con esa clave. Cada iPhone emparejado tiene su propia clave e identidad.
5. Revocar un dispositivo desde el menú de la Mac (`PairingManager.revoke`) borra su clave del Keychain, le manda `error` `notPaired` y cierra su conexión activa, y saca su clave del listener, así que tampoco puede volver a conectar. El iPhone, al recibir `notPaired`, borra su clave y vuelve a ofrecer "Emparejar". Como el `deviceId` de cada sesión está demostrado (§5.3), la conexión que se cierra es de verdad la de ese dispositivo: no puede estar conectado bajo la identidad de otro.

La clave nunca viaja por la red: el QR es el canal fuera de banda. La Mac guarda la clave solo cuando el iPhone ya demostró tenerla (el handshake y la prueba del `hello`).

### 7.2 Ciclo de vida de la clave pendiente

| Momento | Dónde vive la clave |
|---|---|
| `beginPairing` → primer `hello` | Solo en memoria (`PairingManager.pending`) y en el conjunto de PSK del listener. No se escribe en el Keychain de la Mac. |
| `hello` con el `deviceId` pendiente, antes del vencimiento | Pasa al Keychain como dispositivo emparejado; `pending` se vacía. El conjunto de PSK del listener no cambia (la misma identidad y clave), así que no hay reinicio. |
| Vence el QR, se cancela o se cierra la ventana sin emparejar | `pending` se descarta y el listener se reinicia sin esa clave. Un iPhone que la haya escaneado se queda con una clave inútil: su handshake falla y la pantalla de emparejamiento lo dice y borra la clave. |
| Vence a mitad del proceso | El vencimiento se evalúa al llegar el `hello`: si ya pasó, se rechaza con `notPaired` y se descarta la pendiente (si el listener ya se reinició sin esa clave, la prueba del `hello` tampoco verifica: mismo resultado). Un handshake en vuelo cuando el listener se reinicia puede cortarse; en ambos casos el iPhone muestra "el código venció, muestra uno nuevo". Regla simple y determinista: no hay periodo de gracia. |
| Fallo del Keychain al guardar | No se empareja: se rechaza con `notPaired`, se cancela la pendiente y el menú muestra el error. Sin persistencia no hay "conexión automática después". |
| Segundo `beginPairing` con uno pendiente | Reemplaza al anterior; el QR viejo queda invalidado. |

**Escaneado dos veces.**

- El mismo iPhone escanea otra vez el mismo QR (dentro de la ventana): el Keychain del iPhone tiene la misma entrada; la Mac lo ve como dispositivo ya emparejado. Idempotente.
- El mismo iPhone escanea un QR nuevo de una Mac ya emparejada (re-emparejar): el iPhone reemplaza su entrada (misma `agentId`); la Mac queda con la identidad vieja huérfana en su lista hasta que se revoque desde el menú. Se acepta: es visible y se limpia con un clic.
- Dos iPhones escanean el mismo QR: el primero que hace el `hello` se registra y la ventana se cierra. La clave del QR ya es la clave permanente de ese dispositivo, así que el segundo también pasaría el handshake y aparecería como el mismo dispositivo (con su propio nombre en el último `hello`). Requiere ver físicamente la pantalla de la Mac durante la ventana de 2 minutos: fuera de la amenaza que cubrimos (otro dispositivo en la red local). Endurecimiento posible sin que la clave viaje: derivar la clave definitiva en ambos lados con el exporter de la primera sesión TLS (`sec_protocol_metadata_create_secret`), que solo conocen las dos partes de ese handshake. Anotado en §10.

### 7.3 Almacenamiento

- Ambos lados usan `kSecClassGenericPassword`. El iPhone, en el Keychain de protección de datos con `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: la identidad es por dispositivo y no migra con un respaldo. La Mac, en el llavero de login clásico: el de protección de datos exige el entitlement `keychain-access-groups` con perfil de aprovisionamiento, que un Personal Team no da (`errSecMissingEntitlement`); el llavero de login solo pide confirmación si cambia la identidad de firma del agente. Si el Keychain falla, las apps siguen funcionando con lo que hay en memoria y muestran un error localizado (detalle técnico solo en Debug); la Mac rechaza el emparejamiento en ese caso, para que el iPhone no se quede con una clave que ella no va a recordar.
- Mac: servicio `com.renandiaz.LevelDeckAgent.pairedDevices`, un ítem por `deviceId` con `{ device: { id, name, pairedAt }, key }`; y `…identity` con el `agentId`, que se crea la primera vez.
- iPhone: servicio `com.renandiaz.LevelDeck.pairedAgents`, un ítem por `agentId` con `{ id, name, deviceId, key, pairedAt }`.
- Lectura en dos pasos, igual en ambos lados: primero se listan las cuentas del servicio (`kSecMatchLimitAll` con `kSecReturnAttributes`) y después se lee cada una (`kSecMatchLimitOne` con `kSecReturnData`). El llavero de login de macOS no admite `kSecReturnData` junto con `kSecMatchLimitAll` (devuelve `errSecParam`, -50).
- Los stores están detrás de protocolos (`PairedDeviceStore`, `PairedAgentStore`) con implementaciones en memoria para los tests.

## 8. Protocolo

Mensajes JSON sobre WebSocket. Todos incluyen `type` y el payload va plano, al mismo nivel que `type`. El protocolo tiene versión (`v: 3` desde la Fase 5, que agregó el `challenge` y la `proof` del `hello`; la v2 cambió `settable` por `volumeSettable`), que solo viaja en `hello` y `state`: el handshake la negocia, y los comandos no la repiten.

**Handshake (v3).**

1. Al abrirse la sesión (TLS-PSK listo), el agente manda `challenge { nonce }`: 32 bytes aleatorios (`SecRandomCopyBytes`) en base64url, nuevos en cada conexión.
2. El cliente responde `hello { v, deviceName, deviceId, proof }` con
   `proof = HMAC-SHA256(key, "leveldeck-hello-v3" ‖ 0x00 ‖ nonce ‖ utf8(deviceId))` en base64url, donde `key` es su clave de emparejamiento (§7). La etiqueta separa este uso de la clave de cualquier otro; el `nonce` tiene largo fijo y el `deviceId` va al final, así que la concatenación no es ambigua.
3. El agente chequea, en orden: la versión (`unsupportedVersion` y cierra), la prueba contra la clave de ese `deviceId` en el conjunto de PSK vigente, con comparación en tiempo constante (`notPaired` y cierra si falta, no verifica o el `deviceId` no está), y el emparejamiento (`PairingManager`: nombre, pendiente, vencimiento; §7). Después responde `state`.
4. El `nonce` es de un solo uso: un segundo `hello` en la misma sesión no verifica. Una sesión sin `hello` válido en 10 s se cierra. Del lado del cliente, si el `challenge` y el `state` no llegan en 5 s, cierra y reintenta (§6.2).

Una prueba inválida se responde con `notPaired`, sin código nuevo: si el TLS pasó con la clave del cliente, la prueba solo falla cuando declara un `deviceId` que no es el suyo o cuando su clave ya no está en la Mac. En ambos casos lo correcto es que borre la clave. Con el transporte en claro de desarrollo (§5.3) no hay claves: `deviceId` y `proof` son opcionales y no se verifican. Un cliente v2 manda el `hello` sin esperar el `challenge` y recibe `unsupportedVersion`; un cliente v3 frente a un agente v2 no recibe `challenge` y se queda reintentando con "La Mac no respondió…". Ambas apps se instalan juntas, así que no hay compatibilidad hacia atrás.

### Cliente → Agente

| type | payload | Efecto |
|---|---|---|
| `hello` | `{ v, deviceName, deviceId, proof }` | Primer mensaje del cliente, en respuesta al `challenge`. `deviceId` es la identidad PSK que la Mac asignó al emparejar (§7) y `proof` el HMAC del `nonce` (ver arriba); ambos se omiten solo con el transporte en claro de desarrollo. El agente responde con `state`; con `error` `unsupportedVersion` y cierra si `v` no coincide; con `error` `notPaired` y cierra si la prueba falta o no verifica, o si `deviceId` no está emparejado ni pendiente. Cualquier otro mensaje antes de `hello` cierra la conexión. |
| `setVolume` | `{ scope: "output"\|"input", value: 0.0–1.0 }` | Cambia el volumen del dispositivo por defecto. |
| `setMute` | `{ scope, muted: Bool }` | Cambia el mute. |
| `setDefaultDevice` | `{ scope, deviceId: String }` | Cambia el dispositivo por defecto del scope. `deviceId` es un UID de `devices`. Si ya no está disponible, `error` `deviceNotFound`. Elegir el activo no hace nada. |

### Agente → Cliente

| type | payload |
|---|---|
| `challenge` | `{ nonce }`. Primer mensaje de cada sesión (v3): 32 bytes aleatorios en base64url. No lleva `v`. Un `nonce` con otro largo es un error de decodificación. |
| `state` | Snapshot completo (ver abajo). Se envía tras `hello` y ante cualquier cambio. |
| `error` | `{ code, message }`. Códigos: `unsupportedVersion`, `notSettable`, `deviceNotFound`, `invalidValue`, `notPaired`. `message` es solo para diagnóstico y no se localiza; el cliente muestra un texto localizado según `code`. `notPaired` va seguido del cierre de la conexión (en el `hello` o al revocar, §7); el cliente borra su clave de esa Mac. |

```json
{
  "type": "state",
  "v": 3,
  "output": { "deviceId": "…", "deviceName": "MacBook Pro Speakers",
              "volume": 0.62, "muted": false, "volumeSettable": true, "muteSettable": true },
  "input":  { "deviceId": "…", "deviceName": "MacBook Pro Microphone",
              "volume": 0.80, "muted": false, "volumeSettable": true, "muteSettable": true },
  "devices": {
    "output": [{ "id": "…", "name": "…" }],
    "input":  [{ "id": "…", "name": "…" }]
  }
}
```

`volumeSettable` indica si se puede cambiar el volumen y `muteSettable` si se puede cambiar el mute; son independientes y el cliente deshabilita cada control por separado. Un canal con la clave `settable` de la v1 no se decodifica.

Si no hay dispositivo por defecto para un scope, su clave va presente con valor `null` (`"input": null`). Omitir la clave es un error de decodificación, igual que cualquier otro campo faltante.

`devices` trae, por scope, los dispositivos que se pueden elegir (§5.2), ordenados por nombre. El activo se reconoce por `deviceId`. La lista se actualiza en todos los clientes al conectar o desconectar dispositivos.

El `deviceId` es el UID del dispositivo (`kAudioDevicePropertyDeviceUID`), no el `AudioObjectID`, porque el UID es estable entre reinicios.

Un `setVolume` con `value` fuera de 0.0–1.0 (o `NaN`) es inválido: no se recorta. `LevelDeckKit` se niega a codificarlo y lo rechaza al decodificar, y el agente responde `error` con `invalidValue`. Un `type` desconocido o un campo faltante también son errores de decodificación y también se responden con `invalidValue`; la conexión sigue abierta.

Un `error` va solo al cliente que mandó el comando. El `state` que resulta de un comando va a todos, así que lo que hace un cliente se refleja en los demás.

Se envía siempre el snapshot completo, no diffs. El payload es pequeño y así se evita todo un tipo de bugs de sincronización. Los envíos de `state` se agrupan (coalescing) a un máximo de 30 por segundo, siempre con el último estado, y no se reenvía un snapshot idéntico al anterior: así cada cambio produce un único evento aunque llegue por varias vías (el comando del cliente y el listener de CoreAudio).

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

**Fase 2 — Conexión local (sin seguridad, solo en desarrollo).** Servidor con Bonjour y WebSocket en claro, que solo existe en builds Debug (flag `LEVELDECK_INSECURE_TRANSPORT`, §5.3). El transporte y el protocolo viven en `LevelDeckKit`. El cliente iOS descubre, conecta y muestra los faders de salida y entrada, cada uno con mute, sincronizados en ambas direcciones. `muteSettable` entra al protocolo (se adelanta desde la Fase 4). Se adelantan desde la Fase 5 el throttle de envíos (máx. 30/s, siempre con el valor final) y la supresión de eco del fader (§6.2). Un overlay de debug en el iPhone muestra el RTT de `setVolume` → `state`.
*Listo cuando:*
- el agente anuncia `_leveldeck._tcp` y el iPhone lo descubre y conecta sin configurar IP;
- los faders de salida y entrada con mute se sincronizan en ambas direcciones en menos de 100 ms en la red local (medido con el overlay de RTT);
- arrastrar el fader no produce saltos ni tiembla por el eco;
- un test de integración en `LevelDeckKit` levanta el servidor en loopback y verifica `hello` → `setVolume` → `state`, y pasa en CI;
- el transporte en claro no se puede compilar en Release (verificado en CI);
- verificación manual en iPhone físico (permiso de red local y Bonjour), con checklist en el PR.

**Fase 3 — Emparejamiento y TLS-PSK.** QR, Keychain, TLS-PSK y revocación (§7). Se agrega `TransportSecurity.tlsPSK` (TLS 1.2 con ciphersuite PSK, una clave por dispositivo, §5.3). Decisión sobre el modo en claro: las apps dejan de usarlo en toda configuración; queda solo en `LevelDeckKit` Debug para tests. El `hello` gana `deviceId` y el protocolo el código `notPaired`. Pantallas nuevas en el iPhone: emparejamiento (cámara) y ajustes (Macs emparejadas). Ventana del QR y lista de dispositivos con revocación en el agente. Textos nuevos en inglés y español.
*Listo cuando:*
- un iPhone sin emparejar no puede conectar (el handshake falla con identidad desconocida y con clave incorrecta);
- uno emparejado conecta automáticamente, sin volver a escanear;
- uno revocado pierde la conexión activa al instante y no puede volver a conectar;
- los tres criterios se prueban con tests de integración en loopback (`PairingIntegrationTests`) que pasan en CI, junto con el vencimiento y la cancelación del QR y la supervivencia de las sesiones activas al reiniciar el listener;
- verificación manual en iPhone físico (permiso de cámara, escaneo, reconexión tras reabrir la app, revocación con la app abierta), con checklist en el PR.

**Fase 4 — Mixer completo.** Selector de dispositivo (`devices` y `setDefaultDevice`), manejo de controles no configurables en el cliente y varios clientes simultáneos. Ajuste de protocolo: `settable` pasa a `volumeSettable` y la versión sube a `v: 2`. (El mute en el cliente y `muteSettable` se adelantaron a la Fase 2.) Textos nuevos en inglés y español.
*Listo cuando:*
- tocar el nombre del dispositivo en el iPhone abre un selector con los dispositivos de ese scope y el activo marcado; elegir uno lo vuelve el dispositivo por defecto de la Mac;
- la lista se actualiza en vivo en todos los clientes al conectar o desconectar audífonos, interfaces USB o monitores; si desaparece el activo, los clientes reflejan el que elija macOS;
- no se muestran los dispositivos ocultos; los virtuales (BlackHole, Zoom, Teams) sí, si tienen streams en ese scope;
- un control no configurable se muestra deshabilitado sin afectar al otro (un dispositivo con mute y sin volumen mantiene el mute usable); conectar un monitor HDMI sin control de volumen deshabilita el fader sin romper nada;
- elegir un dispositivo que desapareció entre la lista y el toque responde `deviceNotFound` y el cliente se recupera solo;
- con varios clientes, lo que hace uno se refleja en los demás, y el que arrastra un fader no se ve afectado por los otros;
- la lógica de dispositivos se prueba con el mock de `AudioControlling` (conexión y desconexión en caliente, activo que desaparece, flags independientes) y un test de integración con dos clientes en loopback, y pasan en CI;
- verificación manual con hardware real, con checklist en el PR.

**Fase 5 — Pulido.** Reconexión con backoff, hápticos, login item y opción de desactivarlo. (La supresión de eco y el throttle se adelantaron a la Fase 2.) Endurecimiento del `hello` con challenge-response: el protocolo sube a `v: 3` (§5.3, §8). Textos nuevos en inglés y español.
*Listo cuando:*
- dormir y despertar la Mac, apagar y encender el Wi-Fi de cualquiera de los dos lados o cambiar de red recupera la conexión sin intervención: el agente vuelve a anunciarse, re-suscribe los listeners de CoreAudio y el iPhone reconecta solo;
- sin conexión, los faders se deshabilitan con "Reconectando…" y el cliente reintenta a 1 s, 2 s, 4 s, 8 s y 10 s; al volver la app al frente reconecta de inmediato;
- háptico ligero al llegar a 0 % y 100 % arrastrando y al activar o desactivar el mute;
- el agente se registra como login item, el menú permite desactivarlo y, si macOS pide aprobación, lo indica y abre los ajustes de ítems de inicio;
- un dispositivo emparejado que declara el `deviceId` de otro es rechazado, y por lo tanto no puede sobrevivir a su propia revocación;
- tests de integración en loopback (`HelloAuthIntegrationTests`, `ReconnectTests`) que pasan en CI;
- verificación manual con checklist en el PR: dormir y despertar la Mac, Wi-Fi apagado y encendido en cada lado, app en segundo plano varios minutos y de vuelta al frente, login item al reiniciar la Mac.

## 10. Después de v1

- **Volumen por aplicación.** → v2, §20. La alternativa sin driver son los process taps de Core Audio (macOS 14.4+); la Fase 10 es un spike con go/no-go. Lo que decía aquí la v1 (driver virtual tipo AudioServerPlugIn, BackgroundMusic, SoundSource) queda como alternativa descartada en §20.2.
- **Widget / Centro de Control (iOS 18+).** Los Control Widgets ejecutan App Intents de corta duración y no pueden mantener una conexión abierta. Cada acción tendría que conectar, hacer el handshake TLS, enviar y cerrar. Hay que medir si la latencia resultante es aceptable.
- **Mac → Mac o iPad.** iPad → v2, Fase 8 (§17). Un cliente para Mac sigue fuera de alcance.
- **Endurecer el emparejamiento.** (a) Derivar la clave definitiva del exporter de la primera sesión TLS para que el QR sea de un solo uso de verdad (§7.2). (b) Forward secrecy: probar `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256` (0xCCAC) en Network.framework; si negocia, preferirlo. (c) Atar la prueba del `hello` a la sesión TLS: incluir en el HMAC un valor del exporter de esa conexión (`sec_protocol_metadata_create_secret`) además del `nonce`. Hoy la prueba no está atada al canal; un relay requeriría que el dispositivo víctima firme un `nonce` ajeno, y la víctima no puede completar un handshake con el atacante porque no comparten clave, así que no es explotable en nuestra amenaza. Ninguna de las tres cambia el flujo del usuario.
- ~~**Verificar el `deviceId` del `hello`.**~~ Hecho en la Fase 5 con challenge-response (§5.3, §8).

## 11. Pruebas

- **LevelDeckKit:** tests unitarios de codificación del protocolo (incluidos `challenge` y la `proof` del `hello`), formato del QR (`PairingCode`, `PresharedKey`), `HelloProof` (vector fijo, otra clave, otro `deviceId`, otro `nonce`, prueba truncada), política del `hello` en `PairingManager` (pendiente, conocido, desconocido, fallo del store), lógica de throttle y coalescing, `Backoff` y `FaderBoundary`.
- **AudioController:** detrás de `AudioControlling`. Tests con mock para la lógica de estado (incluida la de dispositivos: conexión y desconexión en caliente, activo que desaparece, dispositivo que desaparece antes del toque, errores de lectura de la lista y flags independientes) y una verificación manual contra el hardware real (CoreAudio no se puede mockear de forma útil a bajo nivel; el filtro de ocultos y de streams se verifica ahí).
- **Integración:** tests que levantan el servidor de `LevelDeckKit` en loopback con TLS-PSK. `LoopbackIntegrationTests` verifica el ciclo completo `hello` → `setVolume` → `state`, `setMute`, errores y dos clientes con claves distintas a la vez (claves fijas de prueba, sin `authorizer`). Desde la Fase 4, con dos clientes: la lista y la selección de dispositivo llegan a ambos, el activo que desaparece también, `deviceNotFound` solo le llega a quien lo pidió, y el que arrastra (con su `MixerState`) no se mueve por los cambios del otro y queda invalidado si el otro cambia de dispositivo. `PairingIntegrationTests` cubre la Fase 3 con `PairingManager` y un store en memoria: dispositivo emparejado conecta y reconecta, identidad desconocida y clave incorrecta se rechazan en el handshake, `hello` sin `deviceId` se rechaza, dispositivo revocado pierde la conexión activa y no vuelve, el QR cancelado o vencido no sirve, y una sesión activa sobrevive al reinicio del listener. `PlaintextSmokeTests` mantiene vivo el transporte en claro de Debug. Desde la Fase 5, `HelloAuthIntegrationTests` (con `PairingManager`): un cliente que pasa el TLS con su clave pero declara el `deviceId` de otro es rechazado con `notPaired` y el otro sigue conectado; un dispositivo que intenta disfrazarse no puede sobrevivir a su propia revocación; un `hello` sin prueba o con una prueba reciclada de otra sesión se rechaza; un cliente que no responde el `challenge` se cierra por timeout. `ReconnectTests` usa un reloj manual inyectado: los reintentos salen exactamente a 1 s, 2 s, 4 s, 8 s, 10 s y 10 s (y no un instante antes), `reconnectNow` salta la espera y reinicia el contador, el cliente reconecta solo cuando el agente vuelve a su puerto (y el backoff arranca de nuevo desde 1 s), y no reintenta después de `notPaired`. Lo único que corre en tiempo real es que el intento falle o conecte en loopback.
- **AudioModel:** `restart` (al despertar) vuelve a suscribir los listeners y relee ambos scopes, probado con el mock.
- **Keychain real:** `KeychainStoreTests` (solo macOS) usa `KeychainPairedDeviceStore` contra el llavero de login, con un servicio único por test que se borra al terminar: store vacío sin error, dispositivos ordenados por `pairedAt` con sus claves, ida y vuelta del `agentId` y revocación de un solo dispositivo.
- **Checklist manual por fase,** basado en los criterios de "Listo cuando".

## 12. Distribución

Instalación directa desde Xcode en mis dispositivos. Con Apple ID gratuito, la firma de iOS caduca a los 7 días. Con cuenta de desarrollador de pago se puede usar TestFlight o firma de un año. El agente de macOS se firma localmente y no necesita notarización para uso propio.

---

# Parte II — v2

> Deriva de la sección "v2" de `INTENT.md`, que está en borrador. Estado: **borrador 2.0** para revisión. Las decisiones que faltan están en §21, cada una con la opción recomendada; hasta que se tomen, el spec asume la recomendada.
>
> La Parte I (§1–§12) describe la v1 tal como quedó y sigue siendo la referencia de todo lo que la v2 no cambia: emparejamiento (§7), TLS-PSK (§5.3), challenge-response del `hello` (§8), reconexión (§6.2), localización (§3) y pruebas (§11). Donde la v2 reemplaza algo de la Parte I, se dice explícitamente.

## 13. Resumen de la v2

Tres cambios de estructura y uno condicional:

1. **Tiras por dispositivo.** El agente observa y controla volumen y mute de todos los dispositivos de salida y de entrada, no solo del predeterminado. El estado pasa de "dos canales más una lista de nombres" a "una tira por dispositivo y scope, más el predeterminado de cada scope". El protocolo sube a **v4** (§15). El mixer del cliente y el menú de la Mac muestran una tira por dispositivo.
2. **App universal.** El target iOS pasa a iPhone y iPad, con un layout para ancho regular (landscape, Stage Manager, ventanas redimensionables) y el layout compacto de hoy para iPhone y Slide Over (§17).
3. **Estructura de la interfaz revisada.** Auditoría de la UI actual en iPhone, iPad y menú de la Mac, con propuestas por área (§18). El spec fija la estructura; el diseño visual se itera aparte.
4. **Volumen por app (condicional).** Un spike sobre process taps de Core Audio (macOS 14.4+) que termina en un go/no-go documentado. Solo si es "go" hay una fase de implementación (§20, Fase 10 y 11).

Se mantienen: todo nativo y local, sin dependencias de terceros, lógica compartida en `LevelDeckKit` y `LevelDeckAgentKit`, textos en inglés y español, snapshot completo en cada `state`, y el modelo de seguridad de la Fase 3 y la Fase 5 sin cambios.

### 13.1 Vocabulario nuevo

| Término | Qué es |
|---|---|
| **Tira** (`Strip`) | El estado de un dispositivo en un scope: `deviceId`, nombre, tipo de transporte, volumen, mute y configurabilidad de cada uno. Un dispositivo con streams de entrada y de salida (una interfaz USB) produce dos tiras, una por scope, con volúmenes independientes: en CoreAudio el volumen es una propiedad por scope del mismo objeto. |
| **`StripID`** | `(scope, deviceId)`. Es la clave de todo lo que en la v1 iba por `Scope`: gates de eco, throttles, medidor de RTT, listeners. |
| **Predeterminado** | El dispositivo que macOS usa para el scope (`kAudioHardwarePropertyDefault{Output,Input}Device`). En la v2 es una marca sobre una tira, no una tira aparte. |
| **Tira oculta** | Una tira que el cliente no muestra por preferencia del usuario. Es estado del cliente, por Mac emparejada; el agente no la conoce. |

## 14. Agente macOS en la v2

### 14.1 Comportamiento

Lo de §5.1 se mantiene (barra de menú, login item, despertar, cambio de red). Cambia el contenido del menú:

- Una sección **Salida** y una **Entrada**, cada una con una tira por dispositivo: nombre, ícono según transporte, slider de volumen y botón de mute. La tira del predeterminado va marcada y ofrece "Usar como predeterminado" en las demás (menú contextual o botón secundario; la forma exacta es una propuesta de §18.3).
- Las secciones se pueden contraer. Por defecto se muestran expandidas; el estado se recuerda en `UserDefaults`. Con más de ~6 tiras por sección el menú crece hasta un máximo y desplaza (`ScrollView`), para que nunca exceda la pantalla.
- Estado del servicio, dispositivos emparejados, emparejar, login item y Salir siguen igual. Las propuestas para moverlos a una ventana de ajustes están en §18.3; no son parte de esta fase.

### 14.2 Servicio de audio por dispositivo (`AudioControlling` v2)

La API se parametriza por `StripID` en vez de por `Scope`:

```swift
public struct StripID: Hashable, Sendable { public var scope: Scope; public var deviceId: String }

public struct AudioStrip: Sendable, Equatable {
    public var id: StripID
    public var deviceName: String
    public var transport: DeviceTransport   // builtIn, bluetooth, usb, hdmi, displayPort, thunderbolt, airPlay, virtual, aggregate, other
    public var volume: Float                // 0.0–1.0
    public var muted: Bool
    public var volumeSettable: Bool
    public var muteSettable: Bool
}

@MainActor public protocol AudioControlling: AnyObject {
    func strips(_ scope: Scope) throws(AudioControlError) -> [AudioStrip]        // todas las tiras del scope, ordenadas por nombre
    func strip(_ id: StripID) throws(AudioControlError) -> AudioStrip?           // una tira; nil si el dispositivo ya no existe
    func defaultDevice(_ scope: Scope) throws(AudioControlError) -> String?      // deviceId, o nil si no hay
    func setVolume(_ value: Float, strip: StripID) throws(AudioControlError)
    func setMute(_ muted: Bool, strip: StripID) throws(AudioControlError)
    func setDefaultDevice(_ deviceId: String, scope: Scope) throws(AudioControlError)
    func startObserving(_ onChange: @escaping @MainActor (AudioChange) -> Void)
    func stopObserving()
}

public enum AudioChange: Sendable, Equatable {
    case strip(StripID)          // volumen, mute o data source de una tira
    case defaultDevice(Scope)    // cambió el predeterminado del scope
    case deviceList              // se conectó o desconectó algo: releer las tiras de ambos scopes
    case controlsChanged(deviceId: String) // los controles del dispositivo cambiaron: re-resolver sus tiras
    case serviceRestarted        // coreaudiod se reinició: releer todo
}
```

Reglas, además de las de §5.2 que siguen valiendo (normalización 0–1, `AudioObjectIsPropertySettable`, `volumeSettable` y `muteSettable` independientes, filtro de ocultos y de streams, UID como identidad, solo el default de salida y entrada y no el de sonidos del sistema):

- **Qué dispositivos tienen tira.** Los mismos que la lista de la v1 (§5.2): con al menos un stream en el scope y no ocultos. Un dispositivo sin control de volumen ni de mute tiene tira igual, con ambos controles deshabilitados: sigue siendo un destino que se puede volver predeterminado.
- **Volumen por dispositivo, no solo del default.** `VolumeControl.resolve(device, scope)` ya trabaja sobre un `AudioObjectID` arbitrario, así que la lectura y escritura por tira reutiliza la misma resolución (volumen virtual principal → `VolumeScalar` en el elemento principal → `VolumeScalar` por canal). Lo que hay que verificar contra hardware en la Fase 6 es que `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` responde en dispositivos que no son el default (ver §14.4).
- **Data source.** En Macs Intel anteriores al chip T2, "Built-in Output" tenía dos fuentes de datos (parlantes internos y audífonos) con volumen guardado por fuente. Se escucha `kAudioDevicePropertyDataSource` por tira y un cambio dispara `.strip(id)`, que relee volumen y mute. En Macs con T2 y Apple Silicon, parlantes y jack son dispositivos distintos y el cambio llega como alta y baja en la lista, así que esto cubre solo hardware viejo: es barato y no se expone en el protocolo.
- **Un `deviceId` desconocido** en `setVolume` o `setMute` (se desconectó entre el `state` y el comando) lanza `.deviceNotFound(scope)`; el agente relee la lista y el siguiente `state` la corrige. Igual que `setDefaultDevice` en la v1.
- **Dispositivo sin volumen** (`volumeSettable == false`): `setVolume` lanza `.notSettable`; el cliente lo muestra deshabilitado y no lo manda. Igual para mute.

### 14.3 Observar todos los dispositivos a la vez

La v1 tenía cuatro listeners de sistema y dos o tres por scope sobre el dispositivo default. La v2 tiene listeners sobre cada dispositivo con tira:

| Objeto | Propiedad | Evento |
|---|---|---|
| Sistema | `kAudioHardwarePropertyServiceRestarted` | `.serviceRestarted` |
| Sistema | `kAudioHardwarePropertyDevices` | `.deviceList` |
| Sistema | `kAudioHardwarePropertyDefaultOutputDevice` / `DefaultInputDevice` | `.defaultDevice(scope)` |
| Cada dispositivo × scope | las direcciones de volumen que `VolumeControl.resolve` eligió (1 o N por canal) | `.strip(id)` |
| Cada dispositivo × scope | `kAudioDevicePropertyMute` (si existe) | `.strip(id)` |
| Cada dispositivo × scope | `kAudioDevicePropertyDataSource` (si existe) | `.strip(id)` |
| Cada dispositivo | `kAudioDevicePropertyDeviceIsAlive` | `.deviceList` (el dispositivo se está yendo; la lista lo confirma) |
| Cada dispositivo | `kAudioDevicePropertyDeviceHasChanged`, `kAudioObjectPropertyControlList` | `.controlsChanged(deviceId)`: los controles del dispositivo aparecieron o desaparecieron. Se vuelve a correr `VolumeControl.resolve` para cada scope del dispositivo y se re-suscriben **solo** los listeners de esas tiras. Apple documenta `DeviceHasChanged` justamente para esto: "clients should re-evaluate everything they need to know about the device, particularly the layout and values of the controls". |
| Cada dispositivo | `kAudioObjectPropertyName` | `.strip(id)` para cada scope del dispositivo (nombre editado en Configuración de Audio MIDI) |

El bloque y la cola con que se registró cada listener se guardan y se pasan idénticos a `AudioObjectRemovePropertyListenerBlock` (la v1 ya lo hace con `Listener.block`); un bloque recreado no coincide y el listener queda vivo.

Alternativa evaluada y descartada: un solo listener comodín por dispositivo (`kAudioObjectPropertySelectorWildcard`), como hace SimplyCoreAudio. Menos registros, pero dispara por cada propiedad del dispositivo (`DeviceIsRunning`, tamaño de buffer, formato de stream) y obliga a filtrar por selector en cada callback. Con direcciones precisas cada evento ya dice qué releer. Si la medición de la Fase 6 muestra que el registro por direcciones es lento con muchos dispositivos, el comodín es el plan B y no cambia la API de `AudioControlling`.

Cómo escala:

- **Cantidad.** Una Mac típica tiene entre 4 y 15 dispositivos (parlantes, micrófono, un monitor, audífonos Bluetooth, una interfaz, BlackHole en dos o tres variantes, Zoom, Teams). Con 3–5 listeners por tira más 3 por dispositivo son 40–100 bloques registrados. Apple no documenta un límite ni un costo por cantidad; lo documentado es que cada registro retiene su bloque y su cola hasta que se quita, así que el costo real es memoria y la disciplina de quitarlos. BackgroundMusic registra cuatro direcciones por dispositivo y SimplyCoreAudio un comodín por dispositivo, en todos los dispositivos, sin problemas reportados. Se anota como riesgo a medir en la Fase 6 (§14.4), no como problema conocido.
- **Suscripción por diferencia.** Al recibir `.deviceList` no se tiran y recrean todos los listeners: se calcula la diferencia entre el conjunto de tiras anterior y el nuevo, se quitan los listeners de las tiras que desaparecieron y se agregan los de las nuevas. Las tiras que siguen conservan sus listeners. Esto evita perder un evento entre el "quitar todo" y el "volver a poner todo", y hace que conectar un dispositivo sea O(1) en listeners, no O(N).
- **Lectura dirigida.** Cada evento relee solo lo que nombra: `.strip(id)` relee esa tira (3–5 llamadas a la HAL); `.defaultDevice(scope)` relee un `AudioObjectID`; `.deviceList` relee la lista de UIDs de ambos scopes y las tiras nuevas; `.serviceRestarted` y `restart()` (despertar) releen todo y re-suscriben todo. La v1 releía lista y canal en cada evento; en la v2 releer todo en cada evento sería O(N) llamadas a la HAL por cada movimiento de fader, y no hace falta.
- **Un solo evento por cambio.** `AudioModel.onChange` sigue avisando una vez por cambio aplicado; el servidor sigue agrupando a 30/s y descartando snapshots idénticos (§16.1). Ráfagas (despertar: todos los dispositivos reaparecen en ~1 s y disparan decenas de listeners) producen decenas de relecturas dirigidas pero un puñado de `state`, por el coalescing.
- **Listener sobre un dispositivo muerto.** Al desconectar un dispositivo, `DeviceIsAlive` pasa a 0 y `kAudioHardwarePropertyDevices` cambia; el orden entre ambos no está documentado, así que la suscripción por diferencia se hace con la lista, y `DeviceIsAlive` solo adelanta la relectura. `AudioObjectRemovePropertyListenerBlock` sobre el objeto muerto devuelve `kAudioHardwareBadObjectError` y es inofensivo. El patrón de la v1 (`activeListeners` con IDs, bloques que se ignoran si ya no están activos, `remove` que ignora el error) se conserva tal cual. Un Bluetooth que vuelve puede traer otro `AudioObjectID`: todo se indexa por UID, como en la v1.
- **Main actor.** Los listeners siguen entregando en la cola principal y `AudioControlling` sigue siendo `@MainActor`, como en la v1. La lectura de una tira son llamadas a la HAL de microsegundos. La escritura en dispositivos Bluetooth puede tardar más (el driver negocia con el periférico): se mide en la Fase 6 y, si una escritura excede ~5 ms de forma consistente, la escritura de volumen pasa a una cola propia (`AudioHAL` actor) manteniendo `AudioModel` en el main actor. Es una decisión diferida a la medición, no una decisión de diseño de hoy.

### 14.4 Riesgos a verificar contra hardware (Fase 6)

Esto no se puede probar con el mock; va en el checklist manual de la Fase 6 con criterio de éxito explícito:

| Riesgo | Cómo se verifica | Si falla |
|---|---|---|
| `VirtualMainVolume` no responde en un dispositivo que no es el default. **Riesgo bajo:** la propiedad es por `AudioObject` y su semántica documentada (aplica al control maestro o a los canales del layout preferido) no menciona al default; SimplyCoreAudio, eqMac y decenas de apps la leen y escriben en dispositivos arbitrarios con `AudioObjectGetPropertyData`. Lo que Apple no documenta es que funcione fuera de la API `AudioHardwareService` deprecada; está verificado por uso, no por documento. | Leer y escribir el volumen de los parlantes internos mientras el default son los audífonos | `VolumeControl.resolve` ya cae a `VolumeScalar`; si tampoco, la tira queda con `volumeSettable: false` y se documenta el dispositivo |
| Escribir volumen en un Bluetooth no activo no persiste o tarda | Poner los AirPods al 30 % sin ser default, volverlos default, ver que quedaron al 30 %; medir el tiempo de `setVolume` | Mostrar el valor que la HAL devuelve (nunca el enviado) y, si tarda, mover la escritura fuera del main actor (§14.3) |
| Ráfaga de listeners al despertar produce `state` repetidos o un menú que tiembla | Dormir con 8+ dispositivos, despertar, contar `state` enviados (log Debug) | El coalescing y el dedup ya existen; si el problema es la relectura, agregar una ventana de agrupación de 50 ms en `AudioModel.refresh` |
| Un dispositivo con volumen por canal reporta valores distintos por canal | Interfaz USB con L/R separados: mover un canal desde Configuración de Audio MIDI | La v1 promedia y escribe igual en todos; se mantiene y se documenta |
| Aggregate y Multi-Output devices | Crear uno en Configuración de Audio MIDI con dos dispositivos | macOS no les da control de volumen (los controles de Ajustes de Sonido quedan inactivos): la tira aparece con `transport: aggregate` y ambos controles deshabilitados. Controlar sus sub-dispositivos queda fuera de la v2. |
| Los controles de un dispositivo cambian sin que cambie la lista (driver que agrega un control, `DeviceHasChanged`) | BlackHole: cambiar la configuración del driver; monitor que gana mute al cambiar de entrada | `.controlsChanged` re-resuelve y re-suscribe solo esa tira |

## 15. Protocolo v4

Sigue siendo JSON sobre WebSocket con TLS-PSK, payload plano, `v` solo en `hello` y `state`, snapshot completo en cada `state`, sin diffs. El handshake (`challenge` → `hello` con `proof`) es idéntico al de la v3 (§8): la v4 no toca nada de seguridad. Como en la v1, ambas apps se instalan juntas y no hay compatibilidad hacia atrás: un cliente v3 recibe `unsupportedVersion`.

### 15.1 `state`

```json
{
  "type": "state",
  "v": 4,
  "defaults": { "output": "AppleUSBAudioEngine:…", "input": null },
  "strips": {
    "output": [
      { "deviceId": "BuiltInSpeakerDevice", "deviceName": "MacBook Pro Speakers", "transport": "builtIn",
        "volume": 0.62, "muted": false, "volumeSettable": true, "muteSettable": true },
      { "deviceId": "AppleUSBAudioEngine:…", "deviceName": "Scarlett 2i2", "transport": "usb",
        "volume": 1.0, "muted": false, "volumeSettable": false, "muteSettable": false }
    ],
    "input": [
      { "deviceId": "BuiltInMicrophoneDevice", "deviceName": "MacBook Pro Microphone", "transport": "builtIn",
        "volume": 0.80, "muted": false, "volumeSettable": true, "muteSettable": true }
    ]
  }
}
```

- `strips.output` y `strips.input` traen **todas** las tiras del scope, ordenadas por nombre (`localizedStandardCompare`), las mismas que la lista `devices` de la v1 más su estado. Una lista vacía es válida (Mac mini sin micrófono → `"input": []`).
- `defaults.<scope>` es el `deviceId` del predeterminado o `null` si no hay. Siempre presente. Si no es `null`, tiene que coincidir con una tira del scope; si no coincide (dispositivo oculto activo, §5.2), el cliente muestra "Predeterminado: <sin tira>" y no marca ninguna. Es el mismo caso que en la v1 mostraba el nombre sin marcar el selector.
- `transport` es un enum cerrado: `builtIn`, `bluetooth`, `usb`, `hdmi`, `displayPort`, `thunderbolt`, `airPlay`, `virtual`, `aggregate`, `other`. Sale de `kAudioDevicePropertyTransportType`; lo que no mapea es `other`. Sirve para el ícono de la tira; el cliente no toma decisiones con él.
- Las claves `output`, `input` y `devices` de la v3 **desaparecen**. Un `state` con ellas y sin `strips` no se decodifica.
- Regla de tamaño: una tira son ~170 bytes; una Mac con 12 tiras produce un `state` de ~2.3 KB. A 30/s son ~70 KB/s hacia cada cliente. Es lo que cuesta mantener el snapshot completo y se acepta (§16.1 tiene la tabla).

### 15.2 Cliente → Agente

| type | payload | Efecto |
|---|---|---|
| `hello` | `{ v: 4, deviceName, deviceId, proof }` | Sin cambios salvo `v`. |
| `setVolume` | `{ scope, deviceId, value: 0.0–1.0 }` | Cambia el volumen de esa tira. `deviceId` **obligatorio** (decisión §21 D2). Tira desconocida → `deviceNotFound`. `volumeSettable: false` → `notSettable`. `value` fuera de rango o `NaN` → `invalidValue`, sin recorte, igual que la v1. |
| `setMute` | `{ scope, deviceId, muted }` | Igual, para el mute. |
| `setDefaultDevice` | `{ scope, deviceId }` | Sin cambios (§8). |

### 15.3 Agente → Cliente

`challenge` y `error` sin cambios. Los códigos de error son los mismos cinco; `deviceNotFound` ahora también aplica a `setVolume` y `setMute`.

### 15.4 Reglas que se conservan

Se copian aquí porque el lector de la Parte II no debería tener que volver a §8 para lo esencial:

- Un `error` va solo a quien mandó el comando; el `state` resultante va a todos.
- Los `state` se agrupan a 30/s como máximo, siempre con el último snapshot, y no se reenvía un snapshot idéntico al anterior.
- Un mensaje que no se puede decodificar se responde con `invalidValue` y la conexión sigue abierta.
- El `deviceId` es el UID (`kAudioDevicePropertyDeviceUID`), estable entre reinicios.

### 15.5 Modelos en `LevelDeckKit/Protocol`

`ChannelState` y `DeviceList` se retiran. Entran `StripID`, `Strip` (la proyección al protocolo de `AudioStrip`), `DeviceTransport`, `StripList` (`output`/`input` con subscript por `Scope`, como `DeviceList`) y `Defaults`. `StateSnapshot` pasa a `{ defaults, strips }` con `subscript(_ id: StripID) -> Strip?` y `func strips(_ scope: Scope) -> [Strip]`. `ProtocolVersion.current = 4`. Los tests de codificación de `AgentMessageTests` y `ClientMessageTests` se reescriben para la forma nueva, incluidos: `strips` vacío por scope, `defaults` con `null`, `defaults` que no coincide con ninguna tira (se decodifica; la regla es del cliente), `transport` desconocido (error de decodificación: el enum es cerrado y ambas apps se instalan juntas), y `setVolume` sin `deviceId` (error de decodificación).

## 16. Sincronización a escala

La v1 sincronizaba dos controles. La v2 sincroniza 2N, con N variable y con la posibilidad de mover varios a la vez (multitouch en el iPad, varios clientes). Los mecanismos son los mismos (`SendThrottle`, `EchoGate`, `MixerState`, coalescing del servidor); cambia la clave (de `Scope` a `StripID`) y se agregan reglas para que el costo no crezca con N donde no debe.

### 16.1 Lado del agente

| Mecanismo | v1 | v2 |
|---|---|---|
| Relectura tras un evento de la HAL | lista + canal del scope | solo lo que el evento nombra (§14.3) |
| Construcción del snapshot | en cada `onChange` (`currentState()`) | **perezosa:** `onChange` marca `dirty`; el snapshot se construye una vez cuando el throttle dispara (máx. 30/s), no una vez por listener. En una ráfaga de 40 eventos en 100 ms se construyen 3 snapshots, no 40. |
| Coalescing y dedup | 30/s, snapshot idéntico no se reenvía | igual; el dedup compara `StateSnapshot` por `Equatable` (O(N) comparaciones de structs, trivial) |
| Codificación JSON | una por `state` enviado | igual: una por tick de 33 ms, compartida entre todas las sesiones (se codifica una vez y se manda el mismo `Data` a cada cliente; hoy `MessageConnection.send` codifica por sesión, se cambia a codificar antes del bucle) |
| Comandos entrantes | 1 cliente × 1 fader × 30/s | K clientes × F dedos × 30/s. Cada comando es una escritura a la HAL de microsegundos (salvo Bluetooth, §14.3). Con 3 clientes y 2 dedos cada uno son 180 escrituras/s: sin problema. No se limita del lado del agente; el límite es el throttle de cada cliente. |

Tamaño del `state` por cantidad de tiras (JSON compacto con claves ordenadas, sin espacios):

| Tiras totales | Tamaño aprox. | A 30/s |
|---|---|---|
| 2 (la v1) | 0.5 KB | 15 KB/s |
| 8 | 1.6 KB | 48 KB/s |
| 16 | 3.0 KB | 90 KB/s |
| 32 (caso extremo, muchos virtuales) | 5.8 KB | 175 KB/s |

Todo cabe de sobra en Wi-Fi local (decenas de MB/s) y el 30/s solo se alcanza mientras alguien arrastra. Si en la Fase 7 el RTT medido con 16+ tiras supera los 100 ms de la v1, la primera palanca es bajar la frecuencia de `state` a 20/s para clientes que no están arrastrando (el `state` de eco al que arrastra puede seguir a 30/s); la segunda, excluir `deviceName` y `transport` del snapshot periódico. Ninguna se implementa por adelantado: son las salidas si la medición lo pide.

### 16.2 Lado del cliente

- **`MixerState` por tira.** `channels: [Scope: ChannelState]` pasa a `strips: [StripID: Strip]`; `gates`, `heldRemoteVolume` e `invalidatedDrags` se indexan por `StripID`. `apply(snapshot)` recorre las tiras del snapshot: para la tira que se arrastra (o se acaba de soltar) retiene el volumen y aplica el resto; las demás se aplican tal cual. Una tira que estaba y ya no viene se elimina (y si se estaba arrastrando, el arrastre queda invalidado, ver abajo). `devices` desaparece: la lista de dispositivos ahora **son** las tiras.
- **Invalidación del arrastre.** La regla de la v1 ("si cambia el default a mitad del arrastre, manda el agente") deja de tener sentido: el comando lleva `deviceId`, así que cambiar el default no redirige nada. La regla nueva es más simple: un arrastre queda invalidado si **su tira desaparece del snapshot** o si su `volumeSettable` pasa a `false`. Ambas son cambios del dispositivo, no del default. Se cancela el envío pendiente y no se manda más hasta el próximo toque, como en la v1.
- **Throttle por tira.** Un `ThrottledSender<Float>` por tira que se está arrastrando, creado bajo demanda y descartado al soltar (no uno por tira existente: con 30 tiras serían 30 timers ociosos). 30/s por tira. Con multitouch, F dedos producen F × 30/s: se acepta (§16.1). No hay cap global del cliente; si se quisiera, el lugar es `MixerModel`, no `SendThrottle`.
- **Multitouch.** En el iPad se permite arrastrar varias tiras a la vez (`VerticalFader` ya maneja su propio `dragStart`; los gestos de tiras distintas son independientes en SwiftUI). En el iPhone también, aunque en la práctica no se use. Cada tira tiene su gate de eco, así que dos dedos no se pisan.
- **RTT por tira.** `RoundTripMeter` indexa pendientes por `StripID`; el overlay Debug muestra el último RTT de la tira que se movió.
- **Render por diferencia.** Con 30 `state`/s y 16 tiras, si la vista del mixer observa "el snapshot" entero, SwiftUI re-evalúa 16 tiras 30 veces por segundo. Es barato (son structs) pero innecesario, y es lo primero que se nota en un iPad con la ventana grande. `MixerModel` mantiene un `StripModel` `@Observable` por tira y, al aplicar un snapshot, escribe en cada uno **solo si su `Strip` cambió** (`Equatable`). Así una tira que no cambió no invalida su vista. La lista de tiras (agregar, quitar, reordenar) es una propiedad aparte que cambia solo cuando cambian los IDs. Es el equivalente en el cliente de la lectura dirigida del agente.
- **Tiras ocultas.** `HiddenStrips` en `LevelDeckKit/Sync` (lógica pura, probada): conjunto de `StripID` por `agentId`, persistido por la app en `UserDefaults`. Ocultar una tira no la saca del snapshot ni del `MixerState`; solo la vista la filtra. Si la tira oculta es la predeterminada, se muestra igual, con la marca de "oculta" para que el usuario entienda por qué aparece (decisión §21 D4). Si el agente deja de reportar una tira oculta, la preferencia se conserva: al volver el dispositivo sigue oculto.
- **Orden.** Estable por nombre, el mismo del agente; la marca del predeterminado no reordena (decisión §21 D3). Las tiras ocultas se quitan sin alterar el orden del resto.

### 16.3 Lo que no cambia

`SendThrottle`, `EchoGate`, `Backoff`, `FaderBoundary`, `ReconnectPolicy`, `SyncTiming` (30/s y 300 ms) y toda la lógica de reconexión de §6.2 siguen iguales y con los mismos tests. La v2 los usa con otra clave.

## 17. Cliente universal (iPhone y iPad)

### 17.1 Target

Un solo target `LevelDeck`, un solo bundle ID, un solo `Localizable.xcstrings`. Cambios en `project.yml`:

- `TARGETED_DEVICE_FAMILY: "1,2"` (es el valor por defecto de XcodeGen para iOS; hoy está forzado a `"1"`).
- Orientaciones con build settings por familia: `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone: UIInterfaceOrientationPortrait` (como hoy) e `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad` con las cuatro. En el `Info.plist` resultante quedan como `UISupportedInterfaceOrientations~ipad`. Apple exige las cuatro para ventanas redimensionables (TN3192) y App Store Connect ya avisa si faltan.
- `UIRequiresFullScreen` **no** se declara. Está deprecado desde iPadOS 26 y en iPadOS 27 deja de tener efecto; una app sin la clave es redimensionable en Stage Manager y en el modo de ventanas de iPadOS 26. La pantalla de arranque generada (`UILaunchScreen_Generation`, ya presente) es requisito y ya se cumple.
- `UIApplicationSupportsMultipleScenes` **no** se declara (una ventana; decisión §21 D6). Si algún día se activa, el modelo ya está por escena: `DiscoveryView` es dueña del `MixerModel`; lo único compartido sería `PairedAgents` (Keychain), que ya tolera lecturas desde varias vistas.
- Sin cambios en `Info.plist`: Bonjour, red local y cámara aplican igual. El iPad tiene cámara trasera para el QR.
- CI: `generic/platform=iOS Simulator` compila el target universal sin cambios en `verify.sh`. Los runners `macos-15` traen simuladores de iPad (`iPad Pro 13-inch (M4)`, `iPad Air 11-inch (M3)`, entre otros) por si la Fase 8 agrega un test de UI; el job debería listar los disponibles con `xcrun simctl list devices available` antes de elegir uno, porque han faltado en algunas imágenes.

### 17.2 Layout adaptativo

La regla es una: **la clase de tamaño horizontal decide la estructura; el tamaño de la ventana decide cuántas tiras caben**. No se pregunta "¿es iPad?".

| Contexto | `horizontalSizeClass` | Estructura |
|---|---|---|
| iPhone portrait, Slide Over, ventana estrecha de Stage Manager (< ~600 pt) | compact | La de hoy: `NavigationStack`, descubrimiento → mixer; mixer con tiras verticales en desplazamiento horizontal (decisión §21 D5) |
| iPad a pantalla completa, Split View ancho, ventana ancha de Stage Manager | regular | `NavigationSplitView` con barra lateral (Macs encontradas y emparejadas, Ajustes) y el mixer como detalle. La barra lateral se puede ocultar y el mixer ocupa todo. |

Mixer en ancho regular:

- Dos grupos, **Salida** e **Entrada**, lado a lado (o apilados si la ventana es más alta que ancha: `ViewThatFits` decide). Cada grupo es una fila de tiras verticales.
- Ancho de tira fijo (el mismo que el iPhone, ~88 pt de fader más márgenes). Si no caben todas, el grupo desplaza horizontalmente; nunca se encogen por debajo del ancho táctil. La altura del fader crece con la ventana hasta un máximo.
- Con la ventana estrecha se cae al layout compacto automáticamente por la clase de tamaño. Un tamaño mínimo de ventana solo se puede **pedir** (`windowResizability(.contentMinSize)` con `frame(minWidth:)`, iOS 17+), y Apple dice que es una preferencia que el sistema cumple si puede; en iPadOS 18 con Stage Manager la restricción puede venir `nil`. Por eso el layout tiene que sobrevivir cualquier ancho compacto, y por eso el compacto del iPhone es también el del iPad estrecho: no hay un tercer layout.
- iPadOS 26 pone los controles de ventana en el borde inicial de la barra de herramientas: los botones de la barra (emparejar, ajustes) usan `.toolbar` estándar, que el sistema desplaza; no se colocan controles propios ahí. Los atajos se declaran con `.commands` en la `App`, que en iPadOS 26 además genera la barra de menús del iPad; en iPadOS 17 y 18 siguen funcionando como atajos.
- Teclado físico y trackpad: atajos para el predeterminado de salida (`⌘↑` / `⌘↓` suben y bajan 5 %, `⌘M` mute) y `hoverEffect` en faders y botones. Son detalles de la Fase 8; el resto del layout no depende de ellos.
- Los sheets de la v1 (selector de dispositivo, ajustes, emparejamiento) pasan a popover o a la barra lateral en regular (`presentationCompactAdaptation` cubre el cambio automático donde aplica).
- `NavigationSplitView` con `.navigationSplitViewStyle(.balanced)`: la barra lateral queda lado a lado con el mixer en vez de superponerse en portrait, que es lo que se espera de un panel de control. En compacto colapsa solo a una pila, igual que hoy.
- Tamaño de ventana: `containerRelativeFrame` para lo que depende del ancho disponible; `GeometryReader` solo dentro del fader, como hoy. Un cambio de tamaño interactivo (arrastrar el borde de la ventana) no debe cortar un arrastre de fader en curso: el `MixerModel` no se recrea al cambiar de clase de tamaño (la vista raíz cambia de estructura, el modelo es el mismo).

Mixer en ancho compacto (iPhone): ver §21 D5. La recomendación es desplazamiento horizontal con dos grupos apilados (Salida arriba, Entrada abajo), cada uno con sus tiras en fila, y un indicador de página. El iPhone en portrait muestra 3–4 tiras por grupo sin desplazar.

### 17.3 Textos

Varios textos de la v1 dicen "iPhone" ("This iPhone is no longer paired", "removes its key from this iPhone", "Open LevelDeck on the iPhone…" en la ventana del QR de la Mac). Se reemplazan por "this device" / "este dispositivo", o por el modelo cuando aporta (`UIDevice.current.model` da "iPhone" o "iPad"). Se agregan al catálogo con traducción; `check-localizations.py` sigue cubriendo el target.

### 17.4 Estado por dispositivo cliente

Las tiras ocultas y el estado de las secciones (contraídas, orden de la última vez) son preferencias del dispositivo cliente, guardadas en `UserDefaults` con clave por `agentId`. No se sincronizan entre iPhone y iPad (no hay iCloud por principio de "local primero"; se acepta).

## 18. Auditoría de la interfaz y propuestas

Lo que sigue es una auditoría de la UI actual, hecha sobre el código de la v1, con propuestas por área. **Son opciones, no decisiones.** El spec fija la estructura (qué elementos hay y cómo se organizan); el diseño visual (formas, color, tipografía, animación) se itera aparte en Claude Design a partir de estas notas. Cada propuesta indica si toca la estructura (y entonces entra en una fase) o solo lo visual (y entonces es material para la iteración de diseño).

### 18.1 iPhone — Mixer

Estado actual (`MixerView`, `VerticalFader`): dos tiras (Salida, Entrada) en un `HStack`; cada tira tiene título, porcentaje, fader de 88 pt de ancho (rectángulo redondeado con relleno proporcional, sin cap), botón de mute (`bordered`, tinte rojo cuando está en mute), nombre del dispositivo como botón con chevron (abre un sheet), nota de configurabilidad. Arriba, un banner de estado que aparece y desaparece; abajo, el overlay de RTT en Debug.

| # | Hallazgo | Propuesta | Tipo |
|---|---|---|---|
| A1 | El banner de estado empuja el layout al aparecer: los faders saltan de tamaño al reconectar o al mostrar un error. | Reservar el espacio del banner siempre (altura fija) o superponerlo (`overlay(alignment: .top)`) para que el mixer no se mueva. | Estructura (Fase 7) |
| A2 | El fader no tiene cap ni escala; el ícono de la app sí tiene caps y ticks. El relleno proporcional se lee como barra de progreso, no como fader. | Opción a: cap deslizante sobre riel con ticks a 0/25/50/75/100 (coherente con el ícono). Opción b: mantener el relleno pero con un borde de cap y marcas laterales. Opción c: dejar la barra y reforzar el porcentaje. | Visual |
| A3 | El porcentaje va arriba, el mute abajo, el nombre más abajo: tres alturas distintas de texto por tira. Con N tiras, la fila de nombres de largo variable (2 líneas) desalinea las tiras. | Fijar la altura de cada zona de la tira (nombre en una zona de altura fija con truncado, no 2 líneas variables) para que todas las tiras alineen sus faders. | Estructura (Fase 7) |
| A4 | El nombre del dispositivo abre un selector modal para cambiar el default. En la v2 el selector desaparece (todas las tiras están a la vista). | El nombre deja de ser botón. La marca de predeterminado va en la cabecera de la tira; cambiar el default es una acción sobre la tira: opción a, botón "estrella" en la cabecera; opción b, menú contextual (long press) con "Usar como predeterminado" y "Ocultar"; opción c, ambas. | Estructura (Fase 7) |
| A5 | El mute usa tinte rojo cuando está activo y el fader se atenúa a gris. Dos señales para el mismo estado, y rojo suele significar "grabando" en audio. | Una sola señal: fader atenuado con el ícono tachado, sin rojo; o rojo solo si el diseño lo adopta como color de "mute" en toda la app. | Visual |
| A6 | La nota de configurabilidad ("This device doesn't allow…") ocupa dos líneas bajo la tira y cambia su altura. | Reemplazar por un ícono de candado junto al control deshabilitado, con la explicación en `accessibilityHint` y en un popover al tocarlo. | Estructura (Fase 7) |
| A7 | No hay retroalimentación visual de "alguien más movió esto" (otro cliente o la Mac): el fader se mueve solo, sin distinción. | Opción: animar el cambio remoto (interpolar el fader en ~120 ms) y el propio sin animación; así se distingue por movimiento, no por color. | Visual |
| A8 | El overlay de RTT en Debug compite con el layout. | Moverlo a un popover accesible desde un gesto oculto (triple toque en el título) o a Ajustes. | Estructura (Fase 7, Debug) |
| A9 | Solo portrait; en landscape no hay layout. | Con la v2 el landscape del iPhone cae en compact y muestra el mismo mixer con más tiras visibles; no se bloquea. | Estructura (Fase 8) |

### 18.2 iPhone — Descubrimiento, emparejamiento y ajustes

Estado actual (`DiscoveryView`, `PairingView`, `SettingsView`): la pantalla raíz es la lista de Macs; al encontrar una emparejada, empuja el mixer. Ajustes y emparejamiento son sheets desde la barra.

| # | Hallazgo | Propuesta | Tipo |
|---|---|---|---|
| B1 | Al abrir la app se ve la lista de Macs un instante y después salta al mixer. La pantalla que el usuario quiere es el mixer; la lista es un medio. | Invertir: la raíz es el mixer (con estado "Buscando tu Mac…" si no hay conexión) y la lista de Macs es un sheet o un menú en el título (`Menu` en la barra con las Macs encontradas). En regular, la lista es la barra lateral. | Estructura (Fase 8) |
| B2 | `ContentUnavailableView` "Looking for Macs…" e instrucciones solo si la lista está vacía; si hay una Mac no emparejada, el botón "Pair" está en la fila y también en la barra (dos entradas al mismo flujo). | Una sola entrada visible: "Emparejar" en la fila de la Mac no emparejada; el ícono de la barra solo cuando no hay ninguna Mac en la lista. | Estructura (Fase 8) |
| B3 | "Forget" solo por swipe: poco descubrible. | Agregar el botón en la fila (o en el detalle de la Mac) además del swipe. | Estructura (Fase 8) |
| B4 | Ajustes muestra "Protocol v3": dato de desarrollo. | Mover a una sección "Acerca de" o solo en Debug. | Visual |
| B5 | La alerta de revocación ("This iPhone is no longer paired") es correcta pero dice "iPhone". | Texto por modelo (§17.3). | Estructura (Fase 8) |

### 18.3 Mac — Menú de la barra

Estado actual (`MenuContent`, `ChannelControl`, `ServiceStatusView`, `PairedDevicesView`, `LoginItemView`): ventana de 300 pt con dos sliders (Salida, Entrada) con mute y nombre del dispositivo, separador, estado del servicio (nombre, **puerto**, clientes), dispositivos emparejados con punto de conexión y **X de revocar sin confirmación**, "Pair New Device…", interruptor de login item, "Protocol v3" y Quit.

| # | Hallazgo | Propuesta | Tipo |
|---|---|---|---|
| C1 | Con una tira por dispositivo el menú se vuelve largo: 12 tiras × ~50 pt = 600 pt más lo demás. | Secciones Salida/Entrada contraíbles, con la del predeterminado siempre visible; altura máxima con desplazamiento (§14.1). Alternativa: el menú muestra solo los predeterminados y un botón "Todos los dispositivos…" abre una ventana con el mixer completo. | Estructura (Fase 6) — la elección es §21 D7 |
| C2 | Revocar un dispositivo emparejado es un clic sin confirmación, destructivo (el iPhone tiene que volver a escanear). | Confirmación (`confirmationDialog`) o revocar desde un menú contextual con el nombre del dispositivo. | Estructura (Fase 6) |
| C3 | El estado del servicio muestra el puerto y "Protocol v3": detalle técnico en una UI para el usuario final. | Mostrar "Listo · 2 dispositivos conectados"; puerto y protocolo solo en Debug o en un "Acerca de". | Visual |
| C4 | Login item, emparejados y estado del servicio comparten el menú con el audio, que es lo que se usa a diario. | Mover emparejados, login item y "Acerca de" a una ventana de Ajustes (`Settings` scene, `⌘,`) y dejar el menú para el audio y "Emparejar…". | Estructura (Fase 6) — §21 D7 |
| C5 | El slider de la Mac no distingue el default de los demás (hoy solo hay default). | Marca de predeterminado en la tira y "Usar como predeterminado" en el menú contextual de las demás, coherente con A4. | Estructura (Fase 6) |
| C6 | El ícono de la barra no indica mute ni conexión. | Opción: variante del ícono con la salida en mute (barra tachada) y un punto cuando hay un cliente conectado. Es opcional y cabe como iteración visual. | Visual |
| C7 | No hay ventana del mixer: quien quiere ver todo tiene que abrir el menú y mantenerlo abierto. | La misma alternativa de C1: ventana "Mixer" opcional (`Window` scene) que reutiliza las tiras del menú. | Estructura — §21 D7 |

### 18.4 iPad (nuevo)

No hay UI que auditar; las propuestas fijan la estructura de la Fase 8 (§17.2) y dejan al diseño lo demás:

| # | Propuesta | Tipo |
|---|---|---|
| D1 | Barra lateral: Macs (emparejadas primero, con estado de conexión), Ajustes al pie. Detalle: mixer. | Estructura (Fase 8) |
| D2 | Mixer: Salida e Entrada como dos grupos con título; tiras verticales de ancho fijo; el fader crece con la altura. Cabecera de grupo con el nombre del predeterminado y contador de tiras ocultas ("2 ocultas", toca para mostrarlas). | Estructura (Fase 8) |
| D3 | Modo "solo predeterminados" (un interruptor en la cabecera) que colapsa cada grupo a una tira grande, para usar el iPad como el control único de la v1 cuando hay muchas tiras. | Estructura, opcional (Fase 8) |
| D4 | Densidad: en ventanas grandes, mostrar el porcentaje dentro del fader en vez de arriba, para ganar altura. | Visual |
| D5 | Atajos de teclado y `hoverEffect` (§17.2). | Estructura (Fase 8) |

## 19. Fases de la v2

Numeración continua con la v1. Cada fase termina con algo que se puede usar y probar, y con textos nuevos en inglés y español. El orden sigue la prioridad del intent: primero el agente (verificable solo con el menú, como la Fase 1), después el protocolo y el cliente, después el iPad, después el diseño, y al final el spike de volumen por app.

**Fase 6 — Tiras por dispositivo en el agente.** `AudioControlling` v2 (`StripID`, `AudioStrip`, `AudioChange`, §14.2), `CoreAudioController` con listeners por dispositivo y suscripción por diferencia (§14.3), `AudioModel` con tiras por scope y predeterminado por scope, lectura dirigida. El menú muestra una tira por dispositivo en dos secciones contraíbles, con la marca de predeterminado, "Usar como predeterminado" y confirmación al revocar (C1, C2, C5). El protocolo **no cambia todavía**: `AudioServerBridge` proyecta las tiras predeterminadas al `state` v3, así el iPhone de la v1 sigue funcionando mientras se verifica el agente contra hardware.
*Listo cuando:*
- el menú muestra una tira por dispositivo de salida y de entrada, cada una controla su dispositivo, y los cambios externos (teclado, Ajustes del Sistema, Configuración de Audio MIDI, el botón de volumen de unos audífonos Bluetooth) mueven la tira correcta y solo esa;
- conectar o desconectar un dispositivo agrega o quita su tira sin recrear los listeners de las demás (verificado con un log Debug del conteo de listeners: conectar uno suma sus listeners, no reinicia el total);
- el predeterminado de cada scope está marcado y se puede cambiar desde otra tira; si desaparece el predeterminado, la marca pasa a la que elija macOS;
- una tira sin volumen o sin mute deshabilita solo ese control;
- el checklist de riesgos de §14.4 está completo en el PR, con el resultado de cada fila;
- dormir y despertar con 8+ dispositivos no produce tiras duplicadas ni listeners huérfanos;
- `AudioModelTests` y `DeviceSelectionTests` se reescriben con el mock por tira: conexión y desconexión en caliente con diferencia de listeners, predeterminado que desaparece, `deviceNotFound` en `setVolume` de una tira que ya no está, flags independientes por tira, `serviceRestarted` relee todo, y el `state` v3 proyectado sigue correcto; pasan en CI.

**Fase 7 — Protocolo v4 y mixer por tira en el iPhone.** Modelos nuevos en `LevelDeckKit/Protocol` (§15.5), `ProtocolVersion.current = 4`, `AudioServerBridge` emite `strips` y `defaults`, snapshot perezoso y codificación única por tick en el servidor (§16.1). Cliente: `MixerState` por `StripID`, invalidación por desaparición de la tira, throttle por tira bajo demanda, `StripModel` observable por tira, `HiddenStrips`, RTT por tira (§16.2). Mixer compacto con dos grupos y desplazamiento horizontal (D5), banner con espacio reservado (A1), zonas de altura fija por tira (A3), marca y acción de predeterminado en la tira (A4), candado en vez de nota (A6), ocultar y mostrar tiras. El selector de dispositivo y `DevicePickerView` se retiran.
*Listo cuando:*
- el iPhone muestra todas las tiras de la Mac, cada una controla su dispositivo, y lo que se mueve en la Mac o en otro cliente se refleja en la tira correcta;
- arrastrar una tira mientras otro cliente mueve otra no produce saltos en ninguna; arrastrar dos tiras a la vez con dos dedos funciona y cada una manda a 30/s como máximo;
- desconectar el dispositivo que se está arrastrando cancela el envío pendiente y la tira desaparece sin que otro dispositivo reciba su volumen (test con el mock: la tira invalidada no manda más);
- cambiar el predeterminado durante un arrastre **no** invalida el arrastre (regla nueva, §16.2) y el `setVolume` sigue yendo al dispositivo correcto;
- el RTT de `setVolume` → `state` con 16 tiras en el snapshot se mantiene por debajo de 100 ms en la red local, medido con el overlay;
- ocultar una tira la quita del mixer, sobrevive a reconectar y a reabrir la app, y la tira predeterminada oculta se muestra igual con su marca;
- una Mac sin dispositivos de entrada muestra el grupo Entrada vacío con "Sin dispositivos", sin fallar;
- tests: codificación v4 (§15.5), `MixerStateTests` por tira (retención, invalidación por desaparición, no invalidación por cambio de default, dos tiras arrastradas a la vez), `HiddenStripsTests`, `RoundTripMeter` por tira, y `LoopbackIntegrationTests` con dos clientes sobre tiras distintas del mismo scope; pasan en CI;
- verificación manual en iPhone físico con checklist en el PR.

**Fase 8 — iPad.** Target universal (§17.1), `NavigationSplitView` en ancho regular con barra lateral y mixer como detalle (D1, D2, B1), grupos lado a lado o apilados según la ventana, Stage Manager con ventana redimensionable, textos sin "iPhone" (§17.3), atajos de teclado y `hoverEffect` (D5), descubrimiento y ajustes reorganizados (B1–B3, B5). Opcional según decisión: modo "solo predeterminados" (D3).
*Listo cuando:*
- la app corre en iPad en las cuatro orientaciones; en Stage Manager la ventana se redimensiona de ~320 pt de ancho a pantalla completa y el layout pasa de compacto a regular y de vuelta sin perder la conexión ni el estado de los faders;
- en regular, la barra lateral lista las Macs y el mixer ocupa el detalle; en Split View a un tercio, la app cae al layout compacto del iPhone;
- el iPhone no cambia de comportamiento respecto de la Fase 7 (misma app, mismo layout compacto);
- teclado: `⌘↑`/`⌘↓`/`⌘M` actúan sobre la tira predeterminada de salida; trackpad: los controles reaccionan al puntero;
- emparejar desde el iPad con la cámara funciona y la Mac lo lista con su nombre ("iPad de …");
- ningún texto visible dice "iPhone" cuando corre en iPad; `check-localizations.py` pasa;
- CI compila el target universal en Debug y Release; verificación manual en iPad físico con checklist en el PR (Stage Manager, Split View, Slide Over, teclado externo).

**Fase 9 — Diseño.** Aplicar las decisiones visuales que salgan de la iteración en Claude Design sobre las propuestas de §18 marcadas "Visual" (A2, A5, A7, B4, C3, C6, D4) más las estructurales que se hayan diferido. Esta fase no cambia el protocolo ni `LevelDeckKit`; toca solo las vistas de las tres superficies. Su alcance exacto se fija al cerrar la iteración de diseño, con un checklist propio.
*Listo cuando:*
- las tres superficies (iPhone, iPad, menú de la Mac) implementan el diseño acordado, con capturas en el PR comparadas contra los mockups;
- los cambios remotos y los propios se distinguen según lo decidido (A7);
- accesibilidad: cada tira tiene etiqueta, valor y acción ajustable en VoiceOver; Dynamic Type hasta el tamaño de accesibilidad más grande no rompe la alineación de las tiras;
- `verify.sh` pasa sin cambios en los tests de `LevelDeckKit` (prueba de que fue solo visual).

**Fase 10 — Spike: volumen por aplicación.** Un prototipo desechable (target aparte, `Spikes/AppVolumeSpike`, fuera de las apps y de los paquetes) que implementa la cadena de §20.2 para **una** app elegida a mano y mide lo que §20.6 pide. No toca `LevelDeckKit`, el protocolo ni el agente. Termina en `Design/AppVolume/GO-NO-GO.md` con los datos y una recomendación.
*Listo cuando:*
- el prototipo atenúa el audio de una app (Music o Safari) de 100 % a 0 % con rampa, sin clics, mientras las demás apps suenan directo;
- el permiso "System Audio Recording Only" se pidió una sola vez con la firma Apple Development y sobrevivió a tres rebuilds; el flujo con permiso denegado no deja la app muda (auto-test de §20.3 antes de mutear);
- se midió la latencia añadida (RTT de la señal con y sin tap), el hueco al enganchar y soltar el tap, la pérdida de inicio al reanudar una app silenciosa y el CPU en reposo y activo, cada uno en parlantes internos, en una interfaz USB y en AirPods;
- se probó cambiar el dispositivo de salida predeterminado, cambiar la frecuencia de muestreo, abrir el micrófono con AirPods (A2DP → HFP), dormir y despertar, y matar el prototipo con `kill -9` mientras atenuaba; cada caso está en el documento con lo que pasó con el audio de la app;
- `GO-NO-GO.md` responde cada criterio de §20.6 con el dato medido y termina en "go", "no-go" o "go con condiciones", y la sección v2 de `INTENT.md` se actualiza con la respuesta a su pregunta abierta.

**Fase 11 — Volumen por aplicación (solo si la Fase 10 es "go").** Boceto en §20.7; el spec detallado se escribe después del spike, con sus datos. Sube el protocolo a v5 y el deployment target del agente a macOS 14.4.
*Listo cuando:* se define al cerrar la Fase 10. Como mínimo: una tira por app que produce audio, en el menú y en los clientes; el agente vuelve al estado "sin taps" al cerrarse y limpia restos al arrancar; el permiso se explica en el menú antes de pedirlo; y la latencia medida en el spike se mantiene en la implementación real.

## 20. Volumen por aplicación: investigación y spike

Investigado sobre las cabeceras del SDK (`AudioHardware.h`, `AudioHardwareTapping.h`, `CATapDescription.h`, SDK 14.5, 15.5 y 26.5), la documentación y el sample de Apple ("Capturing system audio with Core Audio taps"), una respuesta de un ingeniero de Apple en los foros sobre el permiso, el código de AudioCap (Guilherme Rambo) y una docena de proyectos open source que hacen volumen por app con taps desde 2024. Se marca qué está verificado en fuentes de Apple o en código y qué es solo reportado por terceros.

### 20.1 Qué permite Core Audio

- **No existe un volumen por proceso.** Verificado en las cabeceras: las únicas propiedades de mute por proceso (`kAudioHardwarePropertyProcessIsAudible`, `kAudioDevicePropertyProcessMute`, `ProcessInputMute`) aplican al **propio** proceso que las llama. No hay equivalente al `ISimpleAudioVolume` de Windows. Una constante `kAudioProcessPropertyIsMuted` apareció en un comentario del SDK 14.5 y desapareció en el 15.5 sin llegar nunca al enum.
- **Lo que sí hay son process taps** (`AudioHardwareCreateProcessTap`, `CATapDescription`), disponibles desde **macOS 14.2** según la cabecera (`API_AVAILABLE(macos(14.2))`) y el sample de Apple; la comunidad dice "14.4" porque ahí se descubrió y se volvió confiable el permiso, sin que Apple documente una diferencia funcional. Un tap captura el audio que uno o varios procesos mandan a un dispositivo. Su única acción sobre el proceso ajeno es **silenciarlo** (`CATapMuteBehavior`: `unmuted`, `muted`, `mutedWhenTapped`), todo o nada.
- **Por lo tanto, "volumen por app" = re-enrutar.** Silenciar la app en la HAL con `mutedWhenTapped`, leer su audio por el tap, multiplicarlo por la ganancia y escribirlo al dispositivo real. El agente pasa a estar **en la cadena de audio** de las apps que atenúa. Es lo que hacen todos los proyectos open source encontrados (Atoll, per-app-audio, mac-volume-mixer, MacVolumeMixer, buried-anchor, sonicflow, VolBoost, Fader, FineTune) y, por su perfil (sin driver, permiso "System Audio", indicador morado, solo 14+), lo que Rogue Amoeba hace en SoundSource desde que deprecó su driver ACE.
- Las apps que están al 100 % y sin mute **no se tapean**: suenan directo, con latencia cero y sin costo. El tap se crea al mover el fader fuera de 100 % y se destruye al volver.
- El overlay Swift (`AudioHardwareSystem`, `AudioHardwareTap`) es macOS 15+; con target 14 se usa la API C. macOS 26 agrega `bundleIDs` y `processRestoreEnabled` al `CATapDescription` (tapear por bundle ID y restaurar el tap cuando la app se relanza): útiles, pero no se puede depender de ellos.

### 20.2 Arquitectura del tap (la que se prototipa en el spike)

Por cada app atenuada (o grupo de procesos de una app):

1. `CATapDescription(stereoMixdownOfProcesses: [AudioObjectID de los procesos])`, `isPrivate = true`, `muteBehavior = .mutedWhenTapped`. Los procesos son objetos `Process` de la HAL (`kAudioHardwarePropertyTranslatePIDToProcessObject`), no PIDs.
2. `AudioHardwareCreateProcessTap` y lectura de `kAudioTapPropertyFormat`.
3. Un **aggregate device privado** cuyo `MainSubDevice` (reloj) es el dispositivo de salida real y cuya `TapList` contiene el tap con `DriftCompensation = true` y `TapAutoStart = true`. El tap tiene que ir en el diccionario de creación; agregarlo después falla en silencio.
4. **Un solo IOProc** sobre el aggregate: el buffer de entrada trae los frames del tap, el de salida es el dispositivo real; se aplica la ganancia con rampa (8–20 ms, `vDSP_vrampmul`) y se copia. Mismo reloj para captura y reproducción, así que no hay drift entre ambos lados. La variante de dos IOProcs con ring buffer (captura en un aggregate, reproducción aparte) agrega otro buffer de latencia y obliga a manejar drift a mano: descartada.
5. Al volver a 100 %: `AudioDeviceStop` → `DestroyIOProcID` → `DestroyAggregateDevice` → `DestroyProcessTap`, en ese orden. Al destruir el tap, la app vuelve a sonar directo.

Por qué `mutedWhenTapped` y no `muted`: el mute queda ligado a que alguien esté leyendo el tap. Si el IOProc se detiene o el agente muere, la semántica documentada ("for the duration of the read activity on the tap no audio is sent to the audio hardware") dice que el audio vuelve al hardware. Con `muted` el silencio es incondicional, y hay reportes de apps que quedaron mudas tras un crash del mixer.

Alternativas evaluadas y descartadas:

| Alternativa | Por qué no |
|---|---|
| Driver virtual `AudioServerPlugIn` (lo que hace BackgroundMusic; lo que hacía SoundSource con ACE) | Instalación con root en `/Library/Audio/Plug-Ins/HAL` y reinicio de `coreaudiod`; se vuelve el dispositivo predeterminado y rompe el selector de salida de la v1; playthrough con dos IOProcs; depuración casi imposible (SIP). Rogue Amoeba lo deprecó por lo mismo. Contradice "invisible en la Mac" y "simple antes que completo". |
| ScreenCaptureKit solo audio | Permiso de grabación de pantalla, con el recordatorio mensual de macOS 15+. Descartable. |
| Audio Units, `PreferredChannelLayout`, controles del dispositivo | Son propiedades del dispositivo, no de un cliente ajeno. No sirven. |

### 20.3 El permiso

- **Qué es.** "System Audio Recording Only" (`kTCCServiceAudioCapture`), en Ajustes del Sistema › Privacidad y seguridad › Grabación de pantalla y audio del sistema. Es independiente del de grabación de pantalla. Requiere `NSAudioCaptureUsageDescription` en el `Info.plist` (macOS 14.2+). Se reporta que la clave **no funciona vía `INFOPLIST_KEY_*`**: el agente necesita un `Info.plist` físico fusionado, como ya lo tiene el target iOS. Va traducido en `InfoPlist.xcstrings`.
- **Cuándo se pide.** Verificado con un ingeniero de Apple: no hay API para pedirlo; el sistema lo pide solo la **primera vez que arranca un aggregate que contiene un tap** (`AudioDeviceStart`). Crear el tap y leer su formato no lo disparan.
- **Qué pasa si se niega.** `AudioDeviceStart` devuelve `noErr` y el IOProc recibe ceros para siempre, **pero el tap con `muted` o `mutedWhenTapped` silencia igual a la app**. Es el riesgo principal de UX: permiso negado más mute igual a app muda sin explicación. Regla para el spike y la Fase 11: el agente **nunca** crea un tap que silencia sin antes haber confirmado que recibe audio. Auto-test como el de mac-volume-mixer: un tap `unmuted` sobre el propio agente reproduciendo un tono a −90 dBFS; si el tono no vuelve, el permiso no está y el menú lo dice con el botón a Ajustes.
- **Cómo saber si está concedido.** No hay API pública. AudioCap usa la SPI privada `TCCAccessPreflight` cargada con `dlsym`; queda **excluida** por el principio de "frameworks del sistema, nada privado". El auto-test es la única vía aceptable.
- **Firma.** TCC ata el permiso a la identidad de firma. Con firma ad hoc (`Sign to Run Locally`) el permiso se pierde en cada rebuild; con la identidad "Apple Development" del Personal Team y el bundle ID fijo, se conserva. El agente ya se firma así (§12), así que en Debug no hay que reaprobar en cada build, pero sí hay que lanzarlo como `.app` por LaunchServices.
- **Recordatorio periódico.** El de macOS 15 ("permitir por un mes") aplica a grabación de pantalla sin el picker del sistema; no se encontró evidencia de que aplique a "System Audio Recording Only", y varios proyectos migran a taps justamente para evitarlo. Se verifica en el spike dejando el prototipo instalado el tiempo que dure la fase.
- **Indicador.** Mientras un tap captura, macOS muestra el punto morado de grabación en la barra de menús. Es visible y permanente mientras haya una app atenuada. Va contra "invisible en la Mac" y es una de las preguntas del go/no-go: si molesta, la respuesta es que el punto solo aparece cuando alguna app está fuera del 100 %.

### 20.4 Latencia

Apple no publica cifras. Lo reportado, consistente entre proyectos:

| Situación | Latencia añadida |
|---|---|
| App al 100 % sin mute (sin tap) | 0 ms |
| App atenuada, un IOProc en el aggregate | ~10–20 ms (un buffer del aggregate con compensación de drift; 512 frames a 48 kHz son 10.7 ms) |
| Enganchar o soltar el tap (mover desde o hacia 100 %) | hueco de 50–200 ms en el audio de esa app |
| App que estaba en silencio y vuelve a sonar con tap activo | se pierden las primeras decenas de ms (20–150 ms, peor en Bluetooth) |
| Cambio de ganancia | perceptible en ~10 ms; la rampa por buffer evita clics |
| CPU | 0 % en reposo (sin taps); ~1–2 % con taps activos, una multiplicación vectorial por buffer |

Para un mixer de volumen (no para monitoreo ni juegos) 10–20 ms son aceptables; el hueco al enganchar es lo que más se nota y por eso el tap se crea al salir de 100 % y no en cada movimiento.

### 20.5 Riesgos

| Riesgo | Evidencia | Mitigación en la Fase 11 |
|---|---|---|
| **Renegociación de frecuencia de muestreo** (44.1 ↔ 48 kHz; AirPods A2DP → HFP al abrir un micrófono): el tap entrega ceros o falla por formato, y con `mutedWhenTapped` **la app queda muda** hasta reconstruir | Múltiples issues (oats, vo, meeting-transcriber, macparakeet) | Escuchar `NominalSampleRate` y `StreamConfiguration` del aggregate y `kAudioTapPropertyFormat` del tap; reconstruir tap y aggregate con debounce (~400 ms) y presupuesto de reintentos (1/2/5/15/30 s); mientras se reconstruye, destruir el tap primero para que la app suene directo |
| **Bug de macOS 26.x:** buffers a cero tras minutos con el IOProc corriendo normal, sin señal que lo detecte | Foro de Apple sin respuesta; per-app-audio implementa un watchdog | Watchdog: si el tap entrega solo ceros N segundos mientras el proceso reporta `IsRunningOutput`, reconstruir (máx. 3 por ruta, 30 s mínimo entre intentos) |
| **Crash del agente con taps activos:** evidencia contradictoria sobre si la app queda muda | A favor de que se restaura: semántica de `mutedWhenTapped`, aggregate privado no persistente, "taps cannot outlive the app" (mac-volume-mixer). En contra: reportes con `muted` y taps "huérfanos" durante cambios de dispositivo | Nunca `muted` como estado persistente; teardown ordenado en `applicationWillTerminate`; limpieza de aggregates residuales al arrancar. El spike lo prueba con `kill -9`. |
| **Cambio del dispositivo de salida predeterminado:** el aggregate está atado a un UID | Todos los proyectos lo manejan reconstruyendo | Escuchar `DefaultOutputDevice` (ya lo hace la v2) y reconstruir los taps sobre el dispositivo nuevo; la v2 ya tiene el modelo de dispositivos |
| **Procesos ayudantes:** Safari y toda app WebKit comparten `com.apple.WebKit.GPU`; Chrome tiene un Audio Service; Discord, cuatro procesos. El PID que suena no es el de la app | AudioCap y los mixers agrupan por app padre | Agrupar por bundle ID de la app responsable (`NSRunningApplication`); Safari y WebKit como un solo grupo "Safari y apps web". Un ayudante nuevo a mitad de reproducción no entra al tap hasta reconstruirlo |
| **Listeners de `IsRunningOutput` que no disparan** (macOS 15.0.1) | Foro sin respuesta; todos los proyectos agregan un poll | Listener más poll de respaldo a 1 Hz sobre la lista de procesos |
| **Auto-exclusión en apps de captura:** Discord, Zoom y OBS excluyen "su propio" audio por proceso; si el agente re-reproduce el de Discord, los demás en la llamada oyen su propia voz | Issue en vorssaint-utils | Lista de apps que nunca se tapean (videollamadas y captura), editable |
| **El propio agente** aparece en la lista de procesos de audio (por el auto-test) | AudioCap lo filtra | Excluir el PID propio |
| Spatial audio, AirPlay, dispositivos multicanal | Sin pruebas en ningún proyecto; en 14.2 un bug bajaba el volumen a la mitad con 4+ canales | El spike prueba AirPods con audio espacial; AirPlay queda documentado como no soportado si falla |
| Error intermitente `'nope'` (`kAudioCodecIllegalOperationError`) al crear tap o aggregate | Foro sin respuesta; asociado a aggregates residuales | Limpiar restos antes de recrear; reintentar con backoff |
| `coreaudiod` se reinicia o la Mac despierta | Cabecera: "any state the client has… must be re-established" | `kAudioHardwarePropertyServiceRestarted` ya existe en la v1: reconstruir todos los taps ahí |

### 20.6 Criterios de go/no-go

El spike (Fase 10) responde cada fila con un dato medido. "Go" requiere todas las filas obligatorias en verde.

| # | Criterio | Umbral | Obligatorio |
|---|---|---|---|
| G1 | Latencia añadida con tap activo | ≤ 25 ms en parlantes internos y USB; ≤ 40 ms en AirPods | Sí |
| G2 | Hueco al enganchar y soltar el tap | ≤ 250 ms, sin clic ni pop | Sí |
| G3 | Permiso negado | Ninguna app queda muda; el prototipo lo detecta con el auto-test y lo reporta | Sí |
| G4 | Crash del prototipo (`kill -9`) con una app atenuada | La app vuelve a sonar sola en ≤ 5 s, sin reiniciarla ni reiniciar `coreaudiod` | Sí |
| G5 | Cambio de salida predeterminada y cambio de frecuencia de muestreo | La app sigue sonando (directo o atenuada) tras ≤ 2 s; nunca muda de forma permanente | Sí |
| G6 | AirPods: abrir el micrófono (A2DP → HFP) con la app atenuada | Igual que G5 | Sí |
| G7 | Dormir y despertar con una app atenuada | El tap se reconstruye o se libera; la app suena al despertar | Sí |
| G8 | CPU con dos apps atenuadas | ≤ 3 % en un Apple Silicon base | Sí |
| G9 | Permiso con firma Apple Development | Pedido una vez; sobrevive a tres rebuilds y a reiniciar la Mac | Sí |
| G10 | Recordatorio periódico del permiso | Ninguno durante la fase | No (se anota) |
| G11 | Punto morado en la barra de menús | Aceptable para el usuario del intent, sabiendo que aparece solo con apps atenuadas | No (es un juicio, no una medición) |
| G12 | Audio espacial / AirPlay | Funciona o queda documentado como no soportado | No |

"Go con condiciones" es la salida esperada si G1–G9 pasan y G11 incomoda: se implementa con un interruptor "Volumen por app" apagado por defecto en el menú, que explica el permiso y el indicador antes de activarse.

### 20.7 Boceto de la Fase 11 (solo si es "go")

Se detalla después del spike; lo que sigue fija la forma para que el resto de la v2 no la contradiga.

- **Módulo nuevo** `AgentTaps` en `LevelDeckAgentKit`, detrás de un protocolo `AppAudioControlling` con mock, igual que `AudioControlling`. `AppMixer` mantiene un `AppTap` (tap + aggregate + IOProc) por app atenuada y la lista de apps que producen audio (`ProcessObjectList`, `IsRunningOutput`, poll de respaldo). El IOProc es código en tiempo real: sin asignaciones, locks ni ARC dentro del bloque; la ganancia se lee de un `Float` atómico.
- **Deployment target del agente** a macOS 14.4 (el iOS no cambia). Con `@available(macOS 14.2, *)` como dice la cabecera, pero probado en 14.4+.
- **Protocolo v5.** El `state` gana `apps: [{ bundleId, name, volume, muted, isPlaying }]` y `appVolumeAvailable: "on" | "off" | "permissionNeeded"`. Comandos `setAppVolume { bundleId, value }` y `setAppMute { bundleId, muted }`. Snapshot completo, como siempre. La identidad es el bundle ID de la app responsable, no el PID.
- **Cliente.** Un tercer grupo de tiras, "Apps", con el mismo `StripModel` y la misma sincronización (`StripID` gana un caso `.app(bundleId)`). Sin selector de predeterminado. El ícono de la tira es el de la app (el agente manda el bundle ID; el cliente no tiene los íconos de la Mac, así que se manda un PNG pequeño en un mensaje aparte `appIcon`, o se usa un ícono genérico: decisión para el spec de la Fase 11).
- **Menú de la Mac.** Sección "Apps" con las mismas tiras, un interruptor "Volumen por app" (apagado por defecto si el go es "con condiciones") y el estado del permiso con botón a Ajustes.
- **Seguridad.** Nada cambia: los comandos nuevos van por la misma sesión autenticada. Lo único nuevo en la superficie de la Mac es el permiso TCC, que el usuario concede a mano.
- **Lista de exclusión** (videollamadas, captura) con valores por defecto y editable desde el menú.

## 21. Decisiones pendientes

Cada fila tiene la recomendación del spec y lo que se pierde con cada opción. Hasta que se decidan, el spec asume la recomendada. La misma lista, con más contexto, va al inicio del PR.

| # | Decisión | Recomendación | Alternativas y tradeoffs |
|---|---|---|---|
| D1 | **Forma del `state` v4** | `strips: { output: [...], input: [...] }` + `defaults: { output, input }` (§15.1) | *Lista plana de dispositivos con un objeto por scope adentro* (`{ id, name, output: {...}?, input: {...}? }`): menos repetición de nombre y transporte para interfaces con ambos scopes, pero el cliente tiene que aplanar para pintar tiras y el orden por scope se pierde. *Marca `isDefault` en la tira en vez de `defaults`*: más simple de pintar, pero el "no hay tira para el predeterminado oculto" no se puede expresar. |
| D2 | **`deviceId` obligatorio en `setVolume`/`setMute`** | Obligatorio. El cliente resuelve el predeterminado con `defaults`. | *Opcional = predeterminado*: cómodo para un futuro widget que solo conoce "la salida", pero reintroduce la carrera de la v1 (el default cambia entre que el cliente decide y el agente aplica) y dos caminos de código en el agente. Si el widget llega, se agrega un comando explícito `setDefaultVolume { scope, value }`. |
| D3 | **Orden de las tiras** | Estable por nombre, predeterminado marcado, sin reordenar. | *Predeterminado primero*: más útil en el iPhone con muchas tiras, pero una tira salta de posición al cambiar el default, incluso bajo el dedo. Mitigación posible: el iPhone hace scroll al predeterminado al conectar. |
| D4 | **Ocultar tiras** | Sí, en el cliente, por Mac, en la Fase 7; la predeterminada oculta se muestra igual con marca. | *No ocultar*: menos código y menos estado, pero una Mac con Zoom, Teams y tres BlackHole tiene 8 tiras que nadie quiere tocar. *Ocultar en el agente (no reportar)*: una sola configuración para todos los clientes, pero mezcla preferencia de UI con el protocolo y el snapshot deja de ser "todo lo que hay". |
| D5 | **Mixer compacto (iPhone) con muchas tiras** | Dos grupos apilados (Salida arriba, Entrada abajo), tiras verticales en desplazamiento horizontal por grupo, indicador de página. | *Pestañas Salida/Entrada*: más altura por fader, pero no se ven los dos lados a la vez (la v1 los mostraba juntos). *Lista vertical con sliders horizontales*: caben todas sin desplazar, pero deja de ser un mixer y pierde el gesto vertical de la v1. |
| D6 | **Varias ventanas en el iPad** | No en v2 (una escena). | *Sí*: gratis en estructura porque el modelo es por escena, pero duplica browser y conexiones, y "dos ventanas de la misma Mac" no aporta. |
| D7 | **Menú de la Mac con muchas tiras** | Secciones contraíbles con desplazamiento en el menú (C1), y mover emparejados y login item a una ventana de Ajustes (C4). | *Solo predeterminados en el menú + ventana "Mixer"* (C1 alternativa, C7): menú corto como hoy, pero la ventana es una superficie más que diseñar y mantener. *Todo en el menú sin ajustes aparte*: cero ventanas nuevas, pero el menú con 12 tiras más emparejados más login item es incómodo. |
| D8 | **Escritura de la HAL fuera del main actor** | Diferida a la medición de la Fase 6 (§14.3): solo si una escritura excede ~5 ms. | *Mover ya*: evita el riesgo de antemano, pero agrega un actor y saltos de aislamiento a un código que hoy es simple y se prueba fácil. |
| D9 | **Volumen por app** | Hacer el spike (Fase 10) con los criterios de go/no-go de §20.6; sin compromiso de implementar. La investigación ya dice que es viable en principio (todos los mixers open source de 2024–2026 lo hacen así) y que el costo es entrar en la cadena de audio de las apps atenuadas, con el permiso de grabación de audio del sistema y el punto morado en la barra. | *Descartar ya*: ahorra el spike, pero la pregunta sigue abierta en el intent desde la v1 y hoy sí hay una vía sin driver. *Comprometer la Fase 11 ahora*: los riesgos de §20.5 (app muda si el tap se rompe, permiso negado más mute) son reales y solo el spike dice si las mitigaciones alcanzan. |
| D10 | **Umbrales del go/no-go** (§20.6) | Los propuestos: 25 ms de latencia añadida, 250 ms de hueco, recuperación en ≤ 5 s tras crash. | Son juicio del spec, no del intent: si para el usuario 40 ms o un hueco de medio segundo son aceptables, el spike puede ser "go" con umbrales más laxos. Conviene fijarlos antes de medir para que el resultado no se acomode al dato. |


## 22. Pruebas de la v2

Complementa §11. Todo lo automático corre en `scripts/verify.sh` y en CI; lo que necesita hardware va al checklist manual de su fase.

- **LevelDeckKit:** codificación v4 (§15.5); `MixerStateTests` por tira (retención de una tira mientras otra cambia, invalidación por desaparición y por `volumeSettable` a `false`, no invalidación por cambio de predeterminado, dos arrastres simultáneos, `settle` por tira); `HiddenStripsTests` (ocultar, mostrar, predeterminada oculta, persistencia por `agentId`); `RoundTripMeter` por tira; `SendThrottle` sin cambios.
- **LevelDeckAgentKit (`AgentAudio`):** `AudioModel` con el mock por tira: `.strip` relee solo esa tira (el mock cuenta lecturas), `.deviceList` agrega y quita tiras sin releer las demás, `.controlsChanged` re-resuelve una tira, `.defaultDevice` mueve la marca, `.serviceRestarted` y `restart()` releen todo, `deviceNotFound` y `notSettable` por tira, snapshot perezoso (N eventos en una ventana producen una construcción). `AgentCoreAudio` se verifica contra hardware con el checklist de §14.4.
- **Integración en loopback:** `LoopbackIntegrationTests` con dos clientes sobre tiras distintas del mismo scope y sobre la misma tira; `deviceNotFound` solo a quien lo pidió; el `state` v4 llega idéntico a ambos; una sesión que recibe 100 eventos de tira en 100 ms recibe como máximo 4 `state` (coalescing). `PairingIntegrationTests`, `HelloAuthIntegrationTests` y `ReconnectTests` no cambian: la seguridad no cambia.
- **Rendimiento (manual, Fase 7 y 8):** RTT con 16 tiras en el snapshot por debajo de 100 ms; en el iPad, arrastrar una tira con 16 en pantalla no baja de 60 fps (Instruments, SwiftUI view body count: solo la tira arrastrada se re-evalúa a 30/s).
- **Spike (Fase 10):** las mediciones de §20.6 son el "test"; no hay tests automáticos del prototipo.
