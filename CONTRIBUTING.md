# Cómo contribuir a arxy

## Reportar un bug

Abre un issue con la plantilla de bug report. Incluye siempre:

- Versión (`arxy version --verbose`).
- Distro del host y si es glibc o musl (`arxy doctor --json | jq .libc`).
- Pasos mínimos para reproducir.
- Salida real y salida esperada.

Sin `doctor --json`, el reporte vuelve con preguntas antes que con un fix.

## Proponer un cambio

1. Fork + branch desde `main`.
2. Un commit por tarea, mensaje con el porqué (qué rompía, no solo qué cambia).
3. PR contra `main` con la plantilla. Describe el problema antes que la solución.
4. No hay revisión automática asignada: si en unos días no hay respuesta,
   escribe a SrDicov@gmail.com con el enlace al PR.

## Estilo de código

Vale lo que dice `AGENTS.md`. Resumen:

- Bash puro, sin dependencias nuevas.
- Funciones públicas `cmd_*`, resto con `_`. Variables `ARXY_*`.
- Casi todo comando llama a `ensure_image` primero.
- Comentarios que citan el bug o commit que los motivó: se quedan.
- Configuración como datos; nunca `source`/`eval` sobre archivos del usuario.
- Argumentos estructurados; evitar comandos armados como strings.
- `stdout` para datos componibles y `stderr` para avisos/errores.

## Tests

Cada test es `bash tests/test-*.sh` y sigue siendo ejecutable por separado. Antes del PR, pasa el gate canónico de [AGENTS.md](AGENTS.md).

Los tests que usan `src/arxy`, siempre después de `make sync` (si no,
mienten con el binario viejo). Suites en secuencia, nunca en paralelo.
`tests/test-hardware.sh` solo en host real con Intel, nunca en container.

## Commits

- Uno por tarea. Mensaje corto con el porqué.
- No commitear `src/arxy` desfasado de `lib/`: el CI lo rechaza.
- Push y releases: los hace el maintainer. No pidas acceso de escritura;
  el flujo es fork + PR.
