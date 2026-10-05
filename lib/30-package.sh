# --- instalacion / remocion / mantenimiento (corren como root)
clean_pkg_cache() {
    [[ -n "${ARXY_KEEP_PKG_CACHE:-}" ]] && return 0
    rm -f "$ARXY_ROOT"/var/cache/pacman/pkg/* 2>/dev/null || true
}

# Stack GL completo (mesa + LLVM) sobre mesa-mini, para AMD (radeonsi) o
# NVIDIA (nouveau); solo quien lo necesita (+~170MB). La propietaria queda
# fuera: exige match exacto con el modulo del host.
cmd_gpu_stack() { # <gpu-amd|gpu-nvidia>
    # Sin pacman.conf: aviso y rc 0 (sin match = hold ya quitado, idempotente).
    if [[ ! -f "$ARXY_ROOT/etc/pacman.conf" ]]; then
        msg "aviso: sin pacman.conf en $ARXY_ROOT, omito gpu-stack" >&2; return 0
    fi
    sed -i -E 's|^#?IgnorePkg[[:space:]]*=[[:space:]]*mesa|#IgnorePkg = mesa|' "$ARXY_ROOT/etc/pacman.conf" 2>/dev/null || true
    # Sin --needed a proposito: mini y oficial comparten pkgname+version y
    # --needed lo daria por satisfecho. Solo reinstala si falta LLVM.
    local -a nc
    nc_args nc
    if ! run_pacman -Qq llvm-libs >/dev/null 2>&1; then
        pacman_mut -S "${nc[@]}" mesa || die "fallo al instalar el stack gpu 'mesa' en '$ARXY_ROOT' (¿red? reintenta '$PROG install gpu-amd|gpu-nvidia' o corre '$PROG doctor')"
    fi
    clean_pkg_cache
    msg "gpu: stack completo instalado (${1:-})"
}

# --- meta-paquete gaming: rewrite a dependencias reales (los PKGBUILDs de
# packaging/aur/ son drafts). gpu_stack_pkgs() (doctor --fix) = minimo Vulkan
# y arxy_gaming_pkgs() = gaming completo: distintas a proposito, no unificar.
arxy_gaming_vendor() { # nvidia|amd|intel ("" + rc 1 = sin GPU decidible)
    local v dri
    v="$(detect_gpu || true)"
    case "$v" in
        nvidia)
            # Propietario solo si el modulo responde (nouveau no sirve).
            [[ -r "${ARXY_SYS_ROOT:-}/proc/driver/nvidia/version" ]] && { echo nvidia; return 0; }
            return 1 ;;
        amd) echo amd; return 0 ;;
        *)
            # Sin discreta con dri expuesto se asume Intel (la iGPU no
            # reporta vendor a drm; criterio de hardware.json).
            dri="$(detect_dev_nodes 2>/dev/null | grep -E '/(card[0-9]+|renderD[0-9]+)$' || true)"
            [[ -n "$dri" ]] && { echo intel; return 0; }
            return 1 ;;
    esac
}

arxy_gaming_pkgs() { # <vendor> : un paquete por linea (gaming completo)
    local v="$1" ver
    # Lista canonica en bash (los PKGBUILDs la espejan).
    # libva-*/intel-media-driver fuera: decode de video, no rendering.
    printf '%s\n' steam wine vkd3d gamescope mangohud vulkan-icd-loader lib32-vulkan-icd-loader
    case "$v" in
        nvidia)
            ver="$(detect_nvidia_ver || true)"
            [[ -n "$ver" ]] || die "NVIDIA sin version legible (¿nouveau?)"
            printf '%s\n' "nvidia-utils=$ver" "lib32-nvidia-utils=$ver" ;;
        amd) printf '%s\n' mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon ;;
        intel) printf '%s\n' mesa lib32-mesa vulkan-intel lib32-vulkan-intel ;;
        *) die "vendor gaming invalido: '$v' (usa nvidia, amd o intel)" ;;
    esac
    # AUR (-bin) al final: el llamador parte por sufijo (convencion del repo).
    printf '%s\n' proton-ge-custom-bin dxvk-bin
    return 0
}

cmd_gaming() { # [--dry-run] [nvidia|amd|intel] : rama explicita = override
    local dry="" force=""
    [[ "${1:-}" == "--dry-run" ]] && { dry=1; shift; }
    [[ $# -le 1 ]] || die "uso interno: cmd_gaming [--dry-run] [nvidia|amd|intel]"
    force="${1:-}"
    local vendor
    if [[ -n "$force" ]]; then
        vendor="$force"
    elif ! vendor="$(arxy_gaming_vendor)"; then
        [[ "$(detect_gpu || true)" == nvidia ]] && \
            die "NVIDIA sin driver propietario (¿nouveau?): arxy-gaming exige el modulo propietario"
        die "GPU no detectada (sin drm/dri): usa '$PROG install arxy-gaming-intel|arxy-gaming-amd|arxy-gaming-nvidia --dry-run'"
    fi
    local -a pkgs=()
    mapfile -t pkgs < <(arxy_gaming_pkgs "$vendor")
    if [[ -n "$dry" ]]; then
        echo "vendor detectado: $vendor"
        [[ "$(detect_libc 2>/dev/null || true)" == musl ]] && echo "host musl: solo devices del host, userspace del rootfs"
        echo "meta-paquete: arxy-gaming -> arxy-gaming-$vendor (draft en packaging/aur/, aun no publicado)"
        echo "paquetes (instalaria):"
        printf '  %s\n' "${pkgs[@]}"
        is_mesa_mini 2>/dev/null && echo "conflictos: mesa-mini seria reemplazado por mesa"
        echo "nada tocado (dry-run)"
        return 0
    fi
    local -a off=() aur=() p
    for p in "${pkgs[@]}"; do case "$p" in *-bin) aur+=("$p") ;; *) off+=("$p") ;; esac; done
    # En L2 la parte AUR moriria tras aplicar la oficial (medio-estado):
    # fallar antes de tocar nada (el dry-run ya volvio arriba).
    level 2>/dev/null || true
    if [[ "${_ARXY_LEVEL:-}" == 2 && "${#aur[@]}" -gt 0 ]]; then
        die "arxy-gaming exige nivel 1 para su parte AUR (estas en nivel 2; nada aplicado)"
    fi
    # makepkg prohibe root: la parte AUR se compila como usuario ANTES de
    # elevar; ARXY_GAMING_AUR_DONE hace que la re-ejecucion elevada la salte.
    # Root directo sin usuario que la haga: se instala lo oficial y se dice
    # como completar (mismo limite que 'install --aur' con sudo).
    if [[ "${#aur[@]}" -gt 0 && -z "${ARXY_GAMING_AUR_DONE:-}" ]]; then
        if [[ "$(id -u)" -ne 0 ]]; then
            cmd_install --aur "${aur[@]}"
            export ARXY_GAMING_AUR_DONE=1
        fi
    fi
    need_root
    ensure_image
    # [multilib] para lib32-* (idempotente). Guard primero: imagenes frescas
    # ya traen la estanza activa y sin el duplicariamos el registro.
    grep -q '^\[multilib\]' "$ARXY_ROOT/etc/pacman.conf" 2>/dev/null || \
        sed -i -E '/^#\[multilib\]/,/^#?Include/s/^#//' "$ARXY_ROOT/etc/pacman.conf" 2>/dev/null || true
    cmd_gpu_stack "arxy-gaming-$vendor" # mesa full idempotente (amd/intel/nvidia)
    [[ "${#off[@]}" -gt 0 ]] && cmd_install "${off[@]}"
    if [[ "${#aur[@]}" -gt 0 && -z "${ARXY_GAMING_AUR_DONE:-}" ]]; then
        die "parte AUR pendiente como root (makepkg prohibe root): completala como usuario: $PROG install --aur ${aur[*]}"
    fi
    # Flag interno de cadena (no exportarlo en tu shell: salta la parte
    # AUR; y no renombrarlo con '_': solo PRIV_ENV_KEYS cruza need_root).
    unset ARXY_GAMING_AUR_DONE
    msg "gaming listo: $vendor (arxy-gaming-$vendor)"
}

cmd_install() {
    # Rewrite arxy-gaming (meta-paquete virtual) primero, para que --dry-run
    # # informe sin root (como doctor --fix).
    local -a _rest=()
    local _g _dry="" _want="" _branch="" _gaming_count=0
    for _g in "$@"; do
        case "$_g" in
            arxy-gaming) _want=1; _gaming_count=$((_gaming_count + 1)) ;;
            arxy-gaming-nvidia|arxy-gaming-amd|arxy-gaming-intel)
                _want=1; _branch="${_g##*-}"; _gaming_count=$((_gaming_count + 1)) ;;
            --dry-run) _dry=1 ;;
            *) _rest+=("$_g") ;;
        esac
    done
    (( _gaming_count <= 1 )) || die "elige una sola variante arxy-gaming"
    if [[ -n "$_want" ]]; then
        local -a _gargs=()
        [[ -n "$_dry" ]] && _gargs+=(--dry-run)
        [[ -n "$_branch" ]] && _gargs+=("$_branch")
        cmd_gaming "${_gargs[@]}"
        local _rc=$?
        [[ -n "$_dry" || "${#_rest[@]}" -eq 0 ]] && return $_rc
        set -- "${_rest[@]}"
    fi
    if [[ "${1:-}" == "--aur" ]]; then
        shift
        cmd_install_aur "$@"
        return
    fi
    [[ $# -ge 1 ]] || die "uso: $PROG install <paquete...>  |  $PROG install --aur <paquete...>"
    # Validar TODO el argv ANTES de root/red: un "" o "my app" moria en pacman
    # tras escalar y descargar (~130MB).
    local -a pkgs=()
    local -a gpu_reqs=()
    local g
    for g in "$@"; do
        [[ "$g" == --dry-run ]] && die "--dry-run solo vale con arxy-gaming ('$PROG install arxy-gaming --dry-run')"
        [[ "$g" == -* ]] && die "opcion no soportada en install: '$g'"
        case "$g" in gpu-amd|gpu-nvidia) gpu_reqs+=("$g") ;; *) check_pkg_name "$g"; pkgs+=("$g") ;; esac
    done
    need_root
    data_lock # (la fase AUR-usuario no lo toma: entra por __install-file)
    ensure_image
    # GPU: nombres virtuales, no paquetes; se resuelven antes de pacman y sin
    # flags (): "--root"/"--config" llegarian al pacman privilegiado.
    local _gr
    for _gr in "${gpu_reqs[@]}"; do cmd_gpu_stack "$_gr"; done
    [[ "${#pkgs[@]}" -gt 0 ]] || return 0
    local -a nc
    nc_args nc
    pacman_mut -S --needed "${nc[@]}" "${pkgs[@]}" || die "fallo 'pacman -S' de '${pkgs[*]}' en '$ARXY_ROOT' (mira el error de pacman arriba; ¿red, lock o nombre?)"
    clean_pkg_cache
    local p
    for p in "${pkgs[@]}"; do
        [[ "$p" == -* ]] && continue
        # Si export muere, avisar (nunca en silencio).
        cmd_export "$p" || msg "aviso: no pude exportar $p" >&2
    done
    update_desktop_db
    # Legacy sin tag que export_one no toco (pre-X-Arxy-Pkg): aviso, nunca falla.
    desktop_migrate_auto || true
    [[ -z "${ARXY_NO_AUTO_DEDUP:-}" ]] && do_dedup auto
    msg "instalado: $*"
}
