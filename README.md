# LevelDeck

Control remoto del audio de la Mac desde el iPhone. Un agente en la barra de menú de la Mac expone el volumen y el mute de salida y entrada por la red local, y la app del iPhone los muestra como un mixer con faders sincronizados en tiempo real.

Swift y SwiftUI en ambos lados, solo frameworks del sistema. Sin servidores, cuentas, nube ni dependencias de terceros.

> **Documentos del proyecto.** El porqué está en [`INTENT.md`](INTENT.md) y el cómo en [`SPEC.md`](SPEC.md). Este README solo explica cómo compilar, instalar y usar. Si algo de aquí contradice el spec, manda el spec; si el spec contradice el intent, manda el intent.

## Qué hace

- **Descubrimiento sin configuración.** El iPhone encuentra la Mac por Bonjour (`_leveldeck._tcp`) y se conecta solo a las que ya están emparejadas.
- **Salida y entrada.** Volumen y mute de ambos, con selector del dispositivo activo (audífonos, interfaces USB, monitores, dispositivos virtuales).
- **Sincronización en ambos sentidos.** Si el volumen cambia desde el teclado de la Mac o desde otro iPhone, todos los clientes lo reflejan. El fader que estás arrastrando no salta por el eco.
- **Controles no configurables.** Si un dispositivo no permite cambiar el volumen o el mute (p. ej. HDMI), ese control se deshabilita sin afectar al otro.
- **Solo tus dispositivos.** Emparejamiento por QR y TLS-PSK con una clave por iPhone; revocar desde la Mac corta la conexión al instante.
- **Resistente.** Reconecta sola tras dormir la Mac, cambiar de red o volver la app al frente. El agente arranca al iniciar sesión.
- **Inglés y español** en ambas apps.

## Estado

v1 completa en sus fases 0–5 (ver [`SPEC.md` §9](SPEC.md#9-fases)). El volumen por aplicación y los widgets del Centro de Control quedan para después de v1 (§10).

## Requisitos

| | Versión |
|---|---|
| Mac para compilar | macOS con Xcode 16+ (Swift 6) |
| Agente | macOS 14+ |
| App | iOS 17+ (iPhone) |
| Herramientas | [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) |

El proyecto de Xcode **no se versiona**: se genera desde [`project.yml`](project.yml).

## Primeros pasos

```bash
# 1. Team ID de firma (archivo local, fuera de git)
cp Configs/Local.xcconfig.example Configs/Local.xcconfig
#    edita DEVELOPMENT_TEAM con tu Team ID

# 2. Generar el proyecto
xcodegen generate

# 3. Abrir en Xcode
open LevelDeck.xcodeproj
```

Vuelve a correr `xcodegen generate` cada vez que agregues o quites archivos, o cambies `project.yml`.

En Xcode:

1. Esquema **LevelDeckAgent** → *My Mac* → Run. Aparece el ícono en la barra de menú (no en el Dock).
2. Esquema **LevelDeck** → tu iPhone → Run. La primera vez, iOS pide permiso de red local: acéptalo. En macOS 15+ la Mac también lo pide.

### Emparejar

1. En el menú del agente: **Emparejar nuevo dispositivo…** Se abre una ventana con un QR que vence en 2 minutos.
2. En el iPhone, la Mac aparece en la lista: toca **Emparejar** y escanea el QR.
3. Listo. De ahí en adelante el iPhone se conecta solo, sin volver a escanear.

En el simulador no hay cámara: en builds Debug la ventana del QR muestra el código como texto para pegarlo.

Para revocar un iPhone, hazlo desde la lista de dispositivos del menú del agente. "Olvidar" en los ajustes del iPhone solo borra la clave del iPhone; la Mac lo sigue listando hasta que lo revoques.

## Verificación

```bash
scripts/verify.sh
```

Corre lo mismo que CI (GitHub Actions sobre `macos-15`, en cada push a `main` y `claude/**` y en cada PR):

1. `xcodegen generate`
2. Tests de `LevelDeckKit` (protocolo, emparejamiento, sync e integración en loopback con TLS-PSK)
3. Tests de `LevelDeckAgentKit` (lógica de audio con un mock de CoreAudio)
4. Build de ambas apps en Debug y Release, sin firma
5. Chequeo de que el transporte en claro de desarrollo no existe en las apps Release
6. [`scripts/check-localizations.py`](scripts/check-localizations.py): todo texto de las apps tiene traducción al español

Para iterar sobre un paquete sin generar el proyecto:

```bash
swift test --package-path Packages/LevelDeckKit
swift test --package-path Packages/LevelDeckAgentKit
```

CoreAudio real, la cámara, Bonjour en un iPhone físico y el login item no se pueden probar en CI: cada fase tiene un checklist manual en su PR, basado en los criterios de "Listo cuando" del spec.

## Estructura

```
leveldeck/
├── INTENT.md, SPEC.md       # qué y por qué / cómo
├── project.yml              # XcodeGen: fuente de verdad del proyecto
├── Configs/                 # xcconfig compartido; Local.xcconfig (Team ID) fuera de git
├── LevelDeckAgent/          # app macOS de barra de menú
├── LevelDeck/               # app iOS
├── Packages/
│   ├── LevelDeckKit/        # compartido: Protocol, Transport, Sync, Pairing
│   └── LevelDeckAgentKit/   # solo macOS: AgentAudio (lógica) y AgentCoreAudio (CoreAudio)
├── Design/AppIcon/          # arte fuente del ícono (no lo usa el build)
└── scripts/                 # verify.sh y check-localizations.py
```

La lógica vive en los paquetes, donde se prueba de forma aislada; las apps son sobre todo vistas. Detalle en [`SPEC.md` §4](SPEC.md#4-estructura-del-repositorio).

## Cómo funciona, en corto

- **Transporte.** WebSocket sobre TLS 1.2 con pre-shared key (`TLS_PSK_WITH_AES_128_GCM_SHA256`), con Network.framework. No hay canal sin cifrar: el emparejamiento también ocurre sobre TLS-PSK con la clave del QR.
- **Identidad.** Cada iPhone tiene su propia clave e identidad. Al conectar, la Mac manda un `nonce` y el `hello` responde con su HMAC, así que ningún dispositivo puede presentarse como otro.
- **Protocolo.** JSON, versión 3. El agente siempre manda el snapshot completo del estado (sin diffs), agrupado a un máximo de 30 por segundo. Ver [`SPEC.md` §8](SPEC.md#8-protocolo).
- **Claves.** En el Keychain de ambos lados: el del iPhone no migra con respaldos; la Mac usa el llavero de login.

Limitaciones de seguridad conocidas y aceptadas (sin forward secrecy, QR reutilizable dentro de su ventana de 2 minutos) en [`SPEC.md` §7.2 y §10](SPEC.md#10-después-de-v1).

## Distribución

Proyecto personal, fuera de la App Store. Se instala desde Xcode en tus propios dispositivos. Con Apple ID gratuito la firma de iOS caduca a los 7 días; con cuenta de desarrollador de pago se puede usar TestFlight o firma de un año. El agente se firma localmente y no necesita notarización para uso propio.
