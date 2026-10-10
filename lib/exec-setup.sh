# --- trailer arxy-setup (canonico): despacha $1 a cmd_*; recaptura ARXY_ARGV
# sin el subcomando para que need_root re-ejecute shim + canonico + args.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        setup|init) _entry=cmd_setup ;;
        rollback) _entry=cmd_rollback ;;
        *) printf '%s: error: arxy-setup solo entiende: setup|rollback\n' "$PROG" >&2; exit 1 ;;
    esac
    shift
    ARXY_ARGV=("$@")
    "$_entry" "$@"
fi
