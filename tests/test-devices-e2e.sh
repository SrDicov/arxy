#!/usr/bin/env bash
# test-devices-e2e.sh — audio e input visibles en el sandbox. Silencioso:
# solo lista e inspecciona, nunca emite sonido. Sin root+imagen: SKIP.
# Rootfs sin alsa-utils/evtest: se instalan (--needed, diminutos) en root
# aislado. Un solo guard ARXY_ROOT + un solo t (lib.sh) para ambas clases.
set -uo pipefail
FAIL=0
[[ "$(id -u)" -eq 0 ]] || { echo "SKIP: exige root"; exit 0; }
HERE="$(dirname "$0")"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
BIN="$ARXY_BIN"
R="${ARXY_ROOT:-/tmp/devices-root}"
[[ "$R" == /var/lib/arxy/root ]] && { echo "SKIP: exige ARXY_ROOT aislado"; exit 0; }
# El rootfs aislado por defecto es desechable: limpiar siempre al salir
# (el guard de arriba garantiza que nunca es el real; con ARXY_ROOT
# propio no se toca nada).
[[ "$R" == /tmp/devices-root ]] && trap 'rm -rf /tmp/devices-root' EXIT INT TERM HUP
export ARXY_ROOT="$R"

echo "== audio =="
"$BIN" run sh -c 'command -v aplay' >/dev/null 2>&1 || "$BIN" install alsa-utils >/dev/null 2>&1 || { echo "SKIP: sin alsa-utils (ni red)"; exit 0; }
t "aplay lista tarjetas" "card" -- "$BIN" run aplay -l
t "controlC0 visible" "controlC0" -- "$BIN" run sh -c 'ls /dev/snd/ | grep control'

echo "== input =="
t "event nodes visibles" "event0" -- "$BIN" run sh -c 'ls /dev/input/ | grep event'
"$BIN" run sh -c 'command -v evtest' >/dev/null 2>&1 || "$BIN" install evtest >/dev/null 2>&1 || { echo "SKIP: sin evtest (ni red)"; exit 0; }
t "evtest presente" "evtest" -- "$BIN" run evtest --version

finish
