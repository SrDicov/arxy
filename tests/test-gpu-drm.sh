#!/usr/bin/env bash
# test-gpu-drm.sh — GPU detectada sin hardware, via ARXY_SYS_DRM_PATH.
# Uso: ./tests/test-gpu-drm.sh  (arxy en PATH; no necesita imagen)
set -uo pipefail
FAIL=0
HERE="$(dirname "$0")"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
BIN="$ARXY_BIN"
D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT

fake() { # fake <vendor|-> : prepara un card0 con ese vendor (o sin cards)
    rm -rf "${D:?}"/*
    if [[ "${1:-}" != "-" ]]; then
        mkdir -p "$D/card0/device"
        printf '%s' "$1" > "$D/card0/device/vendor"
    fi
}

t() { # t <nombre> <vendor|-> <esperado>
    fake "$2"
    local got
    got="$(ARXY_SYS_DRM_PATH="$D" "$BIN" version --verbose 2>/dev/null | sed -n 's/^gpu: //p')"
    if [[ "$got" == "$3"* ]]; then echo "PASS: $1";
    else echo "FAIL: $1 (quiero '$3*', tengo '$got')"; FAIL=$((FAIL+1)); fi
}

t "AMD 1002" "0x1002" "amd"
t "NVIDIA 10de" "0x10de" "nvidia"
t "Intel 8086 calla" "0x8086" "no discreta"
t "sin cards calla" "-" "no discreta"
# doctor_gpu se prueba tras sourcear lib (necesita overrides image_ok/is_mesa_mini; ver abajo).
# Ojo pipefail: se captura la salida (|| true) y decide el grep, no el rc.

# --- heuristica NVIDIA pura, con mocks (sin root ni GPU real) ---
# shellcheck source=../lib/00-head.sh
. "$HERE/../lib/00-head.sh" >/dev/null 2>&1
# shellcheck source=../lib/35-gpu.sh
. "$HERE/../lib/35-gpu.sh" >/dev/null 2>&1
# shellcheck source=../lib/10-level.sh
. "$HERE/../lib/10-level.sh" >/dev/null 2>&1
# shellcheck source=../lib/60-detect.sh
. "$HERE/../lib/60-detect.sh" >/dev/null 2>&1
# shellcheck source=../lib/61-doctor.sh
. "$HERE/../lib/61-doctor.sh" >/dev/null 2>&1
# shellcheck source=../lib/62-json.sh
. "$HERE/../lib/62-json.sh" >/dev/null 2>&1

# doctor_gpu exige imagen mini (is_mesa_mini): con mesa completa retorna 0.
# Override determinista (patrón test-arxy-gaming.sh) en subshell del $()
# para no filtrar al resto del test; captura antes de grep (pipefail/SIGPIPE).
fake "0x1002"
_doc="$(image_ok() { return 0; }; is_mesa_mini() { return 0; }; ARXY_SYS_DRM_PATH="$D" doctor_gpu 2>&1 || true)"
if grep -q "aviso GPU AMD" <<<"$_doc"; then echo "PASS: doctor avisa con AMD";
else echo "FAIL: doctor avisa con AMD"; FAIL=$((FAIL+1)); fi

g() { # g <nombre> <quiero> <tengo>
    if [[ "$3" == "$2" ]]; then echo "PASS: $1";
    else echo "FAIL: $1 (quiero '$2', tengo '$3')"; FAIL=$((FAIL+1)); fi
}

echo "== elf_class (file real + fallback)"
g "elf 64 real" "64" "$(elf_class /bin/true)"
g "elf texto vacio" "" "$(elf_class /etc/hostname 2>/dev/null || echo X)"
( file() { echo "foo ELF 32-bit LSB shared object"; } >/dev/null 2>&1
  : ) # subshell no puede tocar FAIL: capturar fuera
fm32="$(file() { echo "foo ELF 32-bit LSB shared object"; }; elf_class /x/libc.so)"
g "elf 32 mock" "32" "$fm32"
g "elf fallback lib32 sin file" "32" "$(PATH=/nonexistent elf_class /x/lib32/fake.so)"
g "elf fallback resto sin file" "" "$(PATH=/nonexistent elf_class /x/lib/fake.so)"

echo "== nvidia_libs (mocks probativos)"
E="$D/empty"; mkdir -p "$E/r" "$E/r64" "$E/r32"
out="$(ARXY_NVIDIA_LIB_ROOT="$E/r" ARXY_NVIDIA_LIB_ROOT64="$E/r64" ARXY_NVIDIA_LIB_ROOT32="$E/r32" nvidia_libs)"
g "libs vacio con mocks vacios" "" "$out"
M="$D/nv"; mkdir -p "$M/r64" "$M/r32"
cp /bin/true "$M/r64/libcuda.so.550.54.14"
ln -s libcuda.so.550.54.14 "$M/r64/libcuda.so.1"
cp /bin/true "$M/r64/libGLX_nvidia.so.0"
cp /bin/true "$M/r64/libGLESv2.so.0" # mesa: sin 'nvidia', no debe salir
cp /bin/true "$M/r32/libnvidia-glcore.so.550.54.14"
out="$(ARXY_NVIDIA_LIB_ROOT="$M/r" ARXY_NVIDIA_LIB_ROOT64="$M/r64" ARXY_NVIDIA_LIB_ROOT32="$M/r32" nvidia_libs)"
[[ "$(printf '%s\n' "$out" | wc -l)" -eq 3 ]] && echo "PASS: libs 3 lineas (dedup link)" || { echo "FAIL: libs 3 lineas (tengo '$out')"; FAIL=$((FAIL+1)); }
grep -qE "^64[[:space:]]+.*libcuda" <<<"$out" && echo "PASS: libs libcuda 64" || { echo "FAIL: libs libcuda 64"; FAIL=$((FAIL+1)); }
grep -q "libGLESv2" <<<"$out" && { echo "FAIL: libs mesa excluida"; FAIL=$((FAIL+1)); } || echo "PASS: libs mesa excluida"
grep -q "libnvidia-glcore" <<<"$out" && echo "PASS: libs lib32 detectada" || { echo "FAIL: libs lib32"; FAIL=$((FAIL+1)); }
out="$(nvidia_libs 2>/dev/null)"
[[ $? -eq 0 ]] && echo "PASS: libs sin mock no falla" || { echo "FAIL: libs sin mock rc"; FAIL=$((FAIL+1)); }
# M9: invariante de contenido (no solo rc): con libs en host, no vacio; sin ellas, vacio+rc0 valido.
if ls /usr/lib64/libcuda* /usr/lib/libcuda* /usr/lib/x86_64-linux-gnu/libcuda* >/dev/null 2>&1; then
    [[ -n "$out" ]] && echo "PASS: libs host no vacio" || { echo "FAIL: libs host vacio con NVIDIA"; FAIL=$((FAIL+1)); }
else
    [[ -z "$out" ]] && echo "PASS: libs host vacio sin NVIDIA" || { echo "FAIL: libs host no vacio sin NVIDIA"; FAIL=$((FAIL+1)); }
fi

echo "== nvidia_icds + rewrite"
V="$D/icd"; mkdir -p "$V/vk" "$V/egl"
printf '{\n "file_format_version": "1.0.0",\n "ICD": { "library_path": "/usr/lib/libGLX_nvidia.so.0" }\n}\n' > "$V/vk/nvidia_icd.json"
printf '{ "ICD": { "library_path": "/usr/lib/libEGL_nvidia.so.0" } }\n' > "$V/egl/10_nvidia.json"
out="$(ARXY_VULKAN_ICD_PATH="$V/vk" ARXY_EGL_PLATFORM_PATH="$V/egl" nvidia_icds)"
[[ "$(printf '%s\n' "$out" | wc -l)" -eq 2 ]] && echo "PASS: icds 2" || { echo "FAIL: icds 2 (tengo '$out')"; FAIL=$((FAIL+1)); }
grep -q "^vulkan" <<<"$out" && grep -q "^egl" <<<"$out" && echo "PASS: icds kinds" || { echo "FAIL: icds kinds"; FAIL=$((FAIL+1)); }
out="$(nvidia_icd_rewrite "$V/vk/nvidia_icd.json" /usr/lib/arxy-nvidia/lib64/libGLX_nvidia.so.0)"
grep -q '"/usr/lib/arxy-nvidia/lib64/libGLX_nvidia.so.0"' <<<"$out" && echo "PASS: rewrite cambia path" || { echo "FAIL: rewrite cambia path"; FAIL=$((FAIL+1)); }
grep -q '"/usr/lib/libGLX_nvidia.so.0"' <<<"$out" && { echo "FAIL: rewrite quita viejo"; FAIL=$((FAIL+1)); } || echo "PASS: rewrite quita viejo"
printf '{ "sin": "library" }\n' > "$V/vk/otro.json"
g "rewrite sin library passthrough" '{ "sin": "library" }' "$(nvidia_icd_rewrite "$V/vk/otro.json" /x/y)"

echo "== nvidia_guest_path"
g "guest 64" "/usr/lib/arxy-nvidia/lib64/libcuda.so.1" "$(nvidia_guest_path /usr/lib64/libcuda.so.1 64)"
g "guest 32" "/usr/lib/arxy-nvidia/lib32/libcuda.so.1" "$(nvidia_guest_path /usr/lib/libcuda.so.1 32)"
g "guest plugin xorg" "/usr/lib/arxy-nvidia/lib64/xorg/modules/drivers/nvidia_drv.so" "$(nvidia_guest_path /usr/lib/xorg/modules/drivers/nvidia_drv.so 64)"
g "guest sin clase vacio" "" "$(nvidia_guest_path /usr/lib/libcuda.so.1 "")"

echo "== nvidia_mounts (mock integral)"
MD="$D/nvdev"; mkdir -p "$MD"; touch "$MD/nvidia0"
out="$(ARXY_NVIDIA_LIB_ROOT="$M/r" ARXY_NVIDIA_LIB_ROOT64="$M/r64" ARXY_NVIDIA_LIB_ROOT32="$M/r32" ARXY_VULKAN_ICD_PATH="$V/vk" ARXY_EGL_PLATFORM_PATH="$V/egl" ARXY_DEV_PATH="$MD" nvidia_mounts)"
grep -q "libcuda.*arxy-nvidia" <<<"$out" && echo "PASS: mounts lib" || { echo "FAIL: mounts lib"; FAIL=$((FAIL+1)); }
grep -q "nvidia_icd.json.*/usr/share/vulkan/icd.d/nvidia_icd.json" <<<"$out" && echo "PASS: mounts icd" || { echo "FAIL: mounts icd"; FAIL=$((FAIL+1)); }
grep -q "nvidia0.*nvidia0" <<<"$out" && echo "PASS: mounts device identidad" || { echo "FAIL: mounts device"; FAIL=$((FAIL+1)); }
out="$(nvidia_mounts 2>/dev/null)"
[[ $? -eq 0 ]] && echo "PASS: mounts sin mock no falla" || { echo "FAIL: mounts sin mock rc"; FAIL=$((FAIL+1)); }
# M9: idem mounts: con /dev/nvidia* en host, no vacio; sin ellos, vacio OK.
if ls /dev/nvidia* >/dev/null 2>&1; then
    [[ -n "$out" ]] && echo "PASS: mounts host no vacio" || { echo "FAIL: mounts host vacio con NVIDIA"; FAIL=$((FAIL+1)); }
else
    [[ -z "$out" ]] && echo "PASS: mounts host vacio sin NVIDIA" || { echo "FAIL: mounts host no vacio sin NVIDIA"; FAIL=$((FAIL+1)); }
fi

echo "== rewrite con espacios y & (sustitucion literal, no sed)"
printf '{ "ICD": { "library_path": "/usr/lib/con espacios/lib&A_nvidia.so.0" } }\n' > "$V/vk/esp.json"
out="$(nvidia_icd_rewrite "$V/vk/esp.json" /usr/lib/arxy-nvidia/lib64/libA_nvidia.so.0)"
grep -q '"/usr/lib/arxy-nvidia/lib64/libA_nvidia.so.0"' <<<"$out" && echo "PASS: rewrite espacios+&" || { echo "FAIL: rewrite espacios+& (tengo '$out')"; FAIL=$((FAIL+1)); }
grep -q 'con espacios' <<<"$out" && { echo "FAIL: rewrite quita viejo con espacios"; FAIL=$((FAIL+1)); } || echo "PASS: rewrite quita viejo con espacios"

echo "== run_in integra NVIDIA (fake bwrap, sin root)"
FB="$D/fakebin"; mkdir -p "$FB"
cat > "$FB/bwrap" <<'EOF'
#!/usr/bin/env bash
# fake bwrap: registra argv y vuelca el contenido de cada --ro-bind-data FD
rec="${BWRAP_RECORD:?}"
: > "$rec"
printf '%s\n' "$@" >> "$rec"
args=("$@"); i=0
while (( i < ${#args[@]} )); do
    if [[ "${args[i]}" == --ro-bind-data ]]; then
        printf 'FDCONTENT %s\n' "${args[i+2]}" >> "$rec"
        cat "/dev/fd/${args[i+1]}" >> "$rec" 2>/dev/null || printf '(FD ilegible)\n' >> "$rec"
        printf 'ENDFD\n' >> "$rec"
    fi
    i=$((i+1))
done
exit 0
EOF
chmod +x "$FB/bwrap"
REC="$D/bwrap-argv"
# bwrap_base no toca GPU aunque haya mocks (pacman via in_bwrap intacto)
out="$(ARXY_NVIDIA_LIB_ROOT="$M/r" ARXY_NVIDIA_LIB_ROOT64="$M/r64" ARXY_NVIDIA_LIB_ROOT32="$M/r32" ARXY_VULKAN_ICD_PATH="$V/vk" ARXY_EGL_PLATFORM_PATH="$V/egl" ARXY_DEV_PATH="$MD" bwrap_base 2>/dev/null | grep -c arxy-nvidia || true)"
g "bwrap_base intacto con mocks" "0" "$out"
# sin NVIDIA -> args sin rastro (mock vacio)
( PATH="$FB:$PATH" BWRAP_RECORD="$REC" ARXY_NVIDIA_LIB_ROOT="$E/r" ARXY_NVIDIA_LIB_ROOT64="$E/r64" ARXY_NVIDIA_LIB_ROOT32="$E/r32" ARXY_VULKAN_ICD_PATH="$E/r" ARXY_EGL_PLATFORM_PATH="$E/r" ARXY_DEV_PATH="$E/r" run_in -- /bin/true ) >/dev/null 2>&1
g "run_in vacio sin NVIDIA" "0" "$(grep -c arxy-nvidia "$REC" || true)"
# con NVIDIA -> dirs antes que binds, dev-bind, ro-bind-data con contenido
# Host musl (Void): run_in vacía userspace NVIDIA; mock glibc (ld-linux sin
# ld-musl → detect_libc=glibc, invierte el bloque musl de abajo) para no activar el wipe.
mkdir -p "$D/glibclib" "$D/glibclib64"
touch "$D/glibclib64/ld-linux-x86-64.so.2"
( PATH="$FB:$PATH" BWRAP_RECORD="$REC" ARXY_LIB_DIR="$D/glibclib" ARXY_LIB64_DIR="$D/glibclib64" ARXY_NVIDIA_LIB_ROOT="$M/r" ARXY_NVIDIA_LIB_ROOT64="$M/r64" ARXY_NVIDIA_LIB_ROOT32="$M/r32" ARXY_VULKAN_ICD_PATH="$V/vk" ARXY_EGL_PLATFORM_PATH="$V/egl" ARXY_DEV_PATH="$MD" run_in -- /bin/true ) >/dev/null 2>&1
# Mock ARXY_DEV_PATH fuera de /dev/* → run_in usa --ro-bind (no --dev-bind);
# se acepta cualquiera pero se exige nvidia0 (si cae el bind, falla igual).
grep -qE -- '--(dev-bind|ro-bind)' "$REC" && grep -q "nvidia0" "$REC" && echo "PASS: run_in dev-bind nvidia0" || { echo "FAIL: run_in dev-bind"; FAIL=$((FAIL+1)); }
grep -q "libcuda" "$REC" && grep -q "arxy-nvidia/lib64" "$REC" && echo "PASS: run_in ro-bind lib" || { echo "FAIL: run_in ro-bind lib"; FAIL=$((FAIL+1)); }
dline="$(grep -n -- '--dir' "$REC" | head -1 | cut -d: -f1)"; bline="$(grep -n "arxy-nvidia/lib64/libcuda" "$REC" | head -1 | cut -d: -f1)"
[[ -n "$dline" && -n "$bline" && "$dline" -lt "$bline" ]] && echo "PASS: run_in dir antes que bind" || { echo "FAIL: run_in orden dir/bind"; FAIL=$((FAIL+1)); }
grep -q "FDCONTENT /usr/share/vulkan/icd.d/nvidia_icd.json" "$REC" && echo "PASS: run_in icd ro-bind-data" || { echo "FAIL: run_in icd ro-bind-data"; FAIL=$((FAIL+1)); }
grep -q '"/usr/lib/arxy-nvidia/lib64/libGLX_nvidia.so.0"' "$REC" && echo "PASS: run_in icd reescrito en FD" || { echo "FAIL: run_in icd contenido FD"; FAIL=$((FAIL+1)); }
grep -q '"/usr/lib/libGLX_nvidia.so.0"' "$REC" && { echo "FAIL: run_in icd path viejo en FD"; FAIL=$((FAIL+1)); } || echo "PASS: run_in icd sin path viejo"
# un ICD 32-bit no debe reescribirse a lib64 (rompia el loader 32
# en silencio). file stubbed a 32-bit => determinista sin ELF real.
echo "== run_in ICD 32-bit reescribe a lib32"
V32="$D/icd32"; mkdir -p "$V32/vk"
printf '{\n "file_format_version": "1.0.0",\n "ICD": { "library_path": "/usr/lib32/libGLX_nvidia.so.0" }\n}\n' > "$V32/vk/nvidia_icd32.json"
file() { echo "foo ELF 32-bit LSB shared object"; }
( PATH="$FB:$PATH" BWRAP_RECORD="$REC" ARXY_LIB_DIR="$D/glibclib" ARXY_LIB64_DIR="$D/glibclib64" ARXY_NVIDIA_LIB_ROOT="$E/r" ARXY_NVIDIA_LIB_ROOT64="$E/r64" ARXY_NVIDIA_LIB_ROOT32="$E/r32" ARXY_VULKAN_ICD_PATH="$V32/vk" ARXY_EGL_PLATFORM_PATH="$E/r" ARXY_DEV_PATH="$MD" run_in -- /bin/true ) >/dev/null 2>&1
unset -f file
grep -q '"/usr/lib/arxy-nvidia/lib32/libGLX_nvidia.so.0"' "$REC" && echo "PASS: run_in icd32 a lib32" || { echo "FAIL: run_in icd32 a lib32"; FAIL=$((FAIL+1)); }
grep -q 'lib64/libGLX_nvidia' "$REC" && { echo "FAIL: run_in icd32 fugo a lib64"; FAIL=$((FAIL+1)); } || echo "PASS: run_in icd32 sin lib64"

echo "== musl: sin userspace del host (solo devices de la base)"
mkdir -p "$D/musllib" "$D/musllib64"
touch "$D/musllib/ld-musl-x86_64.so.1"
g "detect_libc mock musl" "musl" "$(ARXY_LIB_DIR="$D/musllib" ARXY_LIB64_DIR="$D/musllib64" detect_libc)"
( PATH="$FB:$PATH" BWRAP_RECORD="$REC" ARXY_LIB_DIR="$D/musllib" ARXY_LIB64_DIR="$D/musllib64" ARXY_NVIDIA_LIB_ROOT="$M/r" ARXY_NVIDIA_LIB_ROOT64="$M/r64" ARXY_NVIDIA_LIB_ROOT32="$M/r32" ARXY_VULKAN_ICD_PATH="$V/vk" ARXY_EGL_PLATFORM_PATH="$V/egl" ARXY_DEV_PATH="$MD" run_in -- /bin/true ) >/dev/null 2>&1
g "run_in musl+NVIDIA sin arxy-nvidia" "0" "$(grep -c arxy-nvidia "$REC" || true)"
g "run_in musl sin ro-bind-data" "0" "$(grep -c -- --ro-bind-data "$REC" || true)"
( PATH="$FB:$PATH" BWRAP_RECORD="$REC" ARXY_LIB_DIR="$D/musllib" ARXY_LIB64_DIR="$D/musllib64" ARXY_NVIDIA_LIB_ROOT="$E/r" ARXY_NVIDIA_LIB_ROOT64="$E/r64" ARXY_NVIDIA_LIB_ROOT32="$E/r32" ARXY_VULKAN_ICD_PATH="$E/r" ARXY_EGL_PLATFORM_PATH="$E/r" ARXY_DEV_PATH="$MD" run_in -- /bin/true ) >/dev/null 2>&1
g "run_in musl+AMD(dri) sin arxy-nvidia" "0" "$(grep -c arxy-nvidia "$REC" || true)"

echo "== gpu_stack_pkgs por vendor"
mkdir -p "$D/drmA/card0/device" "$D/drmN/card0/device"
printf '0x1002' > "$D/drmA/card0/device/vendor"
printf '0x10de' > "$D/drmN/card0/device/vendor"
g "stack amd" "vulkan-radeon lib32-vulkan-radeon" "$(ARXY_SYS_DRM_PATH="$D/drmA" gpu_stack_pkgs | xargs)"
# NVIDIA pinneado al modulo del host (antes sin pin: mismatch silencioso).
mkdir -p "$D/nvroot/proc/driver/nvidia"
printf 'NVRM version: NVIDIA UNIX x86_64 Kernel Module  550.54.14\n' > "$D/nvroot/proc/driver/nvidia/version"
g "stack nvidia pinneado" "nvidia-utils=550.54.14 lib32-nvidia-utils=550.54.14" "$(ARXY_SYS_DRM_PATH="$D/drmN" ARXY_SYS_ROOT="$D/nvroot" gpu_stack_pkgs | xargs)"
(ARXY_SYS_DRM_PATH="$D/drmN" ARXY_SYS_ROOT="$D/emptyroot" gpu_stack_pkgs >/dev/null 2>&1)
g "stack nvidia sin version muere claro" "1" "$?"
g "stack sin discreta asume intel" "vulkan-intel lib32-vulkan-intel" "$(ARXY_SYS_DRM_PATH="$E/r" gpu_stack_pkgs | xargs)"

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
