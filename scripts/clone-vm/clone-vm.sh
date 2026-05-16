#!/bin/bash
# Clone a VM with new MAC address and get its IP

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Spinner function
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    while kill -0 "$pid" 2>/dev/null; do
        local temp=${spinstr#?}
        printf " [${CYAN}%c${NC}]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# Print header
print_header() {
    echo -e "\n${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}                    ${BOLD}VM CLONING UTILITY${NC}                      ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}\n"
}

# Print step
print_step() {
    echo -e "${CYAN}▶${NC} ${BOLD}$1${NC}"
}

# Print success
print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

# Print error
print_error() {
    echo -e "${RED}✗${NC} $1"
}

# Print info box
print_info_box() {
    echo -e "\n${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}  ${BOLD}VM CLONE SUCCESSFUL!${NC}                                       ${GREEN}║${NC}"
    echo -e "${GREEN}╠════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  VM Name     : ${CYAN}$1${NC}"
    echo -e "${GREEN}║${NC}  IP Address  : ${CYAN}$2${NC}"
    echo -e "${GREEN}║${NC}  MAC Address : ${CYAN}$3${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}\n"
}

if [ $# -lt 1 ]; then
    echo -e "${YELLOW}Usage:${NC} $0 <original-vm-name> [new-vm-name]"
    echo -e "${YELLOW}Example:${NC} $0 ubuntu24.04 ubuntu24.04-clone"
    exit 1
fi

ORIGINAL_VM="$1"
NEW_VM="${2:-${ORIGINAL_VM}-clone}"

# Target storage location
STORAGE_DIR="${VM_STORAGE_DIR:-/var/lib/libvirt/images}"

print_header

echo -e "${BOLD}Source VM:${NC}      $ORIGINAL_VM"
echo -e "${BOLD}Destination VM:${NC} $NEW_VM"
echo -e "${BOLD}Storage Path:${NC}   $STORAGE_DIR\n"

# Create storage directory if it doesn't exist
mkdir -p "$STORAGE_DIR"

# Clone with auto-generated MAC addresses
print_step "Cloning virtual machine (this may take a few minutes)..."

# Specify the target disk location
TARGET_DISK="$STORAGE_DIR/${NEW_VM}.qcow2"

# Start cloning in background and capture output
(virt-clone --original "$ORIGINAL_VM" --name "$NEW_VM" --file "$TARGET_DISK" 2>&1 | tee /tmp/virt-clone-$$.log) &
CLONE_PID=$!

# Show animated progress
spinner_chars="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
i=0
dots=0
while kill -0 $CLONE_PID 2>/dev/null; do
    # Animated spinner
    char=${spinner_chars:i%${#spinner_chars}:1}
    i=$((i+1))

    # Animated dots
    dot_str=$(printf '.%.0s' $(seq 1 $((dots % 4))))
    dots=$((dots+1))

    # Check if we can get any progress info from the log
    if [ -f /tmp/virt-clone-$$.log ]; then
        LAST_LINE=$(tail -1 /tmp/virt-clone-$$.log 2>/dev/null)
        if [[ "$LAST_LINE" == *"Allocating"* ]]; then
            # Extract percentage if available
            if [[ "$LAST_LINE" =~ ([0-9]+)% ]]; then
                PERCENT="${BASH_REMATCH[1]}"
                FILLED=$((PERCENT / 2))
                EMPTY=$((50 - FILLED))
                BAR=$(printf '%*s' $FILLED '' | tr ' ' '█')
                EMPTY_BAR=$(printf '%*s' $EMPTY '' | tr ' ' '░')
                echo -ne "  ${CYAN}[${BAR}${EMPTY_BAR}]${NC} ${PERCENT}% → storage pool\r"
            else
                echo -ne "  ${CYAN}${char}${NC} Copying disk to storage pool${dot_str}$(printf ' %.0s' $(seq 1 $((3 - dots % 4))))\r"
            fi
        else
            echo -ne "  ${CYAN}${char}${NC} Cloning to storage pool${dot_str}$(printf ' %.0s' $(seq 1 $((3 - dots % 4))))\r"
        fi
    else
        echo -ne "  ${CYAN}${char}${NC} Preparing clone${dot_str}$(printf ' %.0s' $(seq 1 $((3 - dots % 4))))\r"
    fi

    sleep 0.15
done

# Clear the line
echo -ne "\r$(printf '%*s' 80 '')\r"

# Wait for clone to finish and check status
wait $CLONE_PID
CLONE_STATUS=$?

# Also check the log for ERROR messages
if [ -f /tmp/virt-clone-$$.log ]; then
    if grep -q "ERROR" /tmp/virt-clone-$$.log; then
        CLONE_STATUS=1
    fi
fi

if [ $CLONE_STATUS -ne 0 ]; then
    print_error "Clone failed\n"

    # Check for common errors and provide solutions
    if grep -q "disk_size" /tmp/virt-clone-$$.log; then
        echo -e "${YELLOW}Issue:${NC} Insufficient disk space\n"
        echo -e "${BOLD}Solutions:${NC}"
        echo -e "  1. Free up disk space in /var/lib/libvirt/images/"
        echo -e "  2. Clone to a different location with more space"
        echo -e "  3. Override the check (WARNING: may cause issues):\n"
        echo -e "     ${CYAN}virt-clone --original $ORIGINAL_VM --name $NEW_VM --auto-clone --check disk_size=off${NC}\n"
    fi

    if [ -f /tmp/virt-clone-$$.log ]; then
        echo -e "${RED}Error details:${NC}"
        cat /tmp/virt-clone-$$.log
    fi

    rm -f /tmp/virt-clone-$$.log
    exit 1
fi

rm -f /tmp/virt-clone-$$.log
print_success "Clone created successfully!\n"

# Start the cloned VM
print_step "Starting virtual machine..."
if virsh start "$NEW_VM" &>/dev/null; then
    print_success "VM started\n"
else
    print_error "Failed to start VM"
    exit 1
fi

# Wait for VM to boot and get IP
print_step "Waiting for network configuration..."
IP_INFO=""
MAC_INFO=""

for i in {1..20}; do
    echo -ne "  ${CYAN}[$(printf '%*s' "$i" '' | tr ' ' '█')$(printf '%*s' $((20-i)) '' | tr ' ' '░')]${NC} ${i}s\r"

    # Try to get IP after 5 seconds
    if [ "$i" -ge 5 ]; then
        IP_INFO=$(virsh domifaddr "$NEW_VM" 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
        MAC_INFO=$(virsh domifaddr "$NEW_VM" 2>/dev/null | grep -oE '([0-9a-f]{2}:){5}[0-9a-f]{2}' | head -1)
        if [ -n "$IP_INFO" ]; then
            echo -ne "\r$(printf '%*s' 80 '')\r"
            print_success "Network ready\n"
            break
        fi
    fi

    sleep 1
done

# One final check if we still don't have IP
if [ -z "$IP_INFO" ]; then
    IP_INFO=$(virsh domifaddr "$NEW_VM" 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
    MAC_INFO=$(virsh domifaddr "$NEW_VM" 2>/dev/null | grep -oE '([0-9a-f]{2}:){5}[0-9a-f]{2}' | head -1)
    if [ -n "$IP_INFO" ]; then
        echo -ne "\r$(printf '%*s' 80 '')\r"
        print_success "Network ready\n"
    fi
fi

echo ""

if [ -n "$IP_INFO" ]; then
    print_info_box "$NEW_VM" "$IP_INFO" "$MAC_INFO"

    echo -e "${YELLOW}⚠  IMPORTANT:${NC} Fix machine identity to avoid conflicts\n"
    echo -e "${BOLD}1.${NC} Copy the fix script to the VM:"
    echo -e "   ${CYAN}scp fix-vm-identity.sh ${VM_USER:-ubuntu}@$IP_INFO:~/${NC}\n"
    echo -e "${BOLD}2.${NC} SSH into the new VM:"
    echo -e "   ${CYAN}ssh ${VM_USER:-ubuntu}@$IP_INFO${NC}\n"
    echo -e "${BOLD}3.${NC} Make it executable and run:"
    echo -e "   ${CYAN}chmod +x fix-vm-identity.sh${NC}"
    echo -e "   ${CYAN}./fix-vm-identity.sh${NC}\n"
    echo -e "${BOLD}Or manually run:${NC}"
    echo -e "   ${CYAN}sudo rm -f /etc/machine-id /var/lib/dbus/machine-id${NC}"
    echo -e "   ${CYAN}sudo systemd-machine-id-setup${NC}"
    echo -e "   ${CYAN}sudo rm -f /var/lib/tailscale/tailscaled.state${NC}"
    echo -e "   ${CYAN}sudo reboot${NC}\n"
    echo -e "${BOLD}Storage Location:${NC}"
    echo -e "   ${CYAN}$TARGET_DISK${NC}\n"
else
    print_error "Could not retrieve IP address automatically\n"
    echo -e "${YELLOW}Manual check:${NC} virsh domifaddr $NEW_VM\n"
fi
