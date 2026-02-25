#!/bin/bash
set -euo pipefail

SSHD_CONF="/etc/ssh/sshd_config.d/ff1.conf"

usage() {
  echo "Usage: $0 [on|off]"
  echo "  on   - Disable ff1 config and use default SSH settings (password auth allowed)"
  echo "  off  - Restore ff1 config (key-only authentication)"
  exit 1
}

[[ $# -ne 1 ]] && usage

case "$1" in
  on)
    if [[ ! -f "$SSHD_CONF" ]]; then
      echo "SSH is already using default settings."
      exit 0
    fi
    echo "Stopping sshd..."
    systemctl stop sshd
    echo "Disabling ff1 SSH config..."
    mv "$SSHD_CONF" "${SSHD_CONF}.disabled"
    echo "Enabling and starting sshd with default settings..."
    systemctl enable --now sshd
    echo "Done. SSH is now running with default settings (password authentication allowed)."
    ;;
  off)
    if [[ ! -f "${SSHD_CONF}.disabled" ]]; then
      echo "Error: ${SSHD_CONF}.disabled not found. Has 'on' been run first?"
      exit 1
    fi
    if [[ -f "$SSHD_CONF" ]]; then
      echo "ff1 SSH config is already active."
      exit 0
    fi
    echo "Stopping sshd..."
    systemctl stop sshd
    echo "Restoring ff1 SSH config..."
    mv "${SSHD_CONF}.disabled" "$SSHD_CONF"
    echo "Done. SSH is restored to ff1 hardened settings (key-only authentication)."
    ;;
  *)
    usage
    ;;
esac
