#!/usr/bin/env bash
# test-env-pass.sh — as_root propaga solo la interfaz ARXY_* permitida al
# hijo elevado. Sin esto opera sobre el rootfs por defecto; propagar por
# prefijo convierte variables accidentales en API privilegiada.
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
# shellcheck source=../lib/00-head.sh
. "$HERE/../lib/00-head.sh" >/dev/null 2>&1
D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT
REC="$D/rec"

export ARXY_ROOT="/tmp/fake-root-no-existe" ARXY_PROBE="si" ARXY_BRIDGE_TOKEN="tok-dummy"
sudo() { printf '%s\n' "$@" > "$REC"; return 0; }
as_root true anything
grep -q "^ARXY_ROOT=/tmp/fake-root-no-existe$" "$REC" && echo "PASS: sudo propaga ROOT" || { echo "FAIL: sudo propaga ROOT"; FAIL=$((FAIL+1)); }
if grep -q "^ARXY_PROBE=" "$REC"; then
    echo "FAIL: sudo propaga variable fuera de la interfaz"; FAIL=$((FAIL+1))
else
    echo "PASS: sudo filtra ARXY_* desconocidas"
fi
grep -q "^ARXY_BRIDGE_TOKEN=tok-dummy$" "$REC" && echo "PASS: token viaja en re-exec" || { echo "FAIL: token en re-exec"; FAIL=$((FAIL+1)); }
grep -q "^true$" "$REC" && grep -q "^anything$" "$REC" && echo "PASS: sudo mantiene argv tras --" || { echo "FAIL: sudo argv"; FAIL=$((FAIL+1)); }

mkdir -p "$D/empty"
ln -s "$(command -v grep)" "$D/empty/grep" 2>/dev/null || true
doas() { printf '%s\n' "$@" > "$REC"; return 0; }
# Sin funcion sudo ni sudo real en PATH: cae a la rama doas.
( unset -f sudo; PATH="$D/empty" as_root true anything )
grep -q "^env$" "$REC" && grep -q "^ARXY_ROOT=/tmp/fake-root-no-existe$" "$REC" && echo "PASS: doas via env propaga" || { echo "FAIL: doas propaga"; FAIL=$((FAIL+1)); }

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
