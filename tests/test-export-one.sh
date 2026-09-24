#!/usr/bin/env bash
# test-export-one.sh — ramas de export_one/pkg_desktops: NoDisplay, Name/Exec ausentes,
# codigos %F, resolucion de binario y recorte de prefijo L2. Sin root ni imagen: rootfs y XDG
# en /tmp, run_pacman stubbed.
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"

D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT
export ARXY_ROOT="$D/root" XDG_DATA_HOME="$D/xdg"
mkdir -p "$ARXY_ROOT/usr/share/applications" "$ARXY_ROOT/usr/bin" "$XDG_DATA_HOME/applications"
: > "$ARXY_ROOT/usr/bin/foo"; chmod +x "$ARXY_ROOT/usr/bin/foo"

# shellcheck source=../lib/00-head.sh
. "$HERE/../lib/00-head.sh" >/dev/null 2>&1
# shellcheck source=../lib/41-desktop.sh
. "$HERE/../lib/41-desktop.sh" >/dev/null 2>&1
# shellcheck source=../lib/31-aur.sh
. "$HERE/../lib/31-aur.sh" >/dev/null 2>&1 # check_pkg_name para T7

ensure_image() { return 0; }
update_desktop_db() { return 0; }
# run_pacman L1 pelado por defecto; T6 lo redefine con prefijo L2.
run_pacman() { [[ "${1:-}" == "-Qlq" ]] && printf '/usr/share/applications/%s\n' "$2"; return 0; }

ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
mkdesk() { # <file> <contenido...>: fixture .desktop en el rootfs
    local f="$1"; shift
    printf '%s\n' "$@" > "$ARXY_ROOT/usr/share/applications/$f"
}

echo "== T1: NoDisplay=true no emite lanzador"
mkdesk nodisp.desktop "[Desktop Entry]" "Name=Nodisp" "Exec=foo" "NoDisplay=true" "Type=Application"
export_one "$ARXY_ROOT/usr/share/applications/nodisp.desktop" nodisp-pkg
[[ ! -e "$XDG_DATA_HOME/applications/arxy-nodisp.desktop" ]] && ok "T1 NoDisplay" || no "T1 NoDisplay"

echo "== T2: sin Name no emite"
mkdesk noname.desktop "[Desktop Entry]" "Exec=foo" "Type=Application"
export_one "$ARXY_ROOT/usr/share/applications/noname.desktop" noname-pkg
[[ ! -e "$XDG_DATA_HOME/applications/arxy-noname.desktop" ]] && ok "T2 sin Name" || no "T2 sin Name"

echo "== T3: sin Exec no emite"
mkdesk noexec.desktop "[Desktop Entry]" "Name=Noexec" "Type=Application"
export_one "$ARXY_ROOT/usr/share/applications/noexec.desktop" noexec-pkg
[[ ! -e "$XDG_DATA_HOME/applications/arxy-noexec.desktop" ]] && ok "T3 sin Exec" || no "T3 sin Exec"

echo "== T4: Exec con %F preserva codigos + X-Arxy-Pkg"
mkdesk codes.desktop "[Desktop Entry]" "Name=Codes" "Exec=foo %F" "Type=Application"
export_one "$ARXY_ROOT/usr/share/applications/codes.desktop" codes-pkg
out="$(cat "$XDG_DATA_HOME/applications/arxy-codes.desktop" 2>/dev/null)"
grep -q "^Exec=arxy run /usr/bin/foo %F$" <<<"$out" && grep -q "^X-Arxy-Pkg=codes-pkg$" <<<"$out" && ok "T4 %F+tag" || no "T4 %F+tag ($out)"

echo "== T5: binario relativo resuelve a /usr/bin del rootfs"
mkdesk rel.desktop "[Desktop Entry]" "Name=Rel" "Exec=foo" "Type=Application"
export_one "$ARXY_ROOT/usr/share/applications/rel.desktop" rel-pkg
grep -q "^Exec=arxy run /usr/bin/foo$" "$XDG_DATA_HOME/applications/arxy-rel.desktop" 2>/dev/null && ok "T5 resuelve" || no "T5 resuelve"

echo "== T6: pkg_desktops recorta prefijo L2 (--root)"
run_pacman() { [[ "${1:-}" == "-Qlq" ]] && printf '%s/usr/share/applications/%s.desktop\n' "$ARXY_ROOT" "$2"; return 0; }
out="$(pkg_desktops alga)"
[[ "$out" == "/usr/share/applications/alga.desktop" ]] && ok "T6 recorte L2" || no "T6 recorte L2 ($out)"

echo "== T7: cmd_export valida nombre ANTES de ensure_image"
out="$(cmd_export "a b" 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "nombre de paquete invalido" <<<"$out" && ok "T7 nombre con espacio muere claro" || no "T7 nombre con espacio ($rc: $out)"
out="$(cmd_export "" 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "nombre de paquete invalido" <<<"$out" && ok "T7 vacio muere claro" || no "T7 vacio ($rc: $out)"

echo "== T8: export --all etiqueta deducido, no literal ()"
rm -f "$XDG_DATA_HOME/applications"/arxy-*.desktop
cmd_export --all >/dev/null 2>&1
! grep -rq "^X-Arxy-Pkg=--all$" "$XDG_DATA_HOME/applications/" 2>/dev/null && ok "T8 sin literal --all" || no "T8 sin literal --all"
grep -q "^X-Arxy-Pkg=codes$" "$XDG_DATA_HOME/applications/arxy-codes.desktop" 2>/dev/null && ok "T8 deducido codes" || no "T8 deducido codes"

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
