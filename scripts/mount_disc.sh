#!/bin/bash
#============================================================================
# mount_disc.sh - Multi-OS registration: physical disc or ISO file
#
# Usage:
#   sudo mount_disc.sh [--auto]              # Detect physical drive
#   sudo mount_disc.sh [--auto] /path/to.iso # Use ISO file
#============================================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Parse arguments
AUTO_MODE=0
ISO_ARG=""
for _arg in "$@"; do
    case "$_arg" in
        --auto) AUTO_MODE=1 ;;
        --help|-h)
            echo "Usage: sudo $(basename "$0") [--auto] [/path/to.iso]"
            echo ""
            echo "Register an OS for PXE boot from physical disc or ISO file."
            echo ""
            echo "Options:"
            echo "  --auto         Non-interactive mode (auto-detect OS, skip prompts)"
            echo "  /path/to.iso   Use ISO file instead of physical disc"
            echo "  --help         Show this help"
            echo ""
            echo "Can be run multiple times to register different OSes."
            exit 0
            ;;
        *) ISO_ARG="$_arg" ;;
    esac
done

CONFIG_FILE="/opt/pxe_toolkit/pxe.conf"
REGISTRY_FILE="/opt/pxe_toolkit/os_registry.conf"
HOSTS_FILE="/opt/pxe_toolkit/hosts.conf"
TFTP_ROOT="/var/lib/tftpboot"
HTTP_ROOT="/var/www/pxe"

[[ $EUID -ne 0 ]] && error "Must run as root"

if [[ -f "${CONFIG_FILE}" ]]; then
    source "${CONFIG_FILE}"
    info "Config loaded: ${SERVER_IP} (${SERVER_IFACE})"
else
    error "${CONFIG_FILE} not found, run setup_pxe.sh first"
fi

info "========== Register OS =========="

#--- 1. Determine source (physical disc or ISO file) ---
TMP_MNT=$(mktemp -d /tmp/os_mount_XXXXX)
SOURCE_TYPE=""
ISO_PATH=""

cleanup_tmp() {
    mountpoint -q "${TMP_MNT}" 2>/dev/null && umount "${TMP_MNT}" 2>/dev/null
    rm -rf "${TMP_MNT}"
}
trap cleanup_tmp EXIT

if [[ -n "$ISO_ARG" ]]; then
    # ISO file mode
    ISO_PATH="$ISO_ARG"
    [[ ! -f "$ISO_PATH" ]] && error "ISO file not found: $ISO_PATH"
    ISO_PATH=$(readlink -f "$ISO_PATH")
    SOURCE_TYPE="iso"
    info "Using ISO file: ${ISO_PATH}"
    mount -o loop,ro "${ISO_PATH}" "${TMP_MNT}" || error "Failed to mount ISO"
else
    # Physical disc mode
    echo ""
    info "Detecting drives:"
    CDROM_DEVS=()
    i=1
    for dev in /dev/sr0 /dev/sr1 /dev/sr2 /dev/cdrom; do
        if [[ -b "$dev" ]] && blkid "$dev" &>/dev/null; then
            LABEL=$(blkid -s LABEL -o value "$dev" 2>/dev/null || echo "unknown")
            SIZE=$(blockdev --getsize64 "$dev" 2>/dev/null | awk '{printf "%.1fG", $1/1073741824}' || echo "?")
            echo "  ${i}) ${dev}  [${LABEL}]  ${SIZE}"
            CDROM_DEVS+=("$dev")
            ((i++))
        fi
    done

    if [[ ${#CDROM_DEVS[@]} -eq 0 ]]; then
        error "No disc detected, please insert one"
    elif [[ ${#CDROM_DEVS[@]} -eq 1 ]]; then
        CDROM_DEV="${CDROM_DEVS[0]}"
        info "Auto-selected: ${CDROM_DEV}"
    elif [[ ${AUTO_MODE} -eq 1 ]]; then
        CDROM_DEV="${CDROM_DEVS[0]}"
        info "Auto: selected first drive: ${CDROM_DEV}"
    else
        echo ""
        read -p "  Select drive [1-${#CDROM_DEVS[@]}] (default 1): " choice
        choice=${choice:-1}
        CDROM_DEV="${CDROM_DEVS[$((choice-1))]}"
    fi
    SOURCE_TYPE="disc"
    info "Using: ${CDROM_DEV}"
    mount -o ro "${CDROM_DEV}" "${TMP_MNT}" || error "Failed to mount disc"
fi

info "Temporarily mounted at: ${TMP_MNT}"

#--- 2. Auto-detect OS ---
OS_FAMILY=""
OS_VERSION=""
OS_NAME=""
OS_ID=""

# Try parsing from .treeinfo
if [[ -f "${TMP_MNT}/.treeinfo" ]]; then
    OS_FAMILY=$(grep -i "^family" "${TMP_MNT}/.treeinfo" | head -1 | cut -d= -f2 | xargs)
    OS_VERSION=$(grep -i "^version" "${TMP_MNT}/.treeinfo" | head -1 | cut -d= -f2 | xargs)
    OS_NAME=$(grep -i "^name" "${TMP_MNT}/.treeinfo" | head -1 | cut -d= -f2 | xargs)
fi

# Fallback to disc label
if [[ -z "${OS_FAMILY}" ]]; then
    if [[ "${SOURCE_TYPE}" == "disc" ]]; then
        DISC_LABEL=$(blkid -s LABEL -o value "${CDROM_DEV}" 2>/dev/null || echo "")
    else
        DISC_LABEL=$(blkid -s LABEL -o value "${ISO_PATH}" 2>/dev/null || echo "")
    fi
    if echo "${DISC_LABEL}" | grep -qi "rhel\|red.hat"; then
        OS_FAMILY="Red Hat Enterprise Linux"
        OS_VERSION=$(echo "${DISC_LABEL}" | grep -oP '[\d]+\.[\d]+' | head -1)
    elif echo "${DISC_LABEL}" | grep -qi "centos"; then
        OS_FAMILY="CentOS"
        OS_VERSION=$(echo "${DISC_LABEL}" | grep -oP '[\d]+[\._][\d]+' | head -1 | tr '_' '.')
        [[ -z "${OS_VERSION}" ]] && OS_VERSION=$(echo "${DISC_LABEL}" | grep -oP '[\d]+' | head -1)
    elif echo "${DISC_LABEL}" | grep -qi "rocky"; then
        OS_FAMILY="Rocky Linux"
        OS_VERSION=$(echo "${DISC_LABEL}" | grep -oP '[\d]+\.[\d]+' | head -1)
    elif echo "${DISC_LABEL}" | grep -qi "alma"; then
        OS_FAMILY="AlmaLinux"
        OS_VERSION=$(echo "${DISC_LABEL}" | grep -oP '[\d]+\.[\d]+' | head -1)
    else
        OS_FAMILY="${DISC_LABEL}"
        OS_VERSION=""
    fi
    [[ -z "${OS_NAME}" ]] && OS_NAME="${OS_FAMILY} ${OS_VERSION}"
fi

# Generate OS_ID
if echo "${OS_FAMILY}" | grep -qi "red.hat"; then
    OS_ID="rhel$(echo "${OS_VERSION}" | tr -d '.' | head -c 4)"
elif echo "${OS_FAMILY}" | grep -qi "centos"; then
    OS_ID="centos$(echo "${OS_VERSION}" | tr -d '.' | head -c 4)"
elif echo "${OS_FAMILY}" | grep -qi "rocky"; then
    OS_ID="rocky$(echo "${OS_VERSION}" | tr -d '.' | head -c 4)"
elif echo "${OS_FAMILY}" | grep -qi "alma"; then
    OS_ID="alma$(echo "${OS_VERSION}" | tr -d '.' | head -c 4)"
else
    OS_ID=$(echo "${OS_FAMILY}${OS_VERSION}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9' | head -c 12)
fi

[[ -z "${OS_ID}" ]] && OS_ID="os_unknown"
[[ -z "${OS_NAME}" ]] && OS_NAME="Unknown OS"

# Auto-detect extra kernel boot parameters
BOOT_EXTRA=""
if echo "${OS_FAMILY}" | grep -qi "NFSCNS\|neokylin"; then
    BOOT_EXTRA="mem_encrypt=off"
fi

echo ""
info "Detected OS:"
echo "  Name:    ${OS_NAME}"
echo "  Family:  ${OS_FAMILY}"
echo "  Version: ${OS_VERSION}"
echo "  ID:      ${OS_ID}"
echo ""

#--- 3. Interactive confirmation ---
if [[ ${AUTO_MODE} -eq 1 ]]; then
    OS_ID=${PXE_OS_ID:-${OS_ID}}
    OS_NAME=${PXE_OS_NAME:-${OS_NAME}}
    TARGET_DISK=${PXE_TARGET_DISK:-sda}
    ROOT_PASSWORD=${PXE_ROOT_PASSWORD:-P@ssw0rd123}
    BOOT_EXTRA=${PXE_BOOT_EXTRA:-${BOOT_EXTRA}}
else
    read -p "  OS ID [${OS_ID}]: " input_id
    OS_ID=${input_id:-${OS_ID}}

    read -p "  OS name [${OS_NAME}]: " input_name
    OS_NAME=${input_name:-${OS_NAME}}

    read -p "  Target disk [sda]: " TARGET_DISK
    TARGET_DISK=${TARGET_DISK:-sda}

    read -p "  Root password [P@ssw0rd123]: " ROOT_PASSWORD
    ROOT_PASSWORD=${ROOT_PASSWORD:-P@ssw0rd123}

    read -p "  Extra kernel args [${BOOT_EXTRA}]: " input_extra
    BOOT_EXTRA=${input_extra:-${BOOT_EXTRA}}
fi

echo ""
info "Summary:"
echo "  OS ID:       ${OS_ID}"
echo "  OS name:     ${OS_NAME}"
echo "  Source:      ${SOURCE_TYPE}"
echo "  PXE server:  ${SERVER_IP}"
echo "  Target disk: ${TARGET_DISK}"
echo "  Root passwd: ${ROOT_PASSWORD}"
echo "  Boot extra: ${BOOT_EXTRA:-(none)}"
echo ""
if [[ ${AUTO_MODE} -eq 0 ]]; then
    read -p "  Confirm? [Y/n]: " confirm
    [[ "$confirm" == "n" || "$confirm" == "N" ]] && { echo "Cancelled"; exit 0; }
fi

OS_DIR="${HTTP_ROOT}/${OS_ID}"

#--- 4/5. Copy or mount OS files ---
if [[ "${SOURCE_TYPE}" == "disc" ]]; then
    # Physical disc: rsync to local
    info "Copying disc to ${OS_DIR} (may take a few minutes)..."
    mkdir -p "${OS_DIR}"
    rsync -a --info=progress2 "${TMP_MNT}/" "${OS_DIR}/"
    info "Copy complete"
else
    # ISO file: permanent loop mount
    # Unmount temp first
    umount "${TMP_MNT}" 2>/dev/null || true
    mkdir -p "${OS_DIR}"
    # Unmount target if already mounted
    mountpoint -q "${OS_DIR}" && umount "${OS_DIR}"
    mount -o loop,ro "${ISO_PATH}" "${OS_DIR}"
    # Persist in fstab
    sed -i "\|${OS_DIR}|d" /etc/fstab
    echo "${ISO_PATH}  ${OS_DIR}  iso9660  loop,ro  0 0" >> /etc/fstab
    info "ISO permanently mounted at ${OS_DIR}"
fi

# Verify
[[ ! -d "${OS_DIR}/repodata" ]] && warn "repodata not found, may not be a valid install source"

#--- 6. Copy kernel + initrd ---
mkdir -p "${TFTP_ROOT}/${OS_ID}"
if [[ -f "${OS_DIR}/images/pxeboot/vmlinuz" ]]; then
    cp "${OS_DIR}/images/pxeboot/vmlinuz"    "${TFTP_ROOT}/${OS_ID}/"
    cp "${OS_DIR}/images/pxeboot/initrd.img" "${TFTP_ROOT}/${OS_ID}/"
    chmod 644 "${TFTP_ROOT}/${OS_ID}/vmlinuz" "${TFTP_ROOT}/${OS_ID}/initrd.img"
    info "Kernel copied to ${TFTP_ROOT}/${OS_ID}/"
else
    warn "images/pxeboot/vmlinuz not found"
fi

#--- 7. Copy UEFI shim + grubx64.efi on first OS registration ---
if [[ ! -f "${TFTP_ROOT}/shimx64.efi" ]]; then
    UEFI_OK=0
    if [[ -f "${OS_DIR}/EFI/BOOT/shimx64.efi" ]]; then
        cp "${OS_DIR}/EFI/BOOT/shimx64.efi" "${TFTP_ROOT}/shimx64.efi"
        info "UEFI shimx64.efi copied"
        UEFI_OK=1
    elif [[ -f "${OS_DIR}/EFI/BOOT/BOOTX64.EFI" ]]; then
        cp "${OS_DIR}/EFI/BOOT/BOOTX64.EFI" "${TFTP_ROOT}/shimx64.efi"
        info "UEFI BOOTX64.EFI -> shimx64.efi copied"
        UEFI_OK=1
    fi
    if [[ -f "${OS_DIR}/EFI/BOOT/grubx64.efi" ]]; then
        cp "${OS_DIR}/EFI/BOOT/grubx64.efi" "${TFTP_ROOT}/grubx64.efi"
        info "UEFI grubx64.efi copied"
        UEFI_OK=1
    fi
    [[ ${UEFI_OK} -eq 0 ]] && warn "UEFI boot files not found"
else
    info "UEFI boot files already exist, skipping"
fi

#--- 8. Generate Kickstart (BIOS + UEFI) ---
generate_ks() {
    local KS_FILE="$1"
    local BOOT_MODE="$2"
    local L_OS_ID="$3"
    local L_DISK="$4"
    local L_PASSWORD="$5"

    cat > "${KS_FILE}" << KSEOF
#version=DEVEL
install
graphical
lang en_US.UTF-8
keyboard us
timezone Asia/Shanghai --isUtc

network --bootproto=dhcp --onboot=yes --activate

rootpw --plaintext ${L_PASSWORD}

url --url=http://${SERVER_IP}/${L_OS_ID}

firewall --disabled
selinux --disabled
services --disabled=firewalld

%addon com_redhat_kdump --disable
%end

ignoredisk --only-use=${L_DISK}
clearpart --all --initlabel --drives=${L_DISK}
KSEOF

    if [[ "$BOOT_MODE" == "uefi" ]]; then
        cat >> "${KS_FILE}" << KSEOF
bootloader --location=mbr --boot-drive=${L_DISK} --append="crashkernel=auto"
part /boot     --fstype=xfs  --size=500    --ondisk=${L_DISK}
part /boot/efi --fstype=efi  --size=500    --ondisk=${L_DISK}
part swap      --size=65536               --ondisk=${L_DISK}
part /         --fstype=xfs  --size=1     --grow --ondisk=${L_DISK}
KSEOF
    else
        cat >> "${KS_FILE}" << KSEOF
bootloader --location=mbr --boot-drive=${L_DISK}
part /boot     --fstype=xfs  --size=500    --ondisk=${L_DISK}
part swap      --size=65536               --ondisk=${L_DISK}
part /         --fstype=xfs  --size=1     --grow --ondisk=${L_DISK}
KSEOF
    fi

    cat >> "${KS_FILE}" << KSEOF

skipx
reboot

%packages
@^graphical-server-environment
@development
net-tools
vim
wget
bash-completion
%end

%post --log=/root/ks-post.log
#!/bin/bash
systemctl disable firewalld 2>/dev/null
systemctl stop firewalld 2>/dev/null
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
echo "Post-install completed: \$(date)"
%end
KSEOF
}

generate_ks "${HTTP_ROOT}/ks-${OS_ID}-bios.cfg" "bios" "${OS_ID}" "${TARGET_DISK}" "${ROOT_PASSWORD}"
generate_ks "${HTTP_ROOT}/ks-${OS_ID}-uefi.cfg" "uefi" "${OS_ID}" "${TARGET_DISK}" "${ROOT_PASSWORD}"
info "Kickstart generated: ks-${OS_ID}-bios.cfg / ks-${OS_ID}-uefi.cfg"

#--- 9. Register in os_registry.conf ---
touch "${REGISTRY_FILE}"
# Remove old record for this OS_ID (if any)
sed -i "/^${OS_ID}|/d" "${REGISTRY_FILE}"
echo "${OS_ID}|${OS_NAME}|${TARGET_DISK}|${ROOT_PASSWORD}|${BOOT_EXTRA}" >> "${REGISTRY_FILE}"
info "Registered: ${OS_ID} -> ${REGISTRY_FILE}"

#--- 10. Regenerate PXE default menus ---
regenerate_pxe_menus() {
    local _TFTP="${TFTP_ROOT}"
    local _HTTP="${HTTP_ROOT}"

    # Read all registered OSes
    local OS_IDS=()
    local OS_NAMES=()
    local OS_EXTRAS=()
    while IFS='|' read -r oid oname odisk opwd oextra; do
        [[ -z "$oid" || "$oid" == \#* ]] && continue
        OS_IDS+=("$oid")
        OS_NAMES+=("$oname")
        OS_EXTRAS+=("$oextra")
    done < "${REGISTRY_FILE}"

    [[ ${#OS_IDS[@]} -eq 0 ]] && return

    # First registered OS is the default
    local DEFAULT_ID="${OS_IDS[0]}"

    # --- BIOS default menu ---
    mkdir -p "${_TFTP}/pxelinux.cfg"
    {
        echo "DEFAULT menu.c32"
        echo "PROMPT 0"
        echo "TIMEOUT 100"
        echo "MENU TITLE ====== PXE Install Menu (BIOS) ======"
        echo ""
        local idx=1
        for i in "${!OS_IDS[@]}"; do
            local oid="${OS_IDS[$i]}"
            local oname="${OS_NAMES[$i]}"
            local oextra="${OS_EXTRAS[$i]}"
            echo "LABEL ${oid}_ks"
            echo "  MENU LABEL ^${idx}. Install ${oname} (Kickstart Auto)"
            [[ "$oid" == "$DEFAULT_ID" ]] && echo "  MENU DEFAULT"
            echo "  KERNEL ${oid}/vmlinuz"
            echo "  APPEND initrd=${oid}/initrd.img inst.repo=http://${SERVER_IP}/${oid} inst.ks=http://${SERVER_IP}/ks-${oid}-bios.cfg ip=dhcp${oextra:+ ${oextra}}"
            echo ""
            ((idx++))
        done
        echo "LABEL local"
        echo "  MENU LABEL ^${idx}. Boot from local drive"
        echo "  LOCALBOOT 0"
    } > "${_TFTP}/pxelinux.cfg/default"

    # --- UEFI grub.cfg ---
    {
        echo "set timeout=10"
        echo "set default=0"
        echo ""

        # MAC condition check (if hosts.conf exists and not empty)
        if [[ -s "${HOSTS_FILE}" ]]; then
            local first_mac=1
            while read -r mac oid; do
                [[ -z "$mac" || "$mac" == \#* ]] && continue
                local mac_colon
                mac_colon=$(echo "$mac" | tr '-' ':' | tr '[:upper:]' '[:lower:]')
                # Find this OS index in the menu
                local menu_idx=0
                for j in "${!OS_IDS[@]}"; do
                    [[ "${OS_IDS[$j]}" == "$oid" ]] && { menu_idx=$j; break; }
                done
                if [[ $first_mac -eq 1 ]]; then
                    echo "if [ \"\${net_default_mac}\" = \"${mac_colon}\" ]; then"
                    first_mac=0
                else
                    echo "elif [ \"\${net_default_mac}\" = \"${mac_colon}\" ]; then"
                fi
                echo "  set default=${menu_idx}"
                echo "  set timeout=3"
            done < "${HOSTS_FILE}"
            [[ $first_mac -eq 0 ]] && echo "fi"
            echo ""
        fi

        # Menu entries
        for i in "${!OS_IDS[@]}"; do
            local oid="${OS_IDS[$i]}"
            local oname="${OS_NAMES[$i]}"
            local oextra="${OS_EXTRAS[$i]}"
            echo "menuentry 'Install ${oname} (Kickstart Auto)' {"
            echo "  linuxefi ${oid}/vmlinuz inst.repo=http://${SERVER_IP}/${oid} inst.ks=http://${SERVER_IP}/ks-${oid}-uefi.cfg ip=dhcp${oextra:+ ${oextra}}"
            echo "  initrdefi ${oid}/initrd.img"
            echo "}"
            echo ""
        done

        echo "menuentry 'Boot from local drive' {"
        echo "  exit"
        echo "}"
    } > "${_TFTP}/grub.cfg"

    # --- Per-MAC BIOS config files ---
    # Clean old per-MAC files
    find "${_TFTP}/pxelinux.cfg/" -name "01-*" -delete 2>/dev/null || true

    if [[ -s "${HOSTS_FILE}" ]]; then
        while read -r mac oid; do
            [[ -z "$mac" || "$mac" == \#* ]] && continue
            local mac_dash
            mac_dash=$(echo "$mac" | tr ':' '-' | tr '[:upper:]' '[:lower:]')
            local mac_file="${_TFTP}/pxelinux.cfg/01-${mac_dash}"
            # Find OS name and extra boot params
            local oname="$oid"
            local oextra=""
            for j in "${!OS_IDS[@]}"; do
                [[ "${OS_IDS[$j]}" == "$oid" ]] && { oname="${OS_NAMES[$j]}"; oextra="${OS_EXTRAS[$j]}"; break; }
            done
            {
                echo "DEFAULT ${oid}_ks"
                echo "PROMPT 0"
                echo "TIMEOUT 30"
                echo ""
                echo "LABEL ${oid}_ks"
                echo "  MENU LABEL Install ${oname} (Kickstart Auto)"
                echo "  KERNEL ${oid}/vmlinuz"
                echo "  APPEND initrd=${oid}/initrd.img inst.repo=http://${SERVER_IP}/${oid} inst.ks=http://${SERVER_IP}/ks-${oid}-bios.cfg ip=dhcp${oextra:+ ${oextra}}"
            } > "${mac_file}"
        done < "${HOSTS_FILE}"
    fi

    info "PXE menus updated"
}

regenerate_pxe_menus

#--- 11. Restart services ---
systemctl restart dnsmasq 2>/dev/null || true
systemctl restart nginx 2>/dev/null || true

#--- 12. Verify ---
echo ""
info "========== Verification =========="
echo -n "  dnsmasq: "; systemctl is-active dnsmasq
echo -n "  nginx:   "; systemctl is-active nginx

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${SERVER_IP}/${OS_ID}/repodata/repomd.xml" 2>/dev/null || echo "000")
[[ "$HTTP_CODE" == "200" ]] && info "✓ Install source (${OS_ID})" || warn "✗ Install source ${OS_ID} (HTTP ${HTTP_CODE})"

HTTP_CODE2=$(curl -s -o /dev/null -w "%{http_code}" "http://${SERVER_IP}/ks-${OS_ID}-bios.cfg" 2>/dev/null || echo "000")
[[ "$HTTP_CODE2" == "200" ]] && info "✓ ks-${OS_ID}-bios.cfg" || warn "✗ ks-${OS_ID}-bios.cfg"

HTTP_CODE3=$(curl -s -o /dev/null -w "%{http_code}" "http://${SERVER_IP}/ks-${OS_ID}-uefi.cfg" 2>/dev/null || echo "000")
[[ "$HTTP_CODE3" == "200" ]] && info "✓ ks-${OS_ID}-uefi.cfg" || warn "✗ ks-${OS_ID}-uefi.cfg"

echo ""
[[ -f "${TFTP_ROOT}/pxelinux.0" ]]            && info "✓ BIOS:  pxelinux.0"              || warn "✗ BIOS:  pxelinux.0"
[[ -f "${TFTP_ROOT}/shimx64.efi" ]]           && info "✓ UEFI:  shimx64.efi (Secure Boot)" || warn "✗ UEFI:  shimx64.efi"
[[ -f "${TFTP_ROOT}/grubx64.efi" ]]           && info "✓ UEFI:  grubx64.efi"             || warn "✗ UEFI:  grubx64.efi"
[[ -f "${TFTP_ROOT}/${OS_ID}/vmlinuz" ]]      && info "✓ ${OS_ID}/vmlinuz"                || warn "✗ ${OS_ID}/vmlinuz"
[[ -f "${TFTP_ROOT}/${OS_ID}/initrd.img" ]]   && info "✓ ${OS_ID}/initrd.img"             || warn "✗ ${OS_ID}/initrd.img"

echo ""
info "Registered OSes:"
while IFS='|' read -r oid oname odisk opwd oextra; do
    [[ -z "$oid" || "$oid" == \#* ]] && continue
    echo "  - ${oid}: ${oname}"
done < "${REGISTRY_FILE}"

echo ""
info "=========================================="
info "  OS ${OS_NAME} (${OS_ID}) registered!"
info "=========================================="
echo ""
echo "  Source:    http://${SERVER_IP}/${OS_ID}"
echo "  KS BIOS:  http://${SERVER_IP}/ks-${OS_ID}-bios.cfg"
echo "  KS UEFI:  http://${SERVER_IP}/ks-${OS_ID}-uefi.cfg"
echo ""
echo "  Next steps:"
echo "    - Register more OSes: sudo /opt/pxe_toolkit/mount_disc.sh"
echo "    - Manage MAC mapping: sudo /opt/pxe_toolkit/manage_hosts.sh"
echo "    - Or PXE boot target servers directly"
echo ""
