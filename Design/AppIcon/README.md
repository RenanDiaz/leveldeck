# Ícono de LevelDeck — arte fuente

Originales del export de diseño. **No los usa el build**; los assets compilados viven en:

| Destino | Archivo |
| --- | --- |
| iOS `LevelDeck` | `LevelDeck/Assets.xcassets/AppIcon.appiconset/` (1024 px, full-bleed; iOS aplica la máscara) |
| macOS `LevelDeckAgent` | `LevelDeckAgent/Assets.xcassets/AppIcon.appiconset/` (16–1024 px, squircle 824/1024 con padding según la grilla de macOS) |
| Barra de menú | `LevelDeckAgent/Assets.xcassets/MenuBarIcon.imageset/` (SVG 18 pt, template) |

## Capas (Icon Composer / Liquid Glass)

`leveldeck-layer-0*.svg` son las capas 1024×1024 para armar un `.icon` en Icon Composer (Xcode 26), de abajo hacia arriba:

1. `fader-grooves` — rieles
2. `scale-ticks` — escala central
3. `cap-output` — perilla de salida (negra)
4. `cap-input` — perilla de entrada (clara)

Fondo: degradado lineal vertical `#F47420` (arriba) → `#E0560D` (abajo), tomado de `leveldeck-fallback-1024.png`.
