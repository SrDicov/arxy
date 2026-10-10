#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# zz-dispatch.sh — shim `arxy`: despacha subcomandos a sub-binarios via exec.
# Standalone a proposito: no sourcea lib/*.sh (el bundle parsea config y
# valida args). Al sourcearse (tests) no ejecuta nada: main solo corre con
# BASH_SOURCE[0] == $0, igual que antes.
#
# Branch -> (bundle, canonico). El canonico viaja en ARXY_CMD para que
# need_root re-ejecute shim + subcomando + args (ver 00-head.sh). El bundle
# recibe el canonico como $1 y su trailer lo despacha a cmd_*.

set -uo pipefail

PROG="arxy"
_ARXY_SHIM="$(readlink -f "$0" 2>/dev/null || echo "$0")"
_ARXY_BINDIR="$(dirname "$_ARXY_SHIM")"

_arxy_exec() { # <bundle> <canonico> [args...] : nunca retorna
    local bundle="$1" cmd="$2"; shift 2
    local bin="$_ARXY_BINDIR/arxy-$bundle"
    if [[ ! -x "$bin" ]]; then
        printf '%s: error: falta sub-binario %s (¿instalacion incompleta?)\n' "$PROG" "$bin" >&2
        exit 1
    fi
    ARXY_SELF="$_ARXY_SHIM" ARXY_CMD="$cmd" exec "$bin" "$cmd" "$@"
}

_arxy_die() { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 1; }

main() {
    [[ $# -ge 1 ]] || { _arxy_exec help help; }
    local cmd="$1"
    shift
    # --help tras el comando: ayuda global (evita que 'install --help' intente
    # instalar un paquete llamado --help). Ayuda por-comando no existe a
    # proposito: cada mal uso ya imprime su 'uso:' de una linea.
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        _arxy_exec help help
    fi
    case "$cmd" in
        install | i | add)          _arxy_exec pkg install "$@" ;;
        remove | rm | uninstall)    _arxy_exec pkg remove "$@" ;;
        update | up | upgrade)      _arxy_exec pkg update "$@" ;;
        clean | clean-cache)        _arxy_exec maint clean "$@" ;;
        gc)                         _arxy_exec maint gc "$@" ;;
        dedup)                      _arxy_exec maint dedup "$@" ;;
        info | show)                _arxy_exec query info "$@" ;;
        list | l | ls | installed)  _arxy_exec query list "$@" ;;
        search | s | find)          _arxy_exec query search "$@" ;;
        search-aur | sa)            _arxy_exec query search-aur "$@" ;;
        __install-file)             _arxy_exec pkg __install-file "$@" ;;
        run | r | exec | x)         _arxy_exec run run "$@" ;;
        which | w)                  _arxy_exec run which "$@" ;;
        shell | sh | enter)         _arxy_exec run shell "$@" ;;
        export)                     _arxy_exec desktop export "$@" ;;
        unexport)                   _arxy_exec desktop unexport "$@" ;;
        desktop)                    _arxy_exec desktop desktop "$@" ;;
        doctor | check)             _arxy_exec doctor doctor "$@" ;;
        quickstart | qs | start)    _arxy_exec doctor quickstart "$@" ;;
        setup | init)               _arxy_exec setup setup "$@" ;;
        rollback)                   _arxy_exec setup rollback "$@" ;;
        host-bridge)                _arxy_exec bridge host-bridge "$@" ;;
        version | -v | --version)   _arxy_exec doctor version "$@" ;;
        help | -h | --help)         _arxy_exec help help "$@" ;;
        -*)                         _arxy_die "flag desconocida: $cmd. Prueba: $PROG help" ;;
        *)                          _arxy_exec run run "$cmd" "$@" ;; # atajo: 'arxy firefox'
    esac
}

# La biblioteca generada se sourcea en tests sin ejecutar el router; como
# programa conserva el mismo punto de entrada.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
