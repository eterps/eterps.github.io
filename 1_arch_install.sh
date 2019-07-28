#!/bin/bash
set -e

encryption_passphrase="letmein"
root_password="letmein"
user_password="letmein"
hostname="archhost"
user_name="arch"
continent_city="Europe/Amsterdam"
swap_size="2"                       # should be 20 for a 16GB machine with hibernation: https://itsfoss.com/swap-size/
disk="/dev/sda"                     # e.g. /dev/sda, /dev/nvme0n1
boot_partition="/dev/sda1"          # e.g. /dev/sda1, /dev/nvme0n1p1
root_partition="/dev/sda2"

echo "Updating system clock"
timedatectl set-ntp true

echo "Creating partition tables"
printf "n\n1\n4096\n+512M\nef00\nw\ny\n" | gdisk $disk
printf "n\n2\n\n\n8e00\nw\ny\n" | gdisk $disk

echo "Zeroing partitions"
set +e
cat /dev/zero > $boot_partition
cat /dev/zero > $root_partition
set -e

echo "Building EFI filesystem"
yes | mkfs.fat -F32 $boot_partition

echo "Setting up cryptographic volume"
printf "%s" "$encryption_passphrase" | cryptsetup -c aes-xts-plain64 -h sha512 -s 512 --use-random --type luks2 --label LVMPART luksFormat $root_partition
printf "%s" "$encryption_passphrase" | cryptsetup luksOpen $root_partition cryptoVols

echo "Setting up LVM"
pvcreate /dev/mapper/cryptoVols
vgcreate Arch /dev/mapper/cryptoVols
lvcreate -L +"$swap_size"GB Arch -n swap
lvcreate -l +100%FREE Arch -n root

echo "Building filesystems for root and swap"
yes | mkswap /dev/mapper/Arch-swap
yes | mkfs.ext4 /dev/mapper/Arch-root

echo "Mounting root/boot and enabling swap"
mount /dev/mapper/Arch-root /mnt
mkdir /mnt/boot
mount $boot_partition /mnt/boot
swapon /dev/mapper/Arch-swap

echo "Installing Arch Linux"
yes '' | pacstrap /mnt base base-devel intel-ucode networkmanager wget reflector refind-efi

echo "Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab

echo "Configuring new system"
arch-chroot /mnt /bin/bash <<EOF
echo "Setting system clock"
ln -fs /usr/share/zoneinfo/$continent_city /etc/localtime
hwclock --systohc --localtime

echo "Setting locales"
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
echo "LANG=en_US.UTF-8" >> /etc/locale.conf
locale-gen

echo "Setting hostname"
echo $hostname > /etc/hostname

echo "Setting root password"
echo -en "$root_password\n$root_password" | passwd

echo "Creating new user"
useradd -m -G wheel -s /bin/bash $user_name
echo -en "$user_password\n$user_password" | passwd $user_name

echo "Generating initramfs"
sed -i 's/^HOOKS.*/HOOKS=(base udev keyboard autodetect modconf block keymap encrypt lvm2 resume filesystems fsck)/' /etc/mkinitcpio.conf
sed -i 's/^MODULES.*/MODULES=(ext4 intel_agp i915)/' /etc/mkinitcpio.conf
mkinitcpio -p linux

echo "Enabling autologin"
mkdir -p  /etc/systemd/system/getty@tty1.service.d/
touch /etc/systemd/system/getty@tty1.service.d/override.conf
tee -a /etc/systemd/system/getty@tty1.service.d/override.conf << END
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin $user_name --noclear %I $TERM
END

echo "Updating mirrors list"
cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.org
reflector --latest 200 --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

touch /etc/pacman.d/hooks/mirrors-update.hook
tee -a /etc/pacman.d/hooks/mirrors-update.hook << END
[Trigger]
Operation = Upgrade
Type = Package
Target = pacman-mirrorlist

[Action]
Description = Updating pacman-mirrorlist with reflector
When = PostTransaction
Depends = reflector
Exec = /bin/sh -c "reflector --latest 200 --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist"
END

echo "Enabling periodic TRIM"
systemctl enable fstrim.timer

echo "Enabling NetworkManager"
systemctl enable NetworkManager

echo "Adding user as a sudoer"
echo '%wheel ALL=(ALL) ALL' | EDITOR='tee -a' visudo

echo "Setup rEFInd"
mkdir -p /boot/EFI/BOOT
cp /usr/share/refind/refind_x64.efi /boot/EFI/BOOT/bootx64.efi
tee -a /boot/refind_linux.conf << END
"Boot with standard options"  "cryptdevice=LABEL=LVMPART:cryptoVols root=/dev/mapper/Arch-root resume=/dev/mapper/Arch-swap quiet rw"
END
EOF

umount -R /mnt
swapoff -a

echo "ArchLinux is ready. You can reboot now!"
