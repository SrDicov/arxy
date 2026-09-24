#!/usr/bin/env bash
# Los argumentos inválidos fallan antes de elevar, descargar o tocar estado.
set -uo pipefail

FAIL=0
HERE="$(dirname "$0")"
. "$HERE/lib.sh"
BIN="$ARXY_BIN"
D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT
export ARXY_ROOT="$D/root"

rejects() { # <nombre> <args...>
    local name="$1" out rc; shift
    out="$("$BIN" "$@" 2>&1)"; rc=$?
    if [[ $rc -ne 0 ]] && grep -q 'uso:' <<<"$out"; then
        echo "PASS: $name"
    else
        echo "FAIL: $name (rc=$rc, salida=$out)"
        FAIL=$((FAIL + 1))
    fi
}

rejects "setup rechaza extras" setup extra
rejects "rollback rechaza extras" rollback extra
rejects "update rechaza extras" update extra
rejects "clean rechaza opcion desconocida" clean --desconocida
rejects "gc rechaza --yes sin --apply" gc --yes
rejects "dedup rechaza extras" dedup extra
rejects "list rechaza extras" list extra
rejects "info exige uno" info uno dos
rejects "quickstart rechaza extras" quickstart extra
rejects "version rechaza extras" version extra
rejects "export exige uno" export uno dos
rejects "unexport exige uno" unexport uno dos
rejects "desktop exige uno" desktop --migrate extra
rejects "which exige uno" which uno dos
rejects "bridge exige un modo" host-bridge --status --stop
rejects "bridge exige path" host-bridge --socket

out="$("$BIN" install "" 2>&1)"; rc=$?
if [[ $rc -ne 0 ]] && grep -q 'nombre de paquete invalido' <<<"$out" \
    && ! grep -q 'necesita root' <<<"$out"; then
    echo "PASS: install valida antes de elevar"
else
    echo "FAIL: install valido tarde (rc=$rc, salida=$out)"
    FAIL=$((FAIL + 1))
fi

[[ ! -e "$ARXY_ROOT" ]] && echo "PASS: argumentos invalidos no crean rootfs" \
    || { echo "FAIL: argumentos invalidos tocaron $ARXY_ROOT"; FAIL=$((FAIL + 1)); }

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit "$FAIL"
