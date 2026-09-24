# CLAUDE.md

## Documentos

- `INTENT.md` manda sobre `SPEC.md`, y `SPEC.md` manda sobre el código y el `README.md`.
- `README.md` explica cómo compilar, instalar, usar y verificar. No copia el spec: enlaza a sus secciones.

## Al cerrar una fase (o cambiar el spec)

Revisa `README.md` y actualiza lo que haya cambiado:

- la sección **Estado** (fases completas y lo que queda para después de v1);
- **Requisitos** (versiones de macOS, iOS, Xcode y Swift);
- **Primeros pasos** y **Emparejar**, si cambió el flujo de instalación o de emparejamiento;
- **Verificación**, si `scripts/verify.sh` o CI hacen algo nuevo;
- **Estructura**, si se agregaron o movieron carpetas o paquetes;
- **Cómo funciona, en corto**, si cambió el transporte, la versión del protocolo o el almacenamiento de claves;
- los enlaces a secciones del spec (`SPEC.md#…`), si se renumeraron o renombraron.

Si no hay nada que cambiar, dilo en el PR.

## Proyecto y verificación

- El `.xcodeproj` no se versiona: se genera con `xcodegen generate` desde `project.yml`.
- Antes de hacer push, corre `scripts/verify.sh` (es lo mismo que corre CI en `macos-15`).
