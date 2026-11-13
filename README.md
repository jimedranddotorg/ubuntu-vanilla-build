# Ubuntu Vanilla ISO & Image Builder (No Snap)

Build bootable Ubuntu or Pop!_OS live ISOs and ready-to-boot disk images from a minimal `debootstrap` base, with `snapd` and Snap store plugins blocked by APT pinning (`Pin-Priority: -1`).

> [!NOTE]
> This project is part of jimedrand.org, an independent open-source effort maintained by [jimed-rand](https://github.com/jimed-rand) and contributors.

---

## Output Targets

Eight builder scripts under `scripts/` share common modules in `scripts/lib/`. Launch any script directly or run `./start-here.sh` from the repository root:

| Output | Ubuntu Builder | Pop!_OS Builder | Notes |
| --- | --- | --- | --- |
| Live ISO | `scripts/build.sh` | `scripts/build-popos.sh` | Hybrid BIOS+UEFI (`amd64`) or UEFI (`arm64`); includes Calamares (desktop) and `/usr/local/bin/install-system` |
| Cloud disk `.img` | `scripts/build-img.sh` | `scripts/build-popos-img.sh` | Raw GPT disk image with `cloud-init`, `growpart`, and serial console |
| VM disk image | `scripts/build-vm.sh` | `scripts/build-popos-vm.sh` | Raw `.img` plus QCOW2, VDI, VMDK, and VHDX exports via `qemu-img` |
| Removable disk `.img` | `scripts/build-removable.sh` | `scripts/build-popos-removable.sh` | Ready to flash onto USB/SD/CF media; NoCloud `growpart` root resize |

Every artifact is written with `.sha1` and `.sha256` checksum files, named `${TARGET_NAME:-<distro>-<version>-<desktop|cli>[-<kind>]-<arch>-<yymmdd-hhmmss>}` in your home directory (override with `UVB_OUTPUT_DIR`).

---

## Supported Releases and Architectures

### Releases

| Codename | Version | Ubuntu Support | Pop!_OS Support | Kernel Metapackage Suffix |
| --- | --- | --- | --- | --- |
| `noble` | 24.04 LTS | Yes | Yes | `-hwe-24.04` |
| `resolute` | 26.04 LTS | Yes | Yes | `-hwe-26.04` |
| `devel` | Rolling dev | Yes | No | none (`linux-generic` / `linux-lowlatency`) |

`jammy` (22.04 LTS) and Ubiquity have been removed. Passing `--release=jammy` or `--installer=ubiquity` exits with an error.

### Architectures (`--arch=amd64|arm64`)

Interactive builds ask for the CPU architecture right after the release choice (defaulting to the host's native architecture):

- **`amd64`**: Builds with `archive.ubuntu.com` (or `apt.pop-os.org/ubuntu` for Pop!_OS). Supports hybrid BIOS+UEFI or UEFI-only firmware. On `arm64` hosts (including Apple Silicon Macs), cross-building `amd64` uses QEMU user emulation (`qemu-x86_64-static`).
- **`arm64`**: Uses `ports.ubuntu.com/ubuntu-ports/` for the Ubuntu base (including Pop!_OS `arm64`, since `apt.pop-os.org/ubuntu` publishes `amd64` only while Pop!_OS `release`/`proprietary`/`release-ubuntu` publish `arm64`). ARM64 builds are **UEFI-only** (`--firmware=hybrid` is rejected). On `amd64` hosts (including Intel Macs), cross-building `arm64` uses QEMU user emulation (`qemu-aarch64-static`).

---

## Quick Start

### Requirements
- **Linux**: Ubuntu 24.04+ or Debian 12+ (Debian hosts need `ubuntu-archive-keyring`).
- **macOS (Intel `x86_64` & Apple Silicon `arm64`)**: Run `./start-here.sh` with [OrbStack](https://orbstack.dev/), Docker Desktop, [Colima](https://github.com/abiosoft/colima), or [Lima](https://lima-vm.io/) installed. `start-here.sh` automatically launches a privileged native-architecture Linux container/VM (`linux/amd64` on Intel Macs, `linux/arm64` on Apple Silicon Macs), keeps the chroot workspace on a Linux volume, uses QEMU user emulation for cross-architecture builds, and writes finished artifacts to `~/ubuntu-vanilla-build-out` (or `UVB_OUTPUT_DIR`).
- **Disk space**: At least 20 GB free for an ISO build, or `20 GB + disk size` for disk images. Concurrent multi-build via GNU `screen` requires at least `2x` that free space.
- **Privileges**: `sudo` access on Linux (or run as `root`).

### Run interactively
```bash
./start-here.sh
```

`start-here.sh` asks for the interface mode (clean CLI prompts or `whiptail`/`dialog` TUI), checks available disk space, optionally queues multiple builds in detached GNU `screen` sessions when free space is at least `2x` the single-build requirement, installs missing host dependencies, and invokes the selected builder.

### Build in GitHub Actions
Trigger **Actions -> Build Ubuntu / Pop!_OS Image** (`.github/workflows/build-image.yml`) via `workflow_dispatch` to select distro, output artifact, release, architecture (`ubuntu-24.04` for `amd64`, native `ubuntu-24.04-arm` for `arm64`), desktop, kernel, browsers, and disk options from a form. Built images and checksums are uploaded directly as workflow artifacts.

To invoke a builder directly:
```bash
cd scripts/
./build.sh -                  # Ubuntu ISO
./build-popos.sh -            # Pop!_OS ISO
./build-vm.sh -               # Ubuntu VM image
./build-removable.sh -        # Ubuntu USB/SD raw image
```

---

## Profiles, Desktops, and Packages

### Profiles (`--profile=desktop|cli`)
- **`desktop`** (default): Installs a desktop environment, Plymouth, Flatpak + Flathub, vendor browser APT repositories, and Calamares (for ISOs).
- **`cli`**: Installs a text-console system with `netplan.io` + `systemd-networkd` (or NetworkManager via `--network=network-manager`), no display server, no GUI browsers or browser repos, and no Calamares. CLI ISOs boot to TTY1 and include `/usr/local/bin/install-system` for installing to disk.

### Desktop choices
- `gnome` (`vanilla-gnome-desktop` + `gnome-console`; `--no-install-recommends` by default, or enable recommends via prompt/`TARGET_GNOME_INSTALL_RECOMMENDS=1`; includes `gnome-software-plugin-flatpak`)
- `xfce` (Xubuntu-equivalent functional stack without `xubuntu-*` branding, `lightdm` + `slick-greeter`, `pipewire-pulse` + `wireplumber`, `labwc`)
- `kde-plasma` (`kde-standard`, `kde-plasma-desktop`, or `kde-full` via `--kde=`; SDDM pinned to Breeze; Discover Flatpak backend)
- `mate` (`mate-desktop-environment` or `mate-desktop-environment-core` via `--mate=full|core`, optional `--mate-extras`; `lightdm` + `slick-greeter`)
- `cinnamon`, `budgie`, `lxde` (`lightdm` + `slick-greeter`)
- `lxqt` (`lxqt` + `sddm` + `xorg`)

### Browsers, Pacstall, and Optional Tools
- **Browser APT sources** (desktop profile):
  - Brave (`brave-browser-release.sources`, `--brave=none|release|origin`, default `release`)
  - LibreWolf (`repo.librewolf.net` `.list`, `--librewolf` / `--no-librewolf`)
  - Mozilla Firefox (`packages.mozilla.org` deb822 `.sources` + `ppa:mozillateam/ppa`, `--firefox`, `--firefox-esr`, `--thunderbird`)
  - Pop!_OS native Firefox deb (`--firefox-popos` on Pop!_OS builders; verified from `apt.pop-os.org`, >10 MB, no `snapd` dependency)
- **Pacstall**: Installed by default (`--no-pacstall` to skip) by adding the Chaotic PPR APT repository (`https://pacstall.dev/q/ppr`) and installing `pacstall` via `apt-get`.
- **Optional pre-installs** (default off unless cloud image): `--fwupd`, `--openssh-server` (regenerates unique host keys on first boot), `--cockpit` (from `-backports`), `--ubuntu-studio` (desktop only), and `--system76-driver` (Pop!_OS only).

---

## Pop!_OS Notes

- Repositories come from `https://apt.pop-os.org/` (`release`, `proprietary`, `release-ubuntu`; `apt-origin.pop-os.org` fallback per suite; staging excluded).
- Only `base-files`, `pop-*`, `linux-system76*`, and `system76-*` are pinned (`o=pop-os-release`, priority 1001) so standard Ubuntu desktop metapackages still resolve without dependency conflicts.
- `linux-system76` (`--kernel=system76`, default on `amd64`) is `amd64`-only; `arm64` Pop!_OS builds use Ubuntu HWE `generic` or `lowlatency`.
- **`pop-desktop` and COSMIC are intentionally excluded** due to Calamares bugs. On `noble` and `resolute` Pop!_OS builds, install COSMIC after booting the installed system:
  ```bash
  sudo apt update
  sudo apt install cosmic-session
  ```

---

## CLI Installer (`/usr/local/bin/install-system`)

Every ISO ships `scripts/cli-installer/install-system` at `/usr/local/bin/install-system`. It runs interactively on a TTY (either `whiptail`/`dialog` boxes or plain text prompts) and follows the Calamares module sequence in `scripts/calamares/settings.conf`:

1. Welcome & UI selection
2. Locale (`scripts/calamares/i18n/SUPPORTED` UTF-8 list) & keyboard layout
3. Timezone (attempts NTP sync via `timedatectl`, falls back offline)
4. Disk partitioning:
   - **Erase disk**: GPT with 1 MiB `bios_grub` (`amd64` only) + 512 MiB ESP + 4 GiB swap + ext4 root
   - **Manual**: launches `cfdisk` and lets you select partitions when multiple exist
5. User account & hostname
6. Unpack `/cdrom/casper/filesystem.squashfs`, configure `fstab`, locale, initramfs, GRUB (`x86_64-efi` + `i386-pc` on `amd64`; `arm64-efi` on `arm64`; `--bootloader-id=pop` on Pop!_OS), strip live packages, reboot.

LUKS encryption is not included in `install-system`; use Calamares on desktop ISOs if you want automated LUKS2 partitioning. See [scripts/cli-installer/README.md](scripts/cli-installer/README.md).

---

## Interface, GNU `screen`, and Advanced Mode

### UI and Logs
- `--ui=cli|tui`: Choose clean ANSI terminal prompts (default) or `whiptail`/`dialog` TUI menus.
- `--no-color` (or `NO_COLOR=1`): Disable all ANSI colors (auto-disabled when not on a TTY or `TERM=dumb`).

### GNU `screen` and Multi-Build
- Pass `--screen` to detach a single build into a GNU `screen` session (logs to `~/uvb-logs/`).
- Pass `--multi-build` to `start-here.sh` (or pick multi-build interactively) to queue multiple builds in parallel `screen` sessions with isolated workspaces and APT caches. Multi-build is enabled only when free disk space is at least `2x` the single-build requirement; otherwise only a single detached `screen` session or foreground run is offered.

### Advanced Mode (`--advanced`)
`--advanced` (or `ADVANCED_MODE=1`) enables:
1. **Config files**: Auto-loads `scripts/build*.cfg` or `--config=FILE` (see `scripts/build.cfg.example`), or generate one with `--generate-config`.
2. **Workspace preservation**: Keeps `<workspace>` intact on failure or Ctrl+C so individual stages (`setup_host`, `debootstrap`, `run_chroot`, `build_iso`, `build_disk_image`) can be re-run without re-bootstrapping.
3. **Persistent APT cache**: Bind-mounts `~/.cache/ubuntu-vanilla-build/apt-cache` (or `popos-vanilla-build`) into the chroot.
4. **Unattended builds**: `--no-interactive` combined with `--locale` and `--keyboard-layout`.

Configuration precedence: **CLI flags > config file > environment variables > interactive prompts > defaults**.

---

## Build Hooks (Modloader)

Place executable `*.sh` scripts in `scripts/hooks/pre-chroot/` (runs on host after `debootstrap` with `WORKSPACE_CHROOT`) or `scripts/hooks/chroot/` (runs inside chroot after `customize_image`). Scripts run in sorted filename order and receive all `TARGET_*` variables. Override the directory with `--hooks-dir=PATH`. See [scripts/hooks/README.md](scripts/hooks/README.md).

---

## Common CLI Examples

```bash
# Ubuntu 24.04 GNOME ISO (amd64)
./scripts/build.sh --release=noble --arch=amd64 --kernel=generic -

# Ubuntu rolling devel CLI-only ISO (arm64) using TUI
./scripts/build.sh --release=devel --arch=arm64 --profile=cli --kernel=generic --ui=tui -

# Pop!_OS 26.04 XFCE VM image with native Pop Firefox and QCOW2+VDI exports
./scripts/build-popos-vm.sh --release=resolute --arch=amd64 --kernel=system76 \
    --desktop=xfce --firefox-popos --formats=qcow2,vdi -

# Ubuntu 24.04 removable USB image (16 GB, hybrid BIOS+UEFI, baked user)
./scripts/build-removable.sh --release=noble --arch=amd64 --kernel=generic \
    --firmware=hybrid --disk-size=16 --user-mode=build --username=alice --password='secret' -

# Unattended build from config inside GNU screen
./scripts/build.sh --advanced --config=scripts/build.cfg --no-interactive --screen -
```

---

## Verification

Verify generated checksums and test boot images in QEMU:

```bash
sha256sum -c <artifact>.sha256
qemu-system-x86_64 -cdrom <ubuntu.iso> -m 4096 -enable-kvm
```

---

## License

Licensed under **GNU General Public License v2.0**. See `LICENSE`.
