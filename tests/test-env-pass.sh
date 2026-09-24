#!/usr/bin/env bash
# test-env-pass.sh — re-exec con privilegios: as_root propaga solo la
# interfaz ARXY_* permitida al hijo elevado (A: stubs sudo/doas), sin
# elevador no se eleva (B: falla claro, nunca opera sobre el rootfs por
# defecto en silencio) y el sudo real deja pasar VAR= explicitos
# (C: NOPASSWD o SKIP honesto, lo cubren los stubs de A).
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
# shellcheck source=lib.sh
. "$HERE/lib.sh" # ok/no
# shellcheck source=../lib/00-head.sh
. "$HERE/../lib/00-head.sh" >/dev/null 2>&1
D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT
REC="$D/rec"

echo "== A: stubs (argv construido) =="
export ARXY_ROOT="/tmp/fake-root-no-existe" ARXY_PROBE="si" ARXY_BRIDGE_TOKEN="tok-dummy"
sudo() { printf '%s\n' "$@" > "$REC"; return 0; }
as_root true anything
grep -q "^ARXY_ROOT=/tmp/fake-root-no-existe$" "$REC" && ok "sudo propaga ROOT" || no "sudo propaga ROOT"
if grep -q "^ARXY_PROBE=" "$REC"; then
    no "sudo propaga variable fuera de la interfaz"
else
    ok "sudo filtra ARXY_* desconocidas"
fi
grep -q "^ARXY_BRIDGE_TOKEN=tok-dummy$" "$REC" && ok "token viaja en re-exec" || no "token en re-exec"
grep -q "^true$" "$REC" && grep -q "^anything$" "$REC" && ok "sudo mantiene argv tras --" || no "sudo argv"

mkdir -p "$D/empty"
ln -s "$(command -v grep)" "$D/empty/grep" 2>/dev/null || true
doas() { printf '%s\n' "$@" > "$REC"; return 0; }
# Sin funcion sudo ni sudo real en PATH: cae a la rama doas.
( unset -f sudo; PATH="$D/empty" as_root true anything )
grep -q "^env$" "$REC" && grep -q "^ARXY_ROOT=/tmp/fake-root-no-existe$" "$REC" && ok "doas via env propaga" || no "doas propaga"
unset -f sudo doas

echo "== B: sin elevador no se eleva =="
# id SÍ (sin el, $(id -u) da "" y [[ "" -eq 0 ]] miente root); sudo/doas NO.
ln -s "$(command -v id)" "$D/empty/id" 2>/dev/null || true

echo "== T1: sin sudo ni doas, as_root falla (rc!=0)"
out="$( ( unset -f sudo doas 2>/dev/null; PATH="$D/empty" as_root true anything ) 2>&1 )"; rc=$?
[[ $rc -ne 0 ]] && ok "T1 falla sin elevador" || no "T1 falla sin elevador"

echo "== T2: need_root sin elevador muere claro"
out="$( ( unset -f sudo doas 2>/dev/null; PATH="$D/empty" ARXY_ARGV=(shell) need_root ) 2>&1 )"; rc=$?
[[ $rc -ne 0 ]] && grep -q "necesita root" <<<"$out" && ok "T2 need_root claro" || no "T2 need_root claro"

echo "== C: sudo real preserva la interfaz =="
export ARXY_SYS_ROOT="/tmp/arxy-e2e-probe"

echo "== T1: arxy_env_pass emite la var"
_pass_out="$(arxy_env_pass)" # regla 5: capturar y grepear despues (pipe a grep -q daria SIGPIPE 141)
grep -qx 'ARXY_SYS_ROOT=/tmp/arxy-e2e-probe' <<<"$_pass_out" && ok "T1 emite" || no "T1 emite"

if ! command -v sudo >/dev/null 2>&1 || ! sudo -n true >/dev/null 2>&1; then
    echo "SKIP: T2/T3 sin sudo NOPASSWD (cubierto por stubs)"
else
    echo "== T2: sudo real deja pasar VAR= explicitos"
    mapfile -t _pass < <(arxy_env_pass)
    # capturar y grepear despues (regla 5); el pipe directo a
    # grep -q bajo pipefail daba SIGPIPE 141 intermitente (flake).
    if out="$(sudo -n "${_pass[@]}" -- env 2>/dev/null)" && grep -qx 'ARXY_SYS_ROOT=/tmp/arxy-e2e-probe' <<<"$out"; then ok "T2 viaja";
    else no "T2 viaja"; fi
    echo "== T3: as_root real propaga al hijo elevado"
    if out="$(as_root env 2>/dev/null)" && grep -qx 'ARXY_SYS_ROOT=/tmp/arxy-e2e-probe' <<<"$out"; then ok "T3 as_root";
    else no "T3 as_root"; fi
fi

finish
