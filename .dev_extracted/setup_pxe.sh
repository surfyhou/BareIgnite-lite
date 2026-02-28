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
