#!/bin/sh
# install-remote.sh — bootstrap de arxy en cualquier distro Linux en un paso:
#
#   curl -fsSL https://raw.githubusercontent.com/SrDicov/arxy/main/install-remote.sh | sudo bash
#
# Hace, en orden: detecta distro/gestor/elevador/arquitectura, instala
# dependencias (nombres por gestor, sin morir por un nombre), instala arxy
# (daemon con cc si hay, si no --without-bridge), descarga el rootfs con
# setup (los repos segun CPU van dentro de setup), update completo y
# verificacion (version + run real). Idempotente: se puede repetir.
#
# POSIX sh a proposito (corre hasta sin bash: ash/dash/busybox): nada de
# [[, arrays, local en caliente, ni pipefail. Errores con die() y motivo.
# Env:
#   ARXY_REF=v0.6.3        rama/tag a instalar (defecto: main)
#   ARXY_REPO=Alguien/arxy para forks (defecto: SrDicov/arxy)
#   ARXY_TARBALL_URL=...   tarball directo (ignora REF/REPO; para test)
#   PREFIX=/usr            destino (defecto de install.sh: /usr/local)
#   DESTDIR=/tmp/pkg       staging: solo instala bins, sin setup/update
#   ARXY_ROOT / ARXY_IMAGE_URL / ARXY_IMAGE_SHA256 / ARXY_SIGNATURE_POLICY
#                          se reenvian a setup/update si no estan vacias
# Seguridad: solo HTTPS; el script no se autoverifica (huevo-gallina):
# leelo en la URL antes de pipearlo, como con cualquier instalador remoto.

set -u

PROG="arxy-remote-install"
REPO="${ARXY_REPO:-SrDicov/arxy}"
REF="${ARXY_REF:-main}"
PREFIX="${PREFIX:-/usr/local}"
DESTDIR="${DESTDIR:-}"

msg() { printf '%s: %s\n' "$PROG" "$*"; }
die() { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 1; }

usage() {
    cat <<EOF
uso: curl -fsSL https://raw.githubusercontent.com/SrDicov/arxy/main/install-remote.sh | sudo bash
     [PREFIX=/usr] [DESTDIR=/tmp/pkg] sh install-remote.sh [--check|--help]

Sin root usa sudo/doas passwordless; si no, pide el pipe con sudo.
--check solo detecta e informa (no cambia nada). Env: ARXY_REF (defecto
main), ARXY_REPO, ARXY_TARBALL_URL, PREFIX, DESTDIR, ARXY_ROOT,
ARXY_IMAGE_URL, ARXY_IMAGE_SHA256, ARXY_SIGNATURE_POLICY.
EOF
}

CHECK=""
for a in ${1+"$@"}; do
    case "$a" in
        --check) CHECK=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "opcion desconocida: '$a' (ver --help)" ;;
    esac
done

# --- deteccion (solo lectura, sin cambios) ---
ARCH="$(uname -m 2>/dev/null || true)"
DIST="desconocida"
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091 # solo ID/PRETTY_NAME, sin ejecutar nada mas
    DIST="$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-${ID:-desconocida}}")"
fi

# Gestor por binario presente (mas fiable que mapear la distro).
PM=""; PM_UPDATE=":"; PM_INSTALL=""
if command -v xbps-install >/dev/null 2>&1; then
    PM="xbps"; PM_UPDATE="xbps-install -S"; PM_INSTALL="xbps-install -y"
elif command -v emerge >/dev/null 2>&1; then
    PM="emerge"; PM_UPDATE=":"; PM_INSTALL="emerge -1q"
elif command -v apk >/dev/null 2>&1; then
    PM="apk"; PM_UPDATE="apk update"; PM_INSTALL="apk add"
elif command -v pacman >/dev/null 2>&1; then
    PM="pacman"; PM_UPDATE="pacman -Sy"; PM_INSTALL="pacman -S --noconfirm --needed"
elif command -v dnf >/dev/null 2>&1; then
    PM="dnf"; PM_UPDATE=":"; PM_INSTALL="dnf install -y"
elif command -v yum >/dev/null 2>&1; then
    PM="dnf"; PM_UPDATE=":"; PM_INSTALL="yum install -y"
elif command -v apt-get >/dev/null 2>&1; then
    PM="apt"; PM_UPDATE="apt-get update"; PM_INSTALL="apt-get install -y"
elif command -v zypper >/dev/null 2>&1; then
    PM="zypper"; PM_UPDATE="zypper refresh"; PM_INSTALL="zypper install -y"
fi

ELEV=""
if [ "$(id -u 2>/dev/null || echo 1)" -eq 0 ]; then
    ELEV=""
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    ELEV="sudo"
elif command -v doas >/dev/null 2>&1 && doas -n true 2>/dev/null; then
    ELEV="doas"
fi

msg "distro: $DIST"
msg "arch: ${ARCH:-?}"
msg "gestor: ${PM:-no detectado}"
if [ -z "$ELEV" ] && [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
    msg "elevador: ninguno passwordless"
else
    msg "elevador: ${ELEV:-root directo}"
fi
[ -n "$CHECK" ] && exit 0

# --- puertas (fallar claro y pronto) ---
[ "$ARCH" = "x86_64" ] || die "arquitectura '${ARCH:-desconocida}' sin rootfs (arxy distribuye x86_64)"
[ -n "$PM" ] || die "gestor no detectado (apt/dnf/pacman/apk/xbps/emerge/zypper): instala a mano bash bwrap curl tar zstd xz gzip file y repite"
if [ -z "$ELEV" ]; then
    die "sin root ni sudo/doas passwordless: repite como root o con el pipe en sudo"
fi

# Espacio para el rootfs (~0.5GB imagen + crecimiento con update).
DFDIR="${ARXY_ROOT:-/var/lib/arxy/root}"
while [ ! -e "$DFDIR" ]; do DFDIR="$(dirname "$DFDIR")"; done
# df -P: una linea por fs (los 4 primeros campos son estables aunque el
# punto de montaje lleve espacios). set -- reusa $@ (args ya consumidos).
# shellcheck disable=SC2046 # split intencionado para trocear la linea de df
set -- $(df -P -k "$DFDIR" 2>/dev/null | tail -n 1)
case "${4:-}" in
    ''|*[!0-9]*) msg "aviso: no pude medir disco libre (sigo)" ;;
    *) [ "$4" -ge 1500000 ] || die "poco disco en $DFDIR (libres ${4}KB, pide ~1.5GB)" ;;
esac

# Rutas absolutas antes de elevar (sudo/doas recortan PATH).
PM_UP_BIN=":"; PM_IN_BIN=""
case "$PM_UPDATE" in : ) ;; *) PM_UP_BIN="$(command -v "${PM_UPDATE%% *}")" || true ;; esac
PM_IN_BIN="$(command -v "${PM_INSTALL%% *}")" || true
[ -n "$PM_IN_BIN" ] || die "no encontre el binario de $PM"

fetch() { # <url> <dest> : curl o wget (lo que haya)
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 -o "$2" "$1" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$2" "$1" 2>/dev/null
    else
        die "sin curl ni wget para descargar"
    fi
}

# Nombres por gestor (emerge necesita atomos). Los que falten se avisan;
# al final se exige por COMANDO, no por paquete (un nombre malo no mata).
pm_pkgs() { # <grupo> : paquetes del grupo para $PM, en una linea
    case "$1" in
        hard)
            case "$PM" in
                emerge) echo "app-shells/bash net-misc/curl app-arch/tar app-arch/gzip app-arch/xz-utils app-arch/zstd sys-apps/file sys-apps/bubblewrap sys-apps/coreutils app-misc/ca-certificates" ;;
                apk) echo "bash curl tar gzip xz zstd file bubblewrap coreutils ca-certificates chimerautils" ;;
                *) echo "bash curl tar gzip xz zstd file bubblewrap coreutils ca-certificates" ;;
            esac
            # xz en apt se llama xz-utils
            [ "$PM" = "apt" ] && echo "xz-utils"
            ;;
        soft)
            case "$PM" in
                emerge) echo "app-crypt/minisign dev-util/desktop-file-utils" ;;
                *) echo "minisign desktop-file-utils" ;;
            esac
            ;;
        cc)
            case "$PM" in
                apk) echo "gcc musl-dev musl-devel gmake" ;; # alpine vs chimera (+make de gmake)
                emerge) echo "" ;;
                apt|dnf|pacman|xbps|zypper) echo "gcc make" ;;
                *) echo "gcc make" ;;
            esac
            ;;
    esac
}

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/arxy-install.XXXXXX" 2>/dev/null)" || die "sin temporal en ${TMPDIR:-/tmp}"
trap 'rm -rf "$TMPD"' EXIT INT TERM HUP

msg "actualizando indices de $PM..."
# shellcheck disable=SC2086 # PM_UPDATE son palabras a proposito
if [ "$PM_UP_BIN" = ":" ]; then :; else $ELEV "$PM_UP_BIN" ${PM_UPDATE#* } >/dev/null 2>&1 || msg "aviso: fallo el update de $PM (sigo con lo instalado)"; fi

pm_install_group() { # <grupo> : instala uno a uno, avisando sin morir
    for _p in $(pm_pkgs "$1"); do
        if $ELEV "$PM_IN_BIN" ${PM_INSTALL#* } "$_p" >/dev/null 2>&1; then
            msg "dep: $_p ok"
        else
            msg "aviso: no pude instalar '$_p' con $PM (sigo)"
        fi
    done
}

msg "instalando dependencias duras..."
pm_install_group hard

# Verificacion por COMANDO (lo que arxy necesita de verdad).
missing=""
for c in bash bwrap curl tar zstd xz gzip file sha256sum; do
    command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
done
if [ -n "$missing" ]; then
    extra="(en gentoo, emerge --sync primero si falta algo)"
    [ "$PM" = "emerge" ] || extra=""
    die "faltan comandos tras instalar dependencias:$missing $extra (instalalos con tu gestor y repite)"
fi
BASH_BIN="$(command -v bash)"

msg "instalando opcionales (minisign, desktop, compilador)..."
pm_install_group soft
pm_install_group cc
command -v minisign >/dev/null 2>&1 || msg "aviso: sin minisign (las firmas solo avisaran)"
command -v update-desktop-database >/dev/null 2>&1 || msg "aviso: sin update-desktop-database (los lanzadores igual se crean)"

# --- descarga del proyecto (a fichero: re-leible y sin pipefail) ---
TARBALL_URL="${ARXY_TARBALL_URL:-https://github.com/$REPO/archive/refs/heads/$REF.tar.gz}"
msg "descargando arxy ($TARBALL_URL)..."
if ! fetch "$TARBALL_URL" "$TMPD/arxy.tar.gz"; then
    # branches vs tags: si falla heads, probar tags (ARXY_REF=v0.6.3).
    TARBALL_URL="https://github.com/$REPO/archive/refs/tags/$REF.tar.gz"
    msg "reintentando como tag ($TARBALL_URL)..."
    fetch "$TARBALL_URL" "$TMPD/arxy.tar.gz" || die "no pude descargar arxy (¿red? ¿existe '$REF'?)"
fi
[ -s "$TMPD/arxy.tar.gz" ] || die "descarga vacia"
SRCDIR="$TMPD/src"
mkdir -p "$SRCDIR" || die "sin escritura en $TMPD"
tar -xzf "$TMPD/arxy.tar.gz" -C "$SRCDIR" || die "tarball corrupto (¿espacio? ¿tar sin gzip?)"
NSUB="$(ls -A "$SRCDIR" 2>/dev/null | wc -l | tr -d ' ')"
[ "$NSUB" = "1" ] || die "tarball inesperado ($NSUB entradas arriba)"
SRC="$SRCDIR/$(ls -A "$SRCDIR")"
[ -f "$SRC/install.sh" ] || die "el tarball no trae install.sh"

# --- daemon host-bridge (el tarball no lo trae compilado; sin el,
# install.sh muere si hay cc). Como usuario: no necesita root.
BRIDGE_FLAG="--without-bridge"
if command -v cc >/dev/null 2>&1 && command -v make >/dev/null 2>&1; then
    msg "compilando daemon host-bridge..."
    if out="$(cd "$SRC" && make bridge 2>&1)"; then
        BRIDGE_FLAG=""
        msg "daemon compilado"
    else
        msg "aviso: no compilo el daemon (se omite; el resto funciona)"
        printf '%s\n' "$out" | tail -n 3 | sed 's/^/  /'
    fi
else
    msg "aviso: sin cc/make (daemon host-bridge omitido; el resto funciona)"
fi

# --- instalacion de arxy (su propio install.sh manda; necesita bash) ---
msg "instalando arxy en $DESTDIR$PREFIX..."
# shellcheck disable=SC2086 # BRIDGE_FLAG vacio o una palabra
if [ -n "$DESTDIR" ]; then
    $ELEV env PREFIX="$PREFIX" DESTDIR="$DESTDIR" "$BASH_BIN" "$SRC/install.sh" $BRIDGE_FLAG || die "fallo install.sh (staging)"
else
    $ELEV env PREFIX="$PREFIX" "$BASH_BIN" "$SRC/install.sh" $BRIDGE_FLAG || die "fallo install.sh"
fi
ARXY_BIN="$PREFIX/bin/arxy"
[ -n "$DESTDIR" ] && ARXY_BIN="$DESTDIR$PREFIX/bin/arxy"
[ -x "$ARXY_BIN" ] || die "install.sh no dejo $ARXY_BIN"

if [ -n "$DESTDIR" ]; then
    msg "staging en $DESTDIR (sin setup/update: es empaquetado, no instalacion)"
    msg "listo (staging)"
    exit 0
fi

# --- rootfs + update + verificacion (con reenvio de overrides) ---
# shellcheck disable=SC2086 # ELEV vacio o sudo/doas
run_arxy() { # <args de arxy...> : como root, reenviando overrides no vacios
    $ELEV env ${ARXY_ROOT:+ARXY_ROOT="$ARXY_ROOT"} \
        ${ARXY_IMAGE_URL:+ARXY_IMAGE_URL="$ARXY_IMAGE_URL"} \
        ${ARXY_IMAGE_SHA256:+ARXY_IMAGE_SHA256="$ARXY_IMAGE_SHA256"} \
        ${ARXY_SIGNATURE_POLICY:+ARXY_SIGNATURE_POLICY="$ARXY_SIGNATURE_POLICY"} \
        "$ARXY_BIN" "$@"
}

msg "descargando el rootfs (setup)..."
run_arxy setup || die "fallo arxy setup (¿red? ¿~1GB libre? reintenta)"

msg "actualizando todos los paquetes (update)..."
run_arxy update || die "fallo arxy update (reintenta '$ARXY_BIN update')"

msg "verificando instalacion..."
VER="$(run_arxy version 2>&1)" || die "arxy version fallo tras instalar"
msg "instalado: $VER"
if run_arxy run /usr/bin/true >/dev/null 2>&1; then
    msg "run funciona (listo para usar)"
else
    die "arxy run fallo tras instalar (mira '$ARXY_BIN doctor')"
fi
if run_arxy doctor >/dev/null 2>&1; then
    msg "doctor limpio"
else
    msg "aviso: doctor marca pendientes (mira '$ARXY_BIN doctor --fix')"
fi
msg "siguiente paso sugerido:"
run_arxy quickstart 2>&1 | head -n 6 || true
msg "listo: $ARXY_BIN"
