#!/usr/bin/env bash
# test-pkgbuild-syntax.sh — los PKGBUILDs de packaging/aur/ son bash valido
# (drafts aun no publicados). namcap si existe (Arch), si no SKIP honesto.
set -uo pipefail
FAIL=0
cd "$(dirname "$0")/.." || exit 1
for p in packaging/aur/*/PKGBUILD; do
    if bash -n "$p" 2>/dev/null; then echo "PASS: bash -n $p";
    else echo "FAIL: bash -n $p"; FAIL=$((FAIL+1)); fi
done
# Coherencia: todo depends del PKGBUILD existe en arxy_gaming_pkgs()
# (salvo pin =ver, que solo vive en bash). Fuente: lib en este repo.
# shellcheck source=../lib/00-head.sh
. "$(dirname "$0")/../lib/00-head.sh" >/dev/null 2>&1
# shellcheck source=../lib/60-detect.sh
. "$(dirname "$0")/../lib/60-detect.sh" >/dev/null 2>&1
# shellcheck source=../lib/61-doctor.sh
. "$(dirname "$0")/../lib/61-doctor.sh" >/dev/null 2>&1
# shellcheck source=../lib/62-json.sh
. "$(dirname "$0")/../lib/62-json.sh" >/dev/null 2>&1
# shellcheck source=../lib/30-package.sh
. "$(dirname "$0")/../lib/30-package.sh" >/dev/null 2>&1
for v in nvidia amd intel; do
    # bash con pin simulado (el pin =ver solo vive en bash, se compara nombre)
    if [[ "$v" == nvidia ]]; then
        mapfile -t _bash < <( ( detect_nvidia_ver() { echo 1.0; }; arxy_gaming_pkgs nvidia ) 2>/dev/null | sed 's/=.*//')
    else
        mapfile -t _bash < <(arxy_gaming_pkgs "$v" 2>/dev/null)
    fi
    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        if printf '%s\n' "${_bash[@]}" | grep -qxF "$dep"; then :;
        else echo "FAIL: $v: depends $dep sin espejo bash"; FAIL=$((FAIL+1)); fi
    done < <( ( . "packaging/aur/arxy-gaming-$v/PKGBUILD"; printf '%s\n' "${depends[@]}" ) 2>/dev/null )
    echo "PASS: coherencia arxy-gaming-$v"
done
if command -v namcap >/dev/null 2>&1; then
    for p in packaging/aur/*/PKGBUILD; do
        if namcap "$p" 2>&1 | grep -qE "^(E|W).*PKGBUILD"; then
            echo "FAIL: namcap $p"; FAIL=$((FAIL+1))
        else echo "PASS: namcap $p"; fi
    done
else
    echo "SKIP: namcap ausente (solo bash -n)"
fi
echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
