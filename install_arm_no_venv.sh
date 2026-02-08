#!/usr/bin/env bash
set -euo pipefail

# Lightweight installer for ARM SBCs (Raspberry Pi / Orange Pi)
# - Installs Python deps per-user with pip3
# - Detects a single mounted removable USB drive and uses it as MEDIA_ROOT
# - Performs safety checks to avoid overwriting system mounts
# - Installs a systemd service `tinymedia` that runs as the invoking user

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_NAME="$(id -un)"

# Non-interactive mode: set AUTO_YES=1 or pass -y / --yes
AUTO_YES=${AUTO_YES:-0}
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) AUTO_YES=1; shift;;
    *) echo "Unknown option: $1" >&2; exit 2;;
  esac
done

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
  if [ "$AUTO_YES" = "1" ]; then
    yn=Y
  else
    read -p "Install python3 and pip3 via apt now? [y/N] " yn
  fi
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
  elif [ "$AUTO_YES" = "1" ]; then
    # In non-interactive mode, pick the sole exfat partition or fail
    declare -a um_exfat_idxs=()
    for j in "${!unmounted[@]}"; do
      um_fs=$(echo "${unmounted[$j]}" | sed -n 's/.*FSTYPE="\([^\"]*\)".*/\1/p')
      [ "$um_fs" = "exfat" ] && um_exfat_idxs+=("$j")
    done
    if [ ${#um_exfat_idxs[@]} -eq 1 ]; then
      sel=${um_exfat_idxs[0]}
      echo "AUTO_YES: selecting exFAT partition [${sel}]" >&2
    else
      echo "AUTO_YES: expected exactly 1 exFAT partition, found ${#um_exfat_idxs[@]}. Aborting." >&2
      exit 1
    fi
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
    if [ "$AUTO_YES" = "1" ]; then
      echo "AUTO_YES: expected exactly 1 exFAT partition, found ${#exfat_idxs[@]}. Aborting." >&2
      exit 1
    fi
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

# Get device info for fstab entry (persistent mount across reboots)
if [ -n "${dev_name:-}" ]; then
  FSTAB_DEV="/dev/$dev_name"
else
  # Find device from mountpoint
  FSTAB_DEV=$(findmnt -n -o SOURCE "$MEDIA_ROOT" 2>/dev/null || true)
fi

# Try to get UUID for more reliable fstab entry
if [ -n "$FSTAB_DEV" ]; then
  DEV_UUID=$(blkid -s UUID -o value "$FSTAB_DEV" 2>/dev/null || true)
  DEV_FSTYPE=$(blkid -s TYPE -o value "$FSTAB_DEV" 2>/dev/null || true)
  echo "Device: $FSTAB_DEV"
  echo "UUID: ${DEV_UUID:-<not found>}"
  echo "Filesystem: ${DEV_FSTYPE:-<not found>}"
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
if [ "$AUTO_YES" = "1" ]; then
  yn=Y
else
  read -p "Proceed and create systemd service 'tinymedia' (runs as $USER_NAME)? [y/N] " yn
fi
if [[ ! "$yn" =~ ^[Yy]$ ]]; then
  echo "Aborting." >&2
  exit 1
fi

# Add fstab entry for persistent mount across reboots
if [ -n "${DEV_UUID:-}" ] && [ -n "${DEV_FSTYPE:-}" ]; then
  # Ensure mount directory exists (needed for fstab to work on reboot)
  if [ ! -d "$MEDIA_ROOT" ]; then
    echo "Creating mount directory $MEDIA_ROOT..."
    sudo mkdir -p "$MEDIA_ROOT"
  fi
  
  # Build mount options based on filesystem type (removed x-systemd.automount for immediate boot mounting)
  if [[ "$DEV_FSTYPE" == "vfat" || "$DEV_FSTYPE" == "exfat" ]]; then
    MOUNT_OPTS="nofail,x-systemd.device-timeout=10,uid=$(id -u),gid=$(id -g),umask=0000"
  else
    # For ext4, ntfs, etc. - don't use uid/gid/umask
    MOUNT_OPTS="nofail,x-systemd.device-timeout=10"
  fi
  
  FSTAB_LINE="UUID=$DEV_UUID $MEDIA_ROOT $DEV_FSTYPE $MOUNT_OPTS 0 0"
  
  # Check if entry already exists
  if grep -q "UUID=$DEV_UUID" /etc/fstab 2>/dev/null; then
    echo "fstab entry for this drive already exists, skipping..."
  else
    echo "Adding fstab entry for persistent mount..."
    echo "$FSTAB_LINE" | sudo tee -a /etc/fstab > /dev/null
    echo "Added: $FSTAB_LINE"
    
    # Reload systemd to recognize new fstab entry
    echo "Reloading systemd daemon..."
    sudo systemctl daemon-reload
    
    # Verify the mount works by unmounting and remounting via fstab
    echo "Verifying fstab entry..."
    if mountpoint -q "$MEDIA_ROOT"; then
      sudo umount "$MEDIA_ROOT" || true
    fi
    
    if sudo mount "$MEDIA_ROOT" 2>/dev/null; then
      echo "✓ fstab entry verified successfully"
    else
      echo "Warning: fstab mount test failed. Entry was added but may need adjustment." >&2
    fi
  fi
elif [ -n "${FSTAB_DEV:-}" ]; then
  # Fallback: use device path if UUID not available
  echo "Warning: UUID not available, using device path $FSTAB_DEV (less reliable)"
  
  if [ ! -d "$MEDIA_ROOT" ]; then
    sudo mkdir -p "$MEDIA_ROOT"
  fi
  
  # Detect filesystem type from the device if not already known
  if [ -z "${DEV_FSTYPE:-}" ]; then
    DEV_FSTYPE=$(lsblk -n -o FSTYPE "$FSTAB_DEV" 2>/dev/null || echo "auto")
  fi
  
  if [[ "$DEV_FSTYPE" == "vfat" || "$DEV_FSTYPE" == "exfat" ]]; then
    MOUNT_OPTS="nofail,x-systemd.device-timeout=10,uid=$(id -u),gid=$(id -g),umask=0000"
  else
    MOUNT_OPTS="nofail,x-systemd.device-timeout=10"
  fi
  
  FSTAB_LINE="$FSTAB_DEV $MEDIA_ROOT $DEV_FSTYPE $MOUNT_OPTS 0 0"
  
  if ! grep -q "$FSTAB_DEV.*$MEDIA_ROOT" /etc/fstab 2>/dev/null; then
    echo "Adding fstab entry using device path..."
    echo "$FSTAB_LINE" | sudo tee -a /etc/fstab > /dev/null
    echo "Added: $FSTAB_LINE"
    sudo systemctl daemon-reload
  fi
else
  echo "Error: Could not determine device, UUID, or fstype for fstab entry." >&2
  echo "The drive will NOT mount automatically after reboot." >&2
  echo "You will need to manually add an fstab entry or mount the drive." >&2
  if [ "$AUTO_YES" != "1" ]; then
    read -p "Continue anyway? [y/N] " cont
    if [[ ! "$cont" =~ ^[Yy]$ ]]; then
      exit 1
    fi
  fi
fi

echo "Installing Python dependencies with pip3..."
python3 -m pip install --upgrade --user --break-system-packages pip
python3 -m pip install --user --break-system-packages Flask gunicorn

SERVICE_FILE="/etc/systemd/system/tinymedia.service"
echo "Writing systemd service to $SERVICE_FILE (requires sudo)..."

# Escape MEDIA_ROOT path for systemd (replace / with -)
MEDIA_ROOT_ESCAPED=$(systemd-escape --path "$MEDIA_ROOT")

sudo bash -c "cat > '$SERVICE_FILE' <<EOF
[Unit]
Description=TinyMedia Lightweight Media Server
After=network.target local-fs.target ${MEDIA_ROOT_ESCAPED}.mount
Requires=${MEDIA_ROOT_ESCAPED}.mount

[Service]
Type=simple
User=$USER_NAME
Environment=MEDIA_ROOT=$MEDIA_ROOT
WorkingDirectory=$REPO_DIR
ExecStartPre=/bin/sleep 2
ExecStartPre=/bin/sh -c 'until mountpoint -q $MEDIA_ROOT; do echo Waiting for $MEDIA_ROOT...; sleep 2; done'
ExecStart=/home/$USER_NAME/.local/bin/gunicorn -w 2 -b 0.0.0.0:5000 server:app
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF"

echo "Reloading systemd and enabling service..."
sudo systemctl daemon-reload
sudo systemctl enable tinymedia
sudo systemctl start tinymedia

echo "Installation complete."
echo ""
echo "The USB drive will auto-mount on reboot via fstab."
echo "Service: sudo systemctl status tinymedia" 
echo "Open http://<device-ip>:5000 on your phone (same network)."
