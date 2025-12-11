#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Proxmox VE Cloud-Init Template Generator
# =============================================================================

# --- Base paths & storage -----------------------------------------------------
DOWNLOAD_DIR="/PATH/TO/templates"         # e.g., "/local-zfs/templates"
STORAGE_POOL="<YOUR_STORAGE_POOL>"        # e.g., "local-zfs" or "local-lvm"

# --- VM IDs (make sure they are free) ----------------------------------------
DEBIAN_12_VMID=9000
DEBIAN_13_VMID=9001
UBUNTU_2204_VMID=9002
UBUNTU_2404_VMID=9003
OPENSUSE_LEAP_156_VMID=9004
OPENSUSE_TUMBLEWEED_VMID=9005

# --- Resources (RAM in MB, cores, disk size) ---------------------------------
VM_RAM=4096                               # e.g., 2048, 4096, 8192
VM_CORES=2                                # e.g., 2, 4
DISK_SIZE="8G"                            # e.g., "8G", "16G", "32G"

# --- Network / Cloud-Init parameters -----------------------------------------
NET_BRIDGE="vmbr0"                        # e.g., "vmbr0", "vmbr1"
SEARCHDOMAIN="<YOUR-SEARCH-DOMAIN>"       # e.g., "example.com" or ""
NAMESERVER="<YOUR-NAMESERVER-IP>"         # e.g., "10.0.0.1" or ""
# DHCP or static; examples:
#   IPCONFIG="dhcp"
#   IPCONFIG="192.168.10.50/24,gw=192.168.10.1"
IPCONFIG="dhcp"

# --- Authentication -----------------------------------------------------------
AUTHORIZED_KEYS="/PATH/TO/authorized_keys"          # e.g., "/root/templates/authorized_keys"
ADMIN_PASSWORD_FILE="/PATH/TO/admin_password"       # e.g., "/root/templates/admin_password"
# Optionally set via environment: export ADMIN_PASSWORD='supersecret'
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"

# --- Timezone -----------------------------------------------------------------
TIMEZONE="Europe/Berlin"

# --- Sysprep operations -------------------------------------------------------
SYSPREP_OPS="bash-history,logfiles,ssh-hostkeys,machine-id,package-manager-cache"

# --- Behavior toggles ---------------------------------------------------------
# If set to "true", a template will NOT be rebuilt if:
# - the base image timestamp is unchanged AND
# - a VM with the target VMID already exists.
SKIP_IF_BASE_UNCHANGED="${SKIP_IF_BASE_UNCHANGED:-false}"

# If "true", wait before/after disk resize to work around PVE timing issues.
# Can be disabled via --no-resize-wait or RESIZE_WAIT_ENABLED=false.
RESIZE_WAIT_ENABLED="${RESIZE_WAIT_ENABLED:-true}"

# CLI default: interactive mode with fzf.
NON_INTERACTIVE=false

# =============================================================================
# Helper functions: logging, error handling, CLI parsing, dependency checks
# =============================================================================

# Basic placeholder sanity check before we start touching the filesystem
if [[ "${DOWNLOAD_DIR}" == "/PATH/TO/templates" ]]; then
  echo "ERROR: DOWNLOAD_DIR is still the placeholder '/PATH/TO/templates'. Please configure it."
  exit 1
fi

LOG_DIR="${DOWNLOAD_DIR}/logs"
STATE_DIR="${DOWNLOAD_DIR}/state"
mkdir -p "${DOWNLOAD_DIR}" "${LOG_DIR}" "${STATE_DIR}"
LOG_FILE="${LOG_DIR}/template-creation-$(date +%Y%m%d-%H%M%S).log"

error_handler() {
  local exit_code=$?
  echo "[!] ERROR: Script failed with exit code ${exit_code}. See log file: ${LOG_FILE}" >&2
  exit "${exit_code}"
}

trap error_handler ERR

# Redirect all stdout and stderr to both console and log file
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "[*] Logging to: ${LOG_FILE}"

require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: Required command '$1' not found. Please install it and retry."
    exit 1
  }
}

print_usage() {
  cat <<EOF
Usage: $0 [--all|--non-interactive] [--no-resize-wait] [--help]

Options:
  --all, --non-interactive
      Build all templates without interactive fzf selection.
  --no-resize-wait
      Disable the sleep before/after disk resize. By default enabled as a
      workaround for PVE timing issues with disk import/resize.
  --help, -h
      Show this help message.

Environment variables:
  ADMIN_PASSWORD
      Admin password for the 'local-admin' cloud-init user. If not set,
      the script will try to read it from ADMIN_PASSWORD_FILE. If still
      empty, 'local-admin' will be SSH-key-only (no password login set).
  SKIP_IF_BASE_UNCHANGED=true
      If set, skip rebuilding a template when the base image timestamp
      has not changed and a VM with the target VMID already exists.
  RESIZE_WAIT_ENABLED=false
      Disable the sleep intervals before/after disk resize without
      passing --no-resize-wait.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all|--non-interactive)
        NON_INTERACTIVE=true
        shift
        ;;
      --no-resize-wait)
        RESIZE_WAIT_ENABLED=false
        shift
        ;;
      --help|-h)
        print_usage
        exit 0
        ;;
      *)
        echo "ERROR: Unknown argument: $1" >&2
        print_usage >&2
        exit 1
        ;;
    esac
  done
}

parse_args "$@"

echo "[*] Checking prerequisites..."
# base tools
BASE_BINS=(qm wget virt-sysprep virt-customize stat pvesm)
for bin in "${BASE_BINS[@]}"; do
  require_bin "$bin"
done
# fzf only required in interactive mode
if ! ${NON_INTERACTIVE}; then
  require_bin fzf
fi

# Storage pool sanity check
if [[ "${STORAGE_POOL}" == "<YOUR_STORAGE_POOL>" ]]; then
  echo "ERROR: STORAGE_POOL is still the placeholder '<YOUR_STORAGE_POOL>'. Please configure it."
  exit 1
fi

if ! pvesm status | awk 'NR>1 {print $1}' | grep -qx "${STORAGE_POOL}"; then
  echo "ERROR: STORAGE_POOL '${STORAGE_POOL}' does not exist on this node."
  exit 1
fi

# Validate SEARCHDOMAIN / NAMESERVER placeholders; allow them to be empty.
if [[ "${SEARCHDOMAIN}" == "<YOUR-SEARCH-DOMAIN>" ]]; then
  echo "ERROR: SEARCHDOMAIN is still the placeholder '<YOUR-SEARCH-DOMAIN>'. Set it or leave it empty (\"\")."
  exit 1
fi

if [[ "${NAMESERVER}" == "<YOUR-NAMESERVER-IP>" ]]; then
  echo "ERROR: NAMESERVER is still the placeholder '<YOUR-NAMESERVER-IP>'. Set it or leave it empty (\"\")."
  exit 1
fi

# Read admin password if not provided via env (optional)
if [[ -z "${ADMIN_PASSWORD}" ]] && [[ -f "${ADMIN_PASSWORD_FILE}" ]]; then
  ADMIN_PASSWORD="$(<"${ADMIN_PASSWORD_FILE}")"
fi

if [[ -z "${ADMIN_PASSWORD}" ]]; then
  echo "[*] No ADMIN_PASSWORD set; 'local-admin' will be SSH-key-only (no password login configured)."
fi

# Basic sanity checks
if [[ ! -f "${AUTHORIZED_KEYS}" ]]; then
  echo "ERROR: authorized_keys file not found at: ${AUTHORIZED_KEYS}"
  exit 1
fi

# =============================================================================
# Function: create_template_vm (with image cache + minimal downloads)
#   $1 = VM ID
#   $2 = VM Name
#   $3 = Base image filename (must match filename in URL!)
#   $4 = Download URL
#   $5 = Package list for virt-customize (e.g., "qemu-guest-agent,cloud-guest-utils")
# =============================================================================
create_template_vm() {
  local vm_id="$1"
  local vm_name="$2"
  local base_image_name="$3"   # must match the filename at the end of the URL
  local download_url="$4"
  local pkg_list="$5"

  local base_image_file="${DOWNLOAD_DIR}/${base_image_name}"
  local work_image_file="${DOWNLOAD_DIR}/${vm_name}-work.qcow2"
  local state_file="${STATE_DIR}/vm-${vm_id}.state"

  echo "[*] Ensuring base image '${base_image_name}' is up-to-date..."

  (
    cd "${DOWNLOAD_DIR}"
    if [[ -f "${base_image_name}" ]]; then
      echo "    -> Local base image exists, checking for updates (wget -N)..."
    else
      echo "    -> No local base image, downloading..."
    fi
    # -N: only downloads if the remote file is newer (timestamping)
    wget --show-progress -N "${download_url}"
  )

  if [[ ! -f "${base_image_file}" ]]; then
    echo "ERROR: Base image ${base_image_file} not found after download."
    exit 1
  fi

  local base_mtime
  base_mtime="$(stat -c %Y "${base_image_file}")"

  # Optional: skip rebuild if base image hasn't changed and VM already exists
  if [[ "${SKIP_IF_BASE_UNCHANGED}" == "true" ]]; then
    if qm config "${vm_id}" &>/dev/null; then
      if [[ -f "${state_file}" ]]; then
        local last_mtime
        last_mtime="$(<"${state_file}")"
        if [[ "${last_mtime}" == "${base_mtime}" ]]; then
          echo "[*] Base image unchanged and VM ${vm_id} already exists; skipping rebuild (SKIP_IF_BASE_UNCHANGED=true)."
          return 0
        fi
      fi
    fi
  fi

  echo "[*] Preparing working copy for ${vm_name}..."
  rm -f "${work_image_file}"
  cp --reflink=auto --sparse=always "${base_image_file}" "${work_image_file}"

  echo "[*] Removing old VM ${vm_id} (if present)..."
  qm destroy "${vm_id}" --purge || true

  echo "[*] Running virt-sysprep on working copy..."
  virt-sysprep -a "${work_image_file}" --operations "${SYSPREP_OPS}"

  echo "[*] Running virt-customize on working copy..."
  if [[ -n "${pkg_list}" ]]; then
    virt-customize -a "${work_image_file}" \
      --install "${pkg_list}" \
      --run-command "echo ${TIMEZONE} > /etc/timezone || true" \
      --run-command "ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime"
  else
    virt-customize -a "${work_image_file}" \
      --run-command "echo ${TIMEZONE} > /etc/timezone || true" \
      --run-command "ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime"
  fi

  echo "[*] Creating VM ${vm_id} (${vm_name})..."
  qm create "${vm_id}" \
    --name "${vm_name}" \
    --memory "${VM_RAM}" \
    --cores "${VM_CORES}" \
    --net0 "virtio,bridge=${NET_BRIDGE}"

  echo "[*] Importing disk into storage pool '${STORAGE_POOL}'..."
  qm importdisk "${vm_id}" "${work_image_file}" "${STORAGE_POOL}"

  # Figure out the actual volume ID that qm importdisk created.
  local disk_vol_id
  disk_vol_id="$(pvesm list "${STORAGE_POOL}" | awk -v pat="^${STORAGE_POOL}:vm-${vm_id}-disk-" '$1 ~ pat {print $1; exit}')"

  if [[ -z "${disk_vol_id}" ]]; then
    echo "ERROR: Could not find imported disk for VM ${vm_id} on storage ${STORAGE_POOL}"
    exit 1
  fi

  echo "[*] Configuring disks, boot, and cloud-init..."
  qm set "${vm_id}" --virtio0 "${disk_vol_id},cache=writeback,discard=on"
  qm set "${vm_id}" --ide2 "${STORAGE_POOL}:cloudinit"
  qm set "${vm_id}" --agent enabled=1
  qm set "${vm_id}" --boot c --bootdisk virtio0
  qm set "${vm_id}" --hotplug disk,network,usb
  qm set "${vm_id}" --serial0 socket
  qm set "${vm_id}" --vga serial0
  qm set "${vm_id}" --cpu cputype=host
  qm set "${vm_id}" --ostype l26
  qm set "${vm_id}" --balloon $(( VM_RAM / 2 ))
  qm set "${vm_id}" --ciupgrade 1
  qm set "${vm_id}" --ciuser "local-admin"
  qm set "${vm_id}" --sshkeys "${AUTHORIZED_KEYS}"

  # Only set password if configured
  if [[ -n "${ADMIN_PASSWORD}" ]]; then
    qm set "${vm_id}" --cipassword "${ADMIN_PASSWORD}"
  fi

  # Only set searchdomain/nameserver if non-empty
  if [[ -n "${SEARCHDOMAIN}" ]]; then
    qm set "${vm_id}" --searchdomain "${SEARCHDOMAIN}"
  fi
  if [[ -n "${NAMESERVER}" ]]; then
    qm set "${vm_id}" --nameserver "${NAMESERVER}"
  fi

  qm set "${vm_id}" --ipconfig0 "ip=${IPCONFIG}"

  echo "[*] Resizing primary disk to ${DISK_SIZE}..."
  if [[ "${RESIZE_WAIT_ENABLED}" == "true" ]]; then
    echo "[*] Waiting 30 seconds before resize (PVE import/resize timing workaround)..."
    sleep 30
  fi
  qm resize "${vm_id}" virtio0 "${DISK_SIZE}"
  if [[ "${RESIZE_WAIT_ENABLED}" == "true" ]]; then
    echo "[*] Waiting 60 seconds after resize..."
    sleep 60
  fi

  echo "[*] Converting VM ${vm_id} to a template..."
  qm template "${vm_id}"
  echo "${base_mtime}" > "${state_file}"
  echo "[✓] Template created: ${vm_name}"

  # Optional: remove working copy to save space
  rm -f "${work_image_file}" || true
}

# =============================================================================
# Template selection (interactive via fzf or non-interactive)
# =============================================================================
options=(
  "ALL"
  "Debian 12"
  "Debian 13"
  "Ubuntu 22.04"
  "Ubuntu 24.04"
  "openSUSE Leap 15.6"
  "openSUSE Tumbleweed"
)

choices=()

if ${NON_INTERACTIVE}; then
  echo "[*] Non-interactive mode: building all known images."
  # all options except "ALL" (index 0)
  choices=("${options[@]:1}")
else
  if ! mapfile -t choices < <(
    printf '%s\n' "${options[@]}" | fzf \
      -m \
      --prompt="Base images (select with SPACE) > " \
      --height=10 \
      --layout=reverse \
      --border \
      --bind "space:toggle+down"
  ); then
    echo "No selection made."
    exit 1
  fi

  if (( ${#choices[@]} == 0 )); then
    echo "No selection made."
    exit 1
  fi

  # If "ALL" is selected (alone or with others),
  # always build all images.
  build_all=false
  for item in "${choices[@]}"; do
    if [[ "${item}" == "ALL" ]]; then
      build_all=true
      break
    fi
  done

  if ${build_all}; then
    echo "[*] 'ALL' selected – all known images will be built."
    # all options except "ALL"
    choices=("${options[@]:1}")
  fi
fi

echo "[*] Selected:"
for item in "${choices[@]}"; do
  echo " - ${item}"
done

echo "[*] Starting template creation..."

for item in "${choices[@]}"; do
  case "${item}" in
    "Debian 12")
      echo "[*] Building Debian 12 image..."
      create_template_vm \
        "${DEBIAN_12_VMID}" \
        "cloudinit-template-debian-12" \
        "debian-12-generic-amd64.qcow2" \
        "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2" \
        "qemu-guest-agent,cloud-guest-utils"
      ;;
    "Debian 13")
      echo "[*] Building Debian 13 image..."
      create_template_vm \
        "${DEBIAN_13_VMID}" \
        "cloudinit-template-debian-13" \
        "debian-13-generic-amd64.qcow2" \
        "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2" \
        "qemu-guest-agent,cloud-guest-utils"
      ;;
    "Ubuntu 22.04")
      echo "[*] Building Ubuntu 22.04 image..."
      create_template_vm \
        "${UBUNTU_2204_VMID}" \
        "cloudinit-template-ubuntu-22.04" \
        "jammy-server-cloudimg-amd64.img" \
        "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img" \
        "qemu-guest-agent,cloud-guest-utils"
      ;;
    "Ubuntu 24.04")
      echo "[*] Building Ubuntu 24.04 image..."
      create_template_vm \
        "${UBUNTU_2404_VMID}" \
        "cloudinit-template-ubuntu-24.04" \
        "ubuntu-24.04-server-cloudimg-amd64.img" \
        "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img" \
        "qemu-guest-agent,cloud-guest-utils"
      ;;
    "openSUSE Leap 15.6")
      echo "[*] Building openSUSE Leap 15.6 image..."
      create_template_vm \
        "${OPENSUSE_LEAP_156_VMID}" \
        "cloudinit-template-opensuse-leap-15.6" \
        "openSUSE-Leap-15.6-Minimal-VM.x86_64-Cloud.qcow2" \
        "https://download.opensuse.org/opensuse/distribution/leap/15.6/appliances/openSUSE-Leap-15.6-Minimal-VM.x86_64-Cloud.qcow2" \
        "qemu-guest-agent,cloud-init"
      ;;
    "openSUSE Tumbleweed")
      echo "[*] Building openSUSE Tumbleweed image..."
      create_template_vm \
        "${OPENSUSE_TUMBLEWEED_VMID}" \
        "cloudinit-template-opensuse-tumbleweed" \
        "openSUSE-Tumbleweed-Minimal-VM.x86_64-Cloud.qcow2" \
        "https://download.opensuse.org/tumbleweed/appliances/openSUSE-Tumbleweed-Minimal-VM.x86_64-Cloud.qcow2" \
        "qemu-guest-agent,cloud-init"
      ;;
    *)
      echo "WARN: Unknown selection '${item}' – skipping."
      ;;
  esac
done

echo "[✓] All selected templates have been created successfully."
echo "[*] Full log available at: ${LOG_FILE}"
