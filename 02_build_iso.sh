#!/bin/bash
#============================================================================
# 02_build_iso.sh
#
# 基于 Ubuntu 24.04 Server ISO 重新打包，实现：
#   1. 全自动安装 Ubuntu（autoinstall），无人值守
#   2. 安装完成后登录，手动执行交互式 PXE 部署脚本
#   3. 插入操作系统光盘，执行挂载脚本即可开始 PXE 装机
#
# 不嵌入任何操作系统 ISO，ISO 体积约 2.8G
#
# 用法：sudo ./02_build_iso.sh
#============================================================================

set -e

#============================================================================
# ★★★ 参数 ★★★
#============================================================================

UBUNTU_ISO="/root/ubuntu-24.04.2-live-server-amd64.iso"
OUTPUT_ISO="/root/pxe_toolkit.iso"
WORK_DIR="/tmp/iso_build"

# 工具机自动安装参数
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

info "========== Ubuntu 24.04 PXE Toolkit ISO 构建 =========="

[[ $EUID -ne 0 ]] && error "请使用 root 运行"
[[ ! -f "${UBUNTU_ISO}" ]] && error "未找到: ${UBUNTU_ISO}"
[[ ! -d "${OFFLINE_DEBS}" ]] && error "未找到: ${OFFLINE_DEBS}/\n请先运行 01_download_offline.sh"

apt-get update -qq
apt-get install -y -qq xorriso p7zip-full

#============================================================================
# 1. 解包 Ubuntu ISO
#============================================================================
info "[1/5] 解包 Ubuntu Server ISO"

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

info "解包完成"

#============================================================================
# 2. 创建 autoinstall 配置
#============================================================================
info "[2/5] 创建 autoinstall 配置"

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
    - chmod +x /target/opt/pxe_toolkit/*.sh
    - curtin in-target -- dpkg -i --force-depends /opt/pxe_toolkit/debs/*.deb || true
    - curtin in-target -- dpkg --configure -a || true
    - |
      cat > /target/etc/profile.d/pxe-welcome.sh << 'WELEOF'
      if [ "\$(id -u)" = "0" ] || [ -n "\$SUDO_USER" ]; then
        echo ""
        echo "======================================"
        echo "  PXE Toolkit 工具机"
        echo ""
        echo "  1. 部署 PXE 服务:"
        echo "     sudo /opt/pxe_toolkit/setup_pxe.sh"
        echo ""
        echo "  2. 插入系统光盘后:"
        echo "     sudo /opt/pxe_toolkit/mount_disc.sh"
        echo "======================================"
        echo ""
      fi
      WELEOF
USERDATA

cat > "${WORK_DIR}/iso_new/autoinstall/meta-data" << 'EOF'
EOF

info "autoinstall 配置完成"

#============================================================================
# 3. 嵌入 payload
#============================================================================
info "[3/5] 嵌入 payload"

PAYLOAD_DIR="${WORK_DIR}/iso_new/pxe_payload"
mkdir -p "${PAYLOAD_DIR}/offline_debs"

cp "${OFFLINE_DEBS}"/*.deb "${PAYLOAD_DIR}/offline_debs/"
info "已复制 $(ls -1 "${PAYLOAD_DIR}/offline_debs/"*.deb | wc -l) 个 deb 包"

# ===== setup_pxe.sh =====
cat > "${PAYLOAD_DIR}/setup_pxe.sh" << 'SETUPEOF'
#!/bin/bash
#============================================================================
# PXE 服务交互式部署
# 用法: sudo /opt/pxe_toolkit/setup_pxe.sh
#============================================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

CONFIG_FILE="/opt/pxe_toolkit/pxe.conf"

[[ $EUID -ne 0 ]] && error "请使用 root 运行"

info "========== PXE 服务部署 =========="
echo ""

#--- 1. 选择网卡 ---
info "检测到以下网卡:"
echo ""
IFACES=()
i=1
while read -r iface; do
    [[ "$iface" == "lo" ]] && continue
    ADDR=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[0-9.]+' || echo "无 IP")
    STATE=$(cat /sys/class/net/"$iface"/operstate 2>/dev/null || echo "unknown")
    MAC=$(cat /sys/class/net/"$iface"/address 2>/dev/null || echo "")
    echo "  ${i}) ${iface}  [${STATE}]  MAC: ${MAC}  IP: ${ADDR}"
    IFACES+=("$iface")
    ((i++))
done < <(ls /sys/class/net/)
echo ""

if [[ ${#IFACES[@]} -eq 0 ]]; then
    error "未检测到任何网卡"
elif [[ ${#IFACES[@]} -eq 1 ]]; then
    SERVER_IFACE="${IFACES[0]}"
    info "只有一个网卡，自动选择: ${SERVER_IFACE}"
else
    read -p "  请选择网卡 [1-${#IFACES[@]}] (默认 1): " choice
    choice=${choice:-1}
    SERVER_IFACE="${IFACES[$((choice-1))]}"
fi
info "使用网卡: ${SERVER_IFACE}"

#--- 2. 网络参数 ---
echo ""
info "网络参数（直接回车使用默认值）:"
echo ""

read -p "  PXE 服务器 IP [172.16.0.1]: " SERVER_IP
SERVER_IP=${SERVER_IP:-172.16.0.1}

read -p "  DHCP 起始地址 [172.16.0.100]: " DHCP_RANGE_START
DHCP_RANGE_START=${DHCP_RANGE_START:-172.16.0.100}

read -p "  DHCP 结束地址 [172.16.0.200]: " DHCP_RANGE_END
DHCP_RANGE_END=${DHCP_RANGE_END:-172.16.0.200}

read -p "  子网掩码 [255.255.255.0]: " DHCP_NETMASK
DHCP_NETMASK=${DHCP_NETMASK:-255.255.255.0}

read -p "  网关 [${SERVER_IP}]: " DHCP_GATEWAY
DHCP_GATEWAY=${DHCP_GATEWAY:-${SERVER_IP}}

echo ""
info "配置确认:"
echo "  网卡:       ${SERVER_IFACE}"
echo "  服务器 IP:  ${SERVER_IP}"
echo "  DHCP 范围:  ${DHCP_RANGE_START} - ${DHCP_RANGE_END}"
echo "  子网掩码:   ${DHCP_NETMASK}"
echo "  网关:       ${DHCP_GATEWAY}"
echo ""
read -p "  确认？[Y/n]: " confirm
[[ "$confirm" == "n" || "$confirm" == "N" ]] && { echo "已取消"; exit 0; }

# 保存配置
cat > "${CONFIG_FILE}" << CONFEOF
SERVER_IP="${SERVER_IP}"
SERVER_IFACE="${SERVER_IFACE}"
DHCP_RANGE_START="${DHCP_RANGE_START}"
DHCP_RANGE_END="${DHCP_RANGE_END}"
DHCP_NETMASK="${DHCP_NETMASK}"
DHCP_GATEWAY="${DHCP_GATEWAY}"
CONFEOF

TFTP_ROOT="/var/lib/tftpboot"
HTTP_ROOT="/var/www/pxe"

#--- 3. 配置网卡 ---
info "配置网卡..."
ip addr flush dev "${SERVER_IFACE}" 2>/dev/null || true
ip addr add "${SERVER_IP}/24" dev "${SERVER_IFACE}" 2>/dev/null || true
ip link set "${SERVER_IFACE}" up

mkdir -p /etc/netplan
cat > /etc/netplan/99-pxe-static.yaml << NPEOF
network:
  version: 2
  ethernets:
    ${SERVER_IFACE}:
      addresses:
        - ${SERVER_IP}/24
NPEOF
netplan apply 2>/dev/null || true

#--- 4. 安装离线 deb（如果还没装过）---
if ! command -v dnsmasq &>/dev/null || ! command -v nginx &>/dev/null; then
    info "安装离线软件包..."
    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true
    rm -f /etc/resolv.conf
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    dpkg -i --force-depends /opt/pxe_toolkit/debs/*.deb 2>/dev/null || true
    dpkg --configure -a 2>/dev/null || true
else
    info "软件包已安装，跳过"
fi

systemctl stop dnsmasq 2>/dev/null || true
systemctl stop nginx 2>/dev/null || true

#--- 5. 目录 + BIOS 引导 ---
info "配置 TFTP..."
mkdir -p "${TFTP_ROOT}/pxelinux.cfg"
mkdir -p "${TFTP_ROOT}/rhel78"
mkdir -p "${HTTP_ROOT}"

for f in pxelinux.0 menu.c32 ldlinux.c32 libutil.c32 libcom32.c32; do
    for dir in /usr/lib/PXELINUX /usr/lib/syslinux/modules/bios /usr/share/syslinux; do
        [[ -f "${dir}/${f}" ]] && cp "${dir}/${f}" "${TFTP_ROOT}/" && break
    done
done

#--- 6. dnsmasq ---
info "配置 dnsmasq..."
cat > /etc/dnsmasq.conf << DNSEOF
interface=${SERVER_IFACE}
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
info "配置 nginx..."
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
mkdir -p /etc/nginx/conf.d

cat > /etc/nginx/conf.d/pxe.conf << NGXEOF
server {
    listen 80;
    server_name ${SERVER_IP};

    location /rhel7.8 {
        alias ${HTTP_ROOT}/rhel7.8;
        autoindex on;
        autoindex_exact_size off;
        autoindex_localtime on;
    }

    location / {
        root ${HTTP_ROOT};
        autoindex on;
    }
}
NGXEOF

#--- 8. 启动服务 ---
info "启动服务..."
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
info "  PXE 基础服务已就绪！"
info "=========================================="
echo ""
echo "  接下来:"
echo "    1. 插入操作系统光盘"
echo "    2. 执行: sudo /opt/pxe_toolkit/mount_disc.sh"
echo ""
SETUPEOF

# ===== mount_disc.sh =====
cat > "${PAYLOAD_DIR}/mount_disc.sh" << 'MOUNTEOF'
#!/bin/bash
#============================================================================
# mount_disc.sh - 挂载操作系统光盘并配置 PXE 引导 + Kickstart
#============================================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

CONFIG_FILE="/opt/pxe_toolkit/pxe.conf"

[[ $EUID -ne 0 ]] && error "请使用 root 运行"

if [[ -f "${CONFIG_FILE}" ]]; then
    source "${CONFIG_FILE}"
    info "已读取配置: ${SERVER_IP} (${SERVER_IFACE})"
else
    error "未找到 ${CONFIG_FILE}，请先运行 setup_pxe.sh"
fi

HTTP_ROOT="/var/www/pxe"
RHEL_DIR="${HTTP_ROOT}/rhel7.8"
TFTP_ROOT="/var/lib/tftpboot"

info "========== 挂载操作系统光盘 =========="

#--- 1. 检测光驱 ---
echo ""
info "检测光驱:"
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
    error "未检测到光盘，请确认已插入"
elif [[ ${#CDROM_DEVS[@]} -eq 1 ]]; then
    CDROM_DEV="${CDROM_DEVS[0]}"
    info "自动选择: ${CDROM_DEV}"
else
    echo ""
    read -p "  请选择光驱 [1-${#CDROM_DEVS[@]}] (默认 1): " choice
    choice=${choice:-1}
    CDROM_DEV="${CDROM_DEVS[$((choice-1))]}"
fi

DISC_LABEL=$(blkid -s LABEL -o value "$CDROM_DEV" 2>/dev/null || echo "unknown")
info "使用: ${CDROM_DEV} (${DISC_LABEL})"

#--- 2. 安装参数 ---
echo ""
info "目标服务器参数（直接回车使用默认值）:"
echo ""

read -p "  目标磁盘 [sda]: " RHEL_TARGET_DISK
RHEL_TARGET_DISK=${RHEL_TARGET_DISK:-sda}

read -p "  Root 密码 [P@ssw0rd123]: " RHEL_ROOT_PASSWORD
RHEL_ROOT_PASSWORD=${RHEL_ROOT_PASSWORD:-P@ssw0rd123}

echo ""
info "确认:"
echo "  光盘:       ${CDROM_DEV} (${DISC_LABEL})"
echo "  PXE 服务器: ${SERVER_IP}"
echo "  目标磁盘:   ${RHEL_TARGET_DISK}"
echo "  Root 密码:  ${RHEL_ROOT_PASSWORD}"
echo ""
read -p "  确认？[Y/n]: " confirm
[[ "$confirm" == "n" || "$confirm" == "N" ]] && { echo "已取消"; exit 0; }

#--- 3. 挂载 ---
mkdir -p "${RHEL_DIR}"
mountpoint -q "${RHEL_DIR}" && umount "${RHEL_DIR}"

mount -o ro "${CDROM_DEV}" "${RHEL_DIR}"
info "已挂载到 ${RHEL_DIR}"

grep -q "${RHEL_DIR}" /etc/fstab || \
    echo "${CDROM_DEV}  ${RHEL_DIR}  iso9660  ro  0 0" >> /etc/fstab

[[ ! -d "${RHEL_DIR}/repodata" ]] && error "光盘异常，未找到 repodata"
info "光盘验证通过"

#--- 4. 内核 + UEFI 引导 ---
mkdir -p "${TFTP_ROOT}/pxelinux.cfg"
mkdir -p "${TFTP_ROOT}/rhel78"

cp "${RHEL_DIR}/images/pxeboot/vmlinuz"    "${TFTP_ROOT}/rhel78/"
cp "${RHEL_DIR}/images/pxeboot/initrd.img" "${TFTP_ROOT}/rhel78/"
info "内核已复制"

# 复制 UEFI 引导文件（shim + GRUB，支持 Secure Boot）
# 启动链: UEFI 固件 → shimx64.efi (微软签名) → grubx64.efi (Red Hat 签名) → 内核
UEFI_OK=0
# 复制 shim（Secure Boot 必需，微软 UEFI CA 签名）
if [[ -f "${RHEL_DIR}/EFI/BOOT/shimx64.efi" ]]; then
    cp "${RHEL_DIR}/EFI/BOOT/shimx64.efi" "${TFTP_ROOT}/shimx64.efi"
    info "UEFI shimx64.efi 已复制"
    UEFI_OK=1
elif [[ -f "${RHEL_DIR}/EFI/BOOT/BOOTX64.EFI" ]]; then
    cp "${RHEL_DIR}/EFI/BOOT/BOOTX64.EFI" "${TFTP_ROOT}/shimx64.efi"
    info "UEFI BOOTX64.EFI → shimx64.efi 已复制"
    UEFI_OK=1
else
    warn "未找到 shim 引导文件（Secure Boot 将不可用）"
fi
# 复制 GRUB EFI（shim 会链式加载此文件）
if [[ -f "${RHEL_DIR}/EFI/BOOT/grubx64.efi" ]]; then
    cp "${RHEL_DIR}/EFI/BOOT/grubx64.efi" "${TFTP_ROOT}/grubx64.efi"
    info "UEFI grubx64.efi 已复制"
    UEFI_OK=1
else
    warn "未找到 grubx64.efi"
fi
[[ ${UEFI_OK} -eq 0 ]] && warn "未找到任何 UEFI 引导文件"

#--- 5. BIOS PXE 菜单 ---
cat > "${TFTP_ROOT}/pxelinux.cfg/default" << BIOSEOF
DEFAULT menu.c32
PROMPT 0
TIMEOUT 100
MENU TITLE ====== PXE Install Menu (BIOS) ======

LABEL rhel78_ks
  MENU LABEL ^1. Install RHEL 7.8 (Kickstart Auto)
  MENU DEFAULT
  KERNEL rhel78/vmlinuz
  APPEND initrd=rhel78/initrd.img inst.repo=http://${SERVER_IP}/rhel7.8 inst.ks=http://${SERVER_IP}/ks-bios.cfg ip=dhcp

LABEL rhel78_manual
  MENU LABEL ^2. Install RHEL 7.8 (Manual)
  KERNEL rhel78/vmlinuz
  APPEND initrd=rhel78/initrd.img inst.repo=http://${SERVER_IP}/rhel7.8 ip=dhcp

LABEL local
  MENU LABEL ^3. Boot from local drive
  LOCALBOOT 0
BIOSEOF

#--- 6. UEFI GRUB 菜单 ---
cat > "${TFTP_ROOT}/grub.cfg" << UEFIEOF
set timeout=10
set default=0

menuentry 'Install RHEL 7.8 (Kickstart Auto)' {
  linuxefi rhel78/vmlinuz inst.repo=http://${SERVER_IP}/rhel7.8 inst.ks=http://${SERVER_IP}/ks-uefi.cfg ip=dhcp
  initrdefi rhel78/initrd.img
}

menuentry 'Install RHEL 7.8 (Manual)' {
  linuxefi rhel78/vmlinuz inst.repo=http://${SERVER_IP}/rhel7.8 ip=dhcp
  initrdefi rhel78/initrd.img
}

menuentry 'Boot from local drive' {
  exit
}
UEFIEOF

#--- 7. Kickstart (BIOS + UEFI) ---
generate_ks() {
    local KS_FILE="$1"
    local BOOT_MODE="$2"

    cat > "${KS_FILE}" << KSEOF
#version=DEVEL
install
graphical
lang en_US.UTF-8
keyboard us
timezone Asia/Shanghai --isUtc

network --bootproto=dhcp --onboot=yes --activate

rootpw --plaintext ${RHEL_ROOT_PASSWORD}

url --url=http://${SERVER_IP}/rhel7.8

firewall --disabled
selinux --disabled
services --disabled=firewalld

%addon com_redhat_kdump --disable
%end

ignoredisk --only-use=${RHEL_TARGET_DISK}
clearpart --all --initlabel --drives=${RHEL_TARGET_DISK}
KSEOF

    if [[ "$BOOT_MODE" == "uefi" ]]; then
        cat >> "${KS_FILE}" << KSEOF
bootloader --location=mbr --boot-drive=${RHEL_TARGET_DISK} --append="crashkernel=auto"
part /boot     --fstype=xfs  --size=500    --ondisk=${RHEL_TARGET_DISK}
part /boot/efi --fstype=efi  --size=500    --ondisk=${RHEL_TARGET_DISK}
part swap      --size=65536               --ondisk=${RHEL_TARGET_DISK}
part /         --fstype=xfs  --size=1     --grow --ondisk=${RHEL_TARGET_DISK}
KSEOF
    else
        cat >> "${KS_FILE}" << KSEOF
bootloader --location=mbr --boot-drive=${RHEL_TARGET_DISK}
part /boot     --fstype=xfs  --size=500    --ondisk=${RHEL_TARGET_DISK}
part swap      --size=65536               --ondisk=${RHEL_TARGET_DISK}
part /         --fstype=xfs  --size=1     --grow --ondisk=${RHEL_TARGET_DISK}
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

generate_ks "${HTTP_ROOT}/ks-bios.cfg" "bios"
generate_ks "${HTTP_ROOT}/ks-uefi.cfg" "uefi"
cp "${HTTP_ROOT}/ks-uefi.cfg" "${HTTP_ROOT}/ks.cfg"
info "Kickstart 已生成"

#--- 8. 重启服务 ---
systemctl restart dnsmasq
systemctl restart nginx

#--- 9. 验证 ---
echo ""
info "========== 验证 =========="
echo -n "  dnsmasq: "; systemctl is-active dnsmasq
echo -n "  nginx:   "; systemctl is-active nginx

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${SERVER_IP}/rhel7.8/repodata/repomd.xml" 2>/dev/null || echo "000")
[[ "$HTTP_CODE" == "200" ]] && info "✓ 安装源" || warn "✗ 安装源 (${HTTP_CODE})"

HTTP_CODE2=$(curl -s -o /dev/null -w "%{http_code}" "http://${SERVER_IP}/ks-bios.cfg" 2>/dev/null || echo "000")
[[ "$HTTP_CODE2" == "200" ]] && info "✓ ks-bios.cfg" || warn "✗ ks-bios.cfg"

HTTP_CODE3=$(curl -s -o /dev/null -w "%{http_code}" "http://${SERVER_IP}/ks-uefi.cfg" 2>/dev/null || echo "000")
[[ "$HTTP_CODE3" == "200" ]] && info "✓ ks-uefi.cfg" || warn "✗ ks-uefi.cfg"

echo ""
[[ -f "${TFTP_ROOT}/pxelinux.0" ]]       && info "✓ BIOS:  pxelinux.0"  || warn "✗ BIOS:  pxelinux.0"
[[ -f "${TFTP_ROOT}/shimx64.efi" ]]     && info "✓ UEFI:  shimx64.efi (Secure Boot)" || warn "✗ UEFI:  shimx64.efi"
[[ -f "${TFTP_ROOT}/grubx64.efi" ]]      && info "✓ UEFI:  grubx64.efi" || warn "✗ UEFI:  grubx64.efi"
[[ -f "${TFTP_ROOT}/rhel78/vmlinuz" ]]    && info "✓ vmlinuz"            || warn "✗ vmlinuz"
[[ -f "${TFTP_ROOT}/rhel78/initrd.img" ]] && info "✓ initrd.img"        || warn "✗ initrd.img"

echo ""
info "=========================================="
info "  PXE 安装服务就绪！"
info "=========================================="
echo ""
echo "  HTTP:  http://${SERVER_IP}/rhel7.8"
echo "  KS:    http://${SERVER_IP}/ks-bios.cfg (BIOS)"
echo "         http://${SERVER_IP}/ks-uefi.cfg (UEFI)"
echo "  日志:  tail -f /var/log/dnsmasq.log"
echo ""
echo "  目标服务器 PXE 启动即可安装！"
echo "  更换光盘后重新执行本脚本即可。"
echo ""
MOUNTEOF

chmod +x "${PAYLOAD_DIR}"/*.sh
info "payload 嵌入完成"

#============================================================================
# 4. 修改 GRUB 引导，注入 autoinstall
#============================================================================
info "[4/5] 修改 GRUB 引导配置"

GRUB_CFG="${WORK_DIR}/iso_new/boot/grub/grub.cfg"

if [[ -f "${GRUB_CFG}" ]]; then
    cp "${GRUB_CFG}" "${GRUB_CFG}.bak"
    sed -i '0,/linux.*\/casper\/vmlinuz/{s|\(linux.*\/casper\/vmlinuz\)\(.*\)|\1 autoinstall ds=nocloud\\;s=/cdrom/autoinstall/\2|}' "${GRUB_CFG}"
    sed -i 's/set timeout=.*/set timeout=5/' "${GRUB_CFG}"
    info "GRUB 已修改"
else
    warn "未找到 grub.cfg"
    find "${WORK_DIR}/iso_new" -name "grub.cfg" -exec echo "  Found: {}" \;
fi

for cfg in "${WORK_DIR}/iso_new/isolinux/txt.cfg" \
           "${WORK_DIR}/iso_new/syslinux/txt.cfg"; do
    [[ -f "$cfg" ]] && sed -i 's|\(append.*initrd\)|\1 autoinstall ds=nocloud;s=/cdrom/autoinstall/|' "$cfg"
done

#============================================================================
# 5. 打包 ISO
#============================================================================
info "[5/5] 打包 ISO"

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

info "xorriso 打包..."

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

[[ ! -f "${OUTPUT_ISO}" ]] && error "ISO 打包失败"

rm -rf "${WORK_DIR}"

ISO_SIZE=$(du -sh "${OUTPUT_ISO}" | awk '{print $1}')
info "=========================================="
info "  PXE Toolkit ISO 构建完成！"
info "=========================================="
echo ""
echo "  输出: ${OUTPUT_ISO} (${ISO_SIZE})"
echo ""
echo "  刻 U 盘:"
echo "    sudo dd if=${OUTPUT_ISO} of=/dev/sdX bs=4M status=progress"
echo ""
echo "  ★ 现场使用流程:"
echo "    1. U 盘启动工具机 → 全自动安装 Ubuntu（约5分钟）"
echo "    2. 重启后登录（${TOOL_USERNAME}/${TOOL_PASSWORD}）"
echo "    3. sudo /opt/pxe_toolkit/setup_pxe.sh"
echo "       → 选网卡、配置 IP（交互式，有默认值）"
echo "    4. 插入操作系统光盘"
echo "    5. sudo /opt/pxe_toolkit/mount_disc.sh"
echo "       → 选光驱、配置目标磁盘和密码（交互式）"
echo "    6. 目标服务器 PXE 启动即可安装"
echo ""
echo "  ★ 更换光盘后重新执行 mount_disc.sh 即可"
echo ""
