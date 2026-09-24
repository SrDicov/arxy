# --- AUR: compila como usuario e instala el paquete resultante como root
cmd_install_aur() {
    [[ $# -ge 1 ]] || die "uso: $PROG install --aur <paquete...>"
    local p f failed=()
    for p in "$@"; do
        [[ "$p" == -* ]] && die "opcion no soportada en AUR: '$p'"
        check_pkg_name "$p"
    done
    ensure_image
    level
    [[ "$_ARXY_LEVEL" == 2 ]] && die "AUR necesita nivel 1 (compilar exige user namespaces); en nivel 2 solo paquetes oficiales"
    ensure_aur_env
    for p in "$@"; do
        f="$(aur_build "$p")"
        if [[ -z "${f:-}" || ! -f "$f" ]]; then
            msg "error: fallo al construir $p (sigo con el resto)" >&2
            failed+=("$p")
            continue
        fi
        if ! as_root "$SELF" __install-file "$f"; then
            msg "error: fallo al instalar $p (sigo con el resto)" >&2
            failed+=("$p")
            continue
        fi
        # Conservar el workdir solo cuando falla, para poder depurarlo.
        [[ "$p" =~ ^[a-zA-Z0-9@._+-]+$ ]] && rm -rf "${ARXY_BUILD:?}/aur/$p" 2>/dev/null || true
    done
    if [[ "${#failed[@]}" -gt 0 ]]; then
        die "no pude construir/instalar AUR: '${failed[*]}' (mira los errores de arriba; reintenta de a uno con '$PROG install --aur <paquete>')"
    fi
    # El hook de usuario es best-effort; una mutación root cubrirá /usr después.
    [[ -w "$ARXY_DATA" && -z "${ARXY_NO_AUTO_DEDUP:-}" ]] && do_dedup auto
    msg "instalado (AUR): $*"
}

# Prepara makepkg y usa paru solo cuando funciona; git es el fallback.
ensure_aur_env() {
    [[ -d "$ARXY_BUILD" ]] || die "falta $ARXY_BUILD: ejecuta 'sudo $PROG setup' para crearlo"
    # Herramientas de build: las que falten se instalan solas (una vez).
    # strip vive en binutils (nombre distinto al binario).
    local t missing_tools=()
    for t in fakeroot strip git curl pkgconf patch debugedit jq; do
        in_sys "/usr/bin/$t" --version >/dev/null 2>&1 || {
            [[ "$t" == "strip" ]] && missing_tools+=("binutils") || missing_tools+=("$t")
        }
    done
    # makepkg viene con pacman (siempre presente si la imagen es valida).
    in_sys /usr/bin/makepkg --version >/dev/null 2>&1 || \
        die "imagen rota: sin makepkg"
    if [[ "${#missing_tools[@]}" -gt 0 ]]; then
        msg "herramientas AUR que faltan: ${missing_tools[*]}" >&2
        as_root "$SELF" install "${missing_tools[@]}" >&2 || \
            die "no pude instalar herramientas AUR '${missing_tools[*]}' (mira el error de pacman de arriba)"
    fi
    if in_sys /usr/bin/paru --version >/dev/null 2>&1; then
        HAVE_PARU=1
    else
        HAVE_PARU=
        msg "aviso: paru no usable; usando git+RPC" >&2
    fi
}

# aur_build imprime solo la ruta final; progreso y errores van a stderr.
check_pkg_name() { # charset Arch seguro para rutas bajo ARXY_BUILD/aur
    local pkg="${1:-}"
    [[ "$pkg" =~ ^[A-Za-z0-9@._+][A-Za-z0-9@._+-]*$ ]] || die "nombre de paquete invalido: '$pkg' (solo [a-zA-Z0-9@._+-], sin '/' ni flags, sin '-' inicial)"
}
aur_build() { # <pkg> -> ruta paquete construido
    local pkg="$1" f
    check_pkg_name "$pkg"
    local work_host="$ARXY_BUILD/aur/$pkg" work_ns="$NS_BUILD/aur/$pkg"
    rm -rf "${work_host:?}"
    mkdir -p "$ARXY_BUILD/aur" || die "no puedo escribir en $ARXY_BUILD"
    # Dentro del namespace solo existe work_ns.
    if [[ -n "${HAVE_PARU:-}" ]]; then
        in_bwrap /usr/bin/paru --noconfirm -G "$pkg" "$work_ns" >&2 2>/dev/null || \
        in_bwrap /usr/bin/git clone --depth 1 "https://aur.archlinux.org/$pkg.git" "$work_ns" >&2 || \
            die "no existe en AUR: $pkg (revisa el nombre con '$PROG search-aur $pkg')"
    else
        in_bwrap /usr/bin/git clone --depth 1 "https://aur.archlinux.org/$pkg.git" "$work_ns" >&2 || \
            die "no existe en AUR: $pkg (revisa el nombre con '$PROG search-aur $pkg')"
    fi
    # Instalar dependencias oficiales antes de invocar makepkg.
    if [[ -f "$work_host/.SRCINFO" ]]; then
        local md missing=() d selfpkgs
        md="$(grep -E '^[[:space:]]*(makedepends?|depends?) =' "$work_host/.SRCINFO" 2>/dev/null | sed 's/^[^=]*=[[:space:]]*//' | sort -u || true)"
        # Excluir subpaquetes del mismo pkgbase: no están en repositorios.
        selfpkgs="$(grep -E '^[[:space:]]*pkgname =' "$work_host/.SRCINFO" 2>/dev/null | sed 's/.*=[[:space:]]*//' | sort -u || true)"
        while IFS= read -r d; do
            d="${d%%[<>=]*}" # quita restricciones de version (gcc>=13 -> gcc)
            [[ -z "$d" ]] && continue
            grep -qxF "$d" <<<"$selfpkgs" 2>/dev/null && continue
            in_bwrap /usr/bin/pacman -Q "$d" >/dev/null 2>&1 || missing+=("$d")
        done <<<"$md"
        if [[ "${#missing[@]}" -gt 0 ]]; then
            # stdout está reservado para la ruta del paquete final.
            msg "deps de $pkg: ${missing[*]}" >&2
            as_root "$SELF" install "${missing[@]}" >&2 || \
                msg "aviso: alguna dep no esta en repos oficiales; sigo y que decida makepkg" >&2
        fi
    fi
    # Los -bin usan una copia de makepkg.conf sin debug ni LTO.
    cp "$ARXY_ROOT/etc/makepkg.conf" "$work_host/makepkg-arxy.conf" 2>/dev/null || \
        die "falta /etc/makepkg.conf en la imagen"
    printf '%s\n' 'OPTIONS=(strip docs !libtool !staticlibs emptydirs zipman purge !debug !lto)' \
        >> "$work_host/makepkg-arxy.conf"
    mkdir -p "$work_host/bin"
    # Shims locales evitan chown bajo userns y admiten sintaxis tar antigua.
    cat > "$work_host/bin/bsdtar" <<'SHIM'
#!/bin/sh
case "$1" in
  -*) exec /usr/bin/bsdtar --no-same-owner "$@" ;;
  [xcrtu]*)
    b="$1"; shift; op="${b%"${b#?}"}"; rest="${b#?}"
    case "$rest" in
      *f*) rest="$(printf '%s' "$rest" | tr -d 'f')"
           if [ -n "$rest" ]; then set -- "-$op" "-$rest" -f "$@";
           else set -- "-$op" -f "$@"; fi ;;
      *) if [ -n "$rest" ]; then set -- "-$op" "-$rest" "$@";
         else set -- "-$op" "$@"; fi ;;
    esac
    exec /usr/bin/bsdtar --no-same-owner "$@" ;;
  *) exec /usr/bin/bsdtar "$@" ;;
esac
SHIM
    # GNU tar antiguo recibe --no-same-owner en la posición que acepta.
    cat > "$work_host/bin/tar" <<'SHIM'
#!/bin/sh
case "$1" in
  -*) exec /usr/bin/tar --no-same-owner "$@" ;;
  *) exec /usr/bin/tar "$@" --no-same-owner ;;
esac
SHIM
    # cp -a necesita anular ownership después de -a, salvo opción explícita.
    cat > "$work_host/bin/cp" <<'SHIM'
#!/bin/sh
for a in "$@"; do
  case "$a" in *preserve*) exec /usr/bin/cp "$@" ;; esac
done
for a in "$@"; do
  case "$a" in -*) case "$a" in *[ap]*) exec /usr/bin/cp "$@" --no-preserve=ownership ;; esac ;; esac
done
exec /usr/bin/cp "$@"
SHIM
    chmod +x "$work_host/bin/bsdtar" "$work_host/bin/tar" "$work_host/bin/cp"
    # install filtra únicamente opciones de propietario/grupo.
    cat > "$work_host/bin/install" <<'SHIM'
#!/bin/sh
# Filtro con centinela (rotar sin recentinela reordena/duplica).
sent="__shim_end_$$"
set -- "$@" "$sent"
while [ $# -gt 0 ] && [ "$1" != "$sent" ]; do
    case "$1" in
        -o|-g|--owner|--group) shift; { shift; } 2>/dev/null ;;
        -o?*|-g?*|--owner=*|--group=*) shift ;;
        *) set -- "$@" "$1"; shift ;;
    esac
done
[ "$1" = "$sent" ] && shift
exec /usr/bin/install "$@"
SHIM
    chmod +x "$work_host/bin/install"
    local build_ok=0
    # ARXY_GPG_CHECK activa la verificación PGP de makepkg.
    local -a pgp_args=(--skippgpcheck)
    [[ -n "${ARXY_GPG_CHECK:-}" ]] && pgp_args=()
    # Argumentos estructurados, sin programa bash -c intermedio.
    in_bwrap --chdir "$work_ns" --setenv PATH "$work_ns/bin:$PATH" -- \
        /usr/bin/makepkg --config "$work_ns/makepkg-arxy.conf" --noconfirm \
        "${pgp_args[@]}" >&2 && build_ok=1
    rm -rf "${work_host:?}/bin" # shims solo para este build: fuera siempre
    [[ $build_ok -eq 1 ]] || die "fallo al compilar '$pkg' con makepkg (mira el error de arriba; el codigo queda en '$ARXY_BUILD/aur/$pkg' para depurar)"
    # En pkgbase divididos, excluir artefactos de paquetes hermanos.
    local sibs sib cand ok
    sibs="$(grep -E '^[[:space:]]*pkgname =' "$work_host/.SRCINFO" 2>/dev/null | sed 's/.*=[[:space:]]*//' | sort -u || true)"
    f=""
    while IFS= read -r cand; do
        ok=1
        while IFS= read -r sib; do
            [[ -z "$sib" ]] && continue
            [[ "$sib" == "$pkg" ]] && continue
            [[ "${cand##*/}" == "$sib"-* ]] && { ok=0; break; }
        done <<<"$sibs"
        [[ $ok -eq 1 ]] && { f="$cand"; break; }
    done < <(ls -t "$work_host"/*.pkg.tar.zst 2>/dev/null || true)
    [[ -n "${f:-}" && -f "$f" ]] || die "makepkg no produjo paquete para $pkg"
    echo "$f"
}

# Paso privilegiado: traduce la ruta host, instala y etiqueta lanzadores.
cmd_install_file() {
    need_root
    [[ $# -eq 1 && -f "${1:-}" ]] || die "uso interno: $PROG __install-file <paquete.pkg.tar.zst>"
    data_lock # fase privilegiada del flujo AUR (corre como root)
    ensure_image
    local file="$1"
    [[ "$file" == "$ARXY_BUILD"/* ]] && file="$NS_BUILD${file#$ARXY_BUILD}"
    local -a nc
    nc_args nc
    pacman_mut -U --needed "${nc[@]}" "$file" || die "fallo 'pacman -U' de '$file' (mira el error de arriba; ¿dependencias, firma o espacio?)"
    clean_pkg_cache
    local name
    name="$(in_sys /usr/bin/pacman -Qp "$file" 2>/dev/null | awk '{print $1}')"
    [[ -n "${name:-}" ]] && { cmd_export "$name" || true; }
    update_desktop_db
    desktop_migrate_auto || true
}
