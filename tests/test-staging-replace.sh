#!/usr/bin/env bash
# test-staging-replace.sh — rama replace-root:
# R existente pero invalido (_image_ok falso) + staging valido. Sin esta
# red, un root corrupto con staging bueno podria no reemplazarse. Sin root
# ni imagen: todo en /tmp.
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
ARXY_ROOT="/tmp/vreplace/root"
export ARXY_ROOT
# shellcheck source=../lib/00-head.sh
. "$HERE/../lib/00-head.sh" >/dev/null 2>&1
# shellcheck source=../lib/60-detect.sh
. "$HERE/../lib/60-detect.sh" >/dev/null 2>&1
# shellcheck source=../lib/61-doctor.sh
. "$HERE/../lib/61-doctor.sh" >/dev/null 2>&1
# shellcheck source=../lib/62-json.sh
. "$HERE/../lib/62-json.sh" >/dev/null 2>&1
# shellcheck source=../lib/20-state.sh
. "$HERE/../lib/20-state.sh" >/dev/null 2>&1
# shellcheck source=../lib/21-setup.sh
. "$HERE/../lib/21-setup.sh" >/dev/null 2>&1
# shellcheck source=../lib/22-gc.sh
. "$HERE/../lib/22-gc.sh" >/dev/null 2>&1
D="$ARXY_DATA"
R="$ARXY_ROOT"
rm -rf "$D"; mkdir -p "$D"
trap 'rm -rf "$D"' EXIT

ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

mkroot() { # <$dir> [$mark] : rootfs valido para _image_ok
    mkdir -p "$1/usr/bin" "$1/etc"
    : > "$1/usr/bin/bash"; : > "$1/usr/bin/pacman"
    chmod +x "$1/usr/bin/bash" "$1/usr/bin/pacman"
    echo "NAME=Arch Linux" > "$1/etc/arch-release"
    [[ -n "${2:-}" ]] && echo "$2" > "$1/.mark"
}
mkbadroot() { # <$dir> : existe pero invalido (sin arch-release)
    mkdir -p "$1/usr/bin"
    : > "$1/usr/bin/bash"; chmod +x "$1/usr/bin/bash"
}
clean() { rm -rf "$R" "$R.old" "$R".new.* "$R".old.tmp.* "$R".swap.* "$D"/.image.partial.*; }
declare -A FIX=()

echo "== T1: inventory clasifica replace-root (R invalido + staging valido)"
clean; mkbadroot "$R"; mkroot "$R.new.111" bueno
out="$(staging_inventory)"
grep -q "^replace-root.*root.new.111" <<<"$out" && ok "T1 replace-root" || no "T1 replace-root ($out)"

echo "== T2: fix_probe pide reemplazar"
clean; mkbadroot "$R"; mkroot "$R.new.222" bueno
fix_probe staging-cleanup FIX
[[ "${FIX[status]}" == todo && "${FIX[action]}" == *"reemplazar root con root.new.222"* ]] && ok "T2 probe" || no "T2 probe"

echo "== T3: recover_staging deja .mark del staging, sin restos"
clean; mkbadroot "$R"; mkroot "$R.new.333" bueno
recover_staging >/dev/null 2>&1
[[ "$(cat "$R/.mark" 2>/dev/null)" == bueno ]] && [[ ! -e "$R.new.333" ]] && ok "T3 reemplaza" || no "T3 reemplaza"
_image_ok "$R" && ok "T3 root valido" || no "T3 root valido"

echo "== T4: dos staging validos -> el mas reciente reemplaza, el otro se borra"
clean; mkbadroot "$R"
mkroot "$R.new.444" viejo; touch -d "2020-01-01" "$R.new.444"
mkroot "$R.new.555" reciente; touch -d "2021-01-01" "$R.new.555"
out="$(staging_inventory)"
grep -q "^replace-root.*root.new.555" <<<"$out" && grep -q "^remove.*root.new.444" <<<"$out" && ok "T4 inventory" || no "T4 inventory ($out)"
recover_staging >/dev/null 2>&1
[[ "$(cat "$R/.mark" 2>/dev/null)" == reciente ]] && [[ ! -e "$R.new.444" ]] && [[ ! -e "$R.new.555" ]] && ok "T4 apply" || no "T4 apply"
clean

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
