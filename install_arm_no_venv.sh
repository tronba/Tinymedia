#!/usr/bin/env bash
set -euo pipefail

# Lightweight installer for ARM SBCs (Raspberry Pi / Orange Pi)
# - Installs Python deps per-user with pip3
# - Detects a single mounted removable USB drive and uses it as MEDIA_ROOT
# - Performs safety checks to avoid overwriting system mounts
# - Installs a systemd service `tinymedia` that runs as the invoking user

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USER_NAME="$(id -un)"

if [ "$EUID" -eq 0 ]; then
  echo "Do NOT run this script as root. Run it as the user that should own the media and service." >&2
  exit 1
fi

ARCH="$(uname -m)"
if [[ "$ARCH" != arm* && "$ARCH" != aarch64 ]]; then
  echo "Warning: detected arch $ARCH — this script targets ARM SBCs but will continue." >&2
fi

command -v python3 >/dev/null 2>&1 || {
  echo "python3 is required. Installing via apt is recommended on Debian-based systems." >&2
  read -p "Install python3 and pip3 via apt now? [y/N] " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    sudo apt update && sudo apt install -y python3 python3-pip
  else
    echo "Please install python3 and pip3 and re-run." >&2
    exit 1
  fi
}

echo "Detecting mounted removable USB drives..."

# Use lsblk to list removable devices with mountpoints. Parse simple KEY=VAL output.
mapfile -t candidates < <(lsblk -o NAME,RM,MOUNTPOINT -P | awk -F' ' '$0 ~ /RM="1"/ && $0 ~ /MOUNTPOINT="/ {print $0}')

if [ ${#candidates[@]} -eq 0 ]; then
  echo "No mounted removable USB drives detected. Please mount your USB drive and re-run." >&2
  echo "Common mount points: /media/$USER_NAME/*  or /mnt/*" >&2
  exit 1
fi

if [ ${#candidates[@]} -gt 1 ]; then
  echo "Multiple removable mounts detected:" >&2
  for i in "${!candidates[@]}"; do
    entry=${candidates[$i]}
    # extract MOUNTPOINT value
    mp=$(echo "$entry" | sed -n 's/.*MOUNTPOINT="\([^"]*\)".*/\1/p')
    echo "  [$i] $mp"
  done
  read -p "Select mount number to use as MEDIA_ROOT: " sel
  if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ -z "${candidates[$sel]:-}" ]; then
    echo "Invalid selection" >&2
    exit 1
  fi
  pick=${candidates[$sel]}
else
  pick=${candidates[0]}
fi

MEDIA_ROOT=$(echo "$pick" | sed -n 's/.*MOUNTPOINT="\([^"]*\)".*/\1/p')

if [ -z "$MEDIA_ROOT" ]; then
  echo "Failed to determine mountpoint." >&2
  exit 1
fi

# Safety checks
if [ "$MEDIA_ROOT" = "/" ] || [ "$MEDIA_ROOT" = "/home" ] || [ "$MEDIA_ROOT" = "/boot" ]; then
  echo "Refusing to use core system mountpoint: $MEDIA_ROOT" >&2
  exit 1
fi

if ! mountpoint -q -- "$MEDIA_ROOT"; then
  echo "$MEDIA_ROOT does not appear to be a mountpoint." >&2
  exit 1
fi

echo "Using MEDIA_ROOT=$MEDIA_ROOT"
read -p "Proceed and create systemd service 'tinymedia' (runs as $USER_NAME)? [y/N] " yn
if [[ ! "$yn" =~ ^[Yy]$ ]]; then
  echo "Aborting." >&2
  exit 1
fi

echo "Installing Python dependencies with pip3..."
python3 -m pip install --upgrade --user pip
python3 -m pip install --user Flask gunicorn

SERVICE_FILE="/etc/systemd/system/tinymedia.service"
echo "Writing systemd service to $SERVICE_FILE (requires sudo)..."
sudo bash -c "cat > '$SERVICE_FILE' <<EOF
[Unit]
Description=TinyMedia Lightweight Media Server
After=network.target

[Service]
Type=simple
User=$USER_NAME
Environment=MEDIA_ROOT=$MEDIA_ROOT
WorkingDirectory=$REPO_DIR
ExecStart=/usr/bin/python3 $REPO_DIR/server.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF"

echo "Reloading systemd and enabling service..."
sudo systemctl daemon-reload
sudo systemctl enable tinymedia
sudo systemctl start tinymedia

echo "Installation complete."
echo "Service: sudo systemctl status tinymedia" 
echo "Open http://<device-ip>:5000 on your phone (same network)."
