#!/usr/bin/env bash
# test-gc.sh — cmd_gc: --json format 1 + --apply con prompt tty.
# root.old VALIDO exige tty (o --yes); CORRUPTO se purga sin preguntar.
# staging via recover_staging. Sin root ni imagen: need_root stubbed, todo
# en /tmp; sin tty via </dev/null (determinista).
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
ARXY_ROOT="/tmp/vgc/root"
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
need_root() { return 0; } # apply aislado: dirs en /tmp
D="$ARXY_DATA"
R="$ARXY_ROOT"
rm -rf "$D"; mkdir -p "$D"
trap 'rm -rf "$D"' EXIT

ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

mkroot() { # <$dir> [$mark] : rootfs valido para _image_ok
    mkdir -p "$1/usr/bin" "$1/etc" "$1/var/cache/pacman/pkg"
    : > "$1/usr/bin/bash"; : > "$1/usr/bin/pacman"
    chmod +x "$1/usr/bin/bash" "$1/usr/bin/pacman"
    echo "NAME=Arch Linux" > "$1/etc/arch-release"
    [[ -n "${2:-}" ]] && echo "$2" > "$1/.mark"
}
clean() { rm -rf "$R" "$R.old" "$D/build" "$R".new.* "$D"/.image.partial.*; }

echo "== T0: vacio -> total 0, apply no falla"
clean
out="$(cmd_gc --json)"
grep -q '"format": 1' <<<"$out" && grep -q '"total_bytes": 0' <<<"$out" && ok "T0 json total 0" || no "T0 json total 0"
grep -q '"applied": false' <<<"$out" && ok "T0 applied false" || no "T0 applied false"
grep -q '"hint": "nada que limpiar"' <<<"$out" && ok "T0 hint nada" || no "T0 hint nada"
cmd_gc --apply --yes >/dev/null 2>&1
[[ $? -eq 0 ]] && ok "T0 apply rc 0" || no "T0 apply rc 0"
# M8: rc no basta; efecto: sigue vacio y el json posterior da total 0.
out="$(cmd_gc --json)"
grep -q '"total_bytes": 0' <<<"$out" && grep -q '"applied": false' <<<"$out" && ok "T0 post-apply vacio" || no "T0 post-apply vacio"
[[ ! -e "$R.old" ]] && ! ls -d "$R".new.* >/dev/null 2>&1 && ok "T0 sin restos" || no "T0 sin restos"

echo "== T1: root.old valido -> prompt, --yes purga"
clean; mkroot "$R"; mkroot "$R.old"; echo x > "$R.old/usr/bin/bash"
out="$(cmd_gc --json)"
grep -q '"root_old": {"present": true, "valid": true' <<<"$out" && ok "T1 json present+valid" || no "T1 json present+valid"
grep -q '"staging": {"entries": 0' <<<"$out" && ok "T1 json staging keys" || no "T1 json staging keys"
grep -q '"hint": "arxy gc --apply libera [0-9]* bytes (incluye rollback recuperable)"' <<<"$out" && ok "T1 hint accionable" || no "T1 hint accionable"
out_err="$(cmd_gc --apply </dev/null 2>&1 || true)"
grep -q "exige tty (usa --yes para no-interactivo)" <<<"$out_err" && ok "T1 sin tty no purga y avisa" || no "T1 sin tty no purga y avisa ($out_err)"
[[ -d "$R.old" ]] && ok "T1 sin tty no toca" || no "T1 sin tty no toca"
cmd_gc --apply --yes >/dev/null 2>&1
[[ ! -d "$R.old" ]] && ok "T1 --yes purga" || no "T1 --yes purga"

echo "== T2: cache -> size > 0, apply la purga"
clean; mkroot "$R"; head -c 10000 /dev/urandom > "$R/var/cache/pacman/pkg/f1.pkg" 2>/dev/null || echo relleno > "$R/var/cache/pacman/pkg/f1.pkg"
out="$(cmd_gc --json)"
sz="$(grep -o '"cache": {"path": "[^"]*", "size": [0-9]*' <<<"$out" | grep -oE '[0-9]+$')"
[[ -n "$sz" && "$sz" -gt 0 ]] && ok "T2 cache size $sz" || no "T2 cache size > 0"
cmd_gc --apply --yes >/dev/null 2>&1
[[ ! -e "$R/var/cache/pacman/pkg/f1.pkg" ]] && ok "T2 apply purga cache" || no "T2 apply purga cache"

echo "== T3: --json no purga (mtimes intactos)"
clean; mkroot "$R.old"; echo x > "$R.old/usr/bin/bash"
m1="$(stat -c %Y "$R.old/usr/bin/bash")"
cmd_gc --json >/dev/null 2>&1
[[ "$(stat -c %Y "$R.old/usr/bin/bash")" == "$m1" ]] && ok "T3 json no toca" || no "T3 json no toca"
[[ -d "$R.old" ]] && ok "T3 json no purga" || no "T3 json no purga"

echo "== T4: texto informa sin aplicar"
clean; mkroot "$R.old"
out="$(cmd_gc)"
grep -q "rollback:" <<<"$out" && grep -q "total:" <<<"$out" && grep -q "nada tocado" <<<"$out" && ok "T4 texto dry-run" || no "T4 texto dry-run"
[[ -d "$R.old" ]] && ok "T4 texto no purga" || no "T4 texto no purga"

echo "== T5: root.old corrupto se purga sin preguntar (ni tty ni --yes)"
clean; mkdir -p "$R.old/etc"; echo roto > "$R.old/.mark"
out="$(cmd_gc --json)"
grep -q '"root_old": {"present": true, "valid": false' <<<"$out" && ok "T5 json valid false" || no "T5 json valid false"
cmd_gc --apply </dev/null >/dev/null 2>&1
[[ $? -eq 0 ]] && [[ ! -d "$R.old" ]] && ok "T5 purga sin prompt" || no "T5 purga sin prompt"

echo "== T6: staging via recover (root valido -> purga)"
clean; mkroot "$R" bueno; mkdir -p "$R.new.111"; touch "$D/.image.partial.222"
out="$(cmd_gc --json)"
grep -q '"staging": {"entries": 2' <<<"$out" && ok "T6 json entries 2" || no "T6 json entries 2"
cmd_gc --apply --yes >/dev/null 2>&1
[[ ! -e "$R.new.111" ]] && [[ ! -e "$D/.image.partial.222" ]] && ok "T6 apply purga staging" || no "T6 apply purga staging"
[[ "$(cat "$R/.mark" 2>/dev/null)" == bueno ]] && ok "T6 root intacto" || no "T6 root intacto"

echo "== T7: --json --apply reporta applied"
clean; mkroot "$R.old"
out="$(cmd_gc --json --apply --yes)"
grep -q '"applied": true' <<<"$out" && ok "T7 applied true" || no "T7 applied true"
grep -qE '"applied_bytes": [0-9]+' <<<"$out" && ok "T7 applied_bytes numero" || no "T7 applied_bytes numero"
[[ ! -d "$R.old" ]] && ok "T7 purga hecha" || no "T7 purga hecha"
clean

echo "== T8: lock tomado -> apply muere claro sin tocar ()"
clean; mkroot "$R"; mkroot "$R.old"; echo x > "$R.old/usr/bin/bash"
# Los T0-T7 directos dejaron ARXY_LOCK_FD tomado en esta shell (reentrancia):
# soltarlo para que solo el lock-padre de abajo bloquee.
exec {ARXY_LOCK_FD}>&- 2>/dev/null || true; unset ARXY_LOCK_FD
exec {_tfd}>"$D/.lock" && flock -n "$_tfd" || no "T8 setup lock"
out="$(cmd_gc --apply --yes 2>&1)"; rc=$?
exec {_tfd}>&-; unset _tfd
[[ $rc -ne 0 ]] && grep -q "otra operacion" <<<"$out" && ok "T8 contencion muere claro" || no "T8 contencion ($rc: $out)"
[[ -d "$R.old" ]] && ok "T8 no toco .old" || no "T8 toco .old"
cmd_gc --apply --yes >/dev/null 2>&1
[[ ! -d "$R.old" ]] && ok "T8 control purga" || no "T8 control purga"
clean

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
