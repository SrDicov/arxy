#!/usr/bin/env bash
# test-config-data.sh — los .conf son datos: precedencia y valores literales,
# sin ejecutar shell ni aceptar claves fuera de la interfaz documentada.
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT

ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

mkdir -p "$D/xdg/arxy"
cat > "$D/xdg/arxy/config" <<EOF
ARXY_ROOT = "/tmp/arxy config/root"
ARXY_BRIDGE_ALLOWLIST='echo xdg-open'
ARXY_UNKNOWN=ignored
touch "$D/executed"
EOF

out="$(HOME="$D" XDG_CONFIG_HOME="$D/xdg" bash -c '
    set --
    . "$0" 2>/dev/null
    printf "ROOT=%s\nALLOW=%s\nUNKNOWN=%s\n" \
        "$ARXY_ROOT" "$ARXY_BRIDGE_ALLOWLIST" "${ARXY_UNKNOWN-unset}"
' "$HERE/../lib/00-head.sh")"

grep -qx 'ROOT=/tmp/arxy config/root' <<<"$out" && ok "T1 conserva espacios" || no "T1 conserva espacios"
grep -qx 'ALLOW=echo xdg-open' <<<"$out" && ok "T2 conserva lista literal" || no "T2 conserva lista literal"
grep -qx 'UNKNOWN=unset' <<<"$out" && ok "T3 ignora clave desconocida" || no "T3 ignora clave desconocida"
[[ ! -e "$D/executed" ]] && ok "T4 no ejecuta comandos" || no "T4 ejecuto el conf"

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
