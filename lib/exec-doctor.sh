# --- trailer arxy-doctor (canonico): despacha $1 a cmd_*; recaptura ARXY_ARGV
# sin el subcomando para que need_root re-ejecute shim + canonico + args.
# cmd_doctor_json no es rama: lo invoca cmd_doctor con --json.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        doctor|check) _entry=cmd_doctor ;;
        quickstart|qs|start) _entry=cmd_quickstart ;;
        version|-v|--version) _entry=cmd_version ;;
        *) printf '%s: error: arxy-doctor solo entiende: doctor|quickstart|version\n' "$PROG" >&2; exit 1 ;;
    esac
    shift
    ARXY_ARGV=("$@")
    "$_entry" "$@"
fi
