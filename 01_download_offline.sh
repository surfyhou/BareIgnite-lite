#!/bin/bash
#============================================================================
# 01_download_offline.sh
# Run on a networked Ubuntu 24.04 to download all deb packages needed for PXE service
# Output: ./offline_debs/ directory
#============================================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEB_DIR="${SCRIPT_DIR}/offline_debs"

info "========== Ubuntu 24.04 Offline deb Download =========="
[[ $EUID -ne 0 ]] && error "Must run as root"

rm -rf "${DEB_DIR}"
mkdir -p "${DEB_DIR}"
apt-get update -qq

PACKAGES=(
    dnsmasq dnsmasq-base
    nginx nginx-common nginx-core
    syslinux syslinux-common syslinux-efi pxelinux
    grub-efi-amd64-signed grub-efi-amd64-bin shim-signed
    curl
)

info "Resolving dependencies..."
ALL_DEPS=$(apt-cache depends --recurse --no-recommends --no-suggests \
    --no-conflicts --no-breaks --no-replaces --no-enhances \
    "${PACKAGES[@]}" 2>/dev/null | grep "^\w" | sort -u)

info "Downloading $(echo "$ALL_DEPS" | wc -l) packages..."
cd "${DEB_DIR}"
FAIL=0
for pkg in $ALL_DEPS; do
    apt-get download "$pkg" 2>/dev/null || ((FAIL++)) || true
done
for pkg in "${PACKAGES[@]}"; do
    ls "${DEB_DIR}/${pkg}_"*.deb &>/dev/null || apt-get download "$pkg" 2>/dev/null || true
done

DEB_COUNT=$(ls -1 "${DEB_DIR}"/*.deb 2>/dev/null | wc -l)
info "Done: ${DEB_COUNT} deb packages (${FAIL} skipped)"
