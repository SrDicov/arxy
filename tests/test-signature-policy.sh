#!/usr/bin/env bash
# test-signature-policy.sh — ARXY_SIGNATURE_POLICY: parseo desde
# conf, precedencia env > user-conf > sys-conf, valor invalido = die,
# ausente = optional. Sin root ni red (confs fixture, source en subshell).
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT
export ARXY_ROOT="$D/root" ARXY_DATA="$D/data"
mkdir -p "$ARXY_DATA"
# shellcheck source=../lib/00-head.sh
. "$HERE/../lib/00-head.sh" >/dev/null 2>&1
# shellcheck source=../lib/20-state.sh
. "$HERE/../lib/20-state.sh" >/dev/null 2>&1
# shellcheck source=../lib/21-setup.sh
. "$HERE/../lib/21-setup.sh" >/dev/null 2>&1
# shellcheck source=../lib/22-gc.sh
. "$HERE/../lib/22-gc.sh" >/dev/null 2>&1

ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1${2:+ (tengo '$2')}"; FAIL=$((FAIL+1)); }

printf 'ARXY_SIGNATURE_POLICY="required"\n' >"$D/user.conf"

# NOTA: ARXY_SYS_CONF por env NO redirige que fichero se sourcea (00-head
# lo fija a /etc antes de leer; el env solo protege VALORES via frozen).
# Por eso sys-conf se cubre en host real (regla 3), no aqui. User-conf si
# es aislable via XDG_CONFIG_HOME (la ruta se deriva en cada arranque).
mkdir -p "$D/xdg-empty" "$D/xdg-user/arxy"
cp "$D/user.conf" "$D/xdg-user/arxy/config"

src() { # src : sourcea 00-head pelado en subshell e imprime la policy
    bash -c "set --; . \"$HERE/../lib/00-head.sh\" >/dev/null 2>&1; printf '%s' \"\$ARXY_SIGNATURE_POLICY\""
}

v="$( ( export XDG_CONFIG_HOME="$D/xdg-empty"; unset ARXY_SIGNATURE_POLICY 2>/dev/null; src ) )"
[[ "$v" == optional ]] && ok "T0: ausente = optional" || no "T0: ausente = optional" "$v"
v="$( ( export XDG_CONFIG_HOME="$D/xdg-user"; unset ARXY_SIGNATURE_POLICY 2>/dev/null; src ) )"
[[ "$v" == required ]] && ok "T1a: user-conf required se lee" || no "T1a: user-conf required se lee" "$v"
v="$( ( export ARXY_SIGNATURE_POLICY=off XDG_CONFIG_HOME="$D/xdg-user"; src ) )"
[[ "$v" == off ]] && ok "T1b: env manda sobre user-conf" || no "T1b: env manda sobre user-conf" "$v"

( export ARXY_SIGNATURE_POLICY=bogus; enforce_signature_policy 0 >/dev/null 2>&1 ); rc=$?
[[ "$rc" != 0 ]] && ok "T2: valor invalido muere" || no "T2: valor invalido muere"
err="$( ( export ARXY_SIGNATURE_POLICY=bogus; enforce_signature_policy 0 ) 2>&1 >/dev/null || true)"
grep -q 'required|optional|off' <<<"$err" && ok "T2: mensaje lista valores" || no "T2: mensaje lista valores" "[$err]"

echo "== T3: todo aviso: va a stderr (; tripwire)"
if grep -rn 'msg "aviso:' "$HERE/../lib" | grep -v '>&2' | grep -q .; then
    no "T3 avisos a stderr" "$(grep -rn 'msg "aviso:' "$HERE/../lib" | grep -v '>&2' | head -n 3 | tr '\n' ' ')"
else
    ok "T3 avisos a stderr"
fi

echo "== T4: todo error: va a stderr (; tripwire)"
if grep -rn 'msg "error:' "$HERE/../lib" | grep -v '>&2' | grep -q .; then
    no "T4 errores a stderr" "$(grep -rn 'msg "error:' "$HERE/../lib" | grep -v '>&2' | head -n 3 | tr '\n' ' ')"
else
    ok "T4 errores a stderr"
fi

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
