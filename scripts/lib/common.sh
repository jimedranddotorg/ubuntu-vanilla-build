#!/bin/bash
# Shared configuration, host lifecycle, debootstrap, chroot preparation,
# package customization, and CLI/TUI resolution for ubuntu-vanilla-build.

UVB_SYSTEM_WORKSPACE_PARENT="/var/cache/ubuntu-vanilla-build"
HOST_ABORT_CLEANUP_DONE=0
DATE="$(TZ="UTC" date +"%y%m%d-%H%M%S")"
HOOKS_DIR="${HOOKS_DIR:-}"
PKG_CACHE_MOUNTED=0
SUDO_KEEPALIVE_PID=""
QEMU_USER_COPIED=""
DEVEL_CODENAME=""
DEVEL_VERSION=""

if [[ -n "${ADVANCED_MODE+x}" ]]; then
    ADVANCED_MODE_EXPLICIT=1
else
    ADVANCED_MODE_EXPLICIT=0
fi
ADVANCED_MODE="${ADVANCED_MODE:-0}"

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------
function assert_bool_var() {
    local name="$1" default="${2:-0}"
    local val="${!name:-$default}"
    case "$val" in
        0|1) ;;
        *)
            ui_err "${name} must be 0 or 1 (got: '${val}')."
            exit 1
            ;;
    esac
}

function cmd_find_index() {
    local cmd="$1" arr_name="$2" _help_fn="$3"
    local -n _arr="$arr_name"
    local i
    for ((i=0; i<${#_arr[*]}; i++)); do
        if [[ "${_arr[i]}" == "$cmd" ]]; then
            index=$i
            return
        fi
    done
    ui_err "Unknown stage command '${cmd}'. Supported commands: ${_arr[*]}. Run '$0 --help' for usage."
    exit 1
}

function parse_cmd_range() {
    local arr_name="$1" help_fn="$2"
    shift 2
    local -n _arr="$arr_name"

    if [[ $# == 0 ]]; then
        set -- "-"
    fi
    if [[ $# -gt 3 ]]; then
        ui_err "Too many stage arguments (got $#, expected at most 3: [start_cmd] [-] [end_cmd]). Run '$0 --help' for usage."
        exit 1
    fi

    local dash_flag=false
    start_index=0
    end_index=${#_arr[*]}
    local ii
    for ii in "$@"; do
        if [[ $ii == "-" ]]; then
            dash_flag=true
            continue
        fi
        cmd_find_index "$ii" "$arr_name" "$help_fn"
        if [[ $dash_flag == false ]]; then
            start_index=$index
        else
            end_index=$((index + 1))
        fi
    done
    if [[ $dash_flag == false ]]; then
        end_index=$((start_index + 1))
    fi
    if [[ $end_index -le $start_index ]]; then
        ui_err "Invalid stage range: '${_arr[end_index-1]}' comes before '${_arr[start_index]}'. Order is: ${_arr[*]}."
        exit 1
    fi
}

function host_priv() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

function setup_sudo_keepalive() {
    if [[ "${LAUNCHED_FROM_START_HERE:-0}" -eq 1 ]] || [[ "$(id -u)" -eq 0 ]]; then
        return 0
    fi
    ui_info "Requesting sudo credentials (kept alive for the entire build) ..."
    if ! sudo -v; then
        ui_err "Failed to obtain sudo credentials. The build requires sudo access."
        exit 1
    fi
    (
        sleep_pid=""
        trap '[[ -n "$sleep_pid" ]] && kill "$sleep_pid" 2>/dev/null || true; exit 0' TERM INT
        while sudo -v -n 2>/dev/null; do
            sleep 30 &
            sleep_pid=$!
            wait "$sleep_pid" 2>/dev/null || exit 0
        done
    ) </dev/null >/dev/null 2>&1 &
    SUDO_KEEPALIVE_PID=$!
}

function cleanup_sudo_keepalive() {
    if [[ -n "$SUDO_KEEPALIVE_PID" ]] && kill -0 "$SUDO_KEEPALIVE_PID" 2>/dev/null; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
        wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
    SUDO_KEEPALIVE_PID=""
}

function invoking_user_home() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        local h
        h="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
        if [[ -n "$h" ]]; then
            echo "$h"
            return 0
        fi
    fi
    echo "${HOME:-/root}"
}

function host_dpkg_arch() {
    if command -v dpkg >/dev/null 2>&1; then
        dpkg --print-architecture
        return 0
    fi
    case "$(uname -m)" in
        x86_64|amd64)   echo "amd64" ;;
        aarch64|arm64)  echo "arm64" ;;
        *)              uname -m ;;
    esac
}

function qemu_static_bin_for_arch() {
    local arch="$1"
    local -a candidates=()
    case "$arch" in
        arm64) candidates=(qemu-aarch64-static qemu-aarch64) ;;
        amd64) candidates=(qemu-x86_64-static qemu-x86_64) ;;
        *)     return 0 ;;
    esac
    local c
    for c in "${candidates[@]}"; do
        if command -v "$c" >/dev/null 2>&1; then
            echo "$c"
            return 0
        fi
    done
    echo "${candidates[0]}"
}

# ---------------------------------------------------------------------------
# Hook loader (modloader)
# ---------------------------------------------------------------------------
function run_hooks() {
    local subdir="$1"
    local hooks_base="${HOOKS_DIR:-$SCRIPT_DIR/hooks}"
    local hooks_path="$hooks_base/$subdir"

    if [[ ! -d "$hooks_path" ]]; then
        return 0
    fi

    local hook_files=()
    local f
    while IFS= read -r -d '' f; do
        hook_files+=("$f")
    done < <(find "$hooks_path" -maxdepth 1 -name '*.sh' -print0 2>/dev/null | sort -z)

    if [[ ${#hook_files[@]} -eq 0 ]]; then
        return 0
    fi

    ui_heading "Loading hooks: $subdir (${#hook_files[@]} mod(s) found)"
    local i=0
    for f in "${hook_files[@]}"; do
        i=$((i + 1))
        local name
        name="$(basename "$f")"
        if [[ ! -x "$f" ]]; then
            ui_warn "[hook $i/${#hook_files[@]}] $name -- skipped (not executable)"
            continue
        fi
        ui_info "[hook $i/${#hook_files[@]}] Loading: $name"
        bash -e "$f"
        ui_ok "[hook $i/${#hook_files[@]}] $name"
    done
}

function run_chroot_hooks() {
    local hooks_path="/root/hooks/chroot"

    if [[ ! -d "$hooks_path" ]]; then
        return 0
    fi

    local hook_files=()
    local f
    while IFS= read -r -d '' f; do
        hook_files+=("$f")
    done < <(find "$hooks_path" -maxdepth 1 -name '*.sh' -print0 2>/dev/null | sort -z)

    if [[ ${#hook_files[@]} -eq 0 ]]; then
        return 0
    fi

    echo "=====> Loading chroot hooks (${#hook_files[@]} mod(s) found)"
    local i=0
    for f in "${hook_files[@]}"; do
        i=$((i + 1))
        local name
        name="$(basename "$f")"
        if [[ ! -x "$f" ]]; then
            echo "  WARN  [hook $i/${#hook_files[@]}] $name -- skipped (not executable)"
            continue
        fi
        echo "  info  [hook $i/${#hook_files[@]}] Loading: $name"
        bash -e "$f"
        echo "  OK    [hook $i/${#hook_files[@]}] $name"
    done
}

# ---------------------------------------------------------------------------
# Defaults, Releases, Architecture & Mirrors
# ---------------------------------------------------------------------------
function set_defaults() {
    export TARGET_UBUNTU_VERSION="${TARGET_UBUNTU_VERSION:-}"
    export TARGET_UBUNTU_MIRROR="${TARGET_UBUNTU_MIRROR:-}"
    export TARGET_ARCH="${TARGET_ARCH:-}"
    export TARGET_KERNEL_FLAVOR="${TARGET_KERNEL_FLAVOR:-}"
    export TARGET_KERNEL_PACKAGE="${TARGET_KERNEL_PACKAGE:-}"
    export TARGET_DESKTOP="${TARGET_DESKTOP:-}"
    export TARGET_KDE_PACKAGE="${TARGET_KDE_PACKAGE:-}"
    export TARGET_MATE_PACKAGE="${TARGET_MATE_PACKAGE:-}"
    export TARGET_BRAVE_CHANNEL="${TARGET_BRAVE_CHANNEL:-}"
    # Boolean toggle vars remain unset here so ${VAR+x} distinguishes
    # "never specified" from "explicitly set to 0 or 1".
    export TARGET_NAME="${TARGET_NAME:-}"
    if [[ "${UVB_DISTRO}" == "popos" ]]; then
        export GRUB_LIVEBOOT_LABEL="${GRUB_LIVEBOOT_LABEL:-Try Pop!_OS without installing}"
    else
        export GRUB_LIVEBOOT_LABEL="${GRUB_LIVEBOOT_LABEL:-Try Ubuntu without installing}"
    fi
    export TARGET_IMAGE_PROFILE="${TARGET_IMAGE_PROFILE:-}"
    export TARGET_NETWORK_STACK="${TARGET_NETWORK_STACK:-}"
    if [[ "$UVB_OUTPUT_KIND" != "iso" ]]; then
        export TARGET_FIRMWARE="${TARGET_FIRMWARE:-}"
        export TARGET_DISK_SIZE_GB="${TARGET_DISK_SIZE_GB:-}"
        export TARGET_USER_MODE="${TARGET_USER_MODE:-}"
        export TARGET_USERNAME="${TARGET_USERNAME:-}"
        export TARGET_USER_PASSWORD="${TARGET_USER_PASSWORD:-}"
        export TARGET_USER_FULLNAME="${TARGET_USER_FULLNAME:-}"
        export TARGET_HOSTNAME="${TARGET_HOSTNAME:-}"
        export TARGET_IMG_ALLOC="${TARGET_IMG_ALLOC:-}"
        export TARGET_VM_FORMATS="${TARGET_VM_FORMATS:-}"
    fi
}

function default_mirror_for_target() {
    local distro="${1:-$UVB_DISTRO}"
    local arch="${2:-${TARGET_ARCH:-amd64}}"
    if [[ "$arch" == "arm64" ]]; then
        # Both Ubuntu arm64 and Pop!_OS arm64 base debootstrap use ports.ubuntu.com
        # (apt.pop-os.org/ubuntu only publishes amd64 packages).
        echo "https://ports.ubuntu.com/ubuntu-ports/"
    elif [[ "$distro" == "popos" ]]; then
        echo "https://apt.pop-os.org/ubuntu"
    else
        echo "https://archive.ubuntu.com/ubuntu/"
    fi
}

function resolve_mirror_default() {
    if [[ -n "${TARGET_UBUNTU_MIRROR:-}" ]]; then
        return 0
    fi
    export TARGET_UBUNTU_MIRROR
    TARGET_UBUNTU_MIRROR="$(default_mirror_for_target "$UVB_DISTRO" "${TARGET_ARCH:-amd64}")"
}

function resolve_devel_metadata() {
    [[ "${TARGET_UBUNTU_VERSION:-}" == "devel" ]] || return 0
    [[ -n "$DEVEL_CODENAME" && -n "$DEVEL_VERSION" ]] && return 0

    local base="${TARGET_UBUNTU_MIRROR:-$(default_mirror_for_target "$UVB_DISTRO" "${TARGET_ARCH:-amd64}")}"
    base="${base%/}"
    if command -v curl >/dev/null 2>&1; then
        local rel_hdr
        rel_hdr="$(curl -fsSL --max-time 8 "${base}/dists/devel/Release" 2>/dev/null | head -n 20 || true)"
        if [[ -n "$rel_hdr" ]]; then
            DEVEL_CODENAME="$(printf '%s\n' "$rel_hdr" | awk -F': ' '/^Codename:/ {print $2; exit}' | tr -d '\r')"
            DEVEL_VERSION="$(printf '%s\n' "$rel_hdr" | awk -F': ' '/^Version:/ {print $2; exit}' | tr -d '\r')"
        fi
    fi
    DEVEL_CODENAME="${DEVEL_CODENAME:-devel}"
    DEVEL_VERSION="${DEVEL_VERSION:-devel}"
}

function release_version() {
    case "$1" in
        noble)  echo "24.04" ;;
        resolute) echo "26.04" ;;
        devel)
            if [[ -n "${DEVEL_VERSION:-}" && "${DEVEL_VERSION}" != "devel" ]]; then
                echo "$DEVEL_VERSION"
            else
                echo "devel"
            fi
            ;;
        *)      echo "" ;;
    esac
}

function assert_supported_release() {
    case "${TARGET_UBUNTU_VERSION:-}" in
        jammy)
            ui_err "Ubuntu 22.04 LTS (jammy) support has been removed (standard support ends April 2027). Use noble, resolute${UVB_DISTRO:+$([[ "$UVB_DISTRO" == "ubuntu" ]] && echo ", or devel")}."
            return 1
            ;;
        noble|resolute)
            return 0
            ;;
        devel)
            if [[ "$UVB_DISTRO" == "popos" ]]; then
                ui_err "The rolling 'devel' release is only supported for Ubuntu builds, not Pop!_OS (Pop!_OS publishes LTS suites: noble, resolute)."
                return 1
            fi
            return 0
            ;;
        *)
            if [[ "$UVB_DISTRO" == "popos" ]]; then
                ui_err "TARGET_UBUNTU_VERSION must be noble or resolute (got: '${TARGET_UBUNTU_VERSION:-}')."
            else
                ui_err "TARGET_UBUNTU_VERSION must be noble, resolute, or devel (got: '${TARGET_UBUNTU_VERSION:-}')."
            fi
            return 1
            ;;
    esac
}

function normalize_arch_variant() {
    local arch="${TARGET_ARCH:-amd64}"
    arch="${arch,,}"
    case "$arch" in
        x86_64|x64) arch="amd64" ;;
        aarch64)    arch="arm64" ;;
    esac
    case "$arch" in
        amd64|arm64) ;;
        *)
            ui_err "TARGET_ARCH / --arch must be amd64 or arm64 (got: '${TARGET_ARCH:-}')."
            exit 1
            ;;
    esac
    export TARGET_ARCH="$arch"
}

function normalize_desktop_variant() {
    local desktop="${TARGET_DESKTOP:-gnome}"
    desktop="${desktop,,}"
    case "$desktop" in
        kde) desktop="kde-plasma" ;;
    esac
    if [[ ! "$desktop" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        ui_err "TARGET_DESKTOP must be a slug like cli, gnome, xfce, lxde, lxqt, mate, cinnamon, budgie, or kde-plasma (got: '${TARGET_DESKTOP:-}')."
        exit 1
    fi
    export TARGET_DESKTOP="$desktop"
}

function default_target_name() {
    local prefix="ubuntu"
    [[ "$UVB_DISTRO" == "popos" ]] && prefix="popos"
    local version flavor kind_tag=""
    version="$(release_version "${TARGET_UBUNTU_VERSION:-}")"
    if [[ "${TARGET_UBUNTU_VERSION:-}" == "devel" && "$version" == "devel" ]]; then
        version="devel"
    fi
    if [[ "${TARGET_IMAGE_PROFILE:-desktop}" == "cli" ]]; then
        flavor="cli"
    else
        flavor="${TARGET_DESKTOP:-gnome}"
    fi
    if [[ "$UVB_OUTPUT_KIND" != "iso" ]]; then
        kind_tag="-${UVB_IMAGE_KIND}"
    fi
    echo "${prefix}-${version}-${flavor}${kind_tag}-${TARGET_ARCH:-amd64}-${DATE}"
}

function set_target_kernel_package_from_flavor() {
    if [[ -n "${TARGET_KERNEL_PACKAGE:-}" ]]; then
        return 0
    fi

    assert_supported_release || exit 1

    if [[ "$UVB_DISTRO" == "popos" ]]; then
        case "${TARGET_KERNEL_FLAVOR:-}" in
            system76|generic|lowlatency) ;;
            *)
                ui_err "TARGET_KERNEL_FLAVOR must be system76, generic, or lowlatency (got: '${TARGET_KERNEL_FLAVOR:-}')."
                exit 1
                ;;
        esac
        if [[ "$TARGET_KERNEL_FLAVOR" == "system76" ]]; then
            if [[ "${TARGET_ARCH:-amd64}" == "arm64" ]]; then
                ui_err "linux-system76 is only published for amd64; use --kernel=generic or --kernel=lowlatency on arm64."
                exit 1
            fi
            export TARGET_KERNEL_PACKAGE="linux-system76"
            return 0
        fi
    else
        case "${TARGET_KERNEL_FLAVOR:-}" in
            generic|lowlatency) ;;
            *)
                ui_err "TARGET_KERNEL_FLAVOR must be generic or lowlatency (got: '${TARGET_KERNEL_FLAVOR:-}')."
                exit 1
                ;;
        esac
    fi

    # Rolling/devel has no -hwe-XX.04 metapackage; use linux-generic / linux-lowlatency.
    if [[ "${TARGET_UBUNTU_VERSION}" == "devel" ]]; then
        case "$TARGET_KERNEL_FLAVOR" in
            generic)    export TARGET_KERNEL_PACKAGE="linux-generic" ;;
            lowlatency) export TARGET_KERNEL_PACKAGE="linux-lowlatency" ;;
        esac
        return 0
    fi

    local hv
    hv="$(release_version "$TARGET_UBUNTU_VERSION")"
    case "$TARGET_KERNEL_FLAVOR" in
        generic)    export TARGET_KERNEL_PACKAGE="linux-generic-hwe-${hv}" ;;
        lowlatency) export TARGET_KERNEL_PACKAGE="linux-lowlatency-hwe-${hv}" ;;
    esac
}

# ---------------------------------------------------------------------------
# APT pins & package installation helpers
# ---------------------------------------------------------------------------
function block_snapd() {
    install -d /etc/apt/preferences.d
    cat <<'EOF' > /etc/apt/preferences.d/nosnap.pref
Package: snapd gnome-software-plugin-snap plasma-discover-backend-snap
Pin: release *
Pin-Priority: -1
EOF
}

function block_fwupd() {
    install -d /etc/apt/preferences.d
    cat <<'EOF' > /etc/apt/preferences.d/nofwupd-build.pref
# Build-time only: removed before the image is finalized.
Package: fwupd
Pin: release *
Pin-Priority: -1
EOF
}

function unblock_fwupd() {
    rm -f /etc/apt/preferences.d/nofwupd-build.pref
}

function apt_install_available() {
    local label="$1"
    shift

    local pkg candidate sim_out
    local -a installable=()
    local -a skipped=()
    local -a snapd_blocked=()
    local -a unresolved=()

    for pkg in "$@"; do
        candidate="$(apt-cache policy "$pkg" | awk '/Candidate:/ {print $2; exit}')"
        if [[ -z "$candidate" || "$candidate" == "(none)" ]]; then
            skipped+=("$pkg")
            continue
        fi
        if ! sim_out="$(apt-get -s install -y "$pkg" 2>&1)"; then
            unresolved+=("$pkg")
            continue
        fi
        if [[ "$sim_out" == Inst\ snapd* || "$sim_out" == *$'\nInst snapd '* || "$sim_out" == *$'\nInst snapd:'* ]]; then
            snapd_blocked+=("$pkg")
            continue
        fi
        installable+=("$pkg")
    done

    ((${#skipped[@]}))       && echo "=====> ${label}: skipping unavailable packages: ${skipped[*]}"
    ((${#unresolved[@]}))    && echo "=====> ${label}: skipping packages with unsatisfied dependencies: ${unresolved[*]}"
    ((${#snapd_blocked[@]})) && echo "=====> ${label}: skipping packages that would pull snapd: ${snapd_blocked[*]}"
    if ((${#installable[@]})); then
        echo "=====> ${label}: installing ${installable[*]}"
        apt-get install -y "${installable[@]}"
    else
        echo "=====> ${label}: no installable packages found"
    fi
}

function install_lightdm_desktop() {
    apt-get install -y "$@" xorg lightdm slick-greeter
}

# ---------------------------------------------------------------------------
# Desktops, Browsers, Pacstall, Optional Services (inside chroot)
# ---------------------------------------------------------------------------
function install_desktop_browsers() {
    local arch="${TARGET_ARCH:-amd64}"
    apt-get install -y software-properties-common

    install -d /usr/share/keyrings /etc/apt/sources.list.d /etc/apt/preferences.d

    echo "=====> Browser APT sources: Brave release, LibreWolf, Mozilla"
    curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg \
        https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg
    curl -fsSLo /etc/apt/sources.list.d/brave-browser-release.sources \
        https://brave-browser-apt-release.s3.brave.com/brave-browser.sources

    # Keep LibreWolf setup unchanged (per repository policy; no extrepo migration).
    curl -fsSL https://repo.librewolf.net/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/librewolf.gpg
    printf '%s\n' \
        "deb [arch=${arch} signed-by=/usr/share/keyrings/librewolf.gpg] https://repo.librewolf.net/ librewolf main" \
        > /etc/apt/sources.list.d/librewolf.list

    # Mozilla APT in modern deb822 .sources format (drop any old .list file on re-runs).
    rm -f /etc/apt/sources.list.d/mozilla.list
    wget -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O- \
        > /usr/share/keyrings/packages.mozilla.org.asc
    cat <<'EOF' > /etc/apt/sources.list.d/mozilla.sources
Types: deb
URIs: https://packages.mozilla.org/apt
Suites: mozilla
Components: main
Signed-By: /usr/share/keyrings/packages.mozilla.org.asc
EOF

    local ppa_suite="${TARGET_UBUNTU_VERSION}"
    if curl -fsIL "https://ppa.launchpadcontent.net/mozillateam/ppa/ubuntu/dists/${ppa_suite}/Release" >/dev/null 2>&1; then
        add-apt-repository ppa:mozillateam/ppa -y
    else
        echo "  WARN  ppa:mozillateam/ppa has no pocket for '${ppa_suite}' yet; skipping PPA (Firefox release from packages.mozilla.org remains available)." >&2
    fi

    cat <<'EOF' > /etc/apt/preferences.d/mozilla
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000

Package: firefox
Pin: release o=Ubuntu
Pin-Priority: -1

Package: firefox
Pin: origin ppa.launchpadcontent.net
Pin-Priority: -1

Package: firefox-esr
Pin: origin ppa.launchpadcontent.net
Pin-Priority: 1000

Package: thunderbird
Pin: origin ppa.launchpadcontent.net
Pin-Priority: 1000
EOF

    apt-get update

    case "${TARGET_BRAVE_CHANNEL:-release}" in
        release)
            echo "=====> install: Brave stable"
            apt-get install -y brave-browser
            ;;
        origin)
            echo "=====> install: Brave Origin"
            apt-get install -y brave-origin
            ;;
        none)
            echo "=====> Brave: not pre-installed (APT source remains)"
            ;;
        *)
            >&2 echo "TARGET_BRAVE_CHANNEL must be none, release, or origin (got: '${TARGET_BRAVE_CHANNEL:-}')."
            exit 1
            ;;
    esac

    if [[ "${TARGET_LIBREWOLF:-0}" == "1" ]]; then
        apt-get install -y librewolf
    else
        echo "=====> LibreWolf: not pre-installed (APT repo remains)"
    fi

    if [[ "${UVB_DISTRO}" == "popos" && "${TARGET_FIREFOX_POPOS:-0}" == "1" ]]; then
        install_firefox_from_popos
    elif [[ "${TARGET_FIREFOX:-0}" == "1" ]]; then
        apt-get install -y --allow-downgrades firefox
    else
        echo "=====> Firefox: not pre-installed (Mozilla repo + pin remain)"
    fi

    if [[ "${TARGET_FIREFOX_ESR:-0}" == "1" ]]; then
        apt_install_available "Firefox ESR" firefox-esr
    else
        echo "=====> Firefox ESR: not pre-installed"
    fi

    if [[ "${TARGET_THUNDERBIRD:-0}" == "1" ]]; then
        apt_install_available "Thunderbird" thunderbird
    else
        echo "=====> Thunderbird: not pre-installed"
    fi
}

function install_pacstall_ppr() {
    if [[ "${TARGET_PACSTALL:-1}" != "1" ]]; then
        echo "=====> Pacstall: skipped (TARGET_PACSTALL=0)"
        return 0
    fi

    echo "=====> Pacstall: adding Chaotic PPR repository (https://pacstall.dev/q/ppr) and installing pacstall"
    # pacstall.dev/q/ppr prompts twice:
    #   1) "Do you want foreign architectures enabled? [Y/n]:" -> n
    #   2) select component from (ubuntu-latest, ubuntu-rolling, ubuntu-develop):
    #      1 = ubuntu-latest (noble/resolute), 3 = ubuntu-develop (devel).
    local ppr_comp_idx="1"
    if [[ "${TARGET_UBUNTU_VERSION:-}" == "devel" ]]; then
        ppr_comp_idx="3"
    fi

    local ppr_script
    ppr_script="$(curl -fsSL https://pacstall.dev/q/ppr)"
    printf 'n\n%s\n' "$ppr_comp_idx" | bash -c "$ppr_script"
    if [[ ! -s /etc/apt/sources.list.d/ppr.list ]]; then
        >&2 echo "ERROR: Chaotic PPR setup did not create /etc/apt/sources.list.d/ppr.list."
        exit 1
    fi
    apt-get update
    apt-get install -y pacstall
}

function customize_image() {
    block_snapd
    block_fwupd

    case "${TARGET_DESKTOP:-gnome}" in
        cli)
            echo "=====> profile: CLI/TTY-only -- no desktop environment installed"
            ;;
        gnome)
            echo "=====> desktop flavor: gnome"
            if [[ "${TARGET_GNOME_INSTALL_RECOMMENDS:-0}" == "1" ]]; then
                echo "=====> gnome package recommends: enabled"
                apt-get install -y vanilla-gnome-desktop gnome-console
            else
                echo "=====> gnome package recommends: disabled (default lightweight mode)"
                apt-get install -y --no-install-recommends vanilla-gnome-desktop gnome-console
            fi
            ;;
        xfce)
            echo "=====> desktop flavor: xfce (PipeWire audio)"
            install_lightdm_desktop \
                xfce4 \
                xfce4-goodies \
                xfce4-terminal \
                xfce4-notifyd \
                xfce4-power-manager \
                xfce4-pulseaudio-plugin \
                xfce4-screensaver \
                xfce4-taskmanager \
                xfce4-indicator-plugin \
                xfce4-whiskermenu-plugin \
                thunar-archive-plugin \
                thunar-media-tags-plugin \
                thunar-volman \
                tumbler \
                gvfs \
                gvfs-backends \
                gvfs-fuse \
                catfish \
                menulibre \
                mugshot \
                gigolo \
                galculator \
                xarchiver \
                blueman \
                pipewire-pulse \
                wireplumber \
                pavucontrol \
                synaptic \
                xdg-user-dirs \
                xdg-user-dirs-gtk \
                fonts-ubuntu \
                fonts-noto-core \
                hunspell-en-us \
                onboard \
                labwc
            ;;
        lxde)
            echo "=====> desktop flavor: lxde"
            install_lightdm_desktop lxde
            ;;
        lxqt)
            echo "=====> desktop flavor: lxqt"
            apt-get install -y lxqt sddm xorg
            ;;
        mate)
            echo "=====> desktop flavor: mate (${TARGET_MATE_PACKAGE:-mate-desktop-environment})"
            install_lightdm_desktop "${TARGET_MATE_PACKAGE:-mate-desktop-environment}"
            if [[ "${TARGET_MATE_EXTRAS:-0}" == "1" ]]; then
                apt-get install -y mate-desktop-environment-extras
            fi
            ;;
        cinnamon)
            echo "=====> desktop flavor: cinnamon"
            install_lightdm_desktop cinnamon-desktop-environment
            ;;
        budgie)
            echo "=====> desktop flavor: budgie"
            install_lightdm_desktop budgie-desktop-environment
            ;;
        kde-plasma)
            echo "=====> desktop flavor: kde-plasma"
            case "${TARGET_KDE_PACKAGE:-kde-standard}" in
                kde-full|kde-standard|kde-plasma-desktop)
                    apt-get install -y "${TARGET_KDE_PACKAGE:-kde-standard}"
                    ;;
                *)
                    >&2 echo "TARGET_KDE_PACKAGE must be kde-full, kde-standard, or kde-plasma-desktop (got: '${TARGET_KDE_PACKAGE:-}')."
                    exit 1
                    ;;
            esac
            echo "=====> SDDM: forcing Plasma's Breeze theme"
            apt-get install -y --no-install-recommends sddm sddm-theme-breeze
            install -d /etc/sddm.conf.d
            cat <<'EOF' > /etc/sddm.conf.d/10-ubuntu-vanilla-breeze.conf
[Theme]
Current=breeze
EOF
            cat <<'EOF' > /etc/apt/preferences.d/no-slick-sddm.pref
# Keep Plasma's stock Breeze greeter theme.
Package: *slick*sddm* *sddm*slick*
Pin: release *
Pin-Priority: -1
EOF
            local _extra_sddm_themes
            _extra_sddm_themes="$(dpkg-query -W -f='${Package}\n' 'sddm-theme-*' 2>/dev/null | grep -vx 'sddm-theme-breeze' || true)"
            if [[ -n "$_extra_sddm_themes" ]]; then
                # shellcheck disable=SC2086
                apt-get purge -y $_extra_sddm_themes
            fi
            apt-get install -y plasma-discover plasma-discover-backend-flatpak
            ;;
        *)
            >&2 echo "Unsupported desktop variant '${TARGET_DESKTOP:-}'."
            exit 1
            ;;
    esac

    if [[ "${TARGET_DESKTOP:-gnome}" != "cli" ]]; then
        apt-get install -y plymouth plymouth-label plymouth-theme-ubuntu-text
    fi

    apt-get install -y curl wget ca-certificates gnupg

    if [[ "${TARGET_DESKTOP:-gnome}" != "cli" ]]; then
        install_desktop_browsers
    else
        echo "=====> profile: CLI/TTY-only -- skipping desktop browsers and their APT repositories"
    fi

    install_pacstall_ppr

    if [[ "${TARGET_DESKTOP:-gnome}" != "cli" && "${TARGET_UBUNTU_STUDIO:-0}" == "1" ]]; then
        apt_install_available "Ubuntu Studio metapackages" \
            ubuntustudio-audio \
            ubuntustudio-graphics \
            ubuntustudio-photography \
            ubuntustudio-publishing \
            ubuntustudio-video \
            ubuntustudio-wallpapers \
            ubuntustudio-menu \
            ubuntu-edu-music
    fi

    if [[ "$UVB_DISTRO" == "popos" && "${TARGET_SYSTEM76_DRIVER:-0}" == "1" ]]; then
        install_popos_system76_driver
    fi

    if [[ "${TARGET_FWUPD:-0}" == "1" ]]; then
        echo "=====> fwupd: pre-installing on request (lifting the build-time block)"
        unblock_fwupd
        apt-get install -y fwupd
    else
        echo "=====> fwupd: not pre-installed (blocked during build; 'sudo apt install fwupd' works after install)"
    fi

    if [[ "${TARGET_OPENSSH_SERVER:-0}" == "1" ]]; then
        echo "=====> OpenSSH server: pre-installing"
        apt-get install -y openssh-server
        cat <<'EOF' > /etc/systemd/system/ssh-host-keys-regen.service
[Unit]
Description=Regenerate missing SSH host keys
Before=ssh.service
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl enable ssh-host-keys-regen.service
    else
        echo "=====> OpenSSH server: not pre-installed"
    fi

    if [[ "${TARGET_COCKPIT:-0}" == "1" ]]; then
        echo "=====> Cockpit: pre-installing from ${TARGET_UBUNTU_VERSION}-backports"
        if ! apt-get install -y -t "${TARGET_UBUNTU_VERSION}-backports" cockpit; then
            echo "=====> Cockpit: no candidate in ${TARGET_UBUNTU_VERSION}-backports; installing from main archive"
            apt-get install -y cockpit
        fi
    else
        echo "=====> Cockpit: not pre-installed"
    fi

    apt-get install -y git vim nano less

    if [[ "${TARGET_DESKTOP:-gnome}" != "cli" ]]; then
        apt-get install -y flatpak
        flatpak remote-add --if-not-exists --system flathub \
            https://flathub.org/repo/flathub.flatpakrepo
    fi

    if [[ "${TARGET_DESKTOP:-gnome}" == "gnome" ]]; then
        apt-get install -y gnome-software gnome-software-plugin-flatpak
    fi

    apt-get purge -y --ignore-missing \
        transmission-gtk \
        transmission-common \
        aisleriot \
        hitori

    if [[ "${TARGET_DESKTOP:-gnome}" == "gnome" ]]; then
        apt-get purge -y --ignore-missing \
            gnome-mahjongg \
            gnome-mines \
            gnome-sudoku
    fi

    if [[ "$UVB_OUTPUT_KIND" == "iso" ]]; then
        if dpkg -s calamares-slideshow-ubuntu &>/dev/null; then
            apt-get purge -y calamares-slideshow-ubuntu
        fi
    fi
}

# ---------------------------------------------------------------------------
# Workspace, mounts, package cache, cleanup
# ---------------------------------------------------------------------------
function check_host_user() {
    local ID="" ID_LIKE=""

    if [[ "$(uname -s)" == "Darwin" ]]; then
        ui_err "Direct execution of ${SCRIPT_NAME} on macOS is unsupported (Linux debootstrap/chroot/loop tools are required)."
        ui_info "Run './start-here.sh' from the repository root instead -- it automatically launches inside a native-arch Linux container (OrbStack / Docker Desktop / Colima / Lima) for both Intel and Apple Silicon Macs."
        exit 1
    fi

    if [[ ! -r /etc/os-release ]]; then
        ui_err "/etc/os-release is missing or unreadable. Run on Ubuntu or Debian (or derivative)."
        exit 1
    fi
    # shellcheck source=/dev/null
    . /etc/os-release

    if [[ "${ID:-}" == "ubuntu" ]] || [[ "${ID_LIKE:-}" == *ubuntu* ]]; then
        return 0
    fi

    if [[ "${ID:-}" == "debian" ]] || [[ "${ID_LIKE:-}" == *debian* ]]; then
        if [[ "${ID:-}" == "debian" ]] && ! dpkg -s ubuntu-archive-keyring &>/dev/null; then
            ui_err "On Debian, install the Ubuntu archive keyring first: sudo apt install ubuntu-archive-keyring"
            exit 1
        fi
        return 0
    fi

    ui_err "Unsupported host OS (ID='${ID:-unknown}', ID_LIKE='${ID_LIKE:-}')."
    exit 1
}

function resolve_package_cache_dir() {
    local base_cache
    if [[ -n "${XDG_CACHE_HOME:-}" ]]; then
        base_cache="${XDG_CACHE_HOME%/}"
    else
        base_cache="$(invoking_user_home)/.cache"
    fi
    local distro_dir="ubuntu-vanilla-build"
    [[ "$UVB_DISTRO" == "popos" ]] && distro_dir="popos-vanilla-build"
    if [[ -n "${UVB_APT_CACHE_SUFFIX:-}" ]]; then
        echo "${base_cache}/${distro_dir}/apt-cache-${UVB_APT_CACHE_SUFFIX}"
    else
        echo "${base_cache}/${distro_dir}/apt-cache"
    fi
}

function mount_package_cache() {
    if [[ "${ADVANCED_MODE:-0}" != "1" ]]; then
        return 0
    fi
    local cache_dir chroot_apt_cache
    cache_dir="$(resolve_package_cache_dir)"
    chroot_apt_cache="$WORKSPACE_CHROOT/var/cache/apt/archives"

    host_priv mkdir -p "$cache_dir"
    host_priv mkdir -p "$chroot_apt_cache"

    if mountpoint -q "$chroot_apt_cache" 2>/dev/null; then
        PKG_CACHE_MOUNTED=1
        return 0
    fi

    ui_info "[advanced] Mounting package cache: $cache_dir"
    host_priv mount --bind "$cache_dir" "$chroot_apt_cache"
    PKG_CACHE_MOUNTED=1
}

function unmount_package_cache() {
    if [[ "$PKG_CACHE_MOUNTED" -eq 0 ]]; then
        return 0
    fi
    local chroot_apt_cache="$WORKSPACE_CHROOT/var/cache/apt/archives"
    if mountpoint -q "$chroot_apt_cache" 2>/dev/null; then
        ui_info "[advanced] Unmounting package cache"
        host_priv umount -l "$chroot_apt_cache" 2>/dev/null || true
    fi
    PKG_CACHE_MOUNTED=0
}

function ensure_workspace_root() {
    host_priv mkdir -p "$WORKSPACE_DIR"
}

function clean_workspace() {
    if [[ -e "${WORKSPACE_DIR:-}" ]]; then
        echo "=====> removing workspace ..."
        host_priv rm -rf "$WORKSPACE_DIR"
    fi
}

function chroot_enter_setup() {
    host_priv mount --bind /dev "$WORKSPACE_CHROOT/dev"
    host_priv mount --bind /run "$WORKSPACE_CHROOT/run"
    host_priv chroot "$WORKSPACE_CHROOT" mount none -t proc /proc
    host_priv chroot "$WORKSPACE_CHROOT" mount none -t sysfs /sys
    host_priv chroot "$WORKSPACE_CHROOT" mount none -t devpts /dev/pts
}

function chroot_exit_teardown() {
    [[ -z "${WORKSPACE_CHROOT:-}" ]] && return 0
    local _mp _rc
    for _mp in "$WORKSPACE_CHROOT/dev/pts" "$WORKSPACE_CHROOT/proc" "$WORKSPACE_CHROOT/sys" "$WORKSPACE_CHROOT/run" "$WORKSPACE_CHROOT/dev"; do
        if mountpoint -q "$_mp" 2>/dev/null; then
            _rc=0
            host_priv umount -l "$_mp" 2>/dev/null || _rc=$?
            if [[ $_rc -ne 0 ]]; then
                echo "  WARN  umount -l '$_mp' failed (exit $_rc); mount may be stale" >&2
            fi
        fi
    done
}

function host_abort_cleanup() {
    if [[ "${HOST_ABORT_CLEANUP_DONE:-0}" -eq 1 ]]; then
        return 0
    fi
    HOST_ABORT_CLEANUP_DONE=1
    if declare -F detach_image_loop >/dev/null 2>&1; then
        detach_image_loop || true
    fi
    chroot_exit_teardown || true
    unmount_package_cache || true
    if [[ -n "${QEMU_USER_COPIED:-}" && -f "${QEMU_USER_COPIED}" ]]; then
        host_priv rm -f "${QEMU_USER_COPIED}" 2>/dev/null || true
    fi
    if [[ "${ADVANCED_MODE:-0}" == "1" ]]; then
        echo "=====> [advanced] Workspace preserved at: ${WORKSPACE_DIR:-unknown}" >&2
        echo "=====> [advanced] Re-run individual stages (e.g. run_chroot) to continue." >&2
    else
        echo "=====> unmounting chroot bind mounts and removing workspace ..." >&2
        if [[ -n "${WORKSPACE_DIR:-}" ]]; then
            clean_workspace || true
        fi
    fi
}

function host_build_exit_trap() {
    local _st=$?
    cleanup_sudo_keepalive || true
    if [[ "$_st" -ne 0 ]] && [[ "${HOST_ABORT_CLEANUP_DONE:-0}" -eq 0 ]]; then
        host_abort_cleanup
    fi
    exit "$_st"
}

function host_build_signal_trap() {
    local code="$1"
    if [[ "${HOST_ABORT_CLEANUP_DONE:-0}" -eq 1 ]]; then
        exit "$code"
    fi
    host_abort_cleanup
    exit "$code"
}

function path_on_windows_mount() {
    local path="$1" probe="$1" fs_type
    while [[ -n "$probe" && "$probe" != "/" && ! -e "$probe" ]]; do
        probe="$(dirname "$probe")"
    done
    [[ -z "$probe" ]] && probe="/"
    fs_type="$(df -T "$probe" 2>/dev/null | awk 'NR==2 {print tolower($2)}')"
    [[ "$path" == /mnt/* ]] || [[ "$path" == /media/* ]] || \
        [[ "$fs_type" == "9p" ]] || [[ "$fs_type" == "drvfs" ]]
}

function workspace_subdir_name() {
    local suffix=""
    [[ "$UVB_DISTRO" == "popos" ]] && suffix="-popos"
    case "$UVB_OUTPUT_KIND" in
        iso)       echo "workspace${suffix}" ;;
        cloud)     echo "workspace${suffix}-img" ;;
        vm)        echo "workspace${suffix}-vm" ;;
        removable) echo "workspace${suffix}-removable" ;;
    esac
}

function default_config_filename() {
    local suffix=""
    [[ "$UVB_DISTRO" == "popos" ]] && suffix="-popos"
    case "$UVB_OUTPUT_KIND" in
        iso)       echo "build${suffix}.cfg" ;;
        cloud)     echo "build${suffix}-img.cfg" ;;
        vm)        echo "build${suffix}-vm.cfg" ;;
        removable) echo "build${suffix}-removable.cfg" ;;
    esac
}

function resolve_workspace_paths() {
    local user_home
    user_home="$(invoking_user_home)"

    local interactive_advanced=0
    if [[ "${ADVANCED_MODE:-0}" == "1" ]] && prompts_enabled; then
        interactive_advanced=1
    fi

    local ws_parent=""
    if [[ -n "${UBUNTU_VANILLA_WORKSPACE:-}" ]]; then
        ws_parent="${UBUNTU_VANILLA_WORKSPACE%/}"
        ui_info "Workspace parent (UBUNTU_VANILLA_WORKSPACE): $ws_parent" >&2
    elif [[ "${ADVANCED_MODE:-0}" == "1" ]]; then
        local ws_default="$user_home/uvb-workspace"
        if [[ "$interactive_advanced" -eq 1 ]]; then
            ui_input "Workspace" "Workspace directory" "$ws_default"
            ws_parent="$UI_REPLY"
        else
            ws_parent="$ws_default"
        fi
        ws_parent="${ws_parent%/}"
    else
        ws_parent="$UVB_SYSTEM_WORKSPACE_PARENT"
    fi
    [[ -z "$ws_parent" ]] && ws_parent="/"

    if path_on_windows_mount "$ws_parent"; then
        ui_warn "$ws_parent is on a Windows/WSL mount -- debootstrap cannot unpack reliably there; using $UVB_SYSTEM_WORKSPACE_PARENT."
        ws_parent="$UVB_SYSTEM_WORKSPACE_PARENT"
    fi

    local ws_sub
    ws_sub="$(workspace_subdir_name)"
    if [[ -n "${UVB_RUN_ID:-}" ]]; then
        ws_sub="${ws_sub}-${UVB_RUN_ID}"
    fi
    WORKSPACE_DIR="${ws_parent%/}/${ws_sub}"
    WORKSPACE_CHROOT="$WORKSPACE_DIR/chroot"
    WORKSPACE_IMAGE="$WORKSPACE_DIR/image"

    if [[ -n "${UVB_OUTPUT_DIR:-}" ]]; then
        OUTPUT_DIR="${UVB_OUTPUT_DIR%/}"
        ui_info "Output directory (UVB_OUTPUT_DIR): $OUTPUT_DIR" >&2
    elif [[ "$interactive_advanced" -eq 1 ]]; then
        ui_input "Output directory" "Output directory for the finished artifact" "$user_home"
        OUTPUT_DIR="${UI_REPLY%/}"
    else
        OUTPUT_DIR="$user_home"
    fi
    [[ -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="/"

    if [[ "${TMPDIR:-}" == /mnt/* ]] || [[ "${TMPDIR:-}" == /media/* ]]; then
        export TMPDIR=/tmp
    fi
}

function ensure_output_dir() {
    if ! mkdir -p "$OUTPUT_DIR" 2>/dev/null; then
        host_priv mkdir -p "$OUTPUT_DIR"
    fi
}

# ---------------------------------------------------------------------------
# Host setup, debootstrap, run_chroot
# ---------------------------------------------------------------------------
function host_qemu_user_packages() {
    if apt-cache show qemu-user-static >/dev/null 2>&1; then
        printf '%s\n' qemu-user-static
    else
        printf '%s\n' qemu-user qemu-user-binfmt
    fi
}

function host_required_packages() {
    local -a deps=(debootstrap)
    case "$UVB_OUTPUT_KIND" in
        iso)       deps+=(squashfs-tools xorriso) ;;
        cloud|removable) deps+=(parted dosfstools e2fsprogs rsync) ;;
        vm)        deps+=(parted dosfstools e2fsprogs rsync qemu-utils) ;;
    esac
    if [[ "${TARGET_ARCH:-amd64}" != "$(host_dpkg_arch)" ]]; then
        local qpkg
        while IFS= read -r qpkg; do
            deps+=("$qpkg")
        done < <(host_qemu_user_packages)
    fi
    printf '%s\n' "${deps[@]}"
}

function setup_host() {
    echo "=====> running setup_host ..."

    local -a _host_deps=()
    mapfile -t _host_deps < <(host_required_packages)

    local skip_install=0
    if [[ "${LAUNCHED_FROM_START_HERE:-0}" -eq 1 ]] && command -v dpkg &>/dev/null && [[ -r /etc/os-release ]]; then
        local ID="" ID_LIKE=""
        # shellcheck source=/dev/null
        . /etc/os-release
        if [[ "${ID:-}" == "ubuntu" ]] || [[ "${ID_LIKE:-}" == *ubuntu* ]] || \
           [[ "${ID:-}" == "debian" ]] || [[ "${ID_LIKE:-}" == *debian* ]]; then
            if dpkg -s "${_host_deps[@]}" &>/dev/null; then
                skip_install=1
                if { [[ "${ID:-}" == "debian" ]] || [[ "${ID_LIKE:-}" == *debian* ]]; } && \
                   { [[ "${ID:-}" != "ubuntu" ]] && [[ "${ID_LIKE:-}" != *ubuntu* ]]; }; then
                    if ! dpkg -s ubuntu-archive-keyring &>/dev/null; then
                        skip_install=0
                    fi
                fi
            fi
        fi
    fi

    if [[ "$skip_install" -eq 1 ]]; then
        echo "=====> Host dependencies already installed. Skipping APT update and installation."
    else
        host_priv apt-get update
        host_priv apt-get install -y "${_host_deps[@]}"
    fi

    if [[ "${ADVANCED_MODE:-0}" == "1" ]] && [[ -d "$WORKSPACE_CHROOT" ]]; then
        echo "=====> [advanced] Reusing existing workspace: $WORKSPACE_DIR"
    else
        clean_workspace
        ensure_workspace_root
        host_priv mkdir -p "$WORKSPACE_CHROOT"
    fi
}

function debootstrap() {
    if [[ "${ADVANCED_MODE:-0}" == "1" ]] && [[ -f "$WORKSPACE_CHROOT/etc/os-release" ]]; then
        echo "=====> [advanced] Chroot already bootstrapped at $WORKSPACE_CHROOT -- skipping debootstrap."
        echo "=====> [advanced] Delete the workspace to force a fresh bootstrap."
        return 0
    fi

    local arch="${TARGET_ARCH:-amd64}"
    local host_arch
    host_arch="$(host_dpkg_arch)"
    local -a db_args=(--arch="$arch" --variant=minbase)

    # Check if host debootstrap has a script for TARGET_UBUNTU_VERSION (e.g. devel
    # or a newly branched codename on older hosts); fall back to gutsy script.
    local db_script=""
    if [[ ! -e "/usr/share/debootstrap/scripts/${TARGET_UBUNTU_VERSION}" ]] && \
       [[ -f "/usr/share/debootstrap/scripts/gutsy" ]]; then
        db_script="/usr/share/debootstrap/scripts/gutsy"
    fi

    echo "=====> running debootstrap (arch=${arch}, suite=${TARGET_UBUNTU_VERSION}) ..."
    if [[ "$arch" != "$host_arch" ]]; then
        local qbin
        qbin="$(qemu_static_bin_for_arch "$arch")"
        if [[ -z "$qbin" ]] || ! command -v "$qbin" >/dev/null 2>&1; then
            ui_err "Cross-building '${arch}' on '${host_arch}' requires '${qbin}' (install 'qemu-user-static' or 'qemu-user-binfmt')."
            exit 1
        fi
        # Two-stage foreign bootstrap ensures qemu static binary is present inside chroot
        # even if host binfmt_misc lacks the F (fix-binary) flag.
        host_priv debootstrap --foreign "${db_args[@]}" "$TARGET_UBUNTU_VERSION" "$WORKSPACE_CHROOT" "$TARGET_UBUNTU_MIRROR" ${db_script:+"$db_script"}
        host_priv install -m 0755 "$(command -v "$qbin")" "$WORKSPACE_CHROOT/usr/bin/$qbin"
        QEMU_USER_COPIED="$WORKSPACE_CHROOT/usr/bin/$qbin"
        host_priv chroot "$WORKSPACE_CHROOT" /debootstrap/debootstrap --second-stage
    else
        host_priv debootstrap "${db_args[@]}" "$TARGET_UBUNTU_VERSION" "$WORKSPACE_CHROOT" "$TARGET_UBUNTU_MIRROR" ${db_script:+"$db_script"}
    fi
}

function run_chroot() {
    echo "=====> running run_chroot ..."

    WORKSPACE_CHROOT="$WORKSPACE_CHROOT" run_hooks pre-chroot

    local arch="${TARGET_ARCH:-amd64}"
    local host_arch
    host_arch="$(host_dpkg_arch)"
    if [[ "$arch" != "$host_arch" ]]; then
        local qbin
        qbin="$(qemu_static_bin_for_arch "$arch")"
        if [[ -n "$qbin" ]] && command -v "$qbin" >/dev/null 2>&1 && [[ ! -x "$WORKSPACE_CHROOT/usr/bin/$qbin" ]]; then
            host_priv install -m 0755 "$(command -v "$qbin")" "$WORKSPACE_CHROOT/usr/bin/$qbin"
            QEMU_USER_COPIED="$WORKSPACE_CHROOT/usr/bin/$qbin"
        fi
    fi

    chroot_enter_setup
    mount_package_cache

    host_priv cp "$SCRIPT_DIR/$SCRIPT_NAME" "$WORKSPACE_CHROOT/root/build.sh"
    host_priv chmod +x "$WORKSPACE_CHROOT/root/build.sh"
    host_priv rm -rf "$WORKSPACE_CHROOT/root/lib"
    host_priv cp -a "$SCRIPT_DIR/lib" "$WORKSPACE_CHROOT/root/lib"

    if [[ "$UVB_OUTPUT_KIND" == "iso" ]]; then
        host_priv rm -rf "$WORKSPACE_CHROOT/root/calamares-config"
        local calamares_src="$SCRIPT_DIR/calamares"
        [[ "$UVB_DISTRO" == "popos" ]] && calamares_src="$SCRIPT_DIR/calamares-popos"
        if [[ -d "$calamares_src" ]]; then
            host_priv cp -a "$calamares_src" "$WORKSPACE_CHROOT/root/calamares-config"
        fi
        if [[ -f "$SCRIPT_DIR/cli-installer/install-system" ]]; then
            host_priv install -m 0755 "$SCRIPT_DIR/cli-installer/install-system" "$WORKSPACE_CHROOT/root/install-system"
        fi
    fi

    host_priv rm -rf "$WORKSPACE_CHROOT/root/hooks"
    local _hooks_base="${HOOKS_DIR:-$SCRIPT_DIR/hooks}"
    if [[ -d "$_hooks_base/chroot" ]]; then
        host_priv mkdir -p "$WORKSPACE_CHROOT/root/hooks"
        host_priv cp -a "$_hooks_base/chroot" "$WORKSPACE_CHROOT/root/hooks/chroot"
    fi

    host_priv chroot "$WORKSPACE_CHROOT" /usr/bin/env \
        DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-readline}" \
        UVB_DISTRO="${UVB_DISTRO}" \
        UVB_OUTPUT_KIND="${UVB_OUTPUT_KIND}" \
        UVB_IMAGE_KIND="${UVB_IMAGE_KIND}" \
        TARGET_UBUNTU_VERSION="${TARGET_UBUNTU_VERSION}" \
        TARGET_UBUNTU_MIRROR="${TARGET_UBUNTU_MIRROR}" \
        TARGET_ARCH="${TARGET_ARCH:-amd64}" \
        TARGET_KERNEL_FLAVOR="${TARGET_KERNEL_FLAVOR:-}" \
        TARGET_KERNEL_PACKAGE="${TARGET_KERNEL_PACKAGE:-}" \
        TARGET_DESKTOP="${TARGET_DESKTOP:-gnome}" \
        TARGET_KDE_PACKAGE="${TARGET_KDE_PACKAGE:-kde-standard}" \
        TARGET_MATE_PACKAGE="${TARGET_MATE_PACKAGE:-mate-desktop-environment}" \
        TARGET_MATE_EXTRAS="${TARGET_MATE_EXTRAS:-0}" \
        TARGET_BRAVE_CHANNEL="${TARGET_BRAVE_CHANNEL:-release}" \
        TARGET_LIBREWOLF="${TARGET_LIBREWOLF:-0}" \
        TARGET_FIREFOX="${TARGET_FIREFOX:-0}" \
        TARGET_FIREFOX_ESR="${TARGET_FIREFOX_ESR:-0}" \
        TARGET_FIREFOX_POPOS="${TARGET_FIREFOX_POPOS:-0}" \
        TARGET_THUNDERBIRD="${TARGET_THUNDERBIRD:-0}" \
        TARGET_UBUNTU_STUDIO="${TARGET_UBUNTU_STUDIO:-0}" \
        TARGET_PACSTALL="${TARGET_PACSTALL:-1}" \
        TARGET_SYSTEM76_DRIVER="${TARGET_SYSTEM76_DRIVER:-0}" \
        TARGET_FWUPD="${TARGET_FWUPD:-0}" \
        TARGET_OPENSSH_SERVER="${TARGET_OPENSSH_SERVER:-0}" \
        TARGET_COCKPIT="${TARGET_COCKPIT:-0}" \
        TARGET_LOCALE="${TARGET_LOCALE:-}" \
        TARGET_KEYBOARD_LAYOUT="${TARGET_KEYBOARD_LAYOUT:-}" \
        TARGET_KEYBOARD_VARIANT="${TARGET_KEYBOARD_VARIANT:-}" \
        TARGET_GNOME_INSTALL_RECOMMENDS="${TARGET_GNOME_INSTALL_RECOMMENDS:-0}" \
        TARGET_NAME="${TARGET_NAME}" \
        GRUB_LIVEBOOT_LABEL="${GRUB_LIVEBOOT_LABEL:-}" \
        TARGET_INSTALLER="${TARGET_INSTALLER:-calamares}" \
        TARGET_PACKAGE_REMOVE="${TARGET_PACKAGE_REMOVE:-}" \
        TARGET_IMAGE_PROFILE="${TARGET_IMAGE_PROFILE:-desktop}" \
        TARGET_NETWORK_STACK="${TARGET_NETWORK_STACK:-network-manager}" \
        TARGET_FIRMWARE="${TARGET_FIRMWARE:-uefi}" \
        DEVEL_CODENAME="${DEVEL_CODENAME:-}" \
        DEVEL_VERSION="${DEVEL_VERSION:-}" \
        /root/build.sh --chroot-internal -

    host_priv rm -f "$WORKSPACE_CHROOT/root/build.sh" "$WORKSPACE_CHROOT/root/install-system"
    host_priv rm -rf "$WORKSPACE_CHROOT/root/lib" "$WORKSPACE_CHROOT/root/calamares-config" "$WORKSPACE_CHROOT/root/hooks"
    if [[ -n "${QEMU_USER_COPIED:-}" && -f "${QEMU_USER_COPIED}" ]]; then
        host_priv rm -f "${QEMU_USER_COPIED}"
        QEMU_USER_COPIED=""
    fi

    unmount_package_cache
    chroot_exit_teardown
}

# ---------------------------------------------------------------------------
# Chroot prepare & finish_up
# ---------------------------------------------------------------------------
function chroot_prepare() {
    echo "=====> running chroot_prepare ..."

    # Modern deb822 Ubuntu APT sources; replace debootstrap's one-line sources.list.
    rm -f /etc/apt/sources.list
    install -d /etc/apt/sources.list.d

    local keyring="/usr/share/keyrings/ubuntu-archive-keyring.gpg"
    local suites="${TARGET_UBUNTU_VERSION} ${TARGET_UBUNTU_VERSION}-updates ${TARGET_UBUNTU_VERSION}-backports ${TARGET_UBUNTU_VERSION}-security"
    if [[ -f "$keyring" ]]; then
        cat <<EOF > /etc/apt/sources.list.d/ubuntu.sources
Types: deb deb-src
URIs: ${TARGET_UBUNTU_MIRROR}
Suites: ${suites}
Components: main restricted universe multiverse
Signed-By: ${keyring}
EOF
    else
        cat <<EOF > /etc/apt/sources.list
deb ${TARGET_UBUNTU_MIRROR} ${TARGET_UBUNTU_VERSION} main restricted universe multiverse
deb ${TARGET_UBUNTU_MIRROR} ${TARGET_UBUNTU_VERSION}-security main restricted universe multiverse
deb ${TARGET_UBUNTU_MIRROR} ${TARGET_UBUNTU_VERSION}-updates main restricted universe multiverse
deb ${TARGET_UBUNTU_MIRROR} ${TARGET_UBUNTU_VERSION}-backports main restricted universe multiverse
EOF
    fi

    echo "$TARGET_NAME" > /etc/hostname

    apt-get update

    block_snapd
    block_fwupd

    apt-get install -y libterm-readline-gnu-perl systemd-sysv

    if [[ "$UVB_DISTRO" == "popos" ]]; then
        setup_pop_apt_repos
    fi

    dbus-uuidgen > /etc/machine-id
    ln -fs /etc/machine-id /var/lib/dbus/machine-id

    dpkg-divert --local --rename --add /sbin/initctl
    ln -sf /bin/true /sbin/initctl
}

function finish_up() {
    echo "=====> finish_up"

    unblock_fwupd
    rm -f /etc/ssh/ssh_host_*
    truncate -s 0 /etc/machine-id

    rm -f /sbin/initctl
    dpkg-divert --rename --remove /sbin/initctl 2>/dev/null || true

    rm -rf /tmp/* ~/.bash_history
}

function configure_locale_and_keyboard() {
    if [[ -n "${TARGET_LOCALE:-}" ]]; then
        echo "=====> Configuring locale: ${TARGET_LOCALE}"
        sed -i "s/^# *${TARGET_LOCALE}/${TARGET_LOCALE}/" /etc/locale.gen 2>/dev/null || true
        echo "${TARGET_LOCALE}" >> /etc/locale.gen
        sort -u -o /etc/locale.gen /etc/locale.gen
        echo "locales locales/default_environment_locale select ${TARGET_LOCALE}" | debconf-set-selections
        echo "locales locales/locales_to_be_generated multiselect ${TARGET_LOCALE}" | debconf-set-selections
        dpkg-reconfigure --frontend=noninteractive locales
    else
        dpkg-reconfigure locales
    fi

    if [[ -n "${TARGET_KEYBOARD_LAYOUT:-}" ]]; then
        local _kb_variant="${TARGET_KEYBOARD_VARIANT:-}"
        echo "=====> Configuring keyboard: layout=${TARGET_KEYBOARD_LAYOUT}${_kb_variant:+, variant=${_kb_variant}}"
        apt-get install -y keyboard-configuration console-setup 2>/dev/null || true
        echo "keyboard-configuration keyboard-configuration/layoutcode select ${TARGET_KEYBOARD_LAYOUT}" | debconf-set-selections
        echo "keyboard-configuration keyboard-configuration/variant select ${_kb_variant}" | debconf-set-selections
        echo "keyboard-configuration keyboard-configuration/model select pc105" | debconf-set-selections
        echo "console-setup console-setup/charmap47 select UTF-8" | debconf-set-selections
        dpkg-reconfigure --frontend=noninteractive keyboard-configuration
        dpkg-reconfigure --frontend=noninteractive console-setup
    fi
}

function configure_network_manager_conf() {
    if [[ "${TARGET_NETWORK_STACK:-network-manager}" != "network-manager" ]]; then
        return 0
    fi
    install -d /etc/NetworkManager
    cat <<'EOF' > /etc/NetworkManager/NetworkManager.conf
[main]
plugins=keyfile
dns=systemd-resolved
EOF
    dpkg-reconfigure network-manager
}

# ---------------------------------------------------------------------------
# Interactive & non-interactive option resolution
# ---------------------------------------------------------------------------
function interactive_mode_pick() {
    if [[ ! -t 0 ]]; then
        return 0
    fi

    local cfg_name
    cfg_name="$(default_config_filename)"
    ui_heading "Build mode"
    _ui_c_out '1;32'; printf '  %s 1) ' "$UI_SYM_PTR"; _ui_r_out
    printf '%-10s %s ' "Basic" "Guided build with sensible defaults"
    _ui_c_out '32'; printf '[default]\n'; _ui_r_out
    printf '               %s\n' "(workspace in /var/cache/ubuntu-vanilla-build, artifact saved to ~)"
    printf '    2) %-10s %s\n' "Advanced" "Config loading (${cfg_name} / --config), workspace reuse, APT cache,"
    printf '               %s\n' "custom workspace/output paths, --interactive / --no-interactive"

    local choice
    while true; do
        read -r -p "  Mode [1/2, Enter=1]: " choice
        case "${choice,,}" in
            ""|1|b|basic)     export ADVANCED_MODE=0; break ;;
            2|a|adv|advanced) export ADVANCED_MODE=1; break ;;
            *) ui_warn "Invalid selection '$choice' -- enter 1 (basic) or 2 (advanced)." ;;
        esac
    done
    ui_ok "Build mode: $([[ "$ADVANCED_MODE" -eq 1 ]] && echo "advanced" || echo "basic")"
}

function resolve_release_choice() {
    if [[ -n "${TARGET_UBUNTU_VERSION:-}" ]]; then
        return 0
    fi

    if ! prompts_enabled; then
        if [[ "$UVB_DISTRO" == "popos" ]]; then
            ui_err "TARGET_UBUNTU_VERSION is not set. Use --release=noble|resolute for non-interactive runs."
        else
            ui_err "TARGET_UBUNTU_VERSION is not set. Use --release=noble|resolute|devel for non-interactive runs."
        fi
        exit 1
    fi

    if [[ "$UVB_DISTRO" == "popos" ]]; then
        ui_menu "Pop!_OS release" "Choose the target Pop!_OS / Ubuntu LTS base:" "noble" \
            "noble"    "Pop!_OS 24.04 LTS" \
            "resolute" "Pop!_OS 26.04 LTS"
    else
        ui_menu "Ubuntu release" "Choose the target Ubuntu release:" "noble" \
            "noble"    "Ubuntu 24.04 LTS" \
            "resolute" "Ubuntu 26.04 LTS" \
            "devel"    "Ubuntu rolling development branch (current dev series)"
    fi
    export TARGET_UBUNTU_VERSION="$UI_REPLY"
    ui_ok "TARGET_UBUNTU_VERSION=$TARGET_UBUNTU_VERSION"
}

function resolve_arch_choice() {
    if [[ -n "${TARGET_ARCH:-}" ]]; then
        normalize_arch_variant
        return 0
    fi

    local def_arch
    def_arch="$(host_dpkg_arch)"
    [[ "$def_arch" == "amd64" || "$def_arch" == "arm64" ]] || def_arch="amd64"

    if ! prompts_enabled; then
        export TARGET_ARCH="$def_arch"
        return 0
    fi

    if [[ "$def_arch" == "arm64" ]]; then
        ui_menu "Target architecture" "Select CPU architecture for '${TARGET_UBUNTU_VERSION}':" "arm64" \
            "arm64" "64-bit ARM AArch64 (native on this host; UEFI-only)" \
            "amd64" "64-bit x86_64 (cross-build via QEMU qemu-x86_64-static)"
    else
        ui_menu "Target architecture" "Select CPU architecture for '${TARGET_UBUNTU_VERSION}':" "amd64" \
            "amd64" "64-bit x86_64 (native on this host; PC / standard cloud / VMs)" \
            "arm64" "64-bit ARM AArch64 (UEFI-only; cross-build via QEMU qemu-aarch64-static)"
    fi
    export TARGET_ARCH="$UI_REPLY"
    normalize_arch_variant
    ui_ok "TARGET_ARCH=$TARGET_ARCH"
}

function resolve_profile_choice() {
    if [[ -z "${TARGET_IMAGE_PROFILE:-}" ]]; then
        if prompts_enabled; then
            ui_menu "Build profile" "Select desktop-ready or CLI/TTY-only profile:" "desktop" \
                "desktop" "Full graphical desktop environment" \
                "cli"     "CLI / TTY only (no desktop, browsers, or GUI apps)"
            export TARGET_IMAGE_PROFILE="$UI_REPLY"
        else
            export TARGET_IMAGE_PROFILE="desktop"
        fi
    fi
    export TARGET_IMAGE_PROFILE="${TARGET_IMAGE_PROFILE,,}"

    if [[ "$TARGET_IMAGE_PROFILE" == "cli" ]]; then
        if [[ -n "${TARGET_DESKTOP:-}" && "${TARGET_DESKTOP,,}" != "cli" ]]; then
            ui_warn "CLI/TTY-only profile selected -- ignoring desktop '${TARGET_DESKTOP}'."
        fi
        export TARGET_DESKTOP="cli"
        if [[ "$UVB_OUTPUT_KIND" == "iso" ]]; then
            export TARGET_INSTALLER="cli"
        fi
    fi
}

function resolve_network_stack_choice() {
    if [[ -n "${TARGET_NETWORK_STACK:-}" ]]; then
        case "${TARGET_NETWORK_STACK,,}" in
            networkd|systemd-networkd|netplan) export TARGET_NETWORK_STACK="networkd" ;;
            nm|networkmanager|network-manager) export TARGET_NETWORK_STACK="network-manager" ;;
            *)
                ui_err "TARGET_NETWORK_STACK must be networkd or network-manager (got: '${TARGET_NETWORK_STACK}')."
                exit 1
                ;;
        esac
    fi

    if [[ "${TARGET_IMAGE_PROFILE:-desktop}" != "cli" ]]; then
        if [[ "${TARGET_NETWORK_STACK:-}" == "networkd" ]]; then
            ui_warn "Desktop profile always uses NetworkManager -- ignoring network stack 'networkd'."
        fi
        export TARGET_NETWORK_STACK="network-manager"
        return 0
    fi

    if [[ -n "${TARGET_NETWORK_STACK:-}" ]]; then
        return 0
    fi

    if prompts_enabled; then
        ui_menu "Network stack (CLI profile)" "Choose network manager for the CLI system:" "networkd" \
            "networkd"        "netplan + systemd-networkd (lean, server-style)" \
            "network-manager" "NetworkManager (nmcli / nmtui)"
        export TARGET_NETWORK_STACK="$UI_REPLY"
        ui_ok "TARGET_NETWORK_STACK=$TARGET_NETWORK_STACK"
        return 0
    fi

    export TARGET_NETWORK_STACK="networkd"
}

function resolve_kernel_choice() {
    if [[ -n "${TARGET_KERNEL_FLAVOR:-}" ]]; then
        return 0
    fi

    if ! prompts_enabled; then
        if [[ "$UVB_DISTRO" == "popos" && "${TARGET_ARCH:-amd64}" == "amd64" ]]; then
            ui_err "TARGET_KERNEL_FLAVOR is not set. Use --kernel=system76|generic|lowlatency."
        else
            ui_err "TARGET_KERNEL_FLAVOR is not set. Use --kernel=generic|lowlatency."
        fi
        exit 1
    fi

    local hv="" suffix_g="" suffix_l=""
    if [[ "${TARGET_UBUNTU_VERSION}" == "devel" ]]; then
        suffix_g="linux-generic"
        suffix_l="linux-lowlatency"
    else
        hv="$(release_version "${TARGET_UBUNTU_VERSION:-}")"
        suffix_g="linux-generic-hwe-${hv}"
        suffix_l="linux-lowlatency-hwe-${hv}"
    fi

    if [[ "$UVB_DISTRO" == "popos" && "${TARGET_ARCH:-amd64}" == "amd64" ]]; then
        ui_menu "Kernel flavor" "Select kernel package:" "system76" \
            "system76"   "System76 kernel from Pop!_OS repos (linux-system76)" \
            "generic"    "Ubuntu HWE kernel (${suffix_g})" \
            "lowlatency" "Ubuntu HWE low-latency kernel (${suffix_l})"
    else
        ui_menu "Kernel flavor" "Select kernel package:" "generic" \
            "generic"    "Recommended for most systems (${suffix_g})" \
            "lowlatency" "Low-latency audio/RT workloads (${suffix_l})"
    fi
    export TARGET_KERNEL_FLAVOR="$UI_REPLY"
    ui_ok "TARGET_KERNEL_FLAVOR=$TARGET_KERNEL_FLAVOR"
}

function resolve_desktop_choice() {
    if [[ -n "${TARGET_DESKTOP:-}" ]]; then
        return 0
    fi

    if ! prompts_enabled; then
        export TARGET_DESKTOP=gnome
        return 0
    fi

    local prompt="Choose a desktop environment:"
    if [[ "$UVB_DISTRO" == "popos" ]]; then
        prompt="Choose a desktop environment (pop-desktop/COSMIC are excluded; see post-build note):"
    fi
    ui_menu "Desktop environment" "$prompt" "gnome" \
        "gnome"      "Vanilla GNOME desktop (minimal recommends by default)" \
        "budgie"     "Budgie desktop + LightDM (slick-greeter)" \
        "cinnamon"   "Cinnamon desktop + LightDM (slick-greeter)" \
        "kde-plasma" "KDE Plasma + SDDM (Breeze theme pinned)" \
        "lxde"       "Lightweight classic LXDE + LightDM" \
        "lxqt"       "Lightweight Qt LXQt + SDDM" \
        "mate"       "MATE traditional desktop + LightDM" \
        "xfce"       "XFCE + goodies + PipeWire + LightDM + labwc"
    export TARGET_DESKTOP="$UI_REPLY"
    ui_ok "TARGET_DESKTOP=$TARGET_DESKTOP"
}

function resolve_kde_package_choice() {
    if [[ "${TARGET_DESKTOP:-gnome}" != "kde-plasma" ]]; then
        export TARGET_KDE_PACKAGE="kde-standard"
        return 0
    fi
    if [[ -n "${TARGET_KDE_PACKAGE:-}" ]]; then
        return 0
    fi
    if prompts_enabled; then
        ui_menu "KDE package tier" "Select KDE metapackage:" "kde-standard" \
            "kde-standard"       "Balanced KDE software set" \
            "kde-plasma-desktop" "Minimal KDE Plasma desktop" \
            "kde-full"           "Complete KDE software suite"
        export TARGET_KDE_PACKAGE="$UI_REPLY"
        ui_ok "TARGET_KDE_PACKAGE=$TARGET_KDE_PACKAGE"
        return 0
    fi
    export TARGET_KDE_PACKAGE="kde-standard"
}

function resolve_mate_choice() {
    if [[ "${TARGET_DESKTOP:-gnome}" != "mate" ]]; then
        export TARGET_MATE_PACKAGE="${TARGET_MATE_PACKAGE:-mate-desktop-environment}"
        export TARGET_MATE_EXTRAS=0
        return 0
    fi

    case "${TARGET_MATE_PACKAGE:-}" in
        full) export TARGET_MATE_PACKAGE="mate-desktop-environment" ;;
        core) export TARGET_MATE_PACKAGE="mate-desktop-environment-core" ;;
    esac

    if [[ -n "${TARGET_MATE_PACKAGE:-}" ]] && [[ -v TARGET_MATE_EXTRAS ]]; then
        return 0
    fi

    if prompts_enabled; then
        if [[ -z "${TARGET_MATE_PACKAGE:-}" ]]; then
            ui_menu "MATE metapackage" "Choose MATE package tier:" "mate-desktop-environment" \
                "mate-desktop-environment"      "Full MATE desktop" \
                "mate-desktop-environment-core" "Core only (smaller install)"
            export TARGET_MATE_PACKAGE="$UI_REPLY"
            ui_ok "TARGET_MATE_PACKAGE=$TARGET_MATE_PACKAGE"
        fi
        if [[ ! -v TARGET_MATE_EXTRAS ]]; then
            if ui_confirm "Install mate-desktop-environment-extras?" n; then
                export TARGET_MATE_EXTRAS=1
            else
                export TARGET_MATE_EXTRAS=0
            fi
            ui_ok "TARGET_MATE_EXTRAS=$TARGET_MATE_EXTRAS"
        fi
        return 0
    fi

    export TARGET_MATE_PACKAGE="${TARGET_MATE_PACKAGE:-mate-desktop-environment}"
    export TARGET_MATE_EXTRAS="${TARGET_MATE_EXTRAS:-0}"
}

function resolve_gnome_recommends_choice() {
    if [[ "${TARGET_DESKTOP:-gnome}" != "gnome" ]]; then
        export TARGET_GNOME_INSTALL_RECOMMENDS=0
        return 0
    fi
    if [[ -n "${TARGET_GNOME_INSTALL_RECOMMENDS:-}" ]]; then
        return 0
    fi
    if prompts_enabled; then
        if ui_confirm "Install vanilla-gnome-desktop with APT recommended packages?" n; then
            export TARGET_GNOME_INSTALL_RECOMMENDS="1"
        else
            export TARGET_GNOME_INSTALL_RECOMMENDS="0"
        fi
        ui_ok "TARGET_GNOME_INSTALL_RECOMMENDS=$TARGET_GNOME_INSTALL_RECOMMENDS"
        return 0
    fi
    export TARGET_GNOME_INSTALL_RECOMMENDS=0
}

function interactive_toggle_pick() {
    local var_name="$1" heading="$2" install_label="$3" _skip_label="$4" _prompt_label="$5"
    if ! prompts_enabled; then
        ui_err "No terminal is available. Set ${var_name}=0|1."
        exit 1
    fi
    if ui_confirm "${heading}: ${install_label}?" n; then
        export "$var_name"="1"
    else
        export "$var_name"="0"
    fi
    ui_ok "${var_name}=${!var_name}"
}

function resolve_browser_selection() {
    if [[ "${TARGET_IMAGE_PROFILE:-desktop}" == "cli" ]]; then
        export TARGET_BRAVE_CHANNEL="none"
        export TARGET_LIBREWOLF=0
        export TARGET_FIREFOX=0
        export TARGET_FIREFOX_ESR=0
        export TARGET_FIREFOX_POPOS=0
        export TARGET_THUNDERBIRD=0
        return 0
    fi

    if [[ -z "${TARGET_BRAVE_CHANNEL:-}" ]]; then
        if prompts_enabled; then
            ui_menu "Brave Browser" "Choose Brave channel (APT repo is always configured):" "release" \
                "release" "Brave Stable (brave-browser)" \
                "origin"  "Brave Origin (minimalist privacy-focused build)" \
                "none"    "Skip Brave pre-installation"
            export TARGET_BRAVE_CHANNEL="$UI_REPLY"
            ui_ok "TARGET_BRAVE_CHANNEL=$TARGET_BRAVE_CHANNEL"
        else
            export TARGET_BRAVE_CHANNEL="release"
        fi
    fi

    if [[ -z "${TARGET_LIBREWOLF+x}" ]]; then
        if prompts_enabled; then
            interactive_toggle_pick TARGET_LIBREWOLF "LibreWolf" "Pre-install librewolf" "Skip" "LibreWolf"
        else
            export TARGET_LIBREWOLF=0
        fi
    fi

    # Ask Firefox interactively only when none of the Firefox variants were explicitly set.
    if [[ -z "${TARGET_FIREFOX+x}" && -z "${TARGET_FIREFOX_ESR+x}" && -z "${TARGET_FIREFOX_POPOS+x}" ]]; then
        if prompts_enabled; then
            if [[ "$UVB_DISTRO" == "popos" ]]; then
                ui_menu "Firefox Browser" "Select Firefox option:" "skip" \
                    "skip"    "Do not pre-install Firefox" \
                    "release" "Firefox Release (Mozilla deb822 APT)" \
                    "esr"     "Firefox ESR (Mozilla PPA)" \
                    "popos"   "Firefox native deb from Pop!_OS repo"
            else
                ui_menu "Firefox Browser" "Select Firefox option:" "skip" \
                    "skip"    "Do not pre-install Firefox" \
                    "release" "Firefox Release (Mozilla deb822 APT)" \
                    "esr"     "Firefox ESR (Mozilla PPA)"
            fi
            case "$UI_REPLY" in
                release) export TARGET_FIREFOX=1 TARGET_FIREFOX_ESR=0 TARGET_FIREFOX_POPOS=0 ;;
                esr)     export TARGET_FIREFOX=0 TARGET_FIREFOX_ESR=1 TARGET_FIREFOX_POPOS=0 ;;
                popos)   export TARGET_FIREFOX=0 TARGET_FIREFOX_ESR=0 TARGET_FIREFOX_POPOS=1 ;;
                skip)    export TARGET_FIREFOX=0 TARGET_FIREFOX_ESR=0 TARGET_FIREFOX_POPOS=0 ;;
            esac
            ui_ok "TARGET_FIREFOX=$TARGET_FIREFOX  TARGET_FIREFOX_ESR=$TARGET_FIREFOX_ESR"
        fi
    fi

    if [[ -z "${TARGET_THUNDERBIRD+x}" ]]; then
        if prompts_enabled; then
            interactive_toggle_pick TARGET_THUNDERBIRD "Thunderbird" "Pre-install thunderbird (Mozilla PPA)" "Skip" "Thunderbird"
        else
            export TARGET_THUNDERBIRD=0
        fi
    fi

    export TARGET_LIBREWOLF="${TARGET_LIBREWOLF:-0}"
    export TARGET_FIREFOX="${TARGET_FIREFOX:-0}"
    export TARGET_FIREFOX_ESR="${TARGET_FIREFOX_ESR:-0}"
    export TARGET_FIREFOX_POPOS="${TARGET_FIREFOX_POPOS:-0}"
    export TARGET_THUNDERBIRD="${TARGET_THUNDERBIRD:-0}"
}

function resolve_ubuntu_studio_choice() {
    if [[ "${TARGET_IMAGE_PROFILE:-desktop}" == "cli" ]]; then
        export TARGET_UBUNTU_STUDIO=0
        return 0
    fi
    if [[ -n "${TARGET_UBUNTU_STUDIO+x}" ]]; then
        export TARGET_UBUNTU_STUDIO="${TARGET_UBUNTU_STUDIO:-0}"
        return 0
    fi
    if prompts_enabled; then
        interactive_toggle_pick TARGET_UBUNTU_STUDIO "Ubuntu Studio" "Install Ubuntu Studio creative metapackages (heavy)" "Skip" "Ubuntu Studio"
    else
        export TARGET_UBUNTU_STUDIO=0
    fi
}

function resolve_pacstall_choice() {
    if [[ -n "${TARGET_PACSTALL+x}" ]]; then
        export TARGET_PACSTALL="${TARGET_PACSTALL:-1}"
        return 0
    fi
    if prompts_enabled; then
        if ui_confirm "Install Pacstall (via Chaotic PPR APT repo)?" y; then
            export TARGET_PACSTALL=1
        else
            export TARGET_PACSTALL=0
        fi
        ui_ok "TARGET_PACSTALL=$TARGET_PACSTALL"
    else
        export TARGET_PACSTALL=1
    fi
}

function resolve_optional_service_choices() {
    if [[ -z "${TARGET_FWUPD+x}" ]]; then
        if prompts_enabled; then
            interactive_toggle_pick TARGET_FWUPD "fwupd (firmware updater)" "Pre-install fwupd (blocked during build otherwise)" "Skip" "fwupd"
        else
            export TARGET_FWUPD=0
        fi
    fi

    if [[ -z "${TARGET_OPENSSH_SERVER+x}" && "$UVB_IMAGE_KIND" == "cloud" ]]; then
        if prompts_enabled; then
            if ui_confirm "OpenSSH server (cloud images usually need SSH): Pre-install openssh-server?" y; then
                export TARGET_OPENSSH_SERVER=1
            else
                export TARGET_OPENSSH_SERVER=0
            fi
            ui_ok "TARGET_OPENSSH_SERVER=$TARGET_OPENSSH_SERVER"
        else
            export TARGET_OPENSSH_SERVER=1
        fi
    fi

    if [[ -z "${TARGET_OPENSSH_SERVER+x}" ]]; then
        if prompts_enabled; then
            interactive_toggle_pick TARGET_OPENSSH_SERVER "OpenSSH server" "Pre-install openssh-server" "Skip" "OpenSSH server"
        else
            export TARGET_OPENSSH_SERVER=0
        fi
    fi

    if [[ -z "${TARGET_COCKPIT+x}" ]]; then
        if prompts_enabled; then
            interactive_toggle_pick TARGET_COCKPIT "Cockpit web admin console" "Pre-install cockpit (${TARGET_UBUNTU_VERSION:-release}-backports)" "Skip" "Cockpit"
        else
            export TARGET_COCKPIT=0
        fi
    fi

    export TARGET_FWUPD="${TARGET_FWUPD:-0}"
    export TARGET_OPENSSH_SERVER="${TARGET_OPENSSH_SERVER:-0}"
    export TARGET_COCKPIT="${TARGET_COCKPIT:-0}"
}

function check_common_settings() {
    assert_supported_release || exit 1
    normalize_arch_variant
    normalize_desktop_variant

    if [[ ! "${TARGET_UBUNTU_MIRROR:-}" =~ ^https?://[^[:space:]]+$ ]]; then
        ui_err "TARGET_UBUNTU_MIRROR must be a valid http:// or https:// URL (got: '${TARGET_UBUNTU_MIRROR:-}')."
        exit 1
    fi
    assert_bool_var TARGET_GNOME_INSTALL_RECOMMENDS
    case "${TARGET_KDE_PACKAGE:-kde-standard}" in
        kde-full|kde-standard|kde-plasma-desktop) ;;
        *)
            ui_err "TARGET_KDE_PACKAGE must be kde-full, kde-standard, or kde-plasma-desktop (got: '${TARGET_KDE_PACKAGE:-}')."
            exit 1
            ;;
    esac
    case "${TARGET_BRAVE_CHANNEL:-release}" in
        none|release|origin) ;;
        *)
            ui_err "TARGET_BRAVE_CHANNEL must be none, release, or origin (got: '${TARGET_BRAVE_CHANNEL:-}')."
            exit 1
            ;;
    esac
    assert_bool_var TARGET_LIBREWOLF
    assert_bool_var TARGET_FIREFOX
    assert_bool_var TARGET_FIREFOX_ESR
    assert_bool_var TARGET_FIREFOX_POPOS
    if [[ "${TARGET_FIREFOX:-0}" == "1" && "${TARGET_FIREFOX_POPOS:-0}" == "1" ]]; then
        ui_err "TARGET_FIREFOX and TARGET_FIREFOX_POPOS cannot both be 1."
        exit 1
    fi
    assert_bool_var TARGET_THUNDERBIRD
    assert_bool_var TARGET_UBUNTU_STUDIO
    assert_bool_var TARGET_PACSTALL 1
    assert_bool_var TARGET_SYSTEM76_DRIVER
    assert_bool_var TARGET_FWUPD
    assert_bool_var TARGET_OPENSSH_SERVER
    assert_bool_var TARGET_COCKPIT

    case "${TARGET_IMAGE_PROFILE:-desktop}" in
        desktop|cli) ;;
        *)
            ui_err "TARGET_IMAGE_PROFILE must be desktop or cli (got: '${TARGET_IMAGE_PROFILE:-}')."
            exit 1
            ;;
    esac
    case "${TARGET_NETWORK_STACK:-network-manager}" in
        networkd|network-manager) ;;
        *)
            ui_err "TARGET_NETWORK_STACK must be networkd or network-manager (got: '${TARGET_NETWORK_STACK:-}')."
            exit 1
            ;;
    esac
    if [[ "${TARGET_DESKTOP:-}" == "mate" ]]; then
        case "${TARGET_MATE_PACKAGE:-mate-desktop-environment}" in
            full) export TARGET_MATE_PACKAGE="mate-desktop-environment" ;;
            core) export TARGET_MATE_PACKAGE="mate-desktop-environment-core" ;;
        esac
        case "${TARGET_MATE_PACKAGE:-mate-desktop-environment}" in
            mate-desktop-environment|mate-desktop-environment-core) ;;
            *)
                ui_err "TARGET_MATE_PACKAGE must be mate-desktop-environment or mate-desktop-environment-core (got: '${TARGET_MATE_PACKAGE:-}')."
                exit 1
                ;;
        esac
        assert_bool_var TARGET_MATE_EXTRAS
    fi
}

# ---------------------------------------------------------------------------
# Config loader & wizard (Advanced mode)
# ---------------------------------------------------------------------------
function _trim_ws() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

function load_config_file() {
    local config_path="$1"
    if [[ ! -f "$config_path" ]]; then
        ui_err "Config file not found: $config_path"
        exit 1
    fi
    ui_info "Loading config from: $config_path"
    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        line="${line%%[[:space:]]\#*}"
        if [[ "$line" =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="$(_trim_ws "${BASH_REMATCH[2]}")"
            if [[ "$val" == \"*\" && "$val" == *\" ]] || [[ "$val" == \'*\' && "$val" == *\' ]]; then
                val="${val:1:${#val}-2}"
                val="$(_trim_ws "$val")"
            fi
            case "$key" in
                TARGET_UBUNTU_VERSION|TARGET_UBUNTU_MIRROR|TARGET_ARCH|\
                TARGET_KERNEL_FLAVOR|TARGET_KERNEL_PACKAGE|TARGET_DESKTOP|\
                TARGET_KDE_PACKAGE|TARGET_MATE_PACKAGE|TARGET_MATE_EXTRAS|\
                TARGET_BRAVE_CHANNEL|TARGET_LIBREWOLF|\
                TARGET_FIREFOX|TARGET_FIREFOX_ESR|TARGET_FIREFOX_POPOS|\
                TARGET_THUNDERBIRD|TARGET_UBUNTU_STUDIO|TARGET_PACSTALL|\
                TARGET_SYSTEM76_DRIVER|TARGET_FWUPD|TARGET_OPENSSH_SERVER|\
                TARGET_COCKPIT|TARGET_GNOME_INSTALL_RECOMMENDS|TARGET_NAME|\
                TARGET_LOCALE|TARGET_KEYBOARD_LAYOUT|TARGET_KEYBOARD_VARIANT|\
                TARGET_INSTALLER|TARGET_PACKAGE_REMOVE|\
                TARGET_FIRMWARE|TARGET_DISK_SIZE_GB|TARGET_IMAGE_PROFILE|\
                TARGET_NETWORK_STACK|TARGET_IMG_ALLOC|TARGET_USER_MODE|\
                TARGET_USERNAME|TARGET_USER_PASSWORD|TARGET_USER_FULLNAME|\
                TARGET_HOSTNAME|TARGET_VM_FORMATS|GRUB_LIVEBOOT_LABEL|\
                UBUNTU_VANILLA_WORKSPACE|UVB_OUTPUT_DIR|UVB_UI_MODE|\
                NO_CONFIRM|INTERACTIVE|ADVANCED_MODE|HOOKS_DIR)
                    [[ -n "$val" ]] && export "$key=$val"
                    ;;
                *)
                    ui_warn "Config: ignoring unknown key '$key'"
                    ;;
            esac
        fi
    done < "$config_path"
}

function generate_config_wizard() {
    if ! prompts_enabled; then
        ui_err "Config wizard requires an interactive terminal."
        exit 1
    fi

    local cfg_file
    cfg_file="$(default_config_filename)"
    local out_path="${CLI_CONFIG_PATH:-$SCRIPT_DIR/$cfg_file}"

    ui_banner "Build Configuration Wizard (${cfg_file})"
    echo "  Press Enter to accept the [default] value shown in brackets."
    echo

    if [[ -f "$out_path" ]]; then
        if ! ui_confirm "$out_path already exists. Overwrite?" n; then
            ui_info "Wizard cancelled."
            exit 0
        fi
    fi

    local _release _arch _profile _kernel _desktop _kde_pkg _mate_pkg _mate_extras _gnome_rec
    local _network _firmware _alloc _disk_size _user_mode _vm_formats _mirror
    local _brave _librewolf _firefox _firefox_esr _firefox_popos _thunderbird
    local _pacstall _ubuntu_studio _system76_driver _fwupd _openssh _cockpit
    local _locale _keyboard_layout _keyboard_variant _ui_mode _advanced _name _workspace _output _hooks

    if [[ "$UVB_DISTRO" == "popos" ]]; then
        while true; do
            ui_input "Release" "Supported Pop!_OS releases (noble / resolute)" "noble"
            _release="${UI_REPLY,,}"
            [[ "$_release" == "noble" || "$_release" == "resolute" ]] && break
            ui_warn "Pop!_OS supports 'noble' or 'resolute'."
        done
    else
        while true; do
            ui_input "Release" "Supported Ubuntu releases (noble / resolute / devel)" "noble"
            _release="${UI_REPLY,,}"
            [[ "$_release" == "noble" || "$_release" == "resolute" || "$_release" == "devel" ]] && break
            ui_warn "Enter 'noble', 'resolute', or 'devel'."
        done
    fi

    while true; do
        ui_input "Architecture" "Target architecture (amd64 / arm64)" "amd64"
        _arch="${UI_REPLY,,}"
        [[ "$_arch" == "amd64" || "$_arch" == "arm64" ]] && break
        ui_warn "Enter 'amd64' or 'arm64'."
    done

    while true; do
        ui_input "Profile" "Build profile (desktop / cli)" "desktop"
        _profile="${UI_REPLY,,}"
        [[ "$_profile" == "desktop" || "$_profile" == "cli" ]] && break
        ui_warn "Enter 'desktop' or 'cli'."
    done

    local _def_kernel="generic"
    [[ "$UVB_DISTRO" == "popos" && "$_arch" == "amd64" ]] && _def_kernel="system76"
    while true; do
        if [[ "$UVB_DISTRO" == "popos" && "$_arch" == "amd64" ]]; then
            ui_input "Kernel" "Kernel flavor (system76 / generic / lowlatency)" "$_def_kernel"
            _kernel="${UI_REPLY,,}"
            [[ "$_kernel" == "system76" || "$_kernel" == "generic" || "$_kernel" == "lowlatency" ]] && break
        else
            ui_input "Kernel" "Kernel flavor (generic / lowlatency)" "$_def_kernel"
            _kernel="${UI_REPLY,,}"
            [[ "$_kernel" == "generic" || "$_kernel" == "lowlatency" ]] && break
        fi
        ui_warn "Invalid kernel flavor '$_kernel'."
    done

    _desktop="cli" _kde_pkg="kde-standard" _mate_pkg="mate-desktop-environment" _mate_extras="0" _gnome_rec="0"
    if [[ "$_profile" == "desktop" ]]; then
        while true; do
            ui_input "Desktop" "Desktop (gnome, xfce, lxde, lxqt, mate, cinnamon, budgie, kde-plasma)" "gnome"
            _desktop="${UI_REPLY,,}"
            [[ "$_desktop" == "kde" ]] && _desktop="kde-plasma"
            case "$_desktop" in
                gnome|xfce|lxde|lxqt|mate|cinnamon|budgie|kde-plasma) break ;;
                *) ui_warn "Unsupported desktop '$_desktop'." ;;
            esac
        done
        if [[ "$_desktop" == "kde-plasma" ]]; then
            ui_input "KDE tier" "KDE package (kde-standard / kde-plasma-desktop / kde-full)" "kde-standard"
            _kde_pkg="$UI_REPLY"
        elif [[ "$_desktop" == "mate" ]]; then
            ui_input "MATE tier" "MATE metapackage (full / core)" "full"
            [[ "$UI_REPLY" == "core" ]] && _mate_pkg="mate-desktop-environment-core"
            ui_input "MATE extras" "Install mate-desktop-environment-extras? (0/1)" "0"
            _mate_extras="$UI_REPLY"
        elif [[ "$_desktop" == "gnome" ]]; then
            ui_input "GNOME recommends" "Include APT recommends for GNOME? (0/1)" "0"
            _gnome_rec="$UI_REPLY"
        fi
    fi

    _network="network-manager"
    if [[ "$_profile" == "cli" ]]; then
        ui_input "Network stack" "Network stack (networkd / network-manager)" "networkd"
        _network="${UI_REPLY,,}"
    fi

    _firmware="" _alloc="" _disk_size="" _user_mode="" _vm_formats=""
    if [[ "$UVB_OUTPUT_KIND" != "iso" ]]; then
        local _fw_def="uefi"
        [[ "$UVB_OUTPUT_KIND" == "removable" ]] && _fw_def="hybrid"
        if [[ "$_arch" == "arm64" ]]; then
            _firmware="uefi"
            ui_info "ARM64 targets use UEFI-only firmware."
        else
            ui_input "Firmware" "Firmware (uefi / hybrid)" "$_fw_def"
            _firmware="${UI_REPLY,,}"
        fi
        ui_input "Allocation tool" "Raw image allocation (truncate / fallocate / dd)" "truncate"
        _alloc="${UI_REPLY,,}"
        local _ds_def=32 _ds_min=10
        [[ "$UVB_OUTPUT_KIND" == "removable" ]] && { _ds_def=16; _ds_min=8; }
        while true; do
            ui_input "Disk size" "Disk image size in GB (minimum ${_ds_min})" "$_ds_def"
            _disk_size="$UI_REPLY"
            [[ "$_disk_size" =~ ^[0-9]+$ ]] && (( _disk_size >= _ds_min )) && break
            ui_warn "Enter a whole number >= ${_ds_min}."
        done
        ui_input "User mode" "User account mode (build / deploy)" "deploy"
        _user_mode="${UI_REPLY,,}"
        if [[ "$UVB_OUTPUT_KIND" == "vm" ]]; then
            ui_input "VM formats" "VM export formats (qcow2,vdi,vmdk,vhdx / all / none)" "qcow2"
            _vm_formats="${UI_REPLY,,}"
        fi
    fi

    local _def_mirror
    _def_mirror="$(default_mirror_for_target "$UVB_DISTRO" "$_arch")"
    ui_input "Mirror" "APT mirror URL" "$_def_mirror"
    _mirror="$UI_REPLY"

    _brave="none" _librewolf="0" _firefox="0" _firefox_esr="0" _firefox_popos="0" _thunderbird="0" _ubuntu_studio="0"
    if [[ "$_profile" == "desktop" ]]; then
        ui_input "Brave" "Brave channel (none / release / origin)" "release"
        _brave="${UI_REPLY,,}"
        ui_input "LibreWolf" "Pre-install LibreWolf? (0/1)" "0"
        _librewolf="$UI_REPLY"
        ui_input "Firefox" "Pre-install Firefox from Mozilla APT? (0/1)" "0"
        _firefox="$UI_REPLY"
        ui_input "Firefox ESR" "Pre-install Firefox ESR from Mozilla PPA? (0/1)" "0"
        _firefox_esr="$UI_REPLY"
        if [[ "$UVB_DISTRO" == "popos" ]]; then
            ui_input "Firefox (Pop!_OS)" "Pre-install native Firefox deb from Pop!_OS repo? (0/1)" "0"
            _firefox_popos="$UI_REPLY"
        fi
        ui_input "Thunderbird" "Pre-install Thunderbird? (0/1)" "0"
        _thunderbird="$UI_REPLY"
        ui_input "Ubuntu Studio" "Install Ubuntu Studio metapackages? (0/1)" "0"
        _ubuntu_studio="$UI_REPLY"
    fi

    ui_input "Pacstall" "Install Pacstall via Chaotic PPR? (0/1)" "1"
    _pacstall="$UI_REPLY"

    _system76_driver="0"
    if [[ "$UVB_DISTRO" == "popos" ]]; then
        ui_input "System76 driver" "Pre-install system76-driver? (0/1)" "0"
        _system76_driver="$UI_REPLY"
    fi

    ui_input "fwupd" "Pre-install fwupd? (0/1)" "0"
    _fwupd="$UI_REPLY"
    ui_input "OpenSSH" "Pre-install openssh-server? (0/1)" "0"
    _openssh="$UI_REPLY"
    ui_input "Cockpit" "Pre-install Cockpit? (0/1)" "0"
    _cockpit="$UI_REPLY"

    ui_input "Locale" "System locale (blank to skip, e.g. en_US.UTF-8)" ""
    _locale="$UI_REPLY"
    ui_input "Keyboard" "Keyboard layout (blank to skip, e.g. us)" ""
    _keyboard_layout="$UI_REPLY"
    _keyboard_variant=""
    if [[ -n "$_keyboard_layout" ]]; then
        ui_input "Keyboard variant" "Keyboard variant (blank for default)" ""
        _keyboard_variant="$UI_REPLY"
    fi

    ui_input "Interface" "Default UI mode (cli / tui)" "cli"
    _ui_mode="${UI_REPLY,,}"
    ui_input "Advanced mode" "Enable advanced mode by default? (0/1)" "1"
    _advanced="$UI_REPLY"

    _workspace="" _output="" _hooks=""
    if [[ "$_advanced" == "1" ]]; then
        ui_input "Workspace" "Custom workspace parent (blank for ~/uvb-workspace)" ""
        _workspace="$UI_REPLY"
        ui_input "Output dir" "Custom output directory (blank for ~)" ""
        _output="$UI_REPLY"
        ui_input "Hooks dir" "Custom hooks directory (blank for scripts/hooks)" ""
        _hooks="$UI_REPLY"
    fi
    ui_input "Artifact name" "Custom output filename base (blank for auto)" ""
    _name="$UI_REPLY"

    cat > "$out_path" <<WIZARD_EOF
# Generated by ${SCRIPT_NAME} config wizard on $(date '+%Y-%m-%d %H:%M:%S %Z')

# --- Core ---
TARGET_UBUNTU_VERSION=${_release}
TARGET_ARCH=${_arch}
TARGET_IMAGE_PROFILE=${_profile}
TARGET_KERNEL_FLAVOR=${_kernel}
TARGET_DESKTOP=${_desktop}
TARGET_NETWORK_STACK=${_network}
TARGET_UBUNTU_MIRROR=${_mirror}
UVB_UI_MODE=${_ui_mode}
WIZARD_EOF

    {
        if [[ "$_profile" == "desktop" ]]; then
            echo ""
            echo "# --- Desktop options ---"
            echo "TARGET_GNOME_INSTALL_RECOMMENDS=${_gnome_rec}"
            echo "TARGET_KDE_PACKAGE=${_kde_pkg}"
            echo "TARGET_MATE_PACKAGE=${_mate_pkg}"
            echo "TARGET_MATE_EXTRAS=${_mate_extras}"
            echo ""
            echo "# --- Browsers ---"
            echo "TARGET_BRAVE_CHANNEL=${_brave}"
            echo "TARGET_LIBREWOLF=${_librewolf}"
            echo "TARGET_FIREFOX=${_firefox}"
            echo "TARGET_FIREFOX_ESR=${_firefox_esr}"
            [[ "$UVB_DISTRO" == "popos" ]] && echo "TARGET_FIREFOX_POPOS=${_firefox_popos}"
            echo "TARGET_THUNDERBIRD=${_thunderbird}"
            echo "TARGET_UBUNTU_STUDIO=${_ubuntu_studio}"
        fi

        echo ""
        echo "# --- Package Manager & Optional Tools ---"
        echo "TARGET_PACSTALL=${_pacstall}"
        [[ "$UVB_DISTRO" == "popos" ]] && echo "TARGET_SYSTEM76_DRIVER=${_system76_driver}"
        echo "TARGET_FWUPD=${_fwupd}"
        echo "TARGET_OPENSSH_SERVER=${_openssh}"
        echo "TARGET_COCKPIT=${_cockpit}"

        if [[ "$UVB_OUTPUT_KIND" != "iso" ]]; then
            echo ""
            echo "# --- Disk Image ---"
            echo "TARGET_FIRMWARE=${_firmware}"
            echo "TARGET_IMG_ALLOC=${_alloc}"
            echo "TARGET_DISK_SIZE_GB=${_disk_size}"
            echo "TARGET_USER_MODE=${_user_mode}"
            [[ -n "$_vm_formats" ]] && echo "TARGET_VM_FORMATS=${_vm_formats}"
        else
            echo "TARGET_INSTALLER=calamares"
        fi

        if [[ -n "$_locale" || -n "$_keyboard_layout" ]]; then
            echo ""
            echo "# --- Locale & Keyboard ---"
            [[ -n "$_locale" ]] && echo "TARGET_LOCALE=${_locale}"
            if [[ -n "$_keyboard_layout" ]]; then
                echo "TARGET_KEYBOARD_LAYOUT=${_keyboard_layout}"
                [[ -n "$_keyboard_variant" ]] && echo "TARGET_KEYBOARD_VARIANT=${_keyboard_variant}"
            fi
        fi

        if [[ "$_advanced" == "1" ]]; then
            echo ""
            echo "# --- Advanced ---"
            echo "ADVANCED_MODE=1"
            [[ -n "$_workspace" ]] && echo "UBUNTU_VANILLA_WORKSPACE=${_workspace}"
            [[ -n "$_output" ]] && echo "UVB_OUTPUT_DIR=${_output}"
            [[ -n "$_hooks" ]] && echo "HOOKS_DIR=${_hooks}"
        fi

        if [[ -n "$_name" ]]; then
            echo ""
            echo "# --- Output ---"
            echo "TARGET_NAME=${_name}"
        fi
    } >> "$out_path"

    echo
    ui_ok "Config written to: $out_path"
    local run_cmd="./scripts/${SCRIPT_NAME}"
    [[ "$PWD" == "$SCRIPT_DIR" ]] && run_cmd="./${SCRIPT_NAME}"
    ui_info "Run '${run_cmd} --advanced --config=${out_path} -' to start a build with these settings."
    exit 0
}

# ---------------------------------------------------------------------------
# Main host & chroot orchestrators
# ---------------------------------------------------------------------------
function print_common_help_options() {
    local rel_list="noble|resolute|devel"
    [[ "$UVB_DISTRO" == "popos" ]] && rel_list="noble|resolute"
    local kern_list="generic|lowlatency"
    [[ "$UVB_DISTRO" == "popos" ]] && kern_list="system76|generic|lowlatency"

    echo "CORE OPTIONS"
    printf '  %-38s %s\n' "--release=${rel_list}" "Target release (prompted on TTY if omitted)"
    printf '  %-38s %s\n' "--arch=amd64|arm64" "Target CPU architecture (default: amd64)"
    printf '  %-38s %s\n' "--profile=desktop|cli" "Graphical desktop or CLI/TTY-only (default: desktop)"
    printf '  %-38s %s\n' "--kernel=${kern_list}" "Kernel flavor"
    printf '  %-38s %s\n' "--mirror=URL" "APT mirror (defaults to archive/ports by arch)"
    echo
    echo "DESKTOP & BROWSERS"
    printf '  %-38s %s\n' "--desktop=NAME" "gnome, xfce, lxde, lxqt, mate, cinnamon, budgie, kde-plasma"
    printf '  %-38s %s\n' "--kde=TIER" "kde-full | kde-standard (default) | kde-plasma-desktop"
    printf '  %-38s %s\n' "--mate=full|core / --[no-]mate-extras" "MATE package tier and optional extras"
    printf '  %-38s %s\n' "--network=networkd|network-manager" "Network stack for CLI profile"
    printf '  %-38s %s\n' "--brave=none|release|origin" "Brave browser channel (default: release)"
    printf '  %-38s %s\n' "--[no-]librewolf / --[no-]thunderbird" "Pre-install LibreWolf or Thunderbird"
    printf '  %-38s %s\n' "--[no-]firefox / --[no-]firefox-esr" "Pre-install Mozilla Firefox or Firefox ESR"
    if [[ "$UVB_DISTRO" == "popos" ]]; then
        printf '  %-38s %s\n' "--[no-]firefox-popos" "Pre-install native Pop!_OS Firefox deb"
        printf '  %-38s %s\n' "--[no-]system76-driver" "Pre-install system76-driver"
    fi
    printf '  %-38s %s\n' "--[no-]ubuntu-studio" "Install Ubuntu Studio creative metapackages"
    echo
    echo "PACKAGES & SERVICES"
    printf '  %-38s %s\n' "--[no-]pacstall" "Install Pacstall via Chaotic PPR (default: yes)"
    printf '  %-38s %s\n' "--[no-]fwupd" "Pre-install fwupd (blocked during build otherwise)"
    printf '  %-38s %s\n' "--[no-]openssh-server" "Pre-install openssh-server"
    printf '  %-38s %s\n' "--[no-]cockpit" "Pre-install Cockpit web admin console"
    echo
    echo "LOCALE, UI & SCREEN"
    printf '  %-38s %s\n' "--locale=LOCALE" "System locale (e.g. en_US.UTF-8)"
    printf '  %-38s %s\n' "--keyboard-layout=CODE" "Keyboard layout code (e.g. us, de)"
    printf '  %-38s %s\n' "--keyboard-variant=VAR" "Keyboard layout variant"
    printf '  %-38s %s\n' "--ui=cli|tui" "Clean terminal prompts or whiptail/dialog TUI"
    printf '  %-38s %s\n' "--no-color" "Disable colored output (also respects NO_COLOR)"
    printf '  %-38s %s\n' "--[no-]screen" "Run inside a detached GNU screen session"
    printf '  %-38s %s\n' "-h, --help" "Show this help and exit"
    echo
    echo "ADVANCED MODE (--advanced)"
    printf '  %-38s %s\n' "--advanced" "Preserve workspace, mount APT cache, enable config"
    printf '  %-38s %s\n' "--interactive / --no-interactive" "Override TTY prompting (advanced only)"
    printf '  %-38s %s\n' "--config=FILE" "Load KEY=VALUE config file (advanced only)"
    printf '  %-38s %s\n' "--generate-config" "Generate $(default_config_filename) interactively"
    printf '  %-38s %s\n' "--hooks-dir=PATH" "Custom hooks directory (default: scripts/hooks/)"
}

# shellcheck disable=SC2120
function host_help() {
    if [[ -n "${1:-}" ]]; then
        echo "$1"
        echo
    fi
    if [[ "$UVB_OUTPUT_KIND" == "iso" ]]; then
        iso_host_help
    else
        disk_image_host_help
    fi
    exit 0
}

function print_build_summary() {
    local hv=""
    hv="$(release_version "${TARGET_UBUNTU_VERSION:-}")"
    local label_distro="Ubuntu"
    [[ "$UVB_DISTRO" == "popos" ]] && label_distro="Pop!_OS"

    ui_heading "Build configuration"
    ui_kv "${label_distro} release" "${TARGET_UBUNTU_VERSION:-?}${hv:+  (${label_distro} ${hv})}"
    ui_kv "Architecture"    "${TARGET_ARCH:-amd64}"
    ui_kv "Profile"         "${TARGET_IMAGE_PROFILE:-desktop}"
    ui_kv "Kernel"          "${TARGET_KERNEL_FLAVOR:-?}${TARGET_KERNEL_PACKAGE:+  [${TARGET_KERNEL_PACKAGE}]}"
    ui_kv "Desktop"         "${TARGET_DESKTOP:-?}"
    case "${TARGET_DESKTOP:-}" in
        gnome)      ui_kv "  with Recommends" "${TARGET_GNOME_INSTALL_RECOMMENDS:-0}" ;;
        kde-plasma) ui_kv "  KDE package" "${TARGET_KDE_PACKAGE:-kde-standard}" ;;
        mate)
            ui_kv "  MATE metapackage" "${TARGET_MATE_PACKAGE:-mate-desktop-environment}"
            ui_kv "  MATE extras" "${TARGET_MATE_EXTRAS:-0}"
            ;;
    esac
    if [[ "$UVB_OUTPUT_KIND" == "iso" ]]; then
        ui_kv "Installer" "$([[ "${TARGET_IMAGE_PROFILE}" == "cli" ]] && echo "cli (install-system)" || echo "calamares + install-system")"
    else
        disk_image_print_summary_fields
    fi
    if [[ "${TARGET_IMAGE_PROFILE:-desktop}" != "cli" ]]; then
        local _bs=""
        case "${TARGET_BRAVE_CHANNEL:-release}" in
            none)    _bs="Brave: none" ;;
            release) _bs="Brave: stable" ;;
            origin)  _bs="Brave: origin" ;;
        esac
        [[ "${TARGET_LIBREWOLF:-0}" == "1" ]] && _bs="${_bs:+${_bs}; }LibreWolf"
        [[ "${TARGET_FIREFOX:-0}" == "1" ]] && _bs="${_bs:+${_bs}; }Firefox"
        [[ "${TARGET_FIREFOX_ESR:-0}" == "1" ]] && _bs="${_bs:+${_bs}; }Firefox ESR"
        [[ "${TARGET_FIREFOX_POPOS:-0}" == "1" ]] && _bs="${_bs:+${_bs}; }Firefox (Pop!_OS)"
        [[ "${TARGET_THUNDERBIRD:-0}" == "1" ]] && _bs="${_bs:+${_bs}; }Thunderbird"
        ui_kv "Browsers"      "$_bs"
        ui_kv "Ubuntu Studio" "${TARGET_UBUNTU_STUDIO:-0}"
    fi
    ui_kv "Pacstall (PPR)"  "${TARGET_PACSTALL:-1}"
    [[ "$UVB_DISTRO" == "popos" ]] && ui_kv "System76 driver" "${TARGET_SYSTEM76_DRIVER:-0}"
    ui_kv "fwupd"           "${TARGET_FWUPD:-0}  (blocked during build otherwise)"
    ui_kv "OpenSSH server"  "${TARGET_OPENSSH_SERVER:-0}"
    ui_kv "Cockpit"         "${TARGET_COCKPIT:-0}"
    if [[ "${ADVANCED_MODE:-0}" == "1" ]]; then
        ui_kv "Advanced mode" "enabled (workspace preserved, package cache active)"
    fi
    ui_kv "Target name"     "${TARGET_NAME:-?}"
    ui_kv "Mirror"          "${TARGET_UBUNTU_MIRROR:-?}"
    ui_kv "Workspace"       "${WORKSPACE_DIR:-?}"
    if [[ "$UVB_OUTPUT_KIND" == "iso" ]]; then
        ui_kv "Output ISO" "${OUTPUT_DIR:-?}/${TARGET_NAME:-image}.iso"
    else
        ui_kv "Output image" "${OUTPUT_DIR:-?}/${TARGET_NAME:-image}.img"
    fi
    echo
}

function _need_opt_val() {
    if [[ "$1" -lt 2 ]]; then
        ui_err "Option '$2' requires a value. Run '$0 --help' for usage."
        exit 1
    fi
}

function host_main() {
    local cli_kernel="" cli_release="" cli_arch="" cli_mirror="" cli_installer=""
    local cli_desktop="" cli_kde="" cli_mate="" cli_mate_extras_set=0 cli_mate_extras=0
    local cli_brave="" cli_librewolf_set=0 cli_librewolf=0
    local cli_firefox_set=0 cli_firefox=0 cli_firefox_esr_set=0 cli_firefox_esr=0
    local cli_firefox_popos_set=0 cli_firefox_popos=0 cli_thunderbird_set=0 cli_thunderbird=0
    local cli_ubuntustudio_set=0 cli_ubuntustudio=0 cli_pacstall_set=0 cli_pacstall=0
    local cli_system76_driver_set=0 cli_system76_driver=0
    local cli_fwupd_set=0 cli_fwupd=0 cli_openssh_set=0 cli_openssh=0 cli_cockpit_set=0 cli_cockpit=0
    local cli_locale="" cli_keyboard_layout="" cli_keyboard_variant=""
    local cli_config="" cli_interactive="" cli_hooks_dir="" cli_ui=""
    local cli_network="" cli_alloc="" cli_firmware="" cli_disk_size="" cli_profile=""
    local cli_user_mode="" cli_username="" cli_password="" cli_fullname="" cli_hostname="" cli_formats=""
    local cli_screen_set=0 cli_screen=0 cli_gen_config=0
    local args=()

    set_defaults

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --kernel=*)           cli_kernel="${1#--kernel=}"; shift ;;
            --kernel)             _need_opt_val $# "$1"; cli_kernel="$2"; shift 2 ;;
            --release=*)          cli_release="${1#--release=}"; shift ;;
            --release)            _need_opt_val $# "$1"; cli_release="$2"; shift 2 ;;
            --arch=*)             cli_arch="${1#--arch=}"; shift ;;
            --arch)               _need_opt_val $# "$1"; cli_arch="$2"; shift 2 ;;
            --mirror=*)           cli_mirror="${1#--mirror=}"; shift ;;
            --mirror)             _need_opt_val $# "$1"; cli_mirror="$2"; shift 2 ;;
            --installer=*)        cli_installer="${1#--installer=}"; shift ;;
            --installer)          _need_opt_val $# "$1"; cli_installer="$2"; shift 2 ;;
            --desktop=*)          cli_desktop="${1#--desktop=}"; shift ;;
            --desktop)            _need_opt_val $# "$1"; cli_desktop="$2"; shift 2 ;;
            --kde=*)              cli_kde="${1#--kde=}"; shift ;;
            --kde)                _need_opt_val $# "$1"; cli_kde="$2"; shift 2 ;;
            --mate=*)             cli_mate="${1#--mate=}"; shift ;;
            --mate)               _need_opt_val $# "$1"; cli_mate="$2"; shift 2 ;;
            --mate-extras)        cli_mate_extras_set=1; cli_mate_extras=1; shift ;;
            --no-mate-extras)     cli_mate_extras_set=1; cli_mate_extras=0; shift ;;
            --brave=*)            cli_brave="${1#--brave=}"; shift ;;
            --brave)              _need_opt_val $# "$1"; cli_brave="$2"; shift 2 ;;
            --librewolf)          cli_librewolf_set=1; cli_librewolf=1; shift ;;
            --no-librewolf)       cli_librewolf_set=1; cli_librewolf=0; shift ;;
            --firefox)            cli_firefox_set=1; cli_firefox=1; shift ;;
            --no-firefox)         cli_firefox_set=1; cli_firefox=0; shift ;;
            --firefox-esr)        cli_firefox_esr_set=1; cli_firefox_esr=1; shift ;;
            --no-firefox-esr)     cli_firefox_esr_set=1; cli_firefox_esr=0; shift ;;
            --firefox-popos)      cli_firefox_popos_set=1; cli_firefox_popos=1; shift ;;
            --no-firefox-popos)   cli_firefox_popos_set=1; cli_firefox_popos=0; shift ;;
            --thunderbird)        cli_thunderbird_set=1; cli_thunderbird=1; shift ;;
            --no-thunderbird)     cli_thunderbird_set=1; cli_thunderbird=0; shift ;;
            --ubuntu-studio)      cli_ubuntustudio_set=1; cli_ubuntustudio=1; shift ;;
            --no-ubuntu-studio)   cli_ubuntustudio_set=1; cli_ubuntustudio=0; shift ;;
            --system76-driver)    cli_system76_driver_set=1; cli_system76_driver=1; shift ;;
            --no-system76-driver) cli_system76_driver_set=1; cli_system76_driver=0; shift ;;
            --pacstall)           cli_pacstall_set=1; cli_pacstall=1; shift ;;
            --no-pacstall)        cli_pacstall_set=1; cli_pacstall=0; shift ;;
            --fwupd)              cli_fwupd_set=1; cli_fwupd=1; shift ;;
            --no-fwupd)           cli_fwupd_set=1; cli_fwupd=0; shift ;;
            --openssh-server)     cli_openssh_set=1; cli_openssh=1; shift ;;
            --no-openssh-server)  cli_openssh_set=1; cli_openssh=0; shift ;;
            --cockpit)            cli_cockpit_set=1; cli_cockpit=1; shift ;;
            --no-cockpit)         cli_cockpit_set=1; cli_cockpit=0; shift ;;
            --locale=*)           cli_locale="${1#--locale=}"; shift ;;
            --locale)             _need_opt_val $# "$1"; cli_locale="$2"; shift 2 ;;
            --keyboard-layout=*)  cli_keyboard_layout="${1#--keyboard-layout=}"; shift ;;
            --keyboard-layout)    _need_opt_val $# "$1"; cli_keyboard_layout="$2"; shift 2 ;;
            --keyboard-variant=*) cli_keyboard_variant="${1#--keyboard-variant=}"; shift ;;
            --keyboard-variant)   _need_opt_val $# "$1"; cli_keyboard_variant="$2"; shift 2 ;;
            --network=*)          cli_network="${1#--network=}"; shift ;;
            --network)            _need_opt_val $# "$1"; cli_network="$2"; shift 2 ;;
            --alloc-tool=*)       cli_alloc="${1#--alloc-tool=}"; shift ;;
            --alloc-tool)         _need_opt_val $# "$1"; cli_alloc="$2"; shift 2 ;;
            --firmware=*)         cli_firmware="${1#--firmware=}"; shift ;;
            --firmware)           _need_opt_val $# "$1"; cli_firmware="$2"; shift 2 ;;
            --disk-size=*)        cli_disk_size="${1#--disk-size=}"; shift ;;
            --disk-size)          _need_opt_val $# "$1"; cli_disk_size="$2"; shift 2 ;;
            --profile=*)          cli_profile="${1#--profile=}"; shift ;;
            --profile)            _need_opt_val $# "$1"; cli_profile="$2"; shift 2 ;;
            --user-mode=*)        cli_user_mode="${1#--user-mode=}"; shift ;;
            --user-mode)          _need_opt_val $# "$1"; cli_user_mode="$2"; shift 2 ;;
            --username=*)         cli_username="${1#--username=}"; shift ;;
            --username)           _need_opt_val $# "$1"; cli_username="$2"; shift 2 ;;
            --password=*)         cli_password="${1#--password=}"; shift ;;
            --password)           _need_opt_val $# "$1"; cli_password="$2"; shift 2 ;;
            --fullname=*)         cli_fullname="${1#--fullname=}"; shift ;;
            --fullname)           _need_opt_val $# "$1"; cli_fullname="$2"; shift 2 ;;
            --hostname=*)         cli_hostname="${1#--hostname=}"; shift ;;
            --hostname)           _need_opt_val $# "$1"; cli_hostname="$2"; shift 2 ;;
            --formats=*)          cli_formats="${1#--formats=}"; shift ;;
            --formats)            _need_opt_val $# "$1"; cli_formats="$2"; shift 2 ;;
            --ui=*)               cli_ui="${1#--ui=}"; shift ;;
            --ui)                 _need_opt_val $# "$1"; cli_ui="$2"; shift 2 ;;
            --no-color)           ui_disable_color; shift ;;
            --screen)             cli_screen_set=1; cli_screen=1; shift ;;
            --no-screen)          cli_screen_set=1; cli_screen=0; shift ;;
            --config=*)           cli_config="${1#--config=}"; shift ;;
            --config)             _need_opt_val $# "$1"; cli_config="$2"; shift 2 ;;
            --interactive)        cli_interactive="1"; shift ;;
            --no-interactive)     cli_interactive="0"; shift ;;
            --hooks-dir=*)        cli_hooks_dir="${1#--hooks-dir=}"; shift ;;
            --hooks-dir)          _need_opt_val $# "$1"; cli_hooks_dir="$2"; shift 2 ;;
            --advanced)           export ADVANCED_MODE=1; ADVANCED_MODE_EXPLICIT=1; shift ;;
            --generate-config)    cli_gen_config=1; shift ;;
            -h|--help)            host_help "" ;;
            --)                   shift; args+=("$@"); break ;;
            --*)
                ui_err "Unknown option '$1'. Run '$0 --help' to see supported options."
                exit 1
                ;;
            *)                    args+=("$1"); shift ;;
        esac
    done
    set -- "${args[@]}"

    if [[ -n "$cli_ui" ]]; then
        export UVB_UI_MODE="$cli_ui"
        normalize_ui_mode
    fi

    if [[ "$cli_gen_config" -eq 1 ]]; then
        export ADVANCED_MODE=1
        [[ "$cli_interactive" == "1" ]] && FORCE_INTERACTIVE=1
        CLI_CONFIG_PATH="$cli_config" generate_config_wizard
    fi

    if [[ "${UVB_FORCE_NONINTERACTIVE_RUN:-0}" == "1" ]]; then
        ADVANCED_MODE_EXPLICIT=1
        exec 0</dev/null
        export NO_CONFIRM=1
    elif [[ "$ADVANCED_MODE_EXPLICIT" -eq 0 ]]; then
        interactive_mode_pick
    fi

    local default_cfg
    default_cfg="$(default_config_filename)"
    if [[ "${ADVANCED_MODE:-0}" == "1" ]]; then
        if [[ -n "$cli_config" ]]; then
            load_config_file "$cli_config"
        elif [[ -f "$SCRIPT_DIR/$default_cfg" ]]; then
            load_config_file "$SCRIPT_DIR/$default_cfg"
        fi
    elif [[ -n "$cli_config" ]]; then
        ui_warn "--config requires --advanced mode. Ignoring config file."
    fi

    if [[ "${UVB_FORCE_NONINTERACTIVE_RUN:-0}" == "1" ]]; then
        FORCE_INTERACTIVE=0
    elif [[ "${ADVANCED_MODE:-0}" != "1" ]]; then
        if [[ -n "$cli_interactive" ]] || [[ -n "${INTERACTIVE:-}" ]]; then
            ui_warn "--interactive / --no-interactive / INTERACTIVE require --advanced mode. Ignoring."
        fi
    elif [[ "$cli_interactive" == "0" ]] || [[ "${INTERACTIVE:-}" == "0" && -z "$cli_interactive" ]]; then
        exec 0</dev/null
        export NO_CONFIRM=1
    elif [[ "$cli_interactive" == "1" ]] || [[ "${INTERACTIVE:-}" == "1" ]]; then
        FORCE_INTERACTIVE=1
    fi

    resolve_ui_mode

    # Re-apply explicit CLI flags so CLI > config > env > prompts > defaults holds everywhere.
    [[ -n "$cli_hooks_dir" ]]          && HOOKS_DIR="$cli_hooks_dir"
    [[ -n "$cli_release" ]]            && export TARGET_UBUNTU_VERSION="$cli_release"
    [[ -n "$cli_arch" ]]               && export TARGET_ARCH="$cli_arch"
    [[ -n "$cli_mirror" ]]             && export TARGET_UBUNTU_MIRROR="$cli_mirror"
    [[ -n "$cli_kernel" ]]             && export TARGET_KERNEL_FLAVOR="$cli_kernel"
    [[ -n "$cli_installer" ]]          && export TARGET_INSTALLER="$cli_installer"
    [[ -n "$cli_desktop" ]]            && export TARGET_DESKTOP="$cli_desktop"
    [[ -n "$cli_kde" ]]                && export TARGET_KDE_PACKAGE="$cli_kde"
    [[ -n "$cli_mate" ]]               && export TARGET_MATE_PACKAGE="$cli_mate"
    [[ "$cli_mate_extras_set" -eq 1 ]] && export TARGET_MATE_EXTRAS="$cli_mate_extras"
    [[ -n "$cli_brave" ]]              && export TARGET_BRAVE_CHANNEL="$cli_brave"
    [[ "$cli_librewolf_set" -eq 1 ]]   && export TARGET_LIBREWOLF="$cli_librewolf"
    if [[ "$cli_firefox_set" -eq 1 ]]; then
        export TARGET_FIREFOX="$cli_firefox"
        [[ "$cli_firefox" == "1" ]] && export TARGET_FIREFOX_ESR="${TARGET_FIREFOX_ESR:-0}" TARGET_FIREFOX_POPOS="${TARGET_FIREFOX_POPOS:-0}"
    fi
    if [[ "$cli_firefox_esr_set" -eq 1 ]]; then
        export TARGET_FIREFOX_ESR="$cli_firefox_esr"
        [[ "$cli_firefox_esr" == "1" ]] && export TARGET_FIREFOX="${TARGET_FIREFOX:-0}" TARGET_FIREFOX_POPOS="${TARGET_FIREFOX_POPOS:-0}"
    fi
    if [[ "$cli_firefox_popos_set" -eq 1 ]]; then
        export TARGET_FIREFOX_POPOS="$cli_firefox_popos"
        [[ "$cli_firefox_popos" == "1" ]] && export TARGET_FIREFOX="${TARGET_FIREFOX:-0}" TARGET_FIREFOX_ESR="${TARGET_FIREFOX_ESR:-0}"
    fi
    [[ "$cli_thunderbird_set" -eq 1 ]]     && export TARGET_THUNDERBIRD="$cli_thunderbird"
    [[ "$cli_ubuntustudio_set" -eq 1 ]]    && export TARGET_UBUNTU_STUDIO="$cli_ubuntustudio"
    [[ "$cli_system76_driver_set" -eq 1 ]] && export TARGET_SYSTEM76_DRIVER="$cli_system76_driver"
    [[ "$cli_pacstall_set" -eq 1 ]]        && export TARGET_PACSTALL="$cli_pacstall"
    [[ "$cli_fwupd_set" -eq 1 ]]           && export TARGET_FWUPD="$cli_fwupd"
    [[ "$cli_openssh_set" -eq 1 ]]         && export TARGET_OPENSSH_SERVER="$cli_openssh"
    [[ "$cli_cockpit_set" -eq 1 ]]         && export TARGET_COCKPIT="$cli_cockpit"
    [[ -n "$cli_locale" ]]                 && export TARGET_LOCALE="$cli_locale"
    [[ -n "$cli_keyboard_layout" ]]        && export TARGET_KEYBOARD_LAYOUT="$cli_keyboard_layout"
    [[ -n "$cli_keyboard_variant" ]]       && export TARGET_KEYBOARD_VARIANT="$cli_keyboard_variant"
    [[ -n "$cli_network" ]]                && export TARGET_NETWORK_STACK="$cli_network"
    [[ -n "$cli_alloc" ]]                  && export TARGET_IMG_ALLOC="$cli_alloc"
    [[ -n "$cli_firmware" ]]               && export TARGET_FIRMWARE="$cli_firmware"
    [[ -n "$cli_disk_size" ]]              && export TARGET_DISK_SIZE_GB="$cli_disk_size"
    [[ -n "$cli_profile" ]]                && export TARGET_IMAGE_PROFILE="$cli_profile"
    [[ -n "$cli_user_mode" ]]              && export TARGET_USER_MODE="$cli_user_mode"
    [[ -n "$cli_username" ]]               && export TARGET_USERNAME="$cli_username"
    [[ -n "$cli_password" ]]               && export TARGET_USER_PASSWORD="$cli_password"
    [[ -n "$cli_fullname" ]]               && export TARGET_USER_FULLNAME="$cli_fullname"
    [[ -n "$cli_hostname" ]]               && export TARGET_HOSTNAME="$cli_hostname"
    [[ -n "$cli_formats" ]]                && export TARGET_VM_FORMATS="$cli_formats"

    # Validate legacy Ubiquity removal early if specified via CLI/config/env.
    if [[ "${TARGET_INSTALLER:-calamares}" == "ubiquity" ]]; then
        ui_err "Ubiquity has been removed (Ubuntu 22.04 jammy support ended). Use Calamares (--installer=calamares) or the CLI installer."
        exit 1
    fi

    cd "$SCRIPT_DIR" || exit 1
    resolve_workspace_paths

    local title_distro="Ubuntu" title_kind="ISO"
    [[ "$UVB_DISTRO" == "popos" ]] && title_distro="Pop!_OS"
    case "$UVB_OUTPUT_KIND" in
        cloud)     title_kind="Cloud Image" ;;
        vm)        title_kind="VM Image" ;;
        removable) title_kind="Removable Image" ;;
    esac
    ui_banner "${title_distro} Vanilla ${title_kind} Builder"
    ui_kv "Script"     "$0"
    ui_kv "Workspace"  "$WORKSPACE_DIR"
    ui_kv "Output dir" "$OUTPUT_DIR"
    ui_kv "Started at" "$(date '+%Y-%m-%d %H:%M:%S %Z')"

    # Early non-destructive checks before acquiring sudo.
    resolve_release_choice
    assert_supported_release || exit 1
    resolve_arch_choice
    resolve_mirror_default
    resolve_devel_metadata

    resolve_profile_choice
    resolve_network_stack_choice
    if [[ "$UVB_OUTPUT_KIND" != "iso" ]]; then
        disk_image_resolve_options
    fi
    resolve_kernel_choice
    resolve_desktop_choice
    normalize_desktop_variant
    if [[ -z "${TARGET_NAME:-}" ]]; then
        export TARGET_NAME
        TARGET_NAME="$(default_target_name)"
    fi
    resolve_gnome_recommends_choice
    resolve_kde_package_choice
    resolve_mate_choice
    resolve_browser_selection
    resolve_ubuntu_studio_choice
    resolve_pacstall_choice
    if [[ "$UVB_DISTRO" == "popos" ]]; then
        resolve_system76_driver_choice
    fi
    resolve_optional_service_choices
    if [[ "$UVB_OUTPUT_KIND" != "iso" ]]; then
        disk_image_resolve_credentials
    fi

    check_common_settings
    if [[ "$UVB_OUTPUT_KIND" == "iso" ]]; then
        iso_check_settings
    else
        disk_image_check_settings
    fi
    set_target_kernel_package_from_flavor
    local start_index end_index
    parse_cmd_range HOST_CMD host_help "$@"
    check_host_user

    print_build_summary
    ui_info "Phases to run: ${HOST_CMD[*]:$start_index:$((end_index - start_index))}"

    # Storage check & optional GNU screen detached launch (only if not already inside screen).
    local req_gb avail_gb
    req_gb="$(uvb_single_build_req_gb "$UVB_OUTPUT_KIND" "${TARGET_DISK_SIZE_GB:-16}" "${TARGET_VM_FORMATS:-qcow2}")"
    avail_gb="$(uvb_available_gb "$WORKSPACE_DIR")"
    ui_info "Storage check: ${avail_gb} GB free on workspace filesystem (recommended >= ${req_gb} GB for this build)."
    if (( avail_gb < req_gb )); then
        ui_warn "Low free disk space (${avail_gb} GB free < ${req_gb} GB recommended)."
    fi

    if [[ -z "${STY:-}" && -z "${UVB_IN_SCREEN:-}" ]]; then
        local launch_in_screen=0
        if [[ "$cli_screen_set" -eq 1 && "$cli_screen" -eq 1 ]]; then
            launch_in_screen=1
        elif [[ "$cli_screen_set" -eq 0 && "${LAUNCHED_FROM_START_HERE:-0}" -eq 0 ]] && prompts_enabled && uvb_screen_available; then
            if ui_confirm "Detach and run this build inside a GNU screen session (lets you keep using this terminal)?" n; then
                launch_in_screen=1
            fi
        fi

        if [[ "$launch_in_screen" -eq 1 ]]; then
            local sess_name="uvb-${UVB_DISTRO}-${UVB_OUTPUT_KIND}-${TARGET_ARCH}-${DATE}"
            local log_file
            log_file="$(invoking_user_home)/uvb-logs/${sess_name}.log"
            local -a screen_stage_args=()
            if (( end_index - start_index == 1 )); then
                screen_stage_args=("${HOST_CMD[$start_index]}")
            else
                screen_stage_args=("${HOST_CMD[$start_index]}" "-" "${HOST_CMD[$((end_index - 1))]}")
            fi
            # Pass resolved variables explicitly via env inside the detached screen command.
            export UVB_IN_SCREEN=1 UVB_FORCE_NONINTERACTIVE_RUN=1 NO_CONFIRM=1 LAUNCHED_FROM_START_HERE=0
            export ADVANCED_MODE="${ADVANCED_MODE:-0}"
            export UBUNTU_VANILLA_WORKSPACE="${WORKSPACE_DIR%/*}" UVB_OUTPUT_DIR="${OUTPUT_DIR}"
            export TARGET_NAME TARGET_UBUNTU_MIRROR HOOKS_DIR UVB_UI_MODE
            uvb_launch_screen_session "$sess_name" "$log_file" \
                env UVB_IN_SCREEN=1 UVB_FORCE_NONINTERACTIVE_RUN=1 NO_CONFIRM=1 LAUNCHED_FROM_START_HERE=0 \
                ADVANCED_MODE="${ADVANCED_MODE:-0}" \
                UBUNTU_VANILLA_WORKSPACE="${WORKSPACE_DIR%/*}" UVB_OUTPUT_DIR="${OUTPUT_DIR}" \
                TARGET_UBUNTU_VERSION="${TARGET_UBUNTU_VERSION:-}" TARGET_ARCH="${TARGET_ARCH:-amd64}" \
                TARGET_IMAGE_PROFILE="${TARGET_IMAGE_PROFILE:-desktop}" \
                TARGET_KERNEL_FLAVOR="${TARGET_KERNEL_FLAVOR:-}" TARGET_KERNEL_PACKAGE="${TARGET_KERNEL_PACKAGE:-}" \
                TARGET_DESKTOP="${TARGET_DESKTOP:-gnome}" TARGET_NETWORK_STACK="${TARGET_NETWORK_STACK:-network-manager}" \
                TARGET_NAME="${TARGET_NAME}" TARGET_UBUNTU_MIRROR="${TARGET_UBUNTU_MIRROR}" \
                HOOKS_DIR="${HOOKS_DIR:-}" UVB_UI_MODE="${UVB_UI_MODE:-cli}" \
                "${SCRIPT_DIR}/${SCRIPT_NAME}" "${screen_stage_args[@]}"
            ui_ok "Started GNU screen session: ${sess_name}"
            ui_info "Attach with: screen -r ${sess_name}"
            ui_info "Log file:    ${log_file}"
            exit 0
        fi
    fi

    echo
    if prompts_enabled && [[ "${NO_CONFIRM:-0}" != "1" ]]; then
        if ! ui_confirm "Start build now?" y; then
            echo
            ui_info "Build cancelled by user. No changes were made."
            exit 0
        fi
    fi

    HOST_ABORT_CLEANUP_DONE=0
    trap host_build_exit_trap EXIT
    trap 'host_build_signal_trap 130' INT
    trap 'host_build_signal_trap 143' TERM

    setup_sudo_keepalive

    local total=$((end_index - start_index))
    local i
    for ((i=start_index; i<end_index; i++)); do
        ui_step "$((i - start_index + 1))" "$total" "${HOST_CMD[i]}"
        "${HOST_CMD[i]}"
    done

    if [[ "$UVB_OUTPUT_KIND" == "iso" ]]; then
        iso_print_build_result
    else
        disk_image_print_build_result
    fi
}

function chroot_help() {
    echo "Supported commands: ${CHROOT_CMD[*]}"
    echo
    echo "Syntax: $0 --chroot-internal [start_cmd] [-] [end_cmd]"
    exit 0
}

function chroot_main() {
    shift
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        chroot_help
    fi
    set_defaults
    export TARGET_ARCH="${TARGET_ARCH:-amd64}"
    export TARGET_IMAGE_PROFILE="${TARGET_IMAGE_PROFILE:-desktop}"
    export TARGET_DESKTOP="${TARGET_DESKTOP:-gnome}"
    export TARGET_KDE_PACKAGE="${TARGET_KDE_PACKAGE:-kde-standard}"
    export TARGET_MATE_PACKAGE="${TARGET_MATE_PACKAGE:-mate-desktop-environment}"
    export TARGET_MATE_EXTRAS="${TARGET_MATE_EXTRAS:-0}"
    export TARGET_INSTALLER="${TARGET_INSTALLER:-calamares}"
    resolve_mirror_default
    normalize_arch_variant
    normalize_desktop_variant
    export TARGET_BRAVE_CHANNEL="${TARGET_BRAVE_CHANNEL:-release}"
    export TARGET_LIBREWOLF="${TARGET_LIBREWOLF:-0}"
    export TARGET_FIREFOX="${TARGET_FIREFOX:-0}"
    export TARGET_FIREFOX_ESR="${TARGET_FIREFOX_ESR:-0}"
    export TARGET_FIREFOX_POPOS="${TARGET_FIREFOX_POPOS:-0}"
    export TARGET_THUNDERBIRD="${TARGET_THUNDERBIRD:-0}"
    export TARGET_UBUNTU_STUDIO="${TARGET_UBUNTU_STUDIO:-0}"
    export TARGET_SYSTEM76_DRIVER="${TARGET_SYSTEM76_DRIVER:-0}"
    export TARGET_FWUPD="${TARGET_FWUPD:-0}"
    export TARGET_OPENSSH_SERVER="${TARGET_OPENSSH_SERVER:-0}"
    export TARGET_COCKPIT="${TARGET_COCKPIT:-0}"

    check_common_settings
    if [[ "$UVB_OUTPUT_KIND" == "iso" ]]; then
        iso_check_settings
    else
        disk_image_check_settings
    fi
    set_target_kernel_package_from_flavor

    if [[ "$(id -u)" -ne 0 ]]; then
        ui_err "The chroot phase must run as root."
        exit 1
    fi
    export HOME=/root
    export LC_ALL=C

    local start_index end_index
    parse_cmd_range CHROOT_CMD chroot_help "$@"

    local i
    for ((i=start_index; i<end_index; i++)); do
        "${CHROOT_CMD[i]}"
    done

    echo "$0 --chroot-internal - Chroot phase done."
}
