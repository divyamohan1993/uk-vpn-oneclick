#!/usr/bin/env bash
# setup-linux.sh - one-click WireGuard for Linux using the uk-vpn-devices bundle.
# Usage: ./setup-linux.sh [device-number]   (default 1; use a DIFFERENT number per device)
set -e
N="${1:-1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONF=""
for base in "$SCRIPT_DIR/uk-vpn-devices" "$SCRIPT_DIR/../uk-vpn-devices" "$HOME/uk-vpn-devices" "$HOME/Desktop/uk-vpn-devices" "$SCRIPT_DIR"; do
  if [ -f "$base/wireguard/device-$N.conf" ]; then CONF="$base/wireguard/device-$N.conf"; break; fi
done
if [ -z "$CONF" ]; then
  echo "Could not find wireguard/device-$N.conf."
  echo "Put the 'uk-vpn-devices' folder next to this script (or in your home dir) and retry."
  exit 1
fi
echo "Using $CONF"

if ! command -v wg-quick >/dev/null 2>&1; then
  echo "Installing WireGuard..."
  if   command -v apt-get >/dev/null 2>&1; then sudo apt-get update -y && sudo apt-get install -y wireguard
  elif command -v dnf     >/dev/null 2>&1; then sudo dnf install -y wireguard-tools
  elif command -v pacman  >/dev/null 2>&1; then sudo pacman -S --noconfirm wireguard-tools
  else echo "Please install 'wireguard-tools' with your package manager, then re-run."; exit 1; fi
fi

sudo install -m 600 "$CONF" /etc/wireguard/uk-vpn.conf
sudo wg-quick down uk-vpn 2>/dev/null || true
sudo wg-quick up uk-vpn

echo ""
echo "Connected. Verify:  curl -s https://ifconfig.me ; echo"
echo "Disconnect:         sudo wg-quick down uk-vpn"
echo "Reconnect later:    sudo wg-quick up uk-vpn"
