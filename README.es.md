# arxy — corre software de Arch en cualquier distro, a velocidad nativa

```bash
sudo arxy setup                  # la primera vez: descarga un Arch mínimo (~128MB, ~490MB en disco)
arxy quickstart                  # te orienta sobre cuál es el siguiente paso lógico
arxy install telegram-desktop    # instala desde repos oficiales (y crea el lanzador en tu menú)
arxy install --aur spotify       # instala paquetes precompilados de AUR (-bin)
arxy run rar x archivo.rar       # ejecuta herramientas CLI directamente dentro del subsistema

```

## Instalación (la ruta más directa)

1. Clona el repositorio y ejecuta el instalador. Funciona en cualquier distro (por ahora no ofrecemos un script estilo `curl | bash` porque el instalador necesita la estructura completa del repo local):

```bash
git clone https://github.com/SrDicov/arxy && cd arxy   # obviamente, necesitas `git`
sudo ./install.sh              # se instala en /usr/local (arxy + axy; si ya eres root, omite `sudo`)
sudo arxy setup                # descarga la imagen base de Arch y lo deja listo para usar

```

**Void Linux** (instalación desde z-repo, como alternativa al paso anterior):

```bash
echo "repository=https://srdicov.github.io/z-repo/x86_64" | sudo tee /etc/xbps.d/20-zrepo.conf
yes | sudo xbps-install -S   # importa la llave del repositorio (solo la primera vez)
sudo xbps-install -y arxy

```

Si usas la variante Void musl, el repositorio es `.../z-repo/x86_64-musl`. Si prefieres compilar el paquete tú mismo, simplemente copia `packaging/void/arxy/` a tu `void-packages/srcpkgs/` y ejecuta `xbps-src pkg arxy`.

**Opciones del instalador** (`install.sh --help`): Puedes usar `PREFIX=` (por defecto va a `/usr/local`), `DESTDIR=` (muy útil como entorno de *staging* si estás empaquetando para tu distro), o `--without-bridge` (para omitir el demonio, que es lo que hace actualmente el paquete de xbps). Si necesitas el bridge, recuerda compilar el binario con `make bridge` antes de instalar. Ojo: `sudo arxy setup` siempre escribe en `/var/lib/arxy`, por lo que necesita permisos de root.

¿Quieres probar una imagen local o tu propia compilación? Usa `ARXY_IMAGE_URL=file:///ruta/al.tar.zst` (ten en cuenta que `file://` no procesa bien los espacios en la ruta). La instalación directa por tubería (`curl | bash`) está en el *roadmap* para la v1.x; hoy por hoy toca clonar.

**Requisitos de tu máquina host:** `bash bwrap curl tar zstd xz gzip file` y una versión de `bash>=4.4`. Puedes verificar si cumples todo ejecutando `arxy doctor`.

## Uso del día a día

| Comando | Qué hace exactamente |
| --- | --- |
| `arxy install <pkg...>` / `--aur` | Instala paquetes (oficiales o `-bin` de AUR) y crea sus accesos directos. Pedirá `sudo` bajo el capó. Los de AUR se compilan como usuario sin privilegios y luego te piden la clave para instalarlos. Si falta la imagen base, la descarga. Los lanzadores van a `~/.local/share/applications/`. |
| `arxy remove <pkg...>` | Desinstala el paquete y limpia su lanzador del menú. |
| `arxy run <bin> [args]` | Ejecuta cualquier binario o comando dentro del entorno del subsistema. |
| `arxy which <bin>` | Te dice si el ejecutable se está resolviendo desde el [subsistema] o desde tu [host]. |
| `arxy shell` | Te abre una terminal interactiva nativa de Arch. |
| `arxy search/info/list/update` | Busca paquetes, muestra detalles, lista lo instalado o actualiza todo el subsistema. |
| `arxy export --all` | Fuerza la regeneración de todos los lanzadores del menú de aplicaciones. |
| `arxy setup / doctor` | (Re)descarga la imagen de forma atómica y con *rollback* / chequea la salud del entorno. |
| `arxy quickstart` | Analiza el estado de tu instalación y te sugiere qué hacer a continuación. |
| `arxy dedup` | Crea *hardlinks* para archivos idénticos en `/usr`. Se lanza automáticamente tras un `install` o `update` si el ahorro supera los 10 MB (puedes desactivarlo con `ARXY_NO_AUTO_DEDUP=1`). |
| `axy` | Un alias rápido para no escribir `arxy` todo el rato. |
| `arxy install arxy-gaming [--dry-run]` | Despliega el stack de *gaming* ajustado a tu GPU. Si la detección no basta, usa `arxy-gaming-amd`, `arxy-gaming-intel` o `arxy-gaming-nvidia`. La parte de AUR se compila en espacio de usuario. Requiere Nivel 1. |
| `arxy host-bridge [--daemon|--stop|--status]` | Gestiona el demonio *host-bridge*, encargado de pasar las notificaciones y los enlaces desde el *sandbox* hacia tu host. |

Si algo se rompe, el flujo de rescate es simple: `arxy doctor` → `arxy doctor --fix` → `arxy quickstart`.

```bash
# Puedes parsear la salida del doctor para integraciones:
arxy doctor --json | jq '{nivel: .level, libc: .libc.kind, gpu: .gpu.vendor}'
# Output esperado: {"nivel": 1, "libc": "glibc", "gpu": "intel"} (el format: 1 es estable)

```

**Sobre las reparaciones:** `arxy doctor --fix` solo informa y propone soluciones, no rompe nada. Si usas `--apply` (como root), aplicará los arreglos no destructivos. Si añades `--apply --confirm` te abrirá un *tty* para confirmar acciones destructivas (por ahora, básicamente limpiar un `db.lck` huérfano). La bandera `--json` nunca aplica cambios, solo devuelve `fixes_available` y `fixes`. (Los arreglos tipo `nvidia-align`, `musl-glibc-stack` y `gpu-full-stack` de momento solo se proponen; su instalación será opt-in en un futuro).

El comando `setup` guarda tu perfil de hardware en `/var/lib/arxy/hardware.json` (es una caché atómica, con `format: 1`, que solo se reescribe si hay cambios). Luego, `arxy version --verbose` lee este archivo y te avisa si has cambiado de kernel o de driver NVIDIA, mientras que `doctor --json` siempre hace el cálculo en tiempo real. Refrescar este perfil sin tener que pasar por `setup` es una tarea pendiente.

**Configuración:** Tienes configuración a nivel de sistema en `/etc/arxy/arxy.conf` y a nivel de usuario en `~/.config/arxy/config`. Son ficheros de datos, no scripts de shell: usa una asignación `ARXY_CLAVE=valor` por línea, con comillas simples o dobles opcionales. No se expanden variables ni se ejecutan comandos, tampoco bajo `sudo`. Las claves admitidas en fichero son `ARXY_ROOT`, `ARXY_IMAGE_URL`, `ARXY_IMAGE_SHA256`, `ARXY_SIGNATURE_POLICY`, `ARXY_LEVEL`, `ARXY_GPG_CHECK`, `ARXY_KEEP_PKG_CACHE`, `ARXY_NO_AUTO_DEDUP`, `ARXY_NO_BRIDGE`, `ARXY_BRIDGE_ALLOWLIST` y `ARXY_BRIDGE_BIN`. Los valores de ejecución documentados siguen pudiendo sobrescribirse mediante el entorno.

## Arquitectura: Los 2 niveles de ejecución

Arrancar el subsistema tiene un coste casi nulo. La imagen no es más que un *rootfs* de Arch extraído a pelo en `/var/lib/arxy/root` (nada de squashfs ni capas FUSE que frenen el I/O; son archivos normales). Compartimos `/home`, `/tmp`, `/run`, `/dev` y el acceso directo a la GPU. Tu sistema real queda expuesto en `/host`. Esta es la clave para conseguir esa velocidad nativa. Las lecturas y la ejecución de software ocurren con tu usuario sin privilegios; solo escalamos a `sudo` para instalar o actualizar cosas.

* **Nivel 1** (bwrap + user namespaces): El comportamiento por defecto y el recomendado.
* **Nivel 2** (sin namespaces): Utiliza `run` inyectando el `ld-linux` del subsistema, e `install` tirando de `chroot` clásico con sudo. Está pensado para kernels *hardened* o entornos de contenedores donde `bwrap` está capado. El sistema detecta automáticamente qué nivel usar (lo puedes ver con `arxy doctor`), pero puedes forzarlo exportando `ARXY_LEVEL=1|2`.

## Limitaciones conocidas:

* **AMD/NVIDIA: El soporte teórico existe, pero nos faltan pruebas en hardware real.** Si `arxy doctor` detecta tu tarjeta dedicada, `install gpu-amd` o `gpu-nvidia` intentarán instalar el `mesa` oficial (que incluye LLVM, a diferencia del `mesa-mini` que viene por defecto) levantando el bloqueo de `IgnorePkg=mesa` (son unos ~170MB extra). El mecanismo está implementado, pero no tenemos métricas de éxito empíricas aún.
* **Drivers propietarios de NVIDIA:** Fuera del alcance de la versión 1.x. Por ahora, solo soportamos Nouveau a través de Mesa.
* **Intel iGPU y softpipe:** 100% verificados (testeado en una HD 630 con aceleración completa, sin depender de LLVM).
* **AUR:** Funciona exclusivamente en el Nivel 1 (compilar requiere de *namespaces*) y nos limitamos a paquetes precompilados (`-bin`). Nada de compilar *toolchains* pesadas dentro de arxy. La comprobación de firmas PGP se salta por defecto (`--skippgpcheck`), a menos que la exijas explícitamente con `ARXY_GPG_CHECK=1`.
* **Cero sandbox de seguridad:** No confíes en arxy para aislar procesos. No hay aislamiento de seguridad ni en el Nivel 1 ni en el 2. Míralo como una capa de compatibilidad para evitar peleas con `glibc`, no como un entorno seguro. **No ejecutes software no confiable.**
* Para ver la deuda técnica actual y las limitaciones permanentes de diseño, pásate por `OUT-OF-SCOPE.md`.
* **Demonios de sistema:** Todo lo que requiera `systemd` o demonios root persistentes (como TeamViewer o AnyDesk) no funcionará dentro del subsistema. Además, cosas como `protonvpn-app` chocarán con el cliente del host porque intentan adueñarse de la misma instancia en el bus de D-Bus compartido. Steam y `umu-launcher` sí funcionan perfectamente (el soporte *multilib* está activado).
* En el Nivel 2, el uso directo de `pacman -S/-U/-R` dentro de `arxy shell` está bloqueado a propósito para evitar romper el entorno (acostúmbrate a usar `arxy install/remove/update`). Además, `CheckSpace` está desactivado bajo el chroot, y la gestión de cachés de rutas absolutas de GTK/Qt funciona en modo *best-effort*.
* `arxy rollback` revierte el *rootfs* al estado de tu último `setup` (obviamente, perderás lo que hayas instalado desde entonces). `arxy clean --apply` purga las cachés y destruye el punto de rollback.
* La deduplicación se hace mediante *hardlinks* exclusivamente en `/usr`. Como `pacman` reemplaza los archivos en lugar de reescribirlos *in-place*, los enlaces duros se rompen limpiamente en cada actualización sin corromper el host. Fuera de `/usr` no se enlaza nada.

## Validación y Pruebas

* **Matriz de pruebas en 5 distros** (Alpine, Chimera, Void, Ubuntu y Ubuntu en modo privilegiado): Se ejecuta a través de `arxy-image/tests/matrix.sh`. Hacemos aserciones estrictas sobre el contenido resultante, no solo miramos el código de salida (pasamos entre 33 y 43 checks dependiendo del nivel y las *flags*, ya que la rama de *libc*, el *fallback* a L2 y el chroot `MATRIX_WRITE2=1` varían según el entorno).
Cubre el ciclo completo del Nivel 1 (instalación, ejecución, exportación, borrado) y el Nivel 2 en operaciones de lectura y bloqueos de AUR. Las escrituras en Nivel 2 se prueban forzando `MATRIX_WRITE2=1`. Exportar accesos directos bajo L2 necesita más cobertura automatizada (se verificó a mano). Esta matriz se ejecuta en el CI con cada build de la imagen base.
* **Hardware real** (Intel HD 630): `tests/test-hardware.sh` comprueba que D-Bus funcione en L1 y L2, que el driver `iris` acelere gráficamente, que el *softpipe* sin LLVM rinda como se espera, y levanta una aplicación Electron renderizando una ventana de verdad. (Como `dbus-send` no viene en la imagen mini, ese test hace un SKIP legítimo a menos que hagas un `arxy install dbus`).

## Instalación de Steam (paso a paso)

No automatizamos esto del todo por las peculiaridades de Steam, así que toca ensuciarse un poco las manos:

1. Ejecuta `arxy install arxy-gaming`. Esto te instala Steam, Proton y Wine (la dependencia que tira de AUR se compilará con tu usuario normal, sin privilegios de root).
2. Arranca el demonio con `arxy host-bridge --daemon`. Es opcional, pero muy recomendable para que funcionen las notificaciones nativas y los enlaces clicables entre el juego y tu escritorio.
3. Inicia Steam con `arxy run steam` **asegurándote de hacerlo con tu usuario** (por diseño de Valve, Steam hará *crash* o se negará a arrancar si lo intentas lanzar como root). En su primer arranque, Steam bajará cientos de megas de su propio *runtime*; ten paciencia, esa descarga viene de los servidores de Valve, no de arxy.
4. Haz login, bájate algún juego que no exija mucho para probar, y verifica que arranca.
5. Para confirmar que tienes aceleración por hardware real, lanza Steam inyectando MangoHUD: `MANGOHUD=1 arxy run steam` (verás el overlay de rendimiento en pantalla).

## Cómo contribuir

El proyecto está escrito en Bash puro; la regla de oro es no introducir dependencias nuevas.

Antes de hacer un commit o abrir una Pull Request, asegúrate de pasar estos checks:

```bash
make sync
make verify               # sintaxis, ShellCheck si existe, suite determinista y copias de empaquetado
make test-all              # opcional: bridge/root/hardware; cada prueba mantiene sus guardas

```

**Nota sobre la estructura:** Los archivos en `lib/*.sh` son la fuente de la verdad (el ejecutable final `src/arxy` simplemente se autogenera concatenándolos, y el instalador lo extrae directamente de ahí). Cada grupo tiene una responsabilidad: estado/setup/GC (`20`–`22`), paquetes oficiales/AUR/mantenimiento (`30`–`32`) y detección/doctor/JSON (`60`–`62`). El archivo `config/arxy.conf` también es el canónico, y todo lo que veas en `packaging/void/arxy/files/` son copias empaquetadas para `xbps` (el CI fallará si detecta que divergen).

Por favor, antes de pushear, corre la matriz de pruebas del repositorio hermano `arxy-image` (`tests/matrix.sh`), tienes las instrucciones en `arxy-image/tests/README.md`. Además, echa un vistazo al archivo `AGENTS.md`: contiene las reglas de diseño derivadas de *bugs* reales que nos costó sangre encontrar.

## Licencia

Distribuido bajo GPL-3.0-or-later — detalles en [LICENSE](LICENSE).
