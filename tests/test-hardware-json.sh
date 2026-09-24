#!/usr/bin/env bash
# test-hardware-json.sh — escritor/lector de hardware.json.
# Sin root ni imagen: sourcea lib/ con ARXY_ROOT en /tmp. Mocks de detección
# en test-detect.sh; aquí el ciclo de vida del fichero (idempotencia,
# no-reescritura, corrupto, ausente) + que doctor --json no lo muta.
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
ARXY_ROOT="/tmp/hwtest/root"
export ARXY_ROOT
# shellcheck source=../lib/00-head.sh
. "$HERE/../lib/00-head.sh" >/dev/null 2>&1
# shellcheck source=../lib/10-level.sh
. "$HERE/../lib/10-level.sh" >/dev/null 2>&1
# shellcheck source=../lib/60-detect.sh
. "$HERE/../lib/60-detect.sh" >/dev/null 2>&1
# shellcheck source=../lib/61-doctor.sh
. "$HERE/../lib/61-doctor.sh" >/dev/null 2>&1
# shellcheck source=../lib/62-json.sh
. "$HERE/../lib/62-json.sh" >/dev/null 2>&1
export -f write_hardware_json show_hardware_profile msg
export ARXY_DATA # deriva en el sourceo; los sh -c la necesitan exportada
D="$ARXY_DATA"               # /tmp/hwtest (deriva de ARXY_ROOT)
rm -rf "$D"; mkdir -p "$D"
trap 'rm -rf "$D" /tmp/hwdoc' EXIT

t() { # t <nombre> -- <cmd...>
    local name="$1"; shift; shift
    local out rc
    if out="$("$@" 2>&1)"; then echo "PASS: $name";
    else rc=$?; echo "FAIL($rc): $name"; printf '%s\n' "$out" | head -6 | sed 's/^/  /'; FAIL=$((FAIL+1)); fi
}

J1='{"format": 1, "level": 1}'
J2='{"format": 1, "level": 2}'

t "write emite 0644 con contenido" -- bash -c 'write_hardware_json "$0" >/dev/null 2>&1; test "$(cat "$1/hardware.json")" = "$0" && test "$(stat -c %a "$1/hardware.json")" = 644' "$J1" "$D"
t "write idéntico preserva mtime" -- bash -c 'a=$(stat -c %Y "$0/hardware.json"); sleep 1; write_hardware_json "$1" >/dev/null 2>&1; test "$(stat -c %Y "$0/hardware.json")" = "$a"' "$D" "$J1"
t "write distinto reescribe" -- bash -c 'write_hardware_json "$1" >/dev/null 2>&1; test "$(cat "$0/hardware.json")" = "$1"' "$D" "$J2"
t "write sin dir no falla setup" -- bash -c 'ARXY_DATA=/proc/noexiste-falso write_hardware_json "$0" 2>/dev/null; test $? -eq 0' "$J1"
# ^ bash -c (NO sh): export -f es de bash; con sh->dash (Debian/este host)
# el subshell no ve las funciones (rc=127) y los 3 write fallan en falso.
# En Arch sh->bash y el CI nunca lo vio. ARXY_DATA se pasa por env porque
# export -f no cubre vars.

# show_* se llama DIRECTO (no en sh -c): tira de media lib/ (emit, probes)
# y exportar el mundo es frágil; aquí no hace falta aislar env.
_rel="$(uname -r)"
printf '{"format": 1, "libc": {"kind": "glibc", "version": "2.44"}, "kernel": {"arch": "x86_64", "release": "%s"}, "gpu": {"vendor": "intel", "driver": null, "render_node": null}, "nvidia": {"present": false, "version": null, "usable": false, "reason": "x"}, "kmods": ["fuse"], "dev": {}, "rootfs": {}}' "$_rel" > "$D/hardware.json"
_out="$(show_hardware_profile 2>/dev/null || true)"
if grep -Fq "hardware: $D/hardware.json (format 1)" <<<"$_out" && grep -q "^  libc: glibc 2.44$" <<<"$_out"; then echo "PASS: show lee fichero";
else echo "FAIL: show lee fichero"; FAIL=$((FAIL+1)); fi
printf '{"format": 1, "kernel": {"arch": "x", "release": "0.0-falso"}, "nvidia": {"version": null}}' > "$D/hardware.json"
_out="$(show_hardware_profile 2>/dev/null || true)"; _err="$(show_hardware_profile 2>&1 >/dev/null || true)"
if grep -q "^hardware: " <<<"$_out" && grep -q "difiere del perfil" <<<"$_err"; then echo "PASS: show avisa con stale";
else echo "FAIL: show avisa con stale"; FAIL=$((FAIL+1)); fi
printf 'no-json{{{' > "$D/hardware.json"
_out="$(show_hardware_profile 2>/dev/null || true)"; _err="$(show_hardware_profile 2>&1 >/dev/null || true)"
if grep -q "^hardware: memoria" <<<"$_out" && grep -q "corrupto" <<<"$_err"; then echo "PASS: show corrupto avisa y sigue";
else echo "FAIL: show corrupto avisa y sigue"; FAIL=$((FAIL+1)); fi
rm -f "$D/hardware.json"
_out="$(show_hardware_profile 2>/dev/null || true)"; _err="$(show_hardware_profile 2>&1 >/dev/null || true)"
if grep -q "^hardware: memoria" <<<"$_out" && grep -q "sin hardware.json" <<<"$_err"; then echo "PASS: show ausente avisa y calcula";
else echo "FAIL: show ausente avisa y calcula"; FAIL=$((FAIL+1)); fi

t "doctor --json no muta hardware.json" -- sh -c 'rm -rf /tmp/hwdoc; ARXY_ROOT=/tmp/hwdoc/root "$0" doctor --json >/dev/null 2>&1 || true; test ! -e /tmp/hwdoc/hardware.json' "$HERE/../src/arxy"

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
