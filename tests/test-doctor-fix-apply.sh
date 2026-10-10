#!/usr/bin/env bash
# test-doctor-fix-apply.sh — --apply con root en rootfs aislado.
# Un setup real en /tmp: hold-mesa se rompe a mano, --apply lo restaura;
# db.lck stale sobrevive sin --confirm; nvidia-align no instala.
# Requiere: root, red, ~1GB en /tmp. NUNCA toca /var/lib/arxy (guarda).
# La ruta del repo padre tiene espacios: el fixture se copia a /tmp.
#
#   sudo -n MATRIX_IMAGE=/ruta/al.tar.zst ./tests/test-doctor-fix-apply.sh
set -uo pipefail
FAIL=0
[[ "$(id -u)" -eq 0 ]] || { echo "FAIL: requiere root (sudo -n $0)"; exit 1; }
HERE="$(dirname "$0")"
BIN="$(readlink -f "$HERE/../src/arxy" 2>/dev/null || echo "$HERE/../src/arxy")"
export ARXY_ROOT="${ARXY_ROOT:-/tmp/fixapply/root}"
[[ "$ARXY_ROOT" == /var/lib/arxy/root ]] && { echo "FAIL: ARXY_ROOT real prohibido"; exit 1; }
R="$ARXY_ROOT"
D="${ARXY_ROOT%/*}"
SRC_IMG="${MATRIX_IMAGE:-/image.tar.zst}"

t() { # t <nombre> -- <cmd...>
    local name="$1"; shift; shift
    local out rc
    if out="$("$@" 2>&1)"; then echo "PASS: $name";
    else rc=$?; echo "FAIL($rc): $name"; printf '%s\n' "$out" | head -6 | sed 's/^/  /'; FAIL=$((FAIL+1)); fi
}

trap 'rm -rf "${D:?}"' EXIT
mkdir -p "$D" || { echo "FAIL: sin $D"; exit 1; }
[[ -f "$SRC_IMG" ]] || { echo "FAIL: no existe $SRC_IMG (pasa MATRIX_IMAGE=...)"; exit 1; }
cp -f "$SRC_IMG" "$D/image.tar.zst" || exit 1
[[ -f "$SRC_IMG.sha256" ]] && cp -f "$SRC_IMG.sha256" "$D/image.tar.zst.sha256"
export ARXY_IMAGE_URL="file://$D/image.tar.zst"

t "setup aislado" -- "$BIN" setup
t "setup deja root valido" -- test -x "$R/usr/bin/bash"
sed '/^IgnorePkg.*mesa/d' "$R/etc/pacman.conf" >"$D/pacman.conf.tmp" && cat "$D/pacman.conf.tmp" >"$R/etc/pacman.conf"; rm -f "$D/pacman.conf.tmp"
t "info ve todo hold-mesa" -- sh -c '"$0" doctor --fix 2>/dev/null | grep -q "\[todo\] hold-mesa"' "$BIN"
t "apply restaura hold" -- sh -c '"$0" doctor --fix --apply >/dev/null 2>&1 && grep -q "^IgnorePkg.*mesa" "$1/etc/pacman.conf"' "$BIN" "$R"
t "apply informa rc 0 + contenido" -- sh -c '"$0" doctor --fix 2>/dev/null | grep -q "fixes available:"' "$BIN"
touch "$R/var/lib/pacman/db.lck"
t "stale lock sobrevive sin --confirm" -- sh -c '"$0" doctor --fix --apply >/dev/null 2>&1; test -f "$1/var/lib/pacman/db.lck"' "$BIN" "$R"
rm -f "$R/var/lib/pacman/db.lck"
t "nvidia-align no instala" -- sh -c '! "$0" list 2>/dev/null | grep -q "^nvidia-utils "' "$BIN"

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
