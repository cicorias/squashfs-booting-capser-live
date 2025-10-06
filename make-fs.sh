#!/usr/bin/env bash
set -euo pipefail

set -x

# sudo apt-get install -y \
#   mmdebstrap \
#   squashfs-tools \
#   grub-efi-amd64-bin \
#   dosfstools \
#   e2fsprogs \
#   gdisk \
#   qemu-utils \
#   kpartx \
#   rsync \
#   xz-utils \
#   mount \
#   parted

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
LIVE_DIR=live
# ---------------------------------------------------------------------------

workdir="$(pwd)/work-ubuntu"
rootfs="${workdir}/rootfs"
mnt="${workdir}/mnt"
esp="${workdir}/esp"
data_mnt="${workdir}/data"
squash="${workdir}/filesystem.squashfs"

deps() {
  local miss=0
  for cmd in mmdebstrap mksquashfs sfdisk losetup mkfs.vfat mkfs.ext4 mkswap mount umount grub-install qemu-img; do
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
    mountpoint -q "$d" && umount -R "$d" || true
  done
  [[ -n "${LOOPDEV:-}" && -e "${LOOPDEV}" ]] && losetup -d "${LOOPDEV}" || true
}
trap cleanup EXIT

echo "[1/10] Prepare workspace"

deps

rm -rf "${workdir}"
mkdir -p "${workdir}" "${rootfs}" "${mnt}" "${esp}" "${data_mnt}"

echo "[2/10] Bootstrap Ubuntu ${DIST} with mmdebstrap"
# mmdebstrap --variant=minbase \
#   --include=linux-image-generic,live-boot,squashfs-tools,ca-certificates,iproute2,iputils-ping,net-tools,less,vim \
#   "${DIST}" "${rootfs}" "${MIRROR}"

mmdebstrap --variant=minbase \
  --include=linux-image-generic,live-boot,squashfs-tools,ca-certificates,iproute2,iputils-ping,net-tools,less,vim \
  --aptopt='Acquire::AllowInsecureRepositories "true";' \
  --aptopt='APT::Get::AllowUnauthenticated "true";' \
  --components="main" \
  noble "${rootfs}" \
  "deb ${MIRROR} ${DIST} main restricted universe multiverse" \
  "deb http://deb.debian.org/debian bookworm main"


echo "${HOSTNAME}" > "${rootfs}/etc/hostname"
chroot "${rootfs}" bash -lc "echo 'root:${ROOTPWD}' | chpasswd"

echo "[3/10] Locate kernel & initrd"
KERNEL="$(readlink -f "${rootfs}"/boot/vmlinuz-*)"
INITRD="$(readlink -f "${rootfs}"/boot/initrd.img-*)"
test -f "${KERNEL}" && test -f "${INITRD}"

echo "[4/10] Build squashfs"
mksquashfs "${rootfs}" "${squash}" -comp xz -wildcards \
  -e proc sys dev run tmp var/tmp var/cache/apt/archives

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
LOOPDEV="$(losetup --show --partscan -f "${IMG}")"
P1="${LOOPDEV}p1"  # ESP
P2="${LOOPDEV}p2"  # Main OS
P3="${LOOPDEV}p3"  # Swap
P4="${LOOPDEV}p4"  # Data (persistence)

mkfs.vfat -F32 -n EFI "${P1}"
mkfs.ext4 -L LIVE "${P2}"
mkswap -L SWAP "${P3}"
mkfs.ext4 -L persistence "${P4}"

echo "[7/10] Mount partitions"
mount "${P2}" "${mnt}"
mkdir -p "${mnt}/boot" "${mnt}/${LIVE_DIR}"
mount "${P1}" "${esp}"
mount "${P4}" "${data_mnt}"

echo "[8/10] Copy kernel/initrd/squashfs and persistence config"
cp -v "${KERNEL}" "${mnt}/boot/vmlinuz"
cp -v "${INITRD}" "${mnt}/boot/initrd"
cp -v "${squash}" "${mnt}/${LIVE_DIR}/filesystem.squashfs"

cat > "${data_mnt}/persistence.conf" <<'EOF'
/ union
EOF
sync

LIVE_UUID="$(blkid -s UUID -o value "${P2}")"

echo "[9/10] Install GRUB (UEFI) and write grub.cfg"
mkdir -p "${mnt}/boot/grub"
cat > "${mnt}/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=3

if [ -z "\$root" ]; then
  search --no-floppy --fs-uuid --set=root ${LIVE_UUID}
fi

menuentry "Ubuntu 24.04 Noble (UEFI live, overlayfs + persistence)" {
    insmod gzio
    insmod part_gpt
    insmod ext2
    linux  /boot/vmlinuz boot=live components live-media=UUID=${LIVE_UUID} live-media-path=/${LIVE_DIR} union=overlay persistence quiet
    initrd /boot/initrd
}
EOF

grub-install \
  --target=x86_64-efi \
  --efi-directory="${esp}" \
  --boot-directory="${mnt}/boot" \
  --removable \
  --no-nvram

sync

echo "[10/10] Finalize and convert to VHDX"
umount -R "${data_mnt}" "${esp}" "${mnt}"
losetup -d "${LOOPDEV}"
trap - EXIT

# qemu-img convert -O vhdx "${IMG}" "${VHDX}"

echo
echo "Built:"
echo "  Raw : ${IMG}"
echo "  VHDX: ${VHDX}"
echo
echo "QEMU (console):"
echo "  qemu-system-x86_64 -m 2048 -machine q35,accel=kvm \\
        -drive file=${IMG},format=raw,if=virtio -nographic"
echo
echo "Hyper-V Gen2: attach ${VHDX} as a SCSI disk on a Gen2 VM (UEFI)."
echo "Disable Secure Boot for quick testing, or install shim/grub signed if needed."
