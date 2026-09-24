# Maintainer: arxy contributors
# Meta-paquete gaming (draft: aun no publicado en AUR).
# Lista canonica en bash: arxy_gaming_pkgs() en lib/30-package.sh
# (sincronizar al publicar).
pkgname=arxy-gaming-@VENDOR@
pkgver=1.0.0
pkgrel=1
pkgdesc="@DESC@"
arch=('any')
license=('GPL-3.0-or-later')
depends=('steam' 'wine' 'vkd3d' 'gamescope' 'mangohud'
         'vulkan-icd-loader' 'lib32-vulkan-icd-loader'
         @VULKAN_DEPS@
         'proton-ge-custom-bin' 'dxvk-bin')
package() {
    :
}
