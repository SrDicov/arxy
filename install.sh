#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# install.sh — instalador generico de arxy para cualquier distro.
# (En Void se recomienda el paquete xbps de packaging/void en su lugar.)
#
#   sudo ./install.sh                    # a /usr/local
#   sudo PREFIX=/usr ./install.sh        # a /usr
#   DESTDIR=/tmp/pkg PREFIX=/usr ./install.sh   # empaquetado
#   ./install.sh --help                  # esta ayuda
#   ./install.sh --without-bridge        # omite el daemon
#
# Instala: bin/arxy (+ sub-binarios arxy-* y symlink axy) y etc/arxy.conf.
# Con el daemon host-bridge salvo --without-bridge.
# La configuracion existente NO se sobrescribe (se deja .nuevo al lado).

set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"
DESTDIR="${DESTDIR:-}"
WITH_BRIDGE=1
for _a in ${1+"$@"}; do
    case "$_a" in
        --without-bridge) WITH_BRIDGE="" ;;
        -h|--help) echo "uso: [sudo] PREFIX= DESTDIR= ./install.sh [--without-bridge]"; exit 0 ;;
        *) echo "opcion desconocida: '$_a' (ver --help)" >&2; exit 1 ;;
    esac
done

SRC_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")"

BIN_DST="$DESTDIR$PREFIX/bin"
CONF_DST="$DESTDIR/etc/arxy"
LIB_DST="$DESTDIR$PREFIX/lib/arxy"

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "falta '$1' en el host" >&2; exit 1; }; }

# Dependencias de runtime de arxy (mismas que el template xbps + sha256sum).
for c in bash bwrap curl tar zstd xz gzip file sha256sum; do
    need_cmd "$c"
done

[[ -f "$SRC_DIR/src/arxy" ]] || { echo "no se encuentra src/arxy (ejecuta desde la raiz del repo)" >&2; exit 1; }
for _b in run pkg query desktop setup maint doctor bridge help; do
    [[ -f "$SRC_DIR/src/arxy-$_b" ]] || { echo "no se encuentra src/arxy-$_b (ejecuta 'make build' desde la raiz)" >&2; exit 1; }
done
[[ -f "$SRC_DIR/config/arxy.conf" ]] || { echo "no se encuentra config/arxy.conf" >&2; exit 1; }
[[ -f "$SRC_DIR/config/arxy.pub" ]] || { echo "no se encuentra config/arxy.pub" >&2; exit 1; }

# fallar ANTES de copiar nada si la sysconf no es escribible (antes
# dejaba binarios a medias + error crudo de install(1)). Sube al primer
# ancestro existente para no romper DESTDIR staging aun no creado.
_conf_probe="$CONF_DST"
while [[ ! -e "$_conf_probe" ]]; do _conf_probe="$(dirname "$_conf_probe")"; done
[[ -w "$_conf_probe" ]] || { echo "sin escritura en $CONF_DST (¿root? para staging usa DESTDIR=/tmp/pkg $0)" >&2; exit 1; }

install -d -m755 "$BIN_DST" "$CONF_DST"
install -m755 "$SRC_DIR/src/arxy" "$BIN_DST/arxy"
for _b in run pkg query desktop setup maint doctor bridge help; do
    install -m755 "$SRC_DIR/src/arxy-$_b" "$BIN_DST/arxy-$_b"
done
ln -sf arxy "$BIN_DST/axy"
if [[ -n "$WITH_BRIDGE" ]]; then
    [[ -f "$SRC_DIR/bridge/arxy-bridged" ]] || { echo "sin bridge/arxy-bridged (ejecuta 'make bridge' o repite con --without-bridge)" >&2; exit 1; }
    install -d -m755 "$LIB_DST"
    install -m755 "$SRC_DIR/bridge/arxy-bridged" "$LIB_DST/arxy-bridged"
    echo "arxy-bridged en $LIB_DST"
fi
if [[ -f "$CONF_DST/arxy.conf" && -z "$DESTDIR" ]]; then
    install -m644 "$SRC_DIR/config/arxy.conf" "$CONF_DST/arxy.conf.nuevo"
    echo "arxy instalado; tu /etc/arxy/arxy.conf se conserva (nuevo en arxy.conf.nuevo)"
else
    install -m644 "$SRC_DIR/config/arxy.conf" "$CONF_DST/arxy.conf"
    echo "arxy instalado en $BIN_DST (arxy + axy)"
fi
# La pubkey NO es config de usuario: siempre se instala (trust root).
install -m644 "$SRC_DIR/config/arxy.pub" "$CONF_DST/arxy.pub"
echo "Siguiente: sudo arxy setup"
