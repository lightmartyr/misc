#!/bin/bash
# ==============================================================================
# RTX 5070 Ti NVIDIA Open Kernel Module Driver Installer for Void Linux
# Source: https://github.com/void-linux/void-packages/pull/56685
# Branch: nvidia-open (fvalasiad/void-packages)
#
# WARNING: This installs from an experimental WIP PR. Expect possible breakages.
# Make sure you know how to revert (TTY access, chroot, or rescue image).
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
    # xbps-src hard-refuses to run as root, so all build steps are executed
    # under this user via 'sudo -u'.
    #
    # Resolution order:
    #   1. $SUDO_USER  — set automatically when the script is invoked via sudo
    #   2. $DOAS_USER  — set by doas (openbsd-style sudo alternative)
    #   3. Prompt the user to supply a username
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

    # Confirm glibc (not musl) — check for ldd version string
    if ldd --version 2>&1 | grep -qi musl; then
        die "musl libc detected. NVIDIA precompiled libraries require glibc."
    fi
    success "Architecture: x86_64-glibc."

    # Ensure pciutils is installed — lspci is not always present on a minimal install
    if ! command -v lspci &>/dev/null; then
        info "lspci not found — installing pciutils..."
        xbps-install -Sy pciutils || die "Failed to install pciutils. Cannot detect GPU."
    fi

    # Update the PCI ID database so new Blackwell (50xx) cards are recognised
    # by name rather than showing as "NVIDIA Corporation Device XXXX".
    if command -v update-pciids &>/dev/null; then
        info "Updating PCI ID database (update-pciids)..."
        update-pciids 2>/dev/null || true   # non-fatal if network is unavailable
    fi

    # Detect any NVIDIA GPU.
    # For very new cards (RTX 50xx / Blackwell) the local pciids database may
    # not yet have the device name, so lspci falls back to the raw vendor ID
    # (10de) or "NVIDIA Corporation Device XXXX".  We therefore check for both
    # the vendor string "NVIDIA" AND the vendor ID "10de" (NVIDIA's PCI vendor).
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

    # Warn (but never hard-fail) if the card cannot be confirmed as Turing+.
    # lspci output for brand-new Blackwell cards may just read
    # "NVIDIA Corporation Device 2c02" with no marketing name, so we cannot
    # reliably gate on a product-name regex.  The open modules will simply fail
    # to load at boot if the GPU is pre-Turing, giving a clear dmesg message.
    if ! echo "$gpu_info" | grep -qiE \
        "RTX [2-9][0-9]{3}|GTX 16[0-9]{2}|TITAN RTX|[Bb]lackwell|[Aa]da|[Hh]opper|[Aa]mpere|[Tt]uring|Device [2-9][0-9a-f]{3}"; then
        warn "Could not confirm a Turing+ GPU from lspci output."
        warn "The open kernel modules support Turing (RTX 20xx / GTX 16xx) and newer only."
        warn "If your GPU is pre-Turing the driver will not load after reboot."
    fi

    # -------------------------------------------------------------------------
    # Kernel version and matching headers
    # -------------------------------------------------------------------------
    KERNEL_VERSION=$(uname -r)
    info "Running kernel: ${KERNEL_VERSION}"

    # Derive the xbps kernel package name from the running kernel version.
    # Void kernel packages are named linux<major>.<minor>, e.g. linux6.12
    # Their header packages are linux<major>.<minor>-headers.
    local kshort
    kshort=$(echo "$KERNEL_VERSION" | grep -oE '^[0-9]+\.[0-9]+')
    KERNEL_PKG="linux${kshort}"
    HEADERS_PKG="${KERNEL_PKG}-headers"

    info "Kernel package: ${KERNEL_PKG}"
    info "Headers package: ${HEADERS_PKG}"

    # Verify the headers package is installed
    if ! xbps-query "$HEADERS_PKG" &>/dev/null; then
        die "Kernel headers package '${HEADERS_PKG}' is not installed.\n" \
            "      Install it with:  xbps-install -S ${HEADERS_PKG}\n" \
            "      Then re-run this script."
    fi
    success "Headers package '${HEADERS_PKG}' is installed."

    # Verify the kernel build directory exists (DKMS needs it)
    # Void places headers under /usr/src/linux-headers-<kver> and symlinks
    # /lib/modules/<kver>/build -> there.
    local mod_build="/lib/modules/${KERNEL_VERSION}/build"
    if [[ ! -d "$mod_build" && ! -L "$mod_build" ]]; then
        die "Kernel build directory not found at '${mod_build}'.\n" \
            "      Try reconfiguring the kernel:  xbps-reconfigure -f ${KERNEL_PKG}"
    fi
    success "Kernel build directory present: ${mod_build}"

    # Confirm gcc is available (DKMS will invoke it)
    command -v gcc &>/dev/null || \
        die "gcc not found. Install base-devel: xbps-install -S base-devel"
    success "gcc: $(gcc --version | head -n1)"

    # Warn about ignored kernel packages that could block header updates
    if grep -rqs 'ignorepkg.*linux' /etc/xbps.d/ 2>/dev/null; then
        warn "Found 'ignorepkg' entries mentioning linux in /etc/xbps.d/"
        warn "This may prevent kernel header updates after future upgrades."
        grep -rh 'ignorepkg.*linux' /etc/xbps.d/ | sed 's/^/         /'
    fi

    # Disk space — xbps-src bootstrap + build needs ~10 GB
    local free_kb free_gb
    free_kb=$(df -k . | awk 'NR==2{print $4}')
    free_gb=$(( free_kb / 1024 / 1024 ))
    if (( free_gb < 10 )); then
        warn "Less than 10 GB free in the current directory (${free_gb} GB available)."
        warn "The build may fail. Consider running from a partition with more space."
    else
        success "Disk space: ${free_gb} GB available."
    fi

    # Ensure all required external commands are present
    # (lspci / pciutils is handled and installed earlier in this phase)
    for cmd in git xbps-install xbps-remove xbps-query xbps-reconfigure dkms; do
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
        base-devel   # compiler toolchain, binutils, etc.
        gcc
        make
        perl         # required by the NVIDIA kernel module Makefile
        xz           # needed for module compression (as noted in PR #54593)
        git
        dkms
        "$HEADERS_PKG"
    )

    info "Installing: ${deps[*]}"
    # xbps-install exits 0 even if packages are already up-to-date
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
        nvidia-utils
        nvidia-settings
        nvidia-opencl
        nvidia470-dkms
        nvidia470-utils
        nvidia390-dkms
        nvidia390-utils
        nvidia-open-dkms
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
    # -R: also remove packages that depend on these
    xbps-remove -Ry "${installed[@]}"
    success "Existing NVIDIA packages removed."
}

# ------------------------------------------------------------------------------
# PHASE 4: CLONE PR #56685 AND BUILD
# ------------------------------------------------------------------------------
build_nvidia() {
    echo -e "\n${BOLD}=== Phase 4: Clone & Build nvidia (PR #56685) ===${RESET}\n"

    # Place the build tree in the build user's home so they own it.
    # xbps-src also writes to $HOME/.xbps-src, so running under the correct
    # user home is important.
    BUILD_DIR="$BUILD_USER_HOME/void-packages-nvidia-open"

    if [[ -d "$BUILD_DIR" ]]; then
        warn "Build directory '${BUILD_DIR}' already exists."
        info "Resetting to latest upstream state of branch nvidia-open..."
        as_user git -C "$BUILD_DIR" fetch origin
        as_user git -C "$BUILD_DIR" reset --hard origin/nvidia-open
    else
        info "Cloning fvalasiad/void-packages (branch: nvidia-open)..."
        as_user git clone \
            --depth=1 \
            --branch nvidia-open \
            https://github.com/fvalasiad/void-packages.git \
            "$BUILD_DIR"
    fi

    success "Source tree ready at: ${BUILD_DIR}"

    # Bootstrap xbps-src (creates the build chroot / masterdir).
    # Must run as the unprivileged build user — xbps-src refuses root.
    info "Bootstrapping xbps-src (this may take several minutes)..."
    as_user "$BUILD_DIR/xbps-src" binary-bootstrap
    success "xbps-src bootstrap complete."

    # Allow restricted (nonfree) packages inside the build environment so the
    # nvidia template can pull its precompiled user-space blobs.
    if ! grep -q 'XBPS_ALLOW_RESTRICTED=yes' "$BUILD_DIR/etc/conf" 2>/dev/null; then
        info "Enabling restricted packages in xbps-src..."
        as_user bash -c "echo 'XBPS_ALLOW_RESTRICTED=yes' >> '$BUILD_DIR/etc/conf'"
    fi

    # Build the nvidia package.
    # PR #56685 patches the existing nvidia template to use the open kernel
    # modules, so building 'nvidia' produces nvidia-dkms backed by the open
    # source kernel module source (driver 590.48.01 at time of writing).
    info "Building nvidia package — driver 590.48.01 (open kernel modules)..."
    info "This will take several minutes..."
    as_user "$BUILD_DIR/xbps-src" pkg -f nvidia

    success "Build finished."
    BINPKGS_DIR="$BUILD_DIR/hostdir/binpkgs"
}

# ------------------------------------------------------------------------------
# PHASE 5: INSTALL BUILT PACKAGES
# ------------------------------------------------------------------------------
install_packages() {
    echo -e "\n${BOLD}=== Phase 5: Install Packages ===${RESET}\n"

    # Verify each expected package was actually produced
    local pkgs_to_install=(nvidia nvidia-utils nvidia-settings)
    for pkg in "${pkgs_to_install[@]}"; do
        if ! ls "$BINPKGS_DIR"/${pkg}-*.xbps &>/dev/null && \
           ! ls "$BINPKGS_DIR"/nonfree/${pkg}-*.xbps &>/dev/null; then
            die "Built package not found for '${pkg}' in ${BINPKGS_DIR}.\n" \
                "      Check the xbps-src output above for build errors."
        fi
    done

    # Ensure the void-repo-nonfree repo is enabled at runtime as well
    info "Enabling nonfree repository..."
    xbps-install -Sy void-repo-nonfree || true
    xbps-install -Sy

    info "Installing built packages from local repository..."
    xbps-install -Sy \
        --repository="$BINPKGS_DIR" \
        --repository="$BINPKGS_DIR/nonfree" \
        "${pkgs_to_install[@]}"

    success "NVIDIA packages installed."
}

# ------------------------------------------------------------------------------
# PHASE 6: TRIGGER DKMS BUILD AND VERIFY
# ------------------------------------------------------------------------------
build_and_verify_dkms() {
    echo -e "\n${BOLD}=== Phase 6: DKMS Build & Verification ===${RESET}\n"

    # Double-check the kernel build symlink is still present after package
    # installs/removals (previous DKMS hooks could have touched things)
    local mod_build="/lib/modules/${KERNEL_VERSION}/build"
    if [[ ! -d "$mod_build" && ! -L "$mod_build" ]]; then
        die "Kernel build symlink missing: ${mod_build}\n" \
            "      Run: xbps-reconfigure -f ${KERNEL_PKG}"
    fi

    info "Triggering DKMS build via: xbps-reconfigure -f ${KERNEL_PKG}"
    xbps-reconfigure -f "$KERNEL_PKG"

    # xbps-reconfigure is synchronous; wait a moment for filesystem to settle
    sleep 2

    # Locate the most recent DKMS make.log for nvidia
    local dkms_log
    dkms_log=$(find /var/lib/dkms -name "make.log" -path "*nvidia*" 2>/dev/null \
        | sort -t/ -k6 -V | tail -n1 || true)

    if [[ -n "$dkms_log" ]]; then
        info "DKMS build log: ${dkms_log}"
        if grep -qi "error:" "$dkms_log" 2>/dev/null; then
            echo ""
            warn "Errors detected in DKMS build log:"
            grep -i "error:" "$dkms_log" | head -20 | sed 's/^/    /'
            echo ""
            die "DKMS module build failed.\n      Full log: ${dkms_log}"
        fi
        success "No errors found in DKMS build log."
    else
        warn "DKMS make.log not found — verifying modules directly."
    fi

    # Verify all four expected kernel modules are present on disk
    local modules_found=0
    for mod in nvidia nvidia-modeset nvidia-uvm nvidia-drm; do
        if find "/lib/modules/${KERNEL_VERSION}" -name "${mod}.ko*" 2>/dev/null \
                | grep -q .; then
            success "Module on disk: ${mod}"
            modules_found=$(( modules_found + 1 ))
        else
            warn "Module NOT found on disk: ${mod}"
        fi
    done

    if (( modules_found == 0 )); then
        die "No NVIDIA kernel modules found under /lib/modules/${KERNEL_VERSION}.\n" \
            "      DKMS log: ${dkms_log:-/var/lib/dkms/}"
    fi

    success "DKMS build verified: ${modules_found}/4 modules present."
}

# ------------------------------------------------------------------------------
# PHASE 7: CONFIGURE BOOT PARAMETERS AND BLACKLIST NOUVEAU
# ------------------------------------------------------------------------------
configure_boot() {
    echo -e "\n${BOLD}=== Phase 7: Boot Configuration ===${RESET}\n"

    local GRUB_PARAM="nvidia_drm.modeset=1 nvidia_drm.fbdev=1"
    local GRUB_DEFAULT="/etc/default/grub"

    # --- GRUB ---
    if [[ -f "$GRUB_DEFAULT" ]]; then
        if grep -q "nvidia_drm.modeset=1" "$GRUB_DEFAULT"; then
            info "Boot parameters already present in ${GRUB_DEFAULT}."
        else
            info "Adding '${GRUB_PARAM}' to GRUB_CMDLINE_LINUX_DEFAULT..."
            cp "$GRUB_DEFAULT" "${GRUB_DEFAULT}.bak"
            info "Backup: ${GRUB_DEFAULT}.bak"
            sed -i \
                "s|^\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"|\1 ${GRUB_PARAM}\"|" \
                "$GRUB_DEFAULT"
            success "Boot parameters added to ${GRUB_DEFAULT}."
        fi

        if command -v update-grub &>/dev/null; then
            info "Running update-grub..."
            update-grub && success "GRUB config regenerated."
        elif command -v grub-mkconfig &>/dev/null; then
            info "Running grub-mkconfig..."
            grub-mkconfig -o /boot/grub/grub.cfg && success "GRUB config regenerated."
        else
            warn "update-grub / grub-mkconfig not found."
            warn "Manually add to your bootloader cmdline: ${GRUB_PARAM}"
        fi
    else
        warn "${GRUB_DEFAULT} not found — skipping GRUB configuration."
        warn "Manually add to your bootloader cmdline: ${GRUB_PARAM}"
    fi

    # --- Blacklist nouveau ---
    local BLACKLIST="/etc/modprobe.d/nouveau-blacklist.conf"
    if [[ ! -f "$BLACKLIST" ]]; then
        info "Blacklisting nouveau kernel module..."
        cat > "$BLACKLIST" <<'EOF'
# Prevent nouveau from loading and conflicting with the NVIDIA open modules.
blacklist nouveau
options nouveau modeset=0
EOF
        success "nouveau blacklisted: ${BLACKLIST}"
    else
        info "nouveau blacklist already present at ${BLACKLIST}."
    fi

    # Bake the blacklist into the initramfs
    info "Regenerating initramfs to include nouveau blacklist..."
    xbps-reconfigure -f "$KERNEL_PKG"
    success "Initramfs regenerated."
}

# ------------------------------------------------------------------------------
# PHASE 8: SUMMARY
# ------------------------------------------------------------------------------
summary() {
    echo -e "\n${BOLD}=== Phase 8: Summary ===${RESET}\n"

    echo -e "${BOLD}Installed packages:${RESET}"
    for pkg in nvidia nvidia-utils nvidia-settings; do
        if xbps-query "$pkg" &>/dev/null; then
            local ver
            ver=$(xbps-query "$pkg" | awk '/pkgver/{print $2}')
            success "  ${pkg}  (${ver})"
        else
            warn "  ${pkg}: not installed"
        fi
    done

    echo ""
    echo -e "${BOLD}Kernel modules (/lib/modules/${KERNEL_VERSION}):${RESET}"
    for mod in nvidia nvidia-modeset nvidia-uvm nvidia-drm; do
        local modpath
        modpath=$(find "/lib/modules/${KERNEL_VERSION}" -name "${mod}.ko*" \
                      2>/dev/null | head -n1 || true)
        if [[ -n "$modpath" ]]; then
            success "  ${mod}  →  ${modpath}"
        else
            warn "  ${mod}: not found"
        fi
    done

    echo ""
    echo -e "${BOLD}DKMS status:${RESET}"
    dkms status 2>/dev/null | sed 's/^/  /' || warn "  dkms status unavailable"

    echo ""
    echo -e "${YELLOW}${BOLD}SOURCE${RESET}  PR #56685 (WIP): https://github.com/void-linux/void-packages/pull/56685"
    echo -e "${YELLOW}${BOLD}DRIVER${RESET}  590.48.01 with open kernel modules"
    echo ""
    echo -e "A ${BOLD}reboot${RESET} is required to load the new modules."
    echo -e "After rebooting, verify with:  ${CYAN}nvidia-smi${RESET}"
    echo ""
    echo -e "${GREEN}${BOLD}Installation complete. Please reboot your system.${RESET}\n"
}

# ------------------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------------------
main() {
    echo -e "\n${BOLD}============================================================${RESET}"
    echo -e "${BOLD}  RTX 5070 Ti NVIDIA Open Driver Installer — Void Linux${RESET}"
    echo -e "${BOLD}============================================================${RESET}"
    echo -e "${YELLOW}PR:      https://github.com/void-linux/void-packages/pull/56685${RESET}"
    echo -e "${YELLOW}Branch:  nvidia-open  (fvalasiad/void-packages)${RESET}"
    echo -e "${RED}WARNING: Experimental / WIP. Ensure TTY or recovery access.${RESET}\n"

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
