#!/usr/bin/env bash
# test-version.sh — version: formato JSON (A), lectura legacy/plano (B),
# migracion plano->JSON (C) y version dentro del root (D). Una sola setup;
# sin root ni imagen (D/T1 usa el root real solo si hay imagen instalada).
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
ARXY_ROOT="/tmp/vtest/root"
ARXY_VERSION_FILE="/tmp/vtest/version" # default vive en el root; aislar por env
export ARXY_ROOT ARXY_VERSION_FILE
# shellcheck source=lib.sh
. "$HERE/lib.sh" # ARXY_BIN default: repo (no el instalado viejo)
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

echo "== A: write_version emite JSON format 1 valido =="
write_version "file:///tmp/x.tar.zst" "abc123" >/dev/null 2>&1 && ok "write rc 0" || no "write rc 0"
for _k in format image sha256 created_at arxy_version; do
    if grep -q "\"$_k\":" "$D/version" 2>/dev/null; then ok "json key $_k"; else no "json key $_k"; fi
done
grep -q '"image": "file:///tmp/x.tar.zst"' "$D/version" 2>/dev/null && ok "json image exacta" || no "json image exacta"
grep -q "\"arxy_version\": \"$ARXY_VERSION\"" "$D/version" 2>/dev/null && ok "json version CLI" || no "json version CLI"
rm -f "$D/version"
write_version "u" "" >/dev/null 2>&1
grep -q '"sha256": null' "$D/version" 2>/dev/null && ok "sha vacio es null" || no "sha vacio es null"
if command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["format"]==1 and isinstance(d["image"],str)' "$D/version" 2>/dev/null; then ok "json parseo estricto";
    else no "json parseo estricto"; fi
else
    echo "SKIP: parseo estricto (sin python3)"
fi

echo "== B: version_field lee JSON y plano =="
printf 'url=file:///plano.tar.zst\ndate=2021-05-05T05:05:05Z\n' > "$D/version"
g="$(version_field url 2>/dev/null || true)"; [[ "$g" == "file:///plano.tar.zst" ]] && ok "lee url plano" || no "lee url plano" "quiero 'file:///plano.tar.zst', tengo '$g'"
g="$(version_field date 2>/dev/null || true)"; [[ "$g" == "2021-05-05T05:05:05Z" ]] && ok "lee date plano" || no "lee date plano" "quiero '2021-05-05T05:05:05Z', tengo '$g'"
write_version "file:///nuevo.tar.zst" "00ff" "2026-01-01T00:00:00Z" >/dev/null 2>&1
g="$(version_field url 2>/dev/null || true)"; [[ "$g" == "file:///nuevo.tar.zst" ]] && ok "lee url JSON" || no "lee url JSON" "quiero 'file:///nuevo.tar.zst', tengo '$g'"
g="$(version_field date 2>/dev/null || true)"; [[ "$g" == "2026-01-01T00:00:00Z" ]] && ok "lee date JSON" || no "lee date JSON" "quiero '2026-01-01T00:00:00Z', tengo '$g'"
version_field frobnicate 2>/dev/null; [[ $? -eq 1 ]] && ok "clave mala rc 1" || no "clave mala rc 1" "quiero 'rc 1', tengo 'rc $?'"
rm -f "$D/version"
version_field url 2>/dev/null; [[ $? -eq 1 ]] && ok "ausente rc 1" || no "ausente rc 1" "quiero 'rc 1', tengo 'rc $?'"
echo "==  lectura corrupta avisa a stderr sin tocar stdout"
printf 'garbage{{{\n' > "$D/version"
out="$(version_line 2>/dev/null)"; err="$(version_line 2>&1 >/dev/null)"
[[ "$out" == "url= date=" ]] && grep -q "aviso: version ilegible" <<<"$err" && ok " aviso corrupto" || no " aviso corrupto" "quiero 'url= date= + aviso', tengo 'out='$out' err='$err''"
if [[ "$(id -u)" -eq 0 ]]; then
    echo "SKIP: ilegible sin permisos (este shell es root, lee igual)"
else
    printf 'url=x\ndate=y\n' > "$D/version" && chmod 000 "$D/version"
    version_field url 2>/dev/null; [[ $? -eq 1 ]] && ok "ilegible rc 1" || no "ilegible rc 1" "quiero 'rc 1', tengo 'rc $?'"
    chmod 644 "$D/version"
fi

echo "== C: plano legacy -> JSON sin perder datos =="
printf 'url=file:///vieja.tar.zst\ndate=2020-01-01T00:00:00Z\n' > "$D/version"
migrate_version_file >/dev/null 2>&1 && ok "migra rc 0" || no "migra rc 0"
grep -q '"image": "file:///vieja.tar.zst"' "$D/version" 2>/dev/null && ok "migra preserva url" || no "migra preserva url"
grep -q '"created_at": "2020-01-01T00:00:00Z"' "$D/version" 2>/dev/null && ok "migra preserva fecha" || no "migra preserva fecha"
grep -q '"format": 1' "$D/version" 2>/dev/null && ok "migra pone format" || no "migra pone format"
a="$(sha256sum <"$D/version")"; m="$(stat -c %Y "$D/version")"; sleep 1
migrate_version_file >/dev/null 2>&1
if [[ "$(sha256sum <"$D/version")" == "$a" ]] && [[ "$(stat -c %Y "$D/version")" == "$m" ]]; then ok "migra idempotente"; else no "migra idempotente"; fi
rm -f "$D/version"
if migrate_version_file 2>/dev/null && [[ ! -e "$D/version" ]]; then ok "ausente no falla ni crea"; else no "ausente no falla ni crea"; fi
printf 'ni-json-ni-plano' > "$D/version"
a="$(sha256sum <"$D/version")"
if migrate_version_file 2>/dev/null && [[ "$(sha256sum <"$D/version")" == "$a" ]]; then ok "basura no se toca"; else no "basura no se toca"; fi
# Sin pipe directo: con pipefail, `prod | grep -q` puede dar SIGPIPE 141
# (regla 5). Capturar en variable y grepear después.
_mig_out="$(migrate_version_file 2>&1 >/dev/null || true)"
if grep -q "corrupto" <<<"$_mig_out"; then ok "basura avisa"; else no "basura avisa"; fi

echo "== D: version vive DENTRO del root =="
export ARXY_VERSION_FILE="$R/var/lib/arxy/version"
rm -f "$D/version" # el legado fuera del root no viaja entre secciones
need_root() { return 0; } # rollback aislado: dirs en /tmp
BIN="$ARXY_BIN"

echo "== T0: rollback rota la version sin copiar nada fuera"
arxy_mkroot_ver "$R" "file:///nuevo" "aaa-nuevo"; echo nuevo > "$R/.mark"
arxy_mkroot_ver "$R.old" "file:///viejo" "bbb-viejo"; echo viejo > "$R.old/.mark"
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
elif ! "$BIN" run /usr/bin/true >/dev/null 2>&1; then
    echo "SKIP: T1 (run no disponible aqui)"
else
    out="$("$BIN" run pacman -Qo /var/lib/arxy/version 2>&1 || true)"
    grep -q "No package owns" <<<"$out" && ok "T1 version sin dueno" || no "T1 version sin dueno"
fi

echo "== T2: rollback a rootfs viejo (plano fuera) + ensure regenera"
export ARXY_IMAGE_URL="file:///nuevo-setup"
rm -rf "$R" "$R.old" "$D/version"
arxy_mkroot_ver "$R" "file:///nuevo"; echo nuevo > "$R/.mark"
arxy_mkroot_ver "$R.old"; echo viejo > "$R.old/.mark" # formato anterior: sin version dentro
printf 'url=file:///legado.tar.zst\ndate=2019-01-01T00:00:00Z\n' > "$D/version"
cmd_rollback >/dev/null 2>&1
[[ "$(cat "$R/.mark" 2>/dev/null)" == viejo ]] && ok "T2 activo es el viejo" || no "T2 activo es el viejo"
ensure_image >/dev/null 2>&1
[[ $? -eq 0 ]] && ok "T2 ensure rc 0" || no "T2 ensure rc 0"
grep -q '"format": 1' "$R/var/lib/arxy/version" 2>/dev/null && ok "T2 version JSON regenerada" || no "T2 version JSON regenerada"
grep -q '"image": "file:///nuevo-setup"' "$R/var/lib/arxy/version" 2>/dev/null && ok "T2 url de la config" || no "T2 url de la config"
grep -q "legado" "$R/var/lib/arxy/version" 2>/dev/null && no "T2 sin restos del legado" || ok "T2 sin restos del legado"

finish
