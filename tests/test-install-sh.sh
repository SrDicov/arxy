#!/usr/bin/env bash
# test-install-sh.sh — matriz DESTDIR de install.sh (L5 estatico).
# Sin root: todo bajo DESTDIR en /tmp. La rama `.nuevo` (conf existente sin
# DESTDIR) exige escribir /etc de verdad: manual con root, documentado aqui.
# Requiere las deps del instalador; si falta alguna: SKIP honesto.
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh" # ok/no/finish
for dep in bash bwrap curl tar zstd xz gzip file sha256sum; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        echo "SKIP: test-install-sh.sh (sin $dep en este host)"
        echo "== resultado: TODO_OK (1 SKIP)"
        exit 0
    fi
done
D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT

echo "== --help y flag mala =="
out="$(bash "$ROOT/install.sh" --help)"; rc=$?
[[ "$rc" == 0 ]] && grep -q 'uso:' <<<"$out" && ok "--help rc 0 + uso" || no "--help" "rc=$rc [$out]"
out="$(bash "$ROOT/install.sh" --bogus 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && grep -q 'opcion desconocida' <<<"$out" && ok "flag mala muere claro" || no "flag mala" "rc=$rc [$out]"

echo "== sin src/ al lado =="
mkdir -p "$D/empty"
cp "$ROOT/install.sh" "$D/empty/install.sh"
out="$(bash "$D/empty/install.sh" 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && grep -q 'src/arxy' <<<"$out" && ok "sin src muere claro" || no "sin src" "rc=$rc [$out]"

echo "== sysconf no escribible =="
out="$(DESTDIR=/proc/arxy-noexiste-falso PREFIX=/usr bash "$ROOT/install.sh" 2>&1)"; rc=$?
[[ "$rc" != 0 ]] && grep -q 'sin escritura' <<<"$out" && ok "sin escritura muere claro" || no "sin escritura" "rc=$rc [$out]"

echo "== DESTDIR + --without-bridge =="
DESTDIR="$D/pkg" PREFIX=/usr bash "$ROOT/install.sh" --without-bridge >/dev/null 2>&1
[[ $? -eq 0 ]] && ok "DESTDIR install rc 0" || no "DESTDIR install rc"
for b in arxy arxy-run arxy-pkg arxy-query arxy-desktop arxy-setup arxy-maint arxy-doctor arxy-bridge arxy-help; do
    [[ -x "$D/pkg/usr/bin/$b" ]] && ok "bin $b" || no "bin $b"
done
[[ -L "$D/pkg/usr/bin/axy" && "$(readlink "$D/pkg/usr/bin/axy")" == arxy ]] \
    && ok "axy symlink a arxy" || no "axy symlink"
[[ ! -e "$D/pkg/usr/lib/arxy" ]] && ok "sin daemon con --without-bridge" || no "lib arxy ausente"
if cmp -s "$ROOT/config/arxy.conf" "$D/pkg/etc/arxy/arxy.conf"; then ok "conf instalada";
else no "conf instalada"; fi
if cmp -s "$ROOT/config/arxy.pub" "$D/pkg/etc/arxy/arxy.pub"; then ok "pubkey instalada";
else no "pubkey instalada"; fi

echo "== daemon: con binario lo instala, sin el pide make bridge =="
if [[ -f "$ROOT/bridge/arxy-bridged" ]]; then
    DESTDIR="$D/pkg2" PREFIX=/usr bash "$ROOT/install.sh" >/dev/null 2>&1
    [[ -x "$D/pkg2/usr/lib/arxy/arxy-bridged" ]] && ok "daemon instalado" || no "daemon instalado"
else
    out="$(DESTDIR="$D/pkg2" PREFIX=/usr bash "$ROOT/install.sh" 2>&1)"; rc=$?
    [[ "$rc" != 0 ]] && grep -q 'make bridge' <<<"$out" && ok "sin daemon pide make bridge" || no "sin daemon" "rc=$rc [$out]"
fi

echo "== .nuevo: manual con root (rama sin DESTDIR + /etc/arxy/arxy.conf) =="
echo "SKIP: .nuevo exige /etc real (checklist manual)"

finish
