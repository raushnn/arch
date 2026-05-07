#!/bin/bash

################################################################################
# Arch Linux Installation Script for Samsung T7 SSD
# Fixed EFI mount + robust GRUB install
################################################################################

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

################################################################################
# Configuration Variables - MODIFY THESE
################################################################################

DEVICE="/dev/sda"
ARCH_SIZE="256GiB"
EFI_SIZE="5GiB"

TIMEZONE="Asia/Kolkata"
HOSTNAME="archbox"
USERNAME="raushan"
LOCALE="en_US.UTF-8"

MOUNT_POINT="/mnt/archinstall"

################################################################################
# Step 0: Fix APT sources
################################################################################

echo -e "${GREEN}Step 0: Fixing APT repository issues...${NC}"

sudo sed -i '/cdrom:/d' /etc/apt/sources.list

sudo mkdir -p /etc/apt/sources.list.d.bak

sudo mv /etc/apt/sources.list.d/brave-browser-release.list \
/etc/apt/sources.list.d.bak/ 2>/dev/null || true

sudo mv /etc/apt/sources.list.d/brave-browser-beta.list \
/etc/apt/sources.list.d.bak/ 2>/dev/null || true

sudo mv /etc/apt/sources.list.d/wine.list \
/etc/apt/sources.list.d.bak/ 2>/dev/null || true

sudo apt update 2>&1 | grep -v "Skipping acquire" || true

################################################################################
# Safety Check
################################################################################

echo -e "${YELLOW}WARNING: This will COMPLETELY WIPE ${DEVICE}${NC}"
echo ""
lsblk ${DEVICE}
echo ""

read -p "Type YES to continue: " confirm

if [ "$confirm" != "YES" ]; then
    echo -e "${RED}Cancelled.${NC}"
    exit 1
fi

################################################################################
# UEFI Check
################################################################################

echo -e "${GREEN}Checking UEFI mode...${NC}"

if [ ! -d /sys/firmware/efi ]; then
    echo -e "${RED}ERROR: System not booted in UEFI mode!${NC}"
    echo "Boot your Linux live USB in UEFI mode and retry."
    exit 1
fi

################################################################################
# Step 1: Force unmount
################################################################################

echo -e "${GREEN}Step 1: Force unmounting...${NC}"

sudo umount -l ${DEVICE}* 2>/dev/null || true
sudo swapoff -a 2>/dev/null || true
sudo fuser -km ${DEVICE} 2>/dev/null || true

sleep 2

sudo umount -f ${DEVICE}* 2>/dev/null || true
sudo dmsetup remove_all 2>/dev/null || true

################################################################################
# Step 2: Create GPT partitions
################################################################################

echo -e "${GREEN}Step 2: Creating partitions...${NC}"

sudo wipefs --all --force ${DEVICE}

sudo parted ${DEVICE} --script \
    mklabel gpt \
    mkpart primary fat32 1MiB ${EFI_SIZE} \
    set 1 esp on \
    set 1 boot on \
    mkpart primary ext4 ${EFI_SIZE} ${ARCH_SIZE} \
    mkpart primary ext4 ${ARCH_SIZE} 100%

sleep 2

sudo partprobe ${DEVICE}

echo ""
echo "Partition layout:"
lsblk ${DEVICE}

################################################################################
# Step 3: Format partitions
################################################################################

echo -e "${GREEN}Step 3: Formatting...${NC}"

sudo mkfs.fat -F32 ${DEVICE}1
sudo mkfs.ext4 -F ${DEVICE}2

################################################################################
# Step 4: Mount partitions
################################################################################

echo -e "${GREEN}Step 4: Mounting partitions...${NC}"

sudo mkdir -p ${MOUNT_POINT}

sudo mount ${DEVICE}2 ${MOUNT_POINT}

sudo mkdir -p ${MOUNT_POINT}/boot/efi

sudo mount ${DEVICE}1 ${MOUNT_POINT}/boot/efi

echo ""
echo "Mounted filesystems:"
mount | grep ${DEVICE}

################################################################################
# Step 5: Install dependencies
################################################################################

echo -e "${GREEN}Step 5: Installing dependencies...${NC}"

sudo apt install -y \
    arch-install-scripts \
    wget \
    curl \
    zstd

################################################################################
# Step 6: Download Arch bootstrap
################################################################################

echo -e "${GREEN}Step 6: Downloading Arch bootstrap...${NC}"

cd /tmp

# Fetch latest bootstrap filename
BOOTSTRAP_FILE=$(curl -s https://mirrors.edge.kernel.org/archlinux/iso/latest/ \
| grep -oE 'archlinux-bootstrap-[0-9\.]+-x86_64\.tar\.zst' \
| head -n1)

if [ -z "$BOOTSTRAP_FILE" ]; then
    echo -e "${RED}Failed to fetch bootstrap filename.${NC}"
    echo "Trying fallback..."

    BOOTSTRAP_FILE="archlinux-bootstrap-$(date +%Y.%m.01)-x86_64.tar.zst"
fi

echo "Bootstrap file: $BOOTSTRAP_FILE"

if [ ! -f "$BOOTSTRAP_FILE" ]; then
    wget -c \
    "https://mirrors.edge.kernel.org/archlinux/iso/latest/${BOOTSTRAP_FILE}"
fi

echo "Extracting bootstrap..."

sudo tar -I zstd -xpf "$BOOTSTRAP_FILE" \
    -C ${MOUNT_POINT} \
    --strip-components=1

################################################################################
# Step 7: Configure pacman mirrors
################################################################################

echo -e "${GREEN}Step 7: Configuring pacman mirrors...${NC}"

sudo sed -i 's/^#Server/Server/' \
${MOUNT_POINT}/etc/pacman.d/mirrorlist

################################################################################
# Step 8: Mount virtual filesystems
################################################################################

echo -e "${GREEN}Step 8: Preparing chroot...${NC}"

sudo mount -t proc /proc ${MOUNT_POINT}/proc
sudo mount -t sysfs /sys ${MOUNT_POINT}/sys
sudo mount --rbind /dev ${MOUNT_POINT}/dev
sudo mount --rbind /dev/pts ${MOUNT_POINT}/dev/pts

echo "nameserver 8.8.8.8" | \
sudo tee ${MOUNT_POINT}/etc/resolv.conf

################################################################################
# Step 9: Install Arch base system
################################################################################

echo -e "${GREEN}Step 9: Installing base system...${NC}"

sudo chroot ${MOUNT_POINT} /bin/bash -c "

set -e

pacman-key --init
pacman-key --populate archlinux

pacman -Sy --noconfirm archlinux-keyring

pacman -Syu --noconfirm \
    base \
    linux \
    linux-firmware \
    nano \
    sudo \
    networkmanager \
    grub \
    efibootmgr

"

################################################################################
# Step 10: Generate fstab
################################################################################

echo -e "${GREEN}Step 10: Generating fstab...${NC}"

sudo genfstab -U ${MOUNT_POINT} | \
sudo tee ${MOUNT_POINT}/etc/fstab

################################################################################
# Step 11: System configuration
################################################################################

echo -e "${GREEN}Step 11: Configuring system...${NC}"

cat << 'CHROOT_SCRIPT' | sudo tee ${MOUNT_POINT}/tmp/configure.sh

#!/bin/bash

set -e

################################################################################
# Timezone
################################################################################

ln -sf /usr/share/zoneinfo/TIMEZONE_PLACEHOLDER /etc/localtime
hwclock --systohc

################################################################################
# Locale
################################################################################

echo "LOCALE_PLACEHOLDER UTF-8" >> /etc/locale.gen

locale-gen

echo "LANG=LOCALE_PLACEHOLDER" > /etc/locale.conf

################################################################################
# Hostname
################################################################################

echo "HOSTNAME_PLACEHOLDER" > /etc/hostname

cat > /etc/hosts << EOF
127.0.0.1 localhost
::1 localhost
127.0.1.1 HOSTNAME_PLACEHOLDER.localdomain HOSTNAME_PLACEHOLDER
EOF

################################################################################
# Root password
################################################################################

echo "root:root" | chpasswd

################################################################################
# User
################################################################################

useradd -m -G wheel -s /bin/bash USERNAME_PLACEHOLDER

echo "USERNAME_PLACEHOLDER:USERNAME_PLACEHOLDER" | chpasswd

################################################################################
# Sudo
################################################################################

sed -i \
's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' \
/etc/sudoers

################################################################################
# GRUB install
################################################################################

echo "Checking EFI mount..."

mkdir -p /boot/efi

if ! mount | grep -q "/boot/efi"; then

    echo "EFI not mounted. Attempting auto mount..."

    EFI_PART=$(blkid -t TYPE="vfat" -o device | head -n1)

    if [ -z "$EFI_PART" ]; then
        echo "No EFI partition found!"
        exit 1
    fi

    mount "$EFI_PART" /boot/efi
fi

echo "EFI mount:"
mount | grep efi || true

echo "Installing GRUB..."

grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --bootloader-id=ARCH \
    --removable

echo "Generating GRUB config..."

grub-mkconfig -o /boot/grub/grub.cfg

################################################################################
# Services
################################################################################

systemctl enable NetworkManager

echo "Configuration complete!"

CHROOT_SCRIPT

################################################################################
# Replace placeholders
################################################################################

sudo sed -i \
"s|TIMEZONE_PLACEHOLDER|${TIMEZONE}|g" \
${MOUNT_POINT}/tmp/configure.sh

sudo sed -i \
"s|LOCALE_PLACEHOLDER|${LOCALE}|g" \
${MOUNT_POINT}/tmp/configure.sh

sudo sed -i \
"s|HOSTNAME_PLACEHOLDER|${HOSTNAME}|g" \
${MOUNT_POINT}/tmp/configure.sh

sudo sed -i \
"s|USERNAME_PLACEHOLDER|${USERNAME}|g" \
${MOUNT_POINT}/tmp/configure.sh

################################################################################
# Execute configuration
################################################################################

sudo chmod +x ${MOUNT_POINT}/tmp/configure.sh

sudo chroot ${MOUNT_POINT} /tmp/configure.sh

################################################################################
# Step 12: Cleanup
################################################################################

echo -e "${GREEN}Step 12: Cleanup...${NC}"

sudo umount -R ${MOUNT_POINT}/dev/pts 2>/dev/null || true
sudo umount -R ${MOUNT_POINT}/dev 2>/dev/null || true
sudo umount -R ${MOUNT_POINT}/sys 2>/dev/null || true
sudo umount -R ${MOUNT_POINT}/proc 2>/dev/null || true

sudo umount ${MOUNT_POINT}/boot/efi 2>/dev/null || true
sudo umount ${MOUNT_POINT} 2>/dev/null || true

################################################################################
# Complete
################################################################################

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN} Installation Complete! ${NC}"
echo -e "${GREEN}========================================${NC}"

echo ""
echo "Boot device: ${DEVICE}"
echo "EFI partition: ${DEVICE}1"
echo "Root partition: ${DEVICE}2"

echo ""
echo "Username: ${USERNAME}"
echo "Password: ${USERNAME}"
echo "Root password: root"

echo ""
echo -e "${RED}Change passwords after first login.${NC}"

echo ""
echo "Reboot and boot from the Samsung T7 SSD."
echo ""
echo -e "${GREEN}Happy Arching 🚀${NC}"
