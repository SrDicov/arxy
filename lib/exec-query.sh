# --- trailer arxy-query (canonico): despacha $1 a cmd_*; recaptura ARXY_ARGV
# sin el subcomando para que need_root re-ejecute shim + canonico + args.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        info|show) _entry=cmd_info ;;
        list|l|ls|installed) _entry=cmd_list ;;
        search|s|find) _entry=cmd_search ;;
        search-aur|sa) _entry=cmd_search_aur ;;
        *) printf '%s: error: arxy-query solo entiende: info|list|search|search-aur\n' "$PROG" >&2; exit 1 ;;
    esac
    shift
    ARXY_ARGV=("$@")
    "$_entry" "$@"
fi
