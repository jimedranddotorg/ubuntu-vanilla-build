#!/bin/bash
# build-popos.sh -- build a bootable Pop!_OS live ISO (apt.pop-os.org, staging excluded).
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
SCRIPT_NAME="$(basename "$(readlink -f "$0")")"

UVB_DISTRO="popos"
UVB_OUTPUT_KIND="iso"
UVB_IMAGE_KIND="${UVB_IMAGE_KIND:-iso}"

# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/popos.sh
source "$SCRIPT_DIR/lib/popos.sh"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/iso.sh
source "$SCRIPT_DIR/lib/iso.sh"

if [[ "${1:-}" == "--chroot-internal" ]]; then
    chroot_main "$@"
else
    host_main "$@"
fi
