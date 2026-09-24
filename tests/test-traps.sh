#!/usr/bin/env bash
# test-traps.sh — do_dedup y probe_overlayfs desarman sus traps.
# Un trap RETURN/EXIT huerfano disparaba en cada retorno posterior de
# otra funcion: rc falso o "unbound variable" con set -u ($t local ya
# no existe). ARXY_ROOT aislado en /tmp; sin root, sin imagen.
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
ARXY_ROOT="$(mktemp -d)/root"
export ARXY_ROOT
# shellcheck source=../lib/00-head.sh
. "$HERE/../lib/00-head.sh" >/dev/null 2>&1
# shellcheck source=../lib/60-detect.sh
. "$HERE/../lib/60-detect.sh" >/dev/null 2>&1
# shellcheck source=../lib/61-doctor.sh
. "$HERE/../lib/61-doctor.sh" >/dev/null 2>&1
# shellcheck source=../lib/62-json.sh
. "$HERE/../lib/62-json.sh" >/dev/null 2>&1
# shellcheck source=../lib/32-maintenance.sh
. "$HERE/../lib/32-maintenance.sh" >/dev/null 2>&1
mkdir -p "$ARXY_DATA" "$ARXY_ROOT/usr"
trap 'rm -rf "$(dirname "$ARXY_ROOT")"' EXIT

ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo "== T1: probe_overlayfs no deja trap RETURN huerfano"
probe_overlayfs >/dev/null 2>&1
[[ -z "$(trap -p RETURN)" ]] && ok "T1 sin trap RETURN" || no "T1 sin trap RETURN"

echo "== T2: tras probe, otro retorno no mete ruido ni cambia rc"
out="$(probe_overlayfs 2>&1; probe_userns >/dev/null 2>&1; echo "rc=$?")"
grep -q "unbound variable" <<<"$out" && no "T2 sin unbound variable" || ok "T2 sin unbound variable"
grep -q "rc=0" <<<"$out" && ok "T2 rc preservado" || no "T2 rc preservado"

echo "== T3: do_dedup no deja traps huerfanos"
before_exit="$(trap -p EXIT)"
do_dedup >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "T3 dedup rc 0" || no "T3 dedup rc 0"
[[ -z "$(trap -p RETURN)" ]] && ok "T3 sin trap RETURN" || no "T3 sin trap RETURN"
[[ "$(trap -p EXIT)" == "$before_exit" ]] && ok "T3 EXIT intacto" || no "T3 EXIT intacto"

echo "== T4: tras dedup, otro retorno no mete ruido"
out="$(do_dedup 2>&1; probe_userns >/dev/null 2>&1; echo "rc=$?")"
grep -q "unbound variable" <<<"$out" && no "T4 sin unbound variable" || ok "T4 sin unbound variable"
grep -q "rc=0" <<<"$out" && ok "T4 rc preservado" || no "T4 rc preservado"

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
