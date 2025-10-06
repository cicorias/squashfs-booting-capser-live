#!/usr/bin/env bash
set -euo pipefail

set -x

# Required packages
# sudo apt-get install -y mmdebstrap squashfs-tools grub-efi-amd64-bin dosfstools e2fsprogs gdisk qemu-utils kpartx rsync xz-utils mount parted ovmf

# ---------------- Tunables ---------------------------------------------------
DIST=${DIST:-noble}
MIRROR=${MIRROR:-http://archive.ubuntu.com/ubuntu}

IMG=${IMG:-ubuntu-${DIST}-uefi-4part.img}
VHDX=${VHDX:-ubuntu-${DIST}-uefi-4part.vhdx}

ESP_MIB=${ESP_MIB:-512}
MAIN_MIB=${MAIN_MIB:-3072}
SWAP_MIB=${SWAP_MIB:-512}
TOTAL_MIB=${TOTAL_MIB:-0}

HOSTNAME=${HOSTNAME:-ubulive}
ROOTPWD=${ROOTPWD:-root}
LIVE_DIR=casper
# ---------------------------------------------------------------------------

workdir="$(pwd)/work-casper"
rootfs="${workdir}/rootfs"
mnt="${workdir}/mnt"
esp="${workdir}/esp"
data_mnt="${workdir}/data"
squash="${workdir}/filesystem.squashfs"

deps() {
  local miss=0
  for cmd in sudo mmdebstrap mksquashfs sfdisk losetup mkfs.vfat mkfs.ext4 mkswap mount umount grub-install qemu-img; do
    if ! command -v "$cmd" &>/dev/null; then
      echo "Missing dependency: $cmd"
      miss=1
    fi
  done
  (( miss == 0 )) || exit 1
}

cleanup() {
  set +e
  for d in "${esp}" "${data_mnt}" "${mnt}"; do
    if mountpoint -q "$d"; then
      sudo umount -R "$d" || true
    fi
  done
  [[ -n "${LOOPDEV:-}" && -e "${LOOPDEV}" ]] && sudo losetup -d "${LOOPDEV}" || true
}

echo "[1/10] Prepare workspace"

deps

echo "Requesting sudo credentials (needed for loop setup, mounts, and image writes)"
sudo -v
trap cleanup EXIT

sudo rm -rf "${workdir}"
mkdir -p "${workdir}" "${rootfs}" "${mnt}" "${esp}" "${data_mnt}"

echo "[2/10] Bootstrap Ubuntu ${DIST} with mmdebstrap"
sudo mmdebstrap --variant=minbase \
  --include=linux-image-generic,casper,squashfs-tools,ca-certificates,iproute2,iputils-ping,net-tools,less,vim,ubuntu-standard,initramfs-tools,console-setup,keyboard-configuration \
  --components="main restricted universe multiverse" \
  "${DIST}" "${rootfs}" \
  "${MIRROR}"

# Set up basic filesystem structure
sudo mkdir -p "${rootfs}/dev" "${rootfs}/proc" "${rootfs}/sys" "${rootfs}/run" "${rootfs}/tmp" "${rootfs}/etc" "${rootfs}/var"
sudo chmod 1777 "${rootfs}/tmp"

# Create essential subdirectories that must exist in squashfs
sudo mkdir -p "${rootfs}/dev/pts" "${rootfs}/dev/shm"

# Create minimal device nodes that must exist in squashfs
sudo mknod -m 666 "${rootfs}/dev/null" c 1 3 2>/dev/null || true
sudo mknod -m 666 "${rootfs}/dev/zero" c 1 5 2>/dev/null || true
sudo mknod -m 666 "${rootfs}/dev/random" c 1 8 2>/dev/null || true
sudo mknod -m 666 "${rootfs}/dev/urandom" c 1 9 2>/dev/null || true
sudo mknod -m 666 "${rootfs}/dev/tty" c 5 0 2>/dev/null || true
sudo mknod -m 666 "${rootfs}/dev/console" c 5 1 2>/dev/null || true
sudo mknod -m 666 "${rootfs}/dev/ptmx" c 5 2 2>/dev/null || true

sudo touch "${rootfs}/etc/fstab"  # Minimal fstab to avoid errors
sudo tee "${rootfs}/etc/fstab" >/dev/null <<EOF
# /etc/fstab: static file system information.
proc            /proc           proc    defaults        0       0
sysfs           /sys            sysfs   defaults        0       0
devtmpfs        /dev            devtmpfs defaults        0       0
tmpfs           /run            tmpfs   defaults        0       0
EOF

printf '%s\n' "${HOSTNAME}" | sudo tee "${rootfs}/etc/hostname" >/dev/null
sudo tee "${rootfs}/etc/hosts" >/dev/null <<EOF
127.0.0.1   localhost
127.0.1.1   ${HOSTNAME}
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF
sudo chroot "${rootfs}" bash -lc "echo 'root:${ROOTPWD}' | chpasswd"

# Configure initramfs to include casper hooks
# Configure initramfs to include casper hooks and set compression
sudo chroot "${rootfs}" bash -lc "echo 'COMPRESS=xz' >> /etc/initramfs-tools/initramfs.conf"
sudo chroot "${rootfs}" bash -lc "echo 'MODULES=most' >> /etc/initramfs-tools/initramfs.conf"
sudo chroot "${rootfs}" bash -lc "update-initramfs -u -k all"

echo "[2.5/10] Copy pager.sh and boot log viewer to rootfs"
sudo cp -v pager.sh "${rootfs}/usr/local/bin/pager.sh"
sudo chmod +x "${rootfs}/usr/local/bin/pager.sh"
sudo tee "${rootfs}/usr/local/bin/view-boot-log.sh" >/dev/null <<'VIEWLOG'
#!/bin/bash
echo "=== Boot Log Viewer ==="
if [ -f /var/log/boot.log ]; then
    /usr/local/bin/pager.sh /var/log/boot.log
elif [ -f /boot.log ]; then
    /usr/local/bin/pager.sh /boot.log
else
    echo "No boot log found. Trying dmesg..."
    dmesg | less
fi
VIEWLOG
sudo chmod +x "${rootfs}/usr/local/bin/view-boot-log.sh"

echo "[3/10] Locate kernel & initrd"
KERNEL="$(readlink -f "${rootfs}"/boot/vmlinuz-*)"
INITRD="$(readlink -f "${rootfs}"/boot/initrd.img-*)"
test -f "${KERNEL}" && test -f "${INITRD}"

echo "[4/10] Build squashfs"
sudo mksquashfs "${rootfs}" "${squash}" -comp xz -wildcards \
  -e 'proc/*' 'sys/*' 'dev/*' 'run/*' 'tmp/*' 'var/tmp/*' 'var/cache/apt/archives/*'
sudo chown "$(id -u)":"$(id -g)" "${squash}"

echo "[5/10] Create GPT image and partitions"
if (( TOTAL_MIB > 0 )); then
  truncate -s "${TOTAL_MIB}M" "${IMG}"
else
  truncate -s $((ESP_MIB + MAIN_MIB + SWAP_MIB + 2048))M "${IMG}"
fi

sfdisk "${IMG}" <<EOF
label: gpt
,${ESP_MIB}MiB,U,*
,${MAIN_MIB}MiB,L
,${SWAP_MIB}MiB,S
,,L
EOF

echo "[6/10] Map loop and make filesystems"
LOOPDEV="$(sudo losetup --show --partscan -f "${IMG}")"
P1="${LOOPDEV}p1"  # ESP
P2="${LOOPDEV}p2"  # Main OS
P3="${LOOPDEV}p3"  # Swap
P4="${LOOPDEV}p4"  # Data (persistence)

sudo mkfs.vfat -F32 -n EFI "${P1}"
sudo mkfs.ext4 -F -L LIVE "${P2}"
sudo mkswap -f -L SWAP "${P3}"
sudo mkfs.ext4 -F -L casper-rw "${P4}"

echo "[7/10] Mount partitions"
sudo mount "${P2}" "${mnt}"
sudo mkdir -p "${mnt}/boot" "${mnt}/${LIVE_DIR}"
sudo mount "${P1}" "${esp}"
sudo mount "${P4}" "${data_mnt}"

echo "[8/10] Copy kernel/initrd/squashfs and persistence config"
sudo cp -v "${KERNEL}" "${mnt}/boot/vmlinuz"
sudo cp -v "${INITRD}" "${mnt}/boot/initrd"
sudo cp -v "${squash}" "${mnt}/${LIVE_DIR}/filesystem.squashfs"

# Casper markers
sudo mkdir -p "${mnt}/.disk"
echo "Ubuntu ${DIST} Live" | sudo tee "${mnt}/.disk/info" >/dev/null
echo "Ubuntu ${DIST}" | sudo tee "${mnt}/.disk/release_notes_url" >/dev/null
sudo touch "${mnt}/.disk/base_installable"
sudo touch "${mnt}/ubuntu"

sudo tee "${data_mnt}/persistence.conf" >/dev/null <<'EOF'
/ union
EOF
sync

LIVE_UUID="$(sudo blkid -s UUID -o value "${P2}")"

echo "[9/10] Install GRUB (UEFI) and write grub.cfg"
sudo mkdir -p "${esp}/EFI/BOOT"
sudo tee "${esp}/EFI/BOOT/grub.cfg" >/dev/null <<'EOFGRUB'
set default=0
set timeout=5

insmod part_gpt
insmod ext2
insmod linux
insmod gzio

set root=(hd0,gpt2)

menuentry 'Ubuntu 24.04 Noble (live + persistence)' {
    set root=(hd0,gpt2)
    linux /boot/vmlinuz boot=casper file=/casper/filesystem.squashfs toram persistent noeject ---
    initrd /boot/initrd
}

menuentry 'Ubuntu (debug: verbose + break)' {
    set root=(hd0,gpt2)
    linux /boot/vmlinuz boot=casper file=/casper/filesystem.squashfs verbose debug break=mount persistent noeject ---
    initrd /boot/initrd
}

menuentry 'Ubuntu (safe: no persistence)' {
    set root=(hd0,gpt2)
    linux /boot/vmlinuz boot=casper file=/casper/filesystem.squashfs toram nopersistent noeject ---
    initrd /boot/initrd
}
EOFGRUB

sudo grub-mkstandalone \
  --directory=/usr/lib/grub/x86_64-efi \
  --format=x86_64-efi \
  --compress=xz \
  --output="${esp}/EFI/BOOT/BOOTX64.EFI" \
  "boot/grub/grub.cfg=${esp}/EFI/BOOT/grub.cfg"

sync

echo "[10/10] Finalize and convert to VHDX"
sudo umount -R "${data_mnt}" "${esp}" "${mnt}"
sudo losetup -d "${LOOPDEV}"
trap - EXIT

# Convert to VHDX (uncomment if needed)
# qemu-img convert -O vhdx "${IMG}" "${VHDX}"

echo
echo "Built:"
echo "  Raw : ${IMG}"
echo "  VHDX: ${VHDX}"
echo
echo "QEMU (console):"
echo "  qemu-system-x86_64 -m 2048 -machine q35,accel=kvm \\
        -drive file=${IMG},format=raw,if=virtio -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd -nographic"
echo
echo "Hyper-V Gen2: attach ${VHDX} as a SCSI disk on a Gen2 VM (UEFI)."
echo "Disable Secure Boot for quick testing, or install shim/grub signed if needed."