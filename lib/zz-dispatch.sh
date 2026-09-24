# --- dispatch
main() {
    [[ $# -ge 1 ]] || { cmd_help; return 0; }
    local cmd="$1"
    shift
    # --help tras el comando: ayuda global. Evita que 'install --help' intente
    # instalar un paquete llamado --help. Ayuda por-comando no existe a proposito
    # (cada mal uso ya imprime su 'uso:' de una linea).
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        cmd_help
        return 0
    fi
    case "$cmd" in
        install | i | add)          cmd_install "$@" ;;
        remove | rm | uninstall)    cmd_remove "$@" ;;
        update | up | upgrade)      cmd_update "$@" ;;
        clean | clean-cache)        cmd_clean "$@" ;;
        gc)                         cmd_gc "$@" ;;
        dedup)                      cmd_dedup "$@" ;;
        info | show)                cmd_info "$@" ;;
        list | l | ls | installed)  cmd_list "$@" ;;
        search | s | find)          cmd_search "$@" ;;
        search-aur | sa)            cmd_search_aur "$@" ;;
        __install-file)             cmd_install_file "$@" ;;
        run | r | exec | x)         cmd_run "$@" ;;
        which | w)                  cmd_which "$@" ;;
        shell | sh | enter)         cmd_shell "$@" ;;
        export)                     cmd_export "$@" ;;
        unexport)                   cmd_unexport "$@" ;;
        desktop)                    cmd_desktop "$@" ;;
        doctor | check)             cmd_doctor "$@" ;;
        quickstart | qs | start)    cmd_quickstart "$@" ;;
        setup | init)               cmd_setup "$@" ;;
        rollback)                   cmd_rollback "$@" ;;
        host-bridge)                cmd_host_bridge "$@" ;;
        version | -v | --version)   cmd_version "$@" ;;
        help | -h | --help)         cmd_help "$@" ;;
        -*)                         die "flag desconocida: $cmd. Prueba: $PROG help" ;;
        *)                          cmd_run "$cmd" "$@" ;; # atajo: 'arxy firefox'
    esac
}

# La biblioteca generada se puede sourcear en tests/herramientas sin ejecutar
# el router. Como programa conserva exactamente el mismo punto de entrada.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
