#!/bin/bash
# Pop!_OS-specific repository setup, native Firefox helper, System76 driver,
# and post-build COSMIC desktop notes.

POP_APT_URL="https://apt.pop-os.org"
POP_APT_ORIGIN_URL="https://apt-origin.pop-os.org"
POP_KEY_FINGERPRINT="63C46DF0140D738961429F4E204DD8AEC33A7AFF"

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

function install_popos_system76_driver() {
    echo "=====> System76 hardware driver: system76-driver (from Pop!_OS repos)"
    apt-get install -y system76-driver
    if [[ -f /etc/apt/preferences.d/pop-default-settings ]]; then
        cat <<'EOF' > /etc/apt/preferences.d/pop-default-settings
# Blanket "Package: *" pin removed by build-popos: this builder installs
# standard Ubuntu desktops and keeps the scoped pin in pop-os-release.
EOF
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

    cat <<'EOF' > /etc/apt/preferences.d/pop-os-release
Package: base-files pop-* linux-system76* linux-image-system76* linux-headers-system76* system76-*
Pin: release o=pop-os-release
Pin-Priority: 1001
EOF

    apt-get update

    apt-get install -y pop-keyring || \
        echo "  WARN  pop-keyring not installable; keeping keyserver-fetched key." >&2

    echo "=====> switching to Pop!_OS base-files (/etc/os-release identity) ..."
    apt-get install -y --allow-downgrades base-files
    if grep -qs '^ID=pop$' /etc/os-release; then
        # shellcheck source=/dev/null
        echo "=====> /etc/os-release: $(. /etc/os-release && echo "${PRETTY_NAME:-${NAME:-unknown}}")"
    else
        echo "  WARN  /etc/os-release does not report ID=pop for '${TARGET_UBUNTU_VERSION}' yet." >&2
    fi
}

function popos_print_cosmic_note() {
    [[ "$UVB_DISTRO" == "popos" ]] || return 0
    case "${TARGET_UBUNTU_VERSION:-}" in
        noble|resolute)
            ui_heading "COSMIC desktop (optional, after installation)"
            echo "  COSMIC (pop-desktop / cosmic-session) is excluded by this builder"
            echo "  because it remains buggy with Calamares. Pop!_OS repos are configured"
            echo "  in the image, so you can add it after installation with:"
            echo
            echo "      sudo apt update"
            echo "      sudo apt install cosmic-session"
            echo
            ;;
    esac
}
