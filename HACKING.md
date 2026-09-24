# HACKING.md — Contratos implícitos del código

Este documento lista los contratos arquitectónicos de `arxy` que no resultan evidentes de una lectura rápida pero gobiernan todo el ciclo de ejecución.

## 0. Filosofía de implementación

`arxy` sigue siendo Bash 4.4 porque arrays, `mapfile`, namerefs y descriptores
dinámicos forman parte de sus contratos actuales. El estilo sí es
POSIX-first: argumentos como arrays en vez de programas construidos como
texto, datos por `stdout`, diagnósticos por `stderr`, un elemento por línea
cuando la salida alimenta otra función y temporales con cleanup confinado.

- Los ficheros `arxy.conf` son datos y nunca se ejecutan con `source`/`eval`.
- No usar `bash -c` si el mismo flujo cabe en argv + `--chdir`/`--setenv`.
- Una función que instala traps temporales debe ejecutarse en subshell o
  restaurarlos sin `eval`.
- `CONFIG_KEYS` es la única lista de configuración pública y forma parte de
  `PRIV_ENV_KEYS`; los overrides internos privilegiados van solo en la segunda.
- Cada `cmd_*` valida cantidad y forma de argumentos antes de elevar
  privilegios, descargar la imagen o crear estado.
- Las sondas de reparación escriben arrays asociativos (`status`, `reason`,
  `action`, `opt_in`); no se serializan estructuras internas con delimitadores.
- `bridge_active_socket` es la única resolución de socket válida para L1/L2;
  variables bridge heredadas se limpian antes de reconstruir el entorno.
- `src/arxy` puede sourcearse sin disparar comandos; `main` solo corre cuando
  el fichero se ejecuta directamente.

## Mapa de módulos

- `00-head`: configuración, identidad del usuario, privilegios y utilidades.
- `10-level`: nivel 1/2 y fronteras de ejecución.
- `20-state`, `21-setup`, `22-gc`: estado/verificación, setup/rollback y GC.
- `30-package`, `31-aur`, `32-maintenance`: paquetes oficiales, AUR y
  mantenimiento.
- `35-gpu`, `40-query`, `41-desktop`, `50-run`: adaptadores especializados.
- `60-detect`, `61-doctor`, `62-json`: detección pura, diagnóstico/reparación
  y serialización/perfil.
- `70-help`, `80-bridge`, `zz-dispatch`: interfaz y punto de entrada.

El orden canónico vive únicamente en `LIB` dentro del `Makefile`; el artefacto
`src/arxy` continúa siendo un ejecutable único para no complicar instalación ni
empaquetado.

## 1. Memoización de `_ARXY_LEVEL`
La función `level()` determina si el entorno permite namespaces de usuario (Nivel 1) o no (Nivel 2). Tras su primera ejecución exitosa, exporta `_ARXY_LEVEL`. El resto de módulos confía ciegamente en esta variable y no vuelve a invocar `level()`.

## 2. Variables Globales Inyectadas
`00-head.sh` parsea configuración y asienta las constantes del sistema: `ARXY_DATA`, `ARXY_ROOT`, `ARXY_BUILD`, y `REAL_APPS`. Los demás scripts asumen que estas variables existen, son absolutas y sus directorios son escribibles por su respectivo usuario (root vs $USER). No se re-verifican en cada función.

## 3. Lazy-Init con `ensure_image`
Casi cualquier comando expuesto al usuario que interactúe con el subsistema debe llamar a `ensure_image` antes de actuar. Esta función actúa como un inicializador perezoso que aborta con instrucciones claras si el contenedor no ha sido descargado (`setup`).

## 4. El Router y `cmd_*`
El módulo `zz-dispatch.sh` mapea el comando introducido por el usuario (ej. `arxy run`) a su función Bash. Para que una función sea invocable públicamente, **debe** prefijarse con `cmd_` (ej. `cmd_run`). Los aliases (como `i` → `cmd_install`) están declarados en `main`; el guard `BASH_SOURCE[0] == $0` mantiene el bundle sourceable para tests.
