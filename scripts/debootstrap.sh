#!/bin/sh -e

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

# cleanup
for a in proc sys dev/pts dev run; do
    umount ${CHROOT}/${a}
done;

rm -f ${CHROOT}/setup.sh
echo -n > ${CHROOT}/root/.bash_history

echo ${HOST_NAME} > ${CHROOT}/etc/hostname
sed -i "/localhost/ s/$/ ${HOST_NAME}/" ${CHROOT}/etc/hosts

# setup systemd services
cp -a configs/system/* ${CHROOT}/etc/systemd/system

cp -a scripts/msm-firmware-loader.sh ${CHROOT}/usr/sbin

# setup NetworkManager
cp configs/*.nmconnection ${CHROOT}/etc/NetworkManager/system-connections
chmod 0600 ${CHROOT}/etc/NetworkManager/system-connections/*
sed -i '/\[main\]/a dns=dnsmasq' ${CHROOT}/etc/NetworkManager/NetworkManager.conf

# enable autoconnect for usb0
cat << EOF > ${CHROOT}/etc/udev/rules.d/99-nm-usb0.rules
SUBSYSTEM=="net", ACTION=="add|change|move", ENV{DEVTYPE}=="gadget", ENV{NM_UNMANAGED}="0"
EOF

# ============================================================
# PHẦN ĐÃ SỬA: Cài kernel tự build (thay vì tải từ postmarketOS)
# ============================================================

# Tạo thư mục chứa các file deb
mkdir -p ${CHROOT}/tmp/debs

# Tải 4 file .deb từ Google Drive về thư mục tạm trong rootfs
echo "Đang tải kernel tự build từ Google Drive..."
wget --no-check-certificate "https://drive.google.com/uc?id=11UzsgVXx2Mtv458dAM6f9D47WBH2pt-k&export=download&confirm=t" -O ${CHROOT}/tmp/debs/linux-image-5.15.0-handsomekernel+_5.15.0-handsomekernel+-1_arm64.deb
wget --no-check-certificate "https://drive.google.com/uc?id=16IorhDrvNJBXkgiJatVyEITejLbDGVYL&export=download&confirm=t" -O ${CHROOT}/tmp/debs/linux-libc-dev_5.15.0-handsomekernel+-1_arm64.deb
wget --no-check-certificate "https://drive.google.com/uc?id=1uhdihOJdlTyEXtdm7WMw95baJ2Qj9pJv" -O ${CHROOT}/tmp/debs/linux-headers-5.15.0-handsomekernel+_5.15.0-handsomekernel+-1_arm64.deb
wget --no-check-certificate "https://drive.google.com/uc?id=1gt8sfv7MDXY3wBTdqOfNbgKNcmyIYNnT&export=download&confirm=t" -O ${CHROOT}/tmp/debs/linux-image-5.15.0-handsomekernel+-dbg_5.15.0-handsomekernel+-1_arm64.deb

# Cài đặt các file .deb bên trong chroot
echo "Đang cài đặt kernel tự build..."
chroot ${CHROOT} qemu-aarch64-static /bin/bash -c "dpkg -i /tmp/debs/*.deb || true"
chroot ${CHROOT} qemu-aarch64-static /bin/bash -c "apt --fix-broken install -y"

# Dọn dẹp file .deb sau khi cài
rm -rf ${CHROOT}/tmp/debs

# ============================================================
# TIẾP TỤC PHẦN CÒN LẠI CỦA SCRIPT (không thay đổi)
# ============================================================

mkdir -p ${CHROOT}/boot/extlinux
cp configs/extlinux.conf ${CHROOT}/boot/extlinux

# copy custom dtb's
cp dtbs/* ${CHROOT}/boot/dtbs/qcom

# create missing directory
mkdir -p ${CHROOT}/lib/firmware/msm-firmware-loader

# update fstab
echo "PARTUUID=80780b1d-0fe1-27d3-23e4-9244e62f8c46\t/boot\text2\tdefaults\t0 2" > ${CHROOT}/etc/fstab

# backup rootfs
tar cpzf rootfs.tgz --exclude="usr/bin/qemu-aarch64-static" -C rootfs .
