#!/usr/bin/env bash
# tests/lib.sh — helpers compartidos de tests. Sourcear lo primero (tras HERE).
# ARXY_BIN: CLI bajo prueba. Default: el repo (src/arxy), NO el instalado:
# el instalado puede ir versiones por detras y da falsos rojos. El env sigue
# mandando para probar otro binario a proposito.
if [[ -z "${ARXY_BIN:-}" ]]; then
    ARXY_BIN="$(readlink -f "$(dirname "${BASH_SOURCE[0]}")/../src/arxy" 2>/dev/null || echo "$(dirname "${BASH_SOURCE[0]}")/../src/arxy")"
    export ARXY_BIN
fi

ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1${2:+ (tengo '$2')}"; FAIL=$((FAIL+1)); }

t() { # t <nombre> <quiero> -- <cmd...>: grep contenido (nunca solo rc)
    local name="$1" want="$2"; shift 3
    local out
    out="$("$@" 2>&1)" || true
    if grep -q "$want" <<<"$out"; then echo "PASS: $name";
    else echo "FAIL: $name (sin [$want])"; printf '%s\n' "$out" | head -3 | sed 's/^/  /'; FAIL=$((FAIL+1)); fi
}

te() { # te <nombre> <rc> -- <cmd...> : vacio + rc exacto (ausencia legitima vs crash)
    local name="$1" wantrc="$2"; shift 2; shift
    local got rc
    got="$("$@")" 2>/dev/null; rc=$?
    if [[ $rc -eq "$wantrc" && -z "$got" ]]; then echo "PASS: $name";
    else echo "FAIL: $name (quiero vacio rc $wantrc, tengo '$got' rc $rc)"; FAIL=$((FAIL+1)); fi
}

finish() { # cierre canonico: mismo TODO_OK/FALLOS + exit en todos los tests
    echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
    exit "$FAIL"
}

arxy_mkroot() { # <$dir> [$mark] : rootfs valido para _image_ok
    mkdir -p "$1/usr/bin" "$1/etc"
    : > "$1/usr/bin/bash"; : > "$1/usr/bin/pacman"
    chmod +x "$1/usr/bin/bash" "$1/usr/bin/pacman"
    echo "NAME=Arch Linux" > "$1/etc/arch-release"
    [[ -n "${2:-}" ]] && echo "$2" > "$1/.mark"
}

arxy_mkroot_ver() { # <$dir> [$version-url] [$sha] : + version dentro del root
    mkdir -p "$1/usr/bin" "$1/etc"
    : > "$1/usr/bin/bash"; : > "$1/usr/bin/pacman"
    chmod +x "$1/usr/bin/bash" "$1/usr/bin/pacman"
    echo "NAME=Arch Linux" > "$1/etc/arch-release"
    if [[ -n "${2:-}" ]]; then
        mkdir -p "$1/var/lib/arxy"
        ( export ARXY_VERSION_FILE="$1/var/lib/arxy/version"
          write_version "$2" "${3:-}" "2020-01-01T00:00:00Z" ) >/dev/null 2>&1
    fi
}

fake_drm() { # fake_drm <vendor|-> : card0 con ese vendor (o sin cards)
    rm -rf "${D:?}"/*
    if [[ "${1:-}" != "-" ]]; then
        mkdir -p "$D/card0/device"
        printf '%s' "$1" > "$D/card0/device/vendor"
    fi
}

staging_clean() { # purga root + staging huerfanos (mismo inventario que recover_staging)
    rm -rf "$R" "$R.old" "$R".new.* "$R".old.tmp.* "$R".swap.* "$D"/.image.partial.*
}
