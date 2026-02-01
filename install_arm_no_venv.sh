#!/usr/bin/env bash
set -euo pipefail

# Lightweight installer for ARM SBCs (Raspberry Pi / Orange Pi)
# - Installs Python deps per-user with pip3
# - Detects a single mounted removable USB drive and uses it as MEDIA_ROOT
# - Performs safety checks to avoid overwriting system mounts
# - Installs a systemd service `tinymedia` that runs as the invoking user

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

echo "Detecting removable USB drives..."

# Use lsblk to list removable partitions with a filesystem
mapfile -t all_removable < <(lsblk -P -o NAME,RM,FSTYPE,LABEL,MOUNTPOINT,SIZE | awk -F' ' '$0 ~ /RM="1"/ && $0 !~ /FSTYPE=""/ {print $0}')

if [ ${#all_removable[@]} -eq 0 ]; then
  echo "No removable USB drives with a filesystem detected." >&2
  exit 1
fi

# Separate mounted and unmounted drives
declare -a candidates=()
declare -a unmounted=()

for entry in "${all_removable[@]}"; do
  mp=$(echo "$entry" | sed -n 's/.*MOUNTPOINT="\([^"]*\)".*/\1/p')
  if [ -n "$mp" ]; then
    candidates+=("$entry")
  else
    unmounted+=("$entry")
  fi
done

# If no mounted drives but we have unmounted ones, offer to mount
if [ ${#candidates[@]} -eq 0 ] && [ ${#unmounted[@]} -gt 0 ]; then
  echo "Found unmounted removable USB drive(s):"
  for i in "${!unmounted[@]}"; do
    entry=${unmounted[$i]}
    name=$(echo "$entry" | sed -n 's/.*NAME="\([^\"]*\)".*/\1/p')
    fstype=$(echo "$entry" | sed -n 's/.*FSTYPE="\([^\"]*\)".*/\1/p')
    label=$(echo "$entry" | sed -n 's/.*LABEL="\([^\"]*\)".*/\1/p')
    size=$(echo "$entry" | sed -n 's/.*SIZE="\([^\"]*\)".*/\1/p')
    echo "  [$i] /dev/$name - $fstype ${label:-} $size"
  done
  
  if [ ${#unmounted[@]} -eq 1 ]; then
    sel=0
  else
    read -p "Select drive number to mount: " sel
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ -z "${unmounted[$sel]:-}" ]; then
      echo "Invalid selection" >&2
      exit 1
    fi
  fi
  
  selected=${unmounted[$sel]}
  dev_name=$(echo "$selected" | sed -n 's/.*NAME="\([^\"]*\)".*/\1/p')
  
  MOUNT_DIR="/media/$USER_NAME/usb"
  echo "Mounting /dev/$dev_name to $MOUNT_DIR..."
  sudo mkdir -p "$MOUNT_DIR"
  
  # Get UID and GID for mount options
  USER_UID=$(id -u)
  USER_GID=$(id -g)
  
  # Mount with appropriate options for the filesystem type
  fstype=$(echo "$selected" | sed -n 's/.*FSTYPE="\([^\"]*\)".*/\1/p')
  if [[ "$fstype" == "vfat" || "$fstype" == "exfat" ]]; then
    sudo mount -o uid=$USER_UID,gid=$USER_GID,umask=0000 "/dev/$dev_name" "$MOUNT_DIR"
  else
    sudo mount "/dev/$dev_name" "$MOUNT_DIR"
    sudo chown -R "$USER_NAME:$USER_NAME" "$MOUNT_DIR"
  fi
  
  MEDIA_ROOT="$MOUNT_DIR"
  echo "Mounted successfully at $MEDIA_ROOT"
  
elif [ ${#candidates[@]} -eq 0 ]; then
  echo "No removable USB drives detected. Please connect a USB drive and re-run." >&2
  exit 1
fi

if [ ${#candidates[@]} -gt 1 ]; then
  echo "Multiple removable mounts detected:" >&2
  # build list of exfat candidates to prefer automatically
  declare -a exfat_idxs=()
  for i in "${!candidates[@]}"; do
    entry=${candidates[$i]}
    name=$(echo "$entry" | sed -n 's/.*NAME="\([^\"]*\)".*/\1/p')
    fstype=$(echo "$entry" | sed -n 's/.*FSTYPE="\([^\"]*\)".*/\1/p')
    label=$(echo "$entry" | sed -n 's/.*LABEL="\([^\"]*\)".*/\1/p')
    size=$(echo "$entry" | sed -n 's/.*SIZE="\([^\"]*\)".*/\1/p')
    mp=$(echo "$entry" | sed -n 's/.*MOUNTPOINT="\([^\"]*\)".*/\1/p')
    tag=""
    if [ "$fstype" = "exfat" ]; then
      tag=" (exfat)"
      exfat_idxs+=("$i")
    fi
    echo "  [$i] /dev/$name$tag - ${fstype:-unknown} ${label:-} ${size:-} - $mp"
  done

  # If exactly one exfat mount exists, select it automatically
  if [ ${#exfat_idxs[@]} -eq 1 ]; then
    sel=${exfat_idxs[0]}
    echo "Automatically selecting exFAT mount [$sel]" >&2
    pick=${candidates[$sel]}
  else
    read -p "Select mount number to use as MEDIA_ROOT: " sel
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ -z "${candidates[$sel]:-}" ]; then
      echo "Invalid selection" >&2
      exit 1
    fi
    pick=${candidates[$sel]}
  fi
elif [ ${#candidates[@]} -eq 1 ]; then
  pick=${candidates[0]}
fi

if [ -n "${pick:-}" ]; then
  MEDIA_ROOT=$(echo "$pick" | sed -n 's/.*MOUNTPOINT="\([^"]*\)".*/\1/p')
fi

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
python3 -m pip install --upgrade --user --break-system-packages pip
python3 -m pip install --user --break-system-packages Flask gunicorn

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
ExecStart=/home/$USER_NAME/.local/bin/gunicorn -w 2 -b 0.0.0.0:5000 server:app
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
