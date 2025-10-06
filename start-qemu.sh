qemu-system-x86_64 -m 2048 -machine q35,accel=kvm -cpu host \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file=ovmf_vars.fd \
    -device virtio-blk-pci,drive=hd0 \
    -drive if=none,file=ubuntu-noble-uefi-4part.img,format=raw,id=hd0 \
    -nic user,model=virtio-net-pci \
    -serial mon:stdio -display none

# echo $! > qemu.pid

# echo "QEMU started with PID $(cat qemu.pid)" > qemu.log
# echo "To stop QEMU, run: kill \$(cat qemu.pid) && rm qemu.pid" >> qemu.log

