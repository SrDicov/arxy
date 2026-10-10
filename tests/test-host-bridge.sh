#!/usr/bin/env bash
# test-host-bridge.sh — CLI de `arxy host-bridge` sin root ni imagen:
# mecanica --daemon/--stop/--status (el protocolo vive en bridge/test-bridge.sh
# y el e2e en test-bridge-in-container.sh). Daemon y socket en TMP.
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
# shellcheck source=lib.sh
. "$HERE/lib.sh" # ARXY_BIN default: repo (no el instalado viejo)
BIN="$ARXY_BIN"
D="$(mktemp -d)"
SOCK="$D/br.sock"
trap '"$BIN" host-bridge --stop --socket "$SOCK" >/dev/null 2>&1 || true; "$BIN" host-bridge --stop --socket "$D/otro.sock" >/dev/null 2>&1 || true; rm -rf "$D"' EXIT

command -v cc >/dev/null 2>&1 || { echo "SKIP: falta cc"; exit 0; }
cc -O2 -Wall -Wextra -Werror -o "$D/arxy-bridged" "$HERE/../bridge/arxy-bridged.c" 2>/dev/null || { echo "FAIL: no compila"; exit 1; }
export ARXY_BRIDGE_BIN="$D/arxy-bridged"
SOCK="$D/br.sock"

t() { # t <nombre> -- <cmd...>
    local name="$1"; shift; shift
    local out rc
    if out="$("$@" 2>&1)"; then echo "PASS: $name";
    else rc=$?; echo "FAIL($rc): $name"; printf '%s\n' "$out" | head -4 | sed 's/^/  /'; FAIL=$((FAIL+1)); fi
}
te() { # te <nombre> <grep> -- <cmd...> : debe FALLAR y el texto matchear
    local name="$1" want="$2"; shift 2; shift
    local out
    if out="$("$@" 2>&1)"; then echo "FAIL: $name (rc 0)"; FAIL=$((FAIL+1));
    elif grep -q "$want" <<<"$out"; then echo "PASS: $name";
    else echo "FAIL: $name (sin [$want] en [$out])"; FAIL=$((FAIL+1)); fi
}

t "help + uso" -- sh -c '"$0" host-bridge --help 2>/dev/null | grep -q "host-bridge \[--daemon"' "$BIN"
te "status sin daemon" "inactivo" -- "$BIN" host-bridge --status --socket "$SOCK"
# (sin allowlist: el default resuelve en este host; el caso vacio
# determinista vive en T19 con ARXY_BRIDGE_ALLOWLIST imposible)
te "stop sin daemon" "sin daemon vivo" -- "$BIN" host-bridge --stop --socket "$SOCK"
t "daemon arranca" -- "$BIN" host-bridge --daemon --socket "$SOCK" --allowed-cmd /bin/echo
[[ -S "$SOCK" ]] && echo "PASS: socket existe" || { echo "FAIL: socket existe"; FAIL=$((FAIL+1)); }
[[ -f "${SOCK%.sock}.pid" ]] && echo "PASS: pidfile existe" || { echo "FAIL: pidfile existe"; FAIL=$((FAIL+1)); }
t "status activo" -- sh -c '"$0" host-bridge --status --socket "$1" 2>/dev/null | grep -q "^activo:"' "$BIN" "$SOCK"
te "doble daemon falla limpio" "ya corre" -- "$BIN" host-bridge --daemon --socket "$SOCK" --allowed-cmd /bin/echo
t "stop" -- "$BIN" host-bridge --stop --socket "$SOCK"
[[ ! -e "$SOCK" ]] && echo "PASS: socket borrado" || { echo "FAIL: socket borrado"; FAIL=$((FAIL+1)); }
[[ ! -e "${SOCK%.sock}.pid" ]] && echo "PASS: pidfile borrado" || { echo "FAIL: pidfile borrado"; FAIL=$((FAIL+1)); }
te "status tras stop" "inactivo" -- "$BIN" host-bridge --status --socket "$SOCK"
t "socket custom" -- "$BIN" host-bridge --daemon --socket "$D/otro.sock" --allowed-cmd /bin/echo
t "stop custom" -- "$BIN" host-bridge --stop --socket "$D/otro.sock"

echo "== allowlist por nombre y defaults =="
t "T16 bare name resuelve via PATH" -- "$BIN" host-bridge --daemon --socket "$D/n.sock" --allowed-cmd echo
t "T16 stop" -- "$BIN" host-bridge --stop --socket "$D/n.sock"
te "T17 explicito malo muere claro" "not executable" -- "$BIN" host-bridge --daemon --socket "$D/m.sock" --allowed-cmd nonexistent-binary-xyz
te "T18 allowed-cmd vacio" "falta binario" -- "$BIN" host-bridge --daemon --socket "$D/m.sock" --allowed-cmd ""
t "T19 config lista" -- env ARXY_BRIDGE_ALLOWLIST="echo" "$BIN" host-bridge --daemon --socket "$D/c.sock"
t "T19 stop" -- "$BIN" host-bridge --stop --socket "$D/c.sock"
te "T19 nada resuelve" "allowlist vacia" -- env ARXY_BRIDGE_ALLOWLIST="nonexistent-xyz" "$BIN" host-bridge --daemon --socket "$D/c.sock"
echo "== T20: pid reutilizado no miente =="
"$BIN" host-bridge --daemon --socket "$D/p.sock" --allowed-cmd /bin/echo >/dev/null 2>&1
echo "$$" > "${D}/p.pid"
te "T20 status con pid ajeno" "inactivo" -- "$BIN" host-bridge --status --socket "$D/p.sock"
# Limpieza del daemon huerfano (pidfile pisado): por nombre exacto, nunca -f
for _p in $(pgrep -x arxy-bridged 2>/dev/null || true); do kill "$_p" 2>/dev/null || true; done
rm -f "$D/p.sock" "$D/p.pid"
echo "PASS: T20 limpieza"

echo "== P4: sin flock no hay auto-arranque pero tampoco crash =="
# shellcheck source=../lib/00-head.sh
. "$HERE/../lib/00-head.sh" >/dev/null 2>&1
# shellcheck source=../lib/80-bridge.sh
. "$HERE/../lib/80-bridge.sh" >/dev/null 2>&1
export XDG_RUNTIME_DIR="$D" ARXY_BRIDGE_BIN="$D/arxy-bridged"
flock() { return 1; }
if ensure_bridge_daemon; then echo "PASS: sin flock rc 0"; else echo "FAIL: sin flock rc"; FAIL=$((FAIL+1)); fi
[[ ! -S "$D/arxy-bridge.sock" ]] && echo "PASS: sin flock no arranca" || { echo "FAIL: sin flock arranco"; FAIL=$((FAIL+1)); }
unset -f flock
echo "== P5: sin binario flock (PATH minimo) tambien degrada limpio =="
mkdir -p "$D/nolk"
for _t in cat chmod sleep rm mktemp od tr head; do ln -sf "$(command -v "$_t")" "$D/nolk/$_t" 2>/dev/null || true; done
if ( unset -f flock 2>/dev/null; PATH="$D/nolk" ensure_bridge_daemon ); then echo "PASS: sin binario rc 0"; else echo "FAIL: sin binario rc"; FAIL=$((FAIL+1)); fi
[[ ! -S "$D/arxy-bridge.sock" ]] && echo "PASS: sin binario no arranca" || { echo "FAIL: sin binario arranco"; FAIL=$((FAIL+1)); }

echo "== P1: xdg-open mock recibe URL (sin abrir navegador) =="
if command -v python3 >/dev/null 2>&1; then
    mkdir -p "$D/mockbin"
    printf '#!/bin/sh\necho "$1" >> "%s/got.txt"\n' "$D" > "$D/mockbin/xdg-open"
    chmod +x "$D/mockbin/xdg-open"
    "$BIN" host-bridge --daemon --socket "$D/x.sock" --allowed-cmd "$D/mockbin/xdg-open" >/dev/null 2>&1
    tok="$(cat "$D/x.token" 2>/dev/null || true)"
    out="$(python3 - "$D/x.sock" "$tok" "$D" <<'EOF' 2>&1
import socket, struct, json, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(10); s.connect(sys.argv[1])
b = json.dumps({'type':'request','command':[sys.argv[3] + '/mockbin/xdg-open','https://example.com/t-1'],'token':sys.argv[2]}).encode()
s.sendall(struct.pack('>I', len(b)) + b)
while True:
    h = s.recv(4)
    if not h: print('EOF'); break
    (n,) = struct.unpack('>I', h)
    js = json.loads(s.recv(n).decode())
    print(js.get('type'), js.get('code', js.get('error','')))
    if js.get('type') in ('exit','error'): break
EOF
)"
    grep -q "https://example.com/t-1" "$D/got.txt" 2>/dev/null && echo "PASS: P1 URL al mock" || { echo "FAIL: P1 URL al mock (tengo [$out])"; FAIL=$((FAIL+1)); }
    grep -q "^exit 0$" <<<"$out" && echo "PASS: P1 exit 0" || { echo "FAIL: P1 exit (tengo [$out])"; FAIL=$((FAIL+1)); }
    "$BIN" host-bridge --stop --socket "$D/x.sock" >/dev/null 2>&1 || true
else
    echo "SKIP: P1 sin python3"
fi

echo "== P6: notify-send --print-id real via bridge (sin UI bloqueante) =="
if ! command -v notify-send >/dev/null 2>&1; then
    echo "SKIP: P6 sin notify-send"
elif ! command -v busctl >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
    echo "SKIP: P6 sin busctl/timeout"
else
    # Regla 5 (pipefail): capturar en variable y grepear despues, nunca prod | grep.
    bus_list="$(busctl --user list 2>&1 || true)"
    if ! grep -q "org.freedesktop.Notifications" <<<"$bus_list"; then
        echo "SKIP: P6 sin daemon org.freedesktop.Notifications"
    elif ! timeout 5 notify-send --print-id "arxy-p6-gate" "gate" >/dev/null 2>&1; then
        echo "SKIP: P6 notify-send --print-id falla en este host"
    elif ! command -v python3 >/dev/null 2>&1; then
        echo "SKIP: P6 sin python3"
    else
        ns_path="$(command -v notify-send)"
        "$BIN" host-bridge --daemon --socket "$D/n6.sock" --allowed-cmd "$ns_path" >/dev/null 2>&1
        tok6="$(cat "$D/n6.token" 2>/dev/null || true)"
        # timeout externo: notify-send no abre UI, pero el test nunca cuelga.
        out6="$(timeout 15 python3 - "$D/n6.sock" "$tok6" "$ns_path" <<'EOF' 2>&1
import socket, struct, json, base64, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(10); s.connect(sys.argv[1])
b = json.dumps({'type':'request','command':[sys.argv[3],'--print-id','arxy-p6','bridge-ok'],'token':sys.argv[2]}).encode()
s.sendall(struct.pack('>I', len(b)) + b)
data = b''
while True:
    h = s.recv(4)
    if not h: print('EOF'); break
    (n,) = struct.unpack('>I', h)
    js = json.loads(s.recv(n).decode())
    t = js.get('type')
    if t == 'output':
        data += base64.b64decode(js.get('data', ''))
    elif t == 'exit':
        print('OUT:' + base64.b64encode(data).decode())
        print('%s %s' % (t, js.get('code', '')))
        break
    elif t == 'error':
        print('%s %s' % (t, js.get('error', '')))
        break
EOF
)"
        grep -q "^exit 0$" <<<"$out6" && echo "PASS: P6 exit 0" || { echo "FAIL: P6 exit (tengo [$out6])"; FAIL=$((FAIL+1)); }
        b64_line="$(grep '^OUT:' <<<"$out6" || true)"
        b64="${b64_line#OUT:}"
        dec6="$(printf '%s' "$b64" | base64 -d 2>/dev/null || true)"
        grep -qE "^[0-9]+$" <<<"$dec6" && echo "PASS: P6 id numerico" || { echo "FAIL: P6 id (tengo [$out6] dec [$dec6])"; FAIL=$((FAIL+1)); }
        "$BIN" host-bridge --stop --socket "$D/n6.sock" >/dev/null 2>&1 || true
    fi
fi

echo "== T21: el resolver no toca el IFS del llamador () =="
IFS=':'
bridge_resolve_allowlist <<<"echo" >/dev/null
[[ "${IFS-}" == ":" ]] && echo "PASS: T21 IFS intacto" || { echo "FAIL: T21 IFS intacto"; FAIL=$((FAIL+1)); }
unset IFS
out21="$(printf 'a:b:c\n' | { IFS=,; bridge_resolve_allowlist <<<"echo" >/dev/null; printf '%s' "$IFS"; })"
[[ "$out21" == "," ]] && echo "PASS: T21 IFS local no fuga" || { echo "FAIL: T21 IFS local no fuga (tengo [$out21])"; FAIL=$((FAIL+1)); }

echo "== T22: una sola grafia de socket fallback (; tripwire) =="
grep -q 'arxy-bridge-$(id -u).sock' "$HERE/../lib/80-bridge.sh" && echo "PASS: T22 canonica en bridge" || { echo "FAIL: T22 canonica en bridge"; FAIL=$((FAIL+1)); }
if grep -rq 'arxy-bridge-${UID}' "$HERE/../lib" 2>/dev/null; then echo "FAIL: T22 grafia divergente"; FAIL=$((FAIL+1));
else echo "PASS: T22 sin grafia divergente"; fi

echo "== T23: stop mata al que ignora TERM =="
cp "$(command -v sleep)" "$D/arxy-bridged"
( trap '' TERM; exec -a arxy-bridged "$D/arxy-bridged" 120 ) &
_kpid=$!
echo "$_kpid" > "$D/k.pid"
out23="$("$BIN" host-bridge --stop --socket "$D/k.sock" 2>&1)"; rc23=$?
kill -9 "$_kpid" 2>/dev/null || true
[[ $rc23 -eq 0 ]] && grep -q "detenido" <<<"$out23" && ! kill -0 "$_kpid" 2>/dev/null && [[ ! -e "$D/k.pid" ]] && echo "PASS: T23 stop mata" || { echo "FAIL: T23 stop mata (rc=$rc23 $out23)"; FAIL=$((FAIL+1)); }

echo "== T24: ensure no filtra locks al daemon (regresion /tmp/.lock) =="
# `run` sin imagen -> ensure_image -> setup toma data_lock y run_in
# auto-arranca: el daemon huerfano retenia el lock horas porque lo heredaba.
# El hijo del spawn debe cerrarlos; el padre conservarlos.
mkdir -p "$D/fakebin"
printf '#!/bin/bash\nls /proc/self/fd > "%s/self-fds.txt"\n' "$D" > "$D/fakebin/arxy-fake"
chmod +x "$D/fakebin/arxy-fake"
export ARXY_SELF="$D/fakebin/arxy-fake" ARXY_ROOT="$D/lockroot"
unset ARXY_NO_BRIDGE
data_lock
ensure_bridge_daemon
if grep -qx "$ARXY_LOCK_FD" "$D/self-fds.txt" 2>/dev/null; then
    echo "FAIL: T24 hijo heredo data_lock fd $ARXY_LOCK_FD"; FAIL=$((FAIL+1))
elif grep -qx "9" "$D/self-fds.txt" 2>/dev/null; then
    echo "FAIL: T24 hijo heredo fd 9 (ensure lock)"; FAIL=$((FAIL+1))
else
    echo "PASS: T24 hijo sin locks"
fi
data_lock && echo "PASS: T24 padre conserva el lock" || { echo "FAIL: T24 padre perdio el lock"; FAIL=$((FAIL+1)); }
exec {ARXY_LOCK_FD}>&- 2>/dev/null || true; unset ARXY_LOCK_FD

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
