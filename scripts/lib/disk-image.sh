#!/bin/bash
# Disk image builders (cloud, vm, removable) shared across Ubuntu & Pop!_OS.

HOST_CMD=(setup_host debootstrap run_chroot build_disk_image)
CHROOT_CMD=(chroot_prepare install_pkg finish_up)

OUTPUT_FILES=()
IMG_LOOP_DEV=""
IMG_MOUNT_DIR=""

function disk_image_default_size_gb() {
    if [[ "$UVB_IMAGE_KIND" == "removable" ]]; then
        echo 16
    else
        echo 32
    fi
}

function disk_image_min_size_gb() {
    if [[ "$UVB_IMAGE_KIND" == "removable" ]]; then
        echo 8
    else
        echo 10
    fi
}

function disk_image_default_firmware() {
    if [[ "${TARGET_ARCH:-amd64}" == "arm64" ]]; then
        echo "uefi"
    elif [[ "$UVB_IMAGE_KIND" == "removable" ]]; then
        echo "hybrid"
    else
        echo "uefi"
    fi
}

function disk_image_host_help() {
    local distro_name="Ubuntu"
    [[ "$UVB_DISTRO" == "popos" ]] && distro_name="Pop!_OS"
    local kind_desc="cloud disk image (.img, cloud-init)"
    case "$UVB_IMAGE_KIND" in
        vm)        kind_desc="VM disk image (.img + QCOW2/VDI/VMDK/VHDX exports)" ;;
        removable) kind_desc="removable-media disk image (.img for USB/SD/CF)" ;;
    esac

    echo "$0 - Build a ready-to-use ${distro_name} ${kind_desc}."
    echo
    echo "USAGE"
    echo "  $0 [options] [start_cmd] [-] [end_cmd]"
    echo
    echo "STAGE COMMANDS"
    echo "  setup_host        Install host build tools and prepare workspace"
    echo "  debootstrap       Bootstrap minimal rootfs (--arch=amd64|arm64)"
    echo "  run_chroot        Configure repos, kernel, desktop/CLI stack, hooks"
    echo "  build_disk_image  Create GPT disk image, install GRUB, export artifacts"
    echo "  Supported commands: ${HOST_CMD[*]}"
    echo
    print_common_help_options
    local def_fw def_sz min_sz
    def_fw="$(disk_image_default_firmware)"
    def_sz="$(disk_image_default_size_gb)"
    min_sz="$(disk_image_min_size_gb)"
    echo
    echo "DISK IMAGE OPTIONS"
    printf '  %-38s %s\n' "--firmware=uefi|hybrid" "Boot firmware (default: ${def_fw}; arm64 is uefi-only)"
    printf '  %-38s %s\n' "--alloc-tool=truncate|fallocate|dd" "Raw .img allocation method (default: truncate)"
    if [[ "$UVB_IMAGE_KIND" == "removable" ]]; then
        printf '  %-38s %s\n' "--disk-size=8|16|32|64|<GB>" "Disk size in GB (default: ${def_sz}; min: ${min_sz}; <16 GB -> 2 GB swap)"
    else
        printf '  %-38s %s\n' "--disk-size=32|64|128|<GB>" "Disk size in GB (default: ${def_sz}; min: ${min_sz}; 512 MB ESP + 4 GB swap)"
    fi
    printf '  %-38s %s\n' "--user-mode=build|deploy" "build = bake credentials; deploy = cloud-init / first-boot wizard"
    printf '  %-38s %s\n' "--username=NAME / --password=PASS" "Credentials for --user-mode=build"
    printf '  %-38s %s\n' "--fullname=NAME / --hostname=NAME" "GECOS full name and hostname"
    if [[ "$UVB_IMAGE_KIND" == "vm" ]]; then
        printf '  %-38s %s\n' "--formats=qcow2,vdi,vmdk,vhdx|all|none" "VM export formats (default: qcow2)"
    fi
    echo
    echo "EXAMPLES"
    if [[ "$UVB_IMAGE_KIND" == "vm" ]]; then
        echo "  $ $0 --release=noble --arch=amd64 --kernel=$([[ "$UVB_DISTRO" == "popos" ]] && echo system76 || echo generic) --formats=qcow2,vdi -"
    elif [[ "$UVB_IMAGE_KIND" == "removable" ]]; then
        echo "  $ $0 --release=noble --firmware=hybrid --disk-size=16 --user-mode=build --username=alice --password=secret -"
    else
        echo "  $ $0 --release=noble --arch=amd64 --profile=cli --kernel=$([[ "$UVB_DISTRO" == "popos" ]] && echo system76 || echo generic) -"
    fi
    echo "  $ $0 --advanced --config=scripts/$(default_config_filename) --no-interactive -"
}

function disk_image_resolve_options() {
    local def_fw def_sz min_sz
    def_fw="$(disk_image_default_firmware)"
    def_sz="$(disk_image_default_size_gb)"
    min_sz="$(disk_image_min_size_gb)"

    # Firmware
    if [[ -n "${TARGET_FIRMWARE:-}" ]]; then
        export TARGET_FIRMWARE="${TARGET_FIRMWARE,,}"
        case "$TARGET_FIRMWARE" in
            bios|legacy) export TARGET_FIRMWARE="hybrid" ;;
            uefi-only)   export TARGET_FIRMWARE="uefi" ;;
        esac
    elif [[ "${TARGET_ARCH:-amd64}" == "arm64" ]]; then
        export TARGET_FIRMWARE="uefi"
    elif prompts_enabled; then
        if [[ "$UVB_IMAGE_KIND" == "removable" ]]; then
            ui_menu "Firmware / boot mode" "Select boot target for removable media:" "hybrid" \
                "hybrid" "BIOS + UEFI on one disk (1 MiB bios_grub + 512 MB ESP)" \
                "uefi"   "UEFI-only (GPT + 512 MB ESP)"
        else
            ui_menu "Firmware / boot mode" "Select boot target:" "uefi" \
                "uefi"   "UEFI-only (GPT + 512 MB ESP; modern cloud/OVMF/Gen2)" \
                "hybrid" "BIOS + UEFI on one disk (1 MiB bios_grub + 512 MB ESP)"
        fi
        export TARGET_FIRMWARE="$UI_REPLY"
        ui_ok "TARGET_FIRMWARE=$TARGET_FIRMWARE"
    else
        export TARGET_FIRMWARE="$def_fw"
    fi

    if [[ "${TARGET_ARCH:-amd64}" == "arm64" && "${TARGET_FIRMWARE}" == "hybrid" ]]; then
        ui_err "ARM64 targets only support --firmware=uefi (legacy BIOS is x86-only)."
        exit 1
    fi

    # Disk size
    if [[ -z "${TARGET_DISK_SIZE_GB:-}" ]]; then
        if prompts_enabled; then
            if [[ "$UVB_IMAGE_KIND" == "removable" ]]; then
                ui_menu "Disk image size" "Layout: 512 MB ESP + swap (2 GB if <16 GB, else 4 GB) + root:" "16" \
                    "8"      "8 GB  (2 GB swap, ~5.5 GB root)" \
                    "16"     "16 GB (4 GB swap, ~11.5 GB root)" \
                    "32"     "32 GB (4 GB swap, ~27.5 GB root)" \
                    "64"     "64 GB (4 GB swap, ~59.5 GB root)" \
                    "custom" "Enter custom size in GB (minimum ${min_sz})"
            else
                ui_menu "Disk image size" "Layout: 512 MB ESP + 4 GB swap + root gets the rest:" "32" \
                    "32"     "32 GB  (~27.5 GB root)" \
                    "64"     "64 GB  (~59.5 GB root)" \
                    "128"    "128 GB (~123.5 GB root)" \
                    "custom" "Enter custom size in GB (minimum ${min_sz})"
            fi
            if [[ "$UI_REPLY" == "custom" ]]; then
                while true; do
                    ui_input "Custom disk size" "Size in GB (minimum ${min_sz})" "$def_sz"
                    if [[ "$UI_REPLY" =~ ^[0-9]+$ ]] && (( UI_REPLY >= min_sz )); then
                        export TARGET_DISK_SIZE_GB="$UI_REPLY"
                        break
                    fi
                    ui_warn "Enter a whole number of GB >= ${min_sz}."
                done
            else
                export TARGET_DISK_SIZE_GB="$UI_REPLY"
            fi
            ui_ok "TARGET_DISK_SIZE_GB=$TARGET_DISK_SIZE_GB"
        else
            export TARGET_DISK_SIZE_GB="$def_sz"
        fi
    fi

    # Allocation tool
    if [[ -n "${TARGET_IMG_ALLOC:-}" ]]; then
        export TARGET_IMG_ALLOC="${TARGET_IMG_ALLOC,,}"
        case "$TARGET_IMG_ALLOC" in
            sparse)               export TARGET_IMG_ALLOC="truncate" ;;
            prealloc|preallocate) export TARGET_IMG_ALLOC="fallocate" ;;
        esac
    elif prompts_enabled; then
        ui_menu "Image allocation tool" "How the raw .img file is created on the host:" "truncate" \
            "truncate"  "Sparse file (instant; allocates blocks on write)" \
            "fallocate" "Preallocated extents (no sparse holes)" \
            "dd"        "Zero-written via dd (slowest; max compatibility)"
        export TARGET_IMG_ALLOC="$UI_REPLY"
        ui_ok "TARGET_IMG_ALLOC=$TARGET_IMG_ALLOC"
    else
        export TARGET_IMG_ALLOC="truncate"
    fi
}

function validate_vm_formats() {
    local fmt list="${1:-}"
    [[ "$list" == "none" ]] && return 0
    [[ -z "$list" ]] && return 1
    for fmt in ${list//,/ }; do
        case "$fmt" in
            qcow2|vdi|vmdk|vhdx) ;;
            *) return 1 ;;
        esac
    done
    return 0
}

function _disk_valid_username() {
    local u="$1"
    [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || return 1
    case "$u" in
        root|daemon|bin|sys|sync|games|man|lp|mail|news|uucp|proxy|www-data|backup|list|irc|nobody|_apt|systemd-*|messagebus|sshd)
            return 1
            ;;
    esac
    return 0
}

function disk_image_resolve_credentials() {
    if [[ -z "${TARGET_USER_MODE:-}" ]]; then
        if prompts_enabled; then
            if [[ "$UVB_IMAGE_KIND" == "cloud" ]]; then
                ui_menu "User account" "Choose when user credentials are created:" "deploy" \
                    "deploy" "Deploy-time via cloud-init (SSH keys/metadata from provider)" \
                    "build"  "Build-time (bake username & password into the image)"
            else
                local def_um="build"
                [[ "$UVB_IMAGE_KIND" == "removable" ]] && def_um="deploy"
                ui_menu "User account" "Choose when user credentials are created:" "$def_um" \
                    "build"  "Build-time (bake username & password into the image)" \
                    "deploy" "First-boot console wizard on tty1 at initial startup"
            fi
            export TARGET_USER_MODE="$UI_REPLY"
            ui_ok "TARGET_USER_MODE=$TARGET_USER_MODE"
        else
            export TARGET_USER_MODE="deploy"
        fi
    fi
    export TARGET_USER_MODE="${TARGET_USER_MODE,,}"

    if [[ "$TARGET_USER_MODE" == "build" ]] && [[ -z "${TARGET_USERNAME:-}" || -z "${TARGET_USER_PASSWORD:-}" ]]; then
        if prompts_enabled; then
            ui_heading "Build-time credentials"
            local u
            while true; do
                ui_input "Username" "Username (lowercase letters, digits, '-' and '_'; not 'root')" ""
                u="$UI_REPLY"
                if _disk_valid_username "$u"; then
                    export TARGET_USERNAME="$u"
                    break
                fi
                ui_warn "Invalid or reserved username '$u'."
            done
            if [[ -z "${TARGET_USER_FULLNAME:-}" ]]; then
                ui_input "Full name" "Full name (optional)" ""
                export TARGET_USER_FULLNAME="$UI_REPLY"
            fi
            ui_password "Password" "Password for ${TARGET_USERNAME}"
            export TARGET_USER_PASSWORD="$UI_REPLY"
            if [[ -z "${TARGET_HOSTNAME:-}" ]]; then
                local def_host="ubuntu"
                [[ "$UVB_DISTRO" == "popos" ]] && def_host="pop-os"
                ui_input "Hostname" "Hostname" "$def_host"
                export TARGET_HOSTNAME="$UI_REPLY"
            fi
        else
            ui_err "TARGET_USER_MODE=build requires TARGET_USERNAME and TARGET_USER_PASSWORD for non-interactive runs."
            exit 1
        fi
    fi

    # VM export formats (vm kind only)
    if [[ "$UVB_IMAGE_KIND" == "vm" ]]; then
        if [[ -n "${TARGET_VM_FORMATS:-}" ]]; then
            export TARGET_VM_FORMATS="${TARGET_VM_FORMATS,,}"
            if [[ "$TARGET_VM_FORMATS" == "all" ]]; then
                export TARGET_VM_FORMATS="qcow2,vdi,vmdk,vhdx"
            fi
        elif prompts_enabled; then
            while true; do
                ui_input "VM export formats" "Formats (qcow2,vdi,vmdk,vhdx / all / none)" "qcow2"
                local raw="${UI_REPLY,,}"
                [[ "$raw" == "all" ]] && raw="qcow2,vdi,vmdk,vhdx"
                if validate_vm_formats "$raw"; then
                    export TARGET_VM_FORMATS="$raw"
                    break
                fi
                ui_warn "Invalid format list '$raw'."
            done
        else
            export TARGET_VM_FORMATS="qcow2"
        fi
    fi
}

function disk_image_check_settings() {
    local min_sz
    min_sz="$(disk_image_min_size_gb)"
    local def_fw
    def_fw="$(disk_image_default_firmware)"

    case "${TARGET_FIRMWARE:-$def_fw}" in
        uefi|hybrid) ;;
        *)
            ui_err "TARGET_FIRMWARE must be uefi or hybrid (got: '${TARGET_FIRMWARE:-}')."
            exit 1
            ;;
    esac
    if [[ "${TARGET_ARCH:-amd64}" == "arm64" && "${TARGET_FIRMWARE:-uefi}" == "hybrid" ]]; then
        ui_err "ARM64 disk images support UEFI-only (--firmware=uefi)."
        exit 1
    fi
    case "${TARGET_IMG_ALLOC:-truncate}" in
        truncate|fallocate|dd) ;;
        *)
            ui_err "TARGET_IMG_ALLOC must be truncate, fallocate, or dd (got: '${TARGET_IMG_ALLOC:-}')."
            exit 1
            ;;
    esac
    local def_sz
    def_sz="$(disk_image_default_size_gb)"
    if [[ ! "${TARGET_DISK_SIZE_GB:-$def_sz}" =~ ^[0-9]+$ ]] || (( ${TARGET_DISK_SIZE_GB:-$def_sz} < min_sz )); then
        ui_err "TARGET_DISK_SIZE_GB must be an integer >= ${min_sz} (got: '${TARGET_DISK_SIZE_GB:-}')."
        exit 1
    fi
    case "${TARGET_USER_MODE:-deploy}" in
        build|deploy) ;;
        *)
            ui_err "TARGET_USER_MODE must be build or deploy (got: '${TARGET_USER_MODE:-}')."
            exit 1
            ;;
    esac
    if [[ "${TARGET_USER_MODE:-deploy}" == "build" && -n "${TARGET_USERNAME:-}" ]] && \
       ! _disk_valid_username "${TARGET_USERNAME}"; then
        ui_err "TARGET_USERNAME must be a valid non-system Linux username (got: '${TARGET_USERNAME}')."
        exit 1
    fi
    if [[ "$UVB_IMAGE_KIND" == "vm" ]] && ! validate_vm_formats "${TARGET_VM_FORMATS:-qcow2}"; then
        ui_err "TARGET_VM_FORMATS must be 'all', 'none', or comma-separated qcow2,vdi,vmdk,vhdx (got: '${TARGET_VM_FORMATS:-}')."
        exit 1
    fi
}

function disk_image_print_summary_fields() {
    local _fw="${TARGET_FIRMWARE:-$(disk_image_default_firmware)}"
    [[ "$_fw" == "uefi" ]] && _fw="uefi  (UEFI-only)"
    [[ "$_fw" == "hybrid" ]] && _fw="hybrid  (BIOS + UEFI)"
    ui_kv "Firmware"         "$_fw"
    ui_kv "Network stack"    "${TARGET_NETWORK_STACK:-network-manager}"
    ui_kv "Image allocation" "${TARGET_IMG_ALLOC:-truncate}"
    if [[ "$UVB_IMAGE_KIND" == "removable" ]]; then
        ui_kv "Disk size" "${TARGET_DISK_SIZE_GB:-16} GB  (ESP 512 MB + swap 2/4 GB by size + root)"
    else
        ui_kv "Disk size" "${TARGET_DISK_SIZE_GB:-32} GB  (ESP 512 MB + swap 4 GB + root)"
    fi
    local _user_line=""
    if [[ "${TARGET_USER_MODE:-deploy}" == "build" ]]; then
        _user_line="baked at build time (user: ${TARGET_USERNAME:-?})"
    elif [[ "$UVB_IMAGE_KIND" == "cloud" ]]; then
        _user_line="created at deploy time (cloud-init)"
    else
        _user_line="first-boot console wizard"
    fi
    ui_kv "User account" "$_user_line"
    if [[ "$UVB_IMAGE_KIND" == "vm" ]]; then
        if [[ "${TARGET_VM_FORMATS:-qcow2}" == "none" ]]; then
            ui_kv "VM formats" "raw .img only"
        else
            ui_kv "VM formats" "raw + ${TARGET_VM_FORMATS:-qcow2}"
        fi
    fi
}

function install_pkg() {
    echo "=====> running install_pkg (kind=${UVB_IMAGE_KIND}, arch=${TARGET_ARCH:-amd64}) ..."
    echo "=====> kernel metapackage: $TARGET_KERNEL_PACKAGE"
    apt-get -y upgrade

    local -a grub_pkgs=(grub-common grub2-common shim-signed)
    if [[ "${TARGET_ARCH:-amd64}" == "arm64" ]]; then
        grub_pkgs+=(grub-efi-arm64-bin grub-efi-arm64-signed)
    else
        grub_pkgs+=(grub-gfxpayload-lists grub-pc grub-pc-bin grub-efi-amd64-bin grub-efi-amd64-signed)
    fi

    apt-get install -y \
        sudo \
        ubuntu-standard \
        net-tools \
        locales \
        netplan.io \
        dosfstools \
        e2fsprogs \
        parted \
        "${grub_pkgs[@]}"

    if [[ "${TARGET_NETWORK_STACK:-network-manager}" == "network-manager" ]]; then
        echo "=====> networking: NetworkManager"
        apt-get install -y network-manager
    else
        echo "=====> networking: netplan + systemd-networkd"
    fi

    echo "=====> installing kernel metapackage: $TARGET_KERNEL_PACKAGE"
    apt-get install -y "$TARGET_KERNEL_PACKAGE"

    if [[ "$UVB_IMAGE_KIND" == "cloud" || "$UVB_IMAGE_KIND" == "removable" ]]; then
        echo "=====> cloud-init: installing (cloud-init + cloud-guest-utils)"
        apt-get install -y cloud-init cloud-guest-utils
    else
        echo "=====> VM image: cloud-init skipped"
    fi

    customize_image
    run_chroot_hooks

    apt-get autoremove -y
    configure_locale_and_keyboard
    configure_network_manager_conf
    apt-get clean -y
}

function detach_image_loop() {
    sync || true
    if [[ -n "${IMG_MOUNT_DIR:-}" ]]; then
        local _mp
        for _mp in "$IMG_MOUNT_DIR/dev/pts" "$IMG_MOUNT_DIR/dev" "$IMG_MOUNT_DIR/proc" \
                   "$IMG_MOUNT_DIR/sys" "$IMG_MOUNT_DIR/run" "$IMG_MOUNT_DIR/boot/efi" \
                   "$IMG_MOUNT_DIR"; do
            if mountpoint -q "$_mp" 2>/dev/null; then
                host_priv umount "$_mp" 2>/dev/null || host_priv umount -l "$_mp" 2>/dev/null || true
            fi
        done
    fi
    if [[ -n "${IMG_LOOP_DEV:-}" ]]; then
        command -v udevadm &>/dev/null && { host_priv udevadm settle 2>/dev/null || true; }
        host_priv losetup -d "$IMG_LOOP_DEV" 2>/dev/null || true
    fi
    IMG_LOOP_DEV=""
    IMG_MOUNT_DIR=""
}

function in_target() {
    host_priv chroot "$IMG_MOUNT_DIR" /usr/bin/env \
        DEBIAN_FRONTEND=noninteractive LC_ALL=C HOME=/root "$@"
}

function create_baked_user() {
    echo "=====> creating user '${TARGET_USERNAME}' inside the image ..."
    in_target useradd -m -s /bin/bash -c "${TARGET_USER_FULLNAME:-$TARGET_USERNAME}" "$TARGET_USERNAME"
    local grp
    for grp in adm cdrom dip plugdev sudo lxd; do
        if in_target getent group "$grp" >/dev/null 2>&1; then
            in_target usermod -aG "$grp" "$TARGET_USERNAME"
        fi
    done
    printf '%s:%s\n' "$TARGET_USERNAME" "$TARGET_USER_PASSWORD" | in_target chpasswd
}

function configure_cloud_init_user() {
    if [[ "$UVB_IMAGE_KIND" != "cloud" && "$UVB_IMAGE_KIND" != "removable" ]] || [[ "${TARGET_USER_MODE:-deploy}" != "build" ]]; then
        return 0
    fi
    host_priv mkdir -p "$IMG_MOUNT_DIR/etc/cloud/cloud.cfg.d"
    host_priv tee "$IMG_MOUNT_DIR/etc/cloud/cloud.cfg.d/90-uvb-default-user.cfg" >/dev/null <<EOF
# Written by ${SCRIPT_NAME}: default user baked at build time.
system_info:
  default_user:
    name: ${TARGET_USERNAME}
    lock_passwd: false
    gecos: ${TARGET_USER_FULLNAME:-$TARGET_USERNAME}
    groups: [adm, cdrom, dip, plugdev, sudo]
    shell: /bin/bash
ssh_pwauth: true
EOF
}

function configure_removable_cloud_init() {
    echo "=====> configuring cloud-init NoCloud + growpart for removable media ..."
    host_priv mkdir -p "$IMG_MOUNT_DIR/etc/cloud/cloud.cfg.d"
    host_priv mkdir -p "$IMG_MOUNT_DIR/var/lib/cloud/seed/nocloud"
    local def_host="ubuntu"
    [[ "$UVB_DISTRO" == "popos" ]] && def_host="pop-os"
    local seed_host="${TARGET_HOSTNAME:-$def_host}"
    host_priv tee "$IMG_MOUNT_DIR/etc/cloud/cloud.cfg.d/90-uvb-removable.cfg" >/dev/null <<'EOF'
# Written by ubuntu-vanilla-build removable image builder.
datasource_list: [ NoCloud, None ]
disable_root: true
ssh_pwauth: true
growpart:
  mode: auto
  devices: ["/"]
  ignore_growroot_disabled: false
resize_rootfs: true
network:
  config: disabled
users: []
EOF
    host_priv tee "$IMG_MOUNT_DIR/var/lib/cloud/seed/nocloud/meta-data" >/dev/null <<EOF
instance-id: uvb-removable-${DATE}
local-hostname: ${seed_host}
EOF
    host_priv tee "$IMG_MOUNT_DIR/var/lib/cloud/seed/nocloud/user-data" >/dev/null <<'EOF'
#cloud-config
users: []
EOF
}

function install_firstboot_user_wizard() {
    echo "=====> installing first-boot user wizard on tty1 ..."
    host_priv tee "$IMG_MOUNT_DIR/usr/local/sbin/uvb-firstboot-setup" >/dev/null <<'WIZARD_EOF'
#!/bin/bash
set -u
echo
echo "=================================================================="
echo "  Welcome! Create your user account for this system."
echo "=================================================================="
echo
username=""
while true; do
    read -r -p "Username: " username
    if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        echo "Invalid username (lowercase letters, digits, '-' and '_')."
        continue
    fi
    if id "$username" &>/dev/null; then
        echo "User '$username' already exists -- pick another name."
        continue
    fi
    break
done
read -r -p "Full name (optional): " fullname
while true; do
    read -r -s -p "Password: " pw1; echo
    read -r -s -p "Confirm password: " pw2; echo
    [[ -n "$pw1" && "$pw1" == "$pw2" ]] && break
    echo "Passwords are empty or do not match -- try again."
done
while true; do
    read -r -p "Hostname [$(cat /etc/hostname)]: " newhost
    [[ -z "$newhost" ]] && break
    if [[ "$newhost" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        break
    fi
    echo "Invalid hostname (use letters, digits, and hyphens)."
done
useradd -m -s /bin/bash -c "${fullname:-$username}" "$username"
for grp in adm cdrom dip plugdev sudo lxd; do
    getent group "$grp" >/dev/null && usermod -aG "$grp" "$username"
done
printf '%s:%s\n' "$username" "$pw1" | chpasswd
if [[ -n "$newhost" ]]; then
    echo "$newhost" > /etc/hostname
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1 ${newhost}/" /etc/hosts || true
    hostname "$newhost" 2>/dev/null || true
fi
rm -f /var/lib/uvb-firstboot-pending
echo
echo "User '$username' created. Continuing boot ..."
sleep 1
exit 0
WIZARD_EOF
    host_priv chmod 0755 "$IMG_MOUNT_DIR/usr/local/sbin/uvb-firstboot-setup"

    host_priv tee "$IMG_MOUNT_DIR/etc/systemd/system/uvb-firstboot-setup.service" >/dev/null <<'UNIT_EOF'
[Unit]
Description=First-boot user account wizard
ConditionPathExists=/var/lib/uvb-firstboot-pending
After=systemd-user-sessions.service
Before=getty@tty1.service display-manager.service

[Service]
Type=oneshot
RemainAfterExit=yes
StandardInput=tty
StandardOutput=tty
StandardError=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
ExecStart=/usr/local/sbin/uvb-firstboot-setup

[Install]
WantedBy=multi-user.target
UNIT_EOF
    host_priv touch "$IMG_MOUNT_DIR/var/lib/uvb-firstboot-pending"
    in_target systemctl enable uvb-firstboot-setup.service
}

function write_output_hashes() {
    local file="$1"
    echo "=====> writing SHA-1 and SHA-256 for ${file##*/} ..."
    (
        cd "$OUTPUT_DIR" || exit 1
        sha1sum "${file##*/}" | host_priv tee "${file##*/}.sha1" >/dev/null
        sha256sum "${file##*/}" | host_priv tee "${file##*/}.sha256" >/dev/null
    )
    OUTPUT_FILES+=("$file" "$file.sha1" "$file.sha256")
}

function fix_disk_output_ownership() {
    local owner=""
    if [[ "$(id -u)" -eq 0 ]]; then
        [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] && owner="$SUDO_USER"
    else
        owner="$(id -un)"
    fi
    [[ -z "$owner" ]] && return 0
    local f
    for f in "${OUTPUT_FILES[@]}"; do
        [[ -e "$f" ]] && host_priv chown "$owner" "$f" 2>/dev/null || true
    done
}

function export_vm_images() {
    local raw="$1"
    local formats="${TARGET_VM_FORMATS:-qcow2}"
    if [[ "$formats" == "none" ]]; then
        echo "=====> VM exports: none requested (raw .img only)"
        return 0
    fi
    local fmt out
    for fmt in ${formats//,/ }; do
        case "$fmt" in
            qcow2)
                out="${raw%.img}.qcow2"
                echo "=====> exporting QCOW2: ${out##*/}"
                host_priv qemu-img convert -f raw -O qcow2 -c "$raw" "$out"
                ;;
            vdi)
                out="${raw%.img}.vdi"
                echo "=====> exporting VDI: ${out##*/}"
                host_priv qemu-img convert -f raw -O vdi "$raw" "$out"
                ;;
            vmdk)
                out="${raw%.img}.vmdk"
                echo "=====> exporting VMDK: ${out##*/}"
                host_priv qemu-img convert -f raw -O vmdk "$raw" "$out"
                ;;
            vhdx)
                out="${raw%.img}.vhdx"
                echo "=====> exporting VHDX: ${out##*/}"
                host_priv qemu-img convert -f raw -O vhdx "$raw" "$out"
                ;;
            *)
                ui_warn "Unknown VM export format '$fmt' -- skipping."
                continue
                ;;
        esac
        write_output_hashes "$out"
    done
}

function build_disk_image() {
    echo "=====> running build_disk_image (kind=${UVB_IMAGE_KIND}, arch=${TARGET_ARCH:-amd64}) ..."

    local def_sz def_fw
    def_sz="$(disk_image_default_size_gb)"
    def_fw="$(disk_image_default_firmware)"
    local size_gb="${TARGET_DISK_SIZE_GB:-$def_sz}"
    local firmware="${TARGET_FIRMWARE:-$def_fw}"
    local arch="${TARGET_ARCH:-amd64}"
    local esp_mib=512
    local swap_mib=4096
    if [[ "$UVB_IMAGE_KIND" == "removable" ]] && (( size_gb < 16 )); then
        swap_mib=2048
    fi

    local img_path="$WORKSPACE_DIR/$TARGET_NAME.img"
    IMG_MOUNT_DIR="$WORKSPACE_DIR/imgroot"
    detach_image_loop || true

    ensure_workspace_root
    host_priv rm -f "$img_path"

    local alloc="${TARGET_IMG_ALLOC:-truncate}"
    echo "=====> allocating ${size_gb} GB image (tool: ${alloc}): $img_path"
    case "$alloc" in
        truncate)  host_priv truncate -s "${size_gb}G" "$img_path" ;;
        fallocate) host_priv fallocate -l "${size_gb}G" "$img_path" ;;
        dd)        host_priv dd if=/dev/zero of="$img_path" bs=1M count="$((size_gb * 1024))" status=progress ;;
    esac

    IMG_LOOP_DEV="$(host_priv losetup --show -f -P "$img_path")"
    echo "=====> loop device: $IMG_LOOP_DEV"

    local p_esp p_swap p_root
    if [[ "$firmware" == "uefi" ]]; then
        host_priv parted -s "$IMG_LOOP_DEV" \
            mklabel gpt \
            mkpart ESP fat32 1MiB "$((1 + esp_mib))MiB" \
            set 1 esp on \
            mkpart swap linux-swap "$((1 + esp_mib))MiB" "$((1 + esp_mib + swap_mib))MiB" \
            mkpart root ext4 "$((1 + esp_mib + swap_mib))MiB" 100%
        p_esp="${IMG_LOOP_DEV}p1"
        p_swap="${IMG_LOOP_DEV}p2"
        p_root="${IMG_LOOP_DEV}p3"
    else
        host_priv parted -s "$IMG_LOOP_DEV" \
            mklabel gpt \
            mkpart biosboot 1MiB 2MiB \
            set 1 bios_grub on \
            mkpart ESP fat32 2MiB "$((2 + esp_mib))MiB" \
            set 2 esp on \
            mkpart swap linux-swap "$((2 + esp_mib))MiB" "$((2 + esp_mib + swap_mib))MiB" \
            mkpart root ext4 "$((2 + esp_mib + swap_mib))MiB" 100%
        p_esp="${IMG_LOOP_DEV}p2"
        p_swap="${IMG_LOOP_DEV}p3"
        p_root="${IMG_LOOP_DEV}p4"
    fi
    host_priv partprobe "$IMG_LOOP_DEV" 2>/dev/null || true
    command -v udevadm &>/dev/null && { host_priv udevadm settle 2>/dev/null || true; }

    echo "=====> creating filesystems (ESP ${esp_mib} MB, swap $((swap_mib / 1024)) GB, root = rest) ..."
    host_priv mkfs.vfat -F 32 -n ESP "$p_esp"
    host_priv mkswap -L swap "$p_swap"
    host_priv mkfs.ext4 -q -L root "$p_root"

    host_priv mkdir -p "$IMG_MOUNT_DIR"
    host_priv mount "$p_root" "$IMG_MOUNT_DIR"
    host_priv mkdir -p "$IMG_MOUNT_DIR/boot/efi"
    host_priv mount "$p_esp" "$IMG_MOUNT_DIR/boot/efi"

    echo "=====> copying root filesystem into image ..."
    host_priv rsync -aHAX \
        --exclude=/root/build.sh \
        --exclude=/root/lib \
        --exclude=/root/hooks \
        --exclude='/var/cache/apt/archives/*.deb' \
        --exclude=/swapfile \
        "$WORKSPACE_CHROOT/" "$IMG_MOUNT_DIR/"

    local uuid_esp uuid_swap uuid_root
    uuid_esp="$(host_priv blkid -s UUID -o value "$p_esp")"
    uuid_swap="$(host_priv blkid -s UUID -o value "$p_swap")"
    uuid_root="$(host_priv blkid -s UUID -o value "$p_root")"

    host_priv tee "$IMG_MOUNT_DIR/etc/fstab" >/dev/null <<EOF
# /etc/fstab -- generated by ${SCRIPT_NAME}
UUID=${uuid_root}  /          ext4  defaults,errors=remount-ro  0 1
UUID=${uuid_esp}  /boot/efi  vfat  umask=0077  0 1
UUID=${uuid_swap}  none       swap  sw  0 0
EOF

    local def_host="ubuntu"
    [[ "$UVB_DISTRO" == "popos" ]] && def_host="pop-os"
    local img_hostname="${TARGET_HOSTNAME:-$def_host}"
    echo "$img_hostname" | host_priv tee "$IMG_MOUNT_DIR/etc/hostname" >/dev/null
    host_priv tee "$IMG_MOUNT_DIR/etc/hosts" >/dev/null <<EOF
127.0.0.1 localhost
127.0.1.1 ${img_hostname}

::1 ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

    host_priv ln -sf ../run/systemd/resolve/stub-resolv.conf "$IMG_MOUNT_DIR/etc/resolv.conf"

    if [[ "$UVB_IMAGE_KIND" != "cloud" ]]; then
        host_priv mkdir -p "$IMG_MOUNT_DIR/etc/netplan"
        if [[ "${TARGET_NETWORK_STACK:-network-manager}" == "network-manager" ]]; then
            host_priv tee "$IMG_MOUNT_DIR/etc/netplan/01-network-manager-all.yaml" >/dev/null <<'EOF'
network:
  version: 2
  renderer: NetworkManager
EOF
            host_priv chmod 0600 "$IMG_MOUNT_DIR/etc/netplan/01-network-manager-all.yaml"
        else
            host_priv tee "$IMG_MOUNT_DIR/etc/netplan/01-dhcp-all.yaml" >/dev/null <<'EOF'
network:
  version: 2
  ethernets:
    all-ethernet:
      match:
        name: "en*"
      dhcp4: true
      dhcp6: true
EOF
            host_priv chmod 0600 "$IMG_MOUNT_DIR/etc/netplan/01-dhcp-all.yaml"
        fi
    fi

    # Ensure qemu static binary is present for cross-arch grub/initramfs calls if needed.
    local host_arch qbin copied_q=""
    host_arch="$(host_dpkg_arch)"
    if [[ "$arch" != "$host_arch" ]]; then
        qbin="$(qemu_static_bin_for_arch "$arch")"
        if [[ -n "$qbin" ]] && command -v "$qbin" >/dev/null 2>&1 && [[ ! -x "$IMG_MOUNT_DIR/usr/bin/$qbin" ]]; then
            host_priv install -m 0755 "$(command -v "$qbin")" "$IMG_MOUNT_DIR/usr/bin/$qbin"
            copied_q="$IMG_MOUNT_DIR/usr/bin/$qbin"
        fi
    fi

    host_priv mount --bind /dev "$IMG_MOUNT_DIR/dev"
    host_priv mount --bind /dev/pts "$IMG_MOUNT_DIR/dev/pts"
    host_priv mount -t proc proc "$IMG_MOUNT_DIR/proc"
    host_priv mount -t sysfs sysfs "$IMG_MOUNT_DIR/sys"
    host_priv mount --bind /run "$IMG_MOUNT_DIR/run"

    if [[ "${TARGET_NETWORK_STACK:-networkd}" == "networkd" ]]; then
        in_target systemctl enable systemd-networkd.service || true
    fi

    if [[ "$UVB_IMAGE_KIND" == "cloud" && "${TARGET_NETWORK_STACK:-networkd}" == "network-manager" ]]; then
        host_priv mkdir -p "$IMG_MOUNT_DIR/etc/cloud/cloud.cfg.d"
        host_priv tee "$IMG_MOUNT_DIR/etc/cloud/cloud.cfg.d/91-uvb-network-renderer.cfg" >/dev/null <<'EOF'
system_info:
  network:
    renderers: ['network-manager', 'netplan', 'networkd']
    activators: ['network-manager', 'netplan', 'networkd']
EOF
    fi

    if [[ "$UVB_IMAGE_KIND" == "cloud" ]]; then
        local console_arg="console=tty1 console=ttyS0,115200"
        [[ "$arch" == "arm64" ]] && console_arg="console=tty1 console=ttyAMA0,115200"
        host_priv mkdir -p "$IMG_MOUNT_DIR/etc/default/grub.d"
        host_priv tee "$IMG_MOUNT_DIR/etc/default/grub.d/50-cloudimg.cfg" >/dev/null <<EOF
GRUB_CMDLINE_LINUX_DEFAULT="${console_arg}"
GRUB_TIMEOUT=0
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200"
EOF
    elif [[ "$UVB_IMAGE_KIND" == "removable" ]]; then
        host_priv mkdir -p "$IMG_MOUNT_DIR/etc/default/grub.d"
        host_priv tee "$IMG_MOUNT_DIR/etc/default/grub.d/50-removable.cfg" >/dev/null <<'EOF'
GRUB_TIMEOUT=3
GRUB_TIMEOUT_STYLE=menu
GRUB_CMDLINE_LINUX_DEFAULT=""
EOF
    fi

    host_priv mkdir -p "$IMG_MOUNT_DIR/etc/initramfs-tools/conf.d"
    echo "RESUME=none" | host_priv tee "$IMG_MOUNT_DIR/etc/initramfs-tools/conf.d/resume" >/dev/null

    local boot_id="ubuntu"
    [[ "$UVB_DISTRO" == "popos" ]] && boot_id="pop"
    local efi_target="x86_64-efi"
    [[ "$arch" == "arm64" ]] && efi_target="arm64-efi"

    echo "=====> installing GRUB (arch=${arch}, firmware=${firmware}) ..."
    if [[ "$firmware" == "hybrid" && "$arch" == "amd64" ]]; then
        in_target grub-install --target=i386-pc --recheck "$IMG_LOOP_DEV"
    fi
    in_target grub-install --target="$efi_target" --efi-directory=/boot/efi \
        --bootloader-id="$boot_id" --uefi-secure-boot --recheck --no-nvram
    in_target grub-install --target="$efi_target" --efi-directory=/boot/efi \
        --bootloader-id="$boot_id" --uefi-secure-boot --removable --recheck --no-nvram
    in_target update-initramfs -u
    in_target update-grub

    if [[ "${TARGET_USER_MODE:-deploy}" == "build" ]]; then
        create_baked_user
    elif [[ "$UVB_IMAGE_KIND" == "vm" || "$UVB_IMAGE_KIND" == "removable" ]]; then
        install_firstboot_user_wizard
    else
        echo "=====> user account: created at deploy time by cloud-init"
    fi
    configure_cloud_init_user
    if [[ "$UVB_IMAGE_KIND" == "removable" ]]; then
        configure_removable_cloud_init
    fi

    if [[ -n "$copied_q" && -f "$copied_q" ]]; then
        host_priv rm -f "$copied_q"
    fi

    detach_image_loop

    ensure_output_dir
    echo "=====> moving image to $OUTPUT_DIR/$TARGET_NAME.img"
    host_priv mv "$img_path" "$OUTPUT_DIR/$TARGET_NAME.img"
    write_output_hashes "$OUTPUT_DIR/$TARGET_NAME.img"

    if [[ "$UVB_IMAGE_KIND" == "vm" ]]; then
        export_vm_images "$OUTPUT_DIR/$TARGET_NAME.img"
    fi

    fix_disk_output_ownership
    clean_workspace
}

function disk_image_print_build_result() {
    local img_path="${OUTPUT_DIR:-?}/${TARGET_NAME:-image}.img"
    if [[ ! -f "$img_path" ]]; then
        ui_heading "Build finished"
        ui_info "No image produced at $img_path (this is expected for partial runs)."
        return 0
    fi
    local size=""
    size="$(du -h --apparent-size "$img_path" 2>/dev/null | awk '{print $1}')"

    ui_heading "Build complete"
    ui_kv "Image"  "$img_path"
    ui_kv "Size"   "${size:-unknown}"
    [[ -f "$img_path.sha1" ]]   && ui_kv "SHA1"   "$(awk '{print $1}' "$img_path.sha1")"
    [[ -f "$img_path.sha256" ]] && ui_kv "SHA256" "$(awk '{print $1}' "$img_path.sha256")"
    if [[ "$UVB_IMAGE_KIND" == "vm" ]]; then
        local fmt out
        for fmt in ${TARGET_VM_FORMATS//,/ }; do
            [[ "$fmt" == "none" ]] && continue
            out="${img_path%.img}.${fmt}"
            [[ -f "$out" ]] && ui_kv "Export ($fmt)" "$out"
        done
    fi
    echo
    echo "  Next steps:"
    if [[ "$UVB_IMAGE_KIND" == "cloud" ]]; then
        echo "    Upload the raw .img to your cloud provider; cloud-init/growpart grows root on first boot."
        if [[ "${TARGET_USER_MODE:-deploy}" == "build" ]]; then
            echo "    Log in with the baked account: ${TARGET_USERNAME:-?}."
        else
            echo "    User accounts and SSH keys are provisioned at deploy time by cloud-init."
        fi
    elif [[ "$UVB_IMAGE_KIND" == "removable" ]]; then
        echo "    Flash the raw .img onto a USB stick, SD card, or CF card of equal or larger size"
        echo "    (dd, balenaEtcher, Rufus). On first boot, growpart expands root to fill the media."
        if [[ "${TARGET_FIRMWARE:-hybrid}" == "hybrid" ]]; then
            echo "    Hybrid image: boots on both legacy BIOS and UEFI systems."
        else
            echo "    UEFI-only image: boot from UEFI firmware."
        fi
        if [[ "${TARGET_USER_MODE:-deploy}" == "build" ]]; then
            echo "    Log in with the baked account: ${TARGET_USERNAME:-?}."
        else
            echo "    On first boot, the console wizard prompts to create your user account."
        fi
    else
        echo "    Attach the exported disk (.qcow2/.vdi/.vmdk/.vhdx) or raw .img to a new VM."
        if [[ "${TARGET_FIRMWARE:-uefi}" == "hybrid" ]]; then
            echo "    Hybrid image: boots on both BIOS and UEFI VMs."
        else
            echo "    UEFI-only image: create the VM with UEFI firmware."
        fi
        if [[ "${TARGET_USER_MODE:-deploy}" == "build" ]]; then
            echo "    Log in with the baked account: ${TARGET_USERNAME:-?}."
        else
            echo "    On first boot, the VM console wizard prompts to create your user account."
        fi
    fi
    echo
    if declare -F popos_print_cosmic_note >/dev/null 2>&1; then
        popos_print_cosmic_note
    fi
}
