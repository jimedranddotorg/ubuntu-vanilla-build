#!/bin/bash
# start-here.sh -- guided launcher & GNU screen multi-build orchestrator.
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0" 2>/dev/null || (cd -- "$(dirname -- "$0")" && printf '%s/%s\n' "$(pwd -P)" "$(basename -- "$0")"))")"
# shellcheck source=scripts/lib/ui.sh
source "$SCRIPT_DIR/scripts/lib/ui.sh"

_uvb_host_dpkg_arch() {
    local m="${UVB_HOST_ARCH:-$(uname -m)}"
    case "$m" in
        x86_64|amd64)   echo "amd64" ;;
        aarch64|arm64)  echo "arm64" ;;
        *)              echo "$m" ;;
    esac
}

show_start_help() {
    local self="$0"
    cat <<EOF
start-here.sh - Guided launcher and multi-build orchestrator for Ubuntu and Pop!_OS images.

USAGE
  ${self} [--distro=ubuntu|popos] [--output=iso|img|vm|removable] [--arch=amd64|arm64] [builder options...]
  ${self} --create-config [--distro=...] [--output=...] [--config=FILE]
  ${self} --multi-build [--advanced] [--ui=cli|tui]

OPTIONS
  --distro=ubuntu|popos          Target distribution (asked on TTY; default: ubuntu). Env: BUILD_DISTRO
  --output=iso|img|vm|removable  Target artifact (asked on TTY; default: iso). Env: BUILD_OUTPUT
  --arch=amd64|arm64             Target CPU architecture (default: host native; cross-builds use QEMU)
  --ui=cli|tui                   Clean terminal prompts or whiptail/dialog TUI. Env: UVB_UI_MODE
  --no-color                     Disable colored terminal output (also respects NO_COLOR)
  --screen / --no-screen         Run a single build inside a detached GNU screen session
  --multi-build                  Queue multiple concurrent builds in GNU screen (requires >= 2x space)
  --create-config                Run the selected builder's config wizard (no sudo/deps installed)
    (--generate-config)
  --advanced                     Enable advanced mode (config loading, workspace preservation, APT cache)
  -h, --help                     Show this help and exit

HOSTS & CROSS-BUILDING
  Linux (Ubuntu/Debian)          Runs natively; cross-builds amd64<->arm64 via qemu-user-static
  macOS (Intel & Apple Silicon)  Auto-launches inside a privileged native-arch Linux container/VM
                                 (OrbStack / Docker Desktop / Colima / Lima); cross-builds use QEMU

BUILDERS
  ubuntu  iso        -> scripts/build.sh              popos  iso        -> scripts/build-popos.sh
  ubuntu  img        -> scripts/build-img.sh          popos  img        -> scripts/build-popos-img.sh
  ubuntu  vm         -> scripts/build-vm.sh           popos  vm         -> scripts/build-popos-vm.sh
  ubuntu  removable  -> scripts/build-removable.sh    popos  removable  -> scripts/build-popos-removable.sh

EXAMPLES
  $ ${self}
  $ ${self} --distro=popos --output=vm --arch=amd64
  $ ${self} --output=iso --release=devel --profile=cli --ui=tui -
  $ ${self} --multi-build
  $ ${self} --create-config --distro=ubuntu --output=removable

LEARN MORE
  Run './scripts/build.sh --help' (or any builder script with --help) for builder-specific flags.
EOF
}

# Bash 3.2-compatible macOS (Intel x86_64 & Apple Silicon arm64) Linux container/VM dispatcher.
_uvb_run_on_macos() {
    local mac_arch cross_arch
    mac_arch="$(_uvb_host_dpkg_arch)"
    if [[ "$mac_arch" == "arm64" ]]; then
        cross_arch="amd64"
    else
        mac_arch="amd64"
        cross_arch="arm64"
    fi

    local mac_out_dir="${UVB_OUTPUT_DIR:-$HOME/ubuntu-vanilla-build-out}"
    if command -v docker >/dev/null 2>&1; then
        if ! docker info >/dev/null 2>&1; then
            ui_err "Docker CLI is installed on macOS, but the Docker daemon is not running."
            ui_info "Start OrbStack, Docker Desktop, or run 'colima start', then re-run: $0 $*"
            exit 1
        fi
        mkdir -p "$mac_out_dir"
        ui_info "macOS (${mac_arch}) detected: launching Linux container (--platform linux/${mac_arch}; native=${mac_arch}, cross=${cross_arch} via QEMU)"
        ui_info "Artifacts will be written to: ${mac_out_dir}"

        local -a docker_args=(
            run --rm --privileged
            --platform "linux/${mac_arch}"
            -v "${SCRIPT_DIR}:/workspace-repo"
            -v "${mac_out_dir}:/out"
            -v "uvb-mac-workspace:/var/cache/ubuntu-vanilla-build"
            -v "uvb-mac-cache:/root/.cache/ubuntu-vanilla-build"
            -v "uvb-mac-popos-cache:/root/.cache/popos-vanilla-build"
            -v "/dev:/dev"
            -e "UVB_OUTPUT_DIR=/out"
            -e "UVB_MAC_HOST=1"
            -e "UVB_MAC_ARCH=${mac_arch}"
        )
        if [[ -t 0 && -t 1 ]]; then
            docker_args+=(-it)
        elif [[ -t 0 ]]; then
            docker_args+=(-i)
        fi

        local ev
        for ev in TERM NO_COLOR UVB_UI_MODE BUILD_DISTRO BUILD_OUTPUT ADVANCED_MODE \
                  NO_CONFIRM INTERACTIVE UVB_FORCE_NONINTERACTIVE_RUN; do
            if [[ -n "${!ev:-}" ]]; then
                docker_args+=(-e "${ev}=${!ev}")
            fi
        done
        while IFS='=' read -r ev _; do
            case "$ev" in
                TARGET_*|GRUB_LIVEBOOT_LABEL)
                    if [[ -n "${!ev:-}" ]]; then
                        docker_args+=(-e "${ev}=${!ev}")
                    fi
                    ;;
            esac
        done < <(env)

        local -a fwd_args=()
        local skip_next=0 prev_flag="" a abs_p
        for a in "$@"; do
            if [[ "$skip_next" -eq 1 ]]; then
                skip_next=0
                if [[ "$prev_flag" == "--config" ]]; then
                    abs_p="$(cd -- "$(dirname -- "$a")" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename -- "$a")")" || abs_p="$a"
                    case "$abs_p" in
                        "${SCRIPT_DIR}/"*) fwd_args+=("--config=/workspace-repo/${abs_p#"${SCRIPT_DIR}/"}") ;;
                        *) docker_args+=(-v "${abs_p}:/tmp/uvb-user.cfg:ro"); fwd_args+=("--config=/tmp/uvb-user.cfg") ;;
                    esac
                elif [[ "$prev_flag" == "--hooks-dir" ]]; then
                    abs_p="$(cd -- "$a" 2>/dev/null && pwd -P)" || abs_p="$a"
                    docker_args+=(-v "${abs_p}:/tmp/uvb-hooks:ro")
                    fwd_args+=("--hooks-dir=/tmp/uvb-hooks")
                fi
                continue
            fi
            case "$a" in
                --screen)
                    ui_warn "Ignoring --screen inside ephemeral macOS container (running in foreground)."
                    fwd_args+=("--no-screen")
                    ;;
                --multi-build)
                    ui_err "--multi-build inside an ephemeral macOS container is unsupported. Launch multiple terminal tabs or run one build at a time."
                    exit 1
                    ;;
                --config=*)
                    abs_p="${a#--config=}"
                    abs_p="$(cd -- "$(dirname -- "$abs_p")" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename -- "$abs_p")")" || abs_p="${a#--config=}"
                    case "$abs_p" in
                        "${SCRIPT_DIR}/"*) fwd_args+=("--config=/workspace-repo/${abs_p#"${SCRIPT_DIR}/"}") ;;
                        *) docker_args+=(-v "${abs_p}:/tmp/uvb-user.cfg:ro"); fwd_args+=("--config=/tmp/uvb-user.cfg") ;;
                    esac
                    ;;
                --config|--hooks-dir)
                    skip_next=1
                    prev_flag="$a"
                    ;;
                --hooks-dir=*)
                    abs_p="${a#--hooks-dir=}"
                    abs_p="$(cd -- "$abs_p" 2>/dev/null && pwd -P)" || abs_p="${a#--hooks-dir=}"
                    docker_args+=(-v "${abs_p}:/tmp/uvb-hooks:ro")
                    fwd_args+=("--hooks-dir=/tmp/uvb-hooks")
                    ;;
                *)
                    fwd_args+=("$a")
                    ;;
            esac
        done

        local mac_image="${UVB_MAC_IMAGE:-ubuntu:24.04}"
        local inner_cmd='if [ ! -e /proc/sys/fs/binfmt_misc/register ] && [ -d /proc/sys/fs/binfmt_misc ]; then mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true; fi; exec /workspace-repo/start-here.sh "$@"'
        exec docker ${docker_args[@]+"${docker_args[@]}"} "$mac_image" bash -c "$inner_cmd" _ ${fwd_args[@]+"${fwd_args[@]}"}
    elif command -v limactl >/dev/null 2>&1; then
        local lima_vm=""
        if limactl list -q 2>/dev/null | grep -qx "ubuntu-vanilla-build"; then
            lima_vm="ubuntu-vanilla-build"
        elif limactl list -q 2>/dev/null | grep -qx "default"; then
            lima_vm="default"
        fi
        if [[ -z "$lima_vm" ]]; then
            ui_err "No Lima VM ('ubuntu-vanilla-build' or 'default') found on macOS."
            ui_info "Create one with: limactl start --name=ubuntu-vanilla-build template://ubuntu-24.04"
            ui_info "Then re-run: $0 $*"
            exit 1
        fi
        ui_info "macOS (${mac_arch}) detected: delegating into Lima VM '${lima_vm}' (native=${mac_arch}, cross=${cross_arch} via QEMU)"
        exec limactl shell "$lima_vm" -- sudo -E "${SCRIPT_DIR}/start-here.sh" "$@"
    else
        ui_err "macOS requires a Linux container or VM runtime (Linux debootstrap/chroot/loop tools cannot run natively on Darwin)."
        ui_info "On Intel or Apple Silicon Macs, install one of:"
        ui_info "  • OrbStack / Docker Desktop / Colima: brew install --cask orbstack  (or: brew install colima docker && colima start)"
        ui_info "  • Lima VM:                            brew install lima && limactl start --name=ubuntu-vanilla-build template://ubuntu-24.04"
        exit 1
    fi
}

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            show_start_help
            exit 0
            ;;
    esac
done

if [[ "${UVB_HOST_OS:-$(uname -s)}" == "Darwin" ]]; then
    _uvb_run_on_macos "$@"
fi

_start_need_arg() {
    if [[ "$1" -lt 2 ]]; then
        ui_err "Option '$2' requires a value. Run '$0 --help' for usage."
        exit 1
    fi
}

GENERATE_CONFIG=0
ADVANCE_REQUESTED=0
MULTI_BUILD_REQUESTED=0
SCREEN_SET=0
SCREEN_WANT=0
CLI_UI=""
CLI_ARCH=""
BUILD_DISTRO="${BUILD_DISTRO:-}"
BUILD_OUTPUT="${BUILD_OUTPUT:-}"
PASS_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_start_help
            exit 0
            ;;
        --distro=*)          BUILD_DISTRO="${1#--distro=}"; shift ;;
        --distro)            _start_need_arg $# "$1"; BUILD_DISTRO="$2"; shift 2 ;;
        --output=*)          BUILD_OUTPUT="${1#--output=}"; shift ;;
        --output)            _start_need_arg $# "$1"; BUILD_OUTPUT="$2"; shift 2 ;;
        --arch=*)            CLI_ARCH="${1#--arch=}"; PASS_ARGS+=("$1"); shift ;;
        --arch)              _start_need_arg $# "$1"; CLI_ARCH="$2"; PASS_ARGS+=("$1" "$2"); shift 2 ;;
        --ui=*)              CLI_UI="${1#--ui=}"; PASS_ARGS+=("$1"); shift ;;
        --ui)                _start_need_arg $# "$1"; CLI_UI="$2"; PASS_ARGS+=("$1" "$2"); shift 2 ;;
        --no-color)          ui_disable_color; PASS_ARGS+=("$1"); shift ;;
        --screen)            SCREEN_SET=1; SCREEN_WANT=1; shift ;;
        --no-screen)         SCREEN_SET=1; SCREEN_WANT=0; PASS_ARGS+=("$1"); shift ;;
        --multi-build)       MULTI_BUILD_REQUESTED=1; shift ;;
        --create-config|--generate-config) GENERATE_CONFIG=1; shift ;;
        --advanced)          ADVANCE_REQUESTED=1; PASS_ARGS+=("$1"); shift ;;
        --no-interactive)    exec 0</dev/null; FORCE_INTERACTIVE=0; PASS_ARGS+=("$1"); shift ;;
        --interactive)       FORCE_INTERACTIVE=1; PASS_ARGS+=("$1"); shift ;;
        *)                   PASS_ARGS+=("$1"); shift ;;
    esac
done

if [[ "$GENERATE_CONFIG" -eq 1 ]]; then
    PASS_ARGS+=("--generate-config")
fi

# Validate explicit flags early before any UI prompt or clear.
if [[ -n "$CLI_UI" ]]; then
    export UVB_UI_MODE="$CLI_UI"
    normalize_ui_mode
fi

if [[ -n "$BUILD_DISTRO" ]]; then
    case "${BUILD_DISTRO,,}" in
        pop|pop-os|pop_os|popos) BUILD_DISTRO="popos" ;;
        ubuntu)                  BUILD_DISTRO="ubuntu" ;;
        *)
            ui_err "Invalid distribution '${BUILD_DISTRO}'. Use --distro=ubuntu or --distro=popos."
            exit 1
            ;;
    esac
fi

if [[ -n "$BUILD_OUTPUT" ]]; then
    case "${BUILD_OUTPUT,,}" in
        iso)                              BUILD_OUTPUT="iso" ;;
        img|image|cloud|cloud-img)        BUILD_OUTPUT="img" ;;
        vm)                               BUILD_OUTPUT="vm" ;;
        removable|removable-media|usb|sd) BUILD_OUTPUT="removable" ;;
        *)
            ui_err "Invalid output type '${BUILD_OUTPUT}'. Use --output=iso|img|vm|removable."
            exit 1
            ;;
    esac
fi

if [[ "$MULTI_BUILD_REQUESTED" -eq 1 ]] && ! prompts_enabled; then
    ui_err "--multi-build requires an interactive terminal (stdin must be a TTY)."
    exit 1
fi

resolve_builder_script() {
    local d="$1" o="$2"
    case "${d}-${o}" in
        ubuntu-iso)       echo "build.sh" ;;
        ubuntu-img)       echo "build-img.sh" ;;
        ubuntu-vm)        echo "build-vm.sh" ;;
        ubuntu-removable) echo "build-removable.sh" ;;
        popos-iso)        echo "build-popos.sh" ;;
        popos-img)        echo "build-popos-img.sh" ;;
        popos-vm)         echo "build-popos-vm.sh" ;;
        popos-removable)  echo "build-popos-removable.sh" ;;
        *)
            ui_err "Internal error: unsupported target '${d}-${o}'."
            exit 1
            ;;
    esac
}

detect_distro_os() {
    IS_DEBIAN_OR_UBUNTU=0
    IS_DEBIAN=0
    if [[ -r /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        if [[ "${ID:-}" == "ubuntu" ]] || [[ "${ID_LIKE:-}" == *ubuntu* ]]; then
            IS_DEBIAN_OR_UBUNTU=1
        elif [[ "${ID:-}" == "debian" ]] || [[ "${ID_LIKE:-}" == *debian* ]]; then
            IS_DEBIAN_OR_UBUNTU=1
            if [[ "${ID:-}" != "ubuntu" ]] && [[ "${ID_LIKE:-}" != *ubuntu* ]]; then
                IS_DEBIAN=1
            fi
        fi
    fi
}

install_host_deps() {
    local outputs_csv="$1"
    local need_qemu_user="$2"
    local need_screen="$3"

    detect_distro_os

    local -a deps=(debootstrap)
    local o
    for o in ${outputs_csv//,/ }; do
        case "$o" in
            iso)           deps+=(squashfs-tools xorriso) ;;
            img|removable) deps+=(parted dosfstools e2fsprogs rsync) ;;
            vm)            deps+=(parted dosfstools e2fsprogs rsync qemu-utils) ;;
        esac
    done
    if [[ "$need_qemu_user" == "1" ]]; then
        if [[ "$IS_DEBIAN_OR_UBUNTU" -eq 1 ]] && command -v apt-cache >/dev/null 2>&1 && \
           apt-cache show qemu-user-static >/dev/null 2>&1; then
            deps+=(qemu-user-static)
        else
            deps+=(qemu-user qemu-user-binfmt)
        fi
    fi
    if [[ "$need_screen" == "1" ]]; then
        deps+=(screen)
    fi
    if [[ "$IS_DEBIAN" -eq 1 ]]; then
        deps+=(ubuntu-archive-keyring)
    fi

    # Deduplicate deps
    local -a uniq_deps=()
    local d seen u
    for d in "${deps[@]}"; do
        seen=0
        for u in "${uniq_deps[@]+"${uniq_deps[@]}"}"; do
            [[ "$u" == "$d" ]] && { seen=1; break; }
        done
        [[ "$seen" -eq 0 ]] && uniq_deps+=("$d")
    done

    if [[ "$IS_DEBIAN_OR_UBUNTU" -eq 1 ]] && command -v dpkg &>/dev/null; then
        local -a missing=()
        for d in "${uniq_deps[@]}"; do
            if ! dpkg -s "$d" &>/dev/null; then
                missing+=("$d")
            fi
        done
        if (( ${#missing[@]} > 0 )); then
            ui_info "Installing missing host dependencies: ${missing[*]}"
            if [[ "$(id -u)" -eq 0 ]]; then
                apt-get update
                apt-get install -y "${missing[@]}"
            else
                sudo apt-get update
                sudo apt-get install -y "${missing[@]}"
            fi
        fi
    else
        ui_warn "Host is not Debian/Ubuntu; ensure these tools are installed: ${uniq_deps[*]}"
    fi
}

# Sets UI_REPLY (never wrap in $() since ui_menu writes to stdout).
pick_distro_interactive() {
    local suffix="${1:-}"
    ui_menu "Distribution${suffix}" "Select which distribution to build:" "ubuntu" \
        "ubuntu" "Vanilla Ubuntu (noble, resolute, devel)" \
        "popos"  "Pop!_OS from apt.pop-os.org (noble, resolute)"
}

# Sets UI_REPLY (never wrap in $() since ui_menu writes to stdout).
pick_output_interactive() {
    local suffix="${1:-}"
    ui_menu "Output type${suffix}" "Select target artifact:" "iso" \
        "iso"       "Live-installer ISO (USB / DVD / PXE / VM)" \
        "img"       "Cloud disk image: raw .img with cloud-init" \
        "vm"        "VM disk image: raw .img + QCOW2/VDI/VMDK/VHDX" \
        "removable" "Removable-media raw .img for USB sticks / SD / CF"
}

run_multi_build_wizard() {
    local ws_check_path="${UBUNTU_VANILLA_WORKSPACE:-/var/cache/ubuntu-vanilla-build}"
    [[ "$ADVANCE_REQUESTED" -eq 1 && -z "${UBUNTU_VANILLA_WORKSPACE:-}" ]] && ws_check_path="${HOME}/uvb-workspace"

    local avail_gb
    avail_gb="$(uvb_available_gb "$ws_check_path")"
    local min_multi_gb=40 # 2 x 20 GB minimum single-build baseline

    if (( avail_gb < min_multi_gb )); then
        ui_warn "Multi-build requires at least 2x storage (${min_multi_gb} GB+ free; only ${avail_gb} GB available at ${ws_check_path})."
        ui_info "Multi-build disabled. Run a single build in GNU screen (--screen) or foreground instead."
        exit 1
    fi

    ui_banner "GNU screen Multi-Build Queue (${avail_gb} GB available)"

    local host_arch
    host_arch="$(_uvb_host_dpkg_arch)"
    local -a queue_scripts=() queue_labels=() queue_args=() queue_outputs=()
    local need_cross=0 total_req_gb=0 idx=1

    while true; do
        ui_heading "Configure build #${idx}"
        local q_distro q_output q_rel q_arch q_prof q_kern q_desk
        pick_distro_interactive " (#${idx})"
        q_distro="$UI_REPLY"
        uvb_apply_tui_theme "$q_distro"
        pick_output_interactive " (#${idx})"
        q_output="$UI_REPLY"

        if [[ "$q_distro" == "popos" ]]; then
            ui_menu "Release (#${idx})" "Select Pop!_OS release:" "noble" \
                "noble" "Pop!_OS 24.04 LTS" "resolute" "Pop!_OS 26.04 LTS"
        else
            ui_menu "Release (#${idx})" "Select Ubuntu release:" "noble" \
                "noble" "Ubuntu 24.04 LTS" "resolute" "Ubuntu 26.04 LTS" "devel" "Ubuntu devel"
        fi
        q_rel="$UI_REPLY"

        if [[ "$host_arch" == "arm64" ]]; then
            ui_menu "Architecture (#${idx})" "Select architecture:" "arm64" \
                "arm64" "64-bit ARM AArch64 (native)" \
                "amd64" "64-bit x86_64 (QEMU emulation)"
        else
            ui_menu "Architecture (#${idx})" "Select architecture:" "amd64" \
                "amd64" "64-bit x86_64 (native)" \
                "arm64" "64-bit ARM AArch64 (QEMU emulation)"
        fi
        q_arch="$UI_REPLY"
        [[ "$q_arch" != "$host_arch" ]] && need_cross=1

        ui_menu "Profile (#${idx})" "Select profile:" "desktop" \
            "desktop" "Graphical desktop" "cli" "CLI / TTY-only"
        q_prof="$UI_REPLY"

        if [[ "$q_distro" == "popos" && "$q_arch" == "amd64" ]]; then
            ui_menu "Kernel (#${idx})" "Select kernel:" "system76" \
                "system76" "System76 kernel" "generic" "Ubuntu HWE generic" "lowlatency" "Ubuntu HWE lowlatency"
        else
            ui_menu "Kernel (#${idx})" "Select kernel:" "generic" \
                "generic" "Ubuntu generic/HWE" "lowlatency" "Low-latency"
        fi
        q_kern="$UI_REPLY"

        q_desk="cli"
        local desk_arg=""
        if [[ "$q_prof" == "desktop" ]]; then
            if [[ "$q_distro" == "popos" ]]; then
                ui_menu "Desktop (#${idx})" "Select desktop:" "gnome" \
                    "gnome" "Vanilla GNOME + Pop!_OS theme" "cosmic" "Pop!_OS COSMIC (CLI installer + GRUB)" \
                    "xfce" "XFCE + PipeWire" "kde-plasma" "KDE Plasma" \
                    "mate" "MATE" "cinnamon" "Cinnamon" "budgie" "Budgie" "lxde" "LXDE" "lxqt" "LXQt"
            else
                ui_menu "Desktop (#${idx})" "Select desktop:" "gnome" \
                    "gnome" "Vanilla GNOME" "xfce" "XFCE + PipeWire" "kde-plasma" "KDE Plasma" \
                    "mate" "MATE" "cinnamon" "Cinnamon" "budgie" "Budgie" "lxde" "LXDE" "lxqt" "LXQt"
            fi
            q_desk="$UI_REPLY"
            desk_arg=" --desktop=${q_desk}"
        fi

        local est_sz=16
        [[ "$q_output" == "img" || "$q_output" == "vm" ]] && est_sz=32
        local est_gb
        est_gb="$(uvb_single_build_req_gb "$q_output" "$est_sz" "qcow2")"
        total_req_gb=$(( total_req_gb + est_gb ))
        local b_script
        b_script="$(resolve_builder_script "$q_distro" "$q_output")"

        queue_scripts+=("$b_script")
        queue_outputs+=("$q_output")
        queue_labels+=("${q_distro}-${q_output}-${q_rel}-${q_arch}-${q_prof}")
        queue_args+=("--release=${q_rel} --arch=${q_arch} --profile=${q_prof} --kernel=${q_kern}${desk_arg}")

        ui_info "Queued #${idx}: ${q_distro}/${q_output} (${q_rel}, ${q_arch}, ${q_prof}, ${q_desk}). Estimated space: ${total_req_gb} GB / ${avail_gb} GB free."
        if (( total_req_gb >= avail_gb )); then
            ui_warn "Estimated space (${total_req_gb} GB) reached available space (${avail_gb} GB); stopping queue."
            break
        fi
        if ! ui_confirm "Add another build to the GNU screen queue?" n; then
            break
        fi
        idx=$(( idx + 1 ))
    done

    local out_csv
    out_csv="$(IFS=,; echo "${queue_outputs[*]}")"
    install_host_deps "$out_csv" "$need_cross" 1

    if ! uvb_screen_available; then
        ui_err "GNU screen could not be found/installed. Install 'screen' and retry."
        exit 1
    fi

    local date_tag
    date_tag="$(TZ="UTC" date +"%y%m%d-%H%M%S")"
    local i sess log_f run_id
    for (( i=0; i<${#queue_scripts[@]}; i++ )); do
        run_id="q$((i + 1))-${date_tag}"
        sess="uvb-${queue_labels[$i]}-${run_id}"
        log_f="${HOME}/uvb-logs/${sess}.log"
        # Isolate workspaces & APT caches per concurrent screen build so locks never collide.
        local -a raw_opts=()
        read -ra raw_opts <<< "${queue_args[$i]}"
        uvb_launch_screen_session "$sess" "$log_f" \
            env LAUNCHED_FROM_START_HERE=1 UVB_IN_SCREEN=1 UVB_FORCE_NONINTERACTIVE_RUN=1 \
            NO_CONFIRM=1 ADVANCED_MODE="${ADVANCE_REQUESTED}" \
            UVB_RUN_ID="$run_id" UVB_APT_CACHE_SUFFIX="$run_id" \
            "$SCRIPT_DIR/scripts/${queue_scripts[$i]}" "${raw_opts[@]}" -
        ui_ok "Launched screen session: ${sess} (log: ${log_f})"
    done

    echo
    ui_info "List active screen sessions: screen -ls"
    ui_info "Attach to a session:        screen -r <session-name>"
    if [[ "$(id -u)" -ne 0 ]]; then
        ui_warn "If sudo requires a password on a new PTY, attach to each session or re-run 'sudo ./start-here.sh --multi-build'."
    fi
    exit 0
}

# -- Interface & multi-build check ------------------------------------
if [[ "$GENERATE_CONFIG" -eq 0 ]]; then
    resolve_ui_mode
    export UVB_UI_MODE
else
    export UVB_UI_MODE="${UVB_UI_MODE:-cli}"
fi
uvb_apply_tui_theme "${BUILD_DISTRO:-ubuntu}"

if [[ "$MULTI_BUILD_REQUESTED" -eq 1 ]]; then
    run_multi_build_wizard
fi

# -- Distro selection -------------------------------------------------
if [[ -z "$BUILD_DISTRO" ]]; then
    if prompts_enabled; then
        pick_distro_interactive
        BUILD_DISTRO="$UI_REPLY"
    else
        ui_info "No TTY and no --distro given: defaulting to 'ubuntu'."
        BUILD_DISTRO="ubuntu"
    fi
fi
uvb_apply_tui_theme "$BUILD_DISTRO"

# -- Output type selection --------------------------------------------
if [[ -z "$BUILD_OUTPUT" ]]; then
    if prompts_enabled; then
        pick_output_interactive
        BUILD_OUTPUT="$UI_REPLY"
    else
        ui_info "No TTY and no --output given: defaulting to 'iso'."
        BUILD_OUTPUT="iso"
    fi
fi

# Interactive execution mode offer (foreground vs GNU screen vs multi-build when storage >= 2x)
if [[ "$GENERATE_CONFIG" -eq 0 && "$SCREEN_SET" -eq 0 && -z "${STY:-}" ]] && prompts_enabled; then
    ws_check_path="${UBUNTU_VANILLA_WORKSPACE:-/var/cache/ubuntu-vanilla-build}"
    [[ "$ADVANCE_REQUESTED" -eq 1 && -z "${UBUNTU_VANILLA_WORKSPACE:-}" ]] && ws_check_path="${HOME}/uvb-workspace"
    est_sz=16
    [[ "$BUILD_OUTPUT" == "img" || "$BUILD_OUTPUT" == "vm" ]] && est_sz=32
    single_est_gb="$(uvb_single_build_req_gb "$BUILD_OUTPUT" "$est_sz" "qcow2")"
    avail_gb="$(uvb_available_gb "$ws_check_path")"
    multi_req_gb=$(( single_est_gb * 2 ))

    if uvb_screen_available; then
        if (( avail_gb >= multi_req_gb )); then
            ui_menu "Execution mode (${avail_gb} GB free)" \
                "2x storage available (${multi_req_gb} GB needed for multi-build):" "foreground" \
                "foreground" "Run single build in this terminal" \
                "screen"     "Run single build detached in GNU screen" \
                "multi"      "Launch multiple concurrent builds via GNU screen"
            case "$UI_REPLY" in
                screen) SCREEN_WANT=1 ;;
                multi)  run_multi_build_wizard ;;
            esac
        else
            ui_info "Free space: ${avail_gb} GB (multi-build requires 2x = ${multi_req_gb} GB; multi-build option hidden)."
            if ui_confirm "Run this build detached in GNU screen so you can keep working in this terminal?" n; then
                SCREEN_WANT=1
            fi
        fi
    fi
fi

BUILD_SCRIPT="$(resolve_builder_script "$BUILD_DISTRO" "$BUILD_OUTPUT")"
ui_ok "Selected: ${BUILD_DISTRO} / ${BUILD_OUTPUT} (scripts/${BUILD_SCRIPT})"

if [[ "$GENERATE_CONFIG" -eq 0 ]]; then
    need_cross=0
    host_arch="$(_uvb_host_dpkg_arch)"
    target_arch="${CLI_ARCH:-${TARGET_ARCH:-$host_arch}}"
    target_arch="${target_arch,,}"
    case "$target_arch" in
        x86_64|x64) target_arch="amd64" ;;
        aarch64)    target_arch="arm64" ;;
    esac
    if [[ "$target_arch" != "$host_arch" ]]; then
        need_cross=1
    fi
    install_host_deps "$BUILD_OUTPUT" "$need_cross" "$SCREEN_WANT"
fi

SUDO_KEEPALIVE_PID=""
cleanup_sudo_keepalive() {
    if [[ -n "$SUDO_KEEPALIVE_PID" ]] && kill -0 "$SUDO_KEEPALIVE_PID" 2>/dev/null; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
        wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
    SUDO_KEEPALIVE_PID=""
    uvb_cleanup_dialogrc
}

trap uvb_cleanup_dialogrc EXIT

if [[ "$GENERATE_CONFIG" -eq 0 && "$SCREEN_WANT" -eq 0 ]] && [[ "$(id -u)" -ne 0 ]]; then
    ui_info "Requesting sudo credentials (kept alive for the entire build) ..."
    if ! sudo -v 2>/dev/null; then
        ui_err "Failed to obtain sudo credentials. The build requires sudo access (run as a sudo-capable user or with root)."
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
    trap cleanup_sudo_keepalive EXIT
fi

export LAUNCHED_FROM_START_HERE=1
if [[ "$ADVANCE_REQUESTED" -eq 1 ]]; then
    export ADVANCED_MODE=1
fi
if [[ "$SCREEN_WANT" -eq 1 ]]; then
    PASS_ARGS+=("--screen")
fi

"$SCRIPT_DIR/scripts/${BUILD_SCRIPT}" ${PASS_ARGS[@]+"${PASS_ARGS[@]}"}
