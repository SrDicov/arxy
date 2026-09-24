#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# arxy — subsistema Arch minimalista para correr software glibc en cualquier distro.
#
# Un namespace bwrap muestra la raíz Arch como / y comparte recursos del host.
# Estado persistente: /var/lib/arxy y lanzadores arxy-*.desktop del usuario.

set -uo pipefail

HOME="${HOME:-/root}"
export LC_ALL=C

ARXY_VERSION="0.6.1"
PROG="arxy"
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"

# --- configuracion (precedencia: env > user-conf > sys-conf > defaults)
# Los .conf son datos: CLAVE=valor, con comillas opcionales y sin expansión.
# La lista cerrada también protege la lectura del config de usuario como root.
declare -ar CONFIG_KEYS=(
    ARXY_ROOT ARXY_IMAGE_URL ARXY_IMAGE_SHA256 ARXY_SIGNATURE_POLICY
    ARXY_LEVEL ARXY_GPG_CHECK ARXY_KEEP_PKG_CACHE ARXY_NO_AUTO_DEDUP
    ARXY_NO_BRIDGE ARXY_BRIDGE_ALLOWLIST ARXY_BRIDGE_BIN
)
declare -ar PRIV_ENV_KEYS=(
    "${CONFIG_KEYS[@]}"
    ARXY_BRIDGE_SOCKET ARXY_BRIDGE_TOKEN ARXY_VERSION_FILE
    ARXY_VERSION_LEGACY ARXY_SYS_ROOT ARXY_SYS_DRM_PATH ARXY_DEV_PATH
    ARXY_LIB_DIR ARXY_LIB64_DIR ARXY_NVIDIA_LIB_ROOT
    ARXY_NVIDIA_LIB_ROOT64 ARXY_NVIDIA_LIB_ROOT32 ARXY_VULKAN_ICD_PATH
    ARXY_EGL_PLATFORM_PATH ARXY_GAMING_AUR_DONE
)
declare -A _frozen_val=()
while IFS= read -r _n; do _frozen_val["$_n"]="${!_n}"; done < <(compgen -e | grep '^ARXY_' || true)

_config_key_allowed() {
    local key
    for key in "${CONFIG_KEYS[@]}"; do
        [[ "$1" == "$key" ]] && return 0
    done
    return 1
}

_config_trim() { # <texto>: resultado en _CONFIG_TEXT
    _CONFIG_TEXT="$1"
    _CONFIG_TEXT="${_CONFIG_TEXT#"${_CONFIG_TEXT%%[![:space:]]*}"}"
    _CONFIG_TEXT="${_CONFIG_TEXT%"${_CONFIG_TEXT##*[![:space:]]}"}"
}

_config_decode() { # <valor>: resultado literal en _CONFIG_VALUE (sin escapes; # tras espacio es comentario solo sin comillas)
    _config_trim "$1"
    local raw="$_CONFIG_TEXT" n=${#_CONFIG_TEXT}
    _CONFIG_VALUE=""
    if [[ "$raw" == \"* ]]; then
        [[ "$n" -ge 2 && "$raw" == *\" ]] || return 1
        _CONFIG_VALUE="${raw:1:n-2}"
    elif [[ "$raw" == \'* ]]; then
        [[ "$n" -ge 2 && "$raw" == *\' ]] || return 1
        _CONFIG_VALUE="${raw:1:n-2}"
    else
        _CONFIG_VALUE="${raw%%[[:space:]]#*}"
        _config_trim "$_CONFIG_VALUE"
        _CONFIG_VALUE="$_CONFIG_TEXT"
    fi
}

_config_read() { # <fichero>: asignaciones permitidas, sin eval/source
    local file="$1" line key raw line_no=0
    [[ -r "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_no=$((line_no + 1))
        _config_trim "$line"
        line="$_CONFIG_TEXT"
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ ! "$line" =~ ^(export[[:space:]]+)?([A-Z_][A-Z0-9_]*)[[:space:]]*=(.*)$ ]]; then
            printf 'arxy: aviso: %s:%d: linea de configuracion ignorada\n' "$file" "$line_no" >&2
            continue
        fi
        key="${BASH_REMATCH[2]}"
        raw="${BASH_REMATCH[3]}"
        if ! _config_key_allowed "$key"; then
            printf 'arxy: aviso: %s:%d: clave no soportada: %s\n' "$file" "$line_no" "$key" >&2
            continue
        fi
        if ! _config_decode "$raw"; then
            printf 'arxy: aviso: %s:%d: comillas no balanceadas en %s\n' "$file" "$line_no" "$key" >&2
            continue
        fi
        printf -v "$key" '%s' "$_CONFIG_VALUE"
    done < "$file"
}

_restore_frozen() { # el env congelado manda sobre cualquier fichero.
    # Debe ocurrir antes de derivar rutas para evitar estados split-brain.
    local _n
    if ((${#_frozen_val[@]})); then
        for _n in "${!_frozen_val[@]}"; do
            printf -v "$_n" '%s' "${_frozen_val[$_n]}"
            # shellcheck disable=SC2163 # export indirecto intencionado (NAME=valor)
            export "$_n"
        done
    fi
}
ARXY_ROOT="${ARXY_ROOT:-/var/lib/arxy/root}"
ARXY_IMAGE_URL="${ARXY_IMAGE_URL:-}"
ARXY_IMAGE_SHA256="${ARXY_IMAGE_SHA256:-}"
ARXY_SIGNATURE_POLICY="${ARXY_SIGNATURE_POLICY:-optional}" # required|optional|off

ARXY_SYS_CONF="/etc/arxy/arxy.conf"
ARXY_USER_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/arxy/config"
_config_read "$ARXY_SYS_CONF"
_config_read "$ARXY_USER_CONF"
_restore_frozen

ARXY_ARGV=("$@")

# --- usuario real (los .desktop van a SU home aunque se use sudo/doas)
if [[ "$(id -u)" -eq 0 ]]; then
    REAL_USER="${SUDO_USER:-${DOAS_USER:-${USER:-$(id -un)}}}"
else
    REAL_USER="${USER:-$(id -un)}"
fi
REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)"
[[ -z "${REAL_HOME:-}" || ! -d "$REAL_HOME" ]] && REAL_HOME="$HOME"
# XDG explícito manda; en otro caso se usa el home del usuario real.
REAL_APPS="${XDG_DATA_HOME:-$REAL_HOME/.local/share}/applications"

# Bajo sudo/doas también se lee como datos la configuración del usuario real.
if [[ "$(id -u)" -eq 0 && "$REAL_HOME" != "$HOME" ]]; then
    _config_read "$REAL_HOME/.config/arxy/config"
    _restore_frozen
fi
unset _frozen_val _CONFIG_TEXT _CONFIG_VALUE

# Vacío no equivale a unset: rechazarlo evita derivar rutas inesperadas.
if [[ -z "${ARXY_ROOT:-}" ]]; then
    echo "arxy: error: ARXY_ROOT vacio (unset para usar el default)" >&2
    exit 1
fi
if [[ "$ARXY_ROOT" != /* || "$ARXY_ROOT" == / ]]; then
    echo "arxy: error: ARXY_ROOT debe ser una ruta absoluta distinta de /" >&2
    exit 1
fi
# Todas las rutas derivadas nacen aquí, después de resolver configuración.
ARXY_DATA="${ARXY_ROOT%/*}"              # /var/lib/arxy
# La versión vive dentro del root y rota atómicamente con la imagen.
: "${ARXY_VERSION_FILE:=$ARXY_ROOT/var/lib/arxy/version}"
# Ruta antigua: solo se adopta y elimina; el código nuevo no la escribe.
: "${ARXY_VERSION_LEGACY:=$ARXY_DATA/version}"
ARXY_BUILD="$ARXY_DATA/build"              # dir de compilacion AUR (1777)
NS_BUILD="/arxy-build"                     # misma dir vista desde dentro

LD_LINUX="$ARXY_ROOT/usr/lib/ld-linux-x86-64.so.2" # interprete ELF del subsistema
ARXY_LIBPATH="$ARXY_ROOT/usr/lib"

# --- utilidades
msg()  { printf 'arxy: %s\n' "$*"; }
die()  { printf 'arxy: error: %s\n' "$*" >&2; exit 1; }

need_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "falta '$c' en el host (instalalo con tu gestor de paquetes)"
    done
}

# Solo PRIV_ENV_KEYS cruza la frontera sudo/doas; el prefijo ARXY_ no basta.
arxy_env_pass() { # imprime VAR=val por linea (valores: rutas/flags, sin \n)
    # sudo/doas fijan el env en el hijo: sin export basta la asignacion.
    local v value
    for v in "${PRIV_ENV_KEYS[@]}"; do
        [[ -v "$v" ]] || continue
        value="${!v}"
        [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] \
            || die "$v contiene saltos de linea y no se puede elevar con seguridad"
        printf '%s=%s\n' "$v" "$value"
    done
}

# Construye una sola frontera de privilegios para sudo y doas. El modo exec
# reemplaza el proceso; run devuelve el estado del comando al llamador.
_root_run() { # <run|exec> <cmd...>
    local mode="$1"; shift
    local -a pass=()
    mapfile -t pass < <(arxy_env_pass)
    local -a elevate
    if command -v sudo >/dev/null 2>&1; then
        elevate=(sudo "${pass[@]}" --)
    elif command -v doas >/dev/null 2>&1; then
        elevate=(doas env "${pass[@]}")
    else
        die "este comando necesita root y no hay sudo/doas"
    fi
    [[ "$mode" == exec ]] && exec "${elevate[@]}" "$@"
    "${elevate[@]}" "$@"
}

as_root() { _root_run run "$@"; }

# Re-ejecuta todo el argv original como root (los comandos que escriben lo exigen).
need_root() {
    [[ "$(id -u)" -eq 0 ]] && return 0
    _root_run exec "$SELF" "${ARXY_ARGV[@]}"
}

_image_ok() { # <dir>: valida un rootfs (instalado o en staging)
    [[ -x "$1/usr/bin/bash" && -x "$1/usr/bin/pacman" && -f "$1/etc/arch-release" ]]
}
image_ok() { _image_ok "$ARXY_ROOT"; }

# Lock único, no bloqueante y reentrante para toda mutación del estado.
# Se toma después de need_root y vive hasta que termina el proceso.
data_lock() {
    [[ -n "${ARXY_LOCK_FD:-}" ]] && return 0 # ya tomado (anidado)
    # Derivar del ROOT actual evita usar un ARXY_DATA antiguo en tests.
    local lf="${ARXY_ROOT%/*}/.lock"
    mkdir -p "${ARXY_ROOT%/*}" 2>/dev/null || die "no pude crear ${ARXY_ROOT%/*} (¿permisos?)"
    # No redirigir este exec: la redirección persistiría en toda la shell.
    exec {ARXY_LOCK_FD}>"$lf"
    [[ -n "${ARXY_LOCK_FD:-}" ]] || die "no pude abrir lock $lf (¿permisos?)"
    flock -n "$ARXY_LOCK_FD" 2>/dev/null || die "otra operacion arxy en curso (lock $lf); reintenta cuando termine"
}

# Sin tty (scripts, pipes) pacman no puede preguntar: confirmar solo.
# Uso: nc_args <nombre-array>; luego "${arr[@]}".
nc_args() {
    local -n _nc=$1
    _nc=()
    [[ -t 0 ]] || _nc=(--noconfirm)
}

ensure_image() {
    recover_staging || true # huerfanos de kills: reparar nunca bloquea el arranque
    if image_ok; then ensure_version; migrate_version_file; return 0; fi
    msg "imagen no encontrada en $ARXY_ROOT, descargando..."
    cmd_setup
    image_ok || die "la instalacion de la imagen fallo (mira el error de arriba o reintenta 'sudo $PROG setup')"
}
