#!/usr/bin/env bash
# test-surface.sh — acuerdo help<->dispatch<->bundles<->template<->install.sh (L0).
# Pinea la clase de deriva que el split multi-binario introduce: ramas del
# dispatch sin bundle, bundles sin B_* en el Makefile, generados desfasados
# de lib/, packaging/install.sh con listas viejas, canonicos sin trailer.
# Sin root, sin red, sin imagen: todo estatico + `help` (no toca estado).
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
# shellcheck source=lib.sh
. "$HERE/lib.sh" # ok/no/finish + ARXY_BIN (default: src/arxy del repo)
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 1
BIN="${ARXY_BIN:-$ROOT/src/arxy}"

# Pares (bundle canonico) del dispatch, uno por linea "bundle canonico".
# [_a-z-] con primer char obligatorio (con * puro, __install-file daria
# canonico vacio) e incluye _ por el canonico interno __install-file.
dispatch_pairs() {
    grep -o '_arxy_exec [_a-z-][_a-z-]* [_a-z-][_a-z-]*' lib/zz-dispatch.sh | awk '{print $2, $3}' | sort -u
}
dispatch_bundles() { dispatch_pairs | awk '{print $1}' | sort -u; }

echo "== A: cada bundle del dispatch existe, es ejecutable y pasa bash -n =="
for b in $(dispatch_bundles); do
    if [[ -x "src/arxy-$b" ]]; then ok "bundle src/arxy-$b ejecutable"; else no "bundle src/arxy-$b" "falta o sin +x"; continue; fi
    if bash -n "src/arxy-$b" 2>/dev/null; then ok "bash -n arxy-$b"; else no "bash -n arxy-$b"; fi
done
[[ -x src/arxy ]] && ok "shim src/arxy ejecutable" || no "shim src/arxy"
bash -n src/arxy 2>/dev/null && ok "bash -n shim" || no "bash -n shim"

echo "== B: Makefile B_* existe, lista ficheros reales y regenera byte-identico =="
mfiles() { # <varname> : ficheros de la var del Makefile (continuaciones con \)
    # Con awk, no con rango sed: en sed BSD el patron de fin no casa en la
    # propia linea de inicio y el rango se traga la variable siguiente.
    awk -v want="$1 =" '
        $0 ~ "^" want { grab=1; sub("^" want, "") }
        grab { line = line $0 " "; if ($0 !~ /\\$/) exit }
        END { gsub(/\\/, "", line); print line }
    ' Makefile
}
sorted() { tr ' ' '\n' <<<"$1" | grep -v '^$' | sort | tr '\n' ' '; }
D_catdir="$(mktemp -d)"; trap 'rm -rf "$D_catdir"' EXIT
D_cat="$D_catdir/cat.tmp"
for b in $(dispatch_bundles); do
    files="$(mfiles "B_$b")"
    if [[ -z "${files// /}" ]]; then no "B_$b definido en Makefile"; continue; fi
    ok "B_$b definido"
    bad=""
    for f in $files; do [[ -f "$f" ]] || bad="$bad $f"; done
    if [[ -z "$bad" ]]; then ok "B_$b: ficheros existen"; else no "B_$b: faltan:$bad"; continue; fi
    # shellcheck disable=SC2086 # lista de ficheros sin espacios a proposito
    if cat $files >"$D_cat" 2>/dev/null && cmp -s "$D_cat" "src/arxy-$b"; then
        ok "arxy-$b regenera identico"
    else
        no "arxy-$b desfasado de lib/ (repite el build y commitea)"
    fi
    last=""
    for f in $files; do last="$f"; done
    [[ "$last" == "lib/exec-$b.sh" ]] && ok "B_$b cierra con su trailer" || no "B_$b trailer final" "$last"
done

echo "== B2: sin globales muertas en 00-head (compensa SC2034 desactivado) =="
# SC2034 esta desactivado por el split (ver 00-head.sh): una global sin uso
# en un bundle pequeno es normal. Lo que se pinea es que el conjunto no
# CREZCA: subconjunto del maximo conocido (encoger vale = alguien la usa).
# Mencion textual ($VAR o ${VAR}; la auto-asignacion VAR="${VAR:-...}" ya
# cuenta). Aproximacion deliberada: comentarios tambien cuentan.
dead_of() { # <bundle> : globales de 00-head sin mencion en src/arxy-<bundle>
    local g
    for g in $GLOBALS; do
        grep -qF "\$$g" "src/arxy-$1" 2>/dev/null \
        || grep -qF "\${$g" "src/arxy-$1" 2>/dev/null \
        || printf '%s\n' "$g"
    done
}
GLOBALS="$(grep -oE '^[A-Z][A-Z0-9_]*=' lib/00-head.sh | tr -d '=' | tr '\n' ' ')"
pinned_dead() { # <bundle> : maximo conocido, uno por linea
    case "$1" in
        bridge|help) printf '%s\n' ARXY_BUILD ARXY_LIBPATH LD_LINUX NS_BUILD REAL_APPS ;;
        run) printf '%s\n' REAL_APPS ;;
        *) return 0 ;; # bundles gordos: cero muertas
    esac
}
for b in $(dispatch_bundles); do
    extra="$(LC_ALL=C comm -23 <(dead_of "$b" | LC_ALL=C sort -u) <(pinned_dead "$b" | LC_ALL=C sort -u))"
    if [[ -z "$extra" ]]; then ok "$b sin globales muertas nuevas";
    else no "$b globales muertas nuevas" "$(tr '\n' ' ' <<<"$extra")"; fi
done

echo "== C: listas de bundles identicas (dispatch, Makefile, install.sh, template) =="
want="$(dispatch_bundles | tr '\n' ' ')"
mkb="$(grep '^BUNDLES =' Makefile | sed 's/^BUNDLES =//')"
[[ "$(sorted "$mkb")" == "$(sorted "$want")" ]] \
    && ok "Makefile BUNDLES == dispatch" || no "Makefile BUNDLES" "$mkb"
ins="$(grep -o 'for _b in [^;]*' install.sh | head -n 1 | sed 's/^for _b in //')"
[[ "$(sorted "$ins")" == "$(sorted "$want")" ]] \
    && ok "install.sh cubre todos los bundles" || no "install.sh bundles" "$ins"
tpl="$(grep -o 'for _b in [^;]*' packaging/void/arxy/template | head -n 1 | sed 's/^for _b in //')"
[[ "$(sorted "$tpl")" == "$(sorted "$want")" ]] \
    && ok "template xbps cubre todos los bundles" || no "template bundles" "$tpl"

echo "== D: dispatch <- -> trailers (canonicos y aliases, ambas direcciones) =="
trailer_cmds() { # <bundle> : comandos del trailer (sin el brazo de error *)
    awk -F')' '/_entry=cmd_/ && $1 !~ /\*/ {
        gsub(/^[ \t]+/, "", $1); n = split($1, a, "|")
        for (i = 1; i <= n; i++) { gsub(/[ \t]/, "", a[i]); if (a[i] != "") print a[i] }
    }' lib/exec-"$1".sh
}
dispatch_arms() { # "bundle canon;alias alias" por brazo case del dispatch
    grep -E '^[[:space:]]*[^ #][^)]*\)[[:space:]]*_arxy_exec [_a-z-]+ [_a-z-]+' lib/zz-dispatch.sh | while IFS= read -r line; do
        lhs="${line%%)*}"
        rhs="$(printf '%s' "$line" | sed 's/.*_arxy_exec \([_a-z-][_a-z-]*\) \([_a-z-][_a-z-]*\).*/\1 \2/')"
        al="$(printf '%s' "$lhs" | tr '|' '\n' | tr -d '[:blank:]' | tr '\n' ' ')"
        printf '%s;%s\n' "$rhs" "$al"
    done
}
ARMS="$(dispatch_arms)"
for b in $(dispatch_bundles); do
    tcmds="$(trailer_cmds "$b" | LC_ALL=C sort -u)"
    [[ -n "$tcmds" ]] || { no "trailer $b vacio"; continue; }
    dalias="$(printf '%s\n' "$ARMS" | awk -F';' -v b="$b" '$1 ~ "^" b " " {print $2}' | tr ' ' '\n' | grep -v '^$' | grep -v '^\*$' | LC_ALL=C sort -u)"
    miss="$(LC_ALL=C comm -23 <(printf '%s\n' "$dalias") <(printf '%s\n' "$tcmds"))"
    if [[ -z "$miss" ]]; then ok "dispatch ⊆ trailer $b";
    else no "trailer $b sin aliases" "$(tr '\n' ' ' <<<"$miss")"; fi
    dead="$(LC_ALL=C comm -13 <(printf '%s\n' "$dalias") <(printf '%s\n' "$tcmds"))"
    if [[ -z "$dead" ]]; then ok "trailer $b sin brazos muertos";
    else no "trailer $b brazos muertos" "$(tr '\n' ' ' <<<"$dead")"; fi
    cmiss=""
    while IFS=';' read -r bc _rest; do
        c="${bc##* }"
        grep -qxF "$c" <<<"$tcmds" || cmiss="$cmiss $c"
    done < <(printf '%s\n' "$ARMS" | awk -F';' -v b="$b" '$1 ~ "^" b " "')
    if [[ -z "$cmiss" ]]; then ok "$b canonicos en trailer";
    else no "$b canonicos en trailer" "$cmiss"; fi
done
for e in $(grep -ho '_entry=cmd_[a-z_]*' lib/exec-*.sh | sed 's/_entry=//' | sort -u); do
    if grep -rq "^${e}(" lib/ 2>/dev/null; then ok "$e definido"; else no "$e sin definir en lib/"; fi
done

echo "== E: help documenta cada canonico (salvo __install-file, interno) =="
hout="$("$BIN" help 2>&1)"
while read -r b c; do
    [[ -n "$b" ]] || continue
    [[ "$c" == __install-file ]] && continue
    if grep -qwF "$c" <<<"$hout"; then ok "help menciona $c"; else no "help menciona $c"; fi
done < <(dispatch_pairs)

echo "== F: version pineada lib == template =="
lv="$(grep '^ARXY_VERSION=' lib/00-head.sh | cut -d'"' -f2)"
tv="$(grep '^version=' packaging/void/arxy/template | cut -d= -f2)"
[[ -n "$lv" && "$lv" == "$tv" ]] && ok "version $lv en ambos" || no "version lib/template" "lib=$lv template=$tv"

echo "== G: packaging enSync con src/ y config/ (espejo de make verify) =="
if command -v cmp >/dev/null 2>&1; then
    for f in src/arxy*; do
        n="$(basename "$f")"
        if cmp -s "$f" "packaging/void/arxy/files/$n"; then ok "sync $n";
        else no "sync $n" "difiere (repite make sync)"; fi
    done
    cmp -s config/arxy.conf packaging/void/arxy/files/arxy.conf \
        && ok "sync arxy.conf" || no "sync arxy.conf"
    cmp -s config/arxy.pub packaging/void/arxy/files/arxy.pub \
        && ok "sync arxy.pub" || no "sync arxy.pub"
else
    echo "SKIP: G sin cmp en este host"
fi

echo "== H: alias axy en install.sh y template =="
grep -q 'axy' install.sh && ok "install.sh crea axy" || no "install.sh crea axy"
grep -q 'axy' packaging/void/arxy/template && ok "template crea axy" || no "template crea axy"

finish
