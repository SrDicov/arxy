# --- diagnostico, reparaciones y salida humana
# Contratos compartidos por la salida humana y JSON.
declare -ar HOST_TOOLS=(bwrap curl tar zstd sha256sum awk sed grep mktemp su)
declare -ar FIX_IDS=(hold-mesa nvidia-align musl-glibc-stack gpu-full-stack staging-cleanup)
# Cada fix se serializa como {id,applicable,destructive,requires_root,reason,
# would_do,phase,opt_in?}; phase null = aplicable hoy.
cmd_quickstart() { # el siguiente paso segun estado (para quien no lee READMEs)
    [[ $# -eq 0 ]] || die "uso: $PROG quickstart"
    echo "$PROG $ARXY_VERSION: tu siguiente paso es"
    if ! image_ok; then
        echo "  $PROG setup            # descarga el subsistema (~130MB)"
        echo "Despues: $PROG install firefox && $PROG run firefox"
        return 0
    fi
    local n g
    n="$(ls "$REAL_APPS"/arxy-*.desktop 2>/dev/null | wc -l)"
    if [[ "$n" -eq 0 ]]; then
        echo "  $PROG install <app>    # p. ej. $PROG install firefox"
    else
        echo "  $PROG run <app>        # o desde el menu ($n lanzadores; $PROG list para ver)"
    fi
    g="$(detect_gpu || true)"
    if [[ -n "$g" ]] && is_mesa_mini; then
        echo "  ...y GPU $g: $PROG install gpu-$g para aceleracion HW (+~170MB)"
    fi
}

# Aviso mesa-mini en AMD/NVIDIA (solo informa, nunca falla).
# Funcion separada (no inline en doctor): el $() dentro de cmd_doctor
# dispara un falso positivo SC2319 en shellcheck 0.11.
doctor_gpu() {
    local _g
    _g="$(detect_gpu || true)"
    [[ -n "$_g" ]] || return 0
    image_ok || return 0
    is_mesa_mini || return 0
    if [[ "$_g" == nvidia ]]; then
        msg "aviso GPU NVIDIA: solo nouveau via '$PROG install gpu-nvidia' (+~170MB); propietaria no soportada en v1 (rendimiento limitado)"
    else
        msg "aviso GPU AMD: mesa-mini no acelera HW; '$PROG install gpu-amd' instala el stack completo (+~170MB)"
    fi
}

# Sonda pura: llena un array asociativo con status, reason, action y opt_in.
# Estados: ok | todo | info | skip. No serializa datos con delimitadores.
_fix_result() { # <array> <status> <reason> [action] [opt-in]
    local -n target="$1"
    target=([status]="$2" [reason]="$3" [action]="${4:-}" [opt_in]="${5:-}")
}

fix_probe() { # <fix-id> <nombre-array-asociativo>
    local id="$1" result_name="$2"
    local nv inst lc dri g _gsp
    case "$id" in
        hold-mesa)
            if ! image_ok; then
                _fix_result "$result_name" skip "sin rootfs verificado"
            elif is_mesa_mini && ! mesa_hold_active; then
                _fix_result "$result_name" todo "un update traeria mesa oficial +170MB" \
                    "añadir 'IgnorePkg = mesa' bajo [options] de pacman.conf"
            else
                _fix_result "$result_name" ok "hold activo o innecesario"
            fi
            ;;
        nvidia-align)
            nv="$(detect_nvidia_ver || true)"
            if [[ -z "$nv" ]]; then
                if [[ -n "$(detect_dev_nodes | grep nvidia || true)" ]]; then
                    _fix_result "$result_name" skip "nodos nvidia sin versión legible"
                else
                    _fix_result "$result_name" skip "sin NVIDIA en host"
                fi
                return 0
            fi
            if ! image_ok; then
                _fix_result "$result_name" info "host $nv, sin rootfs verificado" \
                    "instalar nvidia-utils=<host> en rootfs"
                return 0
            fi
            inst="$(run_pacman -Qi nvidia-utils 2>/dev/null | grep -m1 '^Version' | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1 || true)"
            if [[ -n "$inst" && "$inst" == "$nv" ]]; then
                _fix_result "$result_name" ok "utils $inst alineados con host"
            else
                _fix_result "$result_name" info "host $nv, rootfs ${inst:-sin nvidia-utils}" \
                    "instalar nvidia-utils=<host> en rootfs"
            fi
            ;;
        musl-glibc-stack)
            lc="$(detect_libc)"
            dri="$(detect_dev_nodes | grep -E '/(card[0-9]+|renderD[0-9]+)$|nvidia' || true)"
            if [[ "$lc" != musl ]]; then _fix_result "$result_name" skip "libc $lc, no aplica"; return 0; fi
            if [[ -z "$dri" ]]; then _fix_result "$result_name" skip "musl sin GPU expuesta"; return 0; fi
            if ! image_ok; then _fix_result "$result_name" skip "sin rootfs verificado"; return 0; fi
            _gsp="$(gpu_stack_pkgs 2>/dev/null | xargs || true)"
            [[ -n "$_gsp" ]] || _gsp="nvidia-utils (version del host ilegible: instala a mano)"
            _fix_result "$result_name" todo "libc musl con GPU: el stack del host no sirve" \
                "instalar en rootfs: $_gsp"
            ;;
        gpu-full-stack)
            g="$(detect_gpu || true)"
            if [[ -z "$g" || "$g" == nvidia ]]; then _fix_result "$result_name" skip "lo cubre nvidia-align o no hay discreta"; return 0; fi
            if ! image_ok; then _fix_result "$result_name" skip "sin rootfs verificado"; return 0; fi
            if ! is_mesa_mini; then _fix_result "$result_name" ok "stack completo instalado"; return 0; fi
            _fix_result "$result_name" todo "GPU $g con mesa-mini (sin LLVM)" \
                "instalar mesa completo + vulkan + lib32 (opt-in)" 1
            ;;
        staging-cleanup)
            local inv="" n=0 action="" item acc p
            inv="$(staging_inventory 2>/dev/null || true)"
            if [[ -z "$inv" ]]; then _fix_result "$result_name" skip "sin staging huerfano"; return 0; fi
            n="$(printf '%s\n' "$inv" | grep -c . || true)"
            while IFS=$'\t' read -r acc p; do
                [[ -n "${p:-}" ]] || continue
                case "$acc" in
                    remove) item="borrar ${p##*/}" ;;
                    recover-root) item="recuperar ${p##*/} a root" ;;
                    replace-root) item="reemplazar root con ${p##*/}" ;;
                    rotate-old) item="rotar ${p##*/} a root.old" ;;
                    *) continue ;;
                esac
                action+="$item; "
            done <<<"$inv"
            if (( n == 1 )); then
                _fix_result "$result_name" todo "1 entrada de staging huerfana" "${action%; }"
            else
                _fix_result "$result_name" todo "$n entradas de staging huerfanas" "${action%; }"
            fi
            ;;
        *) return 1 ;;
    esac
    return 0
}

_fix_json_entry() { # <fid> <array-asoc> : un objeto {...} (separadores los pone el llamador)
    local fid="$1"
    local -n _e="$2"
    local st="${_e[status]}" reason="${_e[reason]}" action="${_e[action]}" app phase wd
    if [[ "$st" == todo ]]; then app=true; else app=false; fi
    case "$fid" in hold-mesa|staging-cleanup) phase=null ;; *) phase=4 ;; esac
    if [[ -n "$action" ]]; then wd="$(json_str "$action")"; else wd=""; fi
    printf '{"id": "%s", "applicable": %s, "destructive": false, "requires_root": true' "$fid" "$app"
    printf ', "reason": %s' "$(json_str "$reason")"
    if [[ -n "$wd" ]]; then printf ', "would_do": [%s]' "$wd"; else printf ', "would_do": []'; fi
    printf ', "phase": %s' "$phase"
    [[ -n "${_e[opt_in]}" ]] && printf ', "opt_in": true'
    printf '}'
}

fixes_json() { # array "fixes" para --json (fixes_available sigue siendo [ids])
    local first=1 fid
    local -A fix=()
    printf '['
    for fid in "${FIX_IDS[@]}"; do
        fix_probe "$fid" fix
        if [[ "$first" == 1 ]]; then first=0; else printf ', '; fi
        _fix_json_entry "$fid" fix
    done
    printf ']'
    return 0
}

fix_apply() { # <fix-id>: 0 aplicado, 1 fallo, 2 no implementado
    case "$1" in
        hold-mesa)
            sed -i '/^\[options\]/a IgnorePkg   = mesa' "$ARXY_ROOT/etc/pacman.conf" 2>/dev/null \
                && mesa_hold_active
            ;;
        staging-cleanup)
            recover_staging >/dev/null
            ;;
        musl-glibc-stack)
            local package_list
            local -a packages
            package_list="$(gpu_stack_pkgs)" && [[ -n "$package_list" ]] || return 1
            mapfile -t packages <<<"$package_list"
            cmd_install "${packages[@]}"
            ;;
        *) return 2 ;;
    esac
}

# Fixes propuestos (informan y proponen; solo hold-mesa aplica).
# Contrato: `doctor --fix` informa (rc 0); `--fix --apply` exige root y
# aplica no-destructivos; `--fix --apply --confirm` + tty para destructivos.
# Ya no toca el `ok` de cmd_doctor: devuelve su propio rc.
doctor_fix() { # [--fix [--apply [--confirm]]]
    [[ "${1:-}" == "--fix" ]] || return 0
    local apply="" confirm="" fails=0
    [[ "${2:-}" == "--apply" ]] && apply=1
    [[ "${3:-}" == "--confirm" ]] && confirm=1
    if [[ -n "$apply" && "$(id -u)" -ne 0 ]]; then
        die "'$PROG doctor --fix --apply' necesita root (sin root solo informa)"
    fi
    [[ -n "$apply" ]] && data_lock # el apply muta (hold/staging/musl)
    # avisar si hay sesion bridge viva (el apply rota el root).
    # Guarda command -v: tests que sourcean 60-hw sin 80-bridge no la tienen.
    [[ -n "$apply" ]] && command -v bridge_session_notice >/dev/null 2>&1 && bridge_session_notice
    local fid st reason action apply_rc
    local -A fix=()
    echo "fixes available: ${#FIX_IDS[@]}"
    for fid in "${FIX_IDS[@]}"; do
        fix_probe "$fid" fix
        st="${fix[status]}"; reason="${fix[reason]}"; action="${fix[action]}"
        case "$st" in
            ok) echo "  [ok]   $fid ($reason)" ;;
            todo)
                echo "  [todo] $fid ($reason)"
                [[ -n "$action" ]] && echo "         would_do: $action"
                if [[ -n "$apply" ]]; then
                    if fix_apply "$fid"; then
                        echo "  [hecho] $fid aplicado"
                    else
                        apply_rc=$?
                        if [[ "$apply_rc" -eq 2 ]]; then
                            echo "  [skip] $fid (aún no implementado)"
                        else
                            echo "  [fallo] $fid no se pudo aplicar" >&2; fails=1
                        fi
                    fi
                fi
                ;;
            info)
                echo "  [info] $fid ($reason) (informativo, no aplicable)"
                ;;
            skip) echo "  [skip] $fid ($reason)" ;;
        esac
    done
    local lock="$ARXY_ROOT/var/lib/pacman/db.lck"
    if [[ -f "$lock" ]]; then
        # ¿pacman real en curso? Por comm de /proc, no por cmdline (pgrep -f
        # se auto-detecta: nuestra propia linea de comandos menciona pacman).
        local _run="" _pc
        for _pc in /proc/[0-9]*/comm; do
            [[ -f "$_pc" ]] || continue
            [[ "$(cat "$_pc" 2>/dev/null)" == pacman ]] && { _run=1; break; }
        done
        if [[ -n "$_run" ]]; then
            msg "db.lck presente con pacman en curso: normal"
        else
            msg "db.lck sin pacman visible: stale probable (destructivo: requiere --apply --confirm + tty)"
            if [[ -n "$apply" && -n "$confirm" ]]; then
                if [[ -t 0 ]]; then
                    local ans
                    read -r -p "¿borrar $lock? [s/N] " ans
                    [[ "$ans" == [sS]* ]] && { rm -f "$lock" && msg "lock borrado"; }
                else
                    msg "sin tty: borralo a mano si ningun pacman corre"
                fi
            fi
        fi
    fi
    if [[ -d "$ARXY_ROOT.old" ]]; then
        msg "rollback pendiente: '$PROG rollback' restaura, o borra $ARXY_ROOT.old"
    fi
    if [[ -z "$apply" ]]; then
        echo "informa sin aplicar: repite con --apply (root) para no-destructivos"
    fi
    return $fails
}

# --- doctor / version / ayuda
cmd_doctor() {
    local args=() a use_json=""
    for a in "$@"; do
        if [[ "$a" == "--json" ]]; then use_json=1; else args+=("$a"); fi
    done
    if [[ -n "$use_json" ]]; then cmd_doctor_json "${args[@]}"; return $?; fi
    case "${args[*]:-}" in
        ""|"--fix"|"--fix --apply"|"--fix --apply --confirm") ;;
        *) die "uso: $PROG doctor [--fix [--apply [--confirm]] [--json]]" ;;
    esac
    local ok=0
    say() { if [[ "$1" -eq 0 ]]; then echo "[OK]   $2"; else echo "[FALTA] $2"; ok=1; fi; }
    local _c
    for _c in "${HOST_TOOLS[@]}"; do
        command -v "$_c" >/dev/null 2>&1; say $? "$_c en el host"
    done
    if command -v unshare >/dev/null 2>&1 && unshare --user --map-root-user true 2>/dev/null; then
        say 0 "user namespaces (unshare -U)"
    elif bwrap --ro-bind / / /bin/true 2>/dev/null; then
        say 0 "user namespaces (bwrap)"
    else
        say 1 "user namespaces (necesarios para correr sin root)"
    fi
    image_ok; local _img=$?
    say $_img "imagen en $ARXY_ROOT"
    # el recien instalado no recibe "siguiente paso" (la via xbps
    # no muestra el eco de install.sh). Sugerir setup/quickstart aqui.
    if (( _img != 0 )); then msg "siguiente: $PROG setup (descarga ~130MB) o $PROG quickstart"; fi
    [[ -f "$ARXY_VERSION_FILE" ]] && msg "imagen: $(version_line)"
    [[ -n "$ARXY_IMAGE_URL" ]]; say $? "ARXY_IMAGE_URL configurada"
    # Deteccion sin dependencias exoticas: solo bwrap funcional (nunca unshare).
    level
    if [[ "$_ARXY_LEVEL" == 1 ]]; then
        echo "[OK]   nivel 1 (bwrap + namespaces)"
    else
        echo "[OK]   nivel 2 (sin namespaces: ld-linux para run, chroot para install)"
    fi
    [[ -n "${ARXY_LEVEL:-}" ]] && msg "override manual: ARXY_LEVEL=$ARXY_LEVEL"
    doctor_gpu
    doctor_fix "${args[@]}"
    local frc=$?
    if [[ "${args[0]:-}" == "--fix" ]]; then return $frc; else return $ok; fi
}

cmd_version() {
    [[ $# -eq 0 || ( $# -eq 1 && "$1" == "--verbose" ) ]] \
        || die "uso: $PROG version [--verbose]"
    echo "$PROG $ARXY_VERSION"
    if [[ -f "$ARXY_VERSION_FILE" ]]; then
        version_line
    fi
    [[ $# -eq 1 ]] || return 0
    level
    echo "nivel: $_ARXY_LEVEL (1=bwrap, 2=sin namespaces)"
    echo "gpu: $(detect_gpu || echo 'no discreta (intel o softpipe)')"
    echo "rootfs: $(du -sh "$ARXY_ROOT" 2>/dev/null | cut -f1) en $ARXY_ROOT"
    if mesa_hold_active; then
        echo "hold mesa-mini: activo"
    else
        echo "hold mesa-mini: ausente"
    fi
    show_hardware_profile
}
