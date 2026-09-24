# AGENTS.md — arxy (CLI)

Arch conviviente en `/var/lib/arxy/root` (ficheros normales, sin squashfs/FUSE).
Comparte `/home /tmp /run /dev` + GPU. **Sin sandbox de seguridad** (capa
compat-glibc, no aislamiento). Solo escribe en `/var/lib/arxy` (rootfs,
`root.old` de rollback, estado) y `~/.local/share/applications/arxy-*.desktop`.
Lee `/etc/arxy/arxy.conf` y `~/.config/arxy/config` como datos (nunca los
ejecuta). Precedencia: **env > user-conf > sys-conf** (env congelado en
`_restore_frozen`, `lib/00-head.sh`). Contratos arquitectónicos (globales, lazy-init,
router `cmd_*`): `HACKING.md`. Límites permanentes: `OUT-OF-SCOPE.md`
(vivo: cada `TODO:` o desviación se registra ahí; si no está, no existe).

## Fuentes canónicas y puerta antes de commit

- `lib/*.sh` es canónico; `src/arxy` es generado (commiteado porque el
  instalador lo lee del clon) concatenando `LIB` en el orden del `Makefile`.
  `config/arxy.conf` y `config/arxy.pub` son canónicos;
  `packaging/void/…/files/` son copias manuales para xbps.
- Flujo: editar solo `lib/` → `make sync` (regenera + copia a packaging) →
  commitear todo junto. `make bridge` compila el daemon C aparte (no va en
  `src/arxy`). Bump versión en este orden: `ARXY_VERSION` en `lib/00-head.sh`
  (+ `make sync`) → `version` en `packaging/void/arxy/template` →
  `version`+`checksum` en `z-packages` (vía API, tras release). Nunca derivar
  del tag (rompe `make sync` offline).
- Gate (lo verifica `lint.yml`; shellcheck corre sobre el generado, no sobre
  fragmentos sueltos que dan falsos SC2034/SC2148):

```bash
make src/arxy && git diff --exit-code src/arxy   # D9: byte-idéntico
bash -n lib/*.sh src/arxy install.sh && shellcheck -S warning src/arxy install.sh
cmp src/arxy packaging/void/arxy/files/arxy && cmp config/arxy.conf packaging/void/arxy/files/arxy.conf && cmp config/arxy.pub packaging/void/arxy/files/arxy.pub
```

- Un commit por tarea, mensaje con el porqué.
- Push, releases y GitHub (incl. z-repo): solo con pedido explícito.
- `pacman` siempre `--noconfirm` vía `nc_args`; nunca `LD_LIBRARY_PATH`
  (envenena al subsistema: solo `ld-linux --library-path` + `unset` explícito).
- Si arxy se instaló a mano, borrar `/usr/local/bin/arxy*` y
  `/usr/local/lib/arxy/` antes del paquete (hacen shadow por PATH).

## Tests

- Cada test es `bash tests/test-*.sh` autocontenido. `tests/run.sh` los
  orquesta en secuencia: `make test` para la suite determinista y
  `make test-all` para los que necesitan entorno externo. Helpers en
  `tests/lib.sh`. `ARXY_BIN` default: `src/arxy` del repo (nunca el instalado:
  da falsos rojos). Tests que usan `$BIN`/`src/arxy`, siempre DESPUÉS de sync.
- Assertions de **contenido** (`grep`), nunca solo rc (hubo bugs mudos con rc=0).
- Suites **en secuencia, nunca en paralelo** (los de daemon/bridge flaquean por
  contención). `tests/test-hardware.sh` solo en host real con Intel, nunca en
  container. Matrix e2e vive en el repo hermano `arxy-image`
  (`tests/matrix.sh`): división intencional — `search`/`info`/`list` con
  contenido, `fc-list`, `quickstart` y `.desktop` reales solo los pinea la
  matrix; la suite del CLI pinea contrato con mocks.
- Mocks de detección (tests sin root ni imagen): `ARXY_SYS_ROOT` (prefijo
  /proc+/sys), `ARXY_DEV_PATH`, `ARXY_LIB_DIR`/`ARXY_LIB64_DIR`, `ARXY_SYS_DRM_PATH`.
  Tests de rama glibc/musl deben mockear `detect_libc` y cubrir AMBOS casos.
- Tests con `sh -c` + funciones de lib/: `export -f` funciones y vars, o
  llamadas directas. Kills deterministas: overrides de función que matan TRAS
  la fase + `kill -9 $BASHPID` (`$$` mataría al test, no al subshell).

## Gotchas de env/paths (cada uno costó un bug)

- Para aislar, exportar SOLO `ARXY_ROOT`; `ARXY_DATA`/`ARXY_BUILD` derivan de
  él tras `_restore_frozen`. Exportar los derivados se ignora en silencio
  (split-brain: setup extraía en un root y escribía estado en otro).
- Re-exec con privilegios (`need_root`, `as_root`) pasa `ARXY_*` solo vía
  `arxy_env_pass()` (única fuente; sudo pelado opera sobre el rootfs default).
- Con `pipefail`, `prod | grep -q` miente (SIGPIPE 141): capturar en variable
  y grepear después. Presencia de binario = `test -x`, nunca `--version`.
- `file://` no acepta espacios en la ruta. `command -v` no resuelve
  builtins/funciones: barrer `PATH` a mano + `readlink -f`.
- Tras `setup`, verificar `arxy version --verbose | grep url=` (una conf pudo
  pisar el env sin aviso; la matrix no lo caza). Tras tocar paths/env, mirar
  **mtimes de `/var/lib/arxy/*`** (tests pasan con estado envenenado).

## Los 2 niveles y contratos estables

- **L1** (bwrap + userns, habitual) / **L2** (sin userns: `run` vía `ld-linux`
  del subsistema, escrituras pacman vía chroot+sudo). `ARXY_LEVEL=1|2` fuerza;
  `level()` detecta y memoiza en `_ARXY_LEVEL`. AUR solo L1, solo `-bin`
  (nunca toolchains); `--skippgpcheck` por defecto (`ARXY_GPG_CHECK=1` exige).
- L2 cambia formatos de salida (`-Qlq --root` devuelve rutas prefijadas):
  todo path-parsing debe funcionar en ambas formas.
- Invariantes: SIGKILL en cualquier punto deja el sistema recuperable en la
  siguiente invocación (`recover_staging`, `lib/20-state.sh`). `version`
  vive DENTRO del root: el rename publica imagen+versión juntas, el rollback
  la rota sola. Casi todo comando llama a `ensure_image` (lazy-init) primero.
- `doctor --json` tiene `"format": 1` estable: solo añadir campos, nunca
  renombrar/quitar (schema mínimo en comentario de `lib/62-json.sh`).
  `reason`/`would_do` en español. `hardware.json` es caché, no fuente.
  `--fix` informa; `--apply` exige root; destructivos exigen `--confirm` + tty.
- Firmas minisign: trust root `config/arxy.pub`; `setup` verifica según
  `ARXY_SIGNATURE_POLICY=required|optional|off` (default `optional`).
  Pin `ARXY_IMAGE_SHA256` + `required` = die (fail closed: el pin omite firma).

## No resucitar sin contexto

- Imagen plana `.tar.zst` (DwarFS/SquashFS descartados); NVIDIA propietaria
  fuera de v1 (solo nouveau); `IgnorePkg=mesa` hold en la mini (~170MB).
- `dedup` solo en `/usr` por hardlinks; auto solo si ahorra ≥10MB
  (`ARXY_NO_AUTO_DEDUP=1` lo desactiva). `s=search` publicado, `s` no es `shell`.
- NVIDIA se detecta con `file -b` (dependencia declarada); nunca parsear ELF a
  mano. `LD_LIBRARY_PATH` no se scrubbea en L1 a propósito.
- `desktop --migrate` etiqueta `.desktop` legacy sin `X-Arxy-Pkg` (idempotente;
  auto tras install/update). Shims de build AUR canónicos en `aur_build`
  (`bsdtar`, `tar`, `cp`, `install`): nuevo shim solo con caso real + test.
- Tech debt: `grep -rn 'TODO:' lib/ tests/ bridge/`.
- Tras cada edit, releer la función entera y probar el path tocado, no solo el
  editado (un edit en `cmd_remove` matcheó `install`).
