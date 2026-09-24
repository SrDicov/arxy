#!/usr/bin/env bash
# test-desktop-shims.sh — sin shims en el rootfs por diseño:
# las apps llegan al host vía ARXY_BRIDGE_SOCKET/TOKEN + allowlist del
# daemon (e2e T0/T16/T19); xdg-open cubre gio. Sin root ni imagen: grep
# al repo (contrato, no comportamiento).
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
REPO="$HERE/.."
# shellcheck source=lib.sh
. "$HERE/lib.sh" # ok/no/finish

# M11: anclaje estructural (no textual): la allowlist funcional es la
# que emite bridge_default_allowlist (la que alimenta al daemon).
# shellcheck source=../lib/00-head.sh
. "$HERE/../lib/00-head.sh" >/dev/null 2>&1
# shellcheck source=../lib/80-bridge.sh
. "$HERE/../lib/80-bridge.sh" >/dev/null 2>&1
_allow="$(bridge_default_allowlist)"
grep -qx 'xdg-open' <<<"$_allow" && ok "allowlist funcional trae xdg-open" || no "allowlist funcional trae xdg-open" "$_allow"
grep -qx 'notify-send' <<<"$_allow" && ok "allowlist funcional trae notify-send" || no "allowlist funcional trae notify-send" "$_allow"

grep -q 'xdg-open' "$REPO/lib/80-bridge.sh" && ok "allowlist trae xdg-open" || no "allowlist trae xdg-open"
grep -q 'notify-send' "$REPO/lib/80-bridge.sh" && ok "allowlist trae notify-send" || no "allowlist trae notify-send"
[[ "$(grep -l 'xdg-open' "$REPO"/lib/*.sh)" == "$REPO/lib/80-bridge.sh" ]] \
    && ok "xdg-open solo en allowlist (sin shim)" || no "xdg-open solo en allowlist" "$(grep -l 'xdg-open' "$REPO"/lib/*.sh | tr '\n' ' ')"
[[ "$(grep -l 'notify-send' "$REPO"/lib/*.sh)" == "$REPO/lib/80-bridge.sh" ]] \
    && ok "notify-send solo en allowlist (sin shim)" || no "notify-send solo en allowlist" "$(grep -l 'notify-send' "$REPO"/lib/*.sh | tr '\n' ' ')"
if grep -rEqw 'gio' "$REPO/lib" "$REPO/bridge" 2>/dev/null; then
    no "gio ausente (xdg-open lo cubre)" "$(grep -rEow 'gio' "$REPO/lib" "$REPO/bridge" 2>/dev/null | head -n 2 | tr '\n' ' ')"
else
    ok "gio ausente (xdg-open lo cubre)"
fi
grep -q 'ARXY_BRIDGE_SOCKET' "$REPO/lib/10-level.sh" && ok "run_in expone SOCKET" || no "run_in expone SOCKET"
grep -q 'ARXY_BRIDGE_TOKEN' "$REPO/lib/10-level.sh" && ok "run_in expone TOKEN" || no "run_in expone TOKEN"
# aviso con sesion viva (pid con cmdline arxy-bridged via exec -a).
if command -v python3 >/dev/null 2>&1; then
    _bn="$(mktemp -d)"
    python3 -c "import socket; s=socket.socket(socket.AF_UNIX); s.bind('$_bn/arxy-bridge.sock')" 2>/dev/null
    ( exec -a arxy-bridged sleep 30 ) & _fpid=$!
    printf '%s' "$_fpid" > "$_bn/arxy-bridge.pid"
    _nout="$(XDG_RUNTIME_DIR="$_bn" bash -c '. "$0" >/dev/null 2>&1; . "$1" >/dev/null 2>&1; bridge_session_notice 2>&1' "$REPO/lib/00-head.sh" "$REPO/lib/80-bridge.sh" 2>&1)"
    grep -q "bridge activo" <<<"$_nout" && ok "session_notice avisa con daemon vivo" || no "session_notice avisa" "$_nout"
    kill "$_fpid" 2>/dev/null; wait "$_fpid" 2>/dev/null || true
    _nout="$(XDG_RUNTIME_DIR="$_bn" bash -c '. "$0" >/dev/null 2>&1; . "$1" >/dev/null 2>&1; bridge_session_notice 2>&1; echo "rc=$?"' "$REPO/lib/00-head.sh" "$REPO/lib/80-bridge.sh" 2>&1)"
    ! grep -q "bridge activo" <<<"$_nout" && grep -q "rc=0" <<<"$_nout" && ok "session_notice calla sin daemon" || no "session_notice calla" "$_nout"
    rm -rf "$_bn"
else
    echo "SKIP: session_notice conductual (sin python3)"
fi
grep -q 'bridge_env_l2' "$REPO/lib/50-run.sh" && ok "L2 (run/shell) inyecta bridge" || no "L2 inyecta bridge"
# Comportamiento con socket falso (python bindea y sale: el path queda
# como socket huerfano; sin pidfile se confia, igual que foreground).
if command -v python3 >/dev/null 2>&1; then
    _bd="$(mktemp -d)"; trap 'rm -rf "$_bd"' EXIT
    python3 -c "import socket; s=socket.socket(socket.AF_UNIX); s.bind('$_bd/arxy-bridge.sock')" 2>/dev/null
    printf 'tok-falso' > "$_bd/arxy-bridge.token"
    _env="$(XDG_RUNTIME_DIR="$_bd" ARXY_BRIDGE_BIN=/nonexistent bash -c '. "$0" >/dev/null 2>&1; . "$1" >/dev/null 2>&1; unset ARXY_BRIDGE_SOCKET ARXY_BRIDGE_TOKEN; bridge_env_l2; printf "SOCK=%s TOKEN=%s" "${ARXY_BRIDGE_SOCKET:-unset}" "${ARXY_BRIDGE_TOKEN:-unset}"' "$REPO/lib/00-head.sh" "$REPO/lib/80-bridge.sh" 2>&1)"
    [[ "$_env" == "SOCK=$_bd/arxy-bridge.sock TOKEN=tok-falso" ]] && ok "bridge_env_l2 exporta con socket vivo" || no "bridge_env_l2 exporta" "$_env"
    _env="$(XDG_RUNTIME_DIR="$_bd" ARXY_NO_BRIDGE=1 ARXY_BRIDGE_BIN=/nonexistent ARXY_BRIDGE_SOCKET=inyectado ARXY_BRIDGE_TOKEN=inyectado bash -c '. "$0" >/dev/null 2>&1; . "$1" >/dev/null 2>&1; bridge_env_l2; printf "SOCK=%s TOKEN=%s" "${ARXY_BRIDGE_SOCKET:-unset}" "${ARXY_BRIDGE_TOKEN:-unset}"' "$REPO/lib/00-head.sh" "$REPO/lib/80-bridge.sh" 2>&1)"
    [[ "$_env" == "SOCK=unset TOKEN=unset" ]] && ok "bridge_env_l2 limpia env sin bridge" || no "bridge_env_l2 NO_BRIDGE" "$_env"
    rm -rf "$_bd"; trap - EXIT
else
    echo "SKIP: bridge_env_l2 conductual (sin python3)"
fi
for _t in T0 T16 T19; do
    # M11: en linea de codigo, no en comentario (mencion en comentario no es cobertura).
    if grep -n "\"$_t" "$REPO/tests/test-bridge-in-container.sh" | grep -qv '^[0-9]*:#'; then ok "e2e cubre $_t";
    else no "e2e cubre $_t"; fi
done

echo "== negativo: el detector de shims caza (no es tautologico) =="
_nd="$(mktemp -d)"
mkdir -p "$_nd/fakelib"
printf '#!/bin/sh\ngio open "$1"\n' > "$_nd/fakelib/99-fake.sh"

echo "== T1: fixture con gio matchea (el detector lo cazaria)"
if grep -rEqw 'gio' "$_nd/fakelib" 2>/dev/null; then ok "T1 caza gio";
else no "T1 caza gio"; fi

echo "== T2: repo real no matchea (ancla el positivo)"
if grep -rEqw 'gio' "$REPO/lib" "$REPO/bridge" 2>/dev/null; then no "T2 repo limpio";
else ok "T2 repo limpio"; fi
rm -rf "$_nd"

finish
