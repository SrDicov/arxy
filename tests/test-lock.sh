#!/usr/bin/env bash
# test-lock.sh — contencion de data_lock (L3).
# Sin root ni imagen: el lock vive bajo ARXY_ROOT en /tmp.
# SKIP honesto sin flock. El holder de fondo mantiene el lock 4s;
# el hijo debe morir con "otra operacion en curso" sin tocar nada.
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
# shellcheck source=lib.sh
. "$HERE/lib.sh" # ok/no/finish
if ! command -v flock >/dev/null 2>&1; then
    echo "SKIP: test-lock.sh (sin flock en este host)"
    echo "== resultado: TODO_OK (1 SKIP)"
    exit 0
fi
D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT
export ARXY_ROOT="$D/root"
# shellcheck source=../lib/00-head.sh
. "$HERE/../lib/00-head.sh" >/dev/null 2>&1
LOCK="${ARXY_ROOT%/*}/.lock"
mkdir -p "$D"

echo "== reentrancia: doble toma en la misma shell vale =="
data_lock && ok "primera toma rc 0" || no "primera toma"
data_lock && ok "segunda toma rc 0 (reentrante)" || no "segunda toma"
exec {ARXY_LOCK_FD}>&- 2>/dev/null || true; unset ARXY_LOCK_FD

echo "== contencion: otro proceso con el lock =="
( exec {h}>"$LOCK" && flock -n "$h" && sleep 4 ) &
holder=$!
sleep 1 # el holder ya tiene el lock (flock -n es inmediato)
out="$( ( data_lock ) 2>&1 )"; rc=$?
kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
if [[ "$rc" != 0 ]] && grep -q 'otra operacion' <<<"$out"; then
    ok "contencion muere claro"
else
    no "contencion" "rc=$rc [$out]"
fi

echo "== liberado: tras el holder se puede tomar =="
data_lock && ok "toma tras liberar" || no "toma tras liberar"
exec {ARXY_LOCK_FD}>&- 2>/dev/null || true; unset ARXY_LOCK_FD

finish
