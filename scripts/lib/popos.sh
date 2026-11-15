#!/bin/bash
# Pop!_OS-specific repository setup (Ubuntu-safe scoped & negative pinning),
# Plymouth/GRUB/desktop aesthetic theming, COSMIC variant, native Firefox
# helper, System76 driver support, and post-upgrade branding migration tool.

POP_APT_URL="https://apt.pop-os.org"
POP_APT_ORIGIN_URL="https://apt-origin.pop-os.org"
POP_KEY_FINGERPRINT="63C46DF0140D738961429F4E204DD8AEC33A7AFF"
POP_KEYRING_FILE="/usr/share/keyrings/pop-os-archive-keyring.gpg"
POP_RELEASE_URL=""

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

function write_popos_scoped_apt_pin() {
    install -d /etc/apt/preferences.d
    # Keep Ubuntu base behavior and end-user `apt upgrade` conflict-free:
    # elevate only Pop!_OS aesthetic, COSMIC, kernel/driver, and native app packages,
    # while blocking pop-default-settings, pop-server/pop-desktop, and Pop's
    # ubuntu-minimal/ubuntu-standard container transitionals from o=pop-os-release.
    cat <<'EOF' > /etc/apt/preferences.d/pop-os-release
Package: pop-theme pop-gtk-theme pop-icon-theme pop-sound-theme pop-gnome-shell-theme pop-fonts pop-wallpapers pop-plymouth-theme plymouth-theme-pop-basic grub-theme-pop grub-pop-* pop-de-cosmic pop-pipewire pop-launcher* pop-shell* pop-keyring pop-transition cosmic-* libcosmic* xdg-desktop-portal-cosmic cutecosmic* popsicle* linux-system76* linux-image-system76* linux-headers-system76* system76-* repolib python3-repolib repoman hidpi-daemon libsystem76* libs76-* gnome-shell-extension-system76* gnome-shell-extension-pop* gnome-shell-extension-alt-tab-raise-first-window gnome-shell-extension-always-show-workspaces gnome-shell-extension-do-not-disturb adw-gtk3 appstream-data-pop* network-manager-config-connectivity-pop greetd
Pin: release o=pop-os-release
Pin-Priority: 1001

Package: pop-default-settings pop-default-settings-* pop-server pop-desktop pop-desktop-raspi pop-container-* pop-upgrade pop-system-updater ubuntu-minimal ubuntu-standard base-files systemd systemd-* libsystemd* udev libudev* dracut dracut-*
Pin: release o=pop-os-release
Pin-Priority: -1
EOF
}

function install_popos_system76_driver() {
    echo "=====> System76 hardware driver: system76-driver (from Pop!_OS repos)"
    # Install system76-ubuntu-repo first when available so system76-driver's
    # `pop-default-settings | system76-ubuntu-repo` dependency never pulls pop-default-settings.
    if apt-cache show system76-ubuntu-repo >/dev/null 2>&1; then
        apt-get install -y system76-ubuntu-repo
    fi
    apt-get install -y system76-driver
    if [[ -f /etc/apt/sources.list.d/pop-os-release-ubuntu.sources && \
          -f /etc/apt/sources.list.d/system76-ubuntu-repo.sources ]]; then
        rm -f /etc/apt/sources.list.d/system76-ubuntu-repo.sources
    fi
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

function _popos_source_uri_from_file() {
    local file="$1"
    [[ -r "$file" ]] || return 0
    awk '/^Enabled:[[:space:]]*yes/ {en=1} /^URIs:[[:space:]]*/ {uri=$2} END {if (en && uri != "") print uri}' "$file"
}

function setup_pop_apt_repos() {
    echo "=====> configuring Pop!_OS APT repositories from ${POP_APT_URL} (Ubuntu-safe scoped pins, staging excluded) ..."

    apt-get install -y gnupg dirmngr ca-certificates curl

    install -d /usr/share/keyrings /etc/apt/sources.list.d /etc/apt/preferences.d

    local keyring="$POP_KEYRING_FILE"
    local tmp_gpg_home
    tmp_gpg_home="$(mktemp -d)"
    gpg --homedir "$tmp_gpg_home" --batch --keyserver hkps://keyserver.ubuntu.com \
        --recv-keys "$POP_KEY_FINGERPRINT"
    gpg --homedir "$tmp_gpg_home" --batch --export "$POP_KEY_FINGERPRINT" > "$keyring"
    rm -rf "$tmp_gpg_home"

    local name base url srcfile added_any=0
    POP_RELEASE_URL=""
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
        [[ "$name" == "release" ]] && POP_RELEASE_URL="$url"
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

    apt-get update

    apt-get install -y pop-keyring || \
        echo "  WARN  pop-keyring not installable; keeping keyserver-fetched key." >&2
}

function install_popos_branding_migration_helper() {
    if [[ -f /root/popos-migrate-branding ]]; then
        echo "=====> installing /usr/local/bin/popos-migrate-branding (post-upgrade Pop!_OS identity helper)"
        install -m 0755 /root/popos-migrate-branding /usr/local/bin/popos-migrate-branding
    fi

    # Expose distributor-logo-pop-os under hicolor so non-Pop icon themes (e.g.
    # KDE Breeze, LXQt, XFCE) resolve LOGO=distributor-logo-pop-os after migration.
    if [[ -f /usr/share/icons/Pop/128x128/places/distributor-logo-pop-os.svg && \
          ! -e /usr/share/icons/hicolor/scalable/places/distributor-logo-pop-os.svg ]]; then
        install -d /usr/share/icons/hicolor/scalable/places
        cp -a /usr/share/icons/Pop/128x128/places/distributor-logo-pop-os.svg \
            /usr/share/icons/hicolor/scalable/places/distributor-logo-pop-os.svg
        if command -v gtk-update-icon-cache >/dev/null 2>&1; then
            gtk-update-icon-cache -f /usr/share/icons/hicolor >/dev/null 2>&1 || true
        fi
    fi
}

function ensure_popos_plymouth_alternatives() {
    if dpkg -s plymouth-theme-ubuntu-text >/dev/null 2>&1; then
        # Some desktops (such as budgie-desktop-environment via
        # plymouth-theme-ubuntu-budgie-text) depend on plymouth-theme-ubuntu-text;
        # only purge it when nothing else depends on it.
        if ! apt-get -s purge -y plymouth-theme-ubuntu-text 2>/dev/null \
            | awk '/^Remv / {print $2}' | grep -vx 'plymouth-theme-ubuntu-text' | grep -q .; then
            apt-get purge -y plymouth-theme-ubuntu-text || true
        fi
    fi
    if [[ -f /usr/share/plymouth/themes/pop-basic/pop-basic.plymouth ]]; then
        if ! update-alternatives --query default.plymouth 2>/dev/null | grep -Fq '/usr/share/plymouth/themes/pop-basic/pop-basic.plymouth'; then
            update-alternatives --install /usr/share/plymouth/themes/default.plymouth default.plymouth \
                /usr/share/plymouth/themes/pop-basic/pop-basic.plymouth 200 >/dev/null 2>&1 || true
        fi
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

function install_popos_grub_theme_from_amd64_pkg() {
    # Upstream pop-grub-theme ships architecture-independent theme assets tagged
    # Architecture: amd64 in apt.pop-os.org/release (absent from binary-arm64).
    # Fetch and cryptographically verify grub-theme-pop from release/binary-amd64
    # and extract only /usr/share/grub/themes/pop so arm64 gets pop-grub too.
    local rel_url=""
    rel_url="${POP_RELEASE_URL:-$(_popos_source_uri_from_file /etc/apt/sources.list.d/pop-os-release.sources)}"
    [[ -n "$rel_url" ]] || rel_url="${POP_APT_URL}/release"

    local keyring="$POP_KEYRING_FILE"
    if [[ ! -f "$keyring" && -f /etc/apt/trusted.gpg.d/pop-keyring-2017-archive.gpg ]]; then
        keyring="/etc/apt/trusted.gpg.d/pop-keyring-2017-archive.gpg"
    fi
    if [[ ! -f "$keyring" ]]; then
        echo "  WARN  Pop!_OS archive keyring missing; cannot fetch grub-theme-pop." >&2
        return 1
    fi

    local tmp_dir=""
    tmp_dir="$(mktemp -d)"
    local base_dist="${rel_url%/}/dists/${TARGET_UBUNTU_VERSION}"
    if ! curl -fsSL "${base_dist}/Release" -o "${tmp_dir}/Release" || \
       ! curl -fsSL "${base_dist}/Release.gpg" -o "${tmp_dir}/Release.gpg"; then
        rm -rf "$tmp_dir"
        return 1
    fi
    if ! gpgv --keyring "$keyring" "${tmp_dir}/Release.gpg" "${tmp_dir}/Release" >/dev/null 2>&1; then
        echo "  WARN  Release.gpg verification failed for ${base_dist}." >&2
        rm -rf "$tmp_dir"
        return 1
    fi

    local pkg_sha256=""
    pkg_sha256="$(awk '
        /^SHA256:/ {in_s=1; next}
        /^[^ ]/ {in_s=0}
        in_s && $3 == "main/binary-amd64/Packages.gz" {print $1; exit}
    ' "${tmp_dir}/Release")"
    if [[ -z "$pkg_sha256" ]] || \
       ! curl -fsSL "${base_dist}/main/binary-amd64/Packages.gz" -o "${tmp_dir}/Packages.gz" || \
       ! printf '%s  %s\n' "$pkg_sha256" "${tmp_dir}/Packages.gz" | sha256sum -c - >/dev/null 2>&1; then
        echo "  WARN  Packages.gz verification failed for ${base_dist}." >&2
        rm -rf "$tmp_dir"
        return 1
    fi

    local deb_info="" deb_rel="" deb_sha256=""
    deb_info="$(gzip -dc "${tmp_dir}/Packages.gz" | awk '
        /^Package: / {pkg=$2; fn=""; sha=""}
        /^Filename: / {fn=$2}
        /^SHA256: / {sha=$2}
        /^$/ {if (pkg == "grub-theme-pop" && fn != "" && sha != "") {print fn "\t" sha; found=1; exit}}
        END {if (!found && pkg == "grub-theme-pop" && fn != "" && sha != "") print fn "\t" sha}
    ')"
    deb_rel="${deb_info%%$'\t'*}"
    deb_sha256="${deb_info#*$'\t'}"
    if [[ -z "$deb_rel" || -z "$deb_sha256" ]]; then
        rm -rf "$tmp_dir"
        return 1
    fi

    if ! curl -fsSL "${rel_url%/}/${deb_rel}" -o "${tmp_dir}/grub-theme-pop.deb" || \
       ! printf '%s  %s\n' "$deb_sha256" "${tmp_dir}/grub-theme-pop.deb" | sha256sum -c - >/dev/null 2>&1; then
        echo "  WARN  grub-theme-pop .deb checksum verification failed." >&2
        rm -rf "$tmp_dir"
        return 1
    fi

    mkdir -p "${tmp_dir}/extract"
    dpkg-deb -x "${tmp_dir}/grub-theme-pop.deb" "${tmp_dir}/extract"
    if [[ ! -f "${tmp_dir}/extract/usr/share/grub/themes/pop/theme.txt" ]]; then
        rm -rf "$tmp_dir"
        return 1
    fi

    install -d /usr/share/grub/themes
    rm -rf /usr/share/grub/themes/pop
    cp -a "${tmp_dir}/extract/usr/share/grub/themes/pop" /usr/share/grub/themes/pop
    rm -rf "$tmp_dir"
    echo "=====> Pop!_OS GRUB theme: extracted verified assets from grub-theme-pop (${TARGET_ARCH:-arm64})"
    return 0
}

function install_popos_grub_branding() {
    echo "=====> GRUB: configuring Pop!_OS bootloader branding (pop-grub)"
    apt_install_available "Pop!_OS GRUB theme" grub-theme-pop
    if [[ ! -f /usr/share/grub/themes/pop/theme.txt ]]; then
        install_popos_grub_theme_from_amd64_pkg || \
            echo "  WARN  grub-theme-pop theme assets unavailable; proceeding with GRUB_DISTRIBUTOR only." >&2
    fi

    install -d /etc/default/grub.d
    # Keep timeout defaults before 50-cloudimg.cfg (0s) and 50-removable.cfg (3s)
    # so installed ISOs/VMs show the Pop!_OS GRUB theme instead of hidden/0s timeout.
    cat <<'EOF' > /etc/default/grub.d/40-pop-menu.cfg
# Pop!_OS GRUB menu defaults (managed by build-popos)
GRUB_TIMEOUT_STYLE=menu
GRUB_TIMEOUT=10
EOF

    if [[ -f /usr/share/grub/themes/pop/theme.txt ]]; then
        if [[ -f /usr/share/grub/themes/pop/icons/pop-os.png ]]; then
            [[ ! -e /usr/share/grub/themes/pop/icons/pop_os.png ]] && ln -sf pop-os.png /usr/share/grub/themes/pop/icons/pop_os.png
            [[ ! -e /usr/share/grub/themes/pop/icons/pop__os.png ]] && ln -sf pop-os.png /usr/share/grub/themes/pop/icons/pop__os.png
        fi
        # Mirror theme under /boot/grub/themes/pop so separate unencrypted /boot
        # (Calamares LUKS2) and direct installs both render the theme reliably.
        install -d /boot/grub/themes
        rm -rf /boot/grub/themes/pop
        cp -a /usr/share/grub/themes/pop /boot/grub/themes/pop

        cat <<'EOF' > /etc/default/grub.d/50-pop-branding.cfg
# Pop!_OS GRUB branding (managed by build-popos)
GRUB_DISTRIBUTOR="Pop!_OS"
GRUB_THEME="/boot/grub/themes/pop/theme.txt"
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

    local wall=""
    wall="$(find /usr/share/backgrounds -maxdepth 3 -type f \
        \( -iname '*pop*' -o -iname '*kate-hazen*' -o -iname '*system76*' \) \
        2>/dev/null | sort | head -n 1 || true)"

    if [[ -d /usr/share/glib-2.0/schemas ]] && command -v glib-compile-schemas >/dev/null 2>&1; then
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

        if [[ -f /usr/share/glib-2.0/schemas/org.gnome.login-screen.gschema.xml ]]; then
            cat <<'EOF' >> /usr/share/glib-2.0/schemas/90_pop-branding.gschema.override

[org.gnome.desktop.interface:GNOME-Greeter]
gtk-theme = 'Pop-dark'
icon-theme = 'Pop'
cursor-theme = 'Pop'
EOF
            if [[ -f /usr/share/icons/Pop/128x128/places/distributor-logo-pop-os.svg ]]; then
                cat <<'EOF' >> /usr/share/glib-2.0/schemas/90_pop-branding.gschema.override

[org.gnome.login-screen]
logo = '/usr/share/icons/Pop/128x128/places/distributor-logo-pop-os.svg'
EOF
            fi
        fi

        if [[ -f /usr/share/glib-2.0/schemas/org.cinnamon.desktop.interface.gschema.xml ]]; then
            cat <<'EOF' >> /usr/share/glib-2.0/schemas/90_pop-branding.gschema.override

[org.cinnamon.desktop.interface]
gtk-theme = 'Pop-dark'
icon-theme = 'Pop'
cursor-theme = 'Pop'
EOF
            if [[ -n "$wall" ]]; then
                cat <<EOF >> /usr/share/glib-2.0/schemas/90_pop-branding.gschema.override

[org.cinnamon.desktop.background]
picture-uri = 'file://${wall}'
EOF
            fi
        fi

        if [[ -f /usr/share/glib-2.0/schemas/org.mate.interface.gschema.xml ]]; then
            cat <<'EOF' >> /usr/share/glib-2.0/schemas/90_pop-branding.gschema.override

[org.mate.interface]
gtk-theme = 'Pop-dark'
icon-theme = 'Pop'
EOF
            if [[ -n "$wall" ]]; then
                cat <<EOF >> /usr/share/glib-2.0/schemas/90_pop-branding.gschema.override

[org.mate.background]
picture-filename = '${wall}'
EOF
            fi
        fi

        if [[ -f /usr/share/glib-2.0/schemas/x.dm.slick-greeter.gschema.xml ]]; then
            cat <<'EOF' >> /usr/share/glib-2.0/schemas/90_pop-branding.gschema.override

[x.dm.slick-greeter]
theme-name = 'Pop-dark'
icon-theme-name = 'Pop'
cursor-theme-name = 'Pop'
EOF
            if [[ -n "$wall" ]]; then
                echo "background = '${wall}'" >> /usr/share/glib-2.0/schemas/90_pop-branding.gschema.override
            fi
            if [[ -f /usr/share/icons/Pop/64x64/places/distributor-logo-pop-os.svg ]]; then
                echo "logo = '/usr/share/icons/Pop/64x64/places/distributor-logo-pop-os.svg'" \
                    >> /usr/share/glib-2.0/schemas/90_pop-branding.gschema.override
            fi
        fi

        glib-compile-schemas /usr/share/glib-2.0/schemas || true
    fi

    if dpkg -s slick-greeter >/dev/null 2>&1; then
        install -d /etc/lightdm
        {
            echo "[Greeter]"
            echo "theme-name=Pop-dark"
            echo "icon-theme-name=Pop"
            echo "cursor-theme-name=Pop"
            [[ -n "$wall" ]] && echo "background=${wall}"
            [[ -f /usr/share/icons/Pop/64x64/places/distributor-logo-pop-os.svg ]] && \
                echo "logo=/usr/share/icons/Pop/64x64/places/distributor-logo-pop-os.svg"
        } > /etc/lightdm/slick-greeter.conf
    fi

    local xfce_xs="/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml"
    if [[ -f "$xfce_xs" ]]; then
        sed -i -e 's/\(name="ThemeName" type="string" value=\)"[^"]*"/\1"Pop-dark"/' \
               -e 's/\(name="IconThemeName" type="string" value=\)"[^"]*"/\1"Pop"/' \
               -e 's/\(name="SoundThemeName" type="string" value=\)"[^"]*"/\1"Pop"/' \
               -e 's/\(name="CursorThemeName" type="string" value=\)"[^"]*"/\1"Pop"/' \
               "$xfce_xs"
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
Comment=Install Pop!_OS to disk using the Unofficial CLI Installer
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
    ui_heading "Pop!_OS upgrade-safe branding"
    echo "  Base OS & APT behave like standard Ubuntu (ubuntu.sources + base-files)"
    echo "  so 'sudo apt update && sudo apt upgrade' stays conflict-free while keeping"
    echo "  the Pop!_OS aesthetic (GRUB, Plymouth, themes, and optional COSMIC)."
    echo "  After upgrading, switch OS identity (/etc/os-release, motd) to Pop!_OS with:"
    echo "      sudo popos-migrate-branding"
    echo

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
