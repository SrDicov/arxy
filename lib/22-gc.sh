# --- inventario y recoleccion de residuos
_gc_bytes() { # <path> : bytes en disco (0 si falta)
    local b
    b="$(du -sb "$1" 2>/dev/null | cut -f1)"
    echo "${b:-0}"
}

# Limpieza con JSON: informa siempre (exit 0); --apply purga.
# root.old VALIDO exige prompt tty (puede resucitarse) salvo --yes;
# root.old CORRUPTO se purga sin preguntar (no hay nada que recuperar).
cmd_gc() { # [--json] [--apply [--yes]]
    local use_json="" apply="" yes="" a
    for a in "$@"; do
        case "$a" in
            --json) use_json=1 ;;
            --apply) apply=1 ;;
            --yes) yes=1 ;;
            *) die "uso: $PROG gc [--json] [--apply [--yes]]" ;;
        esac
    done
    [[ -z "$yes" || -n "$apply" ]] || die "uso: $PROG gc [--json] [--apply [--yes]]"
    [[ -n "$apply" ]] && need_root
    [[ -n "$apply" ]] && data_lock # solo el apply muta (dry-run libre)
    local pkgdir="$ARXY_ROOT/var/cache/pacman/pkg"
    local old="$ARXY_ROOT.old"
    local old_present=0 old_valid=0 old_size=0
    if [[ -d "$old" ]]; then
        old_present=1; old_size="$(_gc_bytes "$old")"
        _image_ok "$old" 2>/dev/null && old_valid=1
    fi
    local cache_size build_size
    cache_size="$(_gc_bytes "$pkgdir")"
    build_size="$(_gc_bytes "$ARXY_BUILD")"
    local st_n=0 st_size=0 _sacc st_path st_b
    while IFS=$'\t' read -r _sacc st_path; do
        [[ -n "${st_path:-}" ]] || continue
        st_n=$((st_n + 1))
        st_b="$(_gc_bytes "$st_path")"
        st_size=$((st_size + st_b))
    done < <(staging_inventory)
    local total=$((old_size + cache_size + build_size + st_size))
    local applied=0 applied_bytes=0
    if [[ -n "$apply" ]]; then
        if (( old_present && old_valid )) && [[ -z "$yes" ]]; then
            [[ -t 0 ]] || die "gc --apply con rollback válido exige tty (usa --yes para no-interactivo)"
            local ans=""
            read -r -p "¿purgar $total bytes (incluye $old, recuperable con rollback)? [s/N] " ans
            if [[ "$ans" != [sS]* ]]; then msg "nada purgado"; return 0; fi
        elif (( total > 104857600 )) && [[ -z "$yes" ]]; then
            [[ -t 0 ]] || die "gc --apply de mas de 100 MB exige tty (usa --yes para no-interactivo)"
            local ans=""
            read -r -p "¿purgar $total bytes? [s/N] " ans
            if [[ "$ans" != [sS]* ]]; then msg "nada purgado"; return 0; fi
        fi
        recover_staging >/dev/null 2>&1
        [[ -d "$old" ]] && rm -rf "${old:?}" 2>/dev/null || true
        rm -f "$pkgdir"/* 2>/dev/null || true
        rm -rf "${ARXY_BUILD:?}" 2>/dev/null || true
        # gc --apply garantiza ARXY_BUILD existente (1777, como setup): el
        # siguiente build no depende de que setup haya corrido antes.
        install -d -m1777 "$ARXY_BUILD" 2>/dev/null || true
        local post s2=0 _acc
        post=$(( $(_gc_bytes "$old") + $(_gc_bytes "$pkgdir") + $(_gc_bytes "$ARXY_BUILD") ))
        while IFS=$'\t' read -r _acc st_path; do
            [[ -n "${st_path:-}" ]] || continue
            s2=$((s2 + $(_gc_bytes "$st_path")))
        done < <(staging_inventory)
        applied=1
        applied_bytes=$((total - post - s2))
        (( applied_bytes >= 0 )) || applied_bytes=0
    fi
    if [[ -n "$use_json" ]]; then
        local hint="nada que limpiar"
        if (( total > 0 && old_present )); then
            hint="arxy gc --apply libera $total bytes (incluye rollback recuperable)"
        elif (( total > 0 )); then
            hint="arxy gc --apply libera $total bytes"
        fi
        printf '{"format": 1'
        printf ', "root_old": {"present": %s, "valid": %s, "size": %s}' \
            "$(json_bool "$old_present")" "$(json_bool "$old_valid")" "$old_size"
        printf ', "cache": {"path": %s, "size": %s}' "$(json_str "$pkgdir")" "$cache_size"
        printf ', "build": {"path": %s, "size": %s}' "$(json_str "$ARXY_BUILD")" "$build_size"
        printf ', "staging": {"entries": %s, "size": %s}' "$st_n" "$st_size"
        printf ', "total_bytes": %s' "$total"
        printf ', "hint": %s' "$(json_str "$hint")"
        printf ', "applied": %s, "applied_bytes": %s}\n' \
            "$(json_bool "$applied")" "$applied_bytes"
        return 0
    fi
    msg "rollback: $old_size bytes en $old (presente: $(json_bool "$old_present"), válido: $(json_bool "$old_valid"))"
    msg "cache pacman: $cache_size bytes en $pkgdir"
    msg "builds: $build_size bytes en $ARXY_BUILD"
    msg "staging: $st_n entradas ($st_size bytes)"
    msg "total: $total bytes"
    if [[ -n "$apply" ]]; then
        msg "gc aplicado: $applied_bytes bytes liberados"
    else
        msg "nada tocado (dry-run); '$PROG gc --apply' para limpiar"
    fi
    return 0
}
