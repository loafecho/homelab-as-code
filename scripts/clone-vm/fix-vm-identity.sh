#!/bin/bash
# Fix cloned VM identity - run this INSIDE the cloned VM

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Print header
print_header() {
    echo -e "\n${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}                ${BOLD}VM IDENTITY FIX UTILITY${NC}                     ${CYAN}║${NC}"
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

# Print warning
print_warning() {
    echo -e "${YELLOW}⚠${NC}  $1"
}

print_header

echo -e "${YELLOW}This script will regenerate the VM's unique identity.${NC}"
echo -e "${YELLOW}Required for cloned VMs to avoid conflicts.${NC}\n"

# Get old machine-id before removal
OLD_MACHINE_ID=""
if [ -f /etc/machine-id ]; then
    OLD_MACHINE_ID=$(cat /etc/machine-id 2>/dev/null)
    echo -e "${BOLD}Current machine-id:${NC} ${CYAN}${OLD_MACHINE_ID}${NC}\n"
fi

# Step 1: Remove old machine IDs
print_step "Removing old machine identity..."
if sudo rm -f /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null; then
    print_success "Old machine IDs removed\n"
else
    print_error "Failed to remove old machine IDs\n"
    exit 1
fi

# Step 2: Generate new machine ID
print_step "Generating new machine identity..."
if sudo systemd-machine-id-setup 2>&1 | grep -q "Initializing"; then
    NEW_MACHINE_ID=$(cat /etc/machine-id 2>/dev/null)
    print_success "New machine-id generated"
    echo -e "  ${CYAN}→${NC} ${NEW_MACHINE_ID}\n"
else
    print_error "Failed to generate new machine ID\n"
    exit 1
fi

# Step 3: Clear DHCP leases
print_step "Clearing DHCP leases..."
LEASE_COUNT=$(find /var/lib/dhcp/ -name "dhclient*.leases" 2>/dev/null | wc -l)
if [ "$LEASE_COUNT" -gt 0 ]; then
    sudo rm -f /var/lib/dhcp/dhclient*.leases 2>/dev/null
    print_success "Cleared $LEASE_COUNT DHCP lease file(s)\n"
else
    print_success "No DHCP leases to clear\n"
fi

# Step 4: Remove Tailscale state if exists
print_step "Checking Tailscale state..."
if [ -f /var/lib/tailscale/tailscaled.state ]; then
    if sudo rm -f /var/lib/tailscale/tailscaled.state 2>/dev/null; then
        print_success "Tailscale state removed (will require re-authentication)\n"
    else
        print_warning "Could not remove Tailscale state\n"
    fi
else
    print_success "No Tailscale state found\n"
fi

# Step 5: Regenerate SSH host keys
print_step "Regenerating SSH host keys for unique identity..."
OLD_KEY_COUNT=$(sudo ls -1 /etc/ssh/ssh_host_* 2>/dev/null | wc -l)
if [ "$OLD_KEY_COUNT" -gt 0 ]; then
    echo -e "  ${CYAN}→${NC} Found $OLD_KEY_COUNT existing host keys"
    if sudo rm -f /etc/ssh/ssh_host_* 2>/dev/null; then
        echo -e "  ${CYAN}→${NC} Removed old host keys"
    fi
fi

if sudo dpkg-reconfigure -f noninteractive openssh-server 2>&1 | grep -q "Generating"; then
    NEW_KEY_COUNT=$(sudo ls -1 /etc/ssh/ssh_host_* 2>/dev/null | wc -l)
    print_success "Generated $NEW_KEY_COUNT new SSH host keys"
    echo -e "  ${CYAN}→${NC} Each clone now has a unique server fingerprint\n"
    sudo systemctl restart sshd 2>/dev/null
else
    print_warning "SSH host key regeneration may have issues\n"
fi

# Summary
echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║${NC}  ${BOLD}IDENTITY FIX COMPLETE!${NC}                                     ${GREEN}║${NC}"
echo -e "${GREEN}╠════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  ${BOLD}Changes:${NC}                                                   ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}    • New machine-id generated                              ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}    • DHCP leases cleared                                   ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}    • Tailscale state removed                               ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}    • SSH host keys regenerated                             ${GREEN}║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}\n"

echo -e "${YELLOW}⚠  VM will reboot in 3 seconds to apply changes...${NC}\n"
sleep 1
echo -e "  ${CYAN}3...${NC}"
sleep 1
echo -e "  ${CYAN}2...${NC}"
sleep 1
echo -e "  ${CYAN}1...${NC}\n"

echo -e "${BOLD}Rebooting now...${NC}\n"
sudo reboot
