# Ubuntu / Pop!_OS CLI Installer

A self-contained Bash installer (`scripts/cli-installer/install-system`) that mirrors the Calamares module sequence (`scripts/calamares/settings.conf`) from a terminal.

Every ISO built by `scripts/build.sh` and `scripts/build-popos.sh` installs this script at `/usr/local/bin/install-system`.

## Usage on a Live ISO

Run from a TTY or terminal on the booted live media:

```bash
sudo install-system
```

To test a newer copy directly from a checkout:

```bash
chmod +x scripts/cli-installer/install-system
sudo ./scripts/cli-installer/install-system
```

At startup, choose between `whiptail`/`dialog` TUI boxes or plain text prompts.

## What It Configures

- **Locale & keyboard**: curated UTF-8 list synced with `scripts/calamares/i18n/SUPPORTED` and XKB layout configuration.
- **Timezone**: tries NTP via `timedatectl` when online, falls back offline.
- **Partitioning**:
  - *Erase disk*: GPT with 1 MiB `bios_grub` (`amd64` only) + 512 MiB FAT32 ESP + 4 GiB swap + ext4 root.
  - *Manual*: runs `cfdisk` and asks which partition to use if multiple candidates match.
- **Bootloader**: detects `amd64` vs `arm64` and Ubuntu (`--bootloader-id=ubuntu`) vs Pop!_OS (`--bootloader-id=pop`). Installs both UEFI (`x86_64-efi` / `arm64-efi`) and legacy BIOS (`i386-pc` on `amd64`).
- **Network**: writes Netplan config for NetworkManager if installed, or `systemd-networkd` DHCP otherwise.
- **Cleanup**: purges live-only packages (`calamares`, `casper`, etc.) when present and attempts online installation of locale language packs.

## Scope Limits

- **No LUKS encryption**: use Calamares on desktop ISOs if you need automated LUKS2 full-disk encryption.
- **No GeoIP / unattended mode**: every step asks on the TTY.
