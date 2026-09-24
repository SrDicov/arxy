#!/usr/bin/env bash
# test-hardware.sh — GPU/dbus/export/app en hardware real (Intel HD 630).
# Uso: ./tests/test-hardware.sh  (arxy en PATH; corre en el HOST, no en container)
# Reporta PASS/SKIP/FAIL con evidencia. Lo que no hay (AMD/NVIDIA) se SKIPea,
# no se finge: ver tabla "probado en hardware" del README.
# Depende de red solo si falta mesa-utils (se instala con sudo no interactivo).
set -uo pipefail
FAIL=0; SKIP=0
HERE_HW="$(dirname "$0")"
# shellcheck source=lib.sh
. "$HERE_HW/lib.sh" >/dev/null 2>&1 # solo ARXY_BIN default; pass/skip/fail propios
# Sin bridge aqui (auto-arranque ensuciaria la sesion; el bridge se prueba
# en test-host-bridge.sh y test-bridge-in-container.sh).
export ARXY_NO_BRIDGE=1

say()  { echo "$1: $2"; }
pass() { say PASS "$1"; }
skip() { say SKIP "$1"; SKIP=$((SKIP+1)); }
fail() { say FAIL "$1"; FAIL=$((FAIL+1)); }

command -v arxy >/dev/null 2>&1 || { echo "FAIL: arxy no instalado en el host"; exit 1; }
echo "== host: $(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"') / $(uname -m)"
echo "== sesion: DISPLAY=${DISPLAY:-} WAYLAND=${WAYLAND_DISPLAY:-} BUS=${DBUS_SESSION_BUS_ADDRESS:-sin-bus}"
arxy version --verbose 2>/dev/null | sed 's/^/== /'

# --- helpers
has_bus() { [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" || -S "/run/user/$(id -u)/bus" ]]; }
has_intel() { grep -qi '8086' /sys/class/drm/card*/device/vendor 2>/dev/null; }
have_glx() { arxy run /usr/bin/test -x /usr/bin/glxinfo >/dev/null 2>&1; }
provision_glx() { # mesa-utils si falta (sudo no interactivo o SKIP)
    have_glx && return 0
    sudo -n arxy install mesa-utils >/dev/null 2>&1 || return 1
    have_glx
}

# T1/T2 dbus sesion L1+L2 (el gap que la matrix no caza: en containers no hay bus)
# OJO: nada de 'prod | grep -q' con pipefail (grep -q cierra el pipe,
# el productor muere por SIGPIPE=141 y el check miente). Se captura todo
# en variable y se grepea despues. Y --version no sirve de sonda: varios
# binarios (dbus-send) devuelven rc!=0 siempre; presencia = test -x.
if ! has_bus; then
    skip "dbus L1 (sin bus de sesion en este host)"
    skip "dbus L2 (sin bus de sesion en este host)"
elif ! arxy run /usr/bin/test -x /usr/bin/dbus-send >/dev/null 2>&1; then
    skip "dbus L1/L2 (imagen sin dbus-send)"
else
    _out="$(arxy run /usr/bin/dbus-send --session --print-reply --dest=org.freedesktop.DBus \
        /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>/dev/null)"
    if grep -q 'org.freedesktop.DBus' <<<"$_out"; then
        pass "dbus sesion L1 ($(grep -c 'string "' <<<"$_out" 2>/dev/null || echo ?) nombres en el bus)"
    else fail "dbus sesion L1"; fi
    _out="$(ARXY_LEVEL=2 arxy run /usr/bin/dbus-send --session --print-reply --dest=org.freedesktop.DBus \
        /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>/dev/null)"
    if grep -q 'org.freedesktop.DBus' <<<"$_out"; then
        pass "dbus sesion L2"
    else fail "dbus sesion L2"; fi
fi

# T3/T4 iris L1+L2 (imagen mini: sin LLVM; el driver iris no lo necesita)
if ! has_intel; then
    skip "iris L1 (sin GPU Intel en este host)"
    skip "iris L2 (sin GPU Intel en este host)"
elif ! provision_glx; then
    skip "iris L1/L2 (sin mesa-utils y sin sudo no interactivo)"
else
    _r="$(arxy run /usr/bin/glxinfo -B 2>/dev/null | grep -E 'renderer string|Accelerated')"
    if grep -q 'Mesa Intel' <<<"$_r" && grep -q 'Accelerated: yes' <<<"$_r"; then
        pass "iris L1 ($(grep -o 'Mesa Intel[^)]*)' <<<"$_r" | head -1))"
    else fail "iris L1 ($_r)"; fi
    _r="$(ARXY_LEVEL=2 arxy run /usr/bin/glxinfo -B 2>/dev/null | grep -E 'renderer string|Accelerated')"
    if grep -q 'Mesa Intel' <<<"$_r" && grep -q 'Accelerated: yes' <<<"$_r"; then
        pass "iris L2"
    else fail "iris L2 ($_r)"; fi
    # T5 softpipe: el driver esta (fallback sin LLVM); si llvm-libs llego como
    # dep de mesa-utils, el contexto software real es llvmpipe y se informa.
    if arxy run /usr/bin/ls /usr/lib/dri/swrast_dri.so >/dev/null 2>&1; then
        if arxy run /usr/bin/pacman -Q llvm-libs >/dev/null 2>&1; then
            pass "softpipe presente (swrast_dri.so; ojo: llvm-libs instalado -> el contexto soft es llvmpipe)"
        else
            _s="$(LIBGL_ALWAYS_SOFTWARE=1 arxy run /usr/bin/glxinfo -B 2>/dev/null | grep 'renderer string')"
            pass "softpipe sin LLVM ($_s)"
        fi
    else fail "softpipe (falta swrast_dri.so en la imagen)"; fi
fi

# T6 export crea lanzador real (y unexport lo retira; no toca paquetes)
_desks="$(arxy run /usr/bin/bash -c 'ls /usr/share/applications/*.desktop 2>/dev/null' || true)"
_desk="$(head -n 1 <<<"$_desks")"
if [[ -z "${_desk:-}" ]]; then
    skip "export (ningun .desktop en la imagen)"
else
    _base="${_desk##*/}"; _base="${_base%.desktop}"
    if arxy export "$_desk" >/dev/null 2>&1 && [[ -f "$HOME/.local/share/applications/arxy-$_base.desktop" ]] \
        && grep -q '^X-Arxy-Pkg=' "$HOME/.local/share/applications/arxy-$_base.desktop"; then
        pass "export crea lanzador (arxy-$_base.desktop)"
        arxy unexport "$_base" >/dev/null 2>&1 || fail "unexport ($_base)"
    else fail "export ($_desk)"; fi
fi

# T7 app Electron real (solo si pear-desktop-bin instalado; no instala nada).
# Ventana Wayland comprobable con hyprctl si existe; si no, proceso vivo + log.
_list="$(arxy list 2>/dev/null || true)"
if ! grep -q '^pear-desktop-bin ' <<<"$_list"; then
    skip "app GUI (pear-desktop-bin no instalado)"
elif [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    skip "app GUI (sin display en este host)"
else
    _dir="/tmp/pear-hwtest-$$"; _log="$_dir.log"
    rm -rf "$_dir"
    (setsid arxy run /usr/bin/youtube-music --no-sandbox --user-data-dir="$_dir" >"$_log" 2>&1 < /dev/null &)
    sleep 12
    _pids="$(pgrep -f "user-data-dir=$_dir" | grep -vx "$$" || true)"
    _crash="$(grep -caiE 'exception|enoent' "$_log" 2>/dev/null || true)"
    _win=""; command -v hyprctl >/dev/null 2>&1 && \
        _win="$(hyprctl clients 2>/dev/null | grep -i 'youtube music' | head -1 || true)"
    # matar solo la app (PIDs listados, nunca patrones ciegos: pkill -f se
    # suicida porque el propio shell contiene el patron).
    for _p in $_pids; do kill -KILL "$_p" 2>/dev/null || true; done
    rm -rf "$_dir" "$_log"
    if [[ -n "$_pids" && "${_crash:-0}" -eq 0 ]]; then
        pass "app GUI viva 12s sin crash${_win:+ + ventana: ${_win}}"
    else fail "app GUI (pids='${_pids:-ninguno}' crash=$_crash)"; fi
fi

# T8 presencia de Steam en el rootfs real (plegado de test-steam-presence.sh).
# NUNCA lanza UI ni ejecuta el binario (ni `steam --help`: se cuelga):
# presencia = test -x, nunca --version (AGENTS.md regla 5). Sin rootfs real
# o sin steam.desktop: SKIP honesto (no FAIL).
_R="${ARXY_ROOT:-/var/lib/arxy/root}"
if [[ ! -d "$_R/usr/bin" ]]; then
    skip "steam (sin rootfs real en $_R)"
elif [[ ! -f "$_R/usr/share/applications/steam.desktop" ]]; then
    skip "steam (sin steam.desktop en $_R)"
else
    if [[ -x "$_R/usr/bin/steam" ]]; then pass "steam presente (+x)";
    else fail "steam ausente en $_R/usr/bin/steam"; fi

    # Regla 5 (pipefail): capturar en variable y grepear despues.
    _desk_out="$(grep -E '^Exec=' "$_R/usr/share/applications/steam.desktop" 2>&1 || true)"
    if grep -q '^Exec=/usr/bin/steam' <<<"$_desk_out"; then pass "steam.desktop Exec";
    else fail "steam.desktop sin Exec=/usr/bin/steam (tengo [$_desk_out])"; fi

    if [[ -e "$_R/usr/bin/proton-ge" ]]; then
        if [[ -x "$_R/usr/bin/proton-ge" ]]; then pass "proton-ge presente (+x)";
        else fail "proton-ge sin +x en $_R/usr/bin/proton-ge"; fi
    else
        echo "INFO: proton-ge ausente (opcional, no bloquea)"
    fi
fi

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS") ($SKIP skips)"
exit $FAIL
