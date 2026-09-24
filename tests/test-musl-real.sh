#!/usr/bin/env bash
# test-musl-real.sh — musl-glibc-stack en host musl real (Alpine/Chimera).
# Sin host musl: SKIP honesto (la matriz NVIDIA/musl vive con mocks en
# test-gpu-drm.sh y test-doctor-fix.sh). Nunca instala nada: solo informa.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh" # ARXY_BIN default: repo (no el instalado viejo)
# Sonda honesta: la misma funcion que usa produccion (dual-loader arbitra
# ldd; la mera presencia de ld-musl no hace musl al host).
HERE="$(dirname "$0")"
# shellcheck source=../lib/00-head.sh
. "$HERE/../lib/00-head.sh" >/dev/null 2>&1
# shellcheck source=../lib/60-detect.sh
. "$HERE/../lib/60-detect.sh" >/dev/null 2>&1
# shellcheck source=../lib/61-doctor.sh
. "$HERE/../lib/61-doctor.sh" >/dev/null 2>&1
# shellcheck source=../lib/62-json.sh
. "$HERE/../lib/62-json.sh" >/dev/null 2>&1
if [[ "$(detect_libc 2>/dev/null)" != musl ]]; then
    echo "SKIP: host $(detect_libc 2>/dev/null) (musl-glibc-stack solo aplica en musl)"
    exit 0
fi
FAIL=0
if "$ARXY_BIN" doctor --fix --json 2>/dev/null | grep -q '"id": "musl-glibc-stack", "applicable": true'; then
    echo "PASS: musl-glibc-stack aplicable en musl real"
else
    echo "FAIL: musl-glibc-stack no aplicable en musl real"; FAIL=1
fi
echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
