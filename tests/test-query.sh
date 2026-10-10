#!/usr/bin/env bash
# test-query.sh — parseo info/list/search/search-aur con stubs (L2).
# Sin root, imagen, red ni AUR: run_pacman/in_sys falsos; run_pacman REAL
# solo para la plomeria L1/L2 (in_bwrap/in_sys stubbed que registran).
# Cada rama muere en `uso:` con args malos antes de privilegios/estado/red.
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
# shellcheck source=lib.sh
. "$HERE/lib.sh" # ok/no/t/te/finish
D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT
R="$D/root"
export ARXY_ROOT="$R"
# shellcheck source=../lib/00-head.sh
. "$HERE/../lib/00-head.sh" >/dev/null 2>&1
# shellcheck source=../lib/20-state.sh
. "$HERE/../lib/20-state.sh" >/dev/null 2>&1
# shellcheck source=../lib/21-setup.sh
. "$HERE/../lib/21-setup.sh" >/dev/null 2>&1
# shellcheck source=../lib/10-level.sh
. "$HERE/../lib/10-level.sh" >/dev/null 2>&1
# shellcheck source=../lib/40-query.sh
. "$HERE/../lib/40-query.sh" >/dev/null 2>&1
REAL_APPS="$D/apps"; mkdir -p "$REAL_APPS" "$R/tmp"
arxy_mkroot_ver "$R" "file:///t.tar.zst" "abc"
printf '[options]\nArchitecture = auto\n[core]\nInclude = /etc/pacman.d/mirrorlist\n' > "$R/etc/pacman.conf"
# Clon del run_pacman real para F: B-E lo pisan con stubs.
eval "$(declare -f run_pacman | sed '1s/^run_pacman/real_run_pacman/')"

echo "== A: validacion de args antes de nada (uso: a stderr, rc != 0) =="
chk_uso() { # <nombre> <fn> [args...] : espera "uso:" + rc != 0
    local name="$1"; shift; local fn="$1"; shift
    local out rc
    out="$("$fn" "$@" 2>&1)"; rc=$?
    if grep -q 'uso:' <<<"$out" && [[ "$rc" != 0 ]]; then ok "uso: $name";
    else no "uso: $name" "rc=$rc [$out]"; fi
}
chk_uso "info sin args" cmd_info
chk_uso "info con 2" cmd_info a b
chk_uso "list con args" cmd_list x
chk_uso "search sin args" cmd_search
chk_uso "search-aur sin args" cmd_search_aur

echo "== B: list etiqueta [desktop] y respeta vacio/error =="
run_pacman() { printf 'firefox 130.0-1\nhtop 3.4-1\n'; }
printf '[Desktop Entry]\nX-Arxy-Pkg=firefox\n' > "$REAL_APPS/arxy-firefox.desktop"
out="$(cmd_list)"
grep -qxF 'firefox 130.0-1  [desktop]' <<<"$out" && ok "list etiqueta firefox" || no "list etiqueta" "$out"
grep -qxF 'htop 3.4-1' <<<"$out" && ok "list sin etiqueta htop" || no "list htop" "$out"
run_pacman() { return 0; } # vacio legitimo: silencio + rc 0
out="$(cmd_list)"; rc=$?
[[ -z "$out" && "$rc" == 0 ]] && ok "list vacio rc 0" || no "list vacio" "rc=$rc [$out]"
run_pacman() { echo "db bloqueada" >&2; return 1; } # db rota: el error sale
out="$(cmd_list 2>&1)"; rc=$?
[[ "$rc" != 0 && "$out" == *db* ]] && ok "list error no tragado" || no "list error" "rc=$rc [$out]"

echo "== C: info cae de -Qi a -Si =="
CALLS="$D/calls"
run_pacman() {
    printf '%s\n' "$*" >>"$CALLS"
    if [[ "$1" == -Qi ]]; then echo "no instalado" >&2; return 1; fi
    printf 'Repos   : extra\nNombre  : %s\n' "$2"
}
: > "$CALLS"
out="$(cmd_info vim)"
grep -q '^Nombre  : vim$' <<<"$out" && ok "info -Si contenido" || no "info -Si" "$out"
[[ "$(head -n 1 "$CALLS")" == "-Qi vim" && "$(sed -n '2p' "$CALLS")" == "-Si vim" ]] \
    && ok "info orden -Qi -> -Si" || no "info orden" "$(tr '\n' '|' <"$CALLS")"
run_pacman() { printf 'Instalado : %s\n' "$2"; }
out="$(cmd_info vim)"
grep -q '^Instalado : vim$' <<<"$out" && ok "info -Qi sin fallback" || no "info -Qi" "$out"

echo "== D: search pasa a pacman tal cual =="
run_pacman() { printf 'extra/firefox 130.0-1\n'; return 0; }
out="$(cmd_search firefox)"; rc=$?
[[ "$rc" == 0 ]] && grep -q '^extra/firefox' <<<"$out" && ok "search passthrough" || no "search" "rc=$rc [$out]"
run_pacman() { echo "sin red" >&2; return 1; }
cmd_search firefox >/dev/null 2>&1; rc=$?
[[ "$rc" != 0 ]] && ok "search propaga rc" || no "search rc"

echo "== E: search-aur exige jq, luego paru o RPC =="
in_sys() { echo "IN_SYS_INESPERADO $*" >&2; return 1; }
chk_uso "search-aur sin args (antes de red)" cmd_search_aur
in_sys() { [[ "$1" == /usr/bin/jq ]] && return 1 || return 0; }
out="$(cmd_search_aur spotify 2>&1 || true)"
grep -q 'falta jq' <<<"$out" && ok "search-aur sin jq muere claro" || no "search-aur jq" "$out"
unset HAVE_PARU HAVE_PARU_CHECKED
in_sys() {
    printf '%s\n' "$*" >>"$CALLS"
    case "$1" in
        /usr/bin/jq) return 0 ;;
        /usr/bin/paru) printf 'aur/spotify-bin 1.2 [votos:9]\n'; return 0 ;;
        *) return 1 ;;
    esac
}
: > "$CALLS"
out="$(cmd_search_aur spotify)"
grep -q '^aur/spotify-bin' <<<"$out" && ok "search-aur via paru" || no "search-aur paru" "$out"
grep -q '/usr/bin/paru -Ss spotify' "$CALLS" && ok "search-aur llama paru -Ss" || no "search-aur args" "$(tr '\n' '|' <"$CALLS")"
unset HAVE_PARU HAVE_PARU_CHECKED
HAVE_PARU_CHECKED=1; HAVE_PARU=
in_sys() {
    printf '%s\n' "$*" >>"$CALLS"
    case "$1" in
        # jq stub DRENA stdin (cat): sin lector, el curl del pipe muere por
        # SIGPIPE y con pipefail el pipeline da 141 (flake, ver AGENTS.md).
        /usr/bin/jq) cat >/dev/null; return 0 ;;
        /usr/bin/curl) printf '{"results":[]}'; return 0 ;;
        *) return 1 ;;
    esac
}
: > "$CALLS"
cmd_search_aur spotify >/dev/null 2>&1
grep -q 'aur.archlinux.org/rpc' "$CALLS" && ok "search-aur sin paru usa RPC" || no "search-aur RPC" "$(tr '\n' '|' <"$CALLS")"
grep -q '/usr/bin/jq -r' "$CALLS" && ok "search-aur RPC pasa por jq" || no "search-aur jq-pipe" "$(tr '\n' '|' <"$CALLS")"
unset HAVE_PARU HAVE_PARU_CHECKED

echo "== F: plomeria L1/L2 del run_pacman real (stubs registran) =="
# real_run_pacman: clon de la funcion sourceada (los stubs de B-E la
# pisan; unset -f la borraria del todo). F corre ANTES de stubbearla... no:
# B-E ya la pisaron; por eso se clono arriba antes de B.
in_bwrap() { printf 'BWRAP %s\n' "$*" >>"$CALLS"; }
in_sys() { printf 'INSYS %s\n' "$*" >>"$CALLS"; }
unset _ARXY_LEVEL; export ARXY_LEVEL=1
: > "$CALLS"
real_run_pacman -Q >/dev/null 2>&1
grep -qxF 'BWRAP /usr/bin/pacman -Q' "$CALLS" && ok "L1: pacman directo en bwrap" || no "L1 plomeria" "$(tr '\n' '|' <"$CALLS")"
unset _ARXY_LEVEL; export ARXY_LEVEL=2
: > "$CALLS"
real_run_pacman -Q >/dev/null 2>&1
grep -q "^INSYS /usr/bin/pacman --root $R --config .* --dbpath $R/var/lib/pacman -Q$" "$CALLS" \
    && ok "L2: pacman con --root+config+dbpath" || no "L2 plomeria" "$(tr '\n' '|' <"$CALLS")"
unset ARXY_LEVEL _ARXY_LEVEL

finish
