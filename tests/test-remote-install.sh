#!/usr/bin/env bash
# test-remote-install.sh — install-remote.sh sin tocar nada (L0).
# --help/--flag-mala + matriz de deteccion con binarios falsos en PATH
# (el e2e real con setup+update se probo a mano en Chimera: ver
# PLAN-TESTING §11; es demasiado pesado para la suite).
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
ROOT="$(cd "$HERE/.." && pwd)"
INST="$ROOT/install-remote.sh"
SH_BIN="$(command -v sh)"

echo "== ayuda y flags =="
out="$("$SH_BIN" "$INST" --help)"; rc=$?
[[ "$rc" == 0 ]] && grep -q 'curl -fsSL' <<<"$out" && echo "PASS: --help" || { echo "FAIL: --help"; FAIL=$((FAIL+1)); }
out="$("$SH_BIN" "$INST" --bogus 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && grep -q 'opcion desconocida' <<<"$out" && echo "PASS: flag mala" || { echo "FAIL: flag mala"; FAIL=$((FAIL+1)); }

echo "== --check no cambia nada y detecta =="
out="$("$SH_BIN" "$INST" --check)"; rc=$?
[[ "$rc" == 0 ]] && grep -q '^arxy-remote-install: gestor: ' <<<"$out" && echo "PASS: --check" || { echo "FAIL: --check"; FAIL=$((FAIL+1)); }

echo "== matriz de gestor por binario presente =="
D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT
mkpm() { printf '#!/bin/sh\nexit 0\n' > "$D/$1"; chmod +x "$D/$1"; }
# PATH solo con stubs (los reales no interfieren; --check no necesita mas).
chk_pm() { # <gestor> <bins...> : stubs en PATH y --check
    local want="$1"; shift
    rm -f "$D"/* 2>/dev/null || true
    local b
    for b in "$@"; do mkpm "$b"; done
    out="$(PATH="$D" "$SH_BIN" "$INST" --check 2>&1)"
    if grep -q "^arxy-remote-install: gestor: $want\$" <<<"$out"; then echo "PASS: pm $want";
    else echo "FAIL: pm $want (tengo [$out])"; FAIL=$((FAIL+1)); fi
}
chk_pm apk apk
chk_pm xbps xbps-install
chk_pm emerge emerge
chk_pm pacman pacman
chk_pm dnf dnf
chk_pm dnf yum
chk_pm apt apt-get
chk_pm zypper zypper

echo "== arquitectura no-x86_64 muere claro =="
rm -f "$D"/* 2>/dev/null || true
printf '#!/bin/sh\necho aarch64\n' > "$D/uname"; chmod +x "$D/uname"
mkpm apk
out="$(PATH="$D" "$SH_BIN" "$INST" 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && grep -q "sin rootfs" <<<"$out" && echo "PASS: aarch64" || { echo "FAIL: aarch64 (rc=$rc [$out])"; FAIL=$((FAIL+1)); }

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
