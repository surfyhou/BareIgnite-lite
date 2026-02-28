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

# ===== setup_pxe.sh =====
cat > "${PAYLOAD_DIR}/setup_pxe.sh" << 'SETUPEOF'
#!/bin/bash
#============================================================================
# PXE Service Interactive Setup
# Usage: sudo /opt/pxe_toolkit/setup_pxe.sh [--auto]
#============================================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# --auto non-interactive mode
AUTO_MODE=0
for _arg in "$@"; do
    case "$_arg" in
        --auto) AUTO_MODE=1 ;;
        --help|-h)
            echo "Usage: sudo $(basename "$0") [--auto]"
            echo ""
            echo "Configure PXE server: network interfaces, IP, DHCP, dnsmasq, nginx."
            echo ""
            echo "Options:"
            echo "  --auto    Non-interactive mode. Selects all interfaces without IP,"
            echo "            uses defaults or values from existing pxe.conf."
            echo "            Environment overrides: PXE_IFACE, PXE_SERVER_IP,"
            echo "            PXE_DHCP_START, PXE_DHCP_END, PXE_NETMASK, PXE_GATEWAY"
            echo "  --help    Show this help"
            echo ""
            echo "Re-run anytime to reconfigure. Delete /opt/pxe_toolkit/pxe.conf to"
            echo "trigger auto-setup on next boot via pxe-setup.service."
            exit 0
            ;;
    esac
done

CONFIG_FILE="/opt/pxe_toolkit/pxe.conf"

[[ $EUID -ne 0 ]] && error "Must run as root"

# Load existing config as defaults
_DEF_IP="172.16.0.1"
_DEF_DHCP_START="172.16.0.100"
_DEF_DHCP_END="172.16.0.200"
_DEF_NETMASK="255.255.255.0"
_DEF_GATEWAY=""
_DEF_IFACES=""
if [[ -f "${CONFIG_FILE}" ]]; then
    source "${CONFIG_FILE}"
    _DEF_IP="${SERVER_IP:-${_DEF_IP}}"
    _DEF_IFACES="${SERVER_IFACES:-${SERVER_IFACE:-}}"
    _DEF_DHCP_START="${DHCP_RANGE_START:-${_DEF_DHCP_START}}"
    _DEF_DHCP_END="${DHCP_RANGE_END:-${_DEF_DHCP_END}}"
    _DEF_NETMASK="${DHCP_NETMASK:-${_DEF_NETMASK}}"
    _DEF_GATEWAY="${DHCP_GATEWAY:-}"
    unset SERVER_IP SERVER_IFACE SERVER_IFACES DHCP_RANGE_START DHCP_RANGE_END DHCP_NETMASK DHCP_GATEWAY
    info "Loaded existing config from ${CONFIG_FILE}"
fi
_DEF_GATEWAY="${_DEF_GATEWAY:-${_DEF_IP}}"

info "========== PXE Service Setup =========="
echo ""

#--- 1. Select interface ---
info "Detected network interfaces:"
echo ""
IFACES=()
i=1
while read -r iface; do
    [[ "$iface" == "lo" ]] && continue
    ADDR=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[0-9.]+' || echo "no IP")
    STATE=$(cat /sys/class/net/"$iface"/operstate 2>/dev/null || echo "unknown")
    MAC=$(cat /sys/class/net/"$iface"/address 2>/dev/null || echo "")
    echo "  ${i}) ${iface}  [${STATE}]  MAC: ${MAC}  IP: ${ADDR}"
    IFACES+=("$iface")
    ((i++))
done < <(ls /sys/class/net/)
echo ""

if [[ ${#IFACES[@]} -eq 0 ]]; then
    error "No network interfaces detected"
elif [[ ${#IFACES[@]} -eq 1 ]]; then
    SERVER_IFACES=("${IFACES[0]}")
    info "Only one interface, auto-selected: ${SERVER_IFACES[0]}"
elif [[ ${AUTO_MODE} -eq 1 ]]; then
    if [[ -n "${PXE_IFACE}" ]]; then
        SERVER_IFACES=("${PXE_IFACE}")
    else
        # Auto: select all interfaces without an IPv4 address
        SERVER_IFACES=()
        for iface in "${IFACES[@]}"; do
            addr=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[0-9.]+' || true)
            if [[ -z "$addr" ]]; then
                SERVER_IFACES+=("$iface")
            fi
        done
        if [[ ${#SERVER_IFACES[@]} -eq 0 ]]; then
            SERVER_IFACES=("${IFACES[1]}")
            warn "No interfaces without IP found, falling back to: ${SERVER_IFACES[0]}"
        fi
    fi
    info "Auto: selected interfaces: ${SERVER_IFACES[*]}"
else
    read -p "  Select interface [1-${#IFACES[@]}] (default 1): " choice
    choice=${choice:-1}
    SERVER_IFACES=("${IFACES[$((choice-1))]}")
fi
info "Using interfaces: ${SERVER_IFACES[*]}"

#--- 2. Network parameters ---
echo ""
info "Network parameters (press Enter for defaults):"
echo ""

if [[ ${AUTO_MODE} -eq 1 ]]; then
    SERVER_IP=${PXE_SERVER_IP:-${_DEF_IP}}
    DHCP_RANGE_START=${PXE_DHCP_START:-${_DEF_DHCP_START}}
    DHCP_RANGE_END=${PXE_DHCP_END:-${_DEF_DHCP_END}}
    DHCP_NETMASK=${PXE_NETMASK:-${_DEF_NETMASK}}
    DHCP_GATEWAY=${PXE_GATEWAY:-${_DEF_GATEWAY}}
else
    read -p "  PXE server IP [${_DEF_IP}]: " SERVER_IP
    SERVER_IP=${SERVER_IP:-${_DEF_IP}}

    read -p "  DHCP range start [${_DEF_DHCP_START}]: " DHCP_RANGE_START
    DHCP_RANGE_START=${DHCP_RANGE_START:-${_DEF_DHCP_START}}

    read -p "  DHCP range end [${_DEF_DHCP_END}]: " DHCP_RANGE_END
    DHCP_RANGE_END=${DHCP_RANGE_END:-${_DEF_DHCP_END}}

    read -p "  Subnet mask [${_DEF_NETMASK}]: " DHCP_NETMASK
    DHCP_NETMASK=${DHCP_NETMASK:-${_DEF_NETMASK}}

    read -p "  Gateway [${SERVER_IP}]: " DHCP_GATEWAY
    DHCP_GATEWAY=${DHCP_GATEWAY:-${SERVER_IP}}
fi

echo ""
info "Configuration summary:"
echo "  Interfaces: ${SERVER_IFACES[*]}"
echo "  Server IP:  ${SERVER_IP}"
echo "  DHCP range: ${DHCP_RANGE_START} - ${DHCP_RANGE_END}"
echo "  Netmask:    ${DHCP_NETMASK}"
echo "  Gateway:    ${DHCP_GATEWAY}"
echo ""
if [[ ${AUTO_MODE} -eq 0 ]]; then
    read -p "  Confirm? [Y/n]: " confirm
    [[ "$confirm" == "n" || "$confirm" == "N" ]] && { echo "Cancelled"; exit 0; }
fi

# Save configuration
cat > "${CONFIG_FILE}" << CONFEOF
SERVER_IP="${SERVER_IP}"
SERVER_IFACES="${SERVER_IFACES[*]}"
DHCP_RANGE_START="${DHCP_RANGE_START}"
DHCP_RANGE_END="${DHCP_RANGE_END}"
DHCP_NETMASK="${DHCP_NETMASK}"
DHCP_GATEWAY="${DHCP_GATEWAY}"
CONFEOF

TFTP_ROOT="/var/lib/tftpboot"
HTTP_ROOT="/var/www/pxe"

#--- 3. Configure interfaces ---
info "Configuring interfaces..."
for iface in "${SERVER_IFACES[@]}"; do
    ip addr flush dev "${iface}" 2>/dev/null || true
    ip addr add "${SERVER_IP}/24" dev "${iface}" 2>/dev/null || true
    ip link set "${iface}" up
done

mkdir -p /etc/netplan
{
echo "network:"
echo "  version: 2"
echo "  ethernets:"
for iface in "${SERVER_IFACES[@]}"; do
    echo "    ${iface}:"
    echo "      addresses:"
    echo "        - ${SERVER_IP}/24"
done
} > /etc/netplan/99-pxe-static.yaml
netplan apply 2>/dev/null || true

#--- 4. Install offline debs (if not already installed) ---
if ! command -v dnsmasq &>/dev/null || ! command -v nginx &>/dev/null; then
    info "Installing offline packages..."
    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true
    rm -f /etc/resolv.conf
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    dpkg -i --force-depends /opt/pxe_toolkit/debs/*.deb 2>/dev/null || true
    dpkg --configure -a 2>/dev/null || true
else
    info "Packages already installed, skipping"
fi

systemctl stop dnsmasq 2>/dev/null || true
systemctl stop nginx 2>/dev/null || true

#--- 5. Directories + BIOS boot ---
info "Configuring TFTP..."
mkdir -p "${TFTP_ROOT}/pxelinux.cfg"
mkdir -p "${HTTP_ROOT}"

for f in pxelinux.0 menu.c32 ldlinux.c32 libutil.c32 libcom32.c32; do
    for dir in /usr/lib/PXELINUX /usr/lib/syslinux/modules/bios /usr/share/syslinux; do
        [[ -f "${dir}/${f}" ]] && cp "${dir}/${f}" "${TFTP_ROOT}/" && break
    done
done

#--- 6. dnsmasq ---
info "Configuring dnsmasq..."
> /etc/dnsmasq.conf
for iface in "${SERVER_IFACES[@]}"; do
    echo "interface=${iface}" >> /etc/dnsmasq.conf
done
cat >> /etc/dnsmasq.conf << DNSEOF
bind-interfaces

dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},${DHCP_NETMASK},1h
dhcp-option=3,${DHCP_GATEWAY}

dhcp-match=set:bios,option:client-arch,0
dhcp-boot=tag:bios,pxelinux.0,,${SERVER_IP}

dhcp-match=set:efi-x86_64,option:client-arch,7
dhcp-match=set:efi-x86_64,option:client-arch,9
dhcp-boot=tag:efi-x86_64,shimx64.efi,,${SERVER_IP}

enable-tftp
tftp-root=${TFTP_ROOT}
port=0
log-dhcp
log-facility=/var/log/dnsmasq.log
DNSEOF

#--- 7. nginx ---
info "Configuring nginx..."
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
mkdir -p /etc/nginx/conf.d

cat > /etc/nginx/conf.d/pxe.conf << NGXEOF
server {
    listen 80;
    server_name ${SERVER_IP};

    location / {
        root ${HTTP_ROOT};
        autoindex on;
        autoindex_exact_size off;
        autoindex_localtime on;
    }
}
NGXEOF

#--- 8. Start services ---
info "Starting services..."
iptables -F 2>/dev/null || true
ufw disable 2>/dev/null || true

systemctl enable dnsmasq
systemctl enable nginx
systemctl restart dnsmasq
systemctl restart nginx

echo ""
echo -n "  dnsmasq: "; systemctl is-active dnsmasq
echo -n "  nginx:   "; systemctl is-active nginx

echo ""
info "=========================================="
info "  PXE base services are ready!"
info "=========================================="
echo ""
echo "  Next steps:"
echo "    1. Insert OS disc (or prepare ISO file)"
echo "    2. Register OS:  sudo /opt/pxe_toolkit/mount_disc.sh"
echo "    3. MAC mapping: sudo /opt/pxe_toolkit/manage_hosts.sh"
echo ""
SETUPEOF

# ===== mount_disc.sh =====
cat > "${PAYLOAD_DIR}/mount_disc.sh" << 'MOUNTEOF'
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
else
    read -p "  OS ID [${OS_ID}]: " input_id
    OS_ID=${input_id:-${OS_ID}}

    read -p "  OS name [${OS_NAME}]: " input_name
    OS_NAME=${input_name:-${OS_NAME}}

    read -p "  Target disk [sda]: " TARGET_DISK
    TARGET_DISK=${TARGET_DISK:-sda}

    read -p "  Root password [P@ssw0rd123]: " ROOT_PASSWORD
    ROOT_PASSWORD=${ROOT_PASSWORD:-P@ssw0rd123}
fi

echo ""
info "Summary:"
echo "  OS ID:       ${OS_ID}"
echo "  OS name:     ${OS_NAME}"
echo "  Source:      ${SOURCE_TYPE}"
echo "  PXE server:  ${SERVER_IP}"
echo "  Target disk: ${TARGET_DISK}"
echo "  Root passwd: ${ROOT_PASSWORD}"
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
echo "${OS_ID}|${OS_NAME}|${TARGET_DISK}|${ROOT_PASSWORD}" >> "${REGISTRY_FILE}"
info "Registered: ${OS_ID} -> ${REGISTRY_FILE}"

#--- 10. Regenerate PXE default menus ---
regenerate_pxe_menus() {
    local _TFTP="${TFTP_ROOT}"
    local _HTTP="${HTTP_ROOT}"

    # Read all registered OSes
    local OS_IDS=()
    local OS_NAMES=()
    while IFS='|' read -r oid oname odisk opwd; do
        [[ -z "$oid" || "$oid" == \#* ]] && continue
        OS_IDS+=("$oid")
        OS_NAMES+=("$oname")
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
            echo "LABEL ${oid}_ks"
            echo "  MENU LABEL ^${idx}. Install ${oname} (Kickstart Auto)"
            [[ "$oid" == "$DEFAULT_ID" ]] && echo "  MENU DEFAULT"
            echo "  KERNEL ${oid}/vmlinuz"
            echo "  APPEND initrd=${oid}/initrd.img inst.repo=http://${SERVER_IP}/${oid} inst.ks=http://${SERVER_IP}/ks-${oid}-bios.cfg ip=dhcp"
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
            echo "menuentry 'Install ${oname} (Kickstart Auto)' {"
            echo "  linuxefi ${oid}/vmlinuz inst.repo=http://${SERVER_IP}/${oid} inst.ks=http://${SERVER_IP}/ks-${oid}-uefi.cfg ip=dhcp"
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
            # Find OS name
            local oname="$oid"
            for j in "${!OS_IDS[@]}"; do
                [[ "${OS_IDS[$j]}" == "$oid" ]] && { oname="${OS_NAMES[$j]}"; break; }
            done
            {
                echo "DEFAULT ${oid}_ks"
                echo "PROMPT 0"
                echo "TIMEOUT 30"
                echo ""
                echo "LABEL ${oid}_ks"
                echo "  MENU LABEL Install ${oname} (Kickstart Auto)"
                echo "  KERNEL ${oid}/vmlinuz"
                echo "  APPEND initrd=${oid}/initrd.img inst.repo=http://${SERVER_IP}/${oid} inst.ks=http://${SERVER_IP}/ks-${oid}-bios.cfg ip=dhcp"
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
while IFS='|' read -r oid oname odisk opwd; do
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
MOUNTEOF

# ===== manage_hosts.sh =====
cat > "${PAYLOAD_DIR}/manage_hosts.sh" << 'HOSTSEOF'
#!/bin/bash
#============================================================================
# manage_hosts.sh - MAC Address Mapping Management
#
# Usage:
#   sudo manage_hosts.sh                    # Interactive menu
#   sudo manage_hosts.sh list-os            # List registered OSes
#   sudo manage_hosts.sh list               # List MAC mappings
#   sudo manage_hosts.sh add <mac> <os_id>  # Add mapping
#   sudo manage_hosts.sh del <mac>          # Delete mapping
#   sudo manage_hosts.sh batch-add <start_mac> <end_mac> <os_id>  # Batch add range
#   sudo manage_hosts.sh apply              # Regenerate PXE config
#============================================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

CONFIG_FILE="/opt/pxe_toolkit/pxe.conf"
REGISTRY_FILE="/opt/pxe_toolkit/os_registry.conf"
HOSTS_FILE="/opt/pxe_toolkit/hosts.conf"
TFTP_ROOT="/var/lib/tftpboot"
HTTP_ROOT="/var/www/pxe"

[[ $EUID -ne 0 ]] && error "Must run as root"

if [[ -f "${CONFIG_FILE}" ]]; then
    source "${CONFIG_FILE}"
else
    error "${CONFIG_FILE} not found, run setup_pxe.sh first"
fi

touch "${HOSTS_FILE}" "${REGISTRY_FILE}"

#--- Menu functions ---

list_os() {
    echo ""
    if [[ ! -s "${REGISTRY_FILE}" ]]; then
        warn "No OSes registered yet"
        return
    fi
    info "Registered OSes:"
    echo ""
    local idx=1
    while IFS='|' read -r oid oname odisk opwd; do
        [[ -z "$oid" || "$oid" == \#* ]] && continue
        echo "  ${idx}) ${oid}  -  ${oname}  (disk: ${odisk})"
        ((idx++))
    done < "${REGISTRY_FILE}"
    echo ""
}

list_hosts() {
    echo ""
    if [[ ! -s "${HOSTS_FILE}" ]]; then
        warn "No MAC mappings configured"
        return
    fi
    info "Current MAC mappings:"
    echo ""
    local idx=1
    while read -r mac oid; do
        [[ -z "$mac" || "$mac" == \#* ]] && continue
        # Find OS name
        local oname="$oid"
        while IFS='|' read -r rid rname rdisk rpwd; do
            [[ "$rid" == "$oid" ]] && { oname="$rname"; break; }
        done < "${REGISTRY_FILE}"
        echo "  ${idx}) ${mac}  ->  ${oid} (${oname})"
        ((idx++))
    done < "${HOSTS_FILE}"
    echo ""
}

add_host() {
    echo ""
    if [[ ! -s "${REGISTRY_FILE}" ]]; then
        warn "Register an OS first (mount_disc.sh)"
        return
    fi

    # Input MAC address
    read -p "  MAC address (format aa:bb:cc:dd:ee:ff): " input_mac
    [[ -z "$input_mac" ]] && { warn "Cancelled"; return; }

    # Normalize MAC: lowercase, colon-separated
    local mac
    mac=$(echo "$input_mac" | tr '[:upper:]' '[:lower:]' | tr '-' ':')

    # Simple format validation
    if ! echo "$mac" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; then
        warn "Invalid MAC format: ${mac}"
        return
    fi

    # Select OS
    echo ""
    info "Select target OS:"
    local os_ids=()
    local os_names=()
    local idx=1
    while IFS='|' read -r oid oname odisk opwd; do
        [[ -z "$oid" || "$oid" == \#* ]] && continue
        echo "  ${idx}) ${oid}  -  ${oname}"
        os_ids+=("$oid")
        os_names+=("$oname")
        ((idx++))
    done < "${REGISTRY_FILE}"
    echo ""

    read -p "  Select [1-${#os_ids[@]}] (default 1): " os_choice
    os_choice=${os_choice:-1}
    local target_oid="${os_ids[$((os_choice-1))]}"
    local target_oname="${os_names[$((os_choice-1))]}"

    if [[ -z "$target_oid" ]]; then
        warn "Invalid selection"
        return
    fi

    # Remove old mapping for this MAC (if any)
    sed -i "/^${mac} /d" "${HOSTS_FILE}" 2>/dev/null || true
    sed -i "/^${mac}	/d" "${HOSTS_FILE}" 2>/dev/null || true

    echo "${mac} ${target_oid}" >> "${HOSTS_FILE}"
    info "Added: ${mac} -> ${target_oid} (${target_oname})"
}

del_host() {
    echo ""
    if [[ ! -s "${HOSTS_FILE}" ]]; then
        warn "No MAC mappings to delete"
        return
    fi

    # Show numbered list
    local macs=()
    local oids=()
    local idx=1
    while read -r mac oid; do
        [[ -z "$mac" || "$mac" == \#* ]] && continue
        local oname="$oid"
        while IFS='|' read -r rid rname rdisk rpwd; do
            [[ "$rid" == "$oid" ]] && { oname="$rname"; break; }
        done < "${REGISTRY_FILE}"
        echo "  ${idx}) ${mac}  ->  ${oid} (${oname})"
        macs+=("$mac")
        oids+=("$oid")
        ((idx++))
    done < "${HOSTS_FILE}"
    echo ""

    read -p "  Number to delete [1-${#macs[@]}]: " del_choice
    [[ -z "$del_choice" ]] && { warn "Cancelled"; return; }

    local del_mac="${macs[$((del_choice-1))]}"
    if [[ -z "$del_mac" ]]; then
        warn "Invalid selection"
        return
    fi

    sed -i "/^${del_mac} /d" "${HOSTS_FILE}" 2>/dev/null || true
    sed -i "/^${del_mac}	/d" "${HOSTS_FILE}" 2>/dev/null || true
    info "Deleted: ${del_mac}"
}

batch_add_host() {
    echo ""
    if [[ ! -s "${REGISTRY_FILE}" ]]; then
        warn "Register an OS first (mount_disc.sh)"
        return
    fi

    info "Batch add - add a range of MACs (same prefix) to one OS"
    echo ""

    read -p "  Starting MAC (e.g. aa:bb:cc:dd:ee:01): " start_mac
    [[ -z "$start_mac" ]] && { warn "Cancelled"; return; }
    start_mac=$(echo "$start_mac" | tr '[:upper:]' '[:lower:]' | tr '-' ':')
    if ! echo "$start_mac" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; then
        warn "Invalid MAC format: ${start_mac}"
        return
    fi

    read -p "  Ending MAC   (e.g. aa:bb:cc:dd:ee:0a): " end_mac
    [[ -z "$end_mac" ]] && { warn "Cancelled"; return; }
    end_mac=$(echo "$end_mac" | tr '[:upper:]' '[:lower:]' | tr '-' ':')
    if ! echo "$end_mac" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; then
        warn "Invalid MAC format: ${end_mac}"
        return
    fi

    local start_int end_int
    start_int=$(( 16#${start_mac//:/} ))
    end_int=$(( 16#${end_mac//:/} ))

    if [[ $start_int -gt $end_int ]]; then
        warn "Starting MAC must be <= ending MAC"
        return
    fi

    local count=$(( end_int - start_int + 1 ))
    if [[ $count -gt 1000 ]]; then
        warn "Range too large (${count} MACs, max 1000)"
        return
    fi

    # Select OS
    echo ""
    info "Select target OS for all ${count} MACs:"
    local os_ids=()
    local os_names=()
    local idx=1
    while IFS='|' read -r oid oname odisk opwd; do
        [[ -z "$oid" || "$oid" == \#* ]] && continue
        echo "  ${idx}) ${oid}  -  ${oname}"
        os_ids+=("$oid")
        os_names+=("$oname")
        ((idx++))
    done < "${REGISTRY_FILE}"
    echo ""

    read -p "  Select [1-${#os_ids[@]}] (default 1): " os_choice
    os_choice=${os_choice:-1}
    local target_oid="${os_ids[$((os_choice-1))]}"
    local target_oname="${os_names[$((os_choice-1))]}"

    if [[ -z "$target_oid" ]]; then
        warn "Invalid selection"
        return
    fi

    echo ""
    info "Will add ${count} MACs: ${start_mac} ~ ${end_mac} -> ${target_oid} (${target_oname})"
    read -p "  Confirm? [Y/n]: " confirm
    [[ "$confirm" == "n" || "$confirm" == "N" ]] && { warn "Cancelled"; return; }

    local i added=0
    for (( i = start_int; i <= end_int; i++ )); do
        local mac
        mac=$(printf "%02x:%02x:%02x:%02x:%02x:%02x" \
            $(( (i >> 40) & 0xff )) \
            $(( (i >> 32) & 0xff )) \
            $(( (i >> 24) & 0xff )) \
            $(( (i >> 16) & 0xff )) \
            $(( (i >> 8) & 0xff )) \
            $(( i & 0xff )))
        sed -i "/^${mac} /d" "${HOSTS_FILE}" 2>/dev/null || true
        sed -i "/^${mac}	/d" "${HOSTS_FILE}" 2>/dev/null || true
        echo "${mac} ${target_oid}" >> "${HOSTS_FILE}"
        ((added++))
    done
    info "Batch added ${added} MAC mappings -> ${target_oid} (${target_oname})"
}

apply_config() {
    echo ""
    info "Regenerating PXE boot configuration..."

    # Read all registered OSes
    local OS_IDS=()
    local OS_NAMES=()
    while IFS='|' read -r oid oname odisk opwd; do
        [[ -z "$oid" || "$oid" == \#* ]] && continue
        OS_IDS+=("$oid")
        OS_NAMES+=("$oname")
    done < "${REGISTRY_FILE}"

    if [[ ${#OS_IDS[@]} -eq 0 ]]; then
        warn "No registered OSes, run mount_disc.sh first"
        return
    fi

    # First registered OS is the default
    local DEFAULT_ID="${OS_IDS[0]}"

    # --- BIOS default menu ---
    mkdir -p "${TFTP_ROOT}/pxelinux.cfg"
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
            echo "LABEL ${oid}_ks"
            echo "  MENU LABEL ^${idx}. Install ${oname} (Kickstart Auto)"
            [[ "$oid" == "$DEFAULT_ID" ]] && echo "  MENU DEFAULT"
            echo "  KERNEL ${oid}/vmlinuz"
            echo "  APPEND initrd=${oid}/initrd.img inst.repo=http://${SERVER_IP}/${oid} inst.ks=http://${SERVER_IP}/ks-${oid}-bios.cfg ip=dhcp"
            echo ""
            ((idx++))
        done
        echo "LABEL local"
        echo "  MENU LABEL ^${idx}. Boot from local drive"
        echo "  LOCALBOOT 0"
    } > "${TFTP_ROOT}/pxelinux.cfg/default"

    # --- UEFI grub.cfg ---
    {
        echo "set timeout=10"
        echo "set default=0"
        echo ""

        # MAC condition check
        if [[ -s "${HOSTS_FILE}" ]]; then
            local first_mac=1
            while read -r mac oid; do
                [[ -z "$mac" || "$mac" == \#* ]] && continue
                local mac_colon
                mac_colon=$(echo "$mac" | tr '-' ':' | tr '[:upper:]' '[:lower:]')
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
            echo "menuentry 'Install ${oname} (Kickstart Auto)' {"
            echo "  linuxefi ${oid}/vmlinuz inst.repo=http://${SERVER_IP}/${oid} inst.ks=http://${SERVER_IP}/ks-${oid}-uefi.cfg ip=dhcp"
            echo "  initrdefi ${oid}/initrd.img"
            echo "}"
            echo ""
        done

        echo "menuentry 'Boot from local drive' {"
        echo "  exit"
        echo "}"
    } > "${TFTP_ROOT}/grub.cfg"

    # --- Per-MAC BIOS config files ---
    find "${TFTP_ROOT}/pxelinux.cfg/" -name "01-*" -delete 2>/dev/null || true

    if [[ -s "${HOSTS_FILE}" ]]; then
        while read -r mac oid; do
            [[ -z "$mac" || "$mac" == \#* ]] && continue
            local mac_dash
            mac_dash=$(echo "$mac" | tr ':' '-' | tr '[:upper:]' '[:lower:]')
            local mac_file="${TFTP_ROOT}/pxelinux.cfg/01-${mac_dash}"
            local oname="$oid"
            for j in "${!OS_IDS[@]}"; do
                [[ "${OS_IDS[$j]}" == "$oid" ]] && { oname="${OS_NAMES[$j]}"; break; }
            done
            {
                echo "DEFAULT ${oid}_ks"
                echo "PROMPT 0"
                echo "TIMEOUT 30"
                echo ""
                echo "LABEL ${oid}_ks"
                echo "  MENU LABEL Install ${oname} (Kickstart Auto)"
                echo "  KERNEL ${oid}/vmlinuz"
                echo "  APPEND initrd=${oid}/initrd.img inst.repo=http://${SERVER_IP}/${oid} inst.ks=http://${SERVER_IP}/ks-${oid}-bios.cfg ip=dhcp"
            } > "${mac_file}"
            info "  Generated: 01-${mac_dash} -> ${oid}"
        done < "${HOSTS_FILE}"
    fi

    # Restart services
    systemctl restart dnsmasq 2>/dev/null || true
    systemctl restart nginx 2>/dev/null || true

    echo ""
    info "PXE config updated and services restarted"

    # Summary
    echo ""
    echo "  BIOS menu:    ${TFTP_ROOT}/pxelinux.cfg/default"
    echo "  UEFI menu:    ${TFTP_ROOT}/grub.cfg"
    local mac_count
    mac_count=$(find "${TFTP_ROOT}/pxelinux.cfg/" -name "01-*" 2>/dev/null | wc -l)
    echo "  Per-MAC files: ${mac_count}"
    echo ""
}

show_menu() {
    echo ""
    echo "======================================"
    echo "  MAC Address Mapping Management"
    echo "======================================"
    echo ""
    echo "  1) List registered OSes"
    echo "  2) List MAC mappings"
    echo "  3) Add MAC mapping"
    echo "  4) Delete MAC mapping"
    echo "  5) Batch add MAC range"
    echo "  6) Apply config (regenerate PXE)"
    echo "  0) Exit"
    echo ""
}

# CLI subcommand functions
cli_add_host() {
    local mac="$1"
    local target_oid="$2"
    mac=$(echo "$mac" | tr '[:upper:]' '[:lower:]' | tr '-' ':')
    if ! echo "$mac" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; then
        error "Invalid MAC format: ${mac}"
    fi
    if ! grep -q "^${target_oid}|" "${REGISTRY_FILE}" 2>/dev/null; then
        error "OS ID not found: ${target_oid}"
    fi
    sed -i "/^${mac} /d" "${HOSTS_FILE}" 2>/dev/null || true
    sed -i "/^${mac}	/d" "${HOSTS_FILE}" 2>/dev/null || true
    echo "${mac} ${target_oid}" >> "${HOSTS_FILE}"
    info "Added: ${mac} -> ${target_oid}"
}

cli_del_host() {
    local mac="$1"
    mac=$(echo "$mac" | tr '[:upper:]' '[:lower:]' | tr '-' ':')
    sed -i "/^${mac} /d" "${HOSTS_FILE}" 2>/dev/null || true
    sed -i "/^${mac}	/d" "${HOSTS_FILE}" 2>/dev/null || true
    info "Deleted: ${mac}"
}

cli_batch_add_host() {
    local start_mac="$1"
    local end_mac="$2"
    local target_oid="$3"

    start_mac=$(echo "$start_mac" | tr '[:upper:]' '[:lower:]' | tr '-' ':')
    end_mac=$(echo "$end_mac" | tr '[:upper:]' '[:lower:]' | tr '-' ':')

    if ! echo "$start_mac" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; then
        error "Invalid start MAC format: ${start_mac}"
    fi
    if ! echo "$end_mac" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; then
        error "Invalid end MAC format: ${end_mac}"
    fi
    if ! grep -q "^${target_oid}|" "${REGISTRY_FILE}" 2>/dev/null; then
        error "OS ID not found: ${target_oid}"
    fi

    local start_int end_int
    start_int=$(( 16#${start_mac//:/} ))
    end_int=$(( 16#${end_mac//:/} ))

    if [[ $start_int -gt $end_int ]]; then
        error "Starting MAC must be <= ending MAC"
    fi

    local count=$(( end_int - start_int + 1 ))
    if [[ $count -gt 1000 ]]; then
        error "Range too large (${count} MACs, max 1000)"
    fi

    local added=0
    for (( i = start_int; i <= end_int; i++ )); do
        local mac
        mac=$(printf "%02x:%02x:%02x:%02x:%02x:%02x" \
            $(( (i >> 40) & 0xff )) \
            $(( (i >> 32) & 0xff )) \
            $(( (i >> 24) & 0xff )) \
            $(( (i >> 16) & 0xff )) \
            $(( (i >> 8) & 0xff )) \
            $(( i & 0xff )))
        sed -i "/^${mac} /d" "${HOSTS_FILE}" 2>/dev/null || true
        sed -i "/^${mac}	/d" "${HOSTS_FILE}" 2>/dev/null || true
        echo "${mac} ${target_oid}" >> "${HOSTS_FILE}"
        ((added++))
    done
    info "Batch added ${added} MAC mappings -> ${target_oid}"
}

# CLI subcommand dispatch
if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: sudo $(basename "$0") [command]"
            echo ""
            echo "Manage MAC address to OS mappings for PXE boot."
            echo ""
            echo "Commands:"
            echo "  list-os                                  List registered OSes"
            echo "  list                                     List MAC mappings"
            echo "  add <mac> <os_id>                        Add single MAC mapping"
            echo "  del <mac>                                Delete MAC mapping"
            echo "  batch-add <start_mac> <end_mac> <os_id>  Batch add MAC range"
            echo "  apply                                    Regenerate PXE config"
            echo "  --help                                   Show this help"
            echo ""
            echo "Without arguments, starts interactive menu."
            exit 0
            ;;
        list-os) list_os ;;
        list)    list_hosts ;;
        add)
            [[ -z "$2" || -z "$3" ]] && error "Usage: manage_hosts.sh add <mac> <os_id>"
            cli_add_host "$2" "$3"
            ;;
        del)
            [[ -z "$2" ]] && error "Usage: manage_hosts.sh del <mac>"
            cli_del_host "$2"
            ;;
        batch-add)
            [[ -z "$2" || -z "$3" || -z "$4" ]] && error "Usage: manage_hosts.sh batch-add <start_mac> <end_mac> <os_id>"
            cli_batch_add_host "$2" "$3" "$4"
            ;;
        apply) apply_config ;;
        *)     error "Unknown subcommand: $1\nUsage: manage_hosts.sh [list-os|list|add|del|batch-add|apply]" ;;
    esac
    exit 0
fi

# Main loop
while true; do
    show_menu
    read -p "  Select [0-6]: " choice
    case "$choice" in
        1) list_os ;;
        2) list_hosts ;;
        3) add_host ;;
        4) del_host ;;
        5) batch_add_host ;;
        6) apply_config ;;
        0) echo ""; info "Goodbye!"; exit 0 ;;
        *) warn "Invalid selection" ;;
    esac
done
HOSTSEOF

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
