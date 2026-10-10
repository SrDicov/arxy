#!/usr/bin/env bash
# test-packaging.sh — template xbps estatico (L5, sin root).
# Pinea: nombres FILESDIR<->vbin<->src/arxy*, version == ARXY_VERSION,
# depends cubre las deps duras de install.sh (direccion documentada, no
# igualdad: el template anade desktop-file-utils/minisign/sudo y omite
# sha256sum; ver PLAN-TESTING §9), conf preservada + pubkey renovada,
# symlink axy. xbps-src/xbps en Void real (L5 resto, no aqui).
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 1
# shellcheck source=lib.sh
. "$HERE/lib.sh" # ok/no/finish
TPL="packaging/void/arxy/template"

echo "== sintaxis =="
bash -n "$TPL" 2>/dev/null && ok "bash -n template" || no "bash -n template"

echo "== nombres: vbin + loop == src/arxy* =="
loop="$(grep -o 'for _b in [^;]*' "$TPL" | head -n 1 | sed 's/^for _b in //')"
names="arxy"
for b in $loop; do names="$names arxy-$b"; done
have="$(cd src && ls arxy* | tr '\n' ' ')"
[[ "$(printf '%s' "$names" | tr ' ' '\n' | sort | tr '\n' ' ')" == "$(printf '%s' "$have" | tr ' ' '\n' | sort | tr '\n' ' ')" ]] \
    && ok "vbin cubre src/arxy*" || no "vbin cubre src" "quiere[$names] hay[$have]"
grep -q 'vbin ${FILESDIR}/arxy$' "$TPL" && ok "vbin arxy explicito" || no "vbin arxy"
grep -q 'ln -sf arxy ${DESTDIR}/usr/bin/axy' "$TPL" && ok "axy symlink" || no "axy symlink"

echo "== version pineada =="
lv="$(grep '^ARXY_VERSION=' lib/00-head.sh | cut -d'"' -f2)"
tv="$(grep '^version=' "$TPL" | cut -d= -f2)"
[[ -n "$lv" && "$lv" == "$tv" ]] && ok "version $lv" || no "version" "lib=$lv template=$tv"

echo "== depends cubre hard-deps de install.sh (menos sha256sum) =="
ideps="$(grep -o 'for c in [^;]*' install.sh | head -n 1 | sed 's/^for c in //')"
tdeps="$(grep '^depends=' "$TPL" | sed 's/^depends=//;s/"//g')"
miss=""
for c in $ideps; do
    [[ "$c" == sha256sum ]] && continue # solo instalador, no runtime
    want="$c"; [[ "$c" == bwrap ]] && want="bubblewrap" # nombre de paquete xbps
    grep -qw "$want" <<<"$tdeps" || miss="$miss $c"
done
[[ -z "$miss" ]] && ok "depends superset" || no "depends superset" "faltan:$miss"

echo "== conf preservada, pubkey renovada =="
grep -q 'conf_files="/etc/arxy/arxy.conf"' "$TPL" && ok "conf_files preserva conf" || no "conf_files"
if grep -q 'arxy.pub' <<<"$(grep '^conf_files=' "$TPL")"; then
    no "pubkey fuera de conf_files"
else
    ok "pubkey fuera de conf_files (se renueva)"
fi

finish
