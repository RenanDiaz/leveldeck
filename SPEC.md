# SPEC — LevelDeck

> Deriva de `INTENT.md`. Si algo aquí contradice el intent, manda el intent.
> Estado: borrador v1.7 (Fase 5: reconexión, hápticos, login item y challenge-response del `hello`; incluye la lectura del Keychain de la Mac en dos pasos de la v1.6.1)

## 1. Resumen

Dos apps nativas en Swift y SwiftUI que se comunican por la red local:

- **Agente macOS:** app de barra de menú que lee y controla el audio del sistema con CoreAudio y expone un servicio en la red local.
- **Cliente iOS:** app que descubre la Mac por Bonjour, se empareja una sola vez y muestra faders sincronizados en tiempo real.

Sin servidores externos, sin cuentas y sin dependencias de terceros.

## 2. Decisiones sobre las preguntas abiertas del intent

| Pregunta | Decisión para v1 | Estado |
|---|---|---|
| Volumen por aplicación | Fuera de v1. Se evalúa después (ver §10). | Provisional |
| Emparejamiento | Código QR mostrado en la Mac y escaneado desde el iPhone; la clave del QR es la PSK del handshake TLS (§7). | Decidido (Fase 3) |
| Widget / Centro de Control | Fuera de v1 (ver §10). | Provisional |
| Estilo de interfaz | Mixer con dos faders verticales (Salida, Entrada) y selector de dispositivo. | Provisional |

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

- **Volumen por aplicación.** Requiere un driver de audio virtual (tipo HAL plug-in / AudioServerPlugIn) que capture el audio de cada app. Alternativas: escribir uno propio (alto costo y firma más compleja), integrarse con BackgroundMusic (open source) o controlar SoundSource si expone automatización. Hacer un spike antes de decidir.
- **Widget / Centro de Control (iOS 18+).** Los Control Widgets ejecutan App Intents de corta duración y no pueden mantener una conexión abierta. Cada acción tendría que conectar, hacer el handshake TLS, enviar y cerrar. Hay que medir si la latencia resultante es aceptable.
- **Mac → Mac o iPad.** El cliente es SwiftUI, así que portarlo a iPad es casi gratis.
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
