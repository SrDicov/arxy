# --- runtime: mount namespace minimo, cero aislamiento
# Solo /home conserva su ruta; el resto del host se alcanza mediante /host.
# No bindear /opt, /srv, etc.: pacman debe escribir dentro del rootfs.
VISIBLE_DIRS=(/home)

host_path_visible() { # <ruta>: visible con la misma ruta dentro del namespace
    local path="$1" dir
    for dir in "${VISIBLE_DIRS[@]}" /tmp /run /dev /proc /sys; do
        [[ "$path" == "$dir" || "$path" == "$dir"/* ]] && return 0
    done
    return 1
}

bwrap_base() {
    local d resolv
    printf '%s\n' --bind "$ARXY_ROOT" /
    # --bind es recursivo; --bind-try tolera orígenes inexistentes.
    for d in "${VISIBLE_DIRS[@]}"; do
        printf '%s\n' --bind-try "$d" "$d"
    done
    [[ -d "$ARXY_BUILD" ]] && printf '%s\n' --bind "$ARXY_BUILD" "$NS_BUILD"
    # Variables gráficas del host no describen el rootfs.
    printf '%s\n' \
        --unsetenv VK_DRIVER_FILES \
        --unsetenv VK_ICD_FILENAMES \
        --unsetenv LIBGL_DRIVERS_PATH \
        --unsetenv ARXY_BRIDGE_SOCKET \
        --unsetenv ARXY_BRIDGE_TOKEN
    printf '%s\n' \
        --bind /tmp /tmp \
        --bind /run /run \
        --dev-bind /dev /dev \
        --proc /proc \
        --ro-bind-try /sys /sys \
        --bind / /host
    resolv="$(readlink -f /etc/resolv.conf 2>/dev/null || echo /etc/resolv.conf)"
    if [[ -f "$resolv" ]]; then
        printf '%s\n' --ro-bind "$resolv" /etc/resolv.conf
    else
        msg "aviso: sin resolv.conf valido en el host, el DNS dentro puede fallar" >&2
    fi
    [[ -f /etc/hosts ]] && printf '%s\n' --ro-bind /etc/hosts /etc/hosts
    # Qt/D-Bus requieren un machine-id real, coherente con el bus compartido.
    if [[ -s /etc/machine-id ]]; then
        printf '%s\n' --ro-bind /etc/machine-id /etc/machine-id
    else
        msg "aviso: host sin machine-id valido, Qt/D-Bus dentro pueden abortar" >&2
    fi
    [[ -f /etc/localtime ]] && printf '%s\n' --ro-bind-try /etc/localtime /etc/localtime
}

# Ejecuta dentro sin reemplazar el proceso; el llamador delimita el comando.
in_bwrap() {
    local -a b
    mapfile -t b < <(bwrap_base)
    bwrap "${b[@]}" \
        --setenv PATH "/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/sbin:/bin" \
        "$@"
}

# Como in_bwrap, pero hace exec y añade NVIDIA/bridge cuando están disponibles.
# Los ICD se pasan por FD para evitar temporales compartidos.
run_in() {
    local -a b
    mapfile -t b < <(bwrap_base)
    local _nvm _nvi
    _nvm="$(nvidia_mounts 2>/dev/null || true)"
    _nvi="$(nvidia_icds 2>/dev/null || true)"
    # musl: el userspace grafico del host no sirve en el rootfs glibc;
    # fuera libs+ICDs (devices ya vienen con --dev-bind /dev de la base).
    if [[ "$(detect_libc 2>/dev/null || true)" == musl ]]; then _nvm=""; _nvi=""; fi
    if [[ -n "$_nvm$_nvi" ]]; then
        # bwrap procesa en orden: crear destinos antes de bindear bibliotecas.
        b+=(--dir /usr/lib/arxy-nvidia/lib64 --dir /usr/lib/arxy-nvidia/lib32)
        local _h _g
        while IFS=$'\t' read -r _h _g; do
            [[ -n "${_h:-}" && -n "${_g:-}" ]] || continue
            case "$_g" in /dev/*) b+=(--dev-bind "$_h" "$_g") ;; *) b+=(--ro-bind "$_h" "$_g") ;; esac
        done <<<"$_nvm"
        local _k _ip _d _lp _gl _nfd _cls
        while IFS=$'\t' read -r _k _ip; do
            [[ -n "${_k:-}" && -n "${_ip:-}" ]] || continue
            case "$_k" in
                vulkan) _d=/usr/share/vulkan/icd.d ;;
                egl) _d=/usr/share/egl/egl_external_platform.d ;;
                # TODO: glvnd egl_vendor.d sin montar (OUT-OF-SCOPE §6); upgrade con --ro-bind-data como los ICDs.
                *) continue ;;
            esac
            # El FD debe abrirse aquí para sobrevivir hasta el exec de bwrap.
            _lp="$(nvidia_icd_library "$_ip")"
            if [[ -n "$_lp" ]]; then
                # No asumir 64-bit: un ICD de 32 bits necesita lib32.
                _cls="64"
                [[ "$(elf_class "$_lp" 2>/dev/null || true)" == "32" ]] && _cls="32"
                _gl="$(nvidia_guest_path "$(basename "$_lp")" "$_cls")"
                [[ -n "$_gl" ]] || continue
                exec {_nfd}< <(nvidia_icd_rewrite "$_ip" "$_gl") || continue
            else
                exec {_nfd}< "$_ip" || continue
            fi
            b+=(--ro-bind-data "$_nfd" "$_d/$(basename "$_ip")")
        done <<<"$_nvi"
    fi
    # El bridge es opcional y puede no estar cargado en pruebas unitarias.
    # bridge_active_socket concentra fallback, autoarranque y validación.
    local _bsock="" _btok=""
    if command -v bridge_active_socket >/dev/null 2>&1; then
        _bsock="$(bridge_active_socket || true)"
    fi
    if [[ -n "$_bsock" ]]; then
        case "$_bsock" in
            /run/*|/tmp/*) b+=(--setenv ARXY_BRIDGE_SOCKET "$_bsock") ;;
            *) b+=(--bind "$_bsock" /tmp/arxy-bridge.sock --setenv ARXY_BRIDGE_SOCKET /tmp/arxy-bridge.sock) ;;
        esac
        _btok="$(cat "$(bridge_token_path "$_bsock")" 2>/dev/null || true)"
        [[ -n "$_btok" ]] && b+=(--setenv ARXY_BRIDGE_TOKEN "$_btok")
    fi
    exec bwrap "${b[@]}" \
        --setenv PATH "/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/sbin:/bin" \
        "$@"
}

run_pacman() {
    level
    if [[ "$_ARXY_LEVEL" == 2 ]]; then
        # Lecturas sin namespace: reescribir Include absolutos hacia el rootfs.
        mkdir -p "$ARXY_ROOT/tmp" 2>/dev/null || true
        local _ro
        _ro="$(mktemp "$ARXY_ROOT/tmp/pacman-arxy-ro.XXXXXX")" || return 1
        sed "s|/etc/pacman.d/|$ARXY_ROOT/etc/pacman.d/|g" "$ARXY_ROOT/etc/pacman.conf" > "$_ro" 2>/dev/null || { rm -f "$_ro"; return 1; }
        in_sys /usr/bin/pacman --root "$ARXY_ROOT" --config "$_ro" \
            --dbpath "$ARXY_ROOT/var/lib/pacman" "$@"
        local _rc=$?
        rm -f "$_ro"
        return $_rc
    else
        in_bwrap /usr/bin/pacman "$@"
    fi
}

# --- niveles de ejecucion
# Nivel 1 usa bwrap; nivel 2 usa ld-linux para run y chroot para mutaciones.
level() { # deja el nivel en _ARXY_LEVEL (memoizado por proceso)
    [[ -n "${_ARXY_LEVEL:-}" ]] && return 0
    if [[ "${ARXY_LEVEL:-}" == 1 || "${ARXY_LEVEL:-}" == 2 ]]; then
        _ARXY_LEVEL="$ARXY_LEVEL"
    elif command -v bwrap >/dev/null 2>&1 && bwrap --ro-bind / / true 2>/dev/null; then
        _ARXY_LEVEL=1
    else
        _ARXY_LEVEL=2
    fi
}

# Entorno canónico de nivel 2; nunca hereda LD_LIBRARY_PATH del host.
level2_env() {
    unset LD_LIBRARY_PATH # del host: envenenaria al ld-linux del subsistema
    case ":${XDG_DATA_DIRS:-}:" in
        *":$ARXY_ROOT/usr/share:"*) ;;
        *) export XDG_DATA_DIRS="$ARXY_ROOT/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}" ;;
    esac
    export GCONV_PATH="$ARXY_ROOT/usr/lib/gconv"
    export GSETTINGS_SCHEMA_DIR="$ARXY_ROOT/usr/share/glib-2.0/schemas"
    if [[ -d "$ARXY_ROOT/usr/lib/girepository-1.0" ]]; then
        case ":${GI_TYPELIB_PATH:-}:" in
            *":$ARXY_ROOT/usr/lib/girepository-1.0:"*) ;;
            *) export GI_TYPELIB_PATH="$ARXY_ROOT/usr/lib/girepository-1.0${GI_TYPELIB_PATH:+:$GI_TYPELIB_PATH}" ;;
        esac
    fi
    local cache
    for cache in "$ARXY_ROOT"/usr/lib/gdk-pixbuf-2.0/*/loaders.cache; do
        [[ -f "$cache" ]] && { export GDK_PIXBUF_MODULE_FILE="$cache"; break; }
    done
}

# in_sys <ruta-absoluta-del-subsistema> [args...] : ejecuta en el nivel activo.
in_sys() {
    level
    local bin="$1"; shift
    if [[ "$_ARXY_LEVEL" == 2 ]]; then
        case "$bin" in "$ARXY_ROOT"/*) ;; *) bin="$ARXY_ROOT$bin" ;; esac
        level2_env
        "$LD_LINUX" --library-path "$ARXY_LIBPATH" "$bin" "$@"
    else
        in_bwrap "$bin" "$@"
    fi
}

# Chroot de nivel 2 con mounts mínimos y limpieza en orden inverso.
in_chroot() {
    local dst mounted=() rc=0 resolv_bak="" resolv_created=""
    for dst in "$ARXY_ROOT/proc" "$ARXY_ROOT/sys" "$ARXY_ROOT/dev"; do
        [[ -d "$dst" ]] || mkdir -p "$dst" 2>/dev/null || continue
        case "$dst" in
            */proc) mount -t proc proc "$dst" 2>/dev/null && mounted+=("$dst") ;;
            *) mount --bind "${dst##"$ARXY_ROOT"}" "$dst" 2>/dev/null && mounted+=("$dst") ;;
        esac
    done
    local real_resolv
    real_resolv="$(readlink -f /etc/resolv.conf 2>/dev/null || echo /etc/resolv.conf)"
    if [[ -f "$real_resolv" ]]; then
        if mount --bind "$real_resolv" "$ARXY_ROOT/etc/resolv.conf" 2>/dev/null; then
            mounted+=("$ARXY_ROOT/etc/resolv.conf")
        else
            [[ -e "$ARXY_ROOT/etc/resolv.conf" ]] || resolv_created=1
            resolv_bak="$ARXY_ROOT/etc/resolv.conf.arxy-bak"
            cp -a "$ARXY_ROOT/etc/resolv.conf" "$resolv_bak" 2>/dev/null || true
            # El fallback por copia mantiene DNS cuando el bind no es posible.
            cp -L "$real_resolv" "$ARXY_ROOT/etc/resolv.conf" 2>/dev/null \
                || msg "aviso: DNS del host no disponible en chroot (fallo bind+copia de resolv.conf)" >&2
        fi
    fi
    if [[ -d "$ARXY_BUILD" ]]; then
        mkdir -p "$ARXY_ROOT$NS_BUILD" 2>/dev/null || true
        mount --bind "$ARXY_BUILD" "$ARXY_ROOT$NS_BUILD" 2>/dev/null && \
            mounted+=("$ARXY_ROOT$NS_BUILD")
    fi
    # Entorno limpio dentro: nada del host (un LD_LIBRARY_PATH del host seria fatal).
    chroot "$ARXY_ROOT" /usr/bin/env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/sbin:/bin" \
        LC_ALL=C HOME=/root "$@" || rc=$?
    local d
    for (( d=${#mounted[@]}-1; d>=0; d-- )); do
        umount -l "${mounted[d]}" 2>/dev/null || true
    done
    if [[ -n "$resolv_bak" && -f "$resolv_bak" ]]; then
        mv -f "$resolv_bak" "$ARXY_ROOT/etc/resolv.conf" 2>/dev/null || true
    elif [[ -n "$resolv_created" ]]; then
        rm -f "$ARXY_ROOT/etc/resolv.conf" 2>/dev/null || true
    fi
    return $rc
}

# pacman que escribe: bwrap en nivel 1, chroot en nivel 2 (scriptlets nativos).
pacman_mut() {
    level
    if [[ "$_ARXY_LEVEL" == 2 ]]; then
        # CheckSpace no puede resolver / dentro de este chroot.
        mkdir -p "$ARXY_ROOT/tmp" 2>/dev/null || true
        rm -f "$ARXY_ROOT"/tmp/pacman-arxy-*.conf 2>/dev/null || true
        local tmpconf
        # busybox mktemp exige que la plantilla TERMINE en XXXXXX (.conf no vale).
        tmpconf="$(mktemp "$ARXY_ROOT/tmp/pacman-arxy.XXXXXX")" || die "no pude crear conf temporal (¿espacio en $ARXY_ROOT/tmp?)"
        grep -v '^[[:space:]]*CheckSpace' "$ARXY_ROOT/etc/pacman.conf" > "$tmpconf" || die "imagen rota: sin pacman.conf (reinstala con 'sudo $PROG setup')"
        in_chroot /usr/bin/pacman --config "/tmp/${tmpconf##*/}" "$@"
        local rc=$?
        rm -f "$tmpconf" || true
        return $rc
    else
        in_bwrap /usr/bin/pacman "$@"
    fi
}

# Si PWD no es visible dentro, entrar via /host (siempre bindeado).
# En nivel 2 no hay namespace: el PWD del host es directamente valido.
inside_dir() {
    [[ "$_ARXY_LEVEL" == 2 ]] && { echo "$PWD"; return 0; }
    if host_path_visible "$PWD"; then echo "$PWD"; else echo "/host$PWD"; fi
}
