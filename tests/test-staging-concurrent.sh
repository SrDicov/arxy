#!/usr/bin/env bash
# test-staging-concurrent.sh — dos staging validos: empate de mtime no debe
# publicar dos raices ni dejar restos; el inventario elige uno determinista. Sin root ni imagen: todo en /tmp.
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
ARXY_ROOT="/tmp/vconc/root"
export ARXY_ROOT
# shellcheck source=../lib/00-head.sh
. "$HERE/../lib/00-head.sh" >/dev/null 2>&1
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

mkroot() { # <$dir> [$mark]
    mkdir -p "$1/usr/bin" "$1/etc"
    : > "$1/usr/bin/bash"; : > "$1/usr/bin/pacman"
    chmod +x "$1/usr/bin/bash" "$1/usr/bin/pacman"
    echo "NAME=Arch Linux" > "$1/etc/arch-release"
    [[ -n "${2:-}" ]] && echo "$2" > "$1/.mark"
}
mkbadroot() { mkdir -p "$1/usr/bin"; : > "$1/usr/bin/bash"; chmod +x "$1/usr/bin/bash"; }
clean() { rm -rf "$R" "$R.old" "$R".new.* "$R".old.tmp.* "$R".swap.* "$D"/.image.partial.*; }

echo "== T1: empate de mtime -> uno reemplaza, el otro se borra (determinista)"
clean; mkbadroot "$R"
mkroot "$R.new.AAA" aaa; mkroot "$R.new.BBB" bbb
touch -d "2021-06-01 00:00:00" "$R.new.AAA" "$R.new.BBB"
a="$(staging_inventory)"; b="$(staging_inventory)"
[[ "$a" == "$b" ]] && ok "T1 determinista" || no "T1 determinista"
[[ "$(grep -c '^replace-root' <<<"$a")" == 1 && "$(grep -c '^remove' <<<"$a")" == 1 ]] && ok "T1 uno+uno" || no "T1 uno+uno ($a)"

echo "== T2: recover deja root valido sin restos"
recover_staging >/dev/null 2>&1
_image_ok "$R" && ls -d "$R".new.* >/dev/null 2>&1 && no "T2 restos" || { _image_ok "$R" && ok "T2 root valido sin restos" || no "T2 root valido"; }

echo "== T3: sin R, dos staging -> uno recupera, otro se borra"
clean
mkroot "$R.new.CCC" ccc; mkroot "$R.new.DDD" ddd
touch -d "2021-06-01 00:00:00" "$R.new.CCC" "$R.new.DDD"
a="$(staging_inventory)"
[[ "$(grep -c '^recover-root' <<<"$a")" == 1 && "$(grep -c '^remove' <<<"$a")" == 1 ]] && ok "T3 uno+uno" || no "T3 uno+uno ($a)"
recover_staging >/dev/null 2>&1
_image_ok "$R" && ! ls -d "$R".new.* >/dev/null 2>&1 && ok "T3 recupera sin restos" || no "T3 recupera sin restos"
clean

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
