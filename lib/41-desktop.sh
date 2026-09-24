pkg_desktops() { # <pkg> -> rutas /usr/share/applications/*.desktop dentro de la imagen
    # L2: pacman --root prefija cada ruta con $ARXY_ROOT (en L1 salen
    # peladas): se recorta el prefijo para que el grep vea lo mismo.
    # ← ciclo 6.5.5 en Void-musl (L2): install/export decia "sin .desktop"
    # para todo paquete (Alacritty.desktop, org.xfce.mousepad.desktop).
    local f base
    while IFS= read -r f; do
        f="${f#$ARXY_ROOT}"
        base="${f##*/}"
        [[ "$f" == "/usr/share/applications/$base" && "$base" == *.desktop ]] && printf '%s\n' "$f"
    done < <(run_pacman -Qlq "$1" 2>/dev/null || true)
    return 0
}

desk_field() { grep -m1 -E "^$2=" "$1" | cut -d= -f2-; }

# cmd_export <pkg | archivo.desktop | --all>
cmd_export() {
    [[ $# -eq 1 ]] || die "uso: $PROG export <paquete | archivo.desktop | --all>"
    # Sin flags a run_pacman (-Qlq pasaria la opcion a pacman).
    [[ "$1" == -* && "$1" != --all ]] && die "opcion no soportada en export: '$1'"
    # el nombre de paquete se valida ANTES de ensure_image (un "a b"
    # moria en pacman tras descargar; un "" daba "sin .desktop" rc 0).
    # Rutas .desktop sí pueden llevar espacios: no se validan.
    if [[ "$1" != --all && "$1" != *.desktop ]]; then check_pkg_name "$1"; fi
    ensure_image
    local -a srcs=()
    if [[ "$1" == "--all" ]]; then
        mapfile -t srcs < <(find "$ARXY_ROOT/usr/share/applications" -maxdepth 1 -name '*.desktop' 2>/dev/null || true)
    elif [[ "$1" == *.desktop ]]; then
        local desk="${1##*/}"
        if [[ -f "$ARXY_ROOT/usr/share/applications/$desk" ]]; then
            srcs=("$ARXY_ROOT/usr/share/applications/$desk")
        elif [[ -f "$1" ]]; then
            srcs=("$1")
        else
            die "no existe paquete ni archivo '$1' (buscado como paquete y en $ARXY_ROOT/usr/share/applications/; prueba '$PROG search $1')"
        fi
    else
        local d
        while IFS= read -r d; do
            srcs+=("$ARXY_ROOT$d")
        done < <(pkg_desktops "$1")
        [[ "${#srcs[@]}" -gt 0 ]] || { msg "sin .desktop para '$1'"; return 0; }
    fi
    local s lbl
    for s in "${srcs[@]}"; do
        # export --all / <archivo.desktop> etiquetaba con el
        # literal ("--all", "foo.desktop") y remove nunca lo encontraba
        # (solo borra por nombre exacto de paquete). Deducir por fichero
        # con la misma funcion que migrate (idempotente).
        if [[ "$1" == --all || "$1" == *.desktop ]]; then
            lbl="$(_desktop_infer_pkg "$s")"
            [[ -n "$lbl" ]] || lbl="$1"
            export_one "$s" "$lbl"
        else
            export_one "$s" "$1"
        fi
    done
    update_desktop_db
}

export_one() { # <ruta.desktop del host> <pkg|nombre>
    local src="$1" pkg="$2" base name exec bin codes icon term cats comment out tmp
    base="${src##*/}"
    [[ -f "$src" ]] || return 0
    name="$(desk_field "$src" Name)"
    exec="$(desk_field "$src" Exec)"
    [[ -n "$name" && -n "$exec" ]] || return 0
    [[ "$(desk_field "$src" NoDisplay)" == "true" ]] && return 0
    bin="${exec%% *}"
    bin="${bin#\"}"; bin="${bin%\"}" # Exec="/ruta/con espacios" %F
    bin="${bin#\'}"; bin="${bin%\'}"
    if [[ "$bin" != /* ]]; then
        for cand in "/usr/bin/$bin" "/usr/local/bin/$bin" "/bin/$bin" "/usr/sbin/$bin"; do
            [[ -x "$ARXY_ROOT$cand" ]] && { bin="$cand"; break; }
        done
    fi
    codes="$(grep -o '%[A-Za-z]' <<<"$exec" | tr '\n' ' ' | sed 's/ *$//' || true)"
    local new_exec="$PROG run $bin"
    [[ -n "${codes// /}" ]] && new_exec="$new_exec $codes"
    icon="$(desk_field "$src" Icon)"
    if [[ -n "$icon" ]]; then
        if [[ "$icon" == /* && -f "$ARXY_ROOT$icon" ]]; then
            icon="$ARXY_ROOT$icon"
        elif [[ "$icon" != */* ]]; then
            local found
            found="$(find "$ARXY_ROOT/usr/share/icons" "$ARXY_ROOT/usr/share/pixmaps" \
                -name "$icon.*" 2>/dev/null | head -n 1 || true)"
            [[ -n "$found" ]] && icon="$found"
        fi
    fi
    term="$(desk_field "$src" Terminal)"
    cats="$(desk_field "$src" Categories)"
    comment="$(desk_field "$src" Comment)"
    mkdir -p "$REAL_APPS"
    out="$REAL_APPS/arxy-$base"
    tmp="$(mktemp "$REAL_APPS/.arxy-desktop.XXXXXX" 2>/dev/null)" \
        || { msg "aviso: no pude crear lanzador temporal en $REAL_APPS" >&2; return 1; }
    {
        echo "[Desktop Entry]"
        echo "Name=$name"
        [[ -n "$comment" ]] && echo "Comment=$comment"
        echo "Exec=$new_exec"
        echo "TryExec=$(command -v "$PROG" 2>/dev/null || echo "/usr/bin/$PROG")"
        [[ -n "$icon" ]] && echo "Icon=$icon"
        echo "Terminal=${term:-false}"
        echo "Type=Application"
        [[ -n "$cats" ]] && echo "Categories=$cats"
        echo "X-Arxy-Pkg=$pkg"
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 0644 "$tmp" 2>/dev/null || true
    if [[ "$(id -u)" -eq 0 && "$REAL_USER" != "root" ]]; then
        chown "$REAL_USER" "$tmp" 2>/dev/null || true
    fi
    mv -f "$tmp" "$out" || { rm -f "$tmp"; return 1; }
    msg "lanzador: ${out##*/}  ($name)"
}

_desktop_infer_pkg() { # <ruta arxy-*.desktop> -> imprime el pkg inferido
    local base="${1##*/}"
    base="${base#arxy-}"
    base="${base%.desktop}"
    # Multi-desktop (p. ej. xterm trae xterm+uxterm con X-Arxy-Pkg=xterm):
    # el nombre solo aproxima; el proximo install/export lo corrige.
    [[ -n "$base" ]] || base="unknown"
    printf '%s' "$base"
}

_desktop_tag_missing() { # <ruta> -> imprime pkg si migro; rc 1 si ya tenia tag
    local f="$1" pkg
    grep -q '^X-Arxy-Pkg=' "$f" 2>/dev/null && return 1
    pkg="$(_desktop_infer_pkg "$f")"
    [[ -n "$(tail -c 1 "$f" 2>/dev/null)" ]] && printf '\n' >>"$f"
    printf 'X-Arxy-Pkg=%s\n' "$pkg" >>"$f"
    printf '%s' "$pkg"
    return 0
}

cmd_desktop_migrate() { # etiqueta legacy sin X-Arxy-Pkg (idempotente)
    local f n=0 s=0 pkg
    shopt -s nullglob
    for f in "$REAL_APPS"/arxy-*.desktop; do
        if pkg="$(_desktop_tag_missing "$f")"; then
            msg "migrate: ${f##*/} -> X-Arxy-Pkg=$pkg"
            n=$((n + 1))
        else
            s=$((s + 1))
        fi
    done
    shopt -u nullglob
    msg "migrate: $n migrados, $s ya al día"
}

desktop_migrate_auto() { # tras install/update: aviso a stderr, nunca falla
    # Solo añade el tag (no toca Name/Exec): no requiere update-desktop-database.
    local f n=0
    shopt -s nullglob
    for f in "$REAL_APPS"/arxy-*.desktop; do
        _desktop_tag_missing "$f" >/dev/null && n=$((n + 1)) || true
    done
    shopt -u nullglob
    if ((n > 0)); then
        printf 'arxy: aviso: %d lanzadores legacy migrados (X-Arxy-Pkg)\n' "$n" >&2
    fi
    return 0
}

cmd_desktop() { # desktop --migrate
    [[ $# -eq 1 ]] || die "uso: $PROG desktop --migrate (ver: $PROG help)"
    case "${1:-}" in
        --migrate) cmd_desktop_migrate ;;
        *) die "uso: $PROG desktop --migrate (ver: $PROG help)" ;;
    esac
}

cmd_unexport() {
    [[ $# -eq 1 ]] || die "uso: $PROG unexport <nombre>"
    local f base="$1"
    base="${base##*/}"
    base="${base%.desktop}"
    f="$REAL_APPS/arxy-$base.desktop"
    [[ -f "$f" ]] || die "no existe lanzador arxy-$base.desktop"
    rm -f "$f" && msg "lanzador borrado: arxy-$base.desktop"
    update_desktop_db
}

update_desktop_db() {
    local updater
    updater="$(command -v update-desktop-database)" || return 0
    [[ -d "$REAL_APPS" ]] || return 0
    if [[ "$(id -u)" -eq 0 && "$REAL_USER" != "root" ]]; then
        su -s /bin/sh -c 'exec "$1" "$2"' "$REAL_USER" sh "$updater" "$REAL_APPS" >/dev/null 2>&1 || true
    else
        "$updater" "$REAL_APPS" >/dev/null 2>&1 || true
    fi
}
