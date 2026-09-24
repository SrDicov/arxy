#!/usr/bin/env bash
# Suite local determinista. Los tests de hardware/imagen real quedan fuera:
# necesitan opt-in y conservan sus propios guards cuando se ejecutan a mano.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
ran=0
skipped=0

for test_file in "$ROOT"/tests/test-*.sh; do
    case "${test_file##*/}" in
        test-hardware.sh|test-arxy-gaming-real.sh|test-musl-real.sh|\
        test-atomic-setup.sh|test-audio-e2e.sh|test-input-e2e.sh|\
        test-doctor-fix-apply.sh|test-bridge-*.sh|test-host-bridge.sh|\
        test-desktop-shims.sh)
            if [[ "${ARXY_TEST_ALL:-}" == 1 ]]; then
                :
            else
                echo "SKIP: ${test_file##*/} (entorno externo; usa make test-all)"
                skipped=$((skipped + 1))
                continue
            fi
            ;;
    esac
    echo "==> ${test_file##*/}"
    if bash "$test_file"; then
        ran=$((ran + 1))
    else
        rc=$?
        echo "FAIL: ${test_file##*/} (rc=$rc)" >&2
        fail=$((fail + 1))
    fi
done

echo "== suite: $ran OK, $skipped SKIP, $fail FAIL"
(( fail == 0 ))
