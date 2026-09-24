#!/usr/bin/env bash
# test-setup-enospc.sh — disco lleno durante setup: el fallo real mas probable (~1GB).
# tar/zstd stubbed con ENOSPC: cmd_setup debe morir limpio, el root viejo seguir
# intacto y operativo, y no quedar huerfanos. Sin root ni red: todo en /tmp.
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"

D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT
export ARXY_ROOT="$D/root"
export ARXY_IMAGE_URL="http://ejemplo.invalid/arxy.tar.zst"
export ARXY_IMAGE_SHA256="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
export ARXY_SIGNATURE_POLICY="off"

# shellcheck source=../lib/00-head.sh
. "$HERE/../lib/00-head.sh" >/dev/null 2>&1
# shellcheck source=../lib/20-state.sh
. "$HERE/../lib/20-state.sh" >/dev/null 2>&1
# shellcheck source=../lib/21-setup.sh
. "$HERE/../lib/21-setup.sh" >/dev/null 2>&1
# shellcheck source=../lib/22-gc.sh
. "$HERE/../lib/22-gc.sh" >/dev/null 2>&1

# Root viejo valido y operativo.
mkdir -p "$ARXY_ROOT/usr/bin" "$ARXY_ROOT/etc" "$ARXY_ROOT/var/lib/arxy"
: > "$ARXY_ROOT/usr/bin/bash"; : > "$ARXY_ROOT/usr/bin/pacman"
chmod +x "$ARXY_ROOT/usr/bin/bash" "$ARXY_ROOT/usr/bin/pacman"
echo "NAME=Arch Linux" > "$ARXY_ROOT/etc/arch-release"
echo "viejo" > "$ARXY_ROOT/.mark"

# Stubs: descarga OK, hash OK, extraccion sin espacio.
need_root() { return 0; }
curl() { local o=""; while [[ $# -gt 0 ]]; do [[ "$1" == "-o" ]] && { o="$2"; shift 2; continue; }; shift; done; [[ -n "$o" ]] && : > "$o"; return 0; }
sha256sum() { printf '%s  -\n' "$ARXY_IMAGE_SHA256"; }
tar() { echo "tar: No space left on device" >&2; return 1; }
zstd() { echo "zstd: No space left on device" >&2; return 1; }

ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo "== T1: setup con ENOSPC muere con mensaje claro"
out="$(cmd_setup 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "no pude extraer la imagen" <<<"$out" && ok "T1 muere limpio" || no "T1 muere limpio (rc=$rc $out)"

echo "== T2: root viejo intacto tras el fallo"
_image_ok "$ARXY_ROOT" && [[ "$(cat "$ARXY_ROOT/.mark")" == viejo ]] && ok "T2 root intacto" || no "T2 root intacto"

echo "== T3: sin huerfanos (el die limpio tras de si)"
out="$(staging_inventory)"
[[ -z "$out" ]] && ok "T3 sin huerfanos" || no "T3 sin huerfanos ($out)"

echo "== T4: el sistema sigue operativo con lo viejo"
out="$(ensure_image 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && [[ "$(cat "$ARXY_ROOT/.mark")" == viejo ]] && ok "T4 operativo" || no "T4 operativo (rc=$rc $out)"

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
