#!/bin/bash
# ==============================================================================
# RTX 5070 Ti NVIDIA Open Kernel Module Driver Installer for Void Linux
# Source: https://github.com/void-linux/void-packages/pull/54593
# Branch: patch-1 (JkktBkkt/void-packages)
#
# This installs nvidia-open-dkms which provides open kernel modules for
# Turing+ GPUs (RTX 20xx / GTX 16xx and newer).
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

# Run a command as the unprivileged build user.
# xbps-src refuses to run as root; we drop to BUILD_USER for all build steps.
as_user() { sudo -u "$BUILD_USER" env HOME="$BUILD_USER_HOME" "$@"; }

# ------------------------------------------------------------------------------
# PHASE 1: PRE-FLIGHT CHECKS
# ------------------------------------------------------------------------------
preflight_checks() {
    echo -e "\n${BOLD}=== Phase 1: Pre-flight Checks ===${RESET}\n"

    # Must run as root
    [[ "$EUID" -eq 0 ]] || die "This script must be run as root (sudo or su)."
    success "Running as root."

    # Identify the unprivileged user to run xbps-src as.
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        BUILD_USER="$SUDO_USER"
    elif [[ -n "${DOAS_USER:-}" && "$DOAS_USER" != "root" ]]; then
        BUILD_USER="$DOAS_USER"
    else
        echo -e "${YELLOW}Could not detect the invoking non-root user automatically.${RESET}"
        read -rp "Enter the username to run xbps-src as: " BUILD_USER
        [[ -n "$BUILD_USER" ]] || die "No build user supplied."
        id "$BUILD_USER" &>/dev/null || die "User '${BUILD_USER}' does not exist."
    fi

    BUILD_USER_HOME=$(getent passwd "$BUILD_USER" | cut -d: -f6)
    [[ -n "$BUILD_USER_HOME" ]] || die "Could not determine home directory for '${BUILD_USER}'."
    success "Build user: ${BUILD_USER} (home: ${BUILD_USER_HOME})"

    # Must be Void Linux
    [[ -f /etc/os-release ]] || die "Cannot detect OS. /etc/os-release not found."
    # shellcheck source=/dev/null
    source /etc/os-release
    [[ "${ID:-}" == "void" ]] || die "This script is for Void Linux only. Detected: ${ID:-unknown}"
    success "Void Linux detected."

    # Must be x86_64-glibc (nvidia precompiled libs require glibc)
    local arch
    arch=$(uname -m)
    [[ "$arch" == "x86_64" ]] || die "Only x86_64 is supported. Detected: $arch"

    # Confirm glibc (not musl)
    if ldd --version 2>&1 | grep -qi musl; then
        die "musl libc detected. NVIDIA precompiled libraries require glibc."
    fi
    success "Architecture: x86_64-glibc."

    # Ensure pciutils is installed
    if ! command -v lspci &>/dev/null; then
        info "lspci not found — installing pciutils..."
        xbps-install -Sy pciutils || die "Failed to install pciutils. Cannot detect GPU."
    fi

    # Update PCI ID database
    if command -v update-pciids &>/dev/null; then
        info "Updating PCI ID database..."
        update-pciids 2>/dev/null || true
    fi

    # Detect NVIDIA GPU
    local lspci_out
    lspci_out=$(lspci 2>/dev/null) || true

    local gpu_info=""
    if echo "$lspci_out" | grep -qi nvidia; then
        gpu_info=$(echo "$lspci_out" | grep -i nvidia | head -n1)
    elif echo "$lspci_out" | grep -qi "10de:"; then
        gpu_info=$(echo "$lspci_out" | grep -i "10de:" | head -n1)
    fi

    if [[ -z "$gpu_info" ]]; then
        die "No NVIDIA GPU detected via lspci (checked for 'nvidia' and vendor ID 10de).\n" \
            "      Is the GPU seated correctly? Try: lspci | grep -i '10de\|nvidia'"
    fi
    success "NVIDIA GPU detected: ${gpu_info}"

    # Warn about Turing+ requirement
    if ! echo "$gpu_info" | grep -qiE \
        "RTX [2-9][0-9]{3}|GTX 16[0-9]{2}|TITAN RTX|[Bb]lackwell|[Aa]da|[Hh]opper|[Aa]mpere|[Tt]uring|Device [2-9][0-9a-f]{3}"; then
        warn "Could not confirm a Turing+ GPU from lspci output."
        warn "The open kernel modules support Turing (RTX 20xx / GTX 16xx) and newer only."
    fi

    # Kernel version and matching headers
    KERNEL_VERSION=$(uname -r)
    info "Running kernel: ${KERNEL_VERSION}"

    local kshort
    kshort=$(echo "$KERNEL_VERSION" | grep -oE '^[0-9]+\.[0-9]+')
    KERNEL_PKG="linux${kshort}"
    HEADERS_PKG="${KERNEL_PKG}-headers"

    info "Kernel package: ${KERNEL_PKG}"
    info "Headers package: ${HEADERS_PKG}"

    if ! xbps-query "$HEADERS_PKG" &>/dev/null; then
        die "Kernel headers package '${HEADERS_PKG}' is not installed.\n" \
            "      Install it with:  xbps-install -S ${HEADERS_PKG}"
    fi
    success "Headers package '${HEADERS_PKG}' is installed."

    local mod_build="/lib/modules/${KERNEL_VERSION}/build"
    if [[ ! -d "$mod_build" && ! -L "$mod_build" ]]; then
        die "Kernel build directory not found at '${mod_build}'.\n" \
            "      Try: xbps-reconfigure -f ${KERNEL_PKG}"
    fi
    success "Kernel build directory present."

    # Check gcc
    command -v gcc &>/dev/null || \
        die "gcc not found. Install base-devel."
    success "gcc: $(gcc --version | head -n1)"

    # Disk space
    local free_kb free_gb
    free_kb=$(df -k . | awk 'NR==2{print $4}')
    free_gb=$(( free_kb / 1024 / 1024 ))
    if (( free_gb < 10 )); then
        warn "Less than 10 GB free (${free_gb} GB available). Build may fail."
    else
        success "Disk space: ${free_gb} GB available."
    fi

    # Required commands
    for cmd in git xbps-install xbps-remove xbps-query xbps-reconfigure dkms xbps-uhelper; do
        command -v "$cmd" &>/dev/null || die "Required command not found: '${cmd}'"
    done
    success "All required commands present."
}

# ------------------------------------------------------------------------------
# PHASE 2: INSTALL BUILD DEPENDENCIES
# ------------------------------------------------------------------------------
install_build_deps() {
    echo -e "\n${BOLD}=== Phase 2: Install Build Dependencies ===${RESET}\n"

    info "Synchronising repository index..."
    xbps-install -Sy

    local deps=(
        base-devel
        gcc
        make
        perl
        xz           # Required for nvidia-open-dkms kernel module compression
        git
        dkms
        "$HEADERS_PKG"
    )

    info "Installing: ${deps[*]}"
    xbps-install -y "${deps[@]}"

    success "Build dependencies installed."
}

# ------------------------------------------------------------------------------
# PHASE 3: REMOVE EXISTING NVIDIA DRIVERS
# ------------------------------------------------------------------------------
remove_existing_nvidia() {
    echo -e "\n${BOLD}=== Phase 3: Remove Existing NVIDIA Drivers ===${RESET}\n"

    local candidates=(
        nvidia
        nvidia-dkms
        nvidia-open-dkms
        nvidia-utils
        nvidia-settings
        nvidia-opencl
        nvidia470-dkms
        nvidia470-utils
        nvidia390-dkms
        nvidia390-utils
    )

    local installed=()
    for pkg in "${candidates[@]}"; do
        if xbps-query "$pkg" &>/dev/null; then
            installed+=("$pkg")
        fi
    done

    if [[ ${#installed[@]} -eq 0 ]]; then
        info "No existing NVIDIA packages found — skipping removal."
        return
    fi

    warn "Removing: ${installed[*]}"
    xbps-remove -Ry "${installed[@]}"
    success "Existing NVIDIA packages removed."
}

# ------------------------------------------------------------------------------
# PHASE 4: CLONE PR #54593 AND BUILD
# ------------------------------------------------------------------------------
build_nvidia() {
    echo -e "\n${BOLD}=== Phase 4: Clone & Build nvidia-open-dkms (PR #54593) ===${RESET}\n"

    BUILD_DIR="$BUILD_USER_HOME/void-packages-nvidia-open"

    if [[ -d "$BUILD_DIR" ]]; then
        warn "Build directory '${BUILD_DIR}' already exists."
        info "Resetting to latest upstream state..."
        as_user git -C "$BUILD_DIR" fetch origin
        as_user git -C "$BUILD_DIR" reset --hard origin/patch-1
    else
        info "Cloning JkktBkkt/void-packages (branch: patch-1)..."
        as_user git clone \
            --depth=1 \
            --branch patch-1 \
            https://github.com/JkktBkkt/void-packages.git \
            "$BUILD_DIR"
    fi

    success "Source tree ready at: ${BUILD_DIR}"

    # Bootstrap xbps-src
    info "Bootstrapping xbps-src..."
    as_user "$BUILD_DIR/xbps-src" binary-bootstrap
    success "xbps-src bootstrap complete."

    # Enable nonfree for nvidia user-space libs
    if ! grep -q 'XBPS_ALLOW_RESTRICTED=yes' "$BUILD_DIR/etc/conf" 2>/dev/null; then
        info "Enabling restricted packages..."
        as_user bash -c "echo 'XBPS_ALLOW_RESTRICTED=yes' >> '$BUILD_DIR/etc/conf'"
    fi

    # Build nvidia-open-dkms
    info "Building nvidia-open-dkms (open kernel modules)..."
    info "This will take several minutes..."
    as_user "$BUILD_DIR/xbps-src" pkg -f nvidia-open-dkms

    success "Build finished."
    BINPKGS_DIR="$BUILD_DIR/hostdir/binpkgs"
    # nvidia-open-dkms goes to hostdir/binpkgs/nvidia-open/ (custom repo)
    BINPKGS_OPEN="$BINPKGS_DIR/nvidia-open"
}

# ------------------------------------------------------------------------------
# PHASE 5: INSTALL BUILT PACKAGES
# ------------------------------------------------------------------------------
install_packages() {
    echo -e "\n${BOLD}=== Phase 5: Install Packages ===${RESET}\n"

    # Find the actual repodata files and .xbps packages dynamically
    info "Searching for built packages in ${BINPKGS_DIR}..."

    # Find all repodata files
    local repodata_files
    repodata_files=$(find "$BINPKGS_DIR" -maxdepth 2 -name "*-repodata" 2>/dev/null || true)

    if [[ -z "$repodata_files" ]]; then
        die "No repodata files found in ${BINPKGS_DIR}. Build may have failed."
    fi

    info "Found repodata files:"
    echo "$repodata_files" | sed 's/^/    /'

    # Find all .xbps package files
    local xbps_files
    xbps_files=$(find "$BINPKGS_DIR" -maxdepth 3 -name "*.xbps" 2>/dev/null || true)

    if [[ -z "$xbps_files" ]]; then
        die "No .xbps package files found in ${BINPKGS_DIR}. Build may have failed."
    fi

    info "Found .xbps packages:"
    echo "$xbps_files" | sed 's/^/    /'

    # Extract unique directories containing repodata (these are our repo paths)
    local repo_dirs=()
    while IFS= read -r line; do
        local dir
        dir=$(dirname "$line")
        repo_dirs+=("$dir")
    done < <(echo "$repodata_files" | sort -u)

    if [[ ${#repo_dirs[@]} -eq 0 ]]; then
        die "Could not determine repository directories."
    fi

    info "Repository directories:"
    for d in "${repo_dirs[@]}"; do
        info "    $d"
    done

    # Check for nvidia-open-dkms package
    if ! echo "$xbps_files" | grep -q "nvidia-open-dkms"; then
        die "nvidia-open-dkms package not found."
    fi

    # Enable nonfree repo for nvidia user-space libs
    info "Enabling nonfree repository..."
    xbps-install -Sy void-repo-nonfree || true
    xbps-install -Sy

    # Register all local repos
    local XBPS_CONF="/etc/xbps.d/99-nvidia-local-repo.conf"
    info "Registering local repositories..."
    {
        for d in "${repo_dirs[@]}"; do
            echo "repository=$d"
        done
    } > "$XBPS_CONF"

    cat "$XBPS_CONF" | sed 's/^/    /'

    xbps-install -Sy

    # Install nvidia first (user-space libs), then nvidia-open-dkms
    info "Installing nvidia (user-space libraries)..."
    xbps-install -Sy nvidia

    info "Installing nvidia-open-dkms (open kernel modules)..."
    local install_status=0
    xbps-install -Sy nvidia-open-dkms || install_status=$?

    rm -f "$XBPS_CONF"

    [[ $install_status -eq 0 ]] || die "xbps-install failed with status ${install_status}."

    success "NVIDIA packages installed."
}

# ------------------------------------------------------------------------------
# PHASE 6: TRIGGER DKMS BUILD AND VERIFY
# ------------------------------------------------------------------------------
build_and_verify_dkms() {
    echo -e "\n${BOLD}=== Phase 6: DKMS Build & Verification ===${RESET}\n"

    local mod_build="/lib/modules/${KERNEL_VERSION}/build"
    if [[ ! -d "$mod_build" && ! -L "$mod_build" ]]; then
        die "Kernel build symlink missing: ${mod_build}"
    fi

    info "Triggering DKMS build..."
    xbps-reconfigure -f "$KERNEL_PKG"

    sleep 2

    # Check DKMS log
    local dkms_log
    dkms_log=$(find /var/lib/dkms -name "make.log" -path "*nvidia-open*" 2>/dev/null \
        | sort -t/ -k6 -V | tail -n1 || true)

    if [[ -n "$dkms_log" ]]; then
        info "DKMS build log: ${dkms_log}"
        if grep -qi "error:" "$dkms_log" 2>/dev/null; then
            echo ""
            warn "Errors detected in DKMS build log:"
            grep -i "error:" "$dkms_log" | head -20 | sed 's/^/    /'
            die "DKMS module build failed."
        fi
        success "No errors found in DKMS build log."
    fi

    # Verify modules
    local modules_found=0
    for mod in nvidia nvidia-modeset nvidia-uvm nvidia-drm; do
        if find "/lib/modules/${KERNEL_VERSION}" -name "${mod}.ko*" 2>/dev/null \
                | grep -q .; then
            success "Module found: ${mod}"
            modules_found=$(( modules_found + 1 ))
        else
            warn "Module NOT found: ${mod}"
        fi
    done

    if (( modules_found == 0 )); then
        die "No NVIDIA kernel modules found."
    fi

    success "DKMS build verified: ${modules_found}/4 modules present."
}

# ------------------------------------------------------------------------------
# PHASE 7: CONFIGURE BOOT PARAMETERS
# ------------------------------------------------------------------------------
configure_boot() {
    echo -e "\n${BOLD}=== Phase 7: Boot Configuration ===${RESET}\n"

    local GRUB_PARAM="nvidia_drm.modeset=1 nvidia_drm.fbdev=1"
    local GRUB_DEFAULT="/etc/default/grub"

    if [[ -f "$GRUB_DEFAULT" ]]; then
        if grep -q "nvidia_drm.modeset=1" "$GRUB_DEFAULT"; then
            info "Boot parameters already present."
        else
            info "Adding boot parameters..."
            cp "$GRUB_DEFAULT" "${GRUB_DEFAULT}.bak"
            sed -i \
                "s|^\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"|\1 ${GRUB_PARAM}\"|" \
                "$GRUB_DEFAULT"
            success "Boot parameters added."
        fi

        if command -v update-grub &>/dev/null; then
            info "Running update-grub..."
            update-grub && success "GRUB updated."
        elif command -v grub-mkconfig &>/dev/null; then
            info "Running grub-mkconfig..."
            grub-mkconfig -o /boot/grub/grub.cfg && success "GRUB updated."
        fi
    fi

    # Blacklist nouveau
    local BLACKLIST="/etc/modprobe.d/nouveau-blacklist.conf"
    if [[ ! -f "$BLACKLIST" ]]; then
        info "Blacklisting nouveau..."
        cat > "$BLACKLIST" <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
        success "nouveau blacklisted."
    fi

    info "Regenerating initramfs..."
    xbps-reconfigure -f "$KERNEL_PKG"
    success "Initramfs regenerated."
}

# ------------------------------------------------------------------------------
# PHASE 8: SUMMARY
# ------------------------------------------------------------------------------
summary() {
    echo -e "\n${BOLD}=== Phase 8: Summary ===${RESET}\n"

    echo -e "${BOLD}Installed packages:${RESET}"
    for pkg in nvidia nvidia-open-dkms nvidia-utils nvidia-settings; do
        if xbps-query "$pkg" &>/dev/null; then
            local ver
            ver=$(xbps-query "$pkg" | awk '/pkgver/{print $2}')
            success "  ${pkg}  (${ver})"
        fi
    done

    echo ""
    echo -e "${BOLD}Kernel modules:${RESET}"
    for mod in nvidia nvidia-modeset nvidia-uvm nvidia-drm; do
        local modpath
        modpath=$(find "/lib/modules/${KERNEL_VERSION}" -name "${mod}.ko*" \
                      2>/dev/null | head -n1 || true)
        if [[ -n "$modpath" ]]; then
            success "  ${mod}"
        else
            warn "  ${mod}: not found"
        fi
    done

    echo ""
    echo -e "${YELLOW}${BOLD}SOURCE${RESET}  PR #54593: https://github.com/void-linux/void-packages/pull/54593"
    echo -e "${YELLOW}${BOLD}PACKAGE${RESET}  nvidia-open-dkms (open kernel modules)"
    echo ""
    echo -e "A ${BOLD}reboot${RESET} is required."
    echo -e "After rebooting, verify with: ${CYAN}nvidia-smi${RESET}"
    echo ""
    echo -e "${GREEN}${BOLD}Installation complete. Please reboot.${RESET}\n"
}

# ------------------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------------------
main() {
    echo -e "\n${BOLD}============================================================${RESET}"
    echo -e "${BOLD}  RTX 5070 Ti NVIDIA Open Driver Installer — Void Linux${RESET}"
    echo -e "${BOLD}============================================================${RESET}"
    echo -e "${YELLOW}PR:      https://github.com/void-linux/void-packages/pull/54593${RESET}"
    echo -e "${YELLOW}Branch:  patch-1  (JkktBkkt/void-packages)${RESET}"
    echo -e "${YELLOW}Package: nvidia-open-dkms (open kernel modules)${RESET}\n"

    preflight_checks
    install_build_deps
    remove_existing_nvidia
    build_nvidia
    install_packages
    build_and_verify_dkms
    configure_boot
    summary
}

main "$@"
