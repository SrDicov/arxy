# --- doctor --json (superficie pública versionada, format 1) ---
# Sin jq a propósito (cero dependencias nuevas): printf + escaping mínimo.
# Reglas: orden de campos fijo, arrays ordenados, avisos a stderr,
# stdout = un solo documento JSON, exit igual que doctor en texto.
# Schema mínimo: format=int, level=int, libc={kind,version}, kernel={arch,
# release}, capacidades=bool, landlock={available,abi}, gpu={vendor,driver,
# render_node}, nvidia={present,version,usable,reason}, kmods=[], dev={},
# rootfs={}, fixes_available=[], fixes_applied=[], fixes=[] y signature={}.
# Añadir campos es compatible; renombrar o quitar no lo es.
json_str() { # <texto> -> "texto" con \ " y controles escapados
    local s="${1//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
    s="${s//$'\b'/\\b}"; s="${s//$'\f'/\\f}"
    printf '"%s"' "$s"
}
json_bool() { # 1|0 -> true|false
    if [[ "${1:-0}" == 1 ]]; then printf 'true'; else printf 'false'; fi
}
json_str_or_null() { # "" -> null (campos opcionales nunca se omiten)
    if [[ -z "${1:-}" ]]; then printf 'null'; else json_str "$1"; fi
}
json_arr() { # líneas por stdin -> ["a", "b"] (vacío -> [])
    local first=1 l
    printf '['
    while IFS= read -r l || [[ -n "$l" ]]; do
        [[ -z "$l" ]] && continue
        if [[ "$first" == 1 ]]; then first=0; else printf ', '; fi
        json_str "$l"
    done
    printf ']'
    return 0
}

kver_at_least() { # <mayor> <menor> : kernel >= X.Y (heurísticas documentadas)
    local k
    k="$(uname -r 2>/dev/null || true)"
    [[ "$k" =~ ^([0-9]+)\.([0-9]+) ]] || return 1
    (( BASH_REMATCH[1] > $1 || (BASH_REMATCH[1] == $1 && BASH_REMATCH[2] >= $2) ))
}
probe_userns() { # 1 si hay namespaces sin root (misma prueba que doctor)
    if command -v unshare >/dev/null 2>&1 && unshare --user --map-root-user true 2>/dev/null; then echo 1; return 0; fi
    if command -v bwrap >/dev/null 2>&1 && bwrap --ro-bind / / /bin/true 2>/dev/null; then echo 1; return 0; fi
    echo 0
}
probe_overlayfs() ( # subshell: 1 si overlay rootless monta en userns, sin restos
    # El mount vive en el ns muerto del unshare: nunca cuelga en el host.
    # El EXIT trap queda confinado al subshell y cubre la muerte a mitad.
    command -v unshare >/dev/null 2>&1 || { echo 0; return 0; }
    local t
    t="$(mktemp -d 2>/dev/null || true)"
    [[ -n "$t" && -d "$t" ]] || { echo 0; return 0; }
    trap 'rm -rf "${t:-}"' EXIT
    mkdir -p "$t/l" "$t/u" "$t/w" "$t/m" 2>/dev/null || { echo 0; return 0; }
    local o="lowerdir=$t/l,upperdir=$t/u,workdir=$t/w,userxattr"
    if unshare -Urm mount -t overlay overlay -o "$o" "$t/m" 2>/dev/null; then
        echo 1
    else
        echo 0
    fi
    rm -rf "${t:?}"
    t="" # el EXIT trap queda idempotente
    return 0
)
probe_mount_setattr() { kver_at_least 5 12 && echo 1 || echo 0; } # existe desde 5.12
probe_seccomp() { kver_at_least 3 17 && echo 1 || echo 0; } # seccomp-bpf desde 3.17
probe_landlock() { kver_at_least 5 13 && echo 1 || echo 0; } # landlock desde 5.13
probe_cgroupv2() {
    command -v stat >/dev/null 2>&1 || { echo 0; return 0; }
    [[ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null || true)" == cgroup2fs ]] && echo 1 || echo 0
}
detect_libc_ver() { # 2.44|1.2.5|"" (best-effort desde la salida de ldd)
    command -v ldd >/dev/null 2>&1 || return 1
    local v
    v="$(ldd --version 2>&1 | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1 || true)"
    [[ -n "$v" ]] && echo "$v" || return 1
}

cmd_doctor_json() { # [--fix|--apply] : se ignoran (solo se lista); JSON a stdout
    local a noted=""
    for a in "$@"; do
        case "$a" in --fix|--apply|--confirm) noted=1 ;; *) die "uso: $PROG doctor [--fix [--apply [--confirm]] | --json]" ;; esac
    done
    [[ -n "$noted" ]] && msg "nota: --json lista fixes sin aplicarlos" >&2
    emit_hardware_json
    return $?
}

# Núcleo reutilizable (doctor --json y hardware.json de setup): emite el
# JSON a stdout y devuelve el ok de doctor (para json=$(...) + rc).
emit_hardware_json() {
    local ok=0 c
    for c in "${HOST_TOOLS[@]}"; do
        command -v "$c" >/dev/null 2>&1 || ok=1
    done
    level
    [[ "$_ARXY_LEVEL" == 1 || "$_ARXY_LEVEL" == 2 ]] || ok=1
    local root_present=0
    if image_ok; then root_present=1; else ok=1; fi
    [[ -n "$ARXY_IMAGE_URL" ]] || ok=1
    local lckind lcver karch krel
    lckind="$(detect_libc)"
    lcver="$(detect_libc_ver || true)"
    karch="$(uname -m 2>/dev/null || true)"
    krel="$(uname -r 2>/dev/null || true)"
    local dev_nodes gv rn
    dev_nodes="$(detect_dev_nodes)"
    gv="$(detect_gpu || true)"
    if [[ -z "$gv" ]]; then
        if grep -qE '/(card[0-9]+|renderD[0-9]+)$' <<<"$dev_nodes"; then gv=intel; else gv=unknown; fi
    fi
    rn="$(grep '/renderD' <<<"$dev_nodes" | sort | head -n 1 || true)"
    local nv nv_present=0 nv_usable=0 nv_reason="sin driver en host"
    nv="$(detect_nvidia_ver || true)"
    [[ -n "$nv" ]] && nv_present=1
    if (( ! nv_present )) && grep -q nvidia <<<"$dev_nodes"; then nv_present=1; fi
    if (( nv_present )); then
        if (( ! root_present )); then nv_reason="sin rootfs verificado";
        elif is_mesa_mini; then nv_reason="mesa-mini sin LLVM en rootfs (instala gpu-nvidia)";
        else nv_usable=1; nv_reason="stack completo"; fi
    fi
    local -a fixes=()
    local -A fix=()
    local fid
    for fid in "${FIX_IDS[@]}"; do
        fix_probe "$fid" fix
        [[ "${fix[status]}" == todo ]] && fixes+=("$fid")
    done
    local rver=""
    [[ -f "$ARXY_VERSION_FILE" ]] && rver="$(version_field date || true)"
    # (ruta JSON): mismo aviso que version_line, a stderr, sin
    # tocar el documento (version:null ya es el contrato en corrupto).
    if [[ -f "$ARXY_VERSION_FILE" && -z "$rver" ]]; then
        msg "aviso: version ilegible, regenero en el proximo setup/install" >&2
    fi
    printf '{"format": 1'
    printf ', "level": %s' "$_ARXY_LEVEL"
    printf ', "libc": {"kind": "%s", "version": %s}' "$lckind" "$(json_str_or_null "$lcver")"
    printf ', "kernel": {"arch": %s, "release": %s}' "$(json_str_or_null "$karch")" "$(json_str_or_null "$krel")"
    printf ', "userns": %s' "$(json_bool "$(probe_userns)")"
    printf ', "overlayfs_rootless": %s' "$(json_bool "$(probe_overlayfs)")"
    printf ', "mount_setattr": %s' "$(json_bool "$(probe_mount_setattr)")"
    printf ', "seccomp": %s' "$(json_bool "$(probe_seccomp)")"
    printf ', "mount_setattr_method": "kernel-version>=5.12"'
    printf ', "seccomp_method": "kernel-version>=3.17"'
    printf ', "cgroupv2": %s' "$(json_bool "$(probe_cgroupv2)")"
    printf ', "cgroupv2_method": "cgroup2fs-en-/sys/fs/cgroup"'
    printf ', "landlock": {"available": %s, "abi": null}' "$(json_bool "$(probe_landlock)")"
    printf ', "gpu": {"vendor": "%s", "driver": null, "render_node": %s}' "$gv" "$(json_str_or_null "$rn")"
    printf ', "nvidia": {"present": %s, "version": %s, "usable": %s, "reason": %s}' \
        "$(json_bool "$nv_present")" "$(json_str_or_null "$nv")" "$(json_bool "$nv_usable")" "$(json_str "$nv_reason")"
    printf ', "kmods": %s' "$( { tr ' ' '\n' <<<"$(detect_kmods)" | grep . | sort || true; } | json_arr)"
    printf ', "dev": {"dri": %s' "$( { grep -E '/(card[0-9]+|renderD[0-9]+)$' <<<"$dev_nodes" | sort || true; } | json_arr)"
    printf ', "nvidia": %s' "$( { grep nvidia <<<"$dev_nodes" | sort || true; } | json_arr)"
    printf ', "fuse": %s}' "$(json_str_or_null "$(grep '/fuse$' <<<"$dev_nodes" | sort | head -n 1 || true)")"
    printf ', "rootfs": {"path": %s, "present": %s, "version": %s}' \
        "$(json_str "$ARXY_ROOT")" "$(json_bool "$root_present")" "$(json_str_or_null "$rver")"
    printf ', "fixes_available": %s' "$(printf '%s\n' "${fixes[@]}" | sort | json_arr)"
    printf ', "fixes": %s' "$(fixes_json)"
    printf ', "fixes_applied": []'
    local sig_pol="${ARXY_SIGNATURE_POLICY:-optional}" sig_avail=0 sig_last=0
    command -v minisign >/dev/null 2>&1 && sig_avail=1
    [[ "$(cat "$ARXY_DATA/.arxy-sig" 2>/dev/null || true)" == 1 ]] && sig_last=1
    printf ', "signature": {"policy": %s, "minisign_available": %s, "last_setup_verified": %s}}\n' \
        "$(json_str "$sig_pol")" "$(json_bool "$sig_avail")" "$(json_bool "$sig_last")"
    return $ok
}

# Perfil persistido: hardware.json es CACHÉ del mismo schema,
# escrita por setup; doctor --json siempre calcula fresco, nunca la lee.
write_hardware_json() { # <json> : atómico + solo-si-cambia; nunca falla setup
    local json="$1" f="$ARXY_DATA/hardware.json" tmp old
    [[ -n "$json" ]] || return 0
    mkdir -p "$ARXY_DATA" 2>/dev/null || { msg "aviso: sin $ARXY_DATA, omito hardware.json" >&2; return 0; }
    if [[ -f "$f" ]]; then
        old="$(cat "$f" 2>/dev/null || true)"
        [[ "$old" == "$json" ]] && return 0 # idéntico: preserva mtime
    fi
    tmp="$(mktemp "$ARXY_DATA/.hardware.json.XXXXXX" 2>/dev/null || true)"
    [[ -n "$tmp" ]] || { msg "aviso: sin temporal para hardware.json" >&2; return 0; }
    printf '%s\n' "$json" >"$tmp" 2>/dev/null || { rm -f "$tmp"; msg "aviso: no pude escribir hardware.json" >&2; return 0; }
    chmod 0644 "$tmp" 2>/dev/null || true
    sync "$tmp" 2>/dev/null || sync 2>/dev/null || true # durabilidad best-effort
    mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; msg "aviso: no pude publicar hardware.json" >&2; return 0; }
    return 0
}

print_profile_block() { # <json> <origen> : bloque "hardware:" (grep, sin jq)
    local j="$1" src="$2" v
    echo "hardware: $src (format 1)"
    v="$(sed -n 's/.*"libc": {"kind": "\([^"]*\)", "version": \([^,}]*\)}.*/\1 \2/p' <<<"$j" | head -n 1 || true)"
    v="${v//\"/}"; [[ "$v" == *" null" ]] && v="${v% null}"
    echo "  libc: ${v:-desconocida}"
    v="$(sed -n 's/.*"kernel": {"arch": \([^,}]*\), "release": \([^}]*\)}.*/\1 \2/p' <<<"$j" | head -n 1 || true)"
    v="${v//\"/}"; [[ "$v" == *" null" ]] && v="${v% null}"
    echo "  kernel: ${v:-desconocido}"
    v="$(sed -n 's/.*"gpu": {"vendor": "\([^"]*\)", "driver": [^,]*, "render_node": \([^}]*\)}.*/\1 \2/p' <<<"$j" | head -n 1 || true)"
    v="${v//\"/}"; [[ "$v" == *" null" ]] && v="${v% null}"
    echo "  gpu: ${v:-desconocida}"
    v="$(sed -n 's/.*"nvidia": {"present": \([a-z]*\), "version": \([^,]*\), "usable": \([a-z]*\), "reason": "\([^"]*\)"}.*/\1 \2 \3 \4/p' <<<"$j" | head -n 1 || true)"
    v="${v//\"/}"
    if [[ "$v" == false* ]]; then echo "  nvidia: no presente";
    else echo "  nvidia: ${v#* }"; fi
    v="$(sed -n 's/.*"kmods": \[\([^]]*\)\].*/\1/p' <<<"$j" | head -n 1 | tr -d '"[]' | tr ',' ' ' | tr -s ' ' || true)"
    echo "  kmods:${v:+ $v}"
    return 0
}

show_hardware_profile() { # bloque perfil en version --verbose (fichero o fresco)
    local f="$ARXY_DATA/hardware.json" j="" from=""
    if [[ -f "$f" ]] && j="$(cat "$f" 2>/dev/null)" && [[ "$j" == *'"format": 1'* ]]; then
        from="$f"
        local klive ksaved nlive nsaved
        klive="$(uname -r 2>/dev/null || true)"
        ksaved="$(sed -n 's/.*"kernel": {[^}]*"release": \([^,}]*\)}.*/\1/p' <<<"$j" | head -n 1 | tr -d '"' || true)"
        [[ -n "$klive" && -n "$ksaved" && "$klive" != "$ksaved" ]] && \
            msg "aviso: kernel actual ($klive) difiere del perfil ($ksaved)" >&2
        nlive="$(detect_nvidia_ver || true)"
        nsaved="$(sed -n 's/.*"nvidia": {[^}]*"version": \([^,}]*\)}.*/\1/p' <<<"$j" | head -n 1 | tr -d '"' || true)"
        [[ "$nlive" != "$nsaved" ]] && \
            msg "aviso: nvidia actual (${nlive:-ausente}) difiere del perfil (${nsaved:-ausente})" >&2
    else
        if [[ -f "$f" ]]; then
            msg "aviso: hardware.json corrupto o con otro format; perfil fresco en memoria" >&2
        else
            msg "aviso: sin hardware.json (lo crea setup); perfil fresco en memoria" >&2
        fi
        j="$(emit_hardware_json 2>/dev/null || true)"
        from="memoria"
        [[ -z "$j" ]] && { msg "aviso: no se pudo calcular el perfil" >&2; return 0; }
    fi
    print_profile_block "$j" "$from"
    return 0
}
