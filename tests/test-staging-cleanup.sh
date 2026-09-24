#!/usr/bin/env bash
# test-staging-cleanup.sh — fix staging-cleanup: detecta huerfanos
# de setup/rollback (root.new.*, .image.partial.*, root.old.tmp.*, .swap.*)
# con la MISMA staging_inventory que aplica recover_staging, y --apply los
# resuelve. Probe sin root ni imagen; el --apply via doctor exige root (SKIP
# sin el); el apply directo (recover_staging) corre como usuario en /tmp.
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
ARXY_ROOT="/tmp/vclean/root"
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
clean() { rm -rf "$R" "$R.old" "$R".new.* "$R".old.tmp.* "$R".swap.* "$D"/.image.partial.*; }
declare -A FIX=()

echo "== T0: limpio -> skip (applicable false)"
clean
fix_probe staging-cleanup FIX
[[ "${FIX[status]}" == skip && "${FIX[reason]}" == "sin staging huerfano" ]] && ok "T0 probe skip" || no "T0 probe skip"
fixes_json 2>/dev/null | grep -q '"id": "staging-cleanup", "applicable": false' && ok "T0 json applicable false" || no "T0 json applicable false"
fixes_json 2>/dev/null | grep -q '"id": "staging-cleanup"[^}]*"phase": null' && ok "T0 json phase null" || no "T0 json phase null"

echo "== T1: root.new con root valido -> borrar"
clean; mkroot "$R" bueno; mkdir -p "$R.new.111"
fix_probe staging-cleanup FIX
[[ "${FIX[status]}" == todo && "${FIX[action]}" == *"borrar root.new.111"* ]] && ok "T1 probe todo+would_do" || no "T1 probe todo+would_do"
recover_staging >/dev/null 2>&1
[[ ! -e "$R.new.111" ]] && [[ "$(cat "$R/.mark")" == bueno ]] && ok "T1 apply borra, root intacto" || no "T1 apply borra, root intacto"

echo "== T2: root.new valido sin root -> recuperar"
clean; mkroot "$R.new.222" nuevo
fix_probe staging-cleanup FIX
[[ "${FIX[action]}" == *"recuperar root.new.222 a root"* ]] && ok "T2 probe recover" || no "T2 probe recover"
recover_staging >/dev/null 2>&1
[[ "$(cat "$R/.mark" 2>/dev/null)" == nuevo ]] && [[ ! -e "$R.new.222" ]] && ok "T2 apply recupera" || no "T2 apply recupera"

echo "== T3: old.tmp con root valido -> rotar a .old"
clean; mkroot "$R" bueno; mkroot "$R.old.tmp.333" previo
fix_probe staging-cleanup FIX
[[ "${FIX[action]}" == *"rotar root.old.tmp.333 a root.old"* ]] && ok "T3 probe rotate" || no "T3 probe rotate"
recover_staging >/dev/null 2>&1
[[ "$(cat "$R.old/.mark" 2>/dev/null)" == previo ]] && [[ ! -e "$R.old.tmp.333" ]] && ok "T3 apply rota" || no "T3 apply rota"

echo "== T4: old.tmp sin root -> recuperar"
clean; mkroot "$R.old.tmp.444" previo
recover_staging >/dev/null 2>&1
[[ "$(cat "$R/.mark" 2>/dev/null)" == previo ]] && [[ ! -e "$R.old.tmp.444" ]] && ok "T4 apply recupera" || no "T4 apply recupera"

echo "== T5: dos old.tmp sin root -> el mas reciente gana por mtime"
clean
mkroot "$R.old.tmp.555" viejo; touch -d "2020-01-01" "$R.old.tmp.555"
mkroot "$R.old.tmp.666" reciente; touch -d "2021-01-01" "$R.old.tmp.666"
recover_staging >/dev/null 2>&1
[[ "$(cat "$R/.mark" 2>/dev/null)" == reciente ]] && ok "T5 root es el reciente" || no "T5 root es el reciente"
[[ "$(cat "$R.old/.mark" 2>/dev/null)" == viejo ]] && ok "T5 viejo rota a .old" || no "T5 viejo rota a .old"
ls -d "$R".old.tmp.* >/dev/null 2>&1 && no "T5 sin restos" || ok "T5 sin restos"

echo "== T6: partial -> borrar"
clean; mkroot "$R" bueno; touch "$D/.image.partial.777"
fix_probe staging-cleanup FIX
[[ "${FIX[action]}" == *"borrar .image.partial.777"* ]] && ok "T6 probe remove" || no "T6 probe remove"
recover_staging >/dev/null 2>&1
[[ ! -e "$D/.image.partial.777" ]] && ok "T6 apply borra" || no "T6 apply borra"

echo "== T7: swap varado"
clean; mkroot "$R" bueno; mkroot "$R.swap.888" swapado
fix_probe staging-cleanup FIX
[[ "${FIX[action]}" == *"borrar root.swap.888"* ]] && ok "T7 probe remove con root valido" || no "T7 probe remove con root valido"
recover_staging >/dev/null 2>&1
[[ ! -e "$R.swap.888" ]] && ok "T7 apply borra" || no "T7 apply borra"
clean; mkroot "$R.swap.999" swapado
recover_staging >/dev/null 2>&1
[[ "$(cat "$R/.mark" 2>/dev/null)" == swapado ]] && [[ ! -e "$R.swap.999" ]] && ok "T7 sin root restaura" || no "T7 sin root restaura"

echo "== T8: doctor --fix --apply aplica staging-cleanup (root)"
clean; mkroot "$R" bueno; touch "$D/.image.partial.000"
if [[ "$(id -u)" -ne 0 ]]; then
    echo "SKIP: T8 (doctor --apply exige root)"
else
    out="$(doctor_fix --fix --apply 2>&1)"
    grep -q "\[hecho\] staging-cleanup aplicado" <<<"$out" && ok "T8 hecho" || no "T8 hecho"
    [[ ! -e "$D/.image.partial.000" ]] && ok "T8 parcial purgado" || no "T8 parcial purgado"
fi
clean

echo "== T9: rm falla -> aviso a stderr, rc 0 (A1)"
clean; mkroot "$R" bueno; mkdir -p "$R.new.111"
rm() { return 1; }
out="$(recover_staging 2>&1)"; rc=$?
unset -f rm
[[ $rc -eq 0 ]] && grep -q "aviso: no pude recuperar $R.new.111" <<<"$out" && ok "T9 aviso + rc 0" || no "T9 aviso + rc 0"
[[ -e "$R.new.111" ]] && ok "T9 huerfano sigue (no se mintio borrado)" || no "T9 huerfano sigue (no se mintio borrado)"

echo "== T10: mv falla -> aviso a stderr, rc 0 (A1)"
clean; mkroot "$R.new.222" nuevo
mv() { return 1; }
out="$(recover_staging 2>&1)"; rc=$?
unset -f mv
[[ $rc -eq 0 ]] && grep -q "aviso: no pude recuperar $R.new.222" <<<"$out" && ok "T10 aviso + rc 0" || no "T10 aviso + rc 0"
clean

echo "== T11: hold-mesa sin [options] falla honesto, no [hecho] falso ()"
clean; mkroot "$R" bueno
printf '# sin estanza options\n' > "$R/etc/pacman.conf"
id() { echo 0; }
need_root() { return 0; }
is_mesa_mini() { return 0; }
cmd_install() { echo "STUB-INSTALL $*"; return 0; }
out="$(doctor_fix --fix --apply 2>&1)"
grep -q "\[fallo\] hold-mesa" <<<"$out" && ok "T11 sin options falla honesto" || no "T11 sin options ($out)"
printf '[options]\n' > "$R/etc/pacman.conf"
out="$(doctor_fix --fix --apply 2>&1)"
unset -f id need_root is_mesa_mini cmd_install
grep -q "\[hecho\] hold-mesa aplicado" <<<"$out" && grep -q '^IgnorePkg.*mesa' "$R/etc/pacman.conf" && ok "T11 control aplica" || no "T11 control ($out)"
clean

echo "== T12: ciclo de vida no toca paths del bridge ()"
# Contrato: setup/rollback/gc viven bajo ARXY_ROOT/ARXY_DATA; el daemon
# (socket/pid/token) vive fuera. Si alguien referencia el bridge desde
# el ciclo de vida, este pin cae (en codigo, no en comentario).
if grep -n "arxy-bridge\|BRIDGE_SOCKET\|bridge_sock_path\|bridge_pid_path\|bridge_token_path\|bridge_session" "$HERE"/../lib/20-state.sh "$HERE"/../lib/21-setup.sh "$HERE"/../lib/22-gc.sh | grep -qv '^[^:]*:[0-9]*:#'; then
    no "T12 lifecycle sin refs bridge"
else
    ok "T12 lifecycle sin refs bridge"
fi
# Conductual: socket falso dentro de DATA sobrevive a recover_staging.
if command -v python3 >/dev/null 2>&1; then
    clean; mkroot "$R" bueno; mkdir -p "$R.new.111"; touch "$D/.image.partial.777"
    if python3 -c "import socket; s=socket.socket(socket.AF_UNIX); s.bind('$D/br.sock')" 2>/dev/null; then
        recover_staging >/dev/null 2>&1
        [[ -S "$D/br.sock" ]] && ok "T12 socket sobrevive a recover" || no "T12 socket borrado por recover"
    else
        echo "SKIP: T12 conductual (AF_UNIX no permitido en este entorno)"
    fi
    rm -f "$D/br.sock"
else
    echo "SKIP: T12 conductual (sin python3)"
fi
clean

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
