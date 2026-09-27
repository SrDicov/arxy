#!/usr/bin/env bash
# test-cachy.sh — cpu_tier por flags (A) + cachy_activate idempotente (B).
# Sin root ni imagen: cpuinfo falsos y pacman.conf temporal.
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
export ARXY_ROOT="/tmp/cachytest/root"
# shellcheck source=lib.sh
. "$HERE/lib.sh" # ok/no/t/te/finish
# shellcheck source=../lib/00-head.sh
. "$HERE/../lib/00-head.sh" >/dev/null 2>&1
# shellcheck source=../lib/60-detect.sh
. "$HERE/../lib/60-detect.sh" >/dev/null 2>&1
# shellcheck source=../lib/21-setup.sh
. "$HERE/../lib/21-setup.sh" >/dev/null 2>&1
D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT

mkcpu() { # <fich> <vendor> <flags...> : cpuinfo falso de 2 CPUs gemelas
    local f="$1" v="$2"; shift 2
    { for _c in 1 2; do
        printf 'processor\t: 0\nvendor_id\t: %s\nmodel\t\t: 1\nmodel name\t: Fake CPU\nflags\t\t: %s\n\n' "$v" "$*"
    done; } > "$f"
}
V3F="fpu avx avx2 bmi1 bmi2 fma lzcnt movbe osxsave"
V4F="$V3F avx512f avx512bw avx512cd avx512dq avx512vl"

echo "== A: cpu_tier =="
# shellcheck disable=SC2086 # flags a proposito como palabras
mkcpu "$D/v3" GenuineIntel $V3F
t "v3 intel" "^v3$" -- cpu_tier "$D/v3" x86_64
# shellcheck disable=SC2086
mkcpu "$D/v4" GenuineIntel $V4F
t "v4 xeon homogeneo" "^v4$" -- cpu_tier "$D/v4" x86_64
# shellcheck disable=SC2086
mkcpu "$D/zn" AuthenticAMD $V4F avx512vbmi
t "znver4 amd+vbmi" "^znver4$" -- cpu_tier "$D/zn" x86_64
# shellcheck disable=SC2086
mkcpu "$D/vbmi-intel" GenuineIntel $V4F avx512vbmi
t "intel+vbmi es v4, no znver4" "^v4$" -- cpu_tier "$D/vbmi-intel" x86_64
{ printf 'processor\t: 0\nvendor_id\t: GenuineIntel\nmodel\t\t: 151\nflags\t\t: %s\n\n' "$V4F"
  printf 'processor\t: 1\nvendor_id\t: GenuineIntel\nmodel\t\t: 190\nflags\t\t: %s\n\n' "$V4F"; } > "$D/hybrid"
t "hibrido heterogeneo topa v3" "^v3$" -- cpu_tier "$D/hybrid" x86_64
mkcpu "$D/v1" GenuineIntel fpu sse2
te "v1 vacio" 1 -- cpu_tier "$D/v1" x86_64
te "aarch64 vacio" 1 -- cpu_tier "$D/v3" aarch64
te "ausente vacio" 1 -- cpu_tier "$D/no-existe" x86_64

echo "== B: cachy_activate =="
R="$ARXY_ROOT"
mkdir -p "$R/etc/pacman.d"
cat > "$R/etc/pacman.conf" <<'CONF'
[options]
Architecture = auto
#[cachyos-v3]
#Include = /etc/pacman.d/cachyos-v3-mirrorlist
#[cachyos-core-v3]
#Include = /etc/pacman.d/cachyos-v3-mirrorlist
#[cachyos-extra-v3]
#Include = /etc/pacman.d/cachyos-v3-mirrorlist
#[cachyos-v4]
#Include = /etc/pacman.d/cachyos-v4-mirrorlist
#[cachyos-core-v4]
#Include = /etc/pacman.d/cachyos-v4-mirrorlist
#[cachyos-extra-v4]
#Include = /etc/pacman.d/cachyos-v4-mirrorlist
#[cachyos-znver4]
#Include = /etc/pacman.d/cachyos-v4-mirrorlist
#[cachyos-core-znver4]
#Include = /etc/pacman.d/cachyos-v4-mirrorlist
#[cachyos-extra-znver4]
#Include = /etc/pacman.d/cachyos-v4-mirrorlist
#[cachyos]
#Include = /etc/pacman.d/cachyos-mirrorlist
[core]
Include = /etc/pacman.d/mirrorlist
CONF
: > "$R/etc/pacman.d/cachyos-mirrorlist"
: > "$R/etc/pacman.d/cachyos-v3-mirrorlist"
: > "$R/etc/pacman.d/cachyos-v4-mirrorlist"
run_pacman() { return 0; } # keyring presente
cachy_usable 2>/dev/null && ok "usable con marker" || no "usable con marker"
cachy_activate v3 2>/dev/null && ok "activa v3 rc 0" || no "activa v3 rc 0"
grep -q '^\[cachyos-v3\]$' "$R/etc/pacman.conf" && ok "v3 activo" || no "v3 activo"
grep -q '^\[cachyos\]$' "$R/etc/pacman.conf" && ok "[cachyos] activo" || no "[cachyos] activo"
grep -q '^Include = /etc/pacman.d/cachyos-v3-mirrorlist$' "$R/etc/pacman.conf" && ok "include v3" || no "include v3"
grep -q '^#\[cachyos-v4\]$' "$R/etc/pacman.conf" && ok "v4 sigue comentado" || no "v4 comentado"
grep -q '^\[core\]$' "$R/etc/pacman.conf" && ok "[core] intacto" || no "[core] intacto"
g="$(cachy_active_tier 2>/dev/null || true)"; [[ "$g" == v3 ]] && ok "tier activo v3" || no "tier activo v3" "$g"
a="$(sha256sum <"$R/etc/pacman.conf")"
cachy_activate v3 2>/dev/null
[[ "$(sha256sum <"$R/etc/pacman.conf")" == "$a" ]] && ok "idempotente" || no "idempotente"
cachy_activate v4 2>/dev/null && ok "swap a v4 rc 0" || no "swap a v4"
grep -q '^\[cachyos-v4\]$' "$R/etc/pacman.conf" && ok "v4 activo" || no "v4 activo"
grep -q '^#\[cachyos-v3\]$' "$R/etc/pacman.conf" && ok "v3 neutralizado" || no "v3 neutralizado"
grep -q '^#Include = /etc/pacman.d/cachyos-v3-mirrorlist$' "$R/etc/pacman.conf" && ok "include v3 neutralizado" || no "include v3 off"
g="$(cachy_active_tier 2>/dev/null || true)"; [[ "$g" == v4 ]] && ok "tier activo v4" || no "tier activo v4" "$g"
cachy_activate znver4 2>/dev/null && ok "znver4 rc 0" || no "znver4 rc 0"
grep -q '^\[cachyos-znver4\]$' "$R/etc/pacman.conf" && ok "znver4 activo" || no "znver4 activo"
g="$(cachy_active_tier 2>/dev/null || true)"; [[ "$g" == znver4 ]] && ok "tier activo znver4" || no "tier activo znver4" "$g"

echo "== C: sin marker no se toca =="
rm -f "$R/etc/pacman.d/cachyos-mirrorlist"
cachy_usable 2>/dev/null && no "usable sin mirrorlist" || ok "usable sin mirrorlist"
printf '[core]\nInclude = /etc/pacman.d/mirrorlist\n' > "$R/etc/pacman.conf"
cachy_activate v3 2>/dev/null && no "activa sin stanzas" || ok "activa sin stanzas rc 1"
cachy_active_tier 2>/dev/null && no "tier en base" || ok "tier en base rc 1"
grep -q '^\[core\]$' "$R/etc/pacman.conf" && ok "base intacta" || no "base intacta"

finish
