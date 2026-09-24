# --- estado persistente, recuperacion y verificacion de imagen
# version estructurado (format 1). El plano legacy (url=/date=) se
# acepta al leer y se migra al escribir. Sin jq: printf al emitir, grep al leer.
data_sync() { # <paths...> : fsync best-effort; nunca falla setup
    # sync con operandos (coreutils) vacia los filesystems que los contienen
    # (syncfs); sin operandos o en busybox es global. Correcto en ambos
    # casos, mas caro en el segundo. Orden de llamada: fichero -> dir.
    sync "$@" 2>/dev/null || sync 2>/dev/null || true
}
_newest_first() { # <prefijo> : "$prefijo"* mas reciente primero (una linea)
    local p
    for p in "$1"*; do [[ -e "$p" ]] || continue
        printf '%s\t%s\n' "$(stat -c %Y "$p" 2>/dev/null || echo 0)" "$p"
    done | sort -rn | cut -f2-
}
staging_inventory() { # huerfanos de setup/rollback: "<accion>\t<path>"; pura
    # Una sola logica para recover_staging (aplica) y fix_probe (lista): un
    # fix en uno se refleja en el otro. Acciones: remove | recover-root
    # (R ausente) | replace-root (R invalido) | rotate-old (R valido).
    # Orden: .old.tmp estuvo VIVO (staging nunca); el mas reciente gana.
    local D="$ARXY_DATA" R="$ARXY_ROOT" p
    local r_exists=0 r_valid=0 filled_root=0 filled_old=0
    [[ -e "$R" ]] && r_exists=1
    image_ok 2>/dev/null && r_valid=1
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        if (( ! r_exists && ! filled_root )) && _image_ok "$p"; then
            printf 'recover-root\t%s\n' "$p"; filled_root=1; r_exists=1; r_valid=1
        elif (( r_valid && ! filled_old )) && _image_ok "$p"; then
            printf 'rotate-old\t%s\n' "$p"; filled_old=1
        elif (( r_exists && ! r_valid && ! filled_root )) && _image_ok "$p"; then
            printf 'replace-root\t%s\n' "$p"; filled_root=1; r_valid=1
        else
            printf 'remove\t%s\n' "$p"
        fi
    done < <(_newest_first "$R.old.tmp.")
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        if (( r_valid || filled_root )); then
            printf 'remove\t%s\n' "$p"
        elif (( ! filled_root )) && _image_ok "$p"; then
            if (( r_exists )); then
                printf 'replace-root\t%s\n' "$p"
            else
                printf 'recover-root\t%s\n' "$p"
            fi
            filled_root=1; r_exists=1; r_valid=1
        else
            printf 'remove\t%s\n' "$p"
        fi
    done < <(_newest_first "$R.new.")
    local s
    for s in "$D"/.image.partial.*; do
        [[ -e "$s" ]] || continue
        printf 'remove\t%s\n' "$s"
    done
    for s in "$R".swap.*; do
        [[ -e "$s" ]] || continue
        # Swap = root ex-vivo completo: nunca se borra si es lo mejor
        # disponible; solo sobra con un root valido ya en su sitio.
        if (( ! r_exists && ! filled_root )); then
            printf 'recover-root\t%s\n' "$s"; filled_root=1
        elif (( r_exists && ! r_valid && ! filled_root )); then
            printf 'replace-root\t%s\n' "$s"; filled_root=1
        else
            printf 'remove\t%s\n' "$s"
        fi
    done
    return 0
}
recover_staging() { # aplica staging_inventory; log a stderr; rc 0 siempre
    local acc path R="$ARXY_ROOT"
    while IFS=$'\t' read -r acc path; do
        [[ -n "${path:-}" ]] || continue
        case "$acc" in
            remove) if rm -rf "${path:?}" 2>/dev/null; then msg "recuperado: huerfano borrado de $path" >&2;
                else msg "aviso: no pude recuperar $path (huerfano no borrado)" >&2; fi ;;
            recover-root) if mv "$path" "$R" 2>/dev/null; then msg "recuperado: root restaurado de $path" >&2;
                else msg "aviso: no pude recuperar $path (root no restaurado)" >&2; fi ;;
            replace-root) rm -rf "${R:?}" 2>/dev/null || msg "aviso: no pude borrar root invalido $R" >&2
                if mv "$path" "$R" 2>/dev/null; then msg "recuperado: root invalido reemplazado de $path" >&2;
                else msg "aviso: no pude recuperar $path (root invalido no reemplazado)" >&2; fi ;;
            rotate-old) rm -rf "${R:?}.old" 2>/dev/null || msg "aviso: no pude borrar $R.old" >&2
                if mv "$path" "$R.old" 2>/dev/null; then msg "recuperado: rotado a .old de $path" >&2;
                else msg "aviso: no pude recuperar $path (no rotado a .old)" >&2; fi ;;
        esac
    done < <(staging_inventory)
    return 0
}
ensure_version() { # root valido sin version util: regenera; rc 0 siempre
    image_ok || return 0
    local f="$ARXY_VERSION_FILE" legacy="$ARXY_VERSION_LEGACY"
    if [[ -f "$f" ]] && { grep -q '"format": 1' "$f" 2>/dev/null || grep -q '^url=' "$f" 2>/dev/null; }; then
        [[ "$legacy" != "$f" ]] && rm -f "$legacy" 2>/dev/null || true
        return 0
    fi
    [[ -f "$f" ]] && msg "aviso: version ilegible, regenero" >&2
    # Sin permiso (usuario normal en root real): callar, setup como root
    # regenera. El mkdir distingue: si el puede crear, el write puede escribir.
    mkdir -p "${f%/*}" 2>/dev/null || return 0
    write_version "${ARXY_IMAGE_URL:-}" "${ARXY_IMAGE_SHA256:-}" >/dev/null 2>&1 \
        || { msg "aviso: no pude regenerar version" >&2; return 0; }
    [[ "$legacy" != "$f" ]] && rm -f "$legacy" 2>/dev/null || true
    return 0
}
write_version() { # <image-url> <sha256> [created_at] : JSON atomico (0|1)
    local url="$1" sha="${2:-}" now="${3:-}" tmp
    [[ -z "$now" ]] && now="$(date -u +%FT%TZ 2>/dev/null || true)"
    tmp="$(mktemp "${ARXY_VERSION_FILE%/*}/.version.XXXXXX" 2>/dev/null || true)"
    [[ -n "$tmp" ]] || return 1
    {
        printf '{"format": 1'
        printf ', "image": %s' "$(json_str "$url")"
        printf ', "sha256": %s' "$(json_str_or_null "$sha")"
        printf ', "created_at": %s' "$(json_str_or_null "$now")"
        printf ', "arxy_version": %s}\n' "$(json_str "$ARXY_VERSION")"
    } >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    chmod 0644 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$ARXY_VERSION_FILE" 2>/dev/null || { rm -f "$tmp"; return 1; }
    return 0
}
version_field() { # <url|date> : valor (JSON o plano); rc 1 si falta
    local k="$1" f="$ARXY_VERSION_FILE" jk line
    [[ -f "$f" ]] || return 1
    case "$k" in url) jk=image ;; date) jk=created_at ;; *) return 1 ;; esac
    line="$(grep -m1 -oE "\"$jk\": \"[^\"]*\"" "$f" 2>/dev/null || true)"
    if [[ -n "$line" ]]; then cut -d'"' -f4 <<<"$line"; return 0; fi
    grep -m1 "^$k=" "$f" 2>/dev/null | cut -d= -f2- || return 1
}
version_line() { # "url=... date=..." (ambos formatos; vacio si falta)
    local u d
    u="$(version_field url || true)"; d="$(version_field date || true)"
    # lectura con fichero corrupto daba campos vacios sin pista
    # (el proximo setup lo regeneraba con aviso, pero el usuario cansado
    # no lo veia). Avisar a stderr sin tocar stdout.
    if [[ -f "$ARXY_VERSION_FILE" && -z "$u$d" ]]; then
        msg "aviso: version ilegible, regenero en el proximo setup/install" >&2
    fi
    echo "url=$u date=$d"
}
# TODO: deuda viva. Remover en v0.6.0 o cuando no haya instalaciones v0.1 activas.
migrate_version_file() { # plano -> JSON atomico; idempotente; rc 0 (avisa)
    local f="$ARXY_VERSION_FILE"
    [[ -f "$f" ]] || return 0
    grep -q '"format": 1' "$f" 2>/dev/null && return 0
    local url="" date=""
    url="$(grep -m1 '^url=' "$f" 2>/dev/null | cut -d= -f2- || true)"
    date="$(grep -m1 '^date=' "$f" 2>/dev/null | cut -d= -f2- || true)"
    if [[ -z "$url$date" ]]; then
        msg "aviso: version corrupto (ni JSON ni plano), no migro" >&2
        return 0
    fi
    if [[ ! -w "$f" && ! -w "${f%/*}" ]]; then
        return 0 # sin permiso (usuario normal): setup como root migrará; callar
    fi
    write_version "$url" "" "$date" 2>/dev/null || msg "aviso: no pude migrar version a JSON" >&2
    return 0
}

verify_signature() { # <tarball> <sig> <pub> -> 0 ok, 1 invalida, 2 sin minisign, 3 sin pub, 4 sin sig
    local tarball="$1" sig="$2" pub="$3"
    command -v minisign >/dev/null 2>&1 || return 2
    [[ -n "${pub:-}" && -f "$pub" ]] || return 3
    [[ -n "${sig:-}" && -f "$sig" && -s "$sig" ]] || return 4
    minisign -V -p "$pub" -m "$tarball" -x "$sig" >/dev/null 2>&1 || return 1
    return 0
}

enforce_signature_policy() { # <rc> : aplica ARXY_SIGNATURE_POLICY (die, warn o sigue)
    local rc="${1:-1}" pol="${ARXY_SIGNATURE_POLICY:-optional}"
    case "$pol" in
        required)
            [[ "$rc" == 0 ]] || die "firma minisign no valida (rc=$rc, policy=required)" ;;
        optional)
            case "$rc" in
                0) : ;;
                2) msg "aviso: sin minisign en el host, omitiendo verificacion de firma" >&2 ;;
                *) die "firma minisign no valida (rc=$rc, policy=optional)" ;;
            esac ;;
        off) : ;;
        *) die "ARXY_SIGNATURE_POLICY invalida: '$pol' (required|optional|off)" ;;
    esac
    return 0
}

sig_should_verify() { # 0 = descargar .minisig y verificar, 1 = omitir
    local pol="${ARXY_SIGNATURE_POLICY:-optional}"
    [[ "$pol" == off ]] && return 1
    [[ -n "${ARXY_IMAGE_SHA256:-}" ]] && return 1 # el pin ya ancla
    case "${ARXY_IMAGE_URL:-}" in http://*|https://*) return 0 ;; esac
    return 1 # file:// y demas: desarrollo local, sin release que firmarlo
}

sig_check_compat() { # die si pin + required (fail closed: required exige firma)
    [[ "${ARXY_SIGNATURE_POLICY:-optional}" == required && -n "${ARXY_IMAGE_SHA256:-}" ]] \
        || return 0
    die "ARXY_IMAGE_SHA256 pineado incompatible con ARXY_SIGNATURE_POLICY=required (el pin omite la firma; quita el pin o pon optional)"
}
