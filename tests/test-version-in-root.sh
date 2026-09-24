#!/usr/bin/env bash
# test-version-in-root.sh — version vive DENTRO del root.
# T0: rollback rota dirs y la version viaja sola (sin copias). T1: pacman no
# la reclama (root real; SKIP sin imagen nueva). T2: rollback a rootfs viejo
# (sin version dentro) + ensure regenera. Sin root salvo T1.
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
ARXY_ROOT="/tmp/vinroot/root"
export ARXY_ROOT
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh" # ARXY_BIN default: repo (no el instalado viejo)
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
need_root() { return 0; } # rollback aislado: dirs en /tmp
D="$ARXY_DATA"
R="$ARXY_ROOT"
rm -rf "$D"; mkdir -p "$D"
trap 'rm -rf "$D"' EXIT

ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

mkroot() { # <$dir> [$version-url] [$sha] : rootfs valido para _image_ok
    mkdir -p "$1/usr/bin" "$1/etc"
    : > "$1/usr/bin/bash"; : > "$1/usr/bin/pacman"
    chmod +x "$1/usr/bin/bash" "$1/usr/bin/pacman"
    echo "NAME=Arch Linux" > "$1/etc/arch-release"
    if [[ -n "${2:-}" ]]; then
        mkdir -p "$1/var/lib/arxy"
        ( export ARXY_VERSION_FILE="$1/var/lib/arxy/version"
          write_version "$2" "${3:-}" "2020-01-01T00:00:00Z" ) >/dev/null 2>&1
    fi
}

echo "== T0: rollback rota la version sin copiar nada fuera"
mkroot "$R" "file:///nuevo" "aaa-nuevo"; echo nuevo > "$R/.mark"
mkroot "$R.old" "file:///viejo" "bbb-viejo"; echo viejo > "$R.old/.mark"
cmd_rollback >/dev/null 2>&1
[[ $? -eq 0 ]] && ok "T0 rollback rc 0" || no "T0 rollback rc 0"
[[ "$(cat "$R/.mark" 2>/dev/null)" == viejo ]] && ok "T0 root es el viejo" || no "T0 root es el viejo"
grep -q '"image": "file:///viejo"' "$R/var/lib/arxy/version" 2>/dev/null && ok "T0 version describe al activo" || no "T0 version describe al activo"
grep -q '"sha256": "bbb-viejo"' "$R/var/lib/arxy/version" 2>/dev/null && ok "T0 sha es del activo" || no "T0 sha es del activo"
grep -q '"image": "file:///nuevo"' "$R.old/var/lib/arxy/version" 2>/dev/null && ok "T0 .old guarda la nueva" || no "T0 .old guarda la nueva"
grep -q '"sha256": "aaa-nuevo"' "$R.old/var/lib/arxy/version" 2>/dev/null && ok "T0 .old guarda su sha" || no "T0 .old guarda su sha"
[[ ! -e "$D/version" ]] && ok "T0 nada fuera del root" || no "T0 nada fuera del root"

echo "== T1: pacman no reclama la version (root real)"
REAL_R="/var/lib/arxy/root"
if [[ ! -f "$REAL_R/var/lib/arxy/version" ]] || [[ ! -x "$REAL_R/usr/bin/pacman" ]]; then
    echo "SKIP: T1 (sin imagen instalada con CLI nuevo)"
elif ! "$ARXY_BIN" run /usr/bin/true >/dev/null 2>&1; then
    echo "SKIP: T1 (run no disponible aqui)"
else
    out="$("$ARXY_BIN" run pacman -Qo /var/lib/arxy/version 2>&1 || true)"
    grep -q "No package owns" <<<"$out" && ok "T1 version sin dueno" || no "T1 version sin dueno"
fi

echo "== T2: rollback a rootfs viejo (plano fuera) + ensure regenera"
export ARXY_IMAGE_URL="file:///nuevo-setup"
rm -rf "$R" "$R.old" "$D/version"
mkroot "$R" "file:///nuevo"; echo nuevo > "$R/.mark"
mkroot "$R.old"; echo viejo > "$R.old/.mark" # formato anterior: sin version dentro
printf 'url=file:///legado.tar.zst\ndate=2019-01-01T00:00:00Z\n' > "$D/version"
cmd_rollback >/dev/null 2>&1
[[ "$(cat "$R/.mark" 2>/dev/null)" == viejo ]] && ok "T2 activo es el viejo" || no "T2 activo es el viejo"
ensure_image >/dev/null 2>&1
[[ $? -eq 0 ]] && ok "T2 ensure rc 0" || no "T2 ensure rc 0"
grep -q '"format": 1' "$R/var/lib/arxy/version" 2>/dev/null && ok "T2 version JSON regenerada" || no "T2 version JSON regenerada"
grep -q '"image": "file:///nuevo-setup"' "$R/var/lib/arxy/version" 2>/dev/null && ok "T2 url de la config" || no "T2 url de la config"
grep -q "legado" "$R/var/lib/arxy/version" 2>/dev/null && no "T2 sin restos del legado" || ok "T2 sin restos del legado"

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
