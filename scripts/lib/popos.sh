#!/bin/bash
# Pop!_OS-specific repository setup, pop-default-settings branding & pinning,
# Plymouth/GRUB/desktop theming, COSMIC variant, native Firefox helper, and
# System76 driver support.

POP_APT_URL="https://apt.pop-os.org"
POP_APT_ORIGIN_URL="https://apt-origin.pop-os.org"
POP_KEY_FINGERPRINT="63C46DF0140D738961429F4E204DD8AEC33A7AFF"
POP_PREF_DIVERT_TARGET="/etc/apt/pop-default-settings.pref.diverted"

function install_firefox_from_popos() {
    echo "=====> Firefox: installing the native build from the Pop!_OS repository"

    cat <<'EOF' > /etc/apt/preferences.d/firefox-popos
Package: firefox firefox-locale-*
Pin: release o=pop-os-release
Pin-Priority: 1001
EOF

    local candidate uri size depends
    candidate="$(apt-cache policy firefox | awk '/Candidate:/ {print $2; exit}')"
    if [[ -z "$candidate" || "$candidate" == "(none)" ]]; then
        >&2 echo "ERROR: the Pop!_OS repositories provide no firefox candidate for '${TARGET_UBUNTU_VERSION}' (${TARGET_ARCH:-amd64})."
        >&2 echo "       Re-run with TARGET_FIREFOX=1 to use Mozilla's APT build instead."
        exit 1
    fi
    uri="$(apt-get install --reinstall --print-uris -y --allow-downgrades firefox 2>/dev/null \
        | awk -F"'" '$2 ~ /\/firefox_/ {print $2; exit}')"
    size="$(apt-cache show "firefox=${candidate}" 2>/dev/null | awk '/^Size:/ {print $2; exit}')"
    depends="$(apt-cache show "firefox=${candidate}" 2>/dev/null | awk -F': ' '/^(Pre-)?Depends:/ {print $2}')"

    if [[ "$uri" != "${POP_APT_URL}/"* && "$uri" != "${POP_APT_ORIGIN_URL}/"* ]]; then
        >&2 echo "ERROR: firefox candidate '${candidate}' does not come from the Pop!_OS repos (URI: ${uri:-unknown})."
        exit 1
    fi
    if [[ "$depends" == *snap* ]]; then
        >&2 echo "ERROR: firefox candidate '${candidate}' depends on snapd."
        exit 1
    fi
    if [[ ! "$size" =~ ^[0-9]+$ ]] || (( size <= 10485760 )); then
        >&2 echo "ERROR: firefox candidate '${candidate}' .deb is ${size:-unknown} bytes (<= 10 MB)."
        exit 1
    fi
    echo "=====> Firefox ${candidate}: $(( size / 1024 / 1024 )) MB deb from ${uri%%/pool/*}, genuine native build."
    apt-get install -y --allow-downgrades firefox
}

function neutralize_pop_default_settings_blanket_pin() {
    install -d /etc/apt/preferences.d
    # /etc/apt/preferences.d/pop-default-settings is NOT a dpkg conffile, so
    # divert it outside preferences.d before/after package updates so future
    # pop-default-settings upgrades cannot restore the blanket "Package: *" pin.
    if [[ "$(dpkg-divert --listpackage /etc/apt/preferences.d/pop-default-settings 2>/dev/null || true)" != "LOCAL" ]]; then
        if [[ -e /etc/apt/preferences.d/pop-default-settings ]]; then
            mv -f /etc/apt/preferences.d/pop-default-settings "$POP_PREF_DIVERT_TARGET"
        fi
        dpkg-divert --local --no-rename --divert "$POP_PREF_DIVERT_TARGET" \
            --add /etc/apt/preferences.d/pop-default-settings >/dev/null 2>&1 || true
    fi
    cat <<'EOF' > /etc/apt/preferences.d/pop-default-settings
# Blanket "Package: *" pin diverted to /etc/apt/pop-default-settings.pref.diverted
# by build-popos so standard Ubuntu desktops (such as vanilla-gnome-desktop)
# remain installable without dependency conflicts. Scoped pins live in pop-os-release.
EOF
}

function write_popos_scoped_apt_pin() {
    install -d /etc/apt/preferences.d
    # Deliberately omit update-manager-core, ubuntu-release-upgrader-*, systemd*,
    # and udev* so vanilla-gnome-desktop and Ubuntu base security updates stay conflict-free.
    cat <<'EOF' > /etc/apt/preferences.d/pop-os-release
Package: base-files pop-* plymouth-theme-pop* grub-theme-pop grub-pop-* cosmic-* libcosmic* xdg-desktop-portal-cosmic cutecosmic* popsicle* linux-system76* linux-image-system76* linux-headers-system76* system76-* repolib python3-repolib repoman hidpi-daemon libsystem76* libs76-* gnome-shell-extension-system76* gnome-shell-extension-pop* gnome-shell-extension-alt-tab-raise-first-window gnome-shell-extension-always-show-workspaces gnome-shell-extension-do-not-disturb adw-gtk3 appstream-data-pop* network-manager-config-connectivity-pop greetd
Pin: release o=pop-os-release
Pin-Priority: 1001
EOF
}

function install_popos_system76_driver() {
    echo "=====> System76 hardware driver: system76-driver (from Pop!_OS repos)"
    apt-get install -y system76-driver
    neutralize_pop_default_settings_blanket_pin
}

function resolve_system76_driver_choice() {
    if [[ -n "${TARGET_SYSTEM76_DRIVER+x}" ]]; then
        export TARGET_SYSTEM76_DRIVER="${TARGET_SYSTEM76_DRIVER:-0}"
        return 0
    fi
    if prompts_enabled; then
        interactive_toggle_pick TARGET_SYSTEM76_DRIVER \
            "System76 hardware driver" \
            "Pre-install system76-driver (recommended only for System76 hardware)" \
            "Skip the System76 driver" \
            "System76 driver"
    else
        export TARGET_SYSTEM76_DRIVER=0
    fi
}

function setup_pop_apt_repos() {
    echo "=====> configuring Pop!_OS APT repositories from ${POP_APT_URL} (staging excluded) ..."

    apt-get install -y gnupg dirmngr ca-certificates curl

    install -d /usr/share/keyrings /etc/apt/sources.list.d /etc/apt/preferences.d

    local keyring="/usr/share/keyrings/pop-os-archive-keyring.gpg"
    local tmp_gpg_home
    tmp_gpg_home="$(mktemp -d)"
    gpg --homedir "$tmp_gpg_home" --batch --keyserver hkps://keyserver.ubuntu.com \
        --recv-keys "$POP_KEY_FINGERPRINT"
    gpg --homedir "$tmp_gpg_home" --batch --export "$POP_KEY_FINGERPRINT" > "$keyring"
    rm -rf "$tmp_gpg_home"

    local name base url srcfile added_any=0
    local release_url="" proprietary_url="" release_ubuntu_url=""
    rm -f /etc/apt/sources.list.d/pop-os-{release,proprietary,release-ubuntu}.list
    for name in release proprietary release-ubuntu; do
        case "$name" in
            release)        srcfile=/etc/apt/sources.list.d/pop-os-release.sources ;;
            proprietary)    srcfile=/etc/apt/sources.list.d/pop-os-apps.sources ;;
            release-ubuntu) srcfile=/etc/apt/sources.list.d/pop-os-release-ubuntu.sources ;;
        esac
        url=""
        for base in "$POP_APT_URL" "$POP_APT_ORIGIN_URL"; do
            if curl -fsIL "${base}/${name}/dists/${TARGET_UBUNTU_VERSION}/Release" >/dev/null 2>&1; then
                url="${base}/${name}"
                break
            fi
        done
        case "$name" in
            release)        release_url="$url" ;;
            proprietary)    proprietary_url="$url" ;;
            release-ubuntu) release_ubuntu_url="$url" ;;
        esac
        if [[ -n "$url" ]]; then
            cat <<EOF > "$srcfile"
X-Repolib-Name: Pop_OS ${name}
Enabled: yes
Types: deb
URIs: ${url}
Suites: ${TARGET_UBUNTU_VERSION}
Components: main
Signed-By: ${keyring}
EOF
            echo "=====> Pop!_OS APT: added ${url} ${TARGET_UBUNTU_VERSION} main (${srcfile##*/})"
            [[ "$url" == "${POP_APT_ORIGIN_URL}/"* ]] && \
                echo "  WARN  ${name}: using origin server; downloads may be less reliable." >&2
            added_any=1
        else
            echo "  WARN  ${name} '${TARGET_UBUNTU_VERSION}' is unreachable -- writing disabled stub." >&2
            cat <<EOF > "$srcfile"
X-Repolib-Name: Pop_OS ${name}
Enabled: no
Types: deb
URIs: ${POP_APT_URL}/${name}
Suites: ${TARGET_UBUNTU_VERSION}
Components: main
Signed-By: ${keyring}
EOF
        fi
    done
    if [[ "$added_any" -eq 0 ]]; then
        >&2 echo "ERROR: none of the Pop!_OS suites could be added for '${TARGET_UBUNTU_VERSION}'."
        exit 1
    fi

    write_popos_scoped_apt_pin
    neutralize_pop_default_settings_blanket_pin

    apt-get update

    apt-get install -y pop-keyring || \
        echo "  WARN  pop-keyring not installable; keeping keyserver-fetched key." >&2

    # Pop!_OS 24.04+ ships OS branding (/etc/os-release, /etc/lsb-release, /etc/issue,
    # motd, pop-os-branding icons, plymouth-theme-pop-basic) via pop-default-settings
    # using dpkg-divert rather than a forked base-files package.
    echo "=====> installing pop-default-settings (Pop!_OS branding & defaults) ..."
    if apt-cache show pop-default-settings >/dev/null 2>&1; then
        apt-get install -y pop-default-settings
        neutralize_pop_default_settings_blanket_pin

        # pop-default-settings.postinst calls `apt-manage modify system --default-mirror`
        # which disables ubuntu.sources and forces http://apt.pop-os.org/ubuntu in
        # system.sources (breaking arm64/ports.ubuntu.com and custom --mirror values)
        # and rewrites pop-os-apps.sources to HTTP. Restore the configured mirror + HTTPS.
        rm -f /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list.d/ubuntu.sources.disabled
        local sys_keyring=""
        if [[ -f /usr/share/keyrings/ubuntu-archive-keyring.gpg ]]; then
            sys_keyring="/usr/share/keyrings/ubuntu-archive-keyring.gpg"
        elif [[ -f /etc/apt/trusted.gpg.d/ubuntu-keyring-2018-archive.gpg ]]; then
            sys_keyring="/etc/apt/trusted.gpg.d/ubuntu-keyring-2018-archive.gpg"
        fi
        local suites="${TARGET_UBUNTU_VERSION} ${TARGET_UBUNTU_VERSION}-updates ${TARGET_UBUNTU_VERSION}-backports ${TARGET_UBUNTU_VERSION}-security"
        {
            echo "X-Repolib-Name: Pop_OS System Sources"
            echo "Enabled: yes"
            echo "Types: deb deb-src"
            echo "URIs: ${TARGET_UBUNTU_MIRROR}"
            echo "Suites: ${suites}"
            echo "Components: main restricted universe multiverse"
            [[ -n "$sys_keyring" ]] && echo "Signed-By: ${sys_keyring}"
            echo "X-Repolib-Default-Mirror: ${TARGET_UBUNTU_MIRROR}"
            echo "X-Repolib-ID: system"
        } > /etc/apt/sources.list.d/system.sources
        if [[ -n "$proprietary_url" ]]; then
            cat <<EOF > /etc/apt/sources.list.d/pop-os-apps.sources
X-Repolib-Name: Pop_OS Applications
Enabled: yes
Types: deb
URIs: ${proprietary_url}
Suites: ${TARGET_UBUNTU_VERSION}
Components: main
Signed-By: ${keyring}
EOF
        fi
        # Ensure release/release-ubuntu remain intact as configured above.
        if [[ -n "$release_url" ]]; then
            cat <<EOF > /etc/apt/sources.list.d/pop-os-release.sources
X-Repolib-Name: Pop_OS release
Enabled: yes
Types: deb
URIs: ${release_url}
Suites: ${TARGET_UBUNTU_VERSION}
Components: main
Signed-By: ${keyring}
EOF
        fi
        if [[ -n "$release_ubuntu_url" ]]; then
            cat <<EOF > /etc/apt/sources.list.d/pop-os-release-ubuntu.sources
X-Repolib-Name: Pop_OS release-ubuntu
Enabled: yes
Types: deb
URIs: ${release_ubuntu_url}
Suites: ${TARGET_UBUNTU_VERSION}
Components: main
Signed-By: ${keyring}
EOF
        fi

        apt-get update
        apt_install_available "Pop!_OS default settings extras" \
            pop-default-settings-zram \
            pop-default-settings-ntsync
    else
        echo "=====> pop-default-settings unavailable; falling back to base-files ..."
        apt-get install -y --allow-downgrades base-files
    fi

    if grep -qs '^ID=pop$' /etc/os-release; then
        # shellcheck source=/dev/null
        echo "=====> /etc/os-release: $(. /etc/os-release && echo "${PRETTY_NAME:-${NAME:-unknown}}")"
    else
        echo "  WARN  /etc/os-release does not report ID=pop for '${TARGET_UBUNTU_VERSION}'." >&2
    fi
}

function ensure_popos_plymouth_alternatives() {
    if dpkg -s plymouth-theme-ubuntu-text >/dev/null 2>&1; then
        apt-get purge -y plymouth-theme-ubuntu-text || true
    fi
    if [[ -f /usr/share/plymouth/themes/pop-basic/pop-basic.plymouth ]]; then
        update-alternatives --set default.plymouth /usr/share/plymouth/themes/pop-basic/pop-basic.plymouth 2>/dev/null || true
    fi
    if [[ -f /usr/share/plymouth/themes/text/text.plymouth ]]; then
        update-alternatives --set text.plymouth /usr/share/plymouth/themes/text/text.plymouth 2>/dev/null || true
    fi
}

function install_popos_plymouth() {
    echo "=====> Plymouth: installing Pop!_OS Plymouth theme (pop-plymouth-theme)"
    apt-get install -y plymouth plymouth-label pop-plymouth-theme plymouth-theme-pop-basic
    ensure_popos_plymouth_alternatives
}

function install_popos_grub_branding() {
    echo "=====> GRUB: configuring Pop!_OS bootloader branding"
    apt_install_available "Pop!_OS GRUB theme" grub-theme-pop

    install -d /etc/default/grub.d
    if [[ -f /usr/share/grub/themes/pop/theme.txt ]]; then
        if [[ -f /usr/share/grub/themes/pop/icons/pop-os.png ]]; then
            [[ ! -e /usr/share/grub/themes/pop/icons/pop_os.png ]] && ln -sf pop-os.png /usr/share/grub/themes/pop/icons/pop_os.png
            [[ ! -e /usr/share/grub/themes/pop/icons/pop__os.png ]] && ln -sf pop-os.png /usr/share/grub/themes/pop/icons/pop__os.png
        fi
        cat <<'EOF' > /etc/default/grub.d/50-pop-branding.cfg
# Pop!_OS GRUB branding (managed by build-popos)
GRUB_DISTRIBUTOR="Pop!_OS"
GRUB_THEME="/usr/share/grub/themes/pop/theme.txt"
EOF
    else
        cat <<'EOF' > /etc/default/grub.d/50-pop-branding.cfg
# Pop!_OS GRUB branding (managed by build-popos)
GRUB_DISTRIBUTOR="Pop!_OS"
EOF
    fi
}

function install_popos_desktop_branding() {
    echo "=====> Desktop branding: installing Pop!_OS theme, icons, sounds, fonts, and wallpapers"
    apt_install_available "Pop!_OS theme & wallpapers" \
        pop-theme \
        pop-wallpapers

    install -d /etc/gtk-3.0
    cat <<'EOF' > /etc/gtk-3.0/settings.ini
[Settings]
gtk-theme-name = Pop-dark
gtk-icon-theme-name = Pop
gtk-sound-theme-name = Pop
gtk-cursor-theme-name = Pop
gtk-icon-sizes = panel-menu-bar=24,24
EOF

    if [[ -d /usr/share/glib-2.0/schemas ]] && command -v glib-compile-schemas >/dev/null 2>&1; then
        local wall=""
        wall="$(find /usr/share/backgrounds -maxdepth 3 -type f \
            \( -iname '*pop*' -o -iname '*kate-hazen*' -o -iname '*system76*' \) \
            2>/dev/null | sort | head -n 1 || true)"
        cat <<'EOF' > /usr/share/glib-2.0/schemas/90_pop-branding.gschema.override
[org.gnome.desktop.interface]
gtk-theme = 'Pop-dark'
icon-theme = 'Pop'
cursor-theme = 'Pop'
sound-theme-name = 'Pop'
color-scheme = 'prefer-dark'

[org.gnome.desktop.sound]
theme-name = 'Pop'
EOF
        if [[ -n "$wall" ]]; then
            cat <<EOF >> /usr/share/glib-2.0/schemas/90_pop-branding.gschema.override

[org.gnome.desktop.background]
picture-uri = 'file://${wall}'
picture-uri-dark = 'file://${wall}'

[org.gnome.desktop.screensaver]
picture-uri = 'file://${wall}'
EOF
        fi
        glib-compile-schemas /usr/share/glib-2.0/schemas || true
    fi
}

function install_popos_cosmic_desktop() {
    echo "=====> desktop flavor: cosmic (full Pop!_OS COSMIC stack, CLI installer + GRUB)"
    # Install pop-de-cosmic without Recommends so firefox/thunderbird/libreoffice
    # do not bypass resolve_browser_selection(), and avoid pop-server (which pulls
    # dracut conflicting with casper/initramfs-tools, fwupd, and forced kernel).
    apt-get install -y --no-install-recommends pop-de-cosmic

    apt_install_available "COSMIC & Pop!_OS desktop suite" \
        cosmic-edit \
        cosmic-monitor \
        cosmic-player \
        cosmic-store \
        cosmic-term \
        cosmic-viewer \
        cosmic-wallpapers \
        cosmic-theme-bundles \
        cutecosmic-qt6 \
        greetd \
        mesa-vulkan-drivers \
        libegl-mesa0 \
        libglx-mesa0 \
        pop-pipewire \
        pop-launcher-system76-power \
        system76-power \
        system76-scheduler \
        network-manager-config-connectivity-pop \
        game-devices-udev \
        nm-connection-editor \
        xdg-user-dirs-gtk \
        gvfs-backends \
        gvfs-fuse \
        policykit-desktop-privileges \
        file-roller \
        evince \
        baobab \
        seahorse \
        simple-scan \
        popsicle-ui \
        popsicle \
        orca \
        speech-dispatcher \
        system-config-printer \
        fonts-noto-cjk \
        fonts-noto-color-emoji \
        gstreamer1.0-plugins-good \
        gstreamer1.0-plugins-bad \
        gstreamer1.0-vaapi \
        xorg

    install_popos_desktop_branding

    # Ensure cosmic-greeter is registered as the display manager cleanly.
    if dpkg -s cosmic-greeter >/dev/null 2>&1; then
        install -d /etc/X11 /etc/systemd/system
        echo "/usr/bin/cosmic-greeter" > /etc/X11/default-display-manager
        if [[ -e /lib/systemd/system/cosmic-greeter.service ]]; then
            ln -sf /lib/systemd/system/cosmic-greeter.service /etc/systemd/system/display-manager.service
        elif [[ -e /usr/lib/systemd/system/cosmic-greeter.service ]]; then
            ln -sf /usr/lib/systemd/system/cosmic-greeter.service /etc/systemd/system/display-manager.service
        fi
        systemctl disable greetd.service >/dev/null 2>&1 || true
        systemctl enable cosmic-greeter-daemon.service >/dev/null 2>&1 || true
        systemctl set-default graphical.target >/dev/null 2>&1 || true
    fi

    if [[ "$UVB_OUTPUT_KIND" == "iso" ]]; then
        apt_install_available "COSMIC live casper helpers" cosmic-initial-setup-casper

        # casper's 15autologin only handles gdm3/lightdm/sddm; add live-only
        # greetd [initial_session] autologin when booted with boot=casper.
        install -d /usr/local/sbin /etc/systemd/system /usr/share/applications
        cat <<'EOF' > /usr/local/sbin/uvb-live-cosmic-autologin
#!/bin/bash
set -eu
grep -qw 'boot=casper' /proc/cmdline || exit 0
live_user="popos"
if [[ -r /etc/casper.conf ]]; then
    # shellcheck source=/dev/null
    . /etc/casper.conf
    live_user="${USERNAME:-popos}"
fi
cfg="/etc/greetd/cosmic-greeter.toml"
[[ -f "$cfg" ]] || exit 0
if ! grep -q '^\[initial_session\]' "$cfg"; then
    cat <<INIT_EOF >> "$cfg"

[initial_session]
command = "cosmic-session"
user = "${live_user}"
INIT_EOF
fi
EOF
        chmod 0755 /usr/local/sbin/uvb-live-cosmic-autologin
        cat <<'EOF' > /etc/systemd/system/uvb-live-cosmic-autologin.service
[Unit]
Description=Configure live ISO COSMIC desktop autologin
ConditionKernelCommandLine=boot=casper
After=casper-md5check.service systemd-user-sessions.service
Before=display-manager.service cosmic-greeter.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/uvb-live-cosmic-autologin
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl enable uvb-live-cosmic-autologin.service

        cat <<'EOF' > /usr/share/applications/install-system.desktop
[Desktop Entry]
Type=Application
Name=Install Pop!_OS
Comment=Install Pop!_OS to disk using the CLI/TUI installer
Exec=cosmic-term -e sudo /usr/local/bin/install-system
Icon=system-software-install
Terminal=false
Categories=System;
EOF
    fi
}

function cleanup_popos_ubuntu_remnants() {
    if dpkg -s ubuntu-pro-client >/dev/null 2>&1; then
        apt-get purge -y ubuntu-pro-client ubuntu-pro-client-l10n || true
    fi
    rm -f /etc/apt/preferences.d/ubuntu-pro-esm-apps \
          /etc/apt/preferences.d/ubuntu-pro-esm-infra \
          /etc/apt/apt.conf.d/20apt-esm-hook.conf \
          /etc/update-motd.d/91-contract-ua-esm-status
}

function popos_print_cosmic_note() {
    [[ "$UVB_DISTRO" == "popos" ]] || return 0
    if [[ "${TARGET_DESKTOP:-}" == "cosmic" ]]; then
        ui_heading "COSMIC desktop (installed)"
        echo "  Full Pop!_OS COSMIC desktop stack is included with GRUB as the"
        echo "  default bootloader (512 MB ESP, no pop-installer/Calamares)."
        if [[ "$UVB_OUTPUT_KIND" == "iso" ]]; then
            echo "  On the live ISO, run 'sudo install-system' (or launch 'Install Pop!_OS'"
            echo "  from the COSMIC launcher) to install to disk."
        fi
        echo
        return 0
    fi
    case "${TARGET_UBUNTU_VERSION:-}" in
        noble|resolute)
            ui_heading "COSMIC desktop (optional)"
            echo "  To build with Pop!_OS COSMIC pre-installed (using the CLI installer + GRUB):"
            echo "      --desktop=cosmic"
            echo "  Or add COSMIC after installation on this image with:"
            echo "      sudo apt update && sudo apt install cosmic-session greetd"
            echo
            ;;
    esac
}
