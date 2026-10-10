# --- trailer arxy-desktop (canonico): despacha $1 a cmd_*; recaptura ARXY_ARGV
# sin el subcomando para que need_root re-ejecute shim + canonico + args.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        export) _entry=cmd_export ;;
        unexport) _entry=cmd_unexport ;;
        desktop) _entry=cmd_desktop ;;
        *) printf '%s: error: arxy-desktop solo entiende: export|unexport|desktop\n' "$PROG" >&2; exit 1 ;;
    esac
    shift
    ARXY_ARGV=("$@")
    "$_entry" "$@"
fi
