#!/bin/bash
#============================================================================
# dev_test.sh — PVE 3-VM End-to-End Test
#
# 3-VM model:
#   VM 745 (builder)    — Persistent Ubuntu 24.04, builds ISO
#   VM 746 (PXE server) — Installed from toolkit ISO, becomes PXE server
#   VM 747 (target)     — PXE boot test target
#
# Constraints:
#   - Does NOT auto-execute embedded scripts; user SSHs into VM 746 manually
#   - All PVE qm commands require user confirmation before execution
#
# Usage: ./dev_test.sh <command>
#
# Commands:
#   build           Build ISO (VM 745) and copy to PVE storage
#   create-pxe      Create VM 746 (PXE server)
#   create-target   Create VM 747 (PXE boot target)
#   start-pxe       Start VM 746
#   start-target    Start VM 747
#   stop-pxe        Stop VM 746
#   stop-target     Stop VM 747
#   destroy-pxe     Destroy VM 746
#   destroy-target  Destroy VM 747
#   swap-iso        VM 746: swap CD-ROM to RHEL ISO + disk-first boot
#   extract         Extract scripts from 02_build_iso.sh to .dev_extracted/
#   deploy          SCP extracted scripts to VM 746
#   ssh-builder     SSH to VM 745
#   ssh-pxe         SSH to VM 746
#   status          Show VM 746/747 status
#============================================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "${CYAN}[STEP]${NC}  $*"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_SCRIPT="${SCRIPT_DIR}/02_build_iso.sh"
EXTRACT_DIR="${SCRIPT_DIR}/.dev_extracted"

#============================================================================
# *** Configuration — modify for your environment ***
#============================================================================

PVE_HOST="root@10.0.1.12"
BUILDER_HOST="root@10.0.1.183"        # VM 745
PXE_VM_ID="746"
PXE_VM_IP="10.0.1.249"                 # VM 746 management IP
PXE_VM_USER="pxe"                      # User created by autoinstall
TARGET_VM_ID="747"
PVE_BRIDGE_MGMT="vmbr0"
PVE_BRIDGE_PXE="vmbr1"
TOOLKIT_ISO="local:iso/pxe_toolkit.iso"
RHEL_ISO="local:iso/rhel-server-7.8-x86_64-dvd.iso"
PVE_STORAGE="local-lvm"

#============================================================================
# PVE command approval gate
#============================================================================

pve_exec() {
    echo -e "${YELLOW}[PVE CMD]${NC} $*"
    read -p "  Execute on PVE host? [y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { warn "Skipped"; return 1; }
    ssh -n "${PVE_HOST}" "$@"
}

#============================================================================
# build — Build ISO (VM 745) and copy to PVE storage
#============================================================================
cmd_build() {
    step "=== Build ISO ==="

    [[ ! -f "${BUILD_SCRIPT}" ]] && error "Not found: ${BUILD_SCRIPT}"

    step "[1/3] SCP 02_build_iso.sh to VM 745 (builder)..."
    scp "${BUILD_SCRIPT}" "${BUILDER_HOST}:/root/"
    info "Upload complete"

    step "[2/3] Building ISO on VM 745..."
    ssh "${BUILDER_HOST}" "cd /root && bash 02_build_iso.sh"
    info "Build complete"

    step "[3/3] Copying ISO to PVE storage..."
    pve_exec "scp ${BUILDER_HOST}:/root/pxe_toolkit.iso /var/lib/vz/template/iso/"
    info "ISO copied to PVE storage"
}

#============================================================================
# create-pxe — Create VM 746 (PXE server)
#============================================================================
cmd_create_pxe() {
    step "Creating PXE server VM (VMID: ${PXE_VM_ID})..."

    pve_exec "qm create ${PXE_VM_ID} \
        --name pxe-server-test \
        --memory 4096 --cores 2 \
        --net0 virtio,bridge=${PVE_BRIDGE_MGMT} \
        --net1 virtio,bridge=${PVE_BRIDGE_PXE} \
        --scsihw virtio-scsi-single \
        --scsi0 ${PVE_STORAGE}:32 \
        --ide2 ${TOOLKIT_ISO},media=cdrom \
        --boot order=ide2\\;scsi0 \
        --ostype l26"

    info "VM ${PXE_VM_ID} created"
}

#============================================================================
# create-target — Create VM 747 (PXE boot target)
#============================================================================
cmd_create_target() {
    step "Creating PXE boot target VM (VMID: ${TARGET_VM_ID})..."

    pve_exec "qm create ${TARGET_VM_ID} \
        --name pxe-test-target \
        --memory 4096 --cores 2 \
        --net0 virtio,bridge=${PVE_BRIDGE_PXE} \
        --scsihw virtio-scsi-single \
        --scsi0 ${PVE_STORAGE}:32 \
        --boot order=net0\\;scsi0 \
        --ostype l26"

    info "VM ${TARGET_VM_ID} created"
}

#============================================================================
# start / stop — VM lifecycle
#============================================================================
cmd_start_pxe() {
    step "Starting VM ${PXE_VM_ID}..."
    pve_exec "qm start ${PXE_VM_ID}"
    info "VM ${PXE_VM_ID} started"
}

cmd_start_target() {
    step "Starting VM ${TARGET_VM_ID}..."
    pve_exec "qm start ${TARGET_VM_ID}"
    info "VM ${TARGET_VM_ID} started"
}

cmd_stop_pxe() {
    step "Stopping VM ${PXE_VM_ID}..."
    pve_exec "qm stop ${PXE_VM_ID}"
    info "VM ${PXE_VM_ID} stopped"
}

cmd_stop_target() {
    step "Stopping VM ${TARGET_VM_ID}..."
    pve_exec "qm stop ${TARGET_VM_ID}"
    info "VM ${TARGET_VM_ID} stopped"
}

#============================================================================
# destroy — Destroy VM
#============================================================================
cmd_destroy_pxe() {
    step "Destroying PXE server VM (VMID: ${PXE_VM_ID})..."
    pve_exec "qm stop ${PXE_VM_ID}" 2>/dev/null || true
    pve_exec "qm destroy ${PXE_VM_ID} --destroy-unreferenced-disks 1 --purge 1"
    info "VM ${PXE_VM_ID} destroyed"
}

cmd_destroy_target() {
    step "Destroying target VM (VMID: ${TARGET_VM_ID})..."
    pve_exec "qm stop ${TARGET_VM_ID}" 2>/dev/null || true
    pve_exec "qm destroy ${TARGET_VM_ID} --destroy-unreferenced-disks 1 --purge 1"
    info "VM ${TARGET_VM_ID} destroyed"
}

#============================================================================
# swap-iso — Swap CD-ROM to RHEL ISO + disk-first boot
#============================================================================
cmd_swap_iso() {
    step "VM ${PXE_VM_ID}: Swapping CD-ROM to RHEL ISO + disk-first boot..."

    pve_exec "qm set ${PXE_VM_ID} --ide2 ${RHEL_ISO},media=cdrom --boot order=scsi0\\;ide2"

    info "CD-ROM swapped to RHEL ISO, boot order: disk first"
}

#============================================================================
# extract — Extract scripts from 02_build_iso.sh
#============================================================================
cmd_extract() {
    step "Extracting embedded scripts from ${BUILD_SCRIPT}..."

    [[ ! -f "${BUILD_SCRIPT}" ]] && error "Not found: ${BUILD_SCRIPT}"

    rm -rf "${EXTRACT_DIR}"
    mkdir -p "${EXTRACT_DIR}"

    # setup_pxe.sh: extract 'SETUPEOF' heredoc
    sed -n "/^cat > .*setup_pxe.sh.*'SETUPEOF'/,/^SETUPEOF$/p" "${BUILD_SCRIPT}" \
        | sed '1d;$d' > "${EXTRACT_DIR}/setup_pxe.sh"

    # mount_disc.sh: extract 'MOUNTEOF' heredoc
    sed -n "/^cat > .*mount_disc.sh.*'MOUNTEOF'/,/^MOUNTEOF$/p" "${BUILD_SCRIPT}" \
        | sed '1d;$d' > "${EXTRACT_DIR}/mount_disc.sh"

    # manage_hosts.sh: extract 'HOSTSEOF' heredoc
    sed -n "/^cat > .*manage_hosts.sh.*'HOSTSEOF'/,/^HOSTSEOF$/p" "${BUILD_SCRIPT}" \
        | sed '1d;$d' > "${EXTRACT_DIR}/manage_hosts.sh"

    chmod +x "${EXTRACT_DIR}"/*.sh

    # Verify
    local ok=1
    for f in setup_pxe.sh mount_disc.sh manage_hosts.sh; do
        if [[ -s "${EXTRACT_DIR}/${f}" ]]; then
            local lines
            lines=$(wc -l < "${EXTRACT_DIR}/${f}")
            info "  ${f} (${lines} lines)"
        else
            warn "  ${f} extraction failed or empty!"
            ok=0
        fi
    done

    [[ ${ok} -eq 1 ]] && info "Extraction complete: ${EXTRACT_DIR}/" || error "Some scripts failed to extract"
}

#============================================================================
# deploy — SCP extracted scripts to VM 746
#============================================================================
cmd_deploy() {
    [[ -z "${PXE_VM_IP}" ]] && error "Set PXE_VM_IP first (VM 746 DHCP address)"
    [[ ! -d "${EXTRACT_DIR}" ]] && error "Run first: $0 extract"

    step "Deploying scripts to VM ${PXE_VM_ID} (${PXE_VM_USER}@${PXE_VM_IP})..."

    for f in setup_pxe.sh mount_disc.sh manage_hosts.sh; do
        [[ ! -f "${EXTRACT_DIR}/${f}" ]] && error "Missing: ${EXTRACT_DIR}/${f}"
    done

    scp "${EXTRACT_DIR}/setup_pxe.sh" \
        "${EXTRACT_DIR}/mount_disc.sh" \
        "${EXTRACT_DIR}/manage_hosts.sh" \
        "${PXE_VM_USER}@${PXE_VM_IP}:/opt/pxe_toolkit/"

    ssh "${PXE_VM_USER}@${PXE_VM_IP}" "chmod +x /opt/pxe_toolkit/*.sh"

    info "Deploy complete"
    ssh "${PXE_VM_USER}@${PXE_VM_IP}" "ls -la /opt/pxe_toolkit/*.sh"
}

#============================================================================
# ssh-builder / ssh-pxe — SSH shortcuts
#============================================================================
cmd_ssh_builder() {
    info "SSH to VM 745 (builder: ${BUILDER_HOST})..."
    ssh "${BUILDER_HOST}"
}

cmd_ssh_pxe() {
    [[ -z "${PXE_VM_IP}" ]] && error "Set PXE_VM_IP first (VM 746 DHCP address)"
    info "SSH to VM ${PXE_VM_ID} (${PXE_VM_USER}@${PXE_VM_IP})..."
    ssh "${PXE_VM_USER}@${PXE_VM_IP}"
}

#============================================================================
# status — Show VM status
#============================================================================
cmd_status() {
    step "Querying VM status..."
    echo ""

    echo -e "${CYAN}VM ${PXE_VM_ID} (PXE server):${NC}"
    pve_exec "qm status ${PXE_VM_ID}" 2>/dev/null || warn "VM ${PXE_VM_ID} does not exist"
    echo ""

    echo -e "${CYAN}VM ${TARGET_VM_ID} (target):${NC}"
    pve_exec "qm status ${TARGET_VM_ID}" 2>/dev/null || warn "VM ${TARGET_VM_ID} does not exist"
}

#============================================================================
# Usage
#============================================================================
usage() {
    echo ""
    echo "Usage: $0 <command>"
    echo ""
    echo "Build & ISO:"
    echo "  build           Build ISO (VM 745) and copy to PVE storage"
    echo "  swap-iso        VM 746: swap CD-ROM to RHEL ISO + disk-first boot"
    echo ""
    echo "VM Lifecycle:"
    echo "  create-pxe      Create VM 746 (PXE server)"
    echo "  create-target   Create VM 747 (PXE boot target)"
    echo "  start-pxe       Start VM 746"
    echo "  start-target    Start VM 747"
    echo "  stop-pxe        Stop VM 746"
    echo "  stop-target     Stop VM 747"
    echo "  destroy-pxe     Destroy VM 746"
    echo "  destroy-target  Destroy VM 747"
    echo "  status          Show VM 746/747 status"
    echo ""
    echo "Script Iteration:"
    echo "  extract         Extract scripts from 02_build_iso.sh to .dev_extracted/"
    echo "  deploy          SCP extracted scripts to VM 746"
    echo ""
    echo "SSH:"
    echo "  ssh-builder     SSH to VM 745 (builder)"
    echo "  ssh-pxe         SSH to VM 746 (PXE server)"
    echo ""
    echo "Typical workflow:"
    echo "  $0 build && $0 create-pxe && $0 start-pxe"
    echo "  # Wait for install -> swap-iso -> SSH in to test manually"
    echo "  $0 extract && $0 deploy   # Quick script iteration"
    echo ""
}

#============================================================================
# Main
#============================================================================
[[ $# -eq 0 ]] && { usage; exit 1; }

CMD="$1"
shift

case "${CMD}" in
    build)          cmd_build ;;
    create-pxe)     cmd_create_pxe ;;
    create-target)  cmd_create_target ;;
    start-pxe)      cmd_start_pxe ;;
    start-target)   cmd_start_target ;;
    stop-pxe)       cmd_stop_pxe ;;
    stop-target)    cmd_stop_target ;;
    destroy-pxe)    cmd_destroy_pxe ;;
    destroy-target) cmd_destroy_target ;;
    swap-iso)       cmd_swap_iso ;;
    extract)        cmd_extract ;;
    deploy)         cmd_deploy ;;
    ssh-builder)    cmd_ssh_builder ;;
    ssh-pxe)        cmd_ssh_pxe ;;
    status)         cmd_status ;;
    *)              error "Unknown command: ${CMD}"; usage ;;
esac
