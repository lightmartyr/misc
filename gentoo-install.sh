#!/usr/bin/env bash
# WARNING: This script will WIPE the specified disk. 
# Ensure you are booted in UEFI mode before running.

set -e # Exit on any error

# --- Configuration Variables ---
DISK="sda"              # Target installation disk (e.g., sda, nvme0n1)
CPU_TYPE="amd"          # Set to "amd" or "intel" for appropriate microcode
TIMEZONE="Europe/London" # Set your local timezone
STAGE3_URL="https://distfiles.gentoo.org/releases/amd64/autobuilds/current-stage3-amd64-openrc/stage3-amd64-openrc-latest.tar.xz"

# --- Pre-flight Checks ---
if [ ! -d /sys/firmware/efi ]; then
    echo "ERROR: Host system is not booted in UEFI mode. Cannot install via EFISTUB/UKI." >&2
    exit 1
fi

echo "Starting Gentoo EFISTUB/UKI installation on /dev/${DISK}..."

# --- 1. Partitioning (GPT) ---
# EFI (ESP): 1GiB | Swap: 8GiB | Root: Remaining (XFS)
echo "Wiping and partitioning /dev/${DISK}..."
parted -a optimal /dev/${DISK} mklabel gpt
parted -a optimal /dev/${DISK} mkpart primary fat32 1MiB 1025MiB
parted -a optimal /dev/${DISK} name 1 boot
parted -a optimal /dev/${DISK} set 1 esp on

parted -a optimal /dev/${DISK} mkpart primary linux-swap 1025MiB 9217MiB
parted -a optimal /dev/${DISK} name 2 swap

parted -a optimal /dev/${DISK} mkpart primary xfs 9217MiB 100%
parted -a optimal /dev/${DISK} name 3 rootfs

# Wait for kernel partition table updates
sleep 2

# Naming schema mapping for NVMe vs SATA/SCSI
if [[ $DISK == *"nvme"* ]]; then
    PART_BOOT="/dev/${DISK}p1"
    PART_SWAP="/dev/${DISK}p2"
    PART_ROOT="/dev/${DISK}p3"
else
    PART_BOOT="/dev/${DISK}1"
    PART_SWAP="/dev/${DISK}2"
    PART_ROOT="/dev/${DISK}3"
fi

# --- 2. Formatting & Mounting ---
echo "Formatting filesystems..."
mkfs.vfat -F 32 -I ${PART_BOOT}
mkswap ${PART_SWAP}
swapon ${PART_SWAP}
mkfs.xfs -f ${PART_ROOT}

echo "Mounting partitions..."
mount ${PART_ROOT} /mnt/gentoo
mkdir -p /mnt/gentoo/efi
mount ${PART_BOOT} /mnt/gentoo/efi

# --- 3. Stage3 Extract ---
echo "Downloading and unpacking stage3..."
cd /mnt/gentoo
wget -O stage3.tar.xz ${STAGE3_URL}
tar xpvf stage3.tar.xz --xattrs-include='*.*' --numeric-owner

# --- 4. Base Configuration & Portage Setup ---
echo "Writing initial system configuration files..."
cat << 'EOF' > /mnt/gentoo/etc/portage/make.conf
COMMON_FLAGS="-O2 -pipe -march=native"
CFLAGS="${COMMON_FLAGS}"
CXXFLAGS="${COMMON_FLAGS}"
FCFLAGS="${COMMON_FLAGS}"
FFLAGS="${COMMON_FLAGS}"
LC_MESSAGES=C.utf8
MAKEOPTS="-j$(nproc)"
ACCEPT_LICENSE="*"
VIDEO_CARDS="nvidia"
USE="X wayland dbus udev"
EOF

# Unmask testing packages (~amd64) for latest binary kernel and NVIDIA drivers
mkdir -p /mnt/gentoo/etc/portage/package.accept_keywords
mkdir -p /mnt/gentoo/etc/portage/package.use
echo "sys-kernel/gentoo-kernel-bin ~amd64" > /mnt/gentoo/etc/portage/package.accept_keywords/gentoo-kernel-bin
echo "x11-drivers/nvidia-drivers ~amd64" > /mnt/gentoo/etc/portage/package.accept_keywords/nvidia-drivers

# Set USE flags for UKI and EFISTUB deployment
echo "sys-kernel/installkernel dracut uki efistub" > /mnt/gentoo/etc/portage/package.use/installkernel

# Configure Dracut to explicitly bundle NVIDIA modules
mkdir -p /mnt/gentoo/etc/dracut.conf.d
cat << 'EOF' > /mnt/gentoo/etc/dracut.conf.d/nvidia.conf
add_drivers+=" nvidia nvidia_modeset nvidia_uvm nvidia_drm "
EOF

# Generate dynamic Kernel Command Line using the XFS Root UUID
ROOT_UUID=$(blkid -s UUID -o value ${PART_ROOT})
mkdir -p /mnt/gentoo/etc/kernel
echo "root=UUID=${ROOT_UUID} nvidia-drm.modeset=1 rw" > /mnt/gentoo/etc/kernel/cmdline

echo "Copying network configuration..."
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/

# --- 5. Mount Virtual Filesystems ---
echo "Mounting virtual filesystems..."
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev
mount --bind /run /mnt/gentoo/run
mount --make-slave /mnt/gentoo/run

# --- 6. Generate the Chroot Setup Script ---
echo "Generating the inner chroot setup script..."
cat << EOF > /mnt/gentoo/root/chroot_setup.sh
#!/usr/bin/env bash
set -e

# Synchronize Portage database
emerge-webrsync

# Configure CPU flag optimizations
emerge app-portage/cpuid2cpuflags
echo "*/* \$(cpuid2cpuflags)" > /etc/portage/package.use/00cpuflags

# System localization
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
echo "${TIMEZONE}" > /etc/timezone
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set en_US.utf8
env-update && source /etc/profile

# Dynamic microcode selection
if [ "${CPU_TYPE}" = "amd" ]; then
    UCODE_PKG="sys-firmware/amd-ucode"
else
    UCODE_PKG="sys-firmware/intel-microcode"
fi

# Step 1: Install base toolchain, kernel-bin, firmware, and EFI boot managers
emerge \${UCODE_PKG} \
       sys-kernel/linux-firmware \
       sys-kernel/installkernel \
       sys-fs/xfsprogs \
       sys-boot/efibootmgr \
       sys-kernel/dracut \
       sys-kernel/gentoo-kernel-bin

# Step 2: Install NVIDIA Drivers (built against the newly installed kernel)
emerge x11-drivers/nvidia-drivers

# Step 3: Force UKI Regeneration 
# (incorporates newly compiled NVIDIA drivers into the boot image)
emerge --config sys-kernel/gentoo-kernel-bin

# Setup Filesystem Table (fstab)
emerge sys-fs/genfstab
genfstab -U / > /etc/fstab

# Finalize networking and services
echo "gentoo-box" > /etc/hostname
emerge net-misc/dhcpcd
rc-update add dhcpcd default
rc-update add sshd default

# Automatically rebuild out-of-tree NVIDIA modules on future kernel updates
emerge sys-kernel/module-rebuild
rc-update add modules-rebuild default

echo "Please set your root password:"
passwd

echo "Chroot setup complete. You can now type 'exit', unmount, and reboot!"
EOF

chmod +x /mnt/gentoo/root/chroot_setup.sh

# --- 7. Execution Hand-off ---
echo "================================================================"
echo "Gentoo environment successfully prepared!"
echo "Run the following commands to execute the chroot installation:"
echo "----------------------------------------------------------------"
echo "chroot /mnt/gentoo /bin/bash"
echo "source /etc/profile"
echo "/root/chroot_setup.sh"
echo "================================================================"