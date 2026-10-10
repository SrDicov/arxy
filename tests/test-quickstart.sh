#!/usr/bin/env bash
# test-quickstart.sh — maquina de estados del siguiente paso (L2).
# Sin root, red ni GPU: root falso + REAL_APPS falso + detect/is_mesa_mini
# stubbed. Los 3 estados + linea GPU + validacion de args.
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
# shellcheck source=lib.sh
. "$HERE/lib.sh" # ok/no/finish
D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT
R="$D/root"
export ARXY_ROOT="$R"
# shellcheck source=../lib/00-head.sh
. "$HERE/../lib/00-head.sh" >/dev/null 2>&1
# shellcheck source=../lib/60-detect.sh
. "$HERE/../lib/60-detect.sh" >/dev/null 2>&1
# shellcheck source=../lib/61-doctor.sh
. "$HERE/../lib/61-doctor.sh" >/dev/null 2>&1
REAL_APPS="$D/apps"; mkdir -p "$REAL_APPS"

echo "== args: quickstart no acepta nada =="
out="$(cmd_quickstart extra 2>&1)"; rc=$?
if grep -q 'uso:' <<<"$out" && [[ "$rc" != 0 ]]; then ok "uso con args";
else no "uso con args" "rc=$rc [$out]"; fi

echo "== estado 1: sin imagen -> setup =="
rm -rf "$R"
out="$(cmd_quickstart)"
grep -q 'arxy setup' <<<"$out" && ok "sugiere setup" || no "sugiere setup" "$out"
grep -q 'install firefox' <<<"$out" && ok "menciona install despues" || no "menciona install" "$out"

echo "== estado 2: con imagen sin lanzadores -> install =="
arxy_mkroot "$R"
detect_gpu() { echo ""; }
is_mesa_mini() { return 1; }
out="$(cmd_quickstart)"
grep -q 'arxy install <app>' <<<"$out" && ok "sugiere install" || no "sugiere install" "$out"
if grep -q 'gpu-' <<<"$out"; then no "sin linea GPU sin gpu"; else ok "sin linea GPU sin gpu"; fi

echo "== estado 3: con lanzadores -> run =="
: > "$REAL_APPS/arxy-htop.desktop"
out="$(cmd_quickstart)"
grep -q 'arxy run <app>' <<<"$out" && ok "sugiere run" || no "sugiere run" "$out"
grep -q '1 lanzadores' <<<"$out" && ok "cuenta lanzadores" || no "cuenta lanzadores" "$out"

echo "== linea GPU: solo con gpu + mesa-mini =="
detect_gpu() { echo "amd"; }
is_mesa_mini() { return 0; }
out="$(cmd_quickstart)"
grep -q 'install gpu-amd' <<<"$out" && ok "sugiere gpu-amd" || no "sugiere gpu-amd" "$out"
is_mesa_mini() { return 1; }
out="$(cmd_quickstart)"
if grep -q 'gpu-' <<<"$out"; then no "sin linea con mesa full"; else ok "sin linea con mesa full"; fi
detect_gpu() { echo ""; }
is_mesa_mini() { return 0; }
out="$(cmd_quickstart)"
if grep -q 'gpu-' <<<"$out"; then no "sin linea sin gpu"; else ok "sin linea sin gpu"; fi

finish
