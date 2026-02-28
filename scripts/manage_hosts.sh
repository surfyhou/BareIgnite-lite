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
    while IFS='|' read -r oid oname odisk opwd oextra; do
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
        while IFS='|' read -r rid rname rdisk rpwd rextra; do
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
    while IFS='|' read -r oid oname odisk opwd oextra; do
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
        while IFS='|' read -r rid rname rdisk rpwd rextra; do
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
    if [[ $count -gt 65536 ]]; then
        warn "Range too large (${count} MACs, max 65536)"
        return
    fi

    # Select OS
    echo ""
    info "Select target OS for all ${count} MACs:"
    local os_ids=()
    local os_names=()
    local idx=1
    while IFS='|' read -r oid oname odisk opwd oextra; do
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
    local OS_EXTRAS=()
    while IFS='|' read -r oid oname odisk opwd oextra; do
        [[ -z "$oid" || "$oid" == \#* ]] && continue
        OS_IDS+=("$oid")
        OS_NAMES+=("$oname")
        OS_EXTRAS+=("$oextra")
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
    if [[ $count -gt 65536 ]]; then
        error "Range too large (${count} MACs, max 65536)"
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
