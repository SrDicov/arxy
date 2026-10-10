#!/usr/bin/env bash
# test-bundle.sh — el split multi-binario: cada src/arxy-* parsea (bash -n),
# se sourcea sin dispatchar y expone sus cmd_* de entrada; el shim despacha
# cada rama a su bundle con validacion de args (sin tocar estado: los casos
# mueren en 'uso:' antes de privilegios/imagen/red).
set -uo pipefail
FAIL=0
cd "$(dirname "$0")/.." || exit 1

export ARXY_ROOT="/tmp/arxy-bundle-test"
export HOME="/tmp/arxy-bundle-test-home"
mkdir -p "$ARXY_ROOT" "$HOME"

check() { # <bundle> <entries...>: bash -n + sourceable + expone entradas
    local b="$1"; shift
    [[ -f "src/$b" ]] || { echo "FAIL: falta src/$b"; FAIL=$((FAIL+1)); return 0; }
    if bash -n "src/$b" 2>/dev/null; then echo "PASS: bash -n $b";
    else echo "FAIL: bash -n $b"; FAIL=$((FAIL+1)); fi
    local miss
    miss="$(ENTRY="$*" bash -c 'ARXY_ROOT=/tmp/arxy-bundle-test HOME=/tmp/arxy-bundle-test-home; . ./src/'"$b"' >/dev/null 2>&1; for f in $ENTRY; do declare -F "$f" >/dev/null 2>&1 || echo "MISSING:$f"; done' 2>&1 || true)"
    if [[ -z "$miss" ]]; then echo "PASS: $b expone [$*]";
    else echo "FAIL: $b $miss"; FAIL=$((FAIL+1)); fi
}

check arxy-run cmd_run cmd_which cmd_shell
check arxy-pkg cmd_install cmd_remove cmd_update cmd_install_file cmd_install_aur cmd_gaming cmd_gpu_stack
check arxy-query cmd_info cmd_list cmd_search cmd_search_aur
check arxy-desktop cmd_export cmd_unexport cmd_desktop cmd_desktop_migrate
check arxy-setup cmd_setup cmd_rollback
check arxy-maint cmd_clean cmd_gc cmd_dedup
check arxy-doctor cmd_doctor cmd_quickstart cmd_version cmd_doctor_json
check arxy-bridge cmd_host_bridge
check arxy-help cmd_help

echo "== despacho shim -> bundle (casos que mueren en uso:, sin estado) =="
smoke() { # <nombre> <quiero> -- <args shim...>
    local name="$1" want="$2"; shift 2; shift
    local out rc
    out="$(ARXY_ROOT=/tmp/arxy-bundle-test HOME=/tmp/arxy-bundle-test-home ./src/arxy "$@" 2>&1)"; rc=$?
    if (( rc != 0 )) && grep -q "$want" <<<"$out" && ! grep -q "command not found" <<<"$out"; then
        echo "PASS: $name"
    else
        echo "FAIL: $name (rc=$rc, sin [$want])"; printf '%s\n' "$out" | head -3 | sed 's/^/  /'; FAIL=$((FAIL+1))
    fi
}

smoke "run sin args" "uso: arxy run" -- run
smoke "remove sin args" "uso: arxy remove" -- remove
smoke "search sin args" "uso: arxy search" -- search
smoke "desktop sin args" "uso: arxy desktop" -- desktop
smoke "setup con args" "uso: arxy setup" -- setup extra
smoke "gc con flag mala" "uso: arxy gc" -- gc --badflag
smoke "doctor con flag mala" "uso: arxy doctor" -- doctor --badflag
smoke "bridge con flag mala" "uso: arxy host-bridge" -- host-bridge --badflag
smoke "alias i -> pkg" "uso: arxy install" -- i
# help imprime y sale 0 (unico caso de exito aqui). Sin pipe directo:
# con pipefail, si grep -q cierra el pipe antes, el CLI muere con SIGPIPE.
_help_out="$(ARXY_ROOT=/tmp/arxy-bundle-test HOME=/tmp/arxy-bundle-test-home ./src/arxy help 2>&1)"
if grep -q "Uso: arxy" <<<"$_help_out"; then
    echo "PASS: help"
else echo "FAIL: help"; FAIL=$((FAIL+1)); fi
# flag desconocida y rama desconocida (-> run). Sin pipe a grep -q bajo
# pipefail (SIGPIPE 141 / rc del productor): capturar y grepear despues.
_out="$(./src/arxy --badflag 2>&1 || true)"
if grep -q "flag desconocida" <<<"$_out"; then echo "PASS: flag desconocida";
else echo "FAIL: flag desconocida"; FAIL=$((FAIL+1)); fi

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
