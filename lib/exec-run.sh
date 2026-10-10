# --- trailer arxy-run (canonico): despacha $1 a cmd_*; recaptura ARXY_ARGV
# sin el subcomando para que need_root re-ejecute shim + canonico + args.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        run|r|exec|x) _entry=cmd_run ;;
        which|w) _entry=cmd_which ;;
        shell|sh|enter) _entry=cmd_shell ;;
        *) printf '%s: error: arxy-run solo entiende: run|which|shell\n' "$PROG" >&2; exit 1 ;;
    esac
    shift
    ARXY_ARGV=("$@")
    "$_entry" "$@"
fi
