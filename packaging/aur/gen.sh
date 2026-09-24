#!/usr/bin/env bash
# gen.sh: regenera los 3 PKGBUILDs desde PKGBUILD.tpl (byte-identicos).
set -euo pipefail
cd "$(dirname "$0")" || exit 1
gen() { sed -e "s/@VENDOR@/$1/g" -e "s/@DESC@/$2/g" -e "s/@VULKAN_DEPS@/$3/g" PKGBUILD.tpl >"arxy-gaming-$1/PKGBUILD"; }
gen amd "Gaming stack for arxy on AMD" "'mesa' 'lib32-mesa' 'vulkan-radeon' 'lib32-vulkan-radeon'"
gen intel "Gaming stack for arxy on Intel" "'mesa' 'lib32-mesa' 'vulkan-intel' 'lib32-vulkan-intel'"
gen nvidia "Gaming stack for arxy on NVIDIA (proprietary driver)" "'nvidia-utils' 'lib32-nvidia-utils'"
