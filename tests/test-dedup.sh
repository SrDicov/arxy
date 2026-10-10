#!/usr/bin/env bash
# test-dedup.sh — do_dedup sobre /usr falso (L3).
# Sin root ni imagen: do_dedup directo (cmd_dedup exige root; el mecanismo
# es el mismo). Inodos comparados con `test -ef` (portable, sin stat).
# SKIP honesto sin cmp/cksum/sha256sum (do_dedup los necesita).
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
# shellcheck source=lib.sh
. "$HERE/lib.sh" # ok/no/finish
for dep in cmp cksum sha256sum; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        echo "SKIP: test-dedup.sh (sin $dep en este host)"
        echo "== resultado: TODO_OK (1 SKIP)"
        exit 0
    fi
done
D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT
R="$D/root"
export ARXY_ROOT="$R"
# shellcheck source=../lib/00-head.sh
. "$HERE/../lib/00-head.sh" >/dev/null 2>&1
# shellcheck source=../lib/32-maintenance.sh
. "$HERE/../lib/32-maintenance.sh" >/dev/null 2>&1
mkdir -p "$R/usr/bin" "$R/opt" "$ARXY_DATA"

echo "== replicas en /usr -> mismo inodo; resto intacto =="
head -c 100000 /dev/zero > "$R/usr/bin/a1"
head -c 100000 /dev/zero > "$R/usr/bin/a2"
head -c 100000 /dev/zero > "$R/opt/b1"
head -c 100000 /dev/zero > "$R/opt/b2"
head -c 100000 /dev/zero > "$R/usr/bin/c1"; printf x >> "$R/usr/bin/c1"
head -c 100000 /dev/zero > "$R/usr/bin/c2"
ln -s a1 "$R/usr/bin/s1"
do_dedup >/dev/null 2>&1
[[ $? -eq 0 ]] && ok "do_dedup rc 0" || no "do_dedup rc"
if test "$R/usr/bin/a1" -ef "$R/usr/bin/a2"; then ok "replicas linkeadas"; else no "replicas linkeadas"; fi
if test "$R/opt/b1" -ef "$R/opt/b2"; then no "fuera de /usr tocado"; else ok "fuera de /usr intacto"; fi
if [[ -L "$R/usr/bin/s1" ]]; then ok "symlink intacto"; else no "symlink intacto"; fi
if test "$R/usr/bin/c1" -ef "$R/usr/bin/c2"; then no "distintos linkeados"; else ok "distintos intactos"; fi
if cmp -s "$R/usr/bin/a1" "$R/usr/bin/a2"; then ok "contenido igual tras link"; else no "contenido igual"; fi
do_dedup >/dev/null 2>&1
if test "$R/usr/bin/a1" -ef "$R/usr/bin/a2"; then ok "idempotente"; else no "idempotente"; fi

echo "== auto: callado bajo 10MB, informa sobre el umbral =="
rm -rf "$R/usr" "$R/opt"; mkdir -p "$R/usr/bin"
head -c 1000000 /dev/zero > "$R/usr/bin/m1"
head -c 1000000 /dev/zero > "$R/usr/bin/m2"
out="$(do_dedup auto 2>&1)"
[[ -z "$out" ]] && ok "auto callado bajo umbral" || no "auto callado" "$out"
rm -f "$R/usr/bin/m1" "$R/usr/bin/m2"
# 3 x 6M sparse: se ahorran 2 copias (12MB >= umbral 10MB). Rapido: sparse.
truncate -s 6M "$R/usr/bin/g1"; truncate -s 6M "$R/usr/bin/g2"; truncate -s 6M "$R/usr/bin/g3"
out="$(do_dedup auto 2>&1)"
grep -q 'ahorrados' <<<"$out" && ok "auto informa sobre umbral" || no "auto informa" "$out"
if test "$R/usr/bin/g1" -ef "$R/usr/bin/g2" && test "$R/usr/bin/g2" -ef "$R/usr/bin/g3"; then ok "sparse linkeadas"; else no "sparse linkeadas"; fi

finish
