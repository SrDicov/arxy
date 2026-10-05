# arxy — run Arch software on any distro, at native speed

arxy is a minimal Arch subsystem that lives **next to** your current distro
instead of replacing it. It extracts a flat Arch rootfs into
`/var/lib/arxy/root`, shares `/home`, `/tmp`, `/run`, `/dev` and the GPU, and
runs Arch binaries on your host kernel. No dual boot, no VM, no slow image
layers.

- **Any distro** (glibc or musl host): Arch software next to your desktop.
- **Native speed**: plain files in a directory, not squashfs or FUSE layers.
- **No new dependencies**: the whole CLI is Bash.

## Install

From source, on any distro:

```bash
git clone https://github.com/SrDicov/arxy && cd arxy
sudo ./install.sh          # installs arxy + axy into /usr/local
sudo arxy setup            # downloads the base Arch image (~128MB, ~490MB on disk)
```

Void Linux, from z-repo:

```bash
echo "repository=https://srdicov.github.io/z-repo/x86_64" | sudo tee /etc/xbps.d/20-zrepo.conf
yes | sudo xbps-install -S   # imports the repo key, first time only
sudo xbps-install -y arxy
sudo arxy setup
```

Host requirements: `bash >= 4.4`, `bwrap`, `curl`, `tar`, `zstd`, `xz`, `gzip`,
`file`. Verify them any time with `arxy doctor`. Other install paths (packaging
for your distro, local images, daemon) are in
[ARCHITECTURE.md](ARCHITECTURE.md#4-install-variants).

## First commands

```bash
arxy quickstart                  # what to do next, given your current state
arxy install firefox gimp        # official repos, plus menu launchers
arxy install --aur spotify       # prebuilt AUR packages (-bin)
arxy run rar x archivo.rar       # run any Arch binary
arxy shell                       # full interactive Arch terminal
```

`axy` is a shorter alias. An unrecognized command is treated as `arxy run`, so
`arxy firefox` works too.

## Commands

| Command | What it does |
| --- | --- |
| `install <pkg...>` / `install --aur <pkg>` | Install packages (official or AUR `-bin`) and create menu launchers. Elevation is handled for you. |
| `remove <pkg...>` | Remove a package and its launcher. |
| `update` | Update the whole subsystem. |
| `run <bin> [args]` | Run any binary or command inside the subsystem. |
| `shell` | Interactive Arch shell (`sudo arxy shell` for manual `pacman`). |
| `search` / `search-aur` / `info` / `list` | Query repos, AUR and installed packages. |
| `which <bin>` | Tell whether it resolves from the subsystem or from the host. |
| `export --all` | Regenerate all menu launchers. |
| `setup` | (Re)download the image atomically, keeping one rollback generation. |
| `doctor` | Check the environment. `--json` for integrations. |
| `quickstart` | Inspect your state and suggest the next step. |
| `dedup` | Hardlink identical files under `/usr` (also runs automatically). |
| `rollback` / `clean --apply` / `gc --apply` | Restore the previous image / purge caches and disk. |
| `host-bridge --daemon` | Forward notifications and links from apps to your desktop. |

Every command with its flags: `arxy help`.

When something breaks: `arxy doctor` → `arxy doctor --fix` → `arxy quickstart`.

## Gaming

```bash
arxy install arxy-gaming      # Steam + Proton + Wine, matched to your GPU
arxy run steam                # must run as your user, not as root
```

First launch, MangoHUD and the GPU stacks: [GAMING.md](GAMING.md).

## Limits worth knowing before you install

- **No security isolation.** arxy is a compatibility layer, not a sandbox. Don't run untrusted software.
- **No kernel modules**: no proprietary NVIDIA driver (nouveau only), no anti-cheat (EAC, BattlEye, Vanguard), no `fuse`/`ntsync`.
- **No system daemons**: software that needs `systemd` inside the subsystem (TeamViewer, AnyDesk) won't run.

Every known limit, with the reason and the upgrade path, is listed in
[OUT-OF-SCOPE.md](OUT-OF-SCOPE.md).

## How it works, in one paragraph

`arxy run` enters the rootfs with `bwrap` and user namespaces (**Level 1**):
reads and program execution happen as your normal user, and only installing or
updating escalate (`sudo`/`doas`, or a polkit dialog with no terminal). Where
user namespaces are disabled — hardened kernels, some containers — arxy falls
back to **Level 2**: `run` injects the subsystem's dynamic loader and installs
go through `chroot` + `sudo`. Your real system is visible at `/host`. Full
details in [ARCHITECTURE.md](ARCHITECTURE.md).

## Documentation

| Document | Contents |
| --- | --- |
| [ARCHITECTURE.md](ARCHITECTURE.md) | How the subsystem is built, install variants, configuration reference, `doctor` output, maintenance, validation. |
| [GAMING.md](GAMING.md) | GPU stacks, Steam, MangoHUD, host-bridge. |
| [OUT-OF-SCOPE.md](OUT-OF-SCOPE.md) | Every known limit and why it exists. |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to propose a change. |
| [AGENTS.md](AGENTS.md) / [HACKING.md](HACKING.md) | Architectural contracts for contributors. |
| [CHANGELOG.md](CHANGELOG.md) | Release history. |
| [SECURITY.md](SECURITY.md) | Reporting a vulnerability. |

*Versión en español: [README.es.md](README.es.md).*

## License

GPL-3.0-or-later — see [LICENSE](LICENSE).