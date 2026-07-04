#!/usr/bin/env bash

set -euo pipefail

# --- CONFIGURATION ---
TARGET_DISK="/dev/sda"
ESP_PART="${TARGET_DISK}1"
ROOT_PART="${TARGET_DISK}2"
CHROOT_DIR="/mnt/gentoo"
STAGE3_URL="https://bouncer.gentoo.org/fetch/root/all/releases/amd64/autobuilds/current-stage3-amd64-desktop-systemd/"

if [ "$EUID" -ne 0 ]; then
    echo "Please run this script as root." >&2
    exit 1
fi

if [ ! -d "/sys/firmware/efi" ]; then
    echo "Error: System is not booted in UEFI mode!" >&2
    exit 1
fi

echo "=== Wiping disk and partitioning ${TARGET_DISK} ==="
blkdiscard -f "$TARGET_DISK" || true
wipefs -a "$TARGET_DISK"

sgdisk -o "$TARGET_DISK"
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"EFI System Partition" "$TARGET_DISK"
sgdisk -n 2:0:0   -t 2:8304 -c 2:"Gentoo Root" "$TARGET_DISK"
udevadm settle

echo "=== Formatting filesystems ==="
mkfs.vfat -F 32 "$ESP_PART"
mkfs.xfs -f "$ROOT_PART"

echo "=== Preparing Mount Points and Stage3 ==="
mkdir -p "$CHROOT_DIR"
mount "$ROOT_PART" "$CHROOT_DIR"
mkdir -p "$CHROOT_DIR/efi"
mount "$ESP_PART" "$CHROOT_DIR/efi"

cd "$CHROOT_DIR"
echo "Fetching latest Stage 3 systemd desktop tarball info..."
STAGE3_FILE=$(curl -s "$STAGE3_URL" | grep -oE 'stage3-amd64-desktop-systemd-[0-9TZ]+.tar.xz' | head -n 1)

if [ -z "$STAGE3_FILE" ]; then
    echo "Failed to resolve Stage 3 filename. Checking baseline fallback..."
    STAGE3_FILE=$(curl -s "${STAGE3_URL}" | grep -o 'stage3-amd64-desktop-systemd-[0-9]\+.*\.tar\.xz' | head -n 1)
fi

echo "Downloading ${STAGE3_FILE}..."
curl -O "${STAGE3_URL}${STAGE3_FILE}"
echo "Unpacking Stage 3..."
tar xpvf "$STAGE3_FILE" --xattrs-include='*.*' --numeric-owner
rm "$STAGE3_FILE"

echo "=== Copying DNS Configuration ==="
cp --dereference /etc/resolv.conf "$CHROOT_DIR/etc/resolv.conf"

echo "=== Tailoring make.conf for Pure Wayland & PipeWire ==="
cat << 'EOF' > "$CHROOT_DIR/etc/portage/make.conf"
COMMON_FLAGS="-O2 -pipe -march=native"
CFLAGS="${COMMON_FLAGS}"
CXXFLAGS="${COMMON_FLAGS}"
FCFLAGS="${COMMON_FLAGS}"
FFLAGS="${COMMON_FLAGS}"
MAKEOPTS="-j$(nproc)"
CHOST="x86_64-pc-linux-gnu"

# Clean global flags for a modern systemd + wayland + pipewire audio stack
USE="wayland pipewire gles2 vulkan systemd dbus unicode icu policykit pam -X -elogind -openrc -gnome -kde"

ACCEPT_LICENSE="*"
GRUB_PLATFORMS=""
L10N="en en-US"
VIDEO_CARDS="nvidia"
EOF

echo "=== Writing fstab ==="
cat << EOF > "$CHROOT_DIR/etc/fstab"
$ROOT_PART    /       xfs     noatime,defaults    0 0
$ESP_PART     /efi    vfat    defaults            0 2
EOF

echo "=== Executing Deployment inside the Chroot ==="
mount --types proc /proc "$CHROOT_DIR/proc"
mount --rbind /sys "$CHROOT_DIR/sys"
mount --make-rslave "$CHROOT_DIR/sys"
mount --rbind /dev "$CHROOT_DIR/dev"
mount --make-rslave "$CHROOT_DIR/dev"
mount --bind /run "$CHROOT_DIR/run"
mount --make-slave "$CHROOT_DIR/run"

# Inner script containing chroot commands
cat << 'CHROOT_EOF' > "$CHROOT_DIR/tmp/chroot_install.sh"
#!/bin/bash
set -euo pipefail
source /etc/profile
export PS1="(chroot) $PS1"

echo "=== Syncing Portage Repository ==="
emerge-webrsync

echo "=== Configuring Timezone, Locales, and Keymap ==="
echo "Europe/London" > /etc/timezone
ln -sf /usr/share/zoneinfo/Europe/London /etc/localtime

cat << 'LOCALE_EOF' > /etc/locale.gen
en_US.UTF-8 UTF-8
en_US ISO-8859-1
LOCALE_EOF

locale-gen

echo "LANG=\"en_US.UTF-8\"" > /etc/locale.conf
echo "LC_COLLATE=\"C.UTF-8\"" >> /etc/locale.conf

mkdir -p /etc/vconsole.conf
echo "KEYMAP=us" > /etc/vconsole.conf

echo "=== Initializing Systemd Machine ID ==="
systemd-machine-id-setup

echo "=== Target Package USE Flags Configuration ==="
mkdir -p /etc/portage/package.use

# Set installkernel features
echo "sys-kernel/installkernel efistub dracut systemd" >> /etc/portage/package.use/installkernel

# Configure nvidia-drivers to utilize the open source kernel module variant
echo "x11-drivers/nvidia-drivers kernel-open modules-sign driver video_cards_nvidia" >> /etc/portage/package.use/nvidia

echo "=== Hardcoding Kernel Command Line Parameters for EFISTUB ==="
mkdir -p /etc/kernel
echo "root=/dev/sda2 rw nvidia-drm.modeset=1" > /etc/kernel/cmdline

echo "=== Optimizing Dracut to Build Lean EFISTUB Images ==="
mkdir -p /etc/dracut.conf.d
cat << 'DRACUT_EOF' > /etc/dracut.conf.d/gentoo.conf
hostonly="yes"
compress="xz"
DRACUT_EOF

echo "=== Phase 1: Installing Firmware, Tools, & NVIDIA Modules ==="
emerge --ask=n sys-kernel/linux-firmware sys-boot/efibootmgr sys-kernel/installkernel sys-fs/xfsprogs x11-drivers/nvidia-drivers app-admin/sudo

echo "=== Phase 2: Building Kernel and Automating EFISTUB Generation ==="
emerge --ask=n sys-kernel/gentoo-kernel-bin

echo "=== Setting Passwords and Accounts ==="
echo "root:gentoo" | chpasswd

# Creating standard user account with proper groups for Wayland/seat management
useradd -m -G wheel,video,audio,render -s /bin/bash richard
echo "richard:gentoo" | chpasswd

echo "=== Configuring Sudo ==="
mkdir -p /etc/sudoers.d
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
# CRITICAL FIX: Sudo requires strict 0440 secure permissions or it will ignore the drop-in file entirely
chmod 0440 /etc/sudoers.d/wheel

echo "=== Configuring Networkd DHCP Profile ==="
mkdir -p /etc/systemd/network
cat << 'NET_EOF' > /etc/systemd/network/20-wired.network
[Match]
Name=en* eth*

[Network]
DHCP=yes
NET_EOF

echo "=== Systemd Post-Configuration Initialization ==="
systemctl enable systemd-networkd.service
systemctl enable systemd-resolved.service
systemctl enable nvidia-persistenced.service

echo "=== Installation complete inside the chroot! ==="
CHROOT_EOF

chmod +x "$CHROOT_DIR/tmp/chroot_install.sh"
chroot "$CHROOT_DIR" /tmp/chroot_install.sh
rm "$CHROOT_DIR/tmp/chroot_install.sh"

echo "=== Cleaning Up and Unmounting ==="
umount -l "$CHROOT_DIR/dev{/shm,/pts,}" || true
umount -R "$CHROOT_DIR"

echo "Gentoo base installation complete! You can now safely reboot your machine."
echo "Default passwords (root and richard): gentoo"
