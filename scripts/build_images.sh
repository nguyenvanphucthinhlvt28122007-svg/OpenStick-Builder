#!/bin/sh -e

CHROOT=${CHROOT=$(pwd)/rootfs}

# Dọn dẹp môi trường cũ
rm -f files/emmc_full_raw.bin
mkdir -p mnt_boot mnt_rootfs files

# 1. Tạo file đĩa ảo nguyên khối (RAW) dung lượng 2GB
echo "Tạo file RAW 2GB..."
truncate -s 2G files/emmc_full_raw.bin

# 2. Ghi bảng phân vùng GPT và chia phân vùng bắt đầu từ Block 0
echo "Tạo bảng phân vùng GPT..."
parted -s files/emmc_full_raw.bin mklabel gpt

# Phân vùng boot: 64MB (Từ 1MiB đến 65MiB)
parted -s files/emmc_full_raw.bin mkpart primary ext2 1MiB 65MiB

# Phân vùng rootfs: Từ 65MiB đến hết 2GB
parted -s files/emmc_full_raw.bin mkpart primary ext4 65MiB 100%

# 3. Ánh xạ file RAW thành ổ cứng ảo để hệ điều hành nhận diện
echo "Ánh xạ vào loop device..."
LOOPDEV=$(sudo losetup -P -f --show files/emmc_full_raw.bin)

BOOT_PART="${LOOPDEV}p1"
ROOTFS_PART="${LOOPDEV}p2"

# 4. Format các phân vùng
echo "Định dạng các phân vùng (ext2 cho boot, ext4 cho rootfs)..."
sudo mkfs.ext2 $BOOT_PART
sudo mkfs.ext4 $ROOTFS_PART

# 5. Mount và bung file rootfs.tgz vào đúng phân vùng
echo "Đang bung dữ liệu..."
sudo mount $BOOT_PART mnt_boot
sudo mount $ROOTFS_PART mnt_rootfs

# Bung boot
sudo tar xf rootfs.tgz -C mnt_boot ./boot --exclude='./boot/linux.efi' --strip-components=2

# Bung rootfs
sudo tar xpf rootfs.tgz -C mnt_rootfs --exclude='./boot/*' --exclude='./root/*' --exclude='./dev/*'

# Cài đặt gt (nếu có thư mục dist)
if [ -d "dist" ]; then
    sudo cp -a dist/* mnt_rootfs/
fi

# 6. Unmount, dọn dẹp và ngắt kết nối ổ đĩa ảo
echo "Hoàn tất, đang gỡ kết nối..."
sudo umount mnt_boot mnt_rootfs
sudo losetup -d $LOOPDEV
rmdir mnt_boot mnt_rootfs

echo "Đã tạo thành công files/emmc_full_raw.bin!"
echo "Hãy dùng file này chọn vào mục Emmc Data để nạp bằng Miko."
