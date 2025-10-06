#!/usr/bin/env bash
set -euo pipefail

set -x

echo "=== Preflight: verifying host build environment ==="

# List of required commands (adjust if you add tools later)
REQUIRED_BINS=(
  mmdebstrap
  mksquashfs
  grub-install
  mkfs.vfat
  mkfs.ext4
  mkswap
  sfdisk
  losetup
  blkid
  qemu-img
)

# Optional but recommended
OPTIONAL_BINS=(
  parted
  gdisk
  kpartx
  rsync
  xz
  mount
)

missing=()

for bin in "${REQUIRED_BINS[@]}"; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    missing+=("$bin")
  fi
done

if ((${#missing[@]} > 0)); then
  echo "❌ Missing required tools:"
  printf '   %s\n' "${missing[@]}"
  echo
  echo "Try installing them with:"
  echo "  sudo apt-get update && sudo apt-get install -y \\"
  echo "    mmdebstrap squashfs-tools grub-efi-amd64-bin dosfstools \\"
  echo "    e2fsprogs util-linux qemu-utils xz-utils"
  echo
  echo "Aborting."
  exit 1
fi

echo "✅ Required tools found."

for bin in "${OPTIONAL_BINS[@]}"; do
  command -v "$bin" >/dev/null 2>&1 || \
    echo "⚠️  Optional tool missing: $bin"
done

echo "=== Environment looks good ==="
