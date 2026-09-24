#!/usr/bin/env bash
# test-arxy-gaming.sh — rewrite arxy-gaming: vendor, pin NVIDIA,
# dry-run puro, multilib, particion oficial/AUR. Sin root ni red: todo con
# stubs y fixtures en /tmp (pacman/cmd_gpu_stack/export stubbed).
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
# shellcheck source=../lib/00-head.sh
. "$HERE/../lib/00-head.sh" >/dev/null 2>&1
# shellcheck source=../lib/35-gpu.sh
. "$HERE/../lib/35-gpu.sh" >/dev/null 2>&1
# shellcheck source=../lib/60-detect.sh
. "$HERE/../lib/60-detect.sh" >/dev/null 2>&1
# shellcheck source=../lib/61-doctor.sh
. "$HERE/../lib/61-doctor.sh" >/dev/null 2>&1
# shellcheck source=../lib/62-json.sh
. "$HERE/../lib/62-json.sh" >/dev/null 2>&1
# shellcheck source=../lib/30-package.sh
. "$HERE/../lib/30-package.sh" >/dev/null 2>&1
# shellcheck source=../lib/31-aur.sh
. "$HERE/../lib/31-aur.sh" >/dev/null 2>&1
# shellcheck source=../lib/32-maintenance.sh
. "$HERE/../lib/32-maintenance.sh" >/dev/null 2>&1
# shellcheck source=../lib/10-level.sh
. "$HERE/../lib/10-level.sh" >/dev/null 2>&1 # level() para T15 ()

D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT
export ARXY_ROOT="$D/root" ARXY_BUILD="$D/build"
mkdir -p "$ARXY_ROOT/etc"
printf '[options]\n#[multilib]\n#Include = /etc/pacman.d/mirrorlist\n' > "$ARXY_ROOT/etc/pacman.conf"

# Stubs: ningun efecto real; registran llamadas.
need_root() { return 0; }
ensure_image() { return 0; }
pacman_mut() { printf 'PACMAN_MUT %s\n' "$*"; return 0; }
cmd_install_aur() { printf 'AUR %s\n' "$*"; return 0; }
cmd_gpu_stack() { printf 'GPUSTACK %s\n' "$*"; return 0; }
cmd_export() { return 0; }
update_desktop_db() { return 0; }
do_dedup() { return 0; }

# Fixtures de GPU.
mkdir -p "$D/empty" "$D/dri/dri" "$D/musllib" "$D/musllib64"
touch "$D/musllib/ld-musl-x86_64.so.1"
mkdir -p "$D/drmA/card0/device" "$D/drmN/card0/device"
printf '0x1002' > "$D/drmA/card0/device/vendor"
printf '0x10de' > "$D/drmN/card0/device/vendor"
mkdir -p "$D/nv/proc/driver/nvidia"
printf 'NVRM version: NVIDIA UNIX x86_64 Kernel Module  550.54.14\n' > "$D/nv/proc/driver/nvidia/version"
touch "$D/dri/dri/card0"

ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo "== T0: sin GPU decidible falla claro"
out="$(ARXY_SYS_DRM_PATH="$D/empty" ARXY_DEV_PATH="$D/empty" cmd_install arxy-gaming 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "GPU no detectada" <<<"$out" && ok "T0 rc+mensaje" || no "T0 rc+mensaje (rc=$rc)"
# No sugerir --aur ni una sintaxis que el parser no acepte.
! grep -q -- "--aur arxy-gaming" <<<"$out" && grep -q "arxy-gaming-intel|arxy-gaming-amd|arxy-gaming-nvidia" <<<"$out" && ok "T0b sintaxis valida de vendor" || no "T0b vendor ($out)"

echo "== T1/T2: dry-run por vendor"
out="$(ARXY_SYS_DRM_PATH="$D/drmA" ARXY_DEV_PATH="$D/empty" cmd_install arxy-gaming --dry-run 2>&1)"
grep -q "arxy-gaming-amd" <<<"$out" && grep -q "vulkan-radeon" <<<"$out" && ok "T1 amd" || no "T1 amd"
out="$(ARXY_SYS_DRM_PATH="$D/empty" ARXY_DEV_PATH="$D/dri" cmd_install arxy-gaming --dry-run 2>&1)"
grep -q "arxy-gaming-intel" <<<"$out" && grep -q "vulkan-intel" <<<"$out" && ok "T2 intel por dri" || no "T2 intel por dri"

echo "== T3: nvidia con pin alineado"
out="$(ARXY_SYS_DRM_PATH="$D/drmN" ARXY_SYS_ROOT="$D/nv" ARXY_DEV_PATH="$D/empty" cmd_install arxy-gaming --dry-run 2>&1)"
grep -q "nvidia-utils=550.54.14" <<<"$out" && grep -q "lib32-nvidia-utils=550.54.14" <<<"$out" && ok "T3 pin" || no "T3 pin"

echo "== T4: nouveau (PCI nvidia sin modulo) falla explicando"
out="$(ARXY_SYS_DRM_PATH="$D/drmN" ARXY_SYS_ROOT="$D/empty" ARXY_DEV_PATH="$D/empty" cmd_install arxy-gaming --dry-run 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "propietario" <<<"$out" && ok "T4 nouveau" || no "T4 nouveau (rc=$rc)"

echo "== T5: otros paquetes no se reescriben"
out="$(cmd_install foo 2>&1)"
grep -q "PACMAN_MUT.*foo" <<<"$out" && ! grep -q "gaming" <<<"$out" && ok "T5 passthrough" || no "T5 passthrough"

echo "== T6: dry-run puro (cero side effects)"
out="$(ARXY_SYS_DRM_PATH="$D/drmA" ARXY_DEV_PATH="$D/empty" cmd_install arxy-gaming --dry-run 2>&1)"
! grep -qE "PACMAN_MUT|^AUR |GPUSTACK" <<<"$out" && grep -q "nada tocado (dry-run)" <<<"$out" && ok "T6 puro" || no "T6 puro"
grep -q "^\[multilib\]" "$ARXY_ROOT/etc/pacman.conf" && no "T6 multilib intacto" || ok "T6 multilib intacto"

echo "== T8: no-dry-run habilita multilib y parte oficial/AUR (flujo L1)"
out="$(ARXY_LEVEL=1 ARXY_SYS_DRM_PATH="$D/drmA" ARXY_DEV_PATH="$D/empty" cmd_install arxy-gaming 2>&1)"
grep -q "^\[multilib\]" "$ARXY_ROOT/etc/pacman.conf" && ok "T8 multilib" || no "T8 multilib"
grep -q "PACMAN_MUT.*lib32-vulkan-radeon" <<<"$out" && ok "T8 oficial" || no "T8 oficial"
grep -q "^AUR .*proton-ge-custom-bin" <<<"$out" && ok "T8 aur" || no "T8 aur"

echo "== T7: conflicto mesa-mini avisado (al final: redefine is_mesa_mini)"
is_mesa_mini() { return 0; }
out="$(ARXY_SYS_DRM_PATH="$D/drmA" ARXY_DEV_PATH="$D/empty" cmd_install arxy-gaming --dry-run 2>&1)"
grep -q "mesa-mini seria reemplazado" <<<"$out" && ok "T7 conflicto" || no "T7 conflicto"

echo "== T9: orden AUR-antes-de-elevar (makepkg prohibe root; flujo L1)"
out="$(ARXY_LEVEL=1 ARXY_SYS_DRM_PATH="$D/drmA" ARXY_DEV_PATH="$D/empty" cmd_install arxy-gaming 2>&1)"
aline="$(grep -n "^AUR " <<<"$out" | head -1 | cut -d: -f1)"
pline="$(grep -n "PACMAN_MUT" <<<"$out" | head -1 | cut -d: -f1)"
[[ -n "$aline" && -n "$pline" && "$aline" -lt "$pline" ]] && ok "T9 AUR antes que oficial" || no "T9 AUR antes que oficial"

echo "== T10: musl dry-run lista igual + avisa devices"
out="$(ARXY_LIB_DIR="$D/musllib" ARXY_LIB64_DIR="$D/musllib64" ARXY_SYS_DRM_PATH="$D/drmA" ARXY_DEV_PATH="$D/empty" cmd_install arxy-gaming --dry-run 2>&1)"
grep -q "vulkan-radeon" <<<"$out" && grep -q "solo devices del host" <<<"$out" && ok "T10 musl" || no "T10 musl"

echo "== T11: check_pkg_name acepta charset Arch, rechaza / .. vacio (A3)"
check_pkg_name "steam" 2>/dev/null && check_pkg_name "proton-ge-custom-bin" 2>/dev/null && ok "T11 validos" || no "T11 validos"
bad=0
for p in "../x" "/etc" "" "a b" 'a;b' 'a$(x)' "-flag" "--"; do (check_pkg_name "$p" >/dev/null 2>&1) && bad=$((bad+1)); done
[[ $bad -eq 0 ]] && ok "T11 invalidos mueren" || no "T11 invalidos mueren ($bad pasaron)"

echo "== T12: rm -rf destructivos llevan :? (tripwire A3)"
grep -q 'rm -rf "${R:?}"' "$HERE/../lib/20-state.sh" && grep -q 'rm -rf "${R:?}.old"' "$HERE/../lib/20-state.sh" && grep -q 'rm -rf "${stage:?}"' "$HERE/../lib/21-setup.sh" && grep -q 'rm -rf "${work_host:?}"' "$HERE/../lib/31-aur.sh" && ok "T12 :? presente" || no "T12 :? presente"

echo "== T12b: ningun rm -rf sobre var pelada en lib/ ()"
# Todo rm -rf exige :? o :- o guarda [[ -n ... ]] en la misma linea.
# Excepciones justificadas: 62-json.sh (rama mkdir-fallo: mktemp pudo
# fallar y hay que retornar 0) y el trap de do_dedup con -n explicito.
bad12b="$(grep -hE 'rm -rf "\$[A-Za-z_]' "$HERE"/../lib/20-state.sh "$HERE"/../lib/21-setup.sh "$HERE"/../lib/22-gc.sh "$HERE"/../lib/31-aur.sh "$HERE"/../lib/32-maintenance.sh "$HERE"/../lib/62-json.sh | grep -v ':?\|:-\|\[\[ -n' || true)"
[[ -z "$bad12b" ]] && ok "T12b rm -rf con guarda" || no "T12b sin guarda: $bad12b"

echo "== T13: barridos prefieren /usr/bin sobre /usr/local ( shadow)"
# Un binario viejo en /usr/local hacia shadow al empaquetado y resucitaba
# bugs (EPERM pre-Commit-18); el orden /usr/bin primero lo impide.
ord13=1
for _f13 in "$HERE/../lib/50-run.sh" "$HERE/../lib/41-desktop.sh"; do
    _l13="$(grep -h 'for cand in' "$_f13")"
    case "$_l13" in *'/usr/bin/'*'/usr/local/bin/'*) : ;; *) ord13=0; echo "  orden roto en $_f13";; esac
done
[[ $ord13 -eq 1 ]] && ok "T13 orden /usr/bin primero" || no "T13 orden"

echo "== T14: install/remove validan nombres antes de root/red"
out="$(cmd_install "" 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "nombre de paquete invalido" <<<"$out" && ! grep -q "PACMAN_MUT" <<<"$out" && ok "T14 install vacio muere pre-red" || no "T14 install vacio ($rc: $out)"
out="$(cmd_install "my app" 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "nombre de paquete invalido" <<<"$out" && ok "T14 install con espacio muere claro" || no "T14 install espacio ($rc: $out)"
out="$(cmd_remove "" 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "nombre de paquete invalido" <<<"$out" && ok "T14 remove vacio muere claro" || no "T14 remove vacio ($rc: $out)"

echo "== T15: gaming en L2 muere antes de aplicar ()"
# Sin esto la parte oficial aplicaba y la AUR abortaba (medio-estado).
# _ARXY_LEVEL es memoizado por proceso: reset para que ARXY_LEVEL mande.
unset _ARXY_LEVEL
out="$(ARXY_LEVEL=2 ARXY_SYS_DRM_PATH="$D/drmA" ARXY_DEV_PATH="$D/empty" cmd_install arxy-gaming 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "nivel 1" <<<"$out" && ! grep -qE "PACMAN_MUT|^AUR |GPUSTACK" <<<"$out" && ok "T15 L2 muere limpio pre-apply" || no "T15 L2 ($rc: $out)"

echo "== T16: variantes gaming conflictivas fallan antes de aplicar"
out="$(cmd_install arxy-gaming-amd arxy-gaming-intel --dry-run 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "una sola variante" <<<"$out" && ! grep -qE "PACMAN_MUT|^AUR |GPUSTACK" <<<"$out" && ok "T16 conflicto claro" || no "T16 conflicto ($rc: $out)"

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
