#!/bin/bash
# Live ISO build stages: install_pkg, build_image, build_iso, and help/summary.

HOST_CMD=(setup_host debootstrap run_chroot build_iso)
CHROOT_CMD=(chroot_prepare install_pkg build_image finish_up)

function default_target_package_remove() {
    if [[ "${TARGET_IMAGE_PROFILE:-desktop}" == "cli" || "${TARGET_INSTALLER:-calamares}" == "cli" ]]; then
        echo "casper discover laptop-detect os-prober"
    else
        echo "calamares casper discover laptop-detect os-prober"
    fi
}

function iso_check_settings() {
    local requested_installer="${TARGET_INSTALLER:-}"
    export TARGET_INSTALLER="${TARGET_INSTALLER:-calamares}"
    if [[ "${TARGET_IMAGE_PROFILE:-desktop}" == "cli" ]]; then
        export TARGET_INSTALLER="cli"
    elif [[ "${TARGET_DESKTOP:-gnome}" == "cosmic" ]]; then
        if [[ "$requested_installer" == "calamares" ]]; then
            ui_warn "COSMIC desktop ISO uses the CLI installer (install-system) and GRUB instead of Calamares."
        fi
        export TARGET_INSTALLER="cli"
    else
        case "${TARGET_INSTALLER}" in
            calamares) ;;
            ubiquity)
                ui_err "Ubiquity has been removed (jammy 22.04 support ended). Use calamares."
                exit 1
                ;;
            *)
                ui_err "TARGET_INSTALLER must be calamares (or cli when --profile=cli or --desktop=cosmic; got: '${TARGET_INSTALLER}')."
                exit 1
                ;;
        esac
    fi
    export TARGET_PACKAGE_REMOVE="${TARGET_PACKAGE_REMOVE:-$(default_target_package_remove)}"
}

function iso_host_help() {
    local desc="Ubuntu"
    [[ "$UVB_DISTRO" == "popos" ]] && desc="Pop!_OS"
    echo "$0 - Build a bootable ${desc} live ISO image (amd64 BIOS+UEFI hybrid, or arm64 UEFI)."
    echo
    echo "USAGE"
    echo "  $0 [options] [start_cmd] [-] [end_cmd]"
    echo
    echo "STAGE COMMANDS"
    echo "  setup_host   Install host build tools and prepare workspace"
    echo "  debootstrap  Bootstrap minimal rootfs (--arch=amd64|arm64)"
    echo "  run_chroot   Configure repos, kernel, desktop/CLI stack, Calamares + install-system"
    echo "  build_iso    Create SquashFS and bootable ISO with xorriso + SHA-1/SHA-256"
    echo "  Supported commands: ${HOST_CMD[*]}"
    echo
    print_common_help_options
    echo
    echo "ISO OPTIONS"
    printf '  %-38s %s\n' "--installer=calamares" "Calamares GUI installer (desktop profile; cosmic uses CLI installer)"
    printf '  %-38s %s\n' "GRUB_LIVEBOOT_LABEL=TEXT" "Live boot menu entry label"
    echo
    echo "OUTPUT"
    echo "  <output-dir>/<name>.iso (+ .sha1, .sha256)"
    echo "  Default <name>: $([[ "$UVB_DISTRO" == "popos" ]] && echo popos || echo ubuntu)-<ver>-<desktop|cli>-<arch>-<UTC-timestamp>"
    echo
    echo "EXAMPLES"
    echo "  $ $0 --release=noble --arch=amd64 --kernel=$([[ "$UVB_DISTRO" == "popos" ]] && echo system76 || echo generic) -"
    echo "  $ $0 --release=noble --profile=cli --network=networkd --kernel=generic -"
    echo "  $ $0 --advanced --config=scripts/$(default_config_filename) --no-interactive -"
}

function apply_calamares_custom_config() {
    echo "=====> installing Calamares configuration ..."
    if [[ ! -d /root/calamares-config ]] || [[ ! -f /root/calamares-config/settings.conf ]]; then
        >&2 echo "Internal error: Calamares config missing in /root/calamares-config."
        exit 1
    fi
    install -d /etc/calamares/modules
    cp -a /root/calamares-config/settings.conf /etc/calamares/settings.conf
    cp -a /root/calamares-config/modules/. /etc/calamares/modules/

    if [[ -f /root/calamares-config/i18n/SUPPORTED ]]; then
        install -d /usr/share/i18n
        if [[ -f /usr/share/i18n/SUPPORTED && ! -f /usr/share/i18n/SUPPORTED.stock-ubuntu-vanilla-backup ]]; then
            cp -a /usr/share/i18n/SUPPORTED /usr/share/i18n/SUPPORTED.stock-ubuntu-vanilla-backup
        fi
        cp /root/calamares-config/i18n/SUPPORTED /usr/share/i18n/SUPPORTED
    fi

    local brand_name="ubuntu"
    [[ "$UVB_DISTRO" == "popos" ]] && brand_name="pop"

    local distro_ver
    distro_ver="$(release_version "$TARGET_UBUNTU_VERSION")"
    if [[ -z "$distro_ver" ]]; then
        >&2 echo "Internal error: no version mapping for '${TARGET_UBUNTU_VERSION}'."
        exit 1
    fi
    if [[ ! -f "/root/calamares-config/branding/${brand_name}/branding.desc" ]]; then
        >&2 echo "Internal error: branding/${brand_name}/branding.desc is missing."
        exit 1
    fi
    install -d "/etc/calamares/branding/${brand_name}"
    cp -a "/root/calamares-config/branding/${brand_name}/." "/etc/calamares/branding/${brand_name}/"
    sed -e "s|@VERSION@|${distro_ver}|g" \
        -e "s|@CODENAME@|${TARGET_UBUNTU_VERSION}|g" \
        "/root/calamares-config/branding/${brand_name}/branding.desc" \
        > "/etc/calamares/branding/${brand_name}/branding.desc"
}

function install_cli_installer_into_live() {
    if [[ -f /root/install-system ]]; then
        echo "=====> installing CLI installer to /usr/local/bin/install-system"
        install -m 0755 /root/install-system /usr/local/bin/install-system
    else
        echo "  WARN  /root/install-system was not copied into chroot; skipping /usr/local/bin/install-system." >&2
    fi

    if [[ "${TARGET_IMAGE_PROFILE:-desktop}" == "cli" || "${TARGET_INSTALLER:-calamares}" == "cli" ]]; then
        install -d /etc/profile.d
        cat <<'EOF' > /etc/profile.d/99-uvb-live-cli.sh
if [ -f /cdrom/casper/filesystem.squashfs ] && grep -qw 'boot=casper' /proc/cmdline 2>/dev/null; then
    printf '\n  Live environment ready. To install to disk, run:\n'
    printf '    sudo install-system\n\n'
fi
EOF
    fi
}

function install_pkg() {
    echo "=====> running install_pkg (profile=${TARGET_IMAGE_PROFILE:-desktop}, arch=${TARGET_ARCH:-amd64}) ..."
    echo "=====> kernel metapackage: $TARGET_KERNEL_PACKAGE"
    apt-get -y upgrade

    local -a grub_pkgs=(grub-common grub2-common shim-signed)
    if [[ "${TARGET_ARCH:-amd64}" == "arm64" ]]; then
        grub_pkgs+=(grub-efi-arm64-bin grub-efi-arm64-signed)
    else
        grub_pkgs+=(grub-gfxpayload-lists grub-pc grub-pc-bin grub-efi-amd64-bin grub-efi-amd64-signed)
    fi

    local -a net_pkgs=(net-tools)
    if [[ "${TARGET_IMAGE_PROFILE:-desktop}" == "cli" ]]; then
        net_pkgs+=(netplan.io)
        if [[ "${TARGET_NETWORK_STACK:-networkd}" == "network-manager" ]]; then
            net_pkgs+=(network-manager)
        fi
    else
        net_pkgs+=(network-manager)
    fi

    local -a base_pkgs=(
        sudo
        ubuntu-standard
        casper
        discover
        laptop-detect
        os-prober
        locales
        whiptail
        gdisk
        mtools
        unzip
        binutils
        dosfstools
        e2fsprogs
        btrfs-progs
        xfsprogs
        ntfs-3g
        parted
        rsync
        squashfs-tools
    )
    if [[ "${TARGET_IMAGE_PROFILE:-desktop}" != "cli" ]]; then
        base_pkgs+=(gparted)
    fi

    apt-get install -y "${base_pkgs[@]}" "${net_pkgs[@]}" "${grub_pkgs[@]}"

    echo "=====> installing kernel metapackage: $TARGET_KERNEL_PACKAGE"
    apt-get install -y "$TARGET_KERNEL_PACKAGE"

    if [[ "${TARGET_IMAGE_PROFILE:-desktop}" == "cli" ]]; then
        echo "=====> CLI/TTY-only ISO: skipping Calamares GUI installer"
        if [[ "${TARGET_NETWORK_STACK:-networkd}" == "networkd" ]]; then
            install -d /etc/netplan
            cat <<'EOF' > /etc/netplan/01-dhcp-all.yaml
network:
  version: 2
  ethernets:
    all-ethernet:
      match:
        name: "en*"
      dhcp4: true
      dhcp6: true
EOF
            chmod 0600 /etc/netplan/01-dhcp-all.yaml
            systemctl enable systemd-networkd.service || true
        fi
    elif [[ "${TARGET_INSTALLER:-calamares}" == "cli" ]]; then
        echo "=====> desktop '${TARGET_DESKTOP:-}': skipping Calamares GUI installer (CLI install-system + GRUB)"
    else
        echo "=====> live installer: calamares"
        apt-get install -y --no-install-recommends calamares
        apply_calamares_custom_config
    fi

    install_cli_installer_into_live
    customize_image
    run_chroot_hooks

    if command -v update-initramfs >/dev/null 2>&1; then
        echo "=====> updating initramfs with live casper configuration ..."
        update-initramfs -u -k all || true
    fi

    apt-get autoremove -y
    configure_locale_and_keyboard
    configure_network_manager_conf
    apt-get clean -y
}

function _pick_efi_binary() {
    local cand
    for cand in "$@"; do
        if [[ -f "$cand" ]]; then
            echo "$cand"
            return 0
        fi
    done
    return 1
}

function build_image() {
    echo "=====> running build_image (arch=${TARGET_ARCH:-amd64}) ..."

    local arch="${TARGET_ARCH:-amd64}"
    rm -rf /image
    mkdir -p /image/{casper,boot/grub,install,EFI/boot,EFI/ubuntu}

    pushd /image >/dev/null || exit 1

    local vmlinuz_src initrd_src
    vmlinuz_src="$(find /boot -maxdepth 1 -name 'vmlinuz-*' -print 2>/dev/null | sort -V | tail -1 || true)"
    initrd_src="$(find /boot -maxdepth 1 -name 'initrd.img-*' -print 2>/dev/null | sort -V | tail -1 || true)"
    if [[ -z "${vmlinuz_src}" || ! -f "$vmlinuz_src" ]]; then
        >&2 echo "No /boot/vmlinuz-* found. Kernel install failed?"
        exit 1
    fi
    if [[ -z "${initrd_src}" || ! -f "$initrd_src" ]]; then
        >&2 echo "No /boot/initrd.img-* found. Kernel install failed?"
        exit 1
    fi
    cp "$vmlinuz_src" casper/vmlinuz
    cp "$initrd_src" casper/initrd

    # Memtest86+ v9.00 unified binary (supports x86_64 BIOS/UEFI and arm64 UEFI).
    local _memtest_url="https://memtest.org/download/v9.00/mt86plus_9.00.binaries.zip"
    local _memtest_sha256="7b2e294c5f30ddc8a01bbfce0dba7370765a867b745e0494ff811de4463eeb5d"
    wget --progress=dot "$_memtest_url" -O install/memtest86.zip
    echo "${_memtest_sha256}  install/memtest86.zip" | sha256sum -c - || {
        >&2 echo "ERROR: Memtest86+ v9.00 archive checksum mismatch."
        rm -f install/memtest86.zip
        exit 1
    }
    if [[ "$arch" == "arm64" ]]; then
        unzip -p install/memtest86.zip mt86p_900_arm64 > install/memtest86+.efi
    else
        unzip -p install/memtest86.zip mt86p_900_x86_64 > install/memtest86+.bin
    fi
    rm -f install/memtest86.zip

    local iso_marker="ubuntu"
    [[ "$UVB_DISTRO" == "popos" ]] && iso_marker="popos"
    touch "$iso_marker"

    local pop_grub_theme_copied=0
    if [[ "$UVB_DISTRO" == "popos" ]]; then
        if [[ -f /boot/grub/themes/pop/theme.txt ]]; then
            install -d boot/grub/themes
            cp -a /boot/grub/themes/pop boot/grub/themes/pop
            pop_grub_theme_copied=1
        elif [[ -f /usr/share/grub/themes/pop/theme.txt ]]; then
            install -d boot/grub/themes
            cp -a /usr/share/grub/themes/pop boot/grub/themes/pop
            pop_grub_theme_copied=1
        fi
    fi

    if [[ "$UVB_DISTRO" == "popos" && "$pop_grub_theme_copied" -eq 1 ]]; then
        local live_entry_header="menuentry \"$GRUB_LIVEBOOT_LABEL\" --class pop-os --class gnu-linux --class os {"
        if [[ "$arch" == "arm64" ]]; then
            cat <<EOF > boot/grub/grub.cfg
search --set=root --file /${iso_marker}

insmod all_video
insmod font
insmod linux
if loadfont /boot/grub/themes/pop/font.pf2 ; then
    set gfxmode=auto
    set gfxpayload=keep
    insmod gfxterm
    terminal_output gfxterm
fi
insmod gfxmenu
insmod png
if [ -f /boot/grub/themes/pop/theme.txt ]; then
    set theme=/boot/grub/themes/pop/theme.txt
    export theme
fi

set default="0"
set timeout=30

${live_entry_header}
    linux /casper/vmlinuz boot=casper nopersistent quiet splash ---
    initrd /casper/initrd
}

menuentry "Check the disc for defects" {
    linux /casper/vmlinuz boot=casper integrity-check quiet splash ---
    initrd /casper/initrd
}

menuentry "UEFI firmware settings" {
    fwsetup
}

menuentry "Test memory with Memtest86+ (UEFI ARM64)" {
    linux /install/memtest86+.efi
}
EOF
        else
            cat <<EOF > boot/grub/grub.cfg
search --set=root --file /${iso_marker}

insmod all_video
insmod font
insmod linux
if loadfont /boot/grub/themes/pop/font.pf2 ; then
    set gfxmode=auto
    set gfxpayload=keep
    insmod gfxterm
    terminal_output gfxterm
fi
insmod gfxmenu
insmod png
if [ -f /boot/grub/themes/pop/theme.txt ]; then
    set theme=/boot/grub/themes/pop/theme.txt
    export theme
fi

set default="0"
set timeout=30

${live_entry_header}
    linux /casper/vmlinuz boot=casper nopersistent quiet splash ---
    initrd /casper/initrd
}

menuentry "Check the disc for defects" {
    linux /casper/vmlinuz boot=casper integrity-check quiet splash ---
    initrd /casper/initrd
}

if [ "\$grub_platform" = "efi" ]; then
menuentry "UEFI firmware settings" {
    fwsetup
}

menuentry "Test memory with Memtest86+ (UEFI)" {
    linux /install/memtest86+.bin
}
else
menuentry "Test memory with Memtest86+ (BIOS)" {
    linux /install/memtest86+.bin
}
fi
EOF
        fi
    elif [[ "$arch" == "arm64" ]]; then
        local live_mac_args=""
        if [[ "$UVB_DISTRO" == "ubuntu" && "${TARGET_SECURITY:-apparmor}" == "selinux" ]]; then
            live_mac_args=" apparmor=0 security=selinux noautorelabel"
        fi
        cat <<EOF > boot/grub/grub.cfg
search --set=root --file /${iso_marker}

insmod all_video
insmod linux

set default="0"
set timeout=30

menuentry "$GRUB_LIVEBOOT_LABEL" {
    linux /casper/vmlinuz boot=casper nopersistent${live_mac_args} quiet splash ---
    initrd /casper/initrd
}

menuentry "Check the disc for defects" {
    linux /casper/vmlinuz boot=casper integrity-check${live_mac_args} quiet splash ---
    initrd /casper/initrd
}

menuentry "UEFI firmware settings" {
    fwsetup
}

menuentry "Test memory with Memtest86+ (UEFI ARM64)" {
    linux /install/memtest86+.efi
}
EOF
    else
        local live_mac_args=""
        if [[ "$UVB_DISTRO" == "ubuntu" && "${TARGET_SECURITY:-apparmor}" == "selinux" ]]; then
            live_mac_args=" apparmor=0 security=selinux noautorelabel"
        fi
        cat <<EOF > boot/grub/grub.cfg
search --set=root --file /${iso_marker}

insmod all_video
insmod linux

set default="0"
set timeout=30

menuentry "$GRUB_LIVEBOOT_LABEL" {
    linux /casper/vmlinuz boot=casper nopersistent${live_mac_args} quiet splash ---
    initrd /casper/initrd
}

menuentry "Check the disc for defects" {
    linux /casper/vmlinuz boot=casper integrity-check${live_mac_args} quiet splash ---
    initrd /casper/initrd
}

if [ "\$grub_platform" = "efi" ]; then
menuentry "UEFI firmware settings" {
    fwsetup
}

menuentry "Test memory with Memtest86+ (UEFI)" {
    linux /install/memtest86+.bin
}
else
menuentry "Test memory with Memtest86+ (BIOS)" {
    linux /install/memtest86+.bin
}
fi
EOF
    fi

    dpkg-query -W --showformat='${Package} ${Version}\n' | tee casper/filesystem.manifest >/dev/null
    cp -v casper/filesystem.manifest casper/filesystem.manifest-desktop

    local pkg pkg_re
    for pkg in $TARGET_PACKAGE_REMOVE; do
        pkg_re="$(printf '%s' "$pkg" | sed 's/[][\\.*^$/]/\\&/g')"
        sed -i "/^${pkg_re} /d" casper/filesystem.manifest-desktop
    done

    cat <<EOF > README.diskdefines
#define DISKNAME  ${GRUB_LIVEBOOT_LABEL}
#define TYPE  binary
#define TYPEbinary  1
#define ARCH  ${arch}
#define ARCH${arch}  1
#define DISKNUM  1
#define DISKNUM1  1
#define TOTALNUM  0
#define TOTALNUM0  1
EOF

    local shim_bin mm_bin grub_bin efi_boot_name efi_mm_name efi_grub_name
    if [[ "$arch" == "arm64" ]]; then
        shim_bin="$(_pick_efi_binary /usr/lib/shim/shimaa64.efi.signed.previous /usr/lib/shim/shimaa64.efi.dualsigned /usr/lib/shim/shimaa64.efi.signed.latest)" || {
            >&2 echo "ERROR: Missing signed arm64 shim EFI binary under /usr/lib/shim/."
            exit 1
        }
        mm_bin="/usr/lib/shim/mmaa64.efi"
        grub_bin="/usr/lib/grub/arm64-efi-signed/grubaa64.efi.signed"
        efi_boot_name="bootaa64.efi"
        efi_mm_name="mmaa64.efi"
        efi_grub_name="grubaa64.efi"
    else
        shim_bin="$(_pick_efi_binary /usr/lib/shim/shimx64.efi.signed.previous /usr/lib/shim/shimx64.efi.dualsigned /usr/lib/shim/shimx64.efi.signed.latest)" || {
            >&2 echo "ERROR: Missing signed amd64 shim EFI binary under /usr/lib/shim/."
            exit 1
        }
        mm_bin="/usr/lib/shim/mmx64.efi"
        grub_bin="/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed"
        efi_boot_name="bootx64.efi"
        efi_mm_name="mmx64.efi"
        efi_grub_name="grubx64.efi"
    fi

    for _efi_src in "$shim_bin" "$mm_bin" "$grub_bin"; do
        if [[ ! -f "$_efi_src" ]]; then
            >&2 echo "ERROR: Required EFI binary '$_efi_src' not found."
            exit 1
        fi
    done

    # Signed Secure Boot grub*.efi binaries hardcode /EFI/ubuntu as their config prefix.
    cp "$shim_bin" "EFI/boot/${efi_boot_name}"
    cp "$mm_bin"   "EFI/boot/${efi_mm_name}"
    cp "$grub_bin" "EFI/boot/${efi_grub_name}"
    cp boot/grub/grub.cfg EFI/ubuntu/grub.cfg

    (
        cd boot/grub || exit 1
        dd if=/dev/zero of=efiboot.img bs=1M count=10
        mkfs.vfat -F 16 efiboot.img
        LC_CTYPE=C mmd -i efiboot.img efi efi/ubuntu efi/boot
        LC_CTYPE=C mcopy -i efiboot.img "../../EFI/boot/${efi_boot_name}" "::efi/boot/${efi_boot_name}"
        LC_CTYPE=C mcopy -i efiboot.img "../../EFI/boot/${efi_mm_name}"   "::efi/boot/${efi_mm_name}"
        LC_CTYPE=C mcopy -i efiboot.img "../../EFI/boot/${efi_grub_name}" "::efi/boot/${efi_grub_name}"
        LC_CTYPE=C mcopy -i efiboot.img ./grub.cfg ::efi/ubuntu/grub.cfg
    )

    if [[ "$arch" == "amd64" ]]; then
        local bios_install_modules="linux16 linux normal iso9660 biosdisk memdisk search tar ls"
        if [[ "$UVB_DISTRO" == "popos" && "$pop_grub_theme_copied" -eq 1 ]]; then
            bios_install_modules="linux16 linux normal iso9660 biosdisk memdisk search tar ls all_video vbe vga video_bochs video_cirrus video video_fb video_colors font gfxterm gfxterm_background gfxmenu bitmap bitmap_scale png trig test echo terminal bufio"
        fi
        grub-mkstandalone \
            --format=i386-pc \
            --output=boot/grub/core.img \
            --install-modules="$bios_install_modules" \
            --modules="linux16 linux normal iso9660 biosdisk search" \
            --locales="" \
            --fonts="" \
            "boot/grub/grub.cfg=boot/grub/grub.cfg"
        cat /usr/lib/grub/i386-pc/cdboot.img boot/grub/core.img > boot/grub/bios.img
    fi

    find . -type f -print0 \
        | xargs -0 md5sum \
        | grep -v -e 'boot/grub/efiboot.img' -e 'boot/grub/bios.img' -e 'md5sum.txt' \
        > md5sum.txt

    popd >/dev/null || exit 1
}

function write_iso_hashes() {
    echo "=====> writing SHA-1 and SHA-256 ..."
    (
        cd "$OUTPUT_DIR" || exit 1
        sha1sum "$TARGET_NAME.iso" | host_priv tee "$TARGET_NAME.iso.sha1" >/dev/null
        sha256sum "$TARGET_NAME.iso" | host_priv tee "$TARGET_NAME.iso.sha256" >/dev/null
    )
}

function fix_iso_output_ownership() {
    local owner=""
    if [[ "$(id -u)" -eq 0 ]]; then
        [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] && owner="$SUDO_USER"
    else
        owner="$(id -un)"
    fi
    [[ -z "$owner" ]] && return 0
    local f
    for f in "$OUTPUT_DIR/$TARGET_NAME.iso" \
             "$OUTPUT_DIR/$TARGET_NAME.iso.sha1" \
             "$OUTPUT_DIR/$TARGET_NAME.iso.sha256"; do
        [[ -e "$f" ]] && host_priv chown "$owner" "$f" 2>/dev/null || true
    done
}

function build_iso() {
    echo "=====> running build_iso (arch=${TARGET_ARCH:-amd64}) ..."

    local arch="${TARGET_ARCH:-amd64}"
    ensure_workspace_root
    host_priv rm -rf "$WORKSPACE_IMAGE"
    if [[ ! -d "$WORKSPACE_CHROOT/image" ]]; then
        >&2 echo "ERROR: Missing $WORKSPACE_CHROOT/image. Re-run build_image (or run_chroot) first."
        exit 1
    fi
    # Copy instead of mv so re-running build_iso in advanced mode stays idempotent.
    host_priv cp -a "$WORKSPACE_CHROOT/image" "$WORKSPACE_IMAGE"

    host_priv mksquashfs "$WORKSPACE_CHROOT" "$WORKSPACE_IMAGE/casper/filesystem.squashfs" \
        -noappend -no-duplicates -no-recovery \
        -wildcards \
        -comp xz -b 1M -Xdict-size 100% \
        -e "var/cache/apt/archives/*" \
        -e "root/*" \
        -e "root/.*" \
        -e "tmp/*" \
        -e "tmp/.*" \
        -e "swapfile" \
        -e "image"

    printf "%s" "$(host_priv du -sx --block-size=1 \
        --exclude="$WORKSPACE_CHROOT/root" \
        --exclude="$WORKSPACE_CHROOT/tmp" \
        --exclude="$WORKSPACE_CHROOT/var/cache/apt/archives" \
        --exclude="$WORKSPACE_CHROOT/swapfile" \
        "$WORKSPACE_CHROOT" | cut -f1)" | host_priv tee "$WORKSPACE_IMAGE/casper/filesystem.size" >/dev/null

    if [[ ! -f "$WORKSPACE_IMAGE/boot/grub/efiboot.img" ]]; then
        >&2 echo "Missing $WORKSPACE_IMAGE/boot/grub/efiboot.img. Aborting."
        exit 1
    fi

    local iso_volid
    iso_volid="$(printf '%s' "$TARGET_NAME" \
        | tr '[:lower:]' '[:upper:]' \
        | tr -c 'A-Z0-9_' '_' \
        | cut -c1-32)"

    ensure_output_dir
    pushd "$WORKSPACE_IMAGE" >/dev/null || exit 1

    local esp_type_guid="28732ac11ff8d211ba4b00a0c93ec93b"
    local iso_mbr_type_guid="a2a0d0ebe5b9334487c068b6b72699c7"

    if [[ "$arch" == "arm64" ]]; then
        host_priv xorriso \
            -as mkisofs \
            -r -V "$iso_volid" \
            -J -joliet-long \
            -l \
            -iso-level 3 \
            -full-iso9660-filenames \
            -o "$OUTPUT_DIR/$TARGET_NAME.iso" \
            -partition_offset 16 \
            -append_partition 2 "$esp_type_guid" boot/grub/efiboot.img \
            -appended_part_as_gpt \
            -iso_mbr_part_type "$iso_mbr_type_guid" \
            -e '--interval:appended_partition_2:all::' \
            -no-emul-boot \
            .
    else
        local boot_hybrid_img="$WORKSPACE_CHROOT/usr/lib/grub/i386-pc/boot_hybrid.img"
        if [[ ! -f "$boot_hybrid_img" ]]; then
            >&2 echo "Missing $boot_hybrid_img. Cannot build hybrid BIOS/UEFI ISO."
            exit 1
        fi
        if [[ ! -f "$WORKSPACE_IMAGE/boot/grub/bios.img" ]]; then
            >&2 echo "Missing $WORKSPACE_IMAGE/boot/grub/bios.img. Aborting."
            exit 1
        fi
        host_priv xorriso \
            -as mkisofs \
            -r -V "$iso_volid" \
            -J -joliet-long \
            -l \
            -iso-level 3 \
            -full-iso9660-filenames \
            -o "$OUTPUT_DIR/$TARGET_NAME.iso" \
            --grub2-mbr "$boot_hybrid_img" \
            -partition_offset 16 \
            --mbr-force-bootable \
            -append_partition 2 "$esp_type_guid" boot/grub/efiboot.img \
            -appended_part_as_gpt \
            -iso_mbr_part_type "$iso_mbr_type_guid" \
            -c boot.catalog \
            -b boot/grub/bios.img \
                -no-emul-boot \
                -boot-load-size 4 \
                -boot-info-table \
                --grub2-boot-info \
            -eltorito-alt-boot \
            -e '--interval:appended_partition_2:all::' \
                -no-emul-boot \
            .
    fi

    popd >/dev/null || exit 1

    write_iso_hashes
    fix_iso_output_ownership
    clean_workspace
}

function iso_print_build_result() {
    local iso_path="${OUTPUT_DIR:-?}/${TARGET_NAME:-image}.iso"
    if [[ ! -f "$iso_path" ]]; then
        ui_heading "Build finished"
        ui_info "No ISO produced at $iso_path (this is expected for partial runs)."
        return 0
    fi
    local size=""
    size="$(du -h --apparent-size "$iso_path" 2>/dev/null | awk '{print $1}')"

    ui_heading "Build complete"
    ui_kv "ISO"    "$iso_path"
    ui_kv "Size"   "${size:-unknown}"
    [[ -f "$iso_path.sha1" ]]   && ui_kv "SHA1"   "$(awk '{print $1}' "$iso_path.sha1")"
    [[ -f "$iso_path.sha256" ]] && ui_kv "SHA256" "$(awk '{print $1}' "$iso_path.sha256")"
    echo
    echo "  Next steps:"
    echo "    Write the ISO to a USB stick (dd / Ventoy / Rufus / balenaEtcher) or boot"
    echo "    it in a VM. Every ISO includes /usr/local/bin/install-system for TTY installs."
    if [[ "${TARGET_IMAGE_PROFILE:-desktop}" == "cli" ]]; then
        echo "    CLI/TTY-only ISO: boots to a live TTY console; run 'sudo install-system'."
    elif [[ "${TARGET_INSTALLER:-calamares}" == "cli" ]]; then
        echo "    Desktop uses CLI installer: open a terminal and run 'sudo install-system'."
    fi
    if [[ "$UVB_DISTRO" == "ubuntu" && "${TARGET_SECURITY:-apparmor}" == "selinux" ]]; then
        echo "    SELinux enabled: installed system auto-relabels on first boot (permissive);"
        echo "    switch to enforcing afterward with 'sudo selinux-config-enforcing'."
    fi
    echo
    if declare -F popos_print_cosmic_note >/dev/null 2>&1; then
        popos_print_cosmic_note
    fi
}
