#!/usr/bin/env bash
# test-perf.sh — presupuesto de forks por comando (L3, determinista).
# Shims en PATH que registran cada exec externo y delegan al binario real;
# se miden solo cotas SUPERIORES (no tiempos, no valores exactos: varian
# segun toolchain). Si alguien mete un fork en el hot path, esto cae.
# Sin root ni imagen: root falso + casos sin estado; `run` solo si L1
# responde aqui (si no: SKIP honesto, la matrix lo mide en L1 real).
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
# shellcheck source=lib.sh
. "$HERE/lib.sh" # ok/no/finish + ARXY_BIN
D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT
SHIM="$D/sh"; LOG="$D/log"; mkdir -p "$SHIM"
export LOG
for c in id cut getent grep readlink uname tr sed awk sort uniq stat file ldd bwrap unshare sudo du find xargs sha256sum cksum cmp comm flock; do
    r="$(command -v "$c" 2>/dev/null)" || continue
    printf '#!/bin/sh\necho "%s" >> "$LOG"\nexec "%s" "$@"\n' "$c" "$r" > "$SHIM/$c"
    chmod +x "$SHIM/$c"
done
export PATH="$SHIM:$PATH"
R="$D/root"
arxy_mkroot "$R"
# DRM/dev vacios para todo el test: sin NVIDIA el path es determinista
# (con GPU real, file/stat/ldd entrarian y la cota no valdria).
mkdir -p "$D/drm" "$D/dev"
export ARXY_SYS_DRM_PATH="$D/drm" ARXY_DEV_PATH="$D/dev"
BIN="${ARXY_BIN:-$HERE/../src/arxy}"

count_execs() { # <var-n> : cuenta lineas de LOG solo con builtins
    local -n _n="$1" _
    _n=0
    while IFS= read -r _; do _n=$((_n + 1)); done < "$LOG"
}
measure() { # <cmd...> : trunca LOG y corre el CLI aislado (sin estado)
    : > "$LOG"
    ARXY_ROOT="$R" HOME="$D/home" XDG_CONFIG_HOME="$D/home/.config" "$BIN" "$@" >/dev/null 2>&1 || true
}
check_budget() { # <nombre> <cota> : n <= cota
    local name="$1" max="$2" n
    count_execs n
    if [[ "$n" -le "$max" ]]; then ok "$name: $n <= $max";
    else no "$name: $n <= $max" "$(sort "$LOG" | uniq -c | sort -rn | head -n 5 | tr '\n' ';')"; fi
}

echo "== baseline 00-head (sin estado, sin red) =="
measure help; check_budget "help" 12
measure version; check_budget "version" 12
measure install; check_budget "install sin args" 12
measure version --verbose; check_budget "version --verbose" 70

echo "== run L1: presupuesto + sin file/stat/ldd sin NVIDIA =="
if bwrap --ro-bind / / /bin/true 2>/dev/null; then
    : > "$LOG"
    ARXY_ROOT="$R" HOME="$D/home" XDG_CONFIG_HOME="$D/home/.config" \
        "$BIN" run /usr/bin/true >/dev/null 2>&1 || true
    check_budget "run L1" 25
    for heavy in file stat ldd; do
        if grep -qx "$heavy" "$LOG"; then no "run sin $heavy (sin DRM)"; else ok "run sin $heavy (sin DRM)"; fi
    done
else
    echo "SKIP: run L1 (sin userns aqui; la matrix lo mide)"
fi

finish
