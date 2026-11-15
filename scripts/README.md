# Build Scripts Reference

The eight entrypoints in `scripts/` source shared modules under `scripts/lib/`:

- `scripts/lib/ui.sh`: semantic CLI logging (`NO_COLOR` / `TERM=dumb` safe), `whiptail`/`dialog` TUI wrappers, storage estimation, and GNU `screen` session launcher.
- `scripts/lib/common.sh`: CLI/config parsing, release/arch/mirror resolution, cross-arch `qemu-user-static` handling, `debootstrap`, deb822 APT setup, desktop/browser stacks, Chaotic PPR Pacstall install, hooks, and Advanced mode lifecycle.
- `scripts/lib/popos.sh`: `apt.pop-os.org` repository setup with Ubuntu-safe scoped & negative `pop-os-release` pins (leaving `ubuntu.sources` and `base-files` untouched), Pop!_OS Plymouth/GRUB/GTK theming, COSMIC desktop variant (`--desktop=cosmic`), native Pop!_OS Firefox deb verification, `system76-driver` (`system76-ubuntu-repo`), and `/usr/local/bin/popos-migrate-branding` installation.
- `scripts/lib/iso.sh`: live ISO package installation (`desktop` and `cli` profiles), Calamares + `/usr/local/bin/install-system` packaging, Memtest86+ v9.00, `amd64` hybrid and `arm64` UEFI `xorriso` generation.
- `scripts/lib/disk-image.sh`: `cloud`, `vm`, and `removable` raw GPT `.img` assembly, NoCloud `growpart` seeding, first-boot console wizard, and `qemu-img` exports.

## Entrypoints

| Script | Distro | Mode | Default Config | Workspace Subdir |
| --- | --- | --- | --- | --- |
| `build.sh` | Ubuntu | ISO | `build.cfg` | `workspace` |
| `build-popos.sh` | Pop!_OS | ISO | `build-popos.cfg` | `workspace-popos` |
| `build-img.sh` | Ubuntu | Cloud `.img` | `build-img.cfg` | `workspace-img` |
| `build-popos-img.sh` | Pop!_OS | Cloud `.img` | `build-popos-img.cfg` | `workspace-popos-img` |
| `build-vm.sh` | Ubuntu | VM image | `build-vm.cfg` | `workspace-vm` |
| `build-popos-vm.sh` | Pop!_OS | VM image | `build-popos-vm.cfg` | `workspace-popos-vm` |
| `build-removable.sh` | Ubuntu | Removable `.img` | `build-removable.cfg` | `workspace-removable` |
| `build-popos-removable.sh` | Pop!_OS | Removable `.img` | `build-popos-removable.cfg` | `workspace-popos-removable` |

## Stage Execution Syntax

```bash
./build.sh [options] [start_cmd] [-] [end_cmd]
```

Host stages (`HOST_CMD`):
- ISO builders: `setup_host`, `debootstrap`, `run_chroot`, `build_iso`
- Disk image builders: `setup_host`, `debootstrap`, `run_chroot`, `build_disk_image`

Chroot sub-stages (`CHROOT_CMD`, invoked automatically via `--chroot-internal`):
- ISO builders: `chroot_prepare`, `install_pkg`, `build_image`, `finish_up`
- Disk image builders: `chroot_prepare`, `install_pkg`, `finish_up`

Examples:
- `./build.sh -`: run all stages (default)
- `./build.sh debootstrap`: run only `debootstrap`
- `./build.sh --advanced run_chroot - build_iso`: resume from `run_chroot` through `build_iso`

## Calamares and CLI Installer

- `calamares/` and `calamares-popos/` provide identical Calamares module flows (`settings.conf`, `modules/*.conf`, `i18n/SUPPORTED`, and distro `branding/`). Both exclude `ubiquity` and `"^live-*"` regex removals, and configure btrfs with `compress=zstd:1`.
- `cli-installer/install-system` is automatically installed to `/usr/local/bin/install-system` on every built ISO.
- `popos-migrate-branding` is installed to `/usr/local/bin/popos-migrate-branding` on every Pop!_OS ISO and disk image for post-upgrade Pop!_OS identity branding (and can also run standalone on plain Ubuntu).
