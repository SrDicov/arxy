# --- GPU real: heuristica NVIDIA en bash, deteccion pura.
# El montaje vive en run_in (lib/10-level.sh): solo run/shell; pacman via
# in_bwrap no toca GPU. Salidas componibles: una entrada por linea. Mocks en
# AGENTS.md. file(1) ya es dependencia declarada. El driver Xorg (xorg/modules)
# no se escanea: su mapeo esta en nvidia_guest_path (ruta conocida).

elf_class() { # <fichero> : 64|32|"" (vacio = no ELF o file ausente)
    local f="$1" cls=""
    if command -v file >/dev/null 2>&1; then
        cls="$(file -bL "$f" 2>/dev/null | grep -oE 'ELF (32|64)-bit' | head -n 1 || true)"
    fi
    case "$cls" in
        "ELF 64-bit") echo 64; return 0 ;;
        "ELF 32-bit") echo 32; return 0 ;;
    esac
    # Fallback por path (sin file): solo 32 es seguro de adivinar; lo
    # desconocido se salta (nunca montar algo mal clasificado).
    case "$f" in
        */lib32/*|*/i386-linux-gnu/*) echo 32; return 0 ;;
    esac
    echo ""
    return 0
}

nvidia_libs() { # "class<TAB>path" por lib NVIDIA del host ("" = ninguna)
    # Patrones con 'nvidia'/'cuda' obligatorios: 'libGLESv*.so*' a secas
    # cazaria mesa. Symlinks saltados (el real ya sale); dedup por inodo.
    local r="${ARXY_NVIDIA_LIB_ROOT:-/usr/lib}"
    local r64="${ARXY_NVIDIA_LIB_ROOT64:-/usr/lib64}"
    local r32="${ARXY_NVIDIA_LIB_ROOT32:-/usr/lib32}"
    local d pat f cls key
    local -A _seen=()
    for d in "$r" "$r64" "$r32"; do
        [[ -d "$d" ]] || continue
        for pat in 'libnvidia-*.so*' 'libcuda.so*' 'libGLX_nvidia.so*' \
                   'libEGL_nvidia.so*' 'libGLESv*nvidia*.so*' \
                   'libvdpau_nvidia.so*' 'libnvidia-gtk*.so*' 'nvidia-*'; do
            for f in "$d"/$pat; do
                [[ -e "$f" ]] || continue
                [[ -L "$f" ]] && continue # symlink: el real ya sale (evita duplicar link+real)
                key="$(stat -c '%d:%i' "$f" 2>/dev/null || echo "$f")"
                [[ -n "${_seen[$key]:-}" ]] && continue
                _seen[$key]=1
                cls="$(elf_class "$f")"
                printf '%s\t%s\n' "$cls" "$f"
            done
        done
    done
    return 0
}

nvidia_icds() { # "kind<TAB>host_path" (kind: vulkan|egl; "" = ninguno)
    local vk="${ARXY_VULKAN_ICD_PATH:-/usr/share/vulkan/icd.d}"
    local egl="${ARXY_EGL_PLATFORM_PATH:-/usr/share/egl/egl_external_platform.d}"
    local f
    for f in "$vk"/*nvidia*.json; do
        [[ -f "$f" ]] || continue
        printf 'vulkan\t%s\n' "$f"
    done
    for f in "$egl"/*nvidia*.json; do
        [[ -f "$f" ]] || continue
        printf 'egl\t%s\n' "$f"
    done
    return 0
}

nvidia_icd_library() { # <icd.json> : library_path ("" si falta)
    grep -m1 -oE '"library_path"[[:space:]]*:[[:space:]]*"[^"]*"' "$1" 2>/dev/null \
        | cut -d'"' -f4 || true
    return 0
}

nvidia_icd_rewrite() { # <host_icd> <guest_lib> : JSON con library_path reescrito
    local icd="$1" glib="$2" lp content
    [[ -f "$icd" ]] || return 0
    lp="$(nvidia_icd_library "$icd")"
    if [[ -z "$lp" ]]; then cat "$icd" 2>/dev/null || true; return 0; fi
    # Sustitucion literal bash (patron entrecomillado = sin globs; en el
    # reemplazo & y \ son literales, al reves que en sed).
    content="$(cat "$icd" 2>/dev/null || true)"
    printf '%s\n' "${content//"$lp"/"$glib"}"
    return 0
}
# TODO: rewrite solo 64-bit (el loader 32-bit necesitaria su manifiesto);
# upgrade con un segundo manifiesto cuando alguien corra Vulkan 32-bit aqui.

nvidia_guest_path() { # <host_path> <class> : path en rootfs ("" = inclasificable)
    local h="$1" cls="${2:-}" lib
    [[ "$cls" == 64 || "$cls" == 32 ]] || return 0
    lib="lib$cls"
    case "$h" in
        *xorg/modules/*) printf '/usr/lib/arxy-nvidia/%s/xorg/%s\n' "$lib" "${h#*xorg/}" ;;
        *) printf '/usr/lib/arxy-nvidia/%s/%s\n' "$lib" "$(basename "$h")" ;;
    esac
    return 0
}

nvidia_mounts() { # "host<TAB>guest" (libs + ICDs + devices; "" = nada)
    local cls p g kind ip n
    while IFS=$'\t' read -r cls p; do
        [[ -n "${p:-}" ]] || continue
        g="$(nvidia_guest_path "$p" "$cls")"
        [[ -n "$g" ]] || continue
        printf '%s\t%s\n' "$p" "$g"
    done < <(nvidia_libs)
    while IFS=$'\t' read -r kind ip; do
        [[ -n "${ip:-}" ]] || continue
        case "$kind" in
            vulkan) printf '%s\t%s\n' "$ip" "/usr/share/vulkan/icd.d/$(basename "$ip")" ;;
            egl) printf '%s\t%s\n' "$ip" "/usr/share/egl/egl_external_platform.d/$(basename "$ip")" ;;
        esac
    done < <(nvidia_icds)
    while IFS= read -r n; do
        [[ -n "$n" ]] || continue
        # Filtro en bash (equivale a grep nvidia; ahorra un fork por run).
        case "$n" in *nvidia*) printf '%s\t%s\n' "$n" "$n" ;; esac
    done < <(detect_dev_nodes 2>/dev/null || true)
    return 0
}

gpu_stack_pkgs() { # un paquete por linea: ICD Vulkan glibc del rootfs
    # GL/DRI ya lo trae mesa-mini (iris/radeonsi/nouveau); falta el ICD Vulkan
    # del vendor (+lib32). Sin discreta se asume Intel (la iGPU no reporta
    # vendor a drm). NVIDIA se pinea al modulo del host: sin version legible,
    # un utils sin pin rompe el GL.
    local ver=""
    case "$(detect_gpu || true)" in
        nvidia) ver="$(detect_nvidia_ver || true)"
            [[ -n "$ver" ]] || die "NVIDIA sin version legible (¿nouveau?): nvidia-utils sin pin romperian el GL"
            printf '%s\n' "nvidia-utils=$ver" "lib32-nvidia-utils=$ver" ;;
        amd) printf '%s\n' vulkan-radeon lib32-vulkan-radeon ;;
        *) printf '%s\n' vulkan-intel lib32-vulkan-intel ;;
    esac
    return 0
}
