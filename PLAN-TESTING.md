# PLAN-TESTING.md — cobertura 100% de arxy, de pies a cabeza

Plan para verificar **todas** las funcionalidades con opencode: cada rama
del router, ambos niveles, AUR, gaming, bridge, firmas, packaging y los
hosts especiales. Métodos ya probados en este repo: suites en secuencia,
asserts de **contenido** (nunca solo rc), `ARXY_BIN`=shim del repo, mocks
`ARXY_*`, guards con SKIP honesto. Reglas de autoría nuevas en `AGENTS.md`.

## 0. Definición de 100%

- Cada rama de `main()` (24, incl. aliases, `*`→run, `-*`→die, `--help`
  posicional) verde en válido E inválido, en L1, L2 y host musl.
- Cada `test-*.sh` + `bridge/test-bridge.sh` TODO_OK; `make test-all` en
  host con root+red; matrix de `arxy-image` verde; hardware verde en Intel.
- `make verify` (con toolchain completa) + `install.sh`/`xbps` instalando.
- Cero `TODO_OK` fingido: lo no ejecutable lleva SKIP con motivo, nunca
  verde falso. Lo diferido vive en §8, no en silencio.

## 1. Superficie y cobertura actual (rama → qué la pinea)

| Rama(s) | Cubierto hoy | Hueco |
|---|---|---|
| `install` oficial | stubs (`test-install-remove-update`) | real con imagen+red (matrix L1) |
| `install --aur`, `__install-file` | stubs + bundle smoke | build AUR real (test-all `gaming-real`, matrix) |
| `remove`, `update` | stubs | real (matrix); `update` con CachyOS/mesa-hold real |
| `clean`, `gc` | `gc` con fixtures; `clean` nada directo | `test-clean.sh` (nuevo, §6) |
| `dedup` | traps; bundle smoke | comportamiento `test-dedup.sh` (nuevo, §6) |
| `info`, `list`, `search`, `search-aur` | bundle smoke + invalid args | parseo de salidas `test-query.sh` (nuevo, §6); contenido real solo matrix |
| `run`, `shell`, `which` | resolve-musl, traps, forks medidos | real L1/L2 (matrix+HW); interactivo manual |
| `export`, `unexport`, `desktop` | `export-one`, `desktop-migrate`, bundle smoke | `--all` real y auto tras install (matrix) |
| `doctor`, `--fix`, `--json` | `doctor-fix`, `doctor-json`, schema parcial | schema total (§6); `--apply` real (test-all) |
| `quickstart` | bundle smoke | máquina de estados `test-quickstart.sh` (nuevo, §6) |
| `version` | `test-version`, hardware-json | deriva kernel/driver (L4) |
| `setup`, `rollback` | `atomic-setup` (root), `staging`, `enospc`, `version` | download real, rotación 1-gen, `file://` con espacios (negativo) |
| `host-bridge`, daemon C | CLI/tmp, deferral, kill; vectores D1 | vectores nuevos §6; e2e contenedor (test-all); recupera tras `kill -9` |
| `help`, `axy`, fallback, aliases | `cli-contract`, bundle smoke | matriz `test-surface.sh` (nuevo, §6) |
| `arxy-gaming*` | stubs + dry-run | real 1GB (test-all); PKGBUILDs al publicar (§7) |
| firmas minisign | fakes + roundtrip real en CI | corrupt/pin/policy cubiertos; `required` real en L4 |
| `install.sh`, template xbps | nada directo | `test-install-sh.sh`, `test-packaging.sh` (nuevos, §6) |

## 2. Capas de ejecución

### L0 — estático (este contenedor, segundos)
`bash -n src/arxy* install.sh lib/*.sh` + regen idempotente (sha) +
`sync` (sha) + shellcheck (donde exista) + `test-makefile.sh` +
`test-bundle.sh`. Nuevo `test-surface.sh`: `help` ⊇ ramas del dispatch ⊇
bundles en `src/` ⊇ `vbin` del template ⊇ bucle de `install.sh` (pinea la
clase de deriva que el split introduce). Criterio: TODO_OK + cero drift.

### L1 — unitarias puras (aquí, minutos, sin root/imagen)
`detect_*`, `cpu_tier` (ambas libc + flags), `elf_class`, `nvidia_*` con
`fake_drm`, config-data (precedencia, literales, claves cerradas,
comillas), version-file (JSON/plano/migración/corrupto), `hardware.json`
(idempotencia, no-mutación por `--json`), `export_one`/`pkg_desktops`
(TSV incl. recorte L2), `gaming_pkgs` (vendor/pin/partición), `icd_rewrite`,
`resolve_target`/`check_musl` (ya existen; ampliar: rutas con espacios,
UTF-8, `--`, cwd con espacios). Criterio: suite L1 verde.

### L2 — contrato CLI por shim (aquí, minutos)
`test-cli-contract.sh` + `test-bundle.sh` + nuevo `test-query.sh`
(stubs `run_pacman`/`in_sys`: parseo oficial y AUR, **ambas formas L1/L2**
de `-Qlq --root`, vacíos, errores) y `test-quickstart.sh` (3 estados con
fixtures: sin imagen / sin lanzadores / con lanzadores + línea GPU con
`detect_gpu` stubbed). Criterio: cada rama muere en `uso:` con args
malos **antes** de privilegios/estado/red; códigos y `stderr` pineados.

### L3 — integración con rootfs falso (aquí, minutos)
`ARXY_ROOT` válido de juguete (`arxy_mkroot_ver`): `run` hasta `bwrap`
(argv pineado byte a byte), `export --migrate` real en `XDG_DATA_HOME`
falso, `dedup` sobre `/usr` falso (nuevo `test-dedup.sh`: réplicas→hardlink
misma `stat %i`, fuera de `/usr` intacto, symlinks intactos, umbral 10MB
con ficheros sparse, `auto` callado bajo umbral; SKIP honesto sin `cmp`),
`clean`/`gc --apply` sobre staging falso (nuevo `test-clean.sh`,
`need_root` stubbed como `test-gc.sh`), rotación `rollback` con
versiones falsas, `desktop --migrate` idempotente, contención de
`data_lock` (nuevo `test-lock.sh`: dos procesos, uno muere con "otra
operacion en curso"; SKIP sin `flock`), presupuesto de forks
(nuevo `test-perf.sh`: cotas superiores por comando con shims en PATH,
p. ej. `run` L1 ≤ 20 execs; determinista, sin tiempos). Criterio: sin
root, sin red, sin mutar el host.

### L4 — imagen real + root (host glibc con root+red, horas)
Fixture: `setup` con `file://` (offline tras 1ª descarga) y con `https://`
+ `.sha256` + firma (`required|optional|off` × pin/sin-pin × sig
válida/corrupta/ausente × minisign presente/ausente = tabla §3).
- Ciclo L1: install→run→export→remove→update; `shell`/`which`; AUR `-bin`
  real; `setup` fresco, re-`setup`, `rollback`, `setup` que destruye
  `.old` (1 generación, §16 OUT-OF-SCOPE); `clean/gc/dedup --apply`
  (dedup real ≥10MB); `doctor --fix --apply` (destructivos con `--confirm`
  + tty); `hardware.json` + avisos de deriva (`version --verbose`);
  `desktop --migrate` auto tras install/update.
- L2 forzado (`ARXY_LEVEL=2`): lecturas, escrituras chroot+sudo,
  `pacman` crudo bloqueado con mensaje, `CheckSpace` off, parsing de
  rutas prefijadas, `run` vía ld-linux, `bridge_env_l2`.
- Kill -9 en cada fase de setup/install/update → recuperable en la
  siguiente invocación (`recover_staging`); disco lleno; tarball corrupto
  (sha mismatch, firma inválida); `ARXY_ROOT` vacío/`/`/relativo (die
  claro); `file://` con espacios (error documentado, test negativo).
- Interactivo manual (no automatizable): `shell` con historia/pty,
  `run` con señales (Ctrl-C llega a la app), primer arranque de Steam
  (lento, ajeno), diálogos polkit sin tty.
- Criterio: `make test-all` TODO_OK + checklist §4 firmada por host.

### L5 — empaquetado (minutos + host Void para xbps)
- Nuevo `test-install-sh.sh` (sin root, con `DESTDIR`): `PREFIX` default
  y `/usr`, `--without-bridge` vs daemon (exige `make bridge`), conf
  existente→`.nuevo` (documentar: solo sin `DESTDIR`; rama manual con
  root), pubkey siempre renovada, `axy` symlink, errores sin `src/*`.
  Nuevo `test-packaging.sh` (sin root): `bash -n` template, `FILESDIR`
  ↔ `vbin` ↔ `src/arxy*` (nombres), `version` == `ARXY_VERSION` (pin
  anti-deriva), `depends` ⊇ hard-deps de `install.sh` (dirección
  documentada, no igualdad: minisign es opcional en runtime).
- Host Void: `xbps-src pkg arxy` + `check_outdated.py` de z-repo +
  instalar, actualizar sobre versión anterior (conf preservada, pubkey
  renovada, daemon viejo conviviendo), desinstalar (estado
  `/var/lib/arxy` sobrevive: checklist manual, sin `uninstall` propio).
- Criterio: paquete compila/instala/actualiza; tests nuevos verdes aquí.

### L6 — matrix multi-distro (repo `arxy-image`, CI/horas)
Alpine, Chimera, Void, Ubuntu, Ubuntu privilegiado: ciclo L1 completo con
asserts de **contenido**, L2 + `MATRIX_WRITE2=1`, bloques AUR en L2,
`search`/`info`/`list` con contenido, `fc-list`, `quickstart` y `.desktop`
reales. División vigente: lo que solo la matrix pinea no se duplica aquí.

### L7 — hosts especiales (por host, con opencode remoto/local)
- **musl** (Alpine/Chimera/musl-Void): exclusión de userspace gráfico,
  `ldd-musl`, sonda `musl-glibc-stack`, AUR solo `-bin`.
- **Endurecido/contenedor sin userns**: fallback L2 real sin forzar
  (sonda decide), e2e L2 completo.
- **Intel HW** (`test-hardware.sh`, nunca en contenedor): GL Iris,
  softpipe sin LLVM, D-Bus L1+L2, app Electron real, `eglinfo/glxinfo/
  vulkaninfo` como baseline para reportes AMD/NVIDIA (§10 OUT-OF-SCOPE).
- **AMD/NVIDIA reales**: montajes `test-gpu-drm` en HW + stacks
  `gpu-amd`/`gpu-nvidia` + `install arxy-gaming` (propietaria solo con
  módulo cargado; nouveau esperado en v1).
- **NFS/autofs**: medir walk de montajes en `run` (repro pendiente desde
  Fase 0; sin repro no hay fix).
- **Sin tty**: rama pkexec (stubs existen; diálogo real manual).
  **cron/NOPASSWD**: `sudo -n` e2e. **Locales/UTF-8**, cwd raros.

### L8 — negativo y robustez (mezcla L3/L4)
Toda la tabla §3 de firmas; kills; ENOSPC; corrupciones; `ARXY_LEVEL=3`
(hoy fallback silencioso a sonda: pinear conducta actual; si debe ser
`die`, es decisión de producto, no de este plan); confs corruptas/
ilegibles/enormes; `user-conf` leída como root; invocaciones concurrentes;
daemon: doble arranque (flock), `--stop`, pidfile stale, **PID reutilizado**
(cmdline check), token 0600/dir 0700, token mismatch, allowlist vacía o
irresoluble, socket borrado a mitad; `LD_LIBRARY_PATH` host en L2
(scrub); `dbus`/machine-id/resolv ausentes (avisos, no crash);
`dedup` con `\n` en nombres (documentado: `find -print0` solo con caso
real); upgrades con `[multilib]` duplicado (§11: aviso pero opera).

## 3. Tabla de firmas `setup` (L3 con fixtures / L4 real)

`policy` × `pin` × `transporte` × `.sha256` × `.sig` × `minisign`:
`required`+pin+sano=ok; `required`+pin+`required`=die (fail closed);
`required`+sig inválida=die; `optional`+sin minisign=aviso+ok;
`optional`+sig corrupta=die; `off`=silencio; `file://` omite firma;
sha mismatch=die siempre. La mitad ya la cubren `test-signature*.sh`;
el resto es L4 con tarball fixture.

## 4. Checklist firmable por host (L4/L7)

Por host (distro, libc, kernel, CPU, GPU, root sí/no, red sí/no): versión
corta+`--verbose`, `doctor --json` baseline, nivel efectivo, ciclo L1,
`ARXY_LEVEL=2` forzado, AUR `-bin`, `doctor --fix --apply`, kills,
ENOSPC (si se puede), bridge `--daemon/--stop/--status` + kill -9 +
rearranque, `.desktop` real abierto desde el menú, `axy` y fallback
`arxy firefox`, `setup`→`rollback`→`setup`. Todo con `ARXY_ROOT` aislado
salvo el ciclo que exija el default (documentarlo).

## 5. Vectores bridge a extender (`bridge/test-bridge.sh`, necesita `cc`)
Profundidad JSON, claves desconocidas, basura tras `}`, subrogados
(cubiertos) + base64 con `=` interior, args >64 / arg >4KiB / frame
>128KiB / frame 0, `MAXARGS` off-by-one, `SO_PEERCRED` uid ajeno, token
erróneo y ausente, allowlist con `/` relativo y PATH no absoluto,
`resize` fuera de `WS_MAXDIM`, exit 127/`128+señal`, `input` tras
`close-input`, timeout 10s sin request, `INQUEUEMAX`, EINTR en drenaje
(cuando se aplique Fase 3). Criterio: un assert de contenido por vector.

## 6. Tests nuevos (nombres finales, convención `tests/test-*.sh`)
1. `test-surface.sh` — acuerdo help↔dispatch↔bundles↔template↔install.sh (L0).
2. `test-query.sh` — parseo oficial/AUR, formas L1/L2, vacíos/errores (L2).
3. `test-quickstart.sh` — 3 estados + línea GPU (L2).
4. `test-dedup.sh` — hardlinks, límites, umbral sparse, `auto` (L3).
5. `test-clean.sh` — `clean` sobre fixtures, `need_root` stubbed (L3).
6. `test-lock.sh` — contención `data_lock` (L3, SKIP sin `flock`).
7. `test-perf.sh` — cotas de forks con shims (L3, determinista).
8. `test-install-sh.sh` — matriz `DESTDIR` (L5, sin root).
9. `test-packaging.sh` — template, versiones, depends (L5, sin root).
Extensiones (sin fichero nuevo): schema total en `test-doctor-json.sh`,
vectores en `bridge/test-bridge.sh`, casos L2 en `test-export-one.sh`.

## 7. Ejecución con opencode (cómo correrlo)
- Orden: L0→L1→L2→L3→L5-estático→L4→L6→L7→L8; no saltar (cada capa asume
  la anterior en verde). **Secuencial siempre** (daemon/bridge flaquean
  con contención); una rama por sesión para L4/L7 por host.
- Pre-vuelo por capa: L0-L3 corren en este contenedor tal cual;
  L4 exige checklist §4 + snapshot del host; L5-estático aquí, xbps en
  Void; L6 en CI del repo hermano; L7 con acceso al HW.
- Registro: `bash tests/run.sh | tee` + `finish()` por test
  (`TODO_OK`/`FALLOS`/SKIP con motivo); flake = re-correr ×2 aislado y
  en suite; si no reproduce, se anota (precedente: `pkgbuild-syntax`
  2026-10-10) y no se toca código.
- Autoría: helpers de `tests/lib.sh`, asserts de contenido, fixtures en
  `/tmp`, guards `id -u`/binario/red con SKIP, `export -f` para `sh -c`,
  kills con `kill -9 $BASHPID` tras la fase, `ARXY_BIN` default intacto.
- Estimación gruesa: L0 segundos, L1-L3 <15min, L5-estático <5min,
  L4 2-4h (descargas+builds), L6 horas en CI, L7 según HW, L8 1-2h.

## 8. No se testea (decidido, con motivo)
Límites de `OUT-OF-SCOPE.md` (anti-cheat, kmods, 32-bit ICD, DDX anidado,
`egl_vendor.d`, daemons systemd, VPN vs bus compartido, downgrade sin
anclaje, aislamiento como sandbox). Sin `uninstall` propio, sin `man`/
completions, sin i18n: no existen, no se pinean. Rama `.nuevo` de
`install.sh` sin `DESTDIR`: manual con root. Primer arranque de Steam,
polkit real, `makepkg` con `namcap`: donde exista la herramienta.
Reescritura Rust (`plan`): diferida, fuera de este plan.

## 9. Hallazgos laterales (al levantar el mapa; no son tareas)- `ARXY_LEVEL=3` (o basura) cae en silencio a la sonda. Pinear o
  convertir en `die` es decisión de producto.
- `install.sh` dice "mismas [deps] que el template + sha256sum" pero el
  template añade `desktop-file-utils minisign sudo`. Propuesto:
  `test-packaging.sh` pinea superset documentado, no igualdad.
- `TODO:` legacy v0.1 (`20-state.sh:138`, "remover en v0.6.0") sigue en
  0.6.3 con test que lo cubre: retirar es decisión de producto.
- Este contenedor trae `bwrap`, `unshare`, `curl`, `flock`, `makepkg`,
  `pacman` y driver `cc` **sin** headers libc; le faltan `cmp`, `diff`,
  `make`, `shellcheck`, `minisign`, `dash`, `namcap` y root. Los SKIP/FAIL
  ambientales de L0-L3 aquí (rc=127 por binario ausente) se resuelven
  solos en host con toolchain; el driver `cc` sin `/usr/include` no
  compila el daemon (Fase 3 sigue bloqueada aquí).

## 10. Bitácora de ejecución (2026-10-10, contenedor uid 1000 sin root)

Entorno distinto al de §9: sin `make`/`cc`/`unshare`/`dash`/`sudo`; con
`minisign`, `cmp`, `diff`, `flock`, `bwrap` (userns OK) y userland BSD
(`sed`/`stat`/`wc` estilo FreeBSD). L4-L8 no ejecutables aquí (exigen
root/red real/HW/Void); L0-L3 + L5-estático, completos.

- §6 tests nuevos (9, todos TODO_OK ×3 + controles negativos donde aplica):
  `test-surface.sh` (L0: dispatch↔`B_*`↔regen idempotente↔install.sh↔
  template↔trailers ambas direcciones↔help↔version↔sync↔axy; muerde ante
  deriva inyectada), `test-query.sh` (L2: validación, `[desktop]`,
  `-Qi`→`-Si`, search, search-aur jq/paru/RPC, plomería L1/L2 del
  `run_pacman` real), `test-quickstart.sh` (3 estados + línea GPU),
  `test-dedup.sh` (hardlinks, límites, umbral sparse 12MB, `auto`),
  `test-clean.sh` (dry-run/apply, conserva rootfs+conf), `test-lock.sh`
  (contención con mensaje, SKIP sin `flock`), `test-perf.sh` (cotas:
  help/version/install ≤12, verbose ≤70, run L1 ≤25 + sin
  file/stat/ldd sin DRM), `test-install-sh.sh` (DESTDIR, --help, flag
  mala, sin src, sin escritura, daemon; `.nuevo` queda manual con root),
  `test-packaging.sh` (nombres, versión, depends superset, conf/pub, axy).
- Extensiones §6: schema anidado total en `test-doctor-json.sh` (claves
  nested por grep + shape de `fixes[0]` por python); casos L2 extra en
  `test-export-one.sh` (mixto L1/L2, end-to-end con listado L2, root con
  espacios). Hallazgo lateral: el schema comentado prometía
  `capacidades=bool` inexistente → comentario corregido.
- Suite: **36 OK / 10 SKIP / 0 FAIL**, estable en 3 pasadas completas.
  Flake `pkgbuild-syntax` RESUELTO con mecanismo (race SIGPIPE
  `printf | grep -q`, misma clase que el gotcha de `AGENTS.md`; cazado
  también en test-query/staging/bundle/detect/migrate/sig-policy/
  split-brain y corregido en todos).
- Decisiones §9 cerradas (ver PLAN-REFACTOR §8): `ARXY_LEVEL` basura →
  autodetecta (pin en test-detect); TODO legacy v0.1 → se conserva;
  dirección de depends documentada (pin en test-packaging).
- L4/L7 pendientes de host con root+red/HW: checklist §4 intacta, sin
  cambios. `bridge/test-bridge.sh` sin correr aquí (sin `cc`).

## 11. L4 ejecutado en Chimera real (2026-10-10, doas passwordless)

Host: Chimera x86_64 musl, Intel (0x8086, sin v3 → repos base), L1 OK,
arxy 0.6.3 instalado en /usr/local + imagen productiva 3.2G del 24-sep.
Todo con `ARXY_ROOT` aislado (`/home/dicov/arxy-l4`) salvo lo indicado.

- Setup https real: 127.8MB + `.sha256` + **firma minisign válida** +
  extract + `-Sy` + imagen lista. `install htop/remove/update/rollback`
  (rotación 1-gen con versión viajando dentro), `run/search/info/list`
  con contenido real (`[desktop]` incluido), L2 forzado (run ld-linux +
  install chroot+doas), `doctor --fix --apply` (instaló `vulkan-intel`
  real por musl-glibc-stack). `file://` rapidísimo para repeticiones.
- Tests con imagen/root: doctor-fix-apply (MATRIX_IMAGE descargado),
  devices-e2e (aplay/evtest auto-instalados), bridge-in-container,
  hardware en Intel real (D-Bus L1+L2 con 62 nombres, **Iris L1+L2**,
  softpipe, export .desktop; solo SKIP app-GUI AUR y steam). mesa-utils
  instalado en prod para el iris (diminuto).
- `quickstart` mostraba conteo con relleno BSD (`(      11`): fix con
  `tr -d` (solo display; el `-eq` era inmune).
- **gaming-real en PC débil: estrategia sin 1GB.** El test completo se
  interrumpe a petición (fase pesada steam+wine). Equivalencia probada
  por partes, sin instalar el stack: (1) `--dry-run` en vivo: vendor
  intel + lista oficial/AUR correctas, nada tocado; (2) plomería AUR
  idéntica en vivo con `paru-bin` (~15MB): toolchain auto (incl. `pacman`
  para makepkg, ver fix arriba), build como usuario, `__install-file`
  como root, export; (3) eglinfo Iris ya verde en test-hardware;
  (4) installs oficiales probados en vivo ×4 (htop, vulkan-intel,
  alsa-utils, mesa-utils). Lo único no ejecutado: la descarga masiva en
  sí (mecanismo `pacman -S`, ya probado) y nombres upstream (fallarían
  en claro, no en silencio). gaming-real queda SKIP documentado.
- Regresiones del bug fd-heredado: T24 + vector 22 (ver PLAN-REFACTOR
  §8); el escenario original (devices) verde tras el fix.
