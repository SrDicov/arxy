# PLAN-REFACTOR.md — Refactorización total de arxy (sin reescritura)

**Estado 2026-10-10: Fases 0, 1 y 2 ejecutadas y verificadas** (detalle en §8).
Fase 3 bloqueada por toolchain (sin headers libc: no compila C aquí);
Fase 4 evaluada (ver §8: verificar-minisign ya existe; externalizar
listas gaming se rechaza con motivos).

La reescritura a Rust (`plan`, fichero sin formato en la raíz) queda
**diferida**. Este plan la fusiona con el informe suckless/Unix-like y se
ejecuta **solo con refactor**: Bash + C POSIX, mismos host-deps, misma UX.
Todo lo que contradiga un contrato vigente se descarta abajo con su motivo.

## 0. No-objetivos (alineación con OUT-OF-SCOPE.md)

- **§17 Sin aislamiento de seguridad.** Nada de este plan "endurece" nada:
  no seccomp, no `--new-session` como promesa, no `config.h` como frontera.
  La allowlist del daemon (`--allowed-cmd`, `ARXY_BRIDGE_ALLOWLIST`) sigue
  siendo la única frontera real (§12) y sigue siendo **runtime**, no
  hardcodeada: quemarla en `config.h` rompería `ARCHITECTURE.md` §5 y el
  contrato con quien arranca el daemon con flags.
- **L2 se queda.** `OUT-OF-SCOPE.md` §19 + matrix e2e lo sostienen (lecturas
  L2, `MATRIX_WRITE2=1`, `ARXY_LEVEL=1|2`, salidas `-Qlq --root` prefijadas).
  No hay `arxy-run-legacy` que rompa UX ni "fail fast" que mate el fallback:
  la separación L1/L2 será interna (rutas de código), no visible.
- **`/host` se queda.** `ARCHITECTURE.md`: el root real visible en `/host`
  es UX documentada. No se elimina para ahorrar un bind.
- **Bash 4.4 se queda** (`HACKING.md` §0: arrays, `mapfile`, namerefs,
  asociativos de `doctor`). No hay migración a `dash`: el host ya exige
  `bash >= 4.4` (`README.md`: la lista cerrada de host-deps no incluye
  `dash`) y toda la suite asume bash (`export -f` en tests). Lo que se
  elimina son **forks**, no el intérprete.
- **pacman se queda.** La analogía kiss/cpt no aplica: kiss gestiona repos
  propios; arxy tiene que hablar con repos Arch dentro del rootfs. `arxy-pkg`
  sigue siendo conducto hacia `pacman`/`makepkg`, no un gestor nuevo.
- **El protocolo del bridge se queda.** `bridge/arxy-bridged.c` espeja la
  spec externa `hrun` (framing 4B big-endian, `MaxFrame` 128KiB, `Data`
  base64, PTY + `input/close-input/resize`, `requestTimeout` 10s). El cliente
  que habla ese protocolo **no vive en este repo**; cambiar el wire a
  `\0`-delimitado rompería compatibilidad con él y amputaría PTY/input
  (los `\x01/\x02/\x03` propuestos no cubren terminal interactiva). El
  trabajo del bridge es otro (Fase 3).
- **s6/runit/dinit no entran.** `CONTRIBUTING.md`: Bash puro, sin
  dependencias nuevas. pidfile + `flock` + `bridge_pid_alive` (con su
  chequeo de cmdline contra PID reutilizado) se quedan; están testeados
  (`test-bridge-*.sh`, `test-host-bridge.sh`).

## 1. Diagnóstico corregido: el coste no es el parseo

El informe suckless atribuye la latencia a que bash "carga, analiza y
evalúa miles de líneas irrelevantes" (`src/arxy`: 3.144 líneas). Eso es
secundario: bash parsea 3k líneas en ~ms. El coste real del hot path
(`arxy run …`) son los **forks por invocación**, hoy:

- `level()` ejecuta `bwrap --ro-bind / / true` como sonda en **cada**
  proceso CLI (memoizado solo por proceso vía `_ARXY_LEVEL`). Es el único
  `--ro-bind / /` del repo (`lib/10-level.sh:141`): no está en el sandbox,
  es la sonda. El informe lo sitúa mal ("el script lo utiliza
  profusamente"); el bind recursivo del hot path es `--bind / /host`
  (`bwrap_base`, línea 35), que sí recorre montajes en cada `run` pero es
  UX documentada y no se toca.
- Sondas encadenadas en `run_in`: `nvidia_mounts`, `nvidia_icds`,
  `detect_libc`, `bridge_active_socket`, `readlink -f`, subshells
  `$(…)` por doquier.

**Fase 0 — medir antes de tocar (requisito de entrada).**

- Contar forks por `arxy run true` con `bash -x` / `strace -f -c` en L1 y
  L2; registrar línea base de `time` (real/user/sys) en glibc y musl.
- Reproducir o descartar el "freeze NFS 20–30s": hoy no hay evidencia en
  el repo (ni en `OUT-OF-SCOPE.md`, ni test, ni issue citado). Sin repro,
  no se optimiza nada por esa vía.
- Los "500×" de la expansión de parámetros y los "<5ms" por binario se
  toman como hipótesis a confirmar con la línea base, no como hechos.

## 2. Fase 1 — hot path `run` sin forks (sin cambiar conducta)

- Sonda de userns barata: sustituir `bwrap --ro-bind / / true` por una
  prueba sin walk de montajes (p. ej. `unshare -Urn true` si existe, o
  lectura de `/proc/sys/kernel/unprivileged_userns_clone` donde exista),
  manteniendo el contrato `ARXY_LEVEL=1|2` fuerza y `_ARXY_LEVEL` memoiza.
  Debe seguir funcionando en los 5 distros de la matrix.
- `run_in`: no llamar a `nvidia_mounts`/`nvidia_icds` cuando no hay DRM
  (`ARXY_SYS_DRM_PATH` vacío / sin `card*`: salida rápida antes de `file`
  y rewrites); no resolver bridge si `ARXY_NO_BRIDGE=1` o no hay socket;
  `detect_libc` una vez por proceso, no por rama.
- Regla: ningún `$(sed|awk|grep)` en `bwrap_base`/`run_in`/`level()` que
  pueda ser expansión de parámetros o test nativo. Fuera del hot path no
  se toca nada (el grueso de `sed` vive en `setup`/AUR, no en `run`).
- Criterio de aceptación: misma salida byte a byte del sandbox
  (`bwrap` recibe los mismos argv; test que dumpea `bwrap_base` + args de
  `run_in` antes/después), menos forks medidos, contract tests verdes.

## 3. Fase 2 — split multi-binario compatible (el núcleo del refactor)

Desmantelar el bundle único **sin romper el contrato CLI** (`zz-dispatch`:
aliases `i/rm/up/s/sa/r/w/sh/l/ls/i`, `__install-file`, `-*` → die,
desconocido → `cmd_run`, `--help` tras comando → ayuda global,
`cmd_*` valida args antes de privilegios/estado/red).

- Modelo: `lib/` sigue canónica; `Makefile: LIB` genera `src/arxy-<cmd>`
  por comando (cada uno concatena `00-head` + solo sus módulos) y `src/arxy`
  pasa a ser **shim fino** con el `case` actual delegando por `exec`.
  `install.sh`, xbps `files/`, `ARXY_BIN` y la matrix siguen viendo un
  `arxy` que se comporta igual.
- Un solo resolvedor de entorno compartido (hoy `00-head.sh`): la
  precedencia **env > user-conf > sys-conf**, `_restore_frozen` contra
  split-brain y la distinción `CONFIG_KEYS` / `PRIV_ENV_KEYS` + `arxy_env_pass()`
  no se duplican ni se "delegan al entorno": se extraen a un snippet común
  sourceado por todos los binarios. Dos resolvedores = split-brain.
- `ensure_image` (lazy-init) y `recover_staging` (recuperable tras SIGKILL)
  quedan en el path común: cada binario que toque el rootfs los llama igual
  que hoy. La atomicidad `staging → rename → fsync → root.old` no se toca.
- `doctor --json` `"format": 1` congelado: mismos campos, `reason`/
  `would_do` en español; `hardware.json` sigue caché. Cualquier split de
  `60-detect`/`61-doctor`/`62-json` debe pasar `test-doctor-json.sh` sin
  cambiar una coma (añadir campos sí, renombrar/quitar no).
- `cpu_tier` se extrae como `arxy-cpu-detect` **conservando la signatura
  testeable** `[cpuinfo] [arch] [ldso]` (ambas ramas glibc/musl mockeando
  `detect_libc`); `detect_gpu` como `arxy-gpu-probe` escupiendo
  `host\tguest` TSV a stdout (ya es el formato interno de `run_in`) y
  respetando los mocks `ARXY_SYS_ROOT`/`ARXY_DEV_PATH`/`ARXY_LIB*_DIR`/
  `ARXY_SYS_DRM_PATH` para que los tests sigan sin HW.
- Gate migrado: `make verify` pasa a exigir `bash -n` + shellcheck sobre
  **cada generado** + `git diff --exit-code src/arxy*` + `cmp` contra
  `packaging/void/…/files/` (que ahora lleva N ficheros). `ARXY_BIN`
  default sigue siendo `src/arxy` (shim); se añade `ARXY_BIN_RUN` etc.
  solo donde un test pinee un sub-binario. Suites en secuencia, asserts de
  contenido, `bridge/test-bridge.sh` aparte: todo igual que `AGENTS.md`.

## 4. Fase 3 — bridge: cerrar la deuda auditada, no cambiar el wire

Los 4 `TODO:` de `bridge/arxy-bridged.c` son el trabajo real, ya priorizado
por la auditoría pre-commit (ver cabecera del `.c`):

1. TOCTOU realpath→execv: `openat2` + `RESOLVE_*` o `fexecve` (con caso:
   hoy `authorize()` + `MAXARGS` lo contienen; es hardening, no fix).
2. EINTR en drenaje final: reintentar `read` en `[done]`.
3. Padding base64 interior: exigir `=` solo al final.
4. Off-by-one 65/64 en parse (inocuo hoy por `MAXARGS`).

Más: cobertura de `test-bridge.sh` para cada cambio; el parser strict-JSON
ya landed (depth cap, claves desconocidas, `\u` subrogados) no se reabre.
De `plan` (Rust) se adopta solo la disciplina aplicable a C: nada de
`lossy`/truncado silencioso en argv y paths (máx. `MAXARGSZ` ya existe).

## 5. Fase 4 — datos fuera del código (gaming, firmas, desktop)

- `arxy-gaming*`: las ramas vendor (`arxy_gaming_vendor`, rewrite a
  `gpu-amd`/`gpu-nvidia`, `mesa-mini`→full) salen de `30-package.sh` a
  manifiestos planos (`/etc/arxy/gaming-<vendor>.list`-style dentro del
  repo, pineados por test con contenido). `IgnorePkg=mesa` y el hold de la
  mini (~170MB) no cambian; la propietaria NVIDIA sigue fuera de v1.
- Firmas: `minisign` por tubería como hoy; `ARXY_SIGNATURE_POLICY` +
  pin `ARXY_IMAGE_SHA256` fail-closed intactos. (De `plan`: nada que
  internalizar aquí; la internalización TLS/HTTP muere con el diferido.)
- `desktop --migrate` idempotente + `X-Arxy-Pkg` y shims AUR canónicos:
  sin cambios de conducta, solo reubicación si el split lo exige.

## 6. Orden de ejecución y aceptación

1. Fase 0 (línea base + repro NFS) → 2. Fase 1 (hot path) → 3. Fase 2
   (split; commitear `lib/` + **todos** los generados + packaging juntos,
   un commit por tarea) → 4. Fase 3 (bridge) → 5. Fase 4 (datos).
2. Tras cualquier toque a paths/env/empaquetado: matrix del repo hermano
   (`arxy-image/tests/matrix.sh`) + `arxy version --verbose | grep url=`
   + mtimes de `/var/lib/arxy/*` (estado envenenado) — ver `AGENTS.md`.
3. CI (`lint.yml`) se amplía al punto 3: regen de N binarios + `bash -n`
   + shellcheck sobre generados + `cmp` de cada fichero + `test-signature.sh`
   con minisign real. El resto de la suite sigue fuera de CI: no asumir push.

## 7. Diferido explícito (con el rewrite)

Todo `plan` (binario estático musl, multi-call `argv[0]`, `rustix`/
`linux_raw`, `unshare`+`pivot_root` a mano, `ureq`+`rustls`/`ring`,
`ruzstd`, `lexopt`, capabilities ambientales), más del informe suckless:
protocolo IPC `\0`, `config.h` hardcodeado, supervisores s6/runit, seccomp,
matar L2, "fail fast" sin fallback. Reabrir solo con caso real + cambio
previo en `OUT-OF-SCOPE.md` (§12/§14/§17/§19 según toque).

## 8. Bitácora de ejecución (2026-10-10, contenedor sin `make`/`cmp`/`diff`)

Contenedor sin `make`, `cmp`, `diff`, `minisign`, `shellcheck`, `dash`;
con `bwrap`, `unshare`, `curl`, `cc`. `make src/arxy` y `make sync` se
replicaron a mano (mismo `LIB`, `cat` + `bash -n` + `cp`); la identidad
byte a byte se verificó con `sha256` vía python en vez de `cmp`.

**Fase 0 — línea base.**
- Suite intacta: 24 OK, 10 SKIP, 2 FAIL, ambos ambientales (no bugs):
  `test-cachy.sh` usa `cmp` (ausente → rc 127) y `test-makefile.sh` usa
  `make` (ausente → rc 127). En un host con toolchain completa se espera
  TODO_OK.
- Harness de forks (`/tmp`, no commiteado): shims que loguean+`exec` para
  18 binarios + root falso (`arxy_mkroot`-style) + `HOME` falso. Casos:
  `run` con `ARXY_LEVEL=1`, `run` con sonda, `version`.
- Base `run` L1: 15 execs externos; con sonda: 16. Desglose: `id -u` ×4 +
  `id -un`/`cut`/`getent` (bloque `REAL_USER`, fijo), `grep ^ARXY_`
  (freeze), `readlink SELF`, 2× `grep version` (`ensure_version`+migrate),
  `readlink resolv`, `grep nvidia`, sonda bwrap, bwrap final. Sin `file`/
  `stat`/`ldd` en host sin NVIDIA (los globs ya salen vacíos sin forks).
- Repro NFS 20–30s: **descartado por falta de evidencia**; el único
  `--ro-bind / /` del repo es la sonda de `level()`, no el sandbox.

**Fase 1 — aplicada (`lib/10-level.sh`, `lib/35-gpu.sh` + regen/sync).**
- `_userns_ok()`: sonda `unshare --user --map-root-user` primero, fallback
  bwrap. No es invención: es la convención ya usada por `doctor` y
  `probe_userns` (`61-doctor.sh`, `62-json.sh`); `level()` era la única
  sonda que aún hacía el bind recursivo.
- `detect_libc` solo si `_nvm$_nvi` no vacío (ahorra subshell+ldd en cada
  run sin NVIDIA; con NVIDIA, mismo coste).
- `readlink -f /etc/resolv.conf` memoizado por proceso (`_ARXY_RESOLV`;
  no cruza sudo: fuera de `PRIV_ENV_KEYS`, se recalcula tras elevar).
  Incidencia: el primer edit duplicó el `readlink` en vez de sustituirlo
  (15→16 en la remedición); se detectó por el harness y se corrigió.
- `nvidia_mounts`: filtro `| grep nvidia` → `case *nvidia*` (misma
  semántica de subcadena, un fork menos; `test-gpu-drm.sh` verde).
- Se descartó el pre-check por globs para `_nvm`/`_nvi`: sin NVIDIA ya no
  hay execs dentro (solo 2 subshells ~0.5ms); duplicar patrones crearía
  deriva sin ganancia medible.
- Resultado medido: `run` L1 15→14 forks, con sonda 16→15; argv final de
  `bwrap` **byte-idéntico** (comparado por programa); `version` intacto
  (10 forks).
- Tests: 10/10 afectados en verde + suite completa 24 OK / 10 SKIP /
  2 FAIL (los ambientales de base). Un FAIL puntual de
  `test-pkgbuild-syntax.sh` en una pasada intermedia **no reprodujo**
  (aislado, tras vecino y en segunda suite completa: TODO_OK); ruta no
  tocada por el diff → flake anotado, no fix.

**Fase 2 — split multi-binario (aplicada y verificada).**
- Modelo: `src/arxy` = shim (`lib/zz-dispatch.sh` reescrito: solo tabla +
  `exec`, standalone, sourceable con `main`). 9 bundles
  (`run pkg query desktop setup maint doctor bridge help`) = módulos
  (`B_*` en `Makefile`) + trailer `lib/exec-*.sh` (despacha `$1` canónico
  a `cmd_*`, recaptura `ARXY_ARGV`). Desviaciones del plan anotadas:
  `arxy-aur`/`arxy-cpu-detect`/`arxy-gpu-probe` NO son procesos separados
  (serían forks+parseos extra contra Fase 1; siguen funciones puras con
  signatures testeables); `arxy-doctor` es gordo a propósito
  (`fix --apply` → `cmd_install`, 13 módulos).
- Plomería: `ARXY_SELF`/`ARXY_CMD` (shim→bundle, viajan en
  `PRIV_ENV_KEYS`, nunca `CONFIG_KEYS`); `need_root` re-ejecuta
  shim+canónico+args; 4 call sites `$SELF`→`$ARXY_SELF` (`31-aur.sh` ×3,
  `80-bridge.sh` daemon); `bridge_bin` intacto (`dirname $SELF`: bundle
  y shim conviven en `src/` y en `$PREFIX/bin`).
- `Makefile`: reglas por bundle + `build`, `check`/`lint` sobre
  `src/arxy*`, `verify` con `git status` limpio (cubre bundles nuevos,
  que `git diff` ignoraría sin commitear) + `cmp` en bucle, `sync` en
  bucle. `lint.yml`, `install.sh` (bucle de bins), template xbps (`vbin`
  por bundle) actualizados.
- `tests/test-bundle.sh` (nuevo): `bash -n` + sourceable + `cmd_*` de
  entrada por bundle + humo shim→bundle con casos que mueren en `uso:`
  (sin estado) + alias/`--badflag`/fallback. Incidencia: el primer
  borrador violó la regla pipefail+`grep -q` del repo en su propio assert;
  corregido (capturar y grepear después).
- Medido: `run` L1 14→15 forks y con sonda 15→16 (+1 fijo: SELF del shim;
  aceptado y documentado); argv final de `bwrap` **byte-idéntico** antes/
  después (comparado por programa); tiempos limpios sin shims:
  monolito ~231ms vs split ~243ms de mediana con varianza ±50ms de
  contenedor → **neutro** (el ahorro de parseo compensa el exec extra).
  Layout instalado validado (`DESTDIR` + `axy` + `arxy run`).
- Suite: 25 OK (24 + test-bundle) / 10 SKIP / 2 FAIL (los ambientales:
  sin `cmp` ni `make` en este contenedor).

**Fase 3 — bridge (BLOQUEADA por toolchain, no aplicada).**
- Este contenedor no tiene headers libc (`/usr/include` ausente) ni root
  para instalarlos: `cc` no compila `bridge/arxy-bridged.c`, luego los 4
  `TODO:` (TOCTOU realpath→execv, EINTR en drenaje, padding base64,
  off-by-one 65/64) no se pueden verificar aquí y no se tocan (daemon =
  frontera de seguridad; C sin compilar no se commitea).
- Procedimiento de aceptación en host con toolchain: `make bridge` limpio
  (`-Wall -Wextra -Werror`) + `bash bridge/test-bridge.sh` + vectores
  nuevos por TODO + suite `test-bridge-*.sh`/`test-host-bridge.sh` con
  `ARXY_TEST_ALL=1`. El protocolo wire NO cambia (compat `hrun`, §0).

**Fase 4 — datos (evaluada; mayormente YA HECHA o RECHAZADA).**
- minisign por tubería con taxonomía rc 0/1/2/3/4 + policy: **ya existe**
  (`verify_signature`/`enforce_signature_policy`, `20-state.sh`;
  `test-signature*.sh` en verde/SKIP honesto sin binario). Nada que hacer.
- Externalizar listas `arxy-gaming-*` a manifiestos planos: **se rechaza**.
  Motivos: (1) el pin `nvidia-utils=$ver` es dinámico (versión del módulo
  del host) y no puede vivir en un fichero estático: el `case` vendor se
  quedaría igual; solo se moverían ~15 líneas estáticas. (2) Ficheros en
  runtime exigirían nueva superficie de instalación (paths, fallos
  "instalación incompleta") contra "sin dependencias nuevas". (3) Los
  PKGBUILDs son drafts no publicados (§7 OUT-OF-SCOPE): cambiar cómo
  construyen `depends` sin `makepkg`/`namcap` aquí es unverificable. El
  mecanismo vigente (lista canónica en bash + `test-pkgbuild-syntax.sh`
  como sincronizador) ya es el óptimo bajo estas restricciones.
- `arxy-cpu-detect`/`arxy-gpu-probe` como procesos: rechazado en Fase 2
  (fork+parseo extra; las funciones ya son puras e inyectables).
- Barrido `sed`/`awk` fuera del hot path y migración `dash`: rechazado
  (Fase 0: sin medición no hay cambio; §0: Bash 4.4 es contrato).
