#!/usr/bin/env bash
# test-clean.sh — cmd_clean dry-run/--apply sobre fixtures (L3).
# Sin root ni imagen: need_root stubbed (como test-gc.sh), root falso con
# version (ensure_image regenera sin root en /tmp). Solo borra
# regenerables: jamas toca pacman.conf ni el rootfs.
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
# shellcheck source=lib.sh
. "$HERE/lib.sh" # ok/no/finish + arxy_mkroot_ver
D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT
R="$D/root"
export ARXY_ROOT="$R"
# shellcheck source=../lib/00-head.sh
. "$HERE/../lib/00-head.sh" >/dev/null 2>&1
# shellcheck source=../lib/20-state.sh
. "$HERE/../lib/20-state.sh" >/dev/null 2>&1
# shellcheck source=../lib/21-setup.sh
. "$HERE/../lib/21-setup.sh" >/dev/null 2>&1
# shellcheck source=../lib/31-aur.sh
. "$HERE/../lib/31-aur.sh" >/dev/null 2>&1
# shellcheck source=../lib/32-maintenance.sh
. "$HERE/../lib/32-maintenance.sh" >/dev/null 2>&1
need_root() { return 0; } # apply aislado: todo en /tmp
arxy_mkroot_ver "$R" "file:///t.tar.zst" "abc"
printf '[options]\nArchitecture = auto\n[core]\nInclude = /etc/pacman.d/mirrorlist\n' > "$R/etc/pacman.conf"
mkdata() {
    mkdir -p "$R/var/cache/pacman/pkg" "$ARXY_BUILD/aur" "$R.old/usr/bin" "$R.old/etc"
    echo pkg > "$R/var/cache/pacman/pkg/f1.pkg"
    echo build > "$ARXY_BUILD/aur/b1"
    echo parcial > "$ARXY_DATA/.image.partial.1"
    : > "$R.old/usr/bin/bash"; : > "$R.old/usr/bin/pacman"
    chmod +x "$R.old/usr/bin/bash" "$R.old/usr/bin/pacman"
    echo "NAME=Arch Linux" > "$R.old/etc/arch-release"
}

echo "== args: clean solo acepta nada o --apply =="
out="$(cmd_clean --foo 2>&1)"; rc=$?
if grep -q 'uso:' <<<"$out" && [[ "$rc" != 0 ]]; then ok "uso con flag mala";
else no "uso con flag mala" "rc=$rc [$out]"; fi
out="$(cmd_clean --apply extra 2>&1)"; rc=$?
if grep -q 'uso:' <<<"$out" && [[ "$rc" != 0 ]]; then ok "uso con 2 args";
else no "uso con 2 args" "rc=$rc [$out]"; fi

echo "== dry-run informa y no toca =="
mkdata
out="$(cmd_clean)"
for k in "rootfs:" "cache pacman:" "builds AUR:" "descargas huerfanas:" "rollback:" "nada tocado"; do
    grep -qF "$k" <<<"$out" && ok "dry-run dice $k" || no "dry-run dice $k" "$out"
done
[[ -f "$R/var/cache/pacman/pkg/f1.pkg" && -f "$ARXY_BUILD/aur/b1" && -d "$R.old" ]] \
    && ok "dry-run no borra" || no "dry-run no borra"

echo "== --apply purga regenerables y conserva rootfs+conf =="
out="$(cmd_clean --apply)"
grep -q 'limpieza hecha' <<<"$out" && ok "apply informa" || no "apply informa" "$out"
[[ ! -e "$R/var/cache/pacman/pkg/f1.pkg" && ! -e "$ARXY_BUILD/aur/b1" && ! -e "$ARXY_DATA/.image.partial.1" && ! -e "$R.old" ]] \
    && ok "apply purga" || no "apply purga"
[[ -x "$R/usr/bin/pacman" && -f "$R/etc/pacman.conf" ]] \
    && ok "rootfs+conf intactos" || no "rootfs+conf intactos"
grep -q '^\[core\]$' "$R/etc/pacman.conf" && ok "conf sin tocar" || no "conf sin tocar"

finish
