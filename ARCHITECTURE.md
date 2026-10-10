# ARCHITECTURE.md — how arxy works

Reference for the pieces that don't fit in [README.md](README.md): what lives on
disk, the two execution levels, install variants, the configuration contract,
diagnostics, maintenance and validation. For known limits see
[OUT-OF-SCOPE.md](OUT-OF-SCOPE.md).

## 1. Layout on disk

| Path | Contents |
| --- | --- |
| `/var/lib/arxy/root` | The Arch rootfs, extracted **flat**: plain files, no squashfs and no FUSE layer. That's the whole reason for native I/O speed. |
| `/var/lib/arxy/root.old` | The previous `setup`, i.e. the rollback point. Only one generation is kept (§7). |
| `/var/lib/arxy/hardware.json` | Cached hardware profile written by `setup` (`format: 1`, atomic, rewritten only on change). A cache, not a source of truth. |
| `/var/lib/arxy/build` | AUR build directory, world-writable: AUR packages build as your unprivileged user. |
| `/var/lib/arxy/version` | Version published together with the image (the rename is atomic, so image and version never disagree). |
| `/var/lib/arxy/*.old.tmp.*` | Staging leftovers. Recovered automatically on the next invocation, so a `SIGKILL` at any point is always recoverable. |
| `~/.local/share/applications/arxy-*.desktop` | Generated menu launchers. The host system itself is never modified. |
| `/etc/arxy/arxy.conf`, `~/.config/arxy/config`, `/etc/arxy/arxy.pub` | Configuration and signature trust root (§5). |

The subsystem shares `/home`, `/tmp`, `/run`, `/dev` and direct GPU access with
the host; the host's real root is bind-mounted at `/host` inside. Sharing
`/home` and the GPU is what removes the usual container overhead: no display
bridge, no D-Bus proxy, no device forwarding.

## 2. Two execution levels

| | Level 1 (default) | Level 2 (fallback) |
| --- | --- | --- |
| Isolation | `bwrap` + user namespaces | none (loader injection) |
| `run` | direct exec inside the namespace | `ld-linux --library-path` into the subsystem rootfs |
| `install` / `update` | namespace + elevated pacman | `chroot` + `sudo` (classic) |
| Needs | unprivileged user namespaces | root to install |
| Use when | default | hardened kernels, containers where userns is disabled |

Detection is automatic and memoized (`arxy doctor --json` reports it); force it
with `ARXY_LEVEL=1|2`.

Reads and program execution always run as your normal user. Escalation happens
only to install or update, and it goes through `sudo`/`doas`, or `pkexec` when
there is no terminal (polkit dialog). `ARXY_*` variables reach the privileged
process only through the explicit pass-through list; a bare `sudo` operates on
the default rootfs.

Level 2 changes observable behaviour, and path parsing must survive both forms:

- Package listings can come back with paths prefixed by the root (`-Qlq --root`).
- Raw `pacman -S/-U/-R` inside `arxy shell` is blocked on purpose: use
  `arxy install/remove/update`.
- `CheckSpace` is off under chroot, and absolute-path cache handling for
  GTK/Qt apps is best-effort.

## 3. Image and signatures

The base image is a flat `.tar.zst` rootfs built by the sibling repo `arxy-image`
in CI and published in its `latest` release. DwarFS/SquashFS images were
discarded: they cost speed on every read.

`setup` verifies the download against the `.sha256` published next to the
tarball, and the signature per `ARXY_SIGNATURE_POLICY` (`required`, `optional`
— default — or `off`) against the trust root `/etc/arxy/arxy.pub`. Pinning
`ARXY_IMAGE_SHA256` together with `required` fails closed: the pin replaces the
signature check.

`setup` is atomic: staging directory → rename → fsync → rotate `root.old`.
Everything published (image, version, hardware profile) moves together. It also
activates the CachyOS repositories matching your CPU, but only if the rootfs
carries the marker for it (keyring + mirrorlists + commented `#[cachyos*]`
stanzas). Without the marker, or with an older image format, you get the base
repos and nothing is touched.

## 4. Install variants

### Remote one-liner (`install-remote.sh`)

```bash
curl -fsSL https://raw.githubusercontent.com/SrDicov/arxy/main/install-remote.sh | sudo bash
```

POSIX-sh bootstrap (runs even without bash) for any distro with `apt`,
`dnf`/`yum`, `pacman`, `apk`, `xbps`, `emerge` or `zypper`. It detects the
distro, package manager, privilege elevator (`sudo`/`doas`) and CPU
architecture, installs host dependencies by package-manager name (tolerating
unknown names, then verifying by command), compiles the host-bridge daemon
when a C compiler is available (otherwise `--without-bridge`), downloads the
arxy release tarball, runs `install.sh`, then `setup` (CPU-tier repos inside),
a full `update`, and verifies with `version` + a real `run` + `doctor`. Needs
x86_64 and ~1.5 GB free. Idempotent: safe to re-run. `--check` only reports
detection; env overrides: `ARXY_REF` (branch/tag, default `main`),
`ARXY_REPO` (forks), `ARXY_TARBALL_URL`, `PREFIX`, `DESTDIR`, `ARXY_ROOT`,
`ARXY_IMAGE_URL`, `ARXY_IMAGE_SHA256`, `ARXY_SIGNATURE_POLICY`.

### Generic installer (`install.sh`)

| Option | Effect |
| --- | --- |
| `PREFIX=` | Install prefix, default `/usr/local`. `PREFIX=/usr` to avoid shadowing a manual install in `/usr/local`. |
| `DESTDIR=` | Staging root, for packaging your distro (`DESTDIR=/tmp/pkg PREFIX=/usr ./install.sh`). |
| `--without-bridge` | Skip the host-bridge daemon (what the xbps package does). |

It installs `arxy` plus the `axy` symlink, `etc/arxy/arxy.conf` and the trust
root `arxy.pub` (always overwritten: it's not user configuration). An existing
`/etc/arxy/arxy.conf` is **preserved**, with the new one left beside it as
`arxy.conf.nuevo`. With the bridge enabled it needs `bridge/arxy-bridged`, so
run `make bridge` first.

Manual installs (`/usr/local/bin/arxy*`, `/usr/local/lib/arxy/`) shadow the
package via `PATH`: remove them before installing a distro package.

### Void Linux

The z-repo packages are built and signed by CI and validated by z-repo's
`check_outdated.py`:

```bash
echo "repository=https://srdicov.github.io/z-repo/x86_64" | sudo tee /etc/xbps.d/20-zrepo.conf
yes | sudo xbps-install -S
sudo xbps-install -y arxy
```

For musl hosts the repository is `.../z-repo/x86_64-musl`. To build the package
yourself, copy `packaging/void/arxy/` into your `void-packages/srcpkgs/` and run
`xbps-src pkg arxy`.

### Local or custom image

```bash
ARXY_IMAGE_URL=file:///path/to/rootfs.tar.zst sudo -E arxy setup
```

`file://` does not handle spaces in the path. `https://` URLs work the same way,
which is how you test a build before publishing it. The remote one-liner
accepts them too (`ARXY_IMAGE_URL=file:///path/to/rootfs.tar.zst`).

## 5. Configuration

Two files, both **data, never scripts**:

- system-wide: `/etc/arxy/arxy.conf`
- per user: `~/.config/arxy/config`

One `ARXY_KEY=value` assignment per line, optional single or double quotes.
Shell expansion and command execution are disabled — including when the file is
read as root — and the key list is closed, so a user config can't inject
privileged variables. Unknown keys are ignored with a warning.

Precedence: **environment > user config > system config**.

| Key | Meaning |
| --- | --- |
| `ARXY_ROOT` | Subsystem root (default `/var/lib/arxy/root`). |
| `ARXY_IMAGE_URL` | Where `setup` downloads the tarball (`https://` or `file://`). |
| `ARXY_IMAGE_SHA256` | Pin an exact tarball; empty means "verify against the published `.sha256`". |
| `ARXY_SIGNATURE_POLICY` | `required` \| `optional` (default) \| `off`. |
| `ARXY_LEVEL` | Force `1` or `2` instead of auto-detecting. |
| `ARXY_GPG_CHECK` | `1` enables AUR PKGBUILD signature checks (skipped by default). |
| `ARXY_KEEP_PKG_CACHE` | Keep the pacman cache instead of cleaning it after updates. |
| `ARXY_NO_AUTO_DEDUP` | `1` disables the automatic post-`install`/`update` dedup. |
| `ARXY_NO_BRIDGE` | `1` disables the host-bridge daemon. |
| `ARXY_BRIDGE_ALLOWLIST` | Commands the bridge daemon may forward. Empty = built-in list. |
| `ARXY_BRIDGE_BIN` | Path to the `arxy-bridged` helper binary. |

Documented runtime values can still be overridden through the environment
(`sudo -E` or an explicit `sudo VAR=… arxy …`).

## 6. Diagnostics

```bash
arxy doctor --json | jq '{nivel: .level, libc: .libc.kind, gpu: .gpu.vendor}'
# {"nivel":1,"libc":"glibc","gpu":"intel"}
```

`doctor --json` has a stable `format: 1`: fields are only ever added, never
renamed or removed, so integrations can rely on it. `doctor` recomputes
everything live.

Repair flags:

- `arxy doctor --fix` only **reports**; it changes nothing.
- `--fix --apply` (as root) applies non-destructive fixes.
- `--fix --apply --confirm` opens a tty to confirm the destructive ones.
- `--json` never applies anything; it just returns `fixes_available` and
  `fixes`.

The `nvidia-align`, `musl-glibc-stack` and `gpu-full-stack` fix types are
proposed only: applying those stays opt-in.

`version` lives inside the root, so `arxy version --verbose` reports the CLI
version, the image version, the level, GPU, size and Mesa hold. It also reads
`hardware.json` and warns if your kernel or NVIDIA driver changed since `setup`.
Refreshing that profile without a full `setup` is still pending.

## 7. Maintenance

- **dedup** hardlinks byte-identical files, under `/usr` only. It runs
  automatically after `install`/`update` when it saves at least 10 MB
  (`ARXY_NO_AUTO_DEDUP=1` disables that). Because `pacman` replaces files
  instead of rewriting them in place, links break cleanly on update without
  corrupting the host, and nothing outside `/usr` is ever linked.
- **rollback** restores the rootfs from the last `setup`; everything installed
  since is lost. Only one generation is kept, so a second `setup` replaces the
  original good copy.
- **clean --apply** purges caches (rootfs, AUR) and destroys the rollback point.
- **gc --json / --apply** reports bytes attributable to rollback, cache, build
  and staging leftovers, and purges with `--apply`.

## 8. Validation

- **Matrix across 5 distros** (Alpine, Chimera, Void, Ubuntu, privileged
  Ubuntu) in the sibling repo `arxy-image`: `tests/matrix.sh`. Assertions are
  on resulting content, not just exit codes (33–43 checks depending on level
  and flags). It covers the full Level 1 cycle (install, run, export, remove),
  Level 2 reads and AUR blocks, plus Level 2 writes forced with
  `MATRIX_WRITE2=1`. Shortcut export under Level 2 is hand-verified only. The
  matrix runs in CI on every base image build.
- **Real hardware** (Intel HD 630): `tests/test-hardware.sh` checks D-Bus on
  both levels, Iris GL acceleration, LLVM-less softpipe rendering and boots a
  real Electron app. `dbus-send` isn't in the mini image, so that test
  legitimately SKIPs until you `arxy install dbus`.
- **CLI suite**: `make test` (deterministic) and `make test-all` (needs an
  external environment), plus `make bridge && bash bridge/test-bridge.sh`.
  Contributor flow in [CONTRIBUTING.md](CONTRIBUTING.md), canonical gate in
  [AGENTS.md](AGENTS.md).