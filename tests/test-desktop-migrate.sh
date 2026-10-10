#!/usr/bin/env bash
# test-desktop-migrate.sh — `arxy desktop --migrate` etiqueta .desktop legacy
# sin X-Arxy-Pkg. Sin root ni imagen: XDG_DATA_HOME
# aislado, funciones en directo + una pasada por el CLI (migrate no exige
# imagen). Idempotente: la 2a corrida es no-op.
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
# shellcheck source=lib.sh
. "$HERE/lib.sh" # ARXY_BIN default: repo (no el instalado viejo)
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export XDG_DATA_HOME="$T/xdg" ARXY_ROOT="$T/root"
mkdir -p "$XDG_DATA_HOME"
# shellcheck source=../lib/00-head.sh
. "$HERE/../lib/00-head.sh" >/dev/null 2>&1
# shellcheck source=../lib/41-desktop.sh
. "$HERE/../lib/41-desktop.sh" >/dev/null 2>&1
update_desktop_db() { return 0; }

ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1${2:+ (tengo '$2')}"; FAIL=$((FAIL+1)); }

[[ "$REAL_APPS" == "$T/xdg/applications" ]] && ok "REAL_APPS aislado" || no "REAL_APPS aislado" "$REAL_APPS"
mkdir -p "$REAL_APPS"

printf '[Desktop Entry]\nName=Legacy\nExec=legacy-bin %%F\nType=Application\n' >"$REAL_APPS/arxy-legacy.desktop"
printf '[Desktop Entry]\nName=Ok\nExec=arxy run /usr/bin/ok\nType=Application\nX-Arxy-Pkg=ok\n' >"$REAL_APPS/arxy-ok.desktop"
sha_ok="$(sha256sum "$REAL_APPS/arxy-ok.desktop" | cut -d' ' -f1)"

cmd_desktop_migrate >/dev/null 2>&1
grep -q '^X-Arxy-Pkg=legacy$' "$REAL_APPS/arxy-legacy.desktop" && ok "legacy gana tag inferido" || no "legacy gana tag inferido"
grep -q '^Name=Legacy$' "$REAL_APPS/arxy-legacy.desktop" && ok "legacy conserva Name" || no "legacy conserva Name"
grep -q '^Exec=legacy-bin %F$' "$REAL_APPS/arxy-legacy.desktop" && ok "legacy conserva Exec" || no "legacy conserva Exec"
[[ "$(sha256sum "$REAL_APPS/arxy-ok.desktop" | cut -d' ' -f1)" == "$sha_ok" ]] && ok "taggeado intacto" || no "taggeado intacto"

sha_leg="$(sha256sum "$REAL_APPS/arxy-legacy.desktop" | cut -d' ' -f1)"
cmd_desktop_migrate >/dev/null 2>&1
[[ "$(sha256sum "$REAL_APPS/arxy-legacy.desktop" | cut -d' ' -f1)" == "$sha_leg" ]] && ok "idempotente (2a corrida no-op)" || no "idempotente"

# Sin trailing newline: igual migra sin pegar lineas.
printf '[Desktop Entry]\nName=NoNL\nExec=nonl-bin' >"$REAL_APPS/arxy-nonl.desktop"
cmd_desktop_migrate >/dev/null 2>&1
grep -q '^X-Arxy-Pkg=nonl$' "$REAL_APPS/arxy-nonl.desktop" && ok "sin-newline migra limpio" || no "sin-newline migra limpio"
[[ "$(grep -c '^X-Arxy-Pkg=' "$REAL_APPS/arxy-nonl.desktop")" -eq 1 ]] && ok "un solo tag" || no "un solo tag"

# Dispatch por CLI (migrate no exige root ni imagen).
printf '[Desktop Entry]\nName=Cli\nExec=cli-bin\nType=Application\n' >"$REAL_APPS/arxy-cli.desktop"
if XDG_DATA_HOME="$T/xdg" ARXY_ROOT="$T/root" "$ARXY_BIN" desktop --migrate >/dev/null 2>&1 \
    && grep -q '^X-Arxy-Pkg=cli$' "$REAL_APPS/arxy-cli.desktop"; then
    ok "CLI desktop --migrate"
else
    no "CLI desktop --migrate"
fi
_mig_out="$(XDG_DATA_HOME="$T/xdg" ARXY_ROOT="$T/root" "$ARXY_BIN" desktop --migrate 2>&1)"
if grep -q 'migrados' <<<"$_mig_out"; then
    ok "CLI informa resumen"
else
    no "CLI informa resumen"
fi

# Uso ante arg desconocido.
if XDG_DATA_HOME="$T/xdg" ARXY_ROOT="$T/root" "$ARXY_BIN" desktop --foo >/dev/null 2>&1; then
    no "desktop --foo falla"
else
    ok "desktop --foo falla"
fi

# Ayuda documenta el subcomando.
grep -q 'desktop --migrate' "$HERE/../lib/70-help.sh" && ok "help documenta migrate" || no "help documenta migrate"

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
