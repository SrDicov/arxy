#!/usr/bin/env bash
# test-atomic-setup.sh — SIGKILL en cada fase de setup deja estado recuperable.
# Kills DETERMINISTAS via overrides de funcion (curl/tar/mv/rm) + kill -9
# $BASHPID ($$ mataria el test: es el PID del padre, no del subshell).
# Requiere root (setup real); SKIP honesto sin el. Aisla en /tmp/arxy-atomic.
# Fixture tarball minimo (_image_ok-valido); pacman_mut y data_sync stubbed
# (data_sync solo LOGUEA: se prueba que setup la llama en cada fase, no el
# fsync del kernel). Sin red (sha fijado, file://).
#
#   sudo -n ./tests/test-atomic-setup.sh
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
[[ "$(id -u)" -eq 0 ]] || { echo "SKIP: requiere root (sudo -n $0)"; exit 0; }

ARXY_ROOT="${ARXY_ROOT:-/tmp/arxy-atomic/root}"
[[ "$ARXY_ROOT" == /var/lib/arxy/root ]] && { echo "FAIL: ARXY_ROOT real prohibido"; exit 1; }
D="${ARXY_ROOT%/*}"
R="$ARXY_ROOT"
mkdir -p "$D" || { echo "FAIL: sin $D"; exit 1; }
trap 'rm -rf "${D:?}"' EXIT

# Fixture ANTES de sourcear (el env se congela al sourcear: SHA ya exportado).
FX="$D/fx"; IMG="$D/image.tar.zst"; SYNCLOG="$D/sync.log"; PACLOG="$D/pacman.log"
mkdir -p "$FX/usr/bin" "$FX/etc"
: > "$FX/usr/bin/bash"; : > "$FX/usr/bin/pacman"
chmod +x "$FX/usr/bin/bash" "$FX/usr/bin/pacman"
echo "NAME=Arch Linux" > "$FX/etc/arch-release"
tar -cf "$IMG" -C "$FX" . || { echo "FAIL: no pude crear fixture"; exit 1; }
export ARXY_ROOT ARXY_IMAGE_URL="file://$IMG"
ARXY_IMAGE_SHA256="$(sha256sum <"$IMG" | cut -d' ' -f1)"
export ARXY_IMAGE_SHA256

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

# Stubs (tras sourcear: ultima definicion gana).
pacman_mut() { printf '%s\n' "$*" >>"$PACLOG"; return 0; }
data_sync() { printf '%s\n' "$*" >>"$SYNCLOG"; return 0; }

ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

mkroot() { # <$dir> [$version-url] : rootfs valido para _image_ok
    mkdir -p "$1/usr/bin" "$1/etc"
    : > "$1/usr/bin/bash"; : > "$1/usr/bin/pacman"
    chmod +x "$1/usr/bin/bash" "$1/usr/bin/pacman"
    echo "NAME=Arch Linux" > "$1/etc/arch-release"
    if [[ -n "${2:-}" ]]; then
        mkdir -p "$1/var/lib/arxy"
        ( export ARXY_VERSION_FILE="$1/var/lib/arxy/version"
          write_version "$2" "" "2020-01-01T00:00:00Z" ) >/dev/null 2>&1
    fi
}

echo "== T0: setup bueno (base + orden de fases)"
rm -rf "$D/root" "$D/root.old" "$D/version" "$SYNCLOG" "$PACLOG"
( cmd_setup ) >/dev/null 2>&1
[[ $? -eq 0 ]] && ok "T0 setup rc 0" || no "T0 setup rc 0"
_image_ok "$R" && ok "T0 root valido" || no "T0 root valido"
grep -q '"format": 1' "$R/var/lib/arxy/version" 2>/dev/null && ok "T0 version JSON dentro" || no "T0 version JSON dentro"
grep -q "\"image\": \"file://$IMG\"" "$R/var/lib/arxy/version" 2>/dev/null && ok "T0 version url custom" || no "T0 version url custom"
[[ -s "$D/level2-rc" ]] && ok "T0 level2-rc" || no "T0 level2-rc"
[[ ! -e "$D/version" ]] && ok "T0 sin legacy fuera" || no "T0 sin legacy fuera"
grep -q "root.new" "$SYNCLOG" 2>/dev/null && grep -q "$D" "$SYNCLOG" 2>/dev/null && ok "T0 sync toca staging+padre" || no "T0 sync toca staging+padre"
grep -q "\-Sy" "$PACLOG" 2>/dev/null && ok "T0 -Sy final" || no "T0 -Sy final"
a="$(sha256sum <"$R/var/lib/arxy/version")"
ensure_image >/dev/null 2>&1
[[ "$(sha256sum <"$R/var/lib/arxy/version")" == "$a" ]] && ok "T0 re-ensure idempotente" || no "T0 re-ensure idempotente"

echo "== T1: kill -9 en descarga"
rm -rf "$D/root" "$D/root.old" "$D"/root.new.* "$D"/.image.partial.* "$D/version"
mkroot "$R" "file:///gen-vieja"; echo viejo > "$R/.mark"
curl() { kill -9 "$BASHPID"; }
rc=0; ( cmd_setup ) >/dev/null 2>&1 || rc=$?
unset -f curl
[[ "$rc" -eq 137 ]] && ok "T1 murio por kill" || no "T1 murio por kill (rc $rc)"
ensure_image >/dev/null 2>&1
[[ "$(cat "$R/.mark" 2>/dev/null)" == viejo ]] && ok "T1 marcador intacto" || no "T1 marcador intacto"
_image_ok "$R" && ok "T1 root intacto" || no "T1 root intacto"
ls -d "$R".new.* >/dev/null 2>&1 && no "T1 sin staging" || ok "T1 sin staging"
ls "$D"/.image.partial.* >/dev/null 2>&1 && no "T1 parcial limpiado" || ok "T1 parcial limpiado"
grep -q '"image": "file:///gen-vieja"' "$R/var/lib/arxy/version" 2>/dev/null && ok "T1 version vieja intacta" || no "T1 version vieja intacta"

echo "== T2: kill -9 tras sha, antes de extraer"
rm -rf "$D/root" "$D/root.old" "$D"/root.new.* "$D"/.image.partial.* "$D/version"
mkroot "$R" "file:///gen-vieja"; echo viejo > "$R/.mark"
tar() { kill -9 "$BASHPID"; }
zstd() { kill -9 "$BASHPID"; }
rc=0; ( cmd_setup ) >/dev/null 2>&1 || rc=$?
unset -f tar zstd
[[ "$rc" -eq 137 ]] && ok "T2 murio por kill" || no "T2 murio por kill (rc $rc)"
ensure_image >/dev/null 2>&1
[[ "$(cat "$R/.mark" 2>/dev/null)" == viejo ]] && ok "T2 marcador intacto" || no "T2 marcador intacto"
ls -d "$R".new.* >/dev/null 2>&1 && no "T2 sin staging" || ok "T2 sin staging"

echo "== T3: kill -9 con staging a medias"
rm -rf "$D/root" "$D/root.old" "$D"/root.new.* "$D"/.image.partial.* "$D/version"
mkroot "$R" "file:///gen-vieja"; echo viejo > "$R/.mark"
tar() { local a prev=""; for a in "$@"; do
    if [[ "$prev" == "-C" ]]; then mkdir -p "$a"; touch "$a/PARTIAL"; kill -9 "$BASHPID"; fi
    prev="$a"; done; kill -9 "$BASHPID"; }
zstd() { kill -9 "$BASHPID"; }
rc=0; ( cmd_setup ) >/dev/null 2>&1 || rc=$?
unset -f tar zstd
[[ "$rc" -eq 137 ]] && ok "T3 murio por kill" || no "T3 murio por kill (rc $rc)"
rec="$(ensure_image 2>&1)"
[[ "$(cat "$R/.mark" 2>/dev/null)" == viejo ]] && ok "T3 marcador intacto" || no "T3 marcador intacto"
ls -d "$R".new.* >/dev/null 2>&1 && no "T3 staging borrado" || ok "T3 staging borrado"
grep -q "recuperado" <<<"$rec" && ok "T3 recovery loguea" || no "T3 recovery loguea"

echo "== T4: kill -9 tras apartar root, antes del rename"
rm -rf "$D/root" "$D/root.old" "$D"/root.new.* "$D"/root.old.tmp.* "$D"/.image.partial.* "$D/version"
mkroot "$R" "file:///gen-vieja"; echo viejo > "$R/.mark"
mv() { case "$*" in *".old.tmp."*) command mv "$@"; kill -9 "$BASHPID";; *) command mv "$@";; esac; }
rc=0; ( cmd_setup ) >/dev/null 2>&1 || rc=$?
unset -f mv
[[ "$rc" -eq 137 ]] && ok "T4 murio por kill" || no "T4 murio por kill (rc $rc)"
[[ ! -e "$R" ]] && ls -d "$R".old.tmp.* >/dev/null 2>&1 && ok "T4 estado intermedio" || no "T4 estado intermedio"
rec="$(ensure_image 2>&1)"
[[ "$(cat "$R/.mark" 2>/dev/null)" == viejo ]] && ok "T4 root recuperado" || no "T4 root recuperado"
grep -q '"image": "file:///gen-vieja"' "$R/var/lib/arxy/version" 2>/dev/null && ok "T4 version viajo con root" || no "T4 version viajo con root"
ls -d "$R".old.tmp.* >/dev/null 2>&1 && no "T4 tmp resuelto" || ok "T4 tmp resuelto"
grep -q "recuperado" <<<"$rec" && ok "T4 recovery loguea" || no "T4 recovery loguea"

echo "== T5: root valido sin version (formato anterior) se regenera"
rm -rf "$D/root" "$D/root.old" "$D"/root.new.* "$D"/root.old.tmp.* "$D/version"
mkroot "$R"; echo vetusto > "$R/.mark"
printf 'url=file:///legado.tar.zst\ndate=2019-01-01T00:00:00Z\n' > "$D/version"
ensure_image >/dev/null 2>&1
[[ "$(cat "$R/.mark" 2>/dev/null)" == vetusto ]] && ok "T5 root intacto" || no "T5 root intacto"
grep -q '"format": 1' "$R/var/lib/arxy/version" 2>/dev/null && ok "T5 version regenerada" || no "T5 version regenerada"
grep -q "\"image\": \"file://$IMG\"" "$R/var/lib/arxy/version" 2>/dev/null && ok "T5 url de la config" || no "T5 url de la config"
[[ ! -e "$D/version" ]] && ok "T5 legacy fuera borrado" || no "T5 legacy fuera borrado"

echo "== T6: kill -9 tras rename, antes de rotar .old"
rm -rf "$D/root" "$D/root.old" "$D"/root.new.* "$D"/root.old.tmp.* "$D"/.image.partial.* "$D/version"
mkroot "$R" "file:///gen-vieja"; echo previo > "$R/.mark"
rm() { case "$* " in *".old.tmp."*) command rm "$@";; *"$R.old "*) kill -9 "$BASHPID";; *) command rm "$@";; esac; }
rc=0; ( cmd_setup ) >/dev/null 2>&1 || rc=$?
unset -f rm
[[ "$rc" -eq 137 ]] && ok "T6 murio por kill" || no "T6 murio por kill (rc $rc)"
_image_ok "$R" && [[ ! -e "$R/.mark" ]] && ok "T6 root nuevo vivo" || no "T6 root nuevo vivo"
ls -d "$R".old.tmp.* >/dev/null 2>&1 && ok "T6 tmp varado" || no "T6 tmp varado"
ensure_image >/dev/null 2>&1
[[ "$(cat "$R.old/.mark" 2>/dev/null)" == previo ]] && ok "T6 .old es el previo" || no "T6 .old es el previo"
ls -d "$R".old.tmp.* >/dev/null 2>&1 && no "T6 tmp resuelto" || ok "T6 tmp resuelto"
[[ ! -e "$D/version" ]] && ok "T6 sin legacy fuera" || no "T6 sin legacy fuera"

echo "== T7: rollback invalida .arxy-sig rancia ()"
rm -rf "$D/root" "$D/root.old" "$D"/root.new.* "$D"/root.old.tmp.* "$D"/.image.partial.* "$D/version"
mkroot "$R"; echo nuevo > "$R/.mark"
mkroot "$R.old"; echo viejo > "$R.old/.mark"
printf '1' > "$D/.arxy-sig"
cmd_rollback >/dev/null 2>&1
[[ "$(cat "$R/.mark" 2>/dev/null)" == viejo ]] && ok "T7 rolo a .old" || no "T7 rolo"
[[ ! -e "$D/.arxy-sig" ]] && ok "T7 sig invalidada" || no "T7 sig rancia sigue"

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
