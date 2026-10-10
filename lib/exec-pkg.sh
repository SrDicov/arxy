# --- trailer arxy-pkg (canonico): despacha $1 a cmd_*; recaptura ARXY_ARGV
# sin el subcomando para que need_root re-ejecute shim + canonico + args.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        install|i|add) _entry=cmd_install ;;
        remove|rm|uninstall) _entry=cmd_remove ;;
        update|up|upgrade) _entry=cmd_update ;;
        __install-file) _entry=cmd_install_file ;;
        *) printf '%s: error: arxy-pkg solo entiende: install|remove|update|__install-file\n' "$PROG" >&2; exit 1 ;;
    esac
    shift
    ARXY_ARGV=("$@")
    "$_entry" "$@"
fi
