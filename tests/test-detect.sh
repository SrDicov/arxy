#!/usr/bin/env bash
# test-detect.sh — unitarias de detect_libc/nvidia_ver/kmods/dev_nodes.
# Sourcea lib/ (solo definiciones + config de solo-lectura): sin root,
# sin imagen. Funciones exportadas (-f) para los subshells; mocks via
# ARXY_SYS_ROOT/ARXY_DEV_PATH/ARXY_LIB_DIR (patrón ARXY_SYS_DRM_PATH).
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
# shellcheck source=../lib/00-head.sh
. "$HERE/../lib/00-head.sh" >/dev/null 2>&1
# shellcheck source=../lib/10-level.sh
. "$HERE/../lib/10-level.sh" >/dev/null 2>&1
# shellcheck source=../lib/60-detect.sh
. "$HERE/../lib/60-detect.sh" >/dev/null 2>&1
# shellcheck source=../lib/61-doctor.sh
. "$HERE/../lib/61-doctor.sh" >/dev/null 2>&1
# shellcheck source=../lib/62-json.sh
. "$HERE/../lib/62-json.sh" >/dev/null 2>&1
export -f detect_libc detect_nvidia_ver detect_kmods detect_dev_nodes
D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT

t() { # t <nombre> <esperado> -- <bash -c ...> : contenido + rc 0 (M10: sin || true global)
    local name="$1" want="$2"; shift 2; shift
    local got rc
    got="$("$@")" 2>/dev/null; rc=$?
    if [[ $rc -eq 0 && "$got" == "$want" ]]; then echo "PASS: $name";
    else echo "FAIL: $name (quiero '$want' rc 0, tengo '$got' rc $rc)"; FAIL=$((FAIL+1)); fi
}
te() { # te <nombre> <rc> -- <bash -c ...> : vacio + rc exacto (ausencia legitima vs crash)
    local name="$1" wantrc="$2"; shift 2; shift
    local got rc
    got="$("$@")" 2>/dev/null; rc=$?
    if [[ $rc -eq "$wantrc" && -z "$got" ]]; then echo "PASS: $name";
    else echo "FAIL: $name (quiero vacio rc $wantrc, tengo '$got' rc $rc)"; FAIL=$((FAIL+1)); fi
}

# --- libc: el host dice la verdad; los mocks fuerzan cada rama
t "libc host válida" "ok" -- bash -c 'case "$(detect_libc)" in glibc|musl|unknown) echo ok;; *) echo MAL;; esac'
mkdir -p "$D/musllib" "$D/musllib64" && touch "$D/musllib/ld-musl-x86_64.so.1"
t "libc mock musl" "musl" -- bash -c 'ARXY_LIB_DIR="'"$D"'/musllib" ARXY_LIB64_DIR="'"$D"'/musllib64" detect_libc'
mkdir -p "$D/empty"
t "libc mock unknown" "unknown" -- bash -c 'PATH=/nonexistent ARXY_LIB_DIR="'"$D"'/empty" ARXY_LIB64_DIR="'"$D"'/empty" detect_libc'
# faltaba la rama glibc-pura (la suite mentia en verde en musl).
mkdir -p "$D/glibclib" "$D/glibclib64" && touch "$D/glibclib64/ld-linux-x86-64.so.2"
t "libc mock glibc pura" "glibc" -- bash -c 'ARXY_LIB_DIR="'"$D"'/glibclib" ARXY_LIB64_DIR="'"$D"'/glibclib64" detect_libc'
# Ambos loaders: arbitra ldd (el primario). En glibc+musl-pkg -> glibc;
# sin ldd no hay primario visible -> unknown (sin prioridad falsa).
mkdir -p "$D/duallib" "$D/duallib64"
touch "$D/duallib/ld-musl-x86_64.so.1" "$D/duallib64/ld-linux-x86-64.so.2"
_host_ldd="$(ldd --version 2>&1 | head -n 1 || true)"
case "$_host_ldd" in *musl*) _want_dual=musl ;; *GLIBC*|*"GNU libc"*) _want_dual=glibc ;; *) _want_dual=unknown ;; esac
t "libc dual arbitra ldd ($_want_dual)" "$_want_dual" -- bash -c 'ARXY_LIB_DIR="'"$D"'/duallib" ARXY_LIB64_DIR="'"$D"'/duallib64" detect_libc'
t "libc dual sin ldd unknown" "unknown" -- bash -c 'PATH=/nonexistent ARXY_LIB_DIR="'"$D"'/duallib" ARXY_LIB64_DIR="'"$D"'/duallib64" detect_libc'

# --- nvidia: /proc y /sys, formato real del driver
mkdir -p "$D/nv1/proc/driver/nvidia" "$D/nv2/sys/module/nvidia"
printf 'NVRM version: NVIDIA UNIX x86_64 Kernel Module  550.54.14  ...\n' > "$D/nv1/proc/driver/nvidia/version"
printf '550.54.14\n' > "$D/nv2/sys/module/nvidia/version"
t "nvidia desde proc" "550.54.14" -- bash -c 'ARXY_SYS_ROOT="'"$D"'/nv1" detect_nvidia_ver'
t "nvidia desde sys" "550.54.14" -- bash -c 'ARXY_SYS_ROOT="'"$D"'/nv2" detect_nvidia_ver'
te "nvidia ausente vacía" 1 -- bash -c 'ARXY_SYS_ROOT="'"$D"'/empty" detect_nvidia_ver'
mkdir -p "$D/nv3/proc/driver/nvidia" "$D/nv3/sys/module/nvidia"
: > "$D/nv3/proc/driver/nvidia/version"
printf '560.35.03\n' > "$D/nv3/sys/module/nvidia/version"
t "nvidia proc vacío cae a sys" "560.35.03" -- bash -c 'ARXY_SYS_ROOT="'"$D"'/nv3" detect_nvidia_ver'
mkdir -p "$D/nv4/proc/driver/nvidia" "$D/nv4/sys/module/nvidia"
printf '550.54.14\n' > "$D/nv4/proc/driver/nvidia/version"
printf '560.35.03\n' > "$D/nv4/sys/module/nvidia/version"
t "nvidia proc manda sobre sys" "550.54.14" -- bash -c 'ARXY_SYS_ROOT="'"$D"'/nv4" detect_nvidia_ver'
r="$(ARXY_SYS_ROOT="$D/empty" detect_nvidia_ver 2>/dev/null; echo "rc=$?")"
if [[ "$r" == "rc=1" ]]; then echo "PASS: nvidia ausente rc=1";
else echo "FAIL: nvidia ausente rc=1 (tengo '$r')"; FAIL=$((FAIL+1)); fi

# --- kmods y dev nodes
mkdir -p "$D/k1/sys/module/fuse" "$D/k1/proc/sys/vm" "$D/k1dev"
touch "$D/k1/proc/sys/vm/unprivileged_userfaultfd"
t "kmods fuse+userfaultfd" "fuse userfaultfd" -- bash -c 'ARXY_SYS_ROOT="'"$D"'/k1" ARXY_DEV_PATH="'"$D"'/k1dev" detect_kmods'
te "kmods vacío" 0 -- bash -c 'ARXY_SYS_ROOT="'"$D"'/empty" ARXY_DEV_PATH="'"$D"'/empty" detect_kmods'
mkdir -p "$D/dev/dri"
touch "$D/dev/dri/card0" "$D/dev/dri/renderD128" "$D/dev/nvidia0" "$D/dev/fuse"
t "dev nodes" "$D/dev/dri/card0
$D/dev/dri/renderD128
$D/dev/nvidia0
$D/dev/fuse" -- bash -c 'ARXY_DEV_PATH="'"$D"'/dev" detect_dev_nodes'
te "dev vacío" 0 -- bash -c 'ARXY_DEV_PATH="'"$D"'/empty" detect_dev_nodes'

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
