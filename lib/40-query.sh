# --- lectura (corre como usuario)
cmd_info() {
    [[ $# -eq 1 ]] || die "uso: $PROG info <paquete>"
    ensure_image
    run_pacman -Qi "$1" 2>/dev/null || run_pacman -Si "$1"
}

cmd_list() {
    [[ $# -eq 0 ]] || die "uso: $PROG list"
    ensure_image
    local exported line pkg q
    exported="$(grep -h '^X-Arxy-Pkg=' "$REAL_APPS"/arxy-*.desktop 2>/dev/null | cut -d= -f2- | sort -u || true)"
    # Sin process substitution: su rc no se propaga y una db rota daria
    # lista vacia con rc 0. Con captura el error sale (el vacio legitimo
    # salta el bucle: <<<"" iteraria una vez con linea vacia).
    q="$(run_pacman -Q "$@")" || return $?
    [[ -n "$q" ]] || return 0
    while IFS= read -r line; do
        pkg="${line%% *}"
        if grep -qxF "$pkg" <<<"$exported" 2>/dev/null; then
            echo "$line  [desktop]"
        else
            echo "$line"
        fi
    done <<<"$q"
}

cmd_search() {
    [[ $# -ge 1 ]] || die "uso: $PROG search <texto>"
    ensure_image
    run_pacman -Ss "$@"
}

cmd_search_aur() {
    [[ $# -ge 1 ]] || die "uso: $PROG search-aur <texto>"
    ensure_image
    in_sys /usr/bin/jq --version >/dev/null 2>&1 || \
        die "falta jq en la imagen: $PROG install jq"
    if [[ -z "${HAVE_PARU_CHECKED:-}" ]]; then
        in_sys /usr/bin/paru --version >/dev/null 2>&1 && HAVE_PARU=1 || HAVE_PARU=
        HAVE_PARU_CHECKED=1
    fi
    if [[ -n "${HAVE_PARU:-}" ]]; then
        in_sys /usr/bin/paru -Ss "$@"
        return
    fi
    # Sin paru: RPC de AUR directo (https://wiki.archlinux.org/title/Aurweb_RPC_interface)
    local q
    q="$(printf '%s ' "$@" | sed 's/ $//')"
    in_sys /usr/bin/curl -sfL --get --data-urlencode "v=5" --data-urlencode "type=search" \
        --data-urlencode "by=name-desc" --data-urlencode "arg=$q" \
        https://aur.archlinux.org/rpc/ 2>/dev/null | \
    in_sys /usr/bin/jq -r '.results[] | "\(.Name) \(.Version) [votos:\(.NumVotes) popularidad:\(.Popularity|floor)]\n    \(.Description // "")"' 2>/dev/null || \
        die "fallo la busqueda AUR de '$q' en https://aur.archlinux.org/rpc/ (¿red? cero resultados no es error)"
}
