#!/bin/bash
#============================================================================
# 01_download_offline.sh
# 在有网络的 Ubuntu 24.04 上运行，下载 PXE 服务所需的全部 deb 包
# 产出：./offline_debs/ 目录
#============================================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEB_DIR="${SCRIPT_DIR}/offline_debs"

info "========== Ubuntu 24.04 离线 deb 包下载 =========="
[[ $EUID -ne 0 ]] && error "请使用 root 运行"

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

info "解析依赖..."
ALL_DEPS=$(apt-cache depends --recurse --no-recommends --no-suggests \
    --no-conflicts --no-breaks --no-replaces --no-enhances \
    "${PACKAGES[@]}" 2>/dev/null | grep "^\w" | sort -u)

info "下载 $(echo "$ALL_DEPS" | wc -l) 个包..."
cd "${DEB_DIR}"
FAIL=0
for pkg in $ALL_DEPS; do
    apt-get download "$pkg" 2>/dev/null || ((FAIL++)) || true
done
for pkg in "${PACKAGES[@]}"; do
    ls "${DEB_DIR}/${pkg}_"*.deb &>/dev/null || apt-get download "$pkg" 2>/dev/null || true
done

DEB_COUNT=$(ls -1 "${DEB_DIR}"/*.deb 2>/dev/null | wc -l)
info "完成: ${DEB_COUNT} 个 deb 包 (${FAIL} 个跳过)"
