#!/bin/bash

# Check if ISO file is provided as an argument
if [ -z "$1" ]; then
    echo "Error: Please provide an ISO file path as an argument"
    exit 1
fi

# Check if Homebrew is installed
if ! command -v brew &> /dev/null; then
    echo "Error: Homebrew is not installed. Please install Homebrew first."
    exit 1
fi

# Check if QEMU is installed, install if not
if ! brew list qemu &> /dev/null; then
    echo "QEMU not found. Installing QEMU via Homebrew..."
    brew install qemu
fi

ISO_FILE="$1"

# Get QEMU prefix from Homebrew
BREW_QEMU="$(brew --prefix qemu)"

# List and copy EDK2 firmware files
ls "$BREW_QEMU/share/qemu" | grep -i edk2
cp "$BREW_QEMU/share/qemu/edk2-x86_64-code.fd" .
cp "$BREW_QEMU/share/qemu/edk2-x86_64-secure-code.fd" .

# Create QCOW2 image if it doesn't exist
if [ ! -f "./ff1.qcow2" ]; then
  qemu-img create -f qcow2 ff1.qcow2 -o nocow=on 8G
  qemu-system-x86_64 \
    -M q35 \
    -accel tcg,thread=multi \
    -cpu qemu64 -m 4G -smp 4 \
    -device intel-hda -device hda-output \
    -device qemu-xhci \
    -drive if=pflash,format=raw,readonly=on,file="./edk2-x86_64-code.fd" \
    -drive if=pflash,format=raw,readonly=on,file="./edk2-x86_64-secure-code.fd" \
    -drive file=./ff1.qcow2,format=qcow2 \
    -drive if=none,id=stick,format=raw,file="$ISO_FILE",readonly=on \
    -device nec-usb-xhci,id=xhci                              \
    -device usb-storage,bus=xhci.0,drive=stick \
    -device virtio-gpu-pci \
    -boot order=d,menu=on \
    -display cocoa \
    -netdev user,id=n1 \
    -device virtio-net-pci,netdev=n1
fi

qemu-system-x86_64 \
  -M q35 \
  -accel tcg,thread=multi \
  -cpu qemu64 -m 4G -smp 4 \
  -device intel-hda -device hda-output \
  -drive if=pflash,format=raw,readonly=on,file="./edk2-x86_64-code.fd" \
  -drive if=pflash,format=raw,readonly=on,file="./edk2-x86_64-secure-code.fd" \
  -drive file=./ff1.qcow2,format=qcow2 \
  -device virtio-gpu-pci \
  -display cocoa \
  -netdev user,id=n1 \
  -device virtio-net-pci,netdev=n1