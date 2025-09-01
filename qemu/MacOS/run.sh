#!/bin/bash

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
  -netdev user,id=n1,hostfwd=tcp::2222-:22 \
  -device virtio-net-pci,netdev=n1