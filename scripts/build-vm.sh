#!/bin/bash
# build-vm.sh -- build a ready-to-use Ubuntu VM disk image (.img + QCOW2/VDI/VMDK/VHDX).
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
SCRIPT_NAME="$(basename "$(readlink -f "$0")")"

UVB_DISTRO="ubuntu"
UVB_OUTPUT_KIND="vm"
UVB_IMAGE_KIND="${UVB_IMAGE_KIND:-vm}"

# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/disk-image.sh
source "$SCRIPT_DIR/lib/disk-image.sh"

if [[ "${1:-}" == "--chroot-internal" ]]; then
    chroot_main "$@"
else
    host_main "$@"
fi
