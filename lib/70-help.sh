cmd_help() {
    cat <<EOF
$PROG $ARXY_VERSION — subsistema Arch minimalista (rápido, sin sandbox).

Uso: $PROG <comando> [args...]   (axy es alias de $PROG)
Sin ayuda por comando: cada mal uso imprime su uso de una linea.

Empezar:
  setup                (re)descarga e instala la imagen (atomico, con rollback)
  quickstart|qs        dice tu siguiente paso segun estado (para empezar)
  doctor [--fix [--apply]|--json]  verifica (fix informa; --apply root)
  version [--verbose]  version CLI+imagen (verbose: nivel/GPU/tamaño/hold)
  help                 esta ayuda

Dia a dia:
  install|i <pkg...>   instalar paquetes de Arch (+ crea lanzadores .desktop)
  install gpu-amd|gpu-nvidia  stack GL completo para esas GPUs (+~170MB)
  install arxy-gaming[-amd|-intel|-nvidia] [--dry-run]  stack gaming (auto u override)
  install --aur <pkg>  instalar de AUR (precompilados -bin, paru o git+RPC)
  remove|rm <pkg...>   desinstalar (+ borra sus lanzadores)
  update|up            actualizar todo el subsistema (pacman -Syu)
  run|r <bin|ruta> [...] ejecutar programa del subsistema o binario suelto
  shell [cmd...]       terminal Arch completa (admin: sudo $PROG shell)
  search|s <texto>     buscar en repos
  search-aur|sa <txt>  buscar en AUR (paru o RPC; requiere jq)
  info <pkg>           info de un paquete (instalado o de repos)
  list|l               paquetes instalados ([desktop] = tiene lanzador)
  which|w <bin|ruta>    muestra donde se resolveria ([subsistema] o [host])
  export <pkg|f.desktop|--all>  (re)crear lanzadores .desktop
  unexport <nombre>    borrar un lanzador
  desktop --migrate    migrar lanzadores legacy sin X-Arxy-Pkg (idempotente)
  host-bridge [--daemon|--stop|--status] [--socket P] [--allowed-cmd BIN...]
                       daemon host-bridge (sin allowlist no arranca)

Reparar y mantener:
  rollback             restaura el setup inmediato anterior (1 sola generacion)
  clean [--apply]   informa uso (rootfs/cache/AUR) y limpia con --apply
  gc [--json] [--apply]  informa bytes (rollback/cache/build/staging) en texto o JSON; --apply purga
  dedup                hardlinkea ficheros identicos de /usr (ahorra disco)

Atajos: i add, rm uninstall, up upgrade, clean-cache, show, l ls installed, s find, sa, r exec x, w, sh enter, check, qs start, init, -v --version, -h --help. Si el comando no existe, se interpreta como 'run':
  $PROG firefox   ==   $PROG run firefox

Ejemplos:
  $PROG install firefox gimp htop
  $PROG run ./mi-binario-suelto --opcion
  $PROG shell
  sudo $PROG shell        # para pacman manual dentro

Config: $ARXY_SYS_CONF, ~/.config/arxy/config (env manda).
Nivel: auto (1=bwrap, 2=sin namespaces); forzar con ARXY_LEVEL=1|2.
Imagen: $ARXY_ROOT  (se descarga sola en el primer uso).
EOF
}
