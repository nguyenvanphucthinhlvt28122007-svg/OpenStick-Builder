#!/bin/sh -e

# Lưu đường dẫn thư mục làm việc hiện tại
BUILD_DIR=$(pwd)

CHROOT=${CHROOT=$(pwd)/rootfs}
RELEASE=${RELEASE=stable}
HOST_NAME=${HOST_NAME=openstick-debian}

echo "=== Dọn dẹp môi trường cũ ==="
rm -rf ${CHROOT}

debootstrap --foreign --arch arm64 \
    --keyring /usr/share/keyrings/debian-archive-keyring.gpg ${RELEASE} ${CHROOT}

cp $(which qemu-aarch64-static) ${CHROOT}/usr/bin

echo "=== Đang chạy debootstrap second-stage ==="
chroot ${CHROOT} /usr/bin/qemu-aarch64-static /bin/bash /debootstrap/debootstrap --second-stage

cat << EOF > ${CHROOT}/etc/apt/sources.list
deb http://deb.debian.org/debian ${RELEASE} main contrib non-free-firmware
deb http://deb.debian.org/debian-security/ ${RELEASE}-security main contrib non-free-firmware
deb http://deb.debian.org/debian ${RELEASE}-updates main contrib non-free-firmware
EOF

# Sửa lỗi DNS trong chroot
cp /etc/resolv.conf ${CHROOT}/etc/resolv.conf

mount -t proc proc ${CHROOT}/proc/
mount -t sysfs sys ${CHROOT}/sys/
mount -o bind /dev/ ${CHROOT}/dev/
mount -o bind /dev/pts/ ${CHROOT}/dev/pts/
mount -o bind /run ${CHROOT}/run/

cp scripts/setup.sh ${CHROOT}
# Chạy trực tiếp setup.sh an toàn hơn
chroot ${CHROOT} /usr/bin/qemu-aarch64-static /bin/sh /setup.sh

# ================================================================
# BUILD KERNEL TỪ SOURCE (trên host)
# ================================================================

apt-get update
apt-get install -y build-essential git bc kmod cpio flex libncurses5-dev \
    libelf-dev libssl-dev dwarves bison fakeroot debhelper gcc-aarch64-linux-gnu

echo "=== Chuẩn bị mã nguồn Kernel ==="
# Cô lập thư mục build để tránh kẹt file cũ ở các lần chạy sau
KERNEL_BUILD_DIR="/tmp/openstick_kernel_build"
rm -rf ${KERNEL_BUILD_DIR}
mkdir -p ${KERNEL_BUILD_DIR}

git clone --depth 1 https://github.com/dann2333/MSM8916-openstick-linux-kernel.git ${KERNEL_BUILD_DIR}/src
cd ${KERNEL_BUILD_DIR}/src

export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-

make msm8916_defconfig
make -j$(nproc) bindeb-pkg

mkdir -p ${CHROOT}/tmp/debs
# bindeb-pkg xuất file .deb ra thư mục cha của source
cp ${KERNEL_BUILD_DIR}/*.deb ${CHROOT}/tmp/debs/

# Dọn dẹp source
cd /
rm -rf ${KERNEL_BUILD_DIR}

cd ${BUILD_DIR}

# ================================================================
# TIẾP TỤC CÁC CẤU HÌNH CÒN LẠI
# ================================================================

echo "=== Đang cài đặt kernel tự build vào rootfs ==="
chroot ${CHROOT} /usr/bin/qemu-aarch64-static /bin/bash -c "dpkg -i /tmp/debs/*.deb || true"
chroot ${CHROOT} /usr/bin/qemu-aarch64-static /bin/bash -c "apt-get --fix-broken install -y"

rm -rf ${CHROOT}/tmp/debs
rm -f ${CHROOT}/setup.sh
echo -n > ${CHROOT}/root/.bash_history

echo ${HOST_NAME} > ${CHROOT}/etc/hostname
sed -i "/localhost/ s/$/ ${HOST_NAME}/" ${CHROOT}/etc/hosts

if [ -d configs/system ] && [ -n "$(ls -A configs/system 2>/dev/null)" ]; then
    cp -a configs/system/* ${CHROOT}/etc/systemd/system
fi

if [ -f scripts/msm-firmware-loader.sh ]; then
    cp -a scripts/msm-firmware-loader.sh ${CHROOT}/usr/sbin
fi

if [ -d configs ] && [ -n "$(ls configs/*.nmconnection 2>/dev/null)" ]; then
    cp configs/*.nmconnection ${CHROOT}/etc/NetworkManager/system-connections
    chmod 0600 ${CHROOT}/etc/NetworkManager/system-connections/*
fi

# Phải kiểm tra file config có tồn tại trước khi dùng sed
if [ -f ${CHROOT}/etc/NetworkManager/NetworkManager.conf ]; then
    sed -i '/\[main\]/a dns=dnsmasq' ${CHROOT}/etc/NetworkManager/NetworkManager.conf
fi

cat << EOF > ${CHROOT}/etc/udev/rules.d/99-nm-usb0.rules
SUBSYSTEM=="net", ACTION=="add|change|move", ENV{DEVTYPE}=="gadget", ENV{NM_UNMANAGED}="0"
EOF

mkdir -p ${CHROOT}/boot/extlinux
if [ -f configs/extlinux.conf ]; then
    cp configs/extlinux.conf ${CHROOT}/boot/extlinux
fi

mkdir -p ${CHROOT}/boot/dtbs/qcom
if [ -d dtbs ] && [ -n "$(ls -A dtbs 2>/dev/null)" ]; then
    cp dtbs/* ${CHROOT}/boot/dtbs/qcom
fi

mkdir -p ${CHROOT}/lib/firmware/msm-firmware-loader

echo "=== Cập nhật fstab ==="
# Sửa lỗi ký tự \t bằng khoảng trắng tiêu chuẩn
echo "PARTUUID=80780b1d-0fe1-27d3-23e4-9244e62f8c46 /boot ext2 defaults 0 2" > ${CHROOT}/etc/fstab

echo "=== Unmount các phân vùng ảo ==="
for a in dev/pts dev proc sys run; do
    umount ${CHROOT}/${a} 2>/dev/null || true
done;

echo "=== Nén rootfs ==="
tar cpzf rootfs.tgz --exclude="usr/bin/qemu-aarch64-static" -C rootfs .
echo "Hoàn tất tạo rootfs.tgz!"
