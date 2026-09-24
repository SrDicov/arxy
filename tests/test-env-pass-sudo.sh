#!/usr/bin/env bash
# test-env-pass-sudo.sh — sudo real preserva la interfaz ARXY_* permitida:
# los stubs prueban el argv construido, no que el sudo real (env_reset,
# secure_path) lo deje pasar. Con sudo NOPASSWD: VAR= explicitos viajan;
# sin el: SKIP honesto (lo cubren los stubs de test-env-pass.sh).
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
# shellcheck source=../lib/00-head.sh
. "$HERE/../lib/00-head.sh" >/dev/null 2>&1

ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

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

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
