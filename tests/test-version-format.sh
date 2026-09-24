#!/usr/bin/env bash
# test-version-format.sh — write_version emite JSON format 1 válido.
# Sin root ni imagen: sourcea lib/ con ARXY_ROOT en /tmp. Las funciones se
# llaman DIRECTO (sin sh -c): en subshell harían falta export -f/vars.
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
ARXY_ROOT="/tmp/vtest/root"
ARXY_VERSION_FILE="/tmp/vtest/version" # default vive en el root; aislar por env
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
no() { echo "FAIL: $1${2:+ (tengo '$2')}"; FAIL=$((FAIL+1)); }

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

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
