# INTENT — LevelDeck

> Control remoto del audio de la Mac desde el iPhone

## Por qué existe

Quiero controlar el audio de mi Mac desde el iPhone con la misma naturalidad con la que Logic Remote controla una sesión de Logic, pero aplicado al audio del sistema y no a un DAW.

Hoy, para ajustar el volumen tengo que estar frente a la Mac: usar el teclado, la barra de menú o los ajustes. Quiero que el iPhone funcione como una superficie de control física: tomarlo, mover un fader y listo.

## Qué significa que funcione

- Abro la app en el iPhone y, sin configurar nada, encuentra mi Mac y ya puedo controlarla.
- Muevo un fader y el volumen cambia al instante, sin retraso perceptible.
- Si el volumen cambia desde la Mac (teclado, otra app), el iPhone lo refleja. Los dos lados cuentan siempre la misma verdad.
- Se siente como un instrumento, no como un formulario: gestos directos, respuesta inmediata y feedback claro.
- Solo mis dispositivos pueden controlar mi Mac.

## Qué quiero poder controlar

En orden de importancia (1 y 2 tienen la misma prioridad):

1. Volumen general de salida y mute.
2. Volumen de entrada (micrófono o interfaz) y mute.
3. Elegir el dispositivo de salida y de entrada activos.
4. Volumen por aplicación. Es deseable, pero sé que macOS no lo ofrece de forma nativa. Quiero entender el costo antes de comprometerme con esto.

## Principios

- **Nativo de Apple.** Swift y SwiftUI en ambos lados, con frameworks del sistema. Nada de capas web ni runtimes extra.
- **Local primero.** Todo ocurre en la red local, sin servidores externos, cuentas ni nube.
- **Invisible en la Mac.** El agente vive discreto en la barra de menú, arranca solo y no estorba.
- **Simple antes que completo.** Prefiero una app que haga pocas cosas y las haga perfectas a una que haga muchas a medias.

## Fuera de alcance (por ahora)

- Publicarla en la App Store. Es un proyecto personal, para mis dispositivos.
- Control fuera de la red local.
- Controlar DAWs, reproducción multimedia u otras funciones de la Mac que no sean audio.
- Soporte para Windows, Android u otras plataformas.

## Preguntas abiertas

- ¿Vale la pena el volumen por aplicación, dado que requiere un driver de audio virtual?
- ¿Cómo se emparejan el iPhone y la Mac la primera vez de forma segura y sin fricción?
- ¿Tiene sentido controlar el volumen también desde un widget o desde el Centro de Control del iPhone, sin abrir la app?
- ¿Cómo debería verse la interfaz: un mixer con varios faders o un control único grande?

## Cómo se va a construir

Con Claude Code u otro agente de código, partiendo de este documento. El spec técnico se deriva de aquí. Si el spec y este intent se contradicen, este documento manda hasta que se actualice.

---

## v2 — borrador para aprobación

> Estado: **borrador**. Lo escribió el agente a partir de los objetivos que le di; hasta que lo apruebe, la v1 (arriba) es la única intención vigente. El spec de la v2 (`SPEC.md`, Parte II) deriva de esta sección.

### Por qué una v2

La v1 cumple lo que pedí: tomo el iPhone, muevo un fader y la Mac responde. Pero controla solo el dispositivo predeterminado de cada lado. Mi Mac tiene más de un destino de audio a la vez (parlantes, audífonos, la interfaz, los virtuales de Zoom y Teams) y hoy, para tocar el volumen de uno que no es el predeterminado, tengo que primero volverlo predeterminado. Eso rompe la metáfora de la superficie de control: en un mixer cada canal tiene su fader, no hay que "seleccionar" el canal antes de moverlo.

Y la superficie que uso con más frecuencia junto a la Mac no es el iPhone, es el iPad. En landscape, con más ancho, es donde un mixer con varias tiras tiene sentido.

### Qué significa que funcione

- Veo una tira por dispositivo de salida y una por dispositivo de entrada, con su fader y su mute. Muevo cualquiera y ese dispositivo cambia, sea o no el predeterminado.
- El predeterminado de cada lado se distingue a la vista y lo puedo cambiar desde su tira, sin abrir un selector aparte.
- Si conecto o desconecto algo en la Mac, las tiras aparecen y desaparecen solas, en todos los dispositivos conectados.
- Si un dispositivo cambia desde la Mac (teclado, Ajustes del Sistema, otra app), su tira lo refleja. Sigue valiendo la regla de la v1: los dos lados cuentan siempre la misma verdad, ahora para todos los dispositivos.
- Puedo esconder las tiras que no me interesan (los virtuales que instalan las apps de videollamada), y esa elección es mía, en mi dispositivo, no de la Mac.
- La app es una sola y corre en iPhone y en iPad. En el iPad se siente diseñada para el iPad: landscape, tiras lado a lado, y se acomoda a cualquier tamaño de ventana en Stage Manager, sin quedar como un iPhone estirado.
- Con muchas tiras, mover un fader sigue siendo instantáneo. La cantidad de dispositivos no puede hacer que la app se sienta más lenta.

### Qué quiero poder controlar

En orden de prioridad:

1. Volumen y mute de cualquier dispositivo de salida y de entrada, no solo del predeterminado. El predeterminado se marca y se puede cambiar.
2. Todo lo anterior desde el iPad, con un layout propio.
3. Que la interfaz se vea mejor. El spec fija la estructura (qué hay en pantalla y cómo se organiza); el diseño visual lo itero aparte, con propuestas, no decisiones.
4. Volumen por aplicación, **solo si es viable**. macOS 14.4 trae process taps de Core Audio que quizás lo permitan sin driver. Quiero un spike corto con un go/no-go explícito antes de comprometerme: si el permiso, la latencia o los riesgos no son aceptables, se descarta y queda documentado por qué.

### Principios que se mantienen

Los de la v1, sin cambios: nativo de Apple, local primero, invisible en la Mac, simple antes que completo. Y dos que la v1 volvió explícitos y que la v2 no negocia:

- **Un solo snapshot completo.** El agente sigue mandando todo el estado en cada mensaje, ahora con todas las tiras. Prefiero pagar unos kilobytes por segundo que reintroducir los bugs de sincronización que los diffs traen.
- **El modelo de seguridad de la v1 no se toca.** Emparejamiento por QR, TLS-PSK con una clave por dispositivo, challenge-response del `hello`, revocación. La v2 agrega capacidades de audio, no superficie de ataque.

### Fuera de alcance (por ahora)

- Sigue fuera: App Store, control fuera de la red local, DAWs y multimedia, otras plataformas.
- Varias ventanas de la app en el iPad a la vez (Stage Manager con dos ventanas de LevelDeck). Una ventana, redimensionable.
- Widget y Centro de Control. Siguen en la lista de "después".
- Un cliente para Mac (controlar una Mac desde otra). El código lo permitiría, pero no lo necesito.

### Preguntas abiertas

- ¿Cómo se ve el mixer en el iPhone cuando hay diez tiras? ¿Desplazamiento horizontal, dos pestañas (Salida y Entrada) o una vista compacta con sliders horizontales?
- ¿Las tiras van en orden estable por nombre, con el predeterminado resaltado, o el predeterminado siempre primero?
- Volumen por app: ¿acepto que el agente se meta en la cadena de audio de esas apps (capturar, atenuar y volver a reproducir), con el permiso de grabación de audio del sistema que eso pide?
