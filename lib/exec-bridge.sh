# --- trailer arxy-bridge (canonico): despacha $1 a cmd_*; recaptura ARXY_ARGV
# sin el subcomando para que need_root re-ejecute shim + canonico + args.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        host-bridge) _entry=cmd_host_bridge ;;
        *) printf '%s: error: arxy-bridge solo entiende: host-bridge\n' "$PROG" >&2; exit 1 ;;
    esac
    shift
    ARXY_ARGV=("$@")
    "$_entry" "$@"
fi
