# --- trailer arxy-maint (canonico): despacha $1 a cmd_*; recaptura ARXY_ARGV
# sin el subcomando para que need_root re-ejecute shim + canonico + args.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        clean|clean-cache) _entry=cmd_clean ;;
        gc) _entry=cmd_gc ;;
        dedup) _entry=cmd_dedup ;;
        *) printf '%s: error: arxy-maint solo entiende: clean|gc|dedup\n' "$PROG" >&2; exit 1 ;;
    esac
    shift
    ARXY_ARGV=("$@")
    "$_entry" "$@"
fi
