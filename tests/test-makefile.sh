#!/usr/bin/env bash
# test-makefile.sh — el build genera src/arxy byte-idéntico y válido.
# Sin root. Se corre desde la raíz del repo arxy (o tests/).
set -uo pipefail
FAIL=0
cd "$(dirname "$0")/.." || exit 1

t() { # t <nombre> -- <cmd...>
    local name="$1"; shift; shift
    local out rc
    if out="$("$@" 2>&1)"; then echo "PASS: $name";
    else rc=$?; echo "FAIL($rc): $name"; printf '%s\n' "$out" | head -6 | sed 's/^/  /'; FAIL=$((FAIL+1)); fi
}

t "make src/arxy sale 0" -- make src/arxy
h1="$(sha256sum <src/arxy)"
t "generado idempotente" -- sh -c 'make -B src/arxy >/dev/null && test "$(sha256sum <src/arxy)" = "'"$h1"'"'
t "bash -n generado" -- bash -n src/arxy
t "shebang + main" -- sh -c 'test "$(head -1 src/arxy)" = "#!/usr/bin/env bash" && grep -q "^main()" src/arxy && test "$(tail -1 src/arxy)" = "fi"'
t "bundle sourceable sin dispatch" -- bash -c 'set -- no-debe-ejecutarse; ARXY_ROOT=/tmp/arxy-source-test; . ./src/arxy >/dev/null 2>&1; declare -F main >/dev/null'

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
