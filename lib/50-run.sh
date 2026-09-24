# --- ejecucion (corre como usuario)
# canonicaliza una ruta sin fiarse del || entre comandos que escriben a
# stdout: busybox realpath no conoce -m, lo trata como operando (imprime
# su resolucion y falla) y el fallback duplicaria la ruta con un \n.
resolve_path() { # <ruta> -> ruta canonica (siempre tiene exito)
    local r
    if r="$(realpath -m "$1" 2>/dev/null)" && [[ "$r" != *$'\n'* ]]; then
        printf '%s' "$r"
    elif r="$(readlink -f "$1" 2>/dev/null)"; then
        printf '%s' "$r"
    else
        printf '%s' "$1"
    fi
}

RESOLVED_HOST="" # ruta equivalente en el host, si aplica (para chequeo musl)
RESOLVED_TARGET="" # resultado de resolve_target (global: $() perderia RESOLVED_HOST)

resolve_target() { # <bin|ruta> -> deja la ruta vista desde dentro en RESOLVED_TARGET
    local t="$1" h
    RESOLVED_HOST=""
    RESOLVED_TARGET=""
    if [[ "$t" == */* ]]; then
        [[ "$t" != /* ]] && t="$PWD/$t"
        t="$(resolve_path "$t")"
        case "$t" in
            /host/*) RESOLVED_TARGET="$t"; return 0 ;;
        esac
        if [[ "$t" == /usr/* || "$t" == /bin/* || "$t" == /sbin/* || "$t" == /etc/* ]] \
            && { [[ ! -e "$t" ]] || ! host_path_visible "$t"; }; then
            RESOLVED_TARGET="$t" # ruta del subsistema (ej. /usr/bin/...) aunque exista algo igual en el host
        elif [[ -e "$t" ]]; then
            RESOLVED_HOST="$t"
            if [[ "$_ARXY_LEVEL" == 2 ]] || host_path_visible "$t"; then
                RESOLVED_TARGET="$t"
            else
                RESOLVED_TARGET="/host$t"
            fi
        else
            RESOLVED_TARGET="$t" # no existe en host: asumir ruta del subsistema y dejar que falle alli
        fi
    else
        for cand in "/usr/bin/$t" "/usr/local/bin/$t" "/bin/$t" "/usr/sbin/$t"; do
            # -L ademas de -x: los symlinks absolutos (/usr/bin/x -> /opt/...)
            # cuelgan vistos desde el host aunque resuelvan bien dentro.
            if [[ -x "$ARXY_ROOT$cand" || -L "$ARXY_ROOT$cand" ]]; then RESOLVED_TARGET="$cand"; return 0; fi
        done
        h="$(command -v "$t" 2>/dev/null || true)"
        if [[ -n "$h" && -f "$h" ]]; then
            h="$(resolve_path "$h")"
            RESOLVED_HOST="$h"
            if [[ "$_ARXY_LEVEL" == 2 ]] || host_path_visible "$h"; then
                RESOLVED_TARGET="$h"
            else
                RESOLVED_TARGET="/host$h"
            fi
        else
            die "'$t' no encontrado. Prueba: $PROG install $t  o  $PROG search $t"
        fi
    fi
}

check_musl() { # avisa/aborta si el binario del host no puede correr sobre glibc
    [[ -z "$RESOLVED_HOST" || ! -f "$RESOLVED_HOST" ]] && return 0
    command -v file >/dev/null 2>&1 || return 0
    local info
    info="$(file -b "$RESOLVED_HOST" 2>/dev/null || true)"
    if grep -q 'ld-musl' <<<"$info"; then
        die "binario dinamico musl ($RESOLVED_HOST): no puede correr sobre glibc. Ejecutalo nativo en el host o consigue la version glibc/estatica."
    fi
}

cmd_run() {
    [[ $# -ge 1 ]] || die "uso: $PROG run <programa|ruta> [args...]"
    ensure_image
    level
    if [[ "$_ARXY_LEVEL" == 2 ]]; then
        [[ -x "$LD_LINUX" ]] || die "imagen rota: sin ld-linux en $LD_LINUX (reinstala con 'sudo $PROG setup')"
    else
        need_cmd bwrap
    fi
    local target="$1"
    shift
    resolve_target "$target" # sin $(): el subshell perderia RESOLVED_HOST
    target="$RESOLVED_TARGET"
    if [[ "$_ARXY_LEVEL" == 2 ]]; then
        bridge_env_l2 # L2 tambien integra el host (socket+token)
        [[ -n "$RESOLVED_HOST" ]] && exec "$target" "$@" # binario del host: nativo
        case "$target" in "$ARXY_ROOT"/*) ;; *) target="$ARXY_ROOT$target" ;; esac
        level2_env
        exec "$LD_LINUX" --library-path "$ARXY_LIBPATH" "$target" "$@"
    fi
    check_musl
    if [[ "$target" == *"/steam" ]]; then
        [[ -d "$ARXY_DATA/home/.local/share/Steam" ]] || msg "Steam descargará ~500 MB en la primera ejecución"
    fi
    run_in --chdir "$(inside_dir)" -- "$target" "$@"
}

# shell en nivel 2: bash del subsistema via ld-linux. Los nombres que el
# host no resuelve caen en command_not_found_handle (ver level2-rc de setup).
cmd_shell_level2() {
    level2_env
    bridge_env_l2 # la shell L2 tambien ve el bridge
    export PS1="(arxy:2) \\u@\\h \\w\\$ "
    local rcfile="$ARXY_DATA/level2-rc"
    if [[ $# -ge 1 ]]; then
        [[ -f "$rcfile" ]] && export BASH_ENV="$rcfile"
        # shellcheck disable=SC2145 # string de shell para bash -c (ver L1)
        exec "$LD_LINUX" --library-path "$ARXY_LIBPATH" "$ARXY_ROOT/bin/bash" -c "$*"
    fi
    if [[ "$(id -u)" -ne 0 ]]; then
        msg "sesion de usuario en nivel 2 (sin namespaces; para administrar: sudo $PROG shell)"
    fi
    if [[ -f "$rcfile" ]]; then
        exec "$LD_LINUX" --library-path "$ARXY_LIBPATH" "$ARXY_ROOT/bin/bash" --rcfile "$rcfile"
    else
        exec "$LD_LINUX" --library-path "$ARXY_LIBPATH" "$ARXY_ROOT/bin/bash"
    fi
}

cmd_shell() {
    ensure_image
    level
    if [[ "$_ARXY_LEVEL" == 2 ]]; then
        [[ -x "$LD_LINUX" ]] || die "imagen rota: sin ld-linux en $LD_LINUX (reinstala con 'sudo $PROG setup')"
        cmd_shell_level2 "$@"
        return
    fi
    need_cmd bwrap
    if [[ "$(id -u)" -ne 0 ]]; then
        msg "sesion de usuario (solo lectura del sistema; para administrar: sudo $PROG shell)"
    fi
    if [[ $# -ge 1 ]]; then
        # shell toma un STRING de shell (como ssh): unir con espacios para
        # bash -c. El re-exec a root ya preserva el argv; serializar con %q
        # aqui romperia pipes, redirects y comillas.
        # shellcheck disable=SC2145
        run_in --chdir "$(inside_dir)" --setenv PS1 "(arxy) \\u@\\h \\w\\$ " -- /bin/bash -c "$*"
    else
        run_in --chdir "$(inside_dir)" --setenv PS1 "(arxy) \\u@\\h \\w\\$ " --setenv ARXY_ACTIVE 1 -- /bin/bash
    fi
}

cmd_which() { # <bin|ruta> : donde se resolveria (subsistema vs host)
    [[ $# -eq 1 ]] || die "uso: $PROG which <programa|ruta>"
    ensure_image
    level
    resolve_target "$1"
    [[ -z "$RESOLVED_HOST" && "$_ARXY_LEVEL" == 2 ]] && RESOLVED_TARGET="$ARXY_ROOT$RESOLVED_TARGET"
    if [[ -n "$RESOLVED_HOST" ]]; then
        echo "$RESOLVED_TARGET  [host]"
    else
        echo "$RESOLVED_TARGET  [subsistema]"
    fi
}
