# GAMING.md — Steam and games on arxy

`arxy install arxy-gaming` deploys a gaming stack matched to your GPU. This
page is the short version; limits that can't be worked around are in
[OUT-OF-SCOPE.md](OUT-OF-SCOPE.md).

## 1. Install the stack

```bash
arxy install arxy-gaming --dry-run   # show the exact package list first
arxy install arxy-gaming
```

Detection is automatic. If it's inconclusive, force the vendor:

```bash
arxy install arxy-gaming-intel      # or -amd, or -nvidia
```

The stack is Steam, Wine, `vkd3d`, gamescope, MangoHUD and the Vulkan loaders,
plus the full Mesa (or `nvidia-utils`) stack for your GPU, `multilib` enabled
for the 32-bit libraries, and Proton-GE + DXVK from the AUR (`-bin`, built as
your unprivileged user, so **Level 1 only**). The AUR toolchain (including
`makepkg` itself) installs on first use. Level 2 fails before touching
anything, so a failed run never leaves half a stack.

Note the Mesa trade-off: the mini image holds `mesa` via `IgnorePkg=mesa`
(keeping it around 170 MB). `arxy-gaming` lifts that hold to get the full Mesa
with LLVM, which is what games actually need.

## 2. Start the host bridge (optional)

```bash
arxy host-bridge --daemon
```

Forwards notifications and clickable links from the game to your desktop. Not
required to play; nicer when you use it. The daemon only forwards commands on
its allowlist (`ARXY_BRIDGE_ALLOWLIST`, empty = a small built-in list) and
refuses to start without one.

## 3. Launch Steam as your user

```bash
arxy run steam
```

Never as root: by Valve's design Steam crashes or refuses to start as root,
and arxy won't work around that.

The first launch downloads hundreds of MB of its own runtime from Valve's
servers. It's slow, it's upstream behaviour, and it's unrelated to arxy.

Then log in, pick an undemanding game and check it boots.

## 4. Confirm real acceleration

```bash
MANGOHUD=1 arxy run steam     # performance overlay
```

MangoHUD on screen means the game is going through the GPU stack. To inspect
the stack directly:

```bash
arxy run glxinfo -B
arxy run eglinfo -B
arxy run vulkaninfo --summary
```

## What won't work

- **Anti-cheat** (EAC, BattlEye, Vanguard, Ricochet): needs a host kernel
  driver and anti-VM telemetry. Not fixable in a container — by design.
  Check the game's manifest on ProtonDB before installing.
- **Kernel modules arxy can't supply**: `nvidia` (proprietary), `ntsync`,
  `fuse`. If the host lacks them, the feature that needs them doesn't work.
- **NVIDIA**: nouveau/Mesa only. `arxy-gaming-nvidia` requires the proprietary
  module to already be loaded on the host.
- **System daemons**: games or launchers that spawn background services
  (TeamViewer, AnyDesk) won't start inside the subsystem.
- **VPN clients**: `protonvpn-app` clashes with the host client over the shared
  D-Bus.

Steam itself, Proton, `umu-launcher` and Wine titles are fine.