#!/bin/sh -e

CHROOT=${CHROOT=$(pwd)/rootfs}

# Dọn dẹp môi trường cũ
rm -f emmc_full.raw files/emmc_full.bin
mkdir -p mnt_boot mnt_rootfs files

# 1. Tạo file raw tạm thời (2GB)
echo "Tạo file đĩa ảo 2GB..."
truncate -s 2G emmc_full.raw

# 2. Ghi bảng phân vùng GPT vào Block 0
echo "Định dạng bảng phân vùng GPT..."
parted -s emmc_full.raw mklabel gpt
parted -s emmc_full.raw mkpart primary ext2 1MiB 65MiB
parted -s emmc_full.raw mkpart primary ext4 65MiB 100%

# 3. Ánh xạ vào loop device
echo "Ánh xạ vào loop device..."
LOOPDEV=$(sudo losetup -P -f --show emmc_full.raw)

BOOT_PART="${LOOPDEV}p1"
ROOTFS_PART="${LOOPDEV}p2"

# 4. Format các phân vùng
echo "Format các phân vùng..."
sudo mkfs.ext2 $BOOT_PART
sudo mkfs.ext4 $ROOTFS_PART

# 5. Mount và chép dữ liệu
echo "Đang chép dữ liệu boot và rootfs..."
sudo mount $BOOT_PART mnt_boot
sudo mount $ROOTFS_PART mnt_rootfs

sudo tar xf rootfs.tgz -C mnt_boot ./boot --exclude='./boot/linux.efi' --strip-components=2
sudo tar xpf rootfs.tgz -C mnt_rootfs --exclude='./boot/*' --exclude='./root/*' --exclude='./dev/*'

if [ -d "dist" ]; then
    sudo cp -a dist/* mnt_rootfs/
fi

# 6. Unmount và gỡ block device ảo
echo "Gỡ kết nối ổ đĩa ảo..."
sudo umount mnt_boot mnt_rootfs
sudo losetup -d $LOOPDEV

# 7. Đóng gói thành file .bin (Định dạng Android Sparse Image)
echo "Đang nén thành file emmc_full.bin..."
img2simg emmc_full.raw files/emmc_full.bin

# Dọn dẹp file raw tạm thời
rm -f emmc_full.raw

echo "Đã đóng gói thành công files/emmc_full.bin!"
