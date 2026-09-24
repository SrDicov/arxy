#!/usr/bin/env bash
# test-version-legacy-read.sh — version_field lee JSON y plano.
# Si la migración falla (sin permisos), la lectura vieja sigue sirviendo.
# Llamadas DIRECTAS (ver test-version-format.sh: sh -c esconde funciones).
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
ARXY_ROOT="/tmp/vtestl/root"
ARXY_VERSION_FILE="/tmp/vtestl/version" # default vive en el root; aislar por env
export ARXY_ROOT ARXY_VERSION_FILE
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
rm -rf "$D"; mkdir -p "$D"
trap 'rm -rf "$D"' EXIT

ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1 (quiero '$2', tengo '$3')"; FAIL=$((FAIL+1)); }

printf 'url=file:///plano.tar.zst\ndate=2021-05-05T05:05:05Z\n' > "$D/version"
g="$(version_field url 2>/dev/null || true)"; [[ "$g" == "file:///plano.tar.zst" ]] && ok "lee url plano" || no "lee url plano" "file:///plano.tar.zst" "$g"
g="$(version_field date 2>/dev/null || true)"; [[ "$g" == "2021-05-05T05:05:05Z" ]] && ok "lee date plano" || no "lee date plano" "2021-05-05T05:05:05Z" "$g"
write_version "file:///nuevo.tar.zst" "00ff" "2026-01-01T00:00:00Z" >/dev/null 2>&1
g="$(version_field url 2>/dev/null || true)"; [[ "$g" == "file:///nuevo.tar.zst" ]] && ok "lee url JSON" || no "lee url JSON" "file:///nuevo.tar.zst" "$g"
g="$(version_field date 2>/dev/null || true)"; [[ "$g" == "2026-01-01T00:00:00Z" ]] && ok "lee date JSON" || no "lee date JSON" "2026-01-01T00:00:00Z" "$g"
version_field frobnicate 2>/dev/null; [[ $? -eq 1 ]] && ok "clave mala rc 1" || no "clave mala rc 1" "rc 1" "rc $?"
rm -f "$D/version"
version_field url 2>/dev/null; [[ $? -eq 1 ]] && ok "ausente rc 1" || no "ausente rc 1" "rc 1" "rc $?"
echo "==  lectura corrupta avisa a stderr sin tocar stdout"
printf 'garbage{{{\n' > "$D/version"
out="$(version_line 2>/dev/null)"; err="$(version_line 2>&1 >/dev/null)"
[[ "$out" == "url= date=" ]] && grep -q "aviso: version ilegible" <<<"$err" && ok " aviso corrupto" || no " aviso corrupto" "url= date= + aviso" "out='$out' err='$err'"
if [[ "$(id -u)" -eq 0 ]]; then
    echo "SKIP: ilegible sin permisos (este shell es root, lee igual)"
else
    printf 'url=x\ndate=y\n' > "$D/version" && chmod 000 "$D/version"
    version_field url 2>/dev/null; [[ $? -eq 1 ]] && ok "ilegible rc 1" || no "ilegible rc 1" "rc 1" "rc $?"
    chmod 644 "$D/version"
fi

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
