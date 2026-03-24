#!/bin/bash
# ==============================================================================
# NVIDIA 590 Open Kernel Module Driver Installer for Void Linux
# ------------------------------------------------------------------------------
# Targets: Turing+ GPUs (RTX 20xx / GTX 16xx and newer)
# Note: Pascal (GTX 10xx) and older are NOT supported by 590+ open drivers.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Colour helpers
# ------------------------------------------------------------------------------
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()     { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

as_user() { sudo -u "$BUILD_USER" env HOME="$BUILD_USER_HOME" "$@"; }

# ------------------------------------------------------------------------------
# PREFLIGHT & COMPATIBILITY CHECKS
# ------------------------------------------------------------------------------
preflight_checks() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root (use sudo)."
    fi

    info "Checking GPU compatibility..."
    local gpu_info
    gpu_info=$(lspci | grep -i nvidia || true)
    if [[ -z "$gpu_info" ]]; then
        die "No NVIDIA GPU detected via lspci."
    fi
    warn "Ensure your card is Turing (RTX 20xx) or newer. 590 drivers dropped Pascal support."

    info "Updating system and installing build dependencies..."
    xbps-install -Sy void-repo-nonfree
    xbps-install -y git base-devel xtools

    # Ensure headers match the running kernel for DKMS
    local kernel_ver
    kernel_ver=$(uname -r | cut -d. -f1,2)
    info "Installing kernel headers for linux${kernel_ver}..."
    xbps-install -y "linux${kernel_ver}-headers"
}

# ------------------------------------------------------------------------------
# CONFIGURATION MODULES
# ------------------------------------------------------------------------------
configure_modesetting() {
    info "Configuring nvidia-drm modeset=1..."
    # Modern Wayland/X11 performance requires modesetting
    mkdir -p /etc/modprobe.d
    echo "options nvidia-drm modeset=1" > /etc/modprobe.d/nvidia-drm.conf
    success "Created /etc/modprobe.d/nvidia-drm.conf"
}

# ------------------------------------------------------------------------------
# MAIN INSTALLATION LOGIC
# ------------------------------------------------------------------------------
main() {
    echo -e "\n${BOLD}============================================================${RESET}"
    echo -e "${BOLD}  NVIDIA 590 Open Driver Installer — Void Linux${RESET}"
    echo -e "============================================================${RESET}"

    preflight_checks

    BUILD_USER="${SUDO_USER:-$USER}"
    BUILD_USER_HOME=$(eval echo "~$BUILD_USER")
    VOID_PACKAGES_DIR="$BUILD_USER_HOME/void-packages"

    if [ ! -d "$VOID_PACKAGES_DIR" ]; then
        info "Cloning void-packages..."
        as_user git clone --depth 1 https://github.com/void-linux/void-packages.git "$VOID_PACKAGES_DIR"
    fi

    cd "$VOID_PACKAGES_DIR"
    
    # Robust PR fetching
    info "Fetching PR #54593 (NVIDIA 590 branch)..."
    as_user git fetch origin pull/54593/head:nvidia-590-open
    as_user git checkout nvidia-590-open

    info "Building nvidia-open-dkms 590..."
    as_user ./xbps-src pkg nvidia-open-dkms

    info "Installing package..."
    xbps-install -y --repository hostdir/binpkgs nvidia-open-dkms

    configure_modesetting

    success "Installation complete. Please reboot."
    echo -e "Verify after reboot with: ${CYAN}nvidia-smi${RESET}"
}

main
