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
