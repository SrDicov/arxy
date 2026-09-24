#!/usr/bin/env bash
# test-version-migrate.sh — plano legacy -> JSON sin perder datos.
# Idempotente, no toca basura, no exige nada si falta. Sin root ni imagen.
# Llamadas DIRECTAS (ver test-version-format.sh: sh -c esconde funciones).
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
ARXY_ROOT="/tmp/vtestm/root"
ARXY_VERSION_FILE="/tmp/vtestm/version" # default vive en el root; aislar por env
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
no() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

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

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
