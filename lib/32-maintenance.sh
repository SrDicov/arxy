# --- remocion y mantenimiento del rootfs
cmd_remove() {
    [[ $# -ge 1 ]] || die "uso: $PROG remove <paquete...>"
    # validar antes de root/red (igual que install).
    local _r
    for _r in "$@"; do
        [[ "$_r" == -* ]] && die "opcion no soportada en remove: '$_r'"
        check_pkg_name "$_r"
    done
    need_root
    data_lock
    ensure_image
    # Igual que install (): sin flags a pacman privilegiado.
    local -a nc
    nc_args nc
    pacman_mut -Rns "${nc[@]}" "$@" || die "fallo 'pacman -Rns' de '$*' en '$ARXY_ROOT' (mira el error de pacman arriba)"
    local p f
    for p in "$@"; do
        [[ "$p" == -* ]] && continue
        while IFS= read -r f; do
            rm -f "$f" && msg "lanzador borrado: ${f##*/}"
        done < <(grep -rlxF "X-Arxy-Pkg=$p" "$REAL_APPS"/arxy-*.desktop 2>/dev/null || true)
    done
    update_desktop_db
}

cmd_update() {
    [[ $# -eq 0 ]] || die "uso: $PROG update"
    need_root
    data_lock
    ensure_image
    local -a nc
    nc_args nc
    pacman_mut -Syu "${nc[@]}" || die "fallo 'pacman -Syu' en '$ARXY_ROOT' (¿red o lock? mira el error de arriba)"
    clean_pkg_cache
    desktop_migrate_auto || true
    [[ -z "${ARXY_NO_AUTO_DEDUP:-}" ]] && do_dedup auto
    return 0 # [[...]] && ... final daria rc=1 con el hook desactivado
}

# Limpieza: dry-run por defecto (informa), --apply ejecuta.
# Solo borra regenerables (cache, builds, restos): jamas toca pacman.conf
# (IgnorePkg y cia sobreviven) ni el rootfs.
cmd_clean() { # [--apply]
    local apply=""
    [[ "${1:-}" == "--apply" ]] && apply=1
    [[ -z "${1:-}" || -n "$apply" ]] || die "uso: $PROG clean [--apply]"
    [[ -z "${2:-}" ]] || die "uso: $PROG clean [--apply]"
    need_root
    ensure_image
    [[ -n "$apply" ]] && data_lock # el apply borra .old (dry-run libre)
    local r p a d o f
    r="$(du -sh "$ARXY_ROOT" 2>/dev/null | cut -f1)"
    p="$(du -sh "$ARXY_ROOT/var/cache/pacman/pkg" 2>/dev/null | cut -f1)"
    a="-"; [[ -d "$ARXY_BUILD/aur" ]] && a="$(du -sh "$ARXY_BUILD/aur" 2>/dev/null | cut -f1)"
    d="-"
    for f in "$ARXY_DATA"/.arxy-dl.* "$ARXY_DATA"/.arxy-sha.*; do
        [[ -e "$f" ]] || continue
        d="$(du -shc "$ARXY_DATA"/.arxy-dl.* "$ARXY_DATA"/.arxy-sha.* 2>/dev/null | tail -1 | cut -f1)"
        break
    done
    o="-"; [[ -d "$ARXY_ROOT.old" ]] && o="$(du -sh "$ARXY_ROOT.old" 2>/dev/null | cut -f1)"
    msg "rootfs: $r en $ARXY_ROOT"
    msg "cache pacman: $p"
    msg "builds AUR: $a en $ARXY_BUILD/aur"
    msg "descargas huerfanas: $d"
    msg "rollback: $o en $ARXY_ROOT.old ('$PROG rollback' lo restaura; --apply lo borra)"
    if [[ -z "$apply" ]]; then
        msg "nada tocado (dry-run); '$PROG clean --apply' para limpiar"
        return 0
    fi
    rm -f "$ARXY_ROOT"/var/cache/pacman/pkg/* 2>/dev/null || true
    rm -rf "${ARXY_BUILD:?}/aur" 2>/dev/null || true
    for f in "$ARXY_DATA"/.arxy-dl.* "$ARXY_DATA"/.arxy-sha.*; do
        [[ -e "$f" ]] || continue
        rm -f "$f"
    done
    rm -rf "${ARXY_ROOT:?}.old" 2>/dev/null || true
    msg "limpieza hecha"
}

# Dedup por hardlinks: runtimes identicos entre apps (Electron) ocupan N
# veces su tamaño; linkearlos ahorra sin coste de lectura ni FUSE.
# pacman reemplaza ficheros al actualizar (no escribe in-place): el link se
# rompe solo y cada app vuelve a ser independiente. Es correcto.
# Si una app modificara un fichero linkeado afectaria a las demas; en /usr
# no ocurre en la practica (ver README).
# TODO: nombres con \n quiebran el parseo (asumimos que /usr no los tiene); upgrade: find -print0 + cksum --zero.
do_dedup() ( # [auto] : subshell; auto solo informa si ahorra >=10MB
    local auto="${1:-}"
    local start=$SECONDS saved=0 linked=0
    local work=""
    work="$(mktemp -d "$ARXY_DATA/.arxy-dedup.XXXXXX" 2>/dev/null)" || { msg "aviso: sin dedup (no hay temporal en $ARXY_DATA)" >&2; return 0; }
    trap '[[ -n "${work:-}" ]] && rm -rf "$work"' EXIT
    # cksum POSIX (stat -c no existe en BSD, find -printf no existe en busybox):
    # CRC+tamaño en una pasada; sha256 solo confirma candidatos.
    # -links 1 = idempotente (lo ya linkeado se salta solo); -type f excluye symlinks.
    find "$ARXY_ROOT/usr" -type f -links 1 -exec cksum {} + 2>/dev/null | sort -k1,1n -k2,2n >"$work/all"
    awk '{print $1, $2}' "$work/all" | uniq -d >"$work/dups"
    local key size line h f first lasth
    while read -r key; do
        [[ -n "$key" ]] || continue
        size="${key#* }"
        awk -v k="$key" '$1" "$2 == k {sub(/^[^ ]+ [^ ]+ /,""); print}' "$work/all" >"$work/group"
        [[ -s "$work/group" ]] || continue # hueco de carrera (fichero borrado entre find y hash): sin entrada no hay xargs colgado
        first=""; lasth=""
        while IFS= read -r line; do
            h="${line%% *}"; f="${line#* }"; f="${f# }"; f="${f#\*}"
            if [[ "$h" == "$lasth" && -n "$first" ]]; then
                # cmp antes de ln: si algo cambio entre cksum y aqui, no linkear distintos.
                if cmp -s "$first" "$f" 2>/dev/null && ln -f "$first" "$f" 2>/dev/null; then
                    saved=$((saved + size)); linked=$((linked + 1))
                fi
            else
                first="$f"; lasth="$h"
            fi
        done < <(tr '\n' '\0' <"$work/group" | xargs -0 sha256sum 2>/dev/null | sort -k1,1)
    done <"$work/dups"
    local mb
    mb="$(awk -v b="$saved" 'BEGIN{printf "%.1f", b/1048576}')"
    if [[ -n "$auto" ]]; then
        [[ "$saved" -ge 10485760 ]] && msg "dedup: $linked archivos linkeados, ${mb} MB ahorrados"
    else
        msg "dedup: $linked archivos linkeados, ${mb} MB ahorrados en $((SECONDS - start))s"
    fi
    rm -rf "${work:?}"
    work="" # el EXIT trap queda idempotente
    return 0 # hook best-effort: un dedup silencioso jamas debe fallar un install/update
)

cmd_dedup() {
    [[ $# -eq 0 ]] || die "uso: $PROG dedup"
    need_root
    ensure_image
    need_cmd find cksum sort awk uniq tr xargs sha256sum ln mktemp cmp
    do_dedup
}
