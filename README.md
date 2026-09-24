# arxy — run Arch software on any distro, at native speed

```bash
sudo arxy setup                  # first time: downloads a minimal Arch (~128MB, ~490MB on disk)
arxy quickstart                  # points you at the next logical step
arxy install telegram-desktop    # installs from official repos (and creates the menu launcher)
arxy install --aur spotify       # installs prebuilt AUR packages (-bin)
arxy run rar x archivo.rar       # runs CLI tools directly inside the subsystem

```

## Installation (the shortest path)

1. Clone the repo and run the installer. Works on any distro (no `curl | bash` script for now because the installer needs the full local repo layout):

```bash
git clone https://github.com/SrDicov/arxy && cd arxy   # you need `git`, obviously
sudo ./install.sh              # installs to /usr/local (arxy + axy; skip `sudo` if already root)
sudo arxy setup                # downloads the base Arch image, ready to use

```

**Void Linux** (install from z-repo, as an alternative to the above):

```bash
echo "repository=https://srdicov.github.io/z-repo/x86_64" | sudo tee /etc/xbps.d/20-zrepo.conf
yes | sudo xbps-install -S   # imports the repo key (first time only)
sudo xbps-install -y arxy

```

For Void musl the repo is `.../z-repo/x86_64-musl`. To build the package yourself, copy `packaging/void/arxy/` into your `void-packages/srcpkgs/` and run `xbps-src pkg arxy`.

**Installer options** (`install.sh --help`): `PREFIX=` (defaults to `/usr/local`), `DESTDIR=` (handy as a staging env when packaging for your distro), or `--without-bridge` (skips the daemon, which is what the xbps package currently does). For the bridge, compile the binary with `make bridge` first. Note: `sudo arxy setup` always writes to `/var/lib/arxy`, so it needs root.

To try a local image or your own build: `ARXY_IMAGE_URL=file:///ruta/al.tar.zst` (note `file://` mishandles spaces in the path). Piped install (`curl | bash`) is on the v1.x roadmap; for now, clone.

**Host requirements:** `bash bwrap curl tar zstd xz gzip file` and `bash>=4.4`. Check with `arxy doctor`.

## Day-to-day use

| Command | What it does |
| --- | --- |
| `arxy install <pkg...>` / `--aur` | Installs packages (official or AUR `-bin`) and creates menu shortcuts. Asks for `sudo` under the hood. AUR ones build as your unprivileged user, then ask for the password to install. Downloads the base image if missing. Launchers go to `~/.local/share/applications/`. |
| `arxy remove <pkg...>` | Removes the package and its menu launcher. |
| `arxy run <bin> [args]` | Runs any binary or command inside the subsystem. |
| `arxy which <bin>` | Tells you whether the executable resolves from the [subsystem] or the [host]. |
| `arxy shell` | Opens a native Arch interactive shell. |
| `arxy search/info/list/update` | Searches packages, shows details, lists installed, or updates the whole subsystem. |
| `arxy export --all` | Forces regeneration of all app menu launchers. |
| `arxy setup / doctor` | (Re)downloads the image atomically with rollback / checks environment health. |
| `arxy quickstart` | Inspects your install state and suggests what to do next. |
| `arxy dedup` | Hardlinks identical files under `/usr`. Runs automatically after `install`/`update` when savings exceed 10 MB (disable with `ARXY_NO_AUTO_DEDUP=1`). |
| `axy` | Short alias so you don't type `arxy` all day. |
| `arxy install arxy-gaming [--dry-run]` | Deploys the gaming stack matched to your GPU. If detection is inconclusive, use `arxy-gaming-amd`, `arxy-gaming-intel`, or `arxy-gaming-nvidia`. The AUR part builds in userspace and needs Level 1. |
| `arxy host-bridge [--daemon\|--stop\|--status]` | Manages the host-bridge daemon, which forwards notifications and links from the sandbox to your host. |

When something breaks: `arxy doctor` → `arxy doctor --fix` → `arxy quickstart`.

```bash
# doctor output is parseable for integrations:
arxy doctor --json | jq '{nivel: .level, libc: .libc.kind, gpu: .gpu.vendor}'
# Expected output: {"nivel": 1, "libc": "glibc", "gpu": "intel"} (format: 1 is stable)

```

**On repairs:** `arxy doctor --fix` only reports and suggests, it breaks nothing. With `--apply` (as root) it applies non-destructive fixes. With `--apply --confirm` it opens a tty to confirm destructive ones (for now, basically a stale `db.lck`). `--json` never applies anything, it just returns `fixes_available` and `fixes`. (The `nvidia-align`, `musl-glibc-stack` and `gpu-full-stack` fix types are proposed only; installing them stays opt-in.)

`setup` saves your hardware profile to `/var/lib/arxy/hardware.json` (atomic cache, `format: 1`, rewritten only on change). Then `arxy version --verbose` reads it and warns if your kernel or NVIDIA driver changed, while `doctor --json` always computes live. Refreshing the profile without `setup` is pending work.

**Configuration:** system-wide at `/etc/arxy/arxy.conf`, per-user at `~/.config/arxy/config`. These are data files, not shell scripts: use one `ARXY_KEY=value` assignment per line, with optional single or double quotes. Shell expansion and command execution are deliberately disabled, including under `sudo`. Supported file keys are `ARXY_ROOT`, `ARXY_IMAGE_URL`, `ARXY_IMAGE_SHA256`, `ARXY_SIGNATURE_POLICY`, `ARXY_LEVEL`, `ARXY_GPG_CHECK`, `ARXY_KEEP_PKG_CACHE`, `ARXY_NO_AUTO_DEDUP`, `ARXY_NO_BRIDGE`, `ARXY_BRIDGE_ALLOWLIST`, and `ARXY_BRIDGE_BIN`. Documented runtime values can still be overridden through the environment.

## Architecture: the 2 execution levels

Starting the subsystem costs next to nothing. The image is just an Arch rootfs extracted flat into `/var/lib/arxy/root` (no squashfs or FUSE layers slowing down I/O; plain files). We share `/home`, `/tmp`, `/run`, `/dev` and direct GPU access. Your real system shows up at `/host`. That's the whole trick behind native speed. Reads and software execution run as your unprivileged user; we only escalate to `sudo` to install or update.

* **Level 1** (bwrap + user namespaces): default and recommended.
* **Level 2** (no namespaces): `run` injects the subsystem's `ld-linux`, `install` uses classic chroot with sudo. For hardened kernels or container environments where `bwrap` is neutered. The level is auto-detected (see `arxy doctor`), or force it with `ARXY_LEVEL=1|2`.

## Known limitations:

* **AMD/NVIDIA: support exists in theory, untested on real hardware.** If `arxy doctor` sees your dedicated card, `install gpu-amd` / `gpu-nvidia` install official `mesa` (with LLVM, unlike the default `mesa-mini`) by lifting the `IgnorePkg=mesa` hold (~170MB extra). Implemented, no empirical success metrics yet.
* **Proprietary NVIDIA drivers:** out of scope for 1.x. Nouveau via Mesa only, for now.
* **Intel iGPU and softpipe:** fully verified (tested on HD 630 with full acceleration, no LLVM needed).
* **AUR:** Level 1 only (building needs namespaces), prebuilt (`-bin`) packages only. No heavy toolchains inside arxy. PGP signature checks are skipped by default (`--skippgpcheck`) unless you force them with `ARXY_GPG_CHECK=1`.
* **Zero security sandbox:** don't rely on arxy to isolate processes. No isolation at either level. Think of it as a compat layer to stop fighting `glibc`, not a safe environment. **Don't run untrusted software.**
* For current tech debt and permanent design limits, see `OUT-OF-SCOPE.md`.
* **System daemons:** anything needing `systemd` or persistent root daemons (TeamViewer, AnyDesk) won't work inside the subsystem. And `protonvpn-app` clashes with the host client fighting over the same instance on the shared D-Bus. Steam and `umu-launcher` work fine (multilib enabled).
* At Level 2, raw `pacman -S/-U/-R` inside `arxy shell` is blocked on purpose (use `arxy install/remove/update`). `CheckSpace` is off under chroot, and absolute-path cache handling for GTK/Qt is best-effort.
* `arxy rollback` reverts the rootfs to your last `setup` (you lose whatever you installed since). `arxy clean --apply` purges caches and destroys the rollback point.
* Dedup uses hardlinks under `/usr` only. Since `pacman` replaces files instead of rewriting in place, links break cleanly on update without corrupting the host. Nothing outside `/usr` gets linked.

## Validation and testing

* **Test matrix across 5 distros** (Alpine, Chimera, Void, Ubuntu, privileged Ubuntu): runs via `arxy-image/tests/matrix.sh`. Strict assertions on resulting content, not just exit codes (33–43 checks depending on level and flags: libc branch, L2 fallback and `MATRIX_WRITE2=1` chroot vary by environment).
Covers the full Level 1 cycle (install, run, export, remove) and Level 2 for reads and AUR blocks. Level 2 writes are tested by forcing `MATRIX_WRITE2=1`. Shortcut export under L2 needs more automated coverage (hand-verified). The matrix runs in CI on every base image build.
* **Real hardware** (Intel HD 630): `tests/test-hardware.sh` checks D-Bus on L1/L2, `iris` GL acceleration, LLVM-less softpipe rendering, and boots a real Electron app rendering a window. (`dbus-send` isn't in the mini image, so that test legitimately SKIPs unless you `arxy install dbus`.)

## Installing Steam (step by step)

Not fully automated, Steam has its quirks:

1. Run `arxy install arxy-gaming`. Gets you Steam, Proton, Wine (the AUR dependency builds as your normal user, no root).
2. Start the daemon with `arxy host-bridge --daemon`. Optional but recommended for native notifications and clickable links between game and desktop.
3. Launch Steam with `arxy run steam` **as your user** (by Valve's design, Steam crashes or refuses to start as root). First launch downloads hundreds of MB of its own runtime; be patient, that comes from Valve's servers, not arxy.
4. Log in, grab an undemanding game to test, check it boots.
5. To confirm real hardware acceleration, launch Steam with MangoHUD: `MANGOHUD=1 arxy run steam` (performance overlay on screen).

## Contributing

Bash only; the golden rule is no new dependencies.

Before committing or opening a PR, pass these checks:

```bash
make sync
make verify               # syntax, ShellCheck when installed, deterministic suite, packaging copies
make test-all              # optional: bridge/root/hardware tests; each keeps its own guards

```

**On layout:** `lib/*.sh` is source of truth (the final `src/arxy` binary just concatenates it; the installer pulls it straight from the clone). Modules have one responsibility: state/setup/GC (`20`–`22`), official packages/AUR/maintenance (`30`–`32`), and detection/doctor/JSON (`60`–`62`). `config/arxy.conf` is canonical too, and everything under `packaging/void/arxy/files/` are xbps packaging copies (CI fails on drift).

Before pushing, run the sibling repo's test matrix (`arxy-image/tests/matrix.sh`, instructions in `arxy-image/tests/README.md`). Also read `AGENTS.md`: design rules learned from real bugs that cost blood to find. `CONTRIBUTING.md` has the full contributor flow.

—

*Versión en español: [README.es.md](README.es.md).*

## License

Distributed under GPL-3.0-or-later — see [LICENSE](LICENSE).
