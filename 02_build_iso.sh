#!/bin/bash
#============================================================================
# 02_build_iso.sh
#
# Repack Ubuntu 24.04 Server ISO to provide:
#   1. Fully automated Ubuntu install (autoinstall), unattended
#   2. After install, log in and manually run interactive PXE setup scripts
#   3. Insert OS disc, run mount script to register multiple OSes
#   4. Manage MAC address mappings to push different OSes as needed
#
# Does not embed any OS ISO, output ISO size ~2.8G
#
# Usage: sudo ./02_build_iso.sh
#============================================================================

set -e

#============================================================================
# *** Parameters ***
#============================================================================

UBUNTU_ISO="/root/ubuntu-24.04.2-live-server-amd64.iso"
OUTPUT_ISO="/root/pxe_toolkit.iso"
WORK_DIR="/tmp/iso_build"

# Tool machine autoinstall parameters
TOOL_HOSTNAME="pxe-server"
TOOL_USERNAME="pxe"
TOOL_PASSWORD="pxe123"

#============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OFFLINE_DEBS="${SCRIPT_DIR}/offline_debs"

info "========== Ubuntu 24.04 PXE Toolkit ISO Build =========="

[[ $EUID -ne 0 ]] && error "Must run as root"
[[ ! -f "${UBUNTU_ISO}" ]] && error "Not found: ${UBUNTU_ISO}"
[[ ! -d "${OFFLINE_DEBS}" ]] && error "Not found: ${OFFLINE_DEBS}/\nRun 01_download_offline.sh first"

apt-get update -qq
apt-get install -y -qq xorriso p7zip-full

#============================================================================
# 1. Extract Ubuntu ISO
#============================================================================
info "[1/5] Extracting Ubuntu Server ISO"

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"/{iso_extract,iso_new}

cd "${WORK_DIR}"
7z x -oiso_extract "${UBUNTU_ISO}" >/dev/null 2>&1 || {
    mkdir -p mnt_iso
    mount -o loop,ro "${UBUNTU_ISO}" mnt_iso
    rsync -a mnt_iso/ iso_extract/
    umount mnt_iso
}
cp -a iso_extract/* iso_new/ 2>/dev/null || true
cp -a iso_extract/.* iso_new/ 2>/dev/null || true

info "Extraction complete"

#============================================================================
# 2. Create autoinstall configuration
#============================================================================
info "[2/5] Creating autoinstall configuration"

PASS_HASH=$(echo "${TOOL_PASSWORD}" | openssl passwd -6 -stdin)

mkdir -p "${WORK_DIR}/iso_new/autoinstall"

cat > "${WORK_DIR}/iso_new/autoinstall/user-data" << USERDATA
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: us
  identity:
    hostname: ${TOOL_HOSTNAME}
    username: ${TOOL_USERNAME}
    password: '${PASS_HASH}'
  storage:
    layout:
      name: direct
  ssh:
    install-server: true
    allow-pw: true
  late-commands:
    - mkdir -p /target/opt/pxe_toolkit/debs
    - cp -a /cdrom/pxe_payload/offline_debs/*.deb /target/opt/pxe_toolkit/debs/ || true
    - cp /cdrom/pxe_payload/setup_pxe.sh /target/opt/pxe_toolkit/
    - cp /cdrom/pxe_payload/mount_disc.sh /target/opt/pxe_toolkit/
    - cp /cdrom/pxe_payload/manage_hosts.sh /target/opt/pxe_toolkit/
    - chmod +x /target/opt/pxe_toolkit/*.sh
    - curtin in-target -- dpkg -i --force-depends /opt/pxe_toolkit/debs/*.deb || true
    - curtin in-target -- dpkg --configure -a || true
    - curtin in-target -- bash -c "echo 'root:pxe123' | chpasswd"
    - |
      cat > /target/etc/systemd/system/pxe-setup.service << 'SVCEOF'
      [Unit]
      Description=PXE Toolkit Auto Setup (First Boot)
      After=network-online.target
      Wants=network-online.target
      ConditionPathExists=!/opt/pxe_toolkit/pxe.conf

      [Service]
      Type=oneshot
      ExecStart=/opt/pxe_toolkit/setup_pxe.sh --auto
      RemainAfterExit=yes
      StandardOutput=journal+console

      [Install]
      WantedBy=multi-user.target
      SVCEOF
    - curtin in-target -- systemctl enable pxe-setup.service
    - |
      cat > /target/etc/profile.d/pxe-welcome.sh << 'WELEOF'
      if [ "\$(id -u)" = "0" ] || [ -n "\$SUDO_USER" ]; then
        echo ""
        echo "======================================"
        echo "  PXE Toolkit Machine"
        echo ""
        echo "  1. Deploy PXE service:"
        echo "     sudo /opt/pxe_toolkit/setup_pxe.sh"
        echo ""
        echo "  2. Register OS (can run multiple times):"
        echo "     sudo /opt/pxe_toolkit/mount_disc.sh"
        echo "     sudo /opt/pxe_toolkit/mount_disc.sh /path/to.iso"
        echo ""
        echo "  3. Manage MAC address mappings:"
        echo "     sudo /opt/pxe_toolkit/manage_hosts.sh"
        echo "======================================"
        echo ""
      fi
      WELEOF
USERDATA

cat > "${WORK_DIR}/iso_new/autoinstall/meta-data" << 'EOF'
EOF

info "autoinstall configuration complete"

#============================================================================
# 3. Embed payload
#============================================================================
info "[3/5] Embedding payload"

PAYLOAD_DIR="${WORK_DIR}/iso_new/pxe_payload"
mkdir -p "${PAYLOAD_DIR}/offline_debs"

cp "${OFFLINE_DEBS}"/*.deb "${PAYLOAD_DIR}/offline_debs/"
info "Copied $(ls -1 "${PAYLOAD_DIR}/offline_debs/"*.deb | wc -l) deb packages"

# Copy PXE toolkit scripts
SCRIPTS_SRC="${SCRIPT_DIR}/scripts"
for _script in setup_pxe.sh mount_disc.sh manage_hosts.sh; do
    [[ ! -f "${SCRIPTS_SRC}/${_script}" ]] && error "Missing: ${SCRIPTS_SRC}/${_script}"
    cp "${SCRIPTS_SRC}/${_script}" "${PAYLOAD_DIR}/${_script}"
done
info "PXE toolkit scripts copied"

chmod +x "${PAYLOAD_DIR}"/*.sh
info "Payload embedding complete"

#============================================================================
# 4. Modify GRUB boot, inject autoinstall
#============================================================================
info "[4/5] Modifying GRUB boot configuration"

GRUB_CFG="${WORK_DIR}/iso_new/boot/grub/grub.cfg"

if [[ -f "${GRUB_CFG}" ]]; then
    cp "${GRUB_CFG}" "${GRUB_CFG}.bak"
    sed -i '0,/linux.*\/casper\/vmlinuz/{s|\(linux.*\/casper\/vmlinuz\)\(.*\)|\1 autoinstall ds=nocloud\\;s=/cdrom/autoinstall/\2|}' "${GRUB_CFG}"
    sed -i 's/set timeout=.*/set timeout=5/' "${GRUB_CFG}"
    info "GRUB modified"
else
    warn "grub.cfg not found"
    find "${WORK_DIR}/iso_new" -name "grub.cfg" -exec echo "  Found: {}" \;
fi

for cfg in "${WORK_DIR}/iso_new/isolinux/txt.cfg" \
           "${WORK_DIR}/iso_new/syslinux/txt.cfg"; do
    [[ -f "$cfg" ]] && sed -i 's|\(append.*initrd\)|\1 autoinstall ds=nocloud;s=/cdrom/autoinstall/|' "$cfg"
done

#============================================================================
# 5. Build ISO
#============================================================================
info "[5/5] Building ISO"

ISO_NEW="${WORK_DIR}/iso_new"

dd if="${UBUNTU_ISO}" bs=1 count=432 of="${WORK_DIR}/mbr.bin" 2>/dev/null

EFI_START=$(fdisk -l "${UBUNTU_ISO}" 2>/dev/null | grep -i "EFI" | awk '{print $2}')
EFI_SIZE=$(fdisk -l "${UBUNTU_ISO}" 2>/dev/null | grep -i "EFI" | awk '{print $4}')

HAS_EFI=0
if [[ -n "${EFI_START}" ]] && [[ -n "${EFI_SIZE}" ]]; then
    dd if="${UBUNTU_ISO}" bs=512 skip=${EFI_START} count=${EFI_SIZE} \
        of="${WORK_DIR}/efi.img" 2>/dev/null
    HAS_EFI=1
fi

info "xorriso building..."

if [[ ${HAS_EFI} -eq 1 ]]; then
    xorriso -as mkisofs \
        -r -V "PXE_TOOLKIT" \
        -iso-level 3 \
        -o "${OUTPUT_ISO}" \
        --grub2-mbr "${WORK_DIR}/mbr.bin" \
        -partition_offset 16 \
        --mbr-force-bootable \
        -append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b "${WORK_DIR}/efi.img" \
        -appended_part_as_gpt \
        -iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7 \
        -c '/boot.catalog' \
        -b '/boot/grub/i386-pc/eltorito.img' \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        --grub2-boot-info \
        -eltorito-alt-boot \
        -e '--interval:appended_partition_2:::' \
        -no-emul-boot \
        "${ISO_NEW}" 2>&1 | tail -3
else
    xorriso -as mkisofs \
        -r -V "PXE_TOOLKIT" \
        -iso-level 3 \
        -o "${OUTPUT_ISO}" \
        -J -joliet-long \
        -b boot/grub/i386-pc/eltorito.img \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        "${ISO_NEW}" 2>&1 | tail -3
fi

[[ ! -f "${OUTPUT_ISO}" ]] && error "ISO build failed"

rm -rf "${WORK_DIR}"

ISO_SIZE=$(du -sh "${OUTPUT_ISO}" | awk '{print $1}')
info "=========================================="
info "  PXE Toolkit ISO build complete!"
info "=========================================="
echo ""
echo "  Output: ${OUTPUT_ISO} (${ISO_SIZE})"
echo ""
echo "  Write to USB:"
echo "    sudo dd if=${OUTPUT_ISO} of=/dev/sdX bs=4M status=progress"
echo ""
echo "  * On-site workflow:"
echo "    1. Boot from USB -> auto-install Ubuntu (~5 min)"
echo "    2. Reboot and login (${TOOL_USERNAME}/${TOOL_PASSWORD})"
echo "    3. sudo /opt/pxe_toolkit/setup_pxe.sh"
echo "       -> Select interface, configure IP (interactive, has defaults)"
echo "    4. Register OS (can repeat multiple times):"
echo "       sudo /opt/pxe_toolkit/mount_disc.sh              # Physical disc"
echo "       sudo /opt/pxe_toolkit/mount_disc.sh /path/to.iso # ISO file"
echo "    5. sudo /opt/pxe_toolkit/manage_hosts.sh"
echo "       -> Assign MAC address mappings (optional)"
echo "    6. PXE boot target servers to install"
echo ""
echo "  * Unmapped MACs will see the OS selection menu"
echo ""
