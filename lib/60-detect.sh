# --- deteccion de plataforma y hardware (funciones puras)
# GPU discreta que mesa-mini (sin LLVM) no acelera: amd|nvidia|"". Via /sys
# (lspci puede no existir en hosts minimos). ARXY_SYS_DRM_PATH inyecta un
# /sys falso para tests sin hardware (ver tests/test-gpu-drm.sh).
detect_gpu() {
    local base="${ARXY_SYS_DRM_PATH:-/sys/class/drm}" v
    for v in "$base"/card*/device/vendor; do
        [[ -f "$v" ]] || continue
        case "$(cat "$v" 2>/dev/null)" in
            *1002*) echo amd; return 0 ;;
            *10de*) echo nvidia; return 0 ;;
        esac
    done
    return 1
}

is_mesa_mini() { # mini = build externo sin firma conocida
    # Sin pipe directo: con pipefail, `prod | grep -q` miente (SIGPIPE
    # 141 cierra el productor antes; regla 5). Capturar y grepear después.
    local _qi
    _qi="$(run_pacman -Qi mesa 2>/dev/null || true)"
    grep -q '^Packager.*Unknown' <<<"$_qi"
}

mesa_hold_active() { # IgnorePkg=mesa en pacman.conf (mini protegido del update)
    grep -q '^IgnorePkg.*mesa' "$ARXY_ROOT/etc/pacman.conf" 2>/dev/null
}

# Mocks de deteccion y salidas componibles sin jq: kmods en una línea
# (espacios), dev_nodes una
# ruta por línea, el resto valor único o vacío. Mocks (patrón ARXY_SYS_DRM_PATH):
#   ARXY_SYS_ROOT=""  prefijo de /proc y /sys (falso en tests)
#   ARXY_DEV_PATH="/dev"  dir de dispositivos (falso en tests)
#   ARXY_LIB_DIR="/lib"  dir de loaders (falso en tests)
#   ARXY_LIB64_DIR="/lib64"  idem 64 bits (falso en tests)
detect_libc() { # glibc|musl|unknown (ambos loaders -> decide ldd: el primario)
    local d="${ARXY_LIB_DIR:-/lib}" d64="${ARXY_LIB64_DIR:-/lib64}"
    local musl="" glibc="" m
    for m in "$d"/ld-musl-*.so.1; do [[ -e "$m" ]] && musl=1 && break; done
    [[ -f "$d64/ld-linux-x86-64.so.2" || -f "$d/ld-linux.so.2" ]] && glibc=1
    [[ -n "$musl" && -z "$glibc" ]] && { echo musl; return 0; }
    [[ -n "$glibc" && -z "$musl" ]] && { echo glibc; return 0; }
    local v=""
    if command -v ldd >/dev/null 2>&1; then
        v="$(ldd --version 2>&1 | head -n 1 || true)"
        case "$v" in *musl*) echo musl; return 0 ;; *GLIBC*|*"GNU libc"*) echo glibc; return 0 ;; esac
    fi
    echo unknown
}

detect_nvidia_ver() { # 550.54.14|"" (vacío = sin driver o sin módulo)
    local base="${ARXY_SYS_ROOT:-}" f v
    for f in "$base/proc/driver/nvidia/version" "$base/sys/module/nvidia/version"; do
        [[ -f "$f" ]] || continue
        v="$(grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' "$f" 2>/dev/null | head -n 1 || true)"
        [[ -n "$v" ]] && { echo "$v"; return 0; }
    done
    return 1
}

detect_kmods() { # sublista presente de: fuse userfaultfd ntsync ("" = ninguno)
    local base="${ARXY_SYS_ROOT:-}" dev="${ARXY_DEV_PATH:-/dev}" out=""
    [[ -d "$base/sys/module/fuse" ]] && out+="fuse "
    [[ -f "$base/proc/sys/vm/unprivileged_userfaultfd" ]] && out+="userfaultfd "
    [[ -e "$dev/ntsync" ]] && out+="ntsync "
    echo "${out% }"
    return 0
}

detect_dev_nodes() { # una ruta por línea: dri/* nvidia* fuse ntsync ("" = nada)
    local dev="${ARXY_DEV_PATH:-/dev}" n
    for n in "$dev"/dri/* "$dev"/nvidia* "$dev"/fuse "$dev"/ntsync; do
        [[ -e "$n" ]] || continue
        echo "$n"
    done
    return 0
}
