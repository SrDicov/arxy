#!/usr/bin/env bash
# test-install-remove-update.sh — red unitaria para cmd_install/cmd_remove/
# cmd_update/cmd_install_aur (mutaciones del rootfs
# sin test directo; solo stubs). Sin root ni red: pacman/export/migrate
# stubbed, rootfs y XDG aislados en /tmp.
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"

D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT
export ARXY_ROOT="$D/root" XDG_DATA_HOME="$D/xdg"
mkdir -p "$ARXY_ROOT/etc" "$XDG_DATA_HOME/applications"
printf '[options]\n' > "$ARXY_ROOT/etc/pacman.conf"

# shellcheck source=../lib/00-head.sh
. "$HERE/../lib/00-head.sh" >/dev/null 2>&1
# shellcheck source=../lib/10-level.sh
. "$HERE/../lib/10-level.sh" >/dev/null 2>&1
# shellcheck source=../lib/30-package.sh
. "$HERE/../lib/30-package.sh" >/dev/null 2>&1
# shellcheck source=../lib/31-aur.sh
. "$HERE/../lib/31-aur.sh" >/dev/null 2>&1
# shellcheck source=../lib/32-maintenance.sh
. "$HERE/../lib/32-maintenance.sh" >/dev/null 2>&1

# Real antes de stubear (T7/T9 restauran en su subshell).
_REAL_AUR="$(declare -f cmd_install_aur)"
_REAL_GPUSTACK="$(declare -f cmd_gpu_stack)"
# Stubs: ningun efecto real; registran llamadas.
need_root() { return 0; }
ensure_image() { return 0; }
pacman_mut() { printf 'PACMAN_MUT %s\n' "$*"; return 0; }
cmd_install_aur() { printf 'AUR %s\n' "$*"; return 0; }
cmd_gpu_stack() { printf 'GPUSTACK %s\n' "$*"; return 0; }
cmd_export() { printf 'EXPORT %s\n' "$*"; return 0; }
desktop_migrate_auto() { printf 'MIGRATE\n'; return 0; }
update_desktop_db() { return 0; }
do_dedup() { return 0; }

ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo "== T1: install oficial llama pacman + export + migrate"
out="$(cmd_install foo 2>&1)"
grep -q "PACMAN_MUT.*-S.*foo" <<<"$out" && grep -q "^EXPORT foo$" <<<"$out" && grep -q "^MIGRATE$" <<<"$out" && grep -q "instalado: foo" <<<"$out" && ok "T1 install oficial" || no "T1 install oficial ($out)"

echo "== T2: nombre virtual GPU va a gpu_stack, no a pacman"
out="$(cmd_install gpu-amd bar 2>&1)"
grep -q "^GPUSTACK gpu-amd$" <<<"$out" && grep -q "PACMAN_MUT.*bar" <<<"$out" && ! grep -q "gpu-amd" <<<"$(grep PACMAN_MUT <<<"$out")" && ok "T2 virtual GPU" || no "T2 virtual GPU ($out)"

echo "== T3: install --aur delega sin elevar"
out="$(cmd_install --aur algo-bin 2>&1)"
grep -q "^AUR algo-bin$" <<<"$out" && ! grep -q "PACMAN_MUT" <<<"$out" && ok "T3 delega AUR" || no "T3 delega AUR ($out)"

echo "== T4: remove borra solo lanzadores del paquete"
printf '[Desktop Entry]\nName=Foo\nX-Arxy-Pkg=foo\n' > "$XDG_DATA_HOME/applications/arxy-foo.desktop"
printf '[Desktop Entry]\nName=Bar\nX-Arxy-Pkg=bar\n' > "$XDG_DATA_HOME/applications/arxy-bar.desktop"
out="$(cmd_remove foo 2>&1)"
grep -q "PACMAN_MUT.*-Rns.*foo" <<<"$out" && [[ ! -e "$XDG_DATA_HOME/applications/arxy-foo.desktop" ]] && [[ -f "$XDG_DATA_HOME/applications/arxy-bar.desktop" ]] && grep -q "lanzador borrado: arxy-foo.desktop" <<<"$out" && ok "T4 remove" || no "T4 remove ($out)"

echo "== T5: remove sin args muere con uso"
out="$(cmd_remove 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "uso:" <<<"$out" && ok "T5 uso" || no "T5 uso (rc=$rc)"

echo "== T6: update hace -Syu + migrate, rc 0"
out="$(cmd_update 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -q "PACMAN_MUT.*-Syu" <<<"$out" && grep -q "^MIGRATE$" <<<"$out" && ok "T6 update" || no "T6 update (rc=$rc $out)"

echo "== T7: AUR en nivel 2 muere explicando (sin compilar)"
out="$( eval "$_REAL_AUR"; _ARXY_LEVEL=2; cmd_install --aur algo-bin 2>&1 )"; rc=$?
[[ $rc -ne 0 ]] && grep -q "nivel 1" <<<"$out" && ok "T7 L2" || no "T7 L2 (rc=$rc $out)"

echo "== T8: install sin args muere con uso"
out="$(cmd_install 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "uso:" <<<"$out" && ok "T8 uso" || no "T8 uso (rc=$rc)"

echo "== T9: gpu-stack sin pacman.conf avisa, no silencia ()"
out="$( eval "$_REAL_GPUSTACK"; ARXY_ROOT="$D/sinroot" cmd_gpu_stack gpu-amd 2>&1 )"; rc=$?
[[ $rc -eq 0 ]] && grep -q "omito gpu-stack" <<<"$out" && ok "T9 aviso" || no "T9 aviso (rc=$rc $out)"

echo "== T10: export fallido avisa y no tumba el install ()"
out="$( cmd_export() { return 1; }; cmd_install foo 2>&1 )"; rc=$?
[[ $rc -eq 0 ]] && grep -q "no pude exportar foo" <<<"$out" && grep -q "PACMAN_MUT.*foo" <<<"$out" && ok "T10 aviso+sigue" || no "T10 aviso+sigue (rc=$rc $out)"

echo "== T11: check_pkg_name rechaza guion inicial ()"
bad=0
for p in "-flag" "--" "--root=/x"; do (check_pkg_name "$p" >/dev/null 2>&1) && bad=$((bad+1)); done
[[ $bad -eq 0 ]] && ok "T11 guion inicial" || no "T11 guion inicial ($bad pasaron)"
check_pkg_name "steam" >/dev/null 2>&1 && check_pkg_name "a+b.c_d@e" >/dev/null 2>&1 && ok "T11 validos siguen" || no "T11 validos siguen"

echo "== T12: install con opcion muere antes de pacman ()"
out="$(cmd_install --root=/evil 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "opcion no soportada" <<<"$out" && ! grep -q "PACMAN_MUT" <<<"$out" && ok "T12 inyeccion" || no "T12 inyeccion (rc=$rc $out)"

echo "== T13: --dry-run sin gaming muere claro ()"
out="$(cmd_install --dry-run foo 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "solo vale con arxy-gaming" <<<"$out" && ! grep -q "PACMAN_MUT" <<<"$out" && ok "T13 dry-run" || no "T13 dry-run (rc=$rc $out)"

echo "== T14: remove con opcion muere antes de pacman ()"
out="$(cmd_remove --config=/evil 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "opcion no soportada" <<<"$out" && ! grep -q "PACMAN_MUT" <<<"$out" && ok "T14 remove" || no "T14 remove (rc=$rc $out)"

echo "== T15: AUR con flag intermedio muere, no lo salta ()"
out="$( eval "$_REAL_AUR"; ensure_aur_env() { return 0; }; _ARXY_LEVEL=1; cmd_install_aur foo -bar 2>&1 )"; rc=$?
[[ $rc -ne 0 ]] && grep -q "opcion no soportada en AUR" <<<"$out" && ok "T15 AUR flag" || no "T15 AUR flag (rc=$rc $out)"

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
