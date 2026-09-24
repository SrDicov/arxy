#!/usr/bin/env bash
# test-split-brain.sh — el env congelado manda y los derivados
# cuelgan del ROOT final, en un solo punto.
# Sin el orden correcto (_restore_frozen ANTES de derivar, en ambos
# restores), setup extrae en un root y escribe version/level2-rc en
# otro, con tests en verde (estado envenenado). Sin root, sin red,
# sin imagen: sondas con HOME aislado + tripwire estatico.
set -uo pipefail
FAIL=0
SKIP=0
HERE="$(dirname "$0")"
LIB="$HERE/../lib/00-head.sh"
D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT

probe() { # <home> <env-root> -> lineas ROOT=/DATA=/BUILD=/VFILE=
    local home="$1" root="$2"
    HOME="$home" XDG_CONFIG_HOME="$home/.config" ARXY_ROOT="$root" \
        bash -c 'set --; . "$0" >/dev/null 2>&1; printf "ROOT=%s\nDATA=%s\nBUILD=%s\nVFILE=%s\n" "$ARXY_ROOT" "$ARXY_DATA" "$ARXY_BUILD" "$ARXY_VERSION_FILE"' "$LIB"
}

# T1: env manda sobre user-conf y DATA deriva del env (no del conf).
mkdir -p "$D/h1/.config/arxy"
printf 'ARXY_ROOT="/tmp/sb-conf/root"\n' > "$D/h1/.config/arxy/config"
OUT="$(probe "$D/h1" "/tmp/sb-env/root")"
echo "$OUT" | grep -qx "ROOT=/tmp/sb-env/root" && echo "PASS: T1 env ROOT sobrevive al user-conf" || { echo "FAIL: T1 env ROOT (vease arriba)"; echo "$OUT"; FAIL=$((FAIL+1)); }
echo "$OUT" | grep -qx "DATA=/tmp/sb-env" && echo "PASS: T1 DATA deriva del env, no del conf" || { echo "FAIL: T1 DATA split-brain"; echo "$OUT"; FAIL=$((FAIL+1)); }
echo "$OUT" | grep -qx "BUILD=/tmp/sb-env/build" && echo "PASS: T1 BUILD deriva del env" || { echo "FAIL: T1 BUILD"; echo "$OUT"; FAIL=$((FAIL+1)); }
echo "$OUT" | grep -qx "VFILE=/tmp/sb-env/root/var/lib/arxy/version" && echo "PASS: T1 VFILE dentro del root aislado" || { echo "FAIL: T1 VFILE"; echo "$OUT"; FAIL=$((FAIL+1)); }

# T2: tripwire estatico — derivacion en UN solo punto (contenido, no rc).
[[ "$(grep -h '^ARXY_DATA=' "$HERE"/../lib/*.sh | wc -l)" == "1" ]] && echo "PASS: T2 ARXY_DATA se asigna en un solo punto" || { echo "FAIL: T2 doble derivacion de ARXY_DATA"; FAIL=$((FAIL+1)); }
[[ "$(grep -h '^ARXY_BUILD=' "$HERE"/../lib/*.sh | wc -l)" == "1" ]] && echo "PASS: T2 ARXY_BUILD se asigna en un solo punto" || { echo "FAIL: T2 doble derivacion de ARXY_BUILD"; FAIL=$((FAIL+1)); }

# T3: segundo restore (ruta root con user-conf del usuario real).# Solo con sudo sin password; si no, SKIP honesto (no se finge).
mkdir -p "$D/h3/.config/arxy"
printf 'ARXY_ROOT="/tmp/sb3-conf/root"\n' > "$D/h3/.config/arxy/config"
if sudo -n true 2>/dev/null; then
    OUT3="$(sudo -n env "HOME=$D/h3" "XDG_CONFIG_HOME=" "SUDO_USER=nobody" "ARXY_ROOT=/tmp/sb3-env/root" \
        bash -c 'set --; . "$0" >/dev/null 2>&1; printf "ROOT=%s\nDATA=%s\n" "$ARXY_ROOT" "$ARXY_DATA"' "$LIB" 2>/dev/null)"
    echo "$OUT3" | grep -qx "ROOT=/tmp/sb3-env/root" && echo "PASS: T3 env sobrevive al segundo restore" || { echo "FAIL: T3 segundo restore piso el env"; echo "$OUT3"; FAIL=$((FAIL+1)); }
    echo "$OUT3" | grep -qx "DATA=/tmp/sb3-env" && echo "PASS: T3 DATA post-segundo-restore" || { echo "FAIL: T3 DATA tras segundo restore"; echo "$OUT3"; FAIL=$((FAIL+1)); }
else
    echo "SKIP: T3 exige sudo -n (segundo restore solo corre como root)"
    SKIP=$((SKIP+1))
fi

# T4: ARXY_ROOT vacio muere en vez de colapsar al real.
if HOME="$D/h1" XDG_CONFIG_HOME="$D/h1/.config" ARXY_ROOT="" bash -c '. "$0" >/dev/null 2>&1' "$LIB" 2>/dev/null; then
    echo "FAIL: T4 ARXY_ROOT vacio aceptado"; FAIL=$((FAIL+1))
else
    echo "PASS: T4 ARXY_ROOT vacio rechazado"
fi

# T5: las operaciones destructivas asumen una raiz absoluta y nunca '/'.
for bad_root in / relative/root; do
    if HOME="$D/h1" XDG_CONFIG_HOME="$D/h1/.config" ARXY_ROOT="$bad_root" bash -c '. "$0" >/dev/null 2>&1' "$LIB" 2>/dev/null; then
        echo "FAIL: T5 ARXY_ROOT inseguro aceptado: $bad_root"; FAIL=$((FAIL+1))
    else
        echo "PASS: T5 ARXY_ROOT inseguro rechazado: $bad_root"
    fi
done

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")${SKIP:+ ($SKIP SKIP)}"
exit $FAIL
