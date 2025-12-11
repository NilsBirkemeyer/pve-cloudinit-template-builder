#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Proxmox VE Cloud-Init Template Generator
# =============================================================================

# --- Static VM IDs (do not put these into .env) ------------------------------
DEBIAN_12_VMID=9000
DEBIAN_13_VMID=9001
UBUNTU_2204_VMID=9002
UBUNTU_2404_VMID=9003
OPENSUSE_LEAP_156_VMID=9004
OPENSUSE_TUMBLEWEED_VMID=9005

# =============================================================================
# Load configuration from .env
# =============================================================================

# Resolve script directory to load .env next to the script
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Load .env if present
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "${SCRIPT_DIR}/.env"
  set +a
fi

# Initialize configuration variables from environment (or empty)
DOWNLOAD_DIR="${DOWNLOAD_DIR:-}"
STORAGE_POOL="${STORAGE_POOL:-}"

VM_RAM="${VM_RAM:-}"
VM_CORES="${VM_CORES:-}"
DISK_SIZE="${DISK_SIZE:-}"

NET_BRIDGE="${NET_BRIDGE:-}"
IPCONFIG="${IPCONFIG:-}"
SEARCHDOMAIN="${SEARCHDOMAIN:-}"
NAMESERVER="${NAMESERVER:-}"

AUTHORIZED_KEYS="${AUTHORIZED_KEYS:-}"
ADMIN_PASSWORD_FILE="${ADMIN_PASSWORD_FILE:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"

TIMEZONE="${TIMEZONE:-}"

SYSPREP_OPS="${SYSPREP_OPS:-bash-history,logfiles,ssh-hostkeys,machine-id,package-manager-cache}"
SKIP_IF_BASE_UNCHANGED="${SKIP_IF_BASE_UNCHANGED:-false}"
RESIZE_WAIT_ENABLED="${RESIZE_WAIT_ENABLED:-true}"

# CLI default: interactive mode with fzf.
NON_INTERACTIVE=false

# =============================================================================
# Early validation before we touch filesystem/logging
# =============================================================================

missing=false
for var in DOWNLOAD_DIR STORAGE_POOL VM_RAM VM_CORES DISK_SIZE NET_BRIDGE IPCONFIG AUTHORIZED_KEYS TIMEZONE; do
  if [[ -z "${!var}" ]]; then
    echo "ERROR: Required variable ${var} is not set. Configure it in .env or the environment." >&2
    missing=true
  fi
done

if [[ "${missing}" == "true" ]]; then
  exit 1
fi

# Fail fast if someone copied example placeholders without editing
if [[ "${DOWNLOAD_DIR}" == "/PATH/TO/templates" ]]; then
  echo "ERROR: DOWNLOAD_DIR is still the placeholder '/PATH/TO/templates'. Please configure it." >&2
  exit 1
fi

if [[ "${STORAGE_POOL}" == "<YOUR_STORAGE_POOL>" ]]; then
  echo "ERROR: STORAGE_POOL is still the placeholder '<YOUR_STORAGE_POOL>'. Please configure it." >&2
  exit 1
fi

if [[ "${SEARCHDOMAIN}" == "<YOUR-SEARCH-DOMAIN>" ]]; then
  echo "ERROR: SEARCHDOMAIN is still the placeholder '<YOUR-SEARCH-DOMAIN>'. Set it or leave it empty (\"\")." >&2
  exit 1
fi

if [[ "${NAMESERVER}" == "<YOUR-NAMESERVER-IP>" ]]; then
  echo "ERROR: NAMESERVER is still the placeholder '<YOUR-NAMESERVER-IP>'. Set it or leave it empty (\"\")." >&2
  exit 1
fi

# =============================================================================
# Logging setup
# =============================================================================

LOG_DIR="${DOWNLOAD_DIR}/logs"
STATE_DIR="${DOWNLOAD_DIR}/state"
mkdir -p "${DOWNLOAD_DIR}" "${LOG_DIR}" "${STATE_DIR}"
LOG_FILE="${LOG_DIR}/template-creation-$(date +%Y%m%d-%H%M%S).log"

# Save original stdout/stderr (console)
exec 3>&1 4>&2

# From here on: default stdout/stderr -> logfile
exec >>"${LOG_FILE}" 2>&1

log() {
  echo "$@" >&3
  echo "$@"
}

log_err() {
  echo "$@" >&3
  echo "$@" >&2
}

error_handler() {
  local exit_code=$?
  log_err "[!] ERROR: Script failed with exit code ${exit_code}. See log file: ${LOG_FILE}"
  exit "${exit_code}"
}

trap error_handler ERR

log "[*] Logging to: ${LOG_FILE}"

require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    log_err "ERROR: Required command '$1' not found. Please install it and retry."
    exit 1
  }
}

print_usage() {
  log "Usage: $0 [--all|--non-interactive] [--no-resize-wait] [--help]"
  log
  log "Options:"
  log "  --all, --non-interactive"
  log "      Build all templates without interactive fzf selection."
  log "  --no-resize-wait"
  log "      Disable the sleep before/after disk resize. By default enabled as a"
  log "      workaround for PVE timing issues with disk import/resize."
  log "  --help, -h"
  log "      Show this help message."
  log
  log "Environment variables (typically set via .env):"
  log "  DOWNLOAD_DIR, STORAGE_POOL, VM_RAM, VM_CORES, DISK_SIZE,"
  log "  NET_BRIDGE, IPCONFIG, SEARCHDOMAIN, NAMESERVER,"
  log "  AUTHORIZED_KEYS, ADMIN_PASSWORD_FILE, ADMIN_PASSWORD, TIMEZONE,"
  log "  SKIP_IF_BASE_UNCHANGED, RESIZE_WAIT_ENABLED, SYSPREP_OPS"
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
        log_err "ERROR: Unknown argument: $1"
        print_usage
        exit 1
        ;;
    esac
  done
}

parse_args "$@"

log "[*] Checking prerequisites..."
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
if ! pvesm status | awk 'NR>1 {print $1}' | grep -qx "${STORAGE_POOL}"; then
  log_err "ERROR: STORAGE_POOL '${STORAGE_POOL}' does not exist on this node."
  exit 1
fi

# Read admin password if not provided via env (optional)
if [[ -z "${ADMIN_PASSWORD}" ]] && [[ -n "${ADMIN_PASSWORD_FILE}" ]] && [[ -f "${ADMIN_PASSWORD_FILE}" ]]; then
  ADMIN_PASSWORD="$(<"${ADMIN_PASSWORD_FILE}")"
fi

if [[ -z "${ADMIN_PASSWORD}" ]]; then
  log "[*] No ADMIN_PASSWORD set; 'local-admin' will be SSH-key-only (no password login configured)."
fi

# Basic sanity checks
if [[ ! -f "${AUTHORIZED_KEYS}" ]]; then
  log_err "ERROR: authorized_keys file not found at: ${AUTHORIZED_KEYS}"
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

  log "[*] Ensuring base image '${base_image_name}' is up-to-date..."

  (
    cd "${DOWNLOAD_DIR}" || exit 1

    if [[ -f "${base_image_name}" ]]; then
      log "    -> Local base image exists, checking for updates (wget -N, quiet)..."
    else
      log "    -> No local base image, downloading (wget -N, quiet)..."
    fi

    if ! wget -q -N "${download_url}"; then
      log_err "ERROR: Download failed for ${download_url}"
      exit 1
    fi
  )

  if [[ ! -f "${base_image_file}" ]]; then
    log_err "ERROR: Base image ${base_image_file} not found after download."
    exit 1
  fi

  log "[*] Base image '${base_image_name}' ready."

  local base_mtime
  base_mtime="$(stat -c %Y "${base_image_file}")"

  # Optional: skip rebuild if base image hasn't changed and VM already exists
  if [[ "${SKIP_IF_BASE_UNCHANGED}" == "true" ]]; then
    if qm config "${vm_id}" &>/dev/null; then
      if [[ -f "${state_file}" ]]; then
        local last_mtime
        last_mtime="$(<"${state_file}")"
        if [[ "${last_mtime}" == "${base_mtime}" ]]; then
          log "[*] Base image unchanged and VM ${vm_id} already exists; skipping rebuild (SKIP_IF_BASE_UNCHANGED=true)."
          return 0
        fi
      fi
    fi
  fi

  log "[*] Preparing working copy for ${vm_name}..."
  rm -f "${work_image_file}"
  cp --reflink=auto --sparse=always "${base_image_file}" "${work_image_file}"

  log "[*] Removing old VM ${vm_id} (if present)..."
  qm destroy "${vm_id}" --purge || true

  log "[*] Running virt-sysprep on working copy..."
  virt-sysprep -a "${work_image_file}" --operations "${SYSPREP_OPS}"

  log "[*] Running virt-customize on working copy..."
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

  log "[*] Creating VM ${vm_id} (${vm_name})..."
  qm create "${vm_id}" \
    --name "${vm_name}" \
    --memory "${VM_RAM}" \
    --cores "${VM_CORES}" \
    --net0 "virtio,bridge=${NET_BRIDGE}"

  log "[*] Importing disk into storage pool '${STORAGE_POOL}'..."
  qm importdisk "${vm_id}" "${work_image_file}" "${STORAGE_POOL}"

  # Figure out the actual volume ID that qm importdisk created.
  local disk_vol_id
  disk_vol_id="$(pvesm list "${STORAGE_POOL}" | awk -v pat="^${STORAGE_POOL}:vm-${vm_id}-disk-" '$1 ~ pat {print $1; exit}')"

  if [[ -z "${disk_vol_id}" ]]; then
    log_err "ERROR: Could not find imported disk for VM ${vm_id} on storage ${STORAGE_POOL}"
    exit 1
  fi

  log "[*] Configuring disks, boot, and cloud-init..."
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

  log "[*] Resizing primary disk to ${DISK_SIZE}..."
  if [[ "${RESIZE_WAIT_ENABLED}" == "true" ]]; then
    log "[*] Waiting 30 seconds before resize (PVE import/resize timing workaround)..."
    sleep 30
  fi
  qm resize "${vm_id}" virtio0 "${DISK_SIZE}"
  if [[ "${RESIZE_WAIT_ENABLED}" == "true" ]]; then
    log "[*] Waiting 60 seconds after resize..."
    sleep 60
  fi

  log "[*] Converting VM ${vm_id} to a template..."
  qm template "${vm_id}"
  echo "${base_mtime}" > "${state_file}"
  log "[✓] Template created: ${vm_name}"

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
  log "[*] Non-interactive mode: building all known images."
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
    log_err "No selection made."
    exit 1
  fi

  if (( ${#choices[@]} == 0 )); then
    log_err "No selection made."
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
    log "[*] 'ALL' selected – all known images will be built."
    # all options except "ALL"
    choices=("${options[@]:1}")
  fi
fi

log "[*] Selected:"
for item in "${choices[@]}"; do
  log " - ${item}"
done

log "[*] Starting template creation..."

for item in "${choices[@]}"; do
  case "${item}" in
    "Debian 12")
      log "[*] Building Debian 12 image..."
      create_template_vm \
        "${DEBIAN_12_VMID}" \
        "cloudinit-template-debian-12" \
        "debian-12-generic-amd64.qcow2" \
        "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2" \
        "qemu-guest-agent,cloud-guest-utils"
      ;;
    "Debian 13")
      log "[*] Building Debian 13 image..."
      create_template_vm \
        "${DEBIAN_13_VMID}" \
        "cloudinit-template-debian-13" \
        "debian-13-generic-amd64.qcow2" \
        "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2" \
        "qemu-guest-agent,cloud-guest-utils"
      ;;
    "Ubuntu 22.04")
      log "[*] Building Ubuntu 22.04 image..."
      create_template_vm \
        "${UBUNTU_2204_VMID}" \
        "cloudinit-template-ubuntu-22.04" \
        "jammy-server-cloudimg-amd64.img" \
        "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img" \
        "qemu-guest-agent,cloud-guest-utils"
      ;;
    "Ubuntu 24.04")
      log "[*] Building Ubuntu 24.04 image..."
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
        "https://download.opensuse.org/distribution/leap/15.6/appliances/openSUSE-Leap-15.6-Minimal-VM.x86_64-Cloud.qcow2" \
        ""
      ;;
    "openSUSE Tumbleweed")
      echo "[*] Building openSUSE Tumbleweed image..."
      create_template_vm \
        "${OPENSUSE_TUMBLEWEED_VMID}" \
        "cloudinit-template-opensuse-tumbleweed" \
        "openSUSE-Tumbleweed-Minimal-VM.x86_64-Cloud.qcow2" \
        "https://download.opensuse.org/tumbleweed/appliances/openSUSE-Tumbleweed-Minimal-VM.x86_64-Cloud.qcow2" \
        ""
      ;;
    *)
      log "WARN: Unknown selection '${item}' – skipping."
      ;;
  esac
done

log "[✓] All selected templates have been created successfully."
log "[*] Full log available at: ${LOG_FILE}"
