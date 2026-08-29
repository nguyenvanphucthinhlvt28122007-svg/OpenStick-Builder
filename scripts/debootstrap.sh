#!/bin/sh -e

# Lưu đường dẫn thư mục làm việc hiện tại
BUILD_DIR=$(pwd)

CHROOT=${CHROOT=$(pwd)/rootfs}
RELEASE=${RELEASE=stable}
HOST_NAME=${HOST_NAME=openstick-debian}

rm -rf ${CHROOT}

debootstrap --foreign --arch arm64 \
    --keyring /usr/share/keyrings/debian-archive-keyring.gpg ${RELEASE} ${CHROOT}

cp $(which qemu-aarch64-static) ${CHROOT}/usr/bin

chroot ${CHROOT} qemu-aarch64-static /bin/bash /debootstrap/debootstrap --second-stage

cat << EOF > ${CHROOT}/etc/apt/sources.list
deb http://deb.debian.org/debian ${RELEASE} main contrib non-free-firmware
deb http://deb.debian.org/debian-security/ ${RELEASE}-security main contrib non-free-firmware
deb http://deb.debian.org/debian ${RELEASE}-updates main contrib non-free-firmware
EOF

mount -t proc proc ${CHROOT}/proc/
mount -t sysfs sys ${CHROOT}/sys/
mount -o bind /dev/ ${CHROOT}/dev/
mount -o bind /dev/pts/ ${CHROOT}/dev/pts/
mount -o bind /run ${CHROOT}/run/

cp scripts/setup.sh ${CHROOT}
chroot ${CHROOT} qemu-aarch64-static /bin/sh -c /setup.sh

# ================================================================
# BUILD KERNEL TỪ SOURCE (trên host)
# ================================================================

# Cài đặt công cụ build (nếu thiếu)
apt-get update
apt-get install -y build-essential git bc kmod cpio flex libncurses5-dev \
    libelf-dev libssl-dev dwarves bison fakeroot debhelper gcc-aarch64-linux-gnu

# Clone source kernel (chỉ lấy commit mới nhất)
git clone --depth 1 https://github.com/dann2333/MSM8916-openstick-linux-kernel.git /tmp/kernel-src
cd /tmp/kernel-src

# Thiết lập biến môi trường cho cross-compile
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-

# Cấu hình kernel (dùng config chung cho MSM8916)
make msm8916_defconfig

# (Tùy chọn) Bật thêm module USB_ACM nếu chưa có
# echo 'CONFIG_USB_ACM=y' >> .config && make olddefconfig

# Build kernel và tạo các gói .deb
make -j$(nproc) bindeb-pkg

# Copy các file .deb vừa tạo vào thư mục tạm trong rootfs
mkdir -p ${CHROOT}/tmp/debs
cp /tmp/linux-*.deb ${CHROOT}/tmp/debs/

# Dọn dẹp source
cd /
rm -rf /tmp/kernel-src

# QUAY LẠI THƯ MỤC LÀM VIỆC BAN ĐẦU
cd ${BUILD_DIR}

# ================================================================
# TIẾP TỤC CÁC CẤU HÌNH CÒN LẠI
# ================================================================

# Cài đặt kernel vào hệ thống (trong chroot)
echo "Đang cài đặt kernel tự build..."
chroot ${CHROOT} qemu-aarch64-static /bin/bash -c "dpkg -i /tmp/debs/*.deb || true"
chroot ${CHROOT} qemu-aarch64-static /bin/bash -c "apt --fix-broken install -y"

# Dọn dẹp file .deb trong rootfs
rm -rf ${CHROOT}/tmp/debs

# clean mounts (lần đầu - đảm bảo unmount trước khi tiếp tục)
for a in proc sys dev/pts dev run; do
    umount ${CHROOT}/${a} 2>/dev/null || true
done;

rm -f ${CHROOT}/setup.sh
echo -n > ${CHROOT}/root/.bash_history

echo ${HOST_NAME} > ${CHROOT}/etc/hostname
sed -i "/localhost/ s/$/ ${HOST_NAME}/" ${CHROOT}/etc/hosts

# setup systemd services (chỉ copy nếu thư mục tồn tại và không rỗng)
if [ -d configs/system ] && [ -n "$(ls -A configs/system 2>/dev/null)" ]; then
    cp -a configs/system/* ${CHROOT}/etc/systemd/system
fi

if [ -f scripts/msm-firmware-loader.sh ]; then
    cp -a scripts/msm-firmware-loader.sh ${CHROOT}/usr/sbin
fi

# setup NetworkManager
if [ -d configs ] && [ -n "$(ls configs/*.nmconnection 2>/dev/null)" ]; then
    cp configs/*.nmconnection ${CHROOT}/etc/NetworkManager/system-connections
    chmod 0600 ${CHROOT}/etc/NetworkManager/system-connections/*
fi
sed -i '/\[main\]/a dns=dnsmasq' ${CHROOT}/etc/NetworkManager/NetworkManager.conf

# enable autoconnect for usb0
cat << EOF > ${CHROOT}/etc/udev/rules.d/99-nm-usb0.rules
SUBSYSTEM=="net", ACTION=="add|change|move", ENV{DEVTYPE}=="gadget", ENV{NM_UNMANAGED}="0"
EOF

# Tạo thư mục boot và copy extlinux.conf
mkdir -p ${CHROOT}/boot/extlinux
if [ -f configs/extlinux.conf ]; then
    cp configs/extlinux.conf ${CHROOT}/boot/extlinux
fi

# Tạo thư mục dtbs và copy các dtb tùy chỉnh (nếu có)
mkdir -p ${CHROOT}/boot/dtbs/qcom
if [ -d dtbs ] && [ -n "$(ls -A dtbs 2>/dev/null)" ]; then
    cp dtbs/* ${CHROOT}/boot/dtbs/qcom
fi

# Tạo thư mục firmware
mkdir -p ${CHROOT}/lib/firmware/msm-firmware-loader

# Cập nhật fstab
echo "PARTUUID=80780b1d-0fe1-27d3-23e4-9244e62f8c46\t/boot\text2\tdefaults\t0 2" > ${CHROOT}/etc/fstab

# Unmount các mount còn sót (lần cuối)
for a in proc sys dev/pts dev run; do
    umount ${CHROOT}/${a} 2>/dev/null || true
done;

# Backup rootfs (lúc này đã ở đúng thư mục BUILD_DIR)
tar cpzf rootfs.tgz --exclude="usr/bin/qemu-aarch64-static" -C rootfs .
