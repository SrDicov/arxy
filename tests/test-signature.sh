#!/usr/bin/env bash
# test-signature.sh — firma minisign del tarball. Sin root, imagen
# ni red: minisign fakeado por funcion (rc controlado) + ficheros fixture.
# Roundtrip real solo si hay minisign (si no: SKIP). La privada de test se
# genera en runtime y jamas se commitea.
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/empty"
export ARXY_ROOT="$D/root" ARXY_DATA="$D/data" ARXY_VERSION_FILE="$D/version"
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

echo "== verify_signature (minisign fakeado) =="
printf 'tarball' >"$D/t.tar.zst"; printf 'sig' >"$D/t.minisig"
FAKE_MINISIGN_RC=0
minisign() { return "${FAKE_MINISIGN_RC:-0}"; }
( verify_signature "$D/t.tar.zst" "$D/t.minisig" "$HERE/../config/arxy.pub" ); rc=$?
[[ "$rc" == 0 ]] && ok "T: rc 0 con firma valida" || no "T: rc 0 con firma valida" "$rc"
FAKE_MINISIGN_RC=1
( verify_signature "$D/t.tar.zst" "$D/t.minisig" "$HERE/../config/arxy.pub" ); rc=$?
[[ "$rc" == 1 ]] && ok "T: rc 1 con firma invalida" || no "T: rc 1 con firma invalida" "$rc"
( unset -f minisign; PATH="$D/empty" verify_signature "$D/t.tar.zst" "$D/t.minisig" "$HERE/../config/arxy.pub" ); rc=$?
[[ "$rc" == 2 ]] && ok "T: rc 2 sin minisign" || no "T: rc 2 sin minisign" "$rc"
minisign() { return "${FAKE_MINISIGN_RC:-0}"; }
FAKE_MINISIGN_RC=0
( verify_signature "$D/t.tar.zst" "$D/t.minisig" "$D/no-pub" ); rc=$?
[[ "$rc" == 3 ]] && ok "T: rc 3 sin pubkey" || no "T: rc 3 sin pubkey" "$rc"
( verify_signature "$D/t.tar.zst" "$D/no-sig" "$HERE/../config/arxy.pub" ); rc=$?
[[ "$rc" == 4 ]] && ok "T: rc 4 sin .minisig" || no "T: rc 4 sin .minisig" "$rc"

echo "== enforce_signature_policy =="
t() { # t <nombre> <policy> <rc> <want: 0|die> [warn?]
    local name="$1" pol="$2" in="$3" want="$4" errout rc
    errout="$( ( export ARXY_SIGNATURE_POLICY="$pol"; enforce_signature_policy "$in" ) 2>&1 )"; rc=$?
    if [[ "$want" == 0 && "$rc" == 0 ]]; then ok "$name";
    elif [[ "$want" == die && "$rc" != 0 ]]; then ok "$name";
    else no "$name" "rc=$rc [$errout]"; fi
    if [[ "${5:-}" == warn ]]; then
        if grep -q 'aviso' <<<"$errout"; then ok "$name (con aviso)";
        else no "$name (con aviso)" "[$errout]"; fi
    fi
}
t "T0 valida+optional sigue" optional 0 0
t "T1 invalida+optional muere" optional 1 die
t "T2 ausente+optional avisa y sigue" optional 2 0 warn
t "T3 sin-pub+optional muere" optional 3 die
t "T4 sin-sig+optional muere" optional 4 die
t "T5 valida+required sigue" required 0 0
t "T6 invalida+required muere" required 1 die
t "T7 ausente+required muere" required 2 die
t "T8 invalida+off se ignora" off 1 0
( export ARXY_SIGNATURE_POLICY=bogus; enforce_signature_policy 0 >/dev/null 2>&1 ); rc=$?
[[ "$rc" != 0 ]] && ok "T: policy invalida muere" || no "T: policy invalida muere"

echo "== sig_check_compat (pin + required = die) =="
( export ARXY_SIGNATURE_POLICY=required ARXY_IMAGE_SHA256="abc123"; sig_check_compat >/dev/null 2>&1 ); rc=$?
[[ "$rc" != 0 ]] && ok "T: pin+required muere" || no "T: pin+required muere"
err="$( ( export ARXY_SIGNATURE_POLICY=required ARXY_IMAGE_SHA256="abc123"; sig_check_compat ) 2>&1 >/dev/null || true)"
grep -q 'incompatible' <<<"$err" && ok "T: mensaje dice incompatible" || no "T: mensaje dice incompatible" "[$err]"
( export ARXY_SIGNATURE_POLICY=required ARXY_IMAGE_SHA256=""; sig_check_compat >/dev/null 2>&1 ); rc=$?
[[ "$rc" == 0 ]] && ok "T: required sin pin sigue" || no "T: required sin pin sigue"
( export ARXY_SIGNATURE_POLICY=optional ARXY_IMAGE_SHA256="abc123"; sig_check_compat >/dev/null 2>&1 ); rc=$?
[[ "$rc" == 0 ]] && ok "T: optional+pin sigue" || no "T: optional+pin sigue"

echo "== sig_should_verify =="
s() { # s <nombre> <want: 0|1> : con env ya fijado en subshell
    local name="$1" want="$2" rc
    ( sig_should_verify ); rc=$?
    [[ "$rc" == "$want" ]] && ok "$name" || no "$name" "rc=$rc"
}
( export ARXY_SIGNATURE_POLICY=optional ARXY_IMAGE_SHA256="" ARXY_IMAGE_URL="https://x/y.tar.zst"; s "T: https+optional verifica" 0 )
( export ARXY_SIGNATURE_POLICY=optional ARXY_IMAGE_SHA256="" ARXY_IMAGE_URL="file:///tmp/y.tar.zst"; s "T: file:// omite" 1 )
( export ARXY_SIGNATURE_POLICY=optional ARXY_IMAGE_SHA256="abc" ARXY_IMAGE_URL="https://x/y.tar.zst"; s "T9: pin omite descarga" 1 )
( export ARXY_SIGNATURE_POLICY=off ARXY_IMAGE_SHA256="" ARXY_IMAGE_URL="https://x/y.tar.zst"; s "T: off omite" 1 )
( export ARXY_SIGNATURE_POLICY=required ARXY_IMAGE_SHA256="" ARXY_IMAGE_URL="https://x/y.tar.zst"; s "T: https+required verifica" 0 )

echo "== pubkey del repo (formato pinneado) =="
[[ "$(wc -l <"$HERE/../config/arxy.pub")" == 2 ]] && ok "pub: 2 lineas" || no "pub: 2 lineas"
head -n 1 "$HERE/../config/arxy.pub" | grep -q '^untrusted comment: minisign public key [0-9A-F]*$' \
    && ok "pub: comment con key id" || no "pub: comment con key id"
[[ -n "$(tail -c 1 "$HERE/../config/arxy.pub")" ]] && no "pub: newline final" || ok "pub: newline final"

echo "== roundtrip real (solo con minisign) =="
unset -f minisign
if command -v minisign >/dev/null 2>&1; then
    K="$D/key"; mkdir -p "$K"
    if minisign -G -W -p "$K/t.pub" -s "$K/t.sec" >/dev/null 2>&1 \
        && printf 'contenido' >"$D/real.tar" \
        && minisign -S -s "$K/t.sec" -m "$D/real.tar" -x "$D/real.minisig" >/dev/null 2>&1; then
        ( verify_signature "$D/real.tar" "$D/real.minisig" "$K/t.pub" ); rc=$?
        [[ "$rc" == 0 ]] && ok "real: firma valida" || no "real: firma valida" "$rc"
        printf 'contenido!' >"$D/real.tar"
        ( verify_signature "$D/real.tar" "$D/real.minisig" "$K/t.pub" ); rc=$?
        [[ "$rc" == 1 ]] && ok "real: tarball tocado falla" || no "real: tarball tocado falla" "$rc"
    else
        echo "SKIP: roundtrip real (minisign -G/-S fallo)"
    fi
else
    echo "SKIP: roundtrip real (sin minisign)"
fi

echo "== vector conocido commiteado (A5: cripto real sin keygen) =="
# tests/fixtures/sig-vector/* : mensaje + pubkey + .minisig fijos, generados
# una vez con minisign real (la secreta se destruyo). Pinea el comportamiento:
# un verify_signature que delegue mal (args cruzados, rc inventado) falla aqui
# aunque pase los fakes de arriba. Solo SKIP sin binario (el CI lo instala).
if command -v minisign >/dev/null 2>&1; then
    V="$HERE/fixtures/sig-vector"
    ( verify_signature "$V/msg.bin" "$V/msg.minisig" "$V/t.pub" ); rc=$?
    [[ "$rc" == 0 ]] && ok "vector: firma valida" || no "vector: firma valida" "$rc"
    cp "$V/msg.bin" "$D/v-tocada.bin" && printf 'X' >>"$D/v-tocada.bin"
    ( verify_signature "$D/v-tocada.bin" "$V/msg.minisig" "$V/t.pub" ); rc=$?
    [[ "$rc" == 1 ]] && ok "vector: mensaje tocado falla" || no "vector: mensaje tocado falla" "$rc"
    cp "$V/msg.minisig" "$D/v-sig-tocada.minisig" && sed -i '2s/./X/' "$D/v-sig-tocada.minisig"
    ( verify_signature "$V/msg.bin" "$D/v-sig-tocada.minisig" "$V/t.pub" ); rc=$?
    [[ "$rc" == 1 ]] && ok "vector: firma tocada falla" || no "vector: firma tocada falla" "$rc"
    # minisign ignora basura trailing por diseno; pinnearlo
    # para que nadie lo "endurezca" rompiendo compat, y cruzar args para
    # cazar delegacion con pub/sig trocados (falla con rc!=0 igual).
    cp "$V/msg.minisig" "$D/v-sig-basura.minisig" && printf 'basura-trailing\n' >>"$D/v-sig-basura.minisig"
    ( verify_signature "$V/msg.bin" "$D/v-sig-basura.minisig" "$V/t.pub" ); rc=$?
    [[ "$rc" == 0 ]] && ok "vector: trailing aceptado (diseno)" || no "vector: trailing aceptado" "$rc"
    ( verify_signature "$V/msg.bin" "$V/t.pub" "$V/msg.minisig" ); rc=$?
    [[ "$rc" != 0 ]] && ok "vector: args cruzados fallan" || no "vector: args cruzados pasan" "$rc"
else
    echo "SKIP: vector conocido (sin minisign)"
fi

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
