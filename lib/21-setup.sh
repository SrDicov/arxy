# --- setup y rollback atomicos
# Invariante: SIGKILL en cualquier punto deja el sistema recuperable en la
# siguiente invocacion (ver recover_staging). Orden: descarga -> fsync -> sha
# -> staging -> fsync -> version DENTRO del staging -> fsync -> rotacion via
# .old.tmp.$$ -> rename -> fsync -> rotar .old -> fsync. Red (-Sy) al final.
cmd_setup() {
    [[ $# -eq 0 ]] || die "uso: $PROG setup"
    need_root
    data_lock # serializar ops con estado (slot .old unico)
    need_cmd curl tar sha256sum zstd
    [[ -n "$ARXY_IMAGE_URL" ]] || die "ARXY_IMAGE_URL vacio. Edita $ARXY_SYS_CONF y pon la URL del tarball."
    mkdir -p "$ARXY_DATA"
    install -d -m1777 "$ARXY_BUILD" # compilacion AUR como usuario (makepkg prohibe root)
    install -d -m1777 "$ARXY_BUILD/aur" # idem para workdirs (si lo crea root, el usuario no puede escribir)
    local tmp sha_tmp sig_tmp img_sha=""
    tmp="$(mktemp "$ARXY_DATA/.image.partial.XXXXXX")" || die "no pude crear temporal en $ARXY_DATA"
    sha_tmp="$(mktemp "$ARXY_DATA/.arxy-sha.XXXXXX")" || die "no pude crear temporal en $ARXY_DATA"
    sig_tmp="$(mktemp "$ARXY_DATA/.arxy-sig.XXXXXX")" || die "no pude crear temporal en $ARXY_DATA"
    # este trap EXIT no guarda/restaura el del llamador a proposito
    # (cmd_setup es toplevel/subshell: no hay trap previo que preservar).
    # shellcheck disable=SC2064
    trap "rm -f '$tmp' '$sha_tmp' '$sig_tmp'" EXIT
    msg "descargando imagen..."
    curl -fL --retry 3 -o "$tmp" "$ARXY_IMAGE_URL" || die "no se pudo descargar la imagen (¿red? reintenta, o usa ARXY_IMAGE_URL=file:///ruta/al/tarball)"
    data_sync "$tmp" "$ARXY_DATA" # lo hasheado es lo que hay en disco
    if [[ -n "$ARXY_IMAGE_SHA256" ]]; then
        [[ "$(sha256sum <"$tmp" | awk '{print $1}')" == "$ARXY_IMAGE_SHA256" ]] || die "sha256 no coincide, abortando (¿descarga truncada? reintenta o revisa ARXY_IMAGE_SHA256)"
    else
        # Sin hash fijado: intentar el .sha256 publicado junto al tarball
        # en el release (arxy-image lo sube siempre). La URL puede traer
        # ?query/#fragmento: se recortan antes de añadir .sha256.
        # Si no existe, avisar y seguir sin verificar (historico).
        local sha_url="${ARXY_IMAGE_URL%%\?*}"
        sha_url="${sha_url%%\#*}.sha256"
        if curl -fLs --retry 2 -o "$sha_tmp" "$sha_url" 2>/dev/null && [[ -s "$sha_tmp" ]]; then
            local sha_rel
            sha_rel="$(grep -Eo '[0-9a-f]{64}' "$sha_tmp" | head -n 1)"
            [[ -n "$sha_rel" && "$(sha256sum <"$tmp" | awk '{print $1}')" == "$sha_rel" ]] \
                || die "sha256 del release no coincide, abortando (¿descarga truncada? reintenta)"
            msg "verificado contra .sha256 del release"
            img_sha="$sha_rel"
        else
            msg "aviso: sin ARXY_IMAGE_SHA256 ni .sha256 en el release, omitiendo verificacion" >&2
        fi
    fi
    # Firma minisign: segundo factor sobre sha256. Solo http(s) sin
    # pin (.minisig publicado junto al tarball; arxy-image lo firma en CI).
    # file:// es desarrollo local y el pin ya ancla: se omiten con aviso.
    local sig_policy="${ARXY_SIGNATURE_POLICY:-optional}" sig_verified=0
    case "$sig_policy" in
        required|optional|off) : ;;
        *) die "ARXY_SIGNATURE_POLICY invalida: '$sig_policy' (required|optional|off)" ;;
    esac
    sig_check_compat
    if sig_should_verify; then
        local sig_url="${ARXY_IMAGE_URL%%\?*}"
        sig_url="${sig_url%%\#*}.minisig"
        local sig_pub="${ARXY_SYS_CONF%/*}/arxy.pub" sig_rc=0
        if curl -fLs --retry 2 -o "$sig_tmp" "$sig_url" 2>/dev/null && [[ -s "$sig_tmp" ]]; then
            verify_signature "$tmp" "$sig_tmp" "$sig_pub" || sig_rc=$?
            enforce_signature_policy "$sig_rc"
            if [[ "$sig_rc" == 0 ]]; then
                msg "firma minisign valida"
                sig_verified=1
            fi
        else
            # Sin .minisig publicado: como "ausente" (rc 4).
            enforce_signature_policy 4
        fi
    elif [[ "$sig_policy" == off ]]; then
        msg "firmas: omitidas (ARXY_SIGNATURE_POLICY=off)"
    elif [[ -n "$ARXY_IMAGE_SHA256" ]]; then
        msg "firmas: omitidas (ARXY_IMAGE_SHA256 pineado ya ancla)"
    else
        msg "firmas: omitidas (URL no http(s), desarrollo local)"
    fi
    printf '%s' "$sig_verified" >"$ARXY_DATA/.arxy-sig" 2>/dev/null || true
    # Extraer a staging y validar ANTES de tocar lo instalado: setup atomico.
    # Si algo falla aqui, la instalacion actual sigue intacta.
    local stage="$ARXY_ROOT.new.$$"
    rm -rf "${stage:?}"
    mkdir -p "$stage" || die "no pude crear staging en $stage (¿~1GB libre?)"
    msg "extrayendo en $stage..."
    if ! tar -xpf "$tmp" -C "$stage" 2>/dev/null; then
        # busybox-tar sin soporte zstd: descomprimir con zstd primero
        zstd -dc "$tmp" | tar -xp -C "$stage" || { rm -rf "${stage:?}"; die "no pude extraer la imagen en $stage (¿descarga truncada o sin ~1GB libre? reintenta; lo instalado sigue intacto)"; }
    fi
    rm -f "$tmp" "$sha_tmp" "$sig_tmp"
    trap - EXIT
    # Destinos de bind que la imagen quiza no trae (bwrap exige que existan
    # dentro): /host y el build dir AUR. Sin esto TODO falla en bwrap.
    mkdir -p "$stage/host" "$stage$NS_BUILD"
    # Nodos /dev estaticos para chroot pelado (sin mounts gpg no funciona:
    # exige /dev/null+urandom). Best-effort: en hosts restringidos falla
    # mknod y se sigue (los binds de in_chroot lo cubren si hay privilegios).
    local dev name dtype maj min
    for dev in "null c 1 3" "zero c 1 5" "full c 1 7" "random c 1 8" "urandom c 1 9" "tty c 5 0"; do
        read -r name dtype maj min <<<"$dev"
        # Sin -m (no existe en chimerautils): mknod pelado + chmod.
        if [[ ! -e "$stage/dev/$name" ]]; then
            mknod "$stage/dev/$name" "$dtype" "$maj" "$min" 2>/dev/null && \
                chmod 666 "$stage/dev/$name" 2>/dev/null || true
        fi
    done
    # El usuario real debe resolverse dentro (getpwuid): Electron y varias
    # apps abortan si su uid no esta en /etc/passwd (pear-desktop:
    # uv_os_get_passwd ENOENT). Se copia su linea del host al staging
    # (virgen: sin riesgo de duplicados). Solo passwd+grupo primario.
    if [[ "$REAL_USER" != "root" ]]; then
        local _hu _hg _gid
        _hu="$(grep "^$REAL_USER:" /etc/passwd 2>/dev/null || true)"
        if [[ -n "$_hu" ]] && ! grep -q "^$REAL_USER:" "$stage/etc/passwd" 2>/dev/null; then
            printf '%s\n' "$_hu" >> "$stage/etc/passwd"
        fi
        _gid="$(id -g "$REAL_USER" 2>/dev/null || true)"
        _hg="$(getent group "${_gid:-}" 2>/dev/null || true)"
        if [[ -n "$_hg" ]] && ! grep -q "^${_hg%%:*}:" "$stage/etc/group" 2>/dev/null; then
            printf '%s\n' "$_hg" >> "$stage/etc/group"
        fi
    fi
    _image_ok "$stage" || { rm -rf "${stage:?}"; die "imagen corrupta: sin bash/pacman/arch-release"; }
    [[ -z "$img_sha" ]] && img_sha="$ARXY_IMAGE_SHA256"
    # version DENTRO del staging: nace con la imagen y el rename la publica
    # junta — nunca hay root nuevo con version vieja ni al reves. El subshell
    # contiene el override (sin save/restore); die ahi sale del subshell.
    mkdir -p "$stage/var/lib/arxy" || { rm -rf "${stage:?}"; die "no pude registrar version en el staging"; }
    ( export ARXY_VERSION_FILE="$stage/var/lib/arxy/version"
      write_version "$ARXY_IMAGE_URL" "$img_sha" ) || { rm -rf "${stage:?}"; die "no pude escribir version"; }
    data_sync "$stage" "$ARXY_DATA"
    # rc para la shell de nivel 2: resuelve en el subsistema lo que el host
    # no conoce (rutas horneadas; se regenera en cada setup). Antes del
    # rename: su contenido no depende de que root este publicado.
    {
        echo "# generado por '$PROG setup' — no editar"
        echo 'command_not_found_handle() {'
        echo "    if [[ -x \"$ARXY_ROOT/usr/bin/\$1\" ]]; then"
        echo "        \"$LD_LINUX\" --library-path \"$ARXY_LIBPATH\" \"$ARXY_ROOT/usr/bin/\$1\" \"\${@:2}\""
        echo '        return $?'
        echo '    fi'
        echo '    echo "bash: $1: orden no encontrada" >&2'
        echo '    return 127'
        echo '}'
        echo 'pacman() {'
        echo '    # En nivel 2 pacman opera sobre el subsistema, nunca sobre el host.'
        echo '    # Solo invocacion por nombre (/usr/bin/pacman directo no intercepta).'
        echo '    [[ -n "${ARXY_ALLOW_RAW_PACMAN:-}" ]] && { command pacman "$@"; return $?; }'
        echo '    local a'
        echo '    for a in "$@"; do'
        echo '        case "$a" in --root|--config|--dbpath)'
        echo '            command pacman "$@"; return $? ;; esac'
        echo '    done'
        echo '    for a in "$@"; do'
        echo '        case "$a" in -S|-Su*|-Sy*|-Sw*|-Sc*|-U*|-R*|-D*|-F*|--sync|--upgrade|--remove|--database)'
        echo '            echo "arxy (nivel 2): esa operacion escribe; usa arxy install/remove/update en el host" >&2'
        echo '            return 1 ;; esac'
        echo '    done'
        echo "    command pacman --root \"$ARXY_ROOT\" --config \"$ARXY_ROOT/etc/pacman.conf\" --dbpath \"$ARXY_ROOT/var/lib/pacman\" \"\$@\""
        echo '}'
    } > "$ARXY_DATA/level2-rc"
    data_sync "$ARXY_DATA"
    # Rotacion via .old.tmp.$$ : el rename publica imagen+version juntas
    # (atomico). Kill aqui deja .old.tmp.$$ y lo resuelve recover_staging.
    local old_tmp="$ARXY_ROOT.old.tmp.$$"
    rm -rf "${old_tmp:?}" 2>/dev/null || true
    if [[ -d "$ARXY_ROOT" ]]; then
        mv "$ARXY_ROOT" "$old_tmp" || { rm -rf "${stage:?}"; die "no pude apartar la instalacion actual"; }
    fi
    mv "$stage" "$ARXY_ROOT" || die "rotacion fallo (la anterior esta en $old_tmp; el proximo arranque la rescata)"
    data_sync "$ARXY_ROOT" "$ARXY_DATA"
    if [[ -d "$old_tmp" ]]; then
        rm -rf "${ARXY_ROOT:?}.old" 2>/dev/null || true
        mv "$old_tmp" "$ARXY_ROOT.old" || msg "aviso: no pude rotar $old_tmp a rollback (el proximo arranque lo rescata)" >&2
    fi
    data_sync "$ARXY_DATA"
    # Una sola verdad: el legacy fuera del root ya no se escribe ni se lee.
    [[ "$ARXY_VERSION_LEGACY" != "$ARXY_VERSION_FILE" ]] && rm -f "$ARXY_VERSION_LEGACY" 2>/dev/null || true
    # Perfil HW persistido (caché del mismo schema; doctor calcula fresco).
    # Antes del -Sy: describe lo instalado aunque falle la red. Nunca falla setup.
    write_hardware_json "$(emit_hardware_json 2>/dev/null || true)"
    msg "sincronizando bases de pacman..."
    pacman_mut -Sy || die "fallo 'pacman -Sy' en $ARXY_ROOT (¿red o DNS? reintenta '$PROG setup' o revisa '$PROG doctor')"
    msg "imagen lista en $ARXY_ROOT"
}

# Restaura la imagen anterior guardada por setup (una generacion).
cmd_rollback() {
    [[ $# -eq 0 ]] || die "uso: $PROG rollback"
    need_root
    data_lock
    [[ -d "$ARXY_ROOT.old" ]] || die "no hay rollback pendiente (falta ${ARXY_ROOT}.old)"
    if [[ -d "$ARXY_ROOT" ]]; then
        local aside="$ARXY_ROOT.swap.$$"
        mv "$ARXY_ROOT" "$aside" || die "no pude apartar $ARXY_ROOT a $aside (¿permisos o espacio? revisa y reintenta; lo instalado sigue intacto)"
        mv "$ARXY_ROOT.old" "$ARXY_ROOT" || { mv "$aside" "$ARXY_ROOT"; die "rollback incompleto a $ARXY_ROOT.old (deje el original en su sitio; revisa espacio/permisos y reintenta '$PROG rollback')"; }
        mv "$aside" "$ARXY_ROOT.old"
    else
        mv "$ARXY_ROOT.old" "$ARXY_ROOT" || die "no pude restaurar $ARXY_ROOT.old a $ARXY_ROOT (¿permisos? rescata a mano con 'mv')"
    fi
    # version viaja DENTRO del root: el swap la rota sola, sin
    # copias. Si el root restaurado es del formato anterior (sin version dentro),
    # ensure_version la regenera en el proximo uso.
    # la atestacion .arxy-sig describe la generacion instalada por
    # setup; tras rotar, invalidar (ausente = no verificado, nunca rancio).
    rm -f "$ARXY_DATA/.arxy-sig"
    msg "rollback completo: imagen anterior restaurada en $ARXY_ROOT"
}
