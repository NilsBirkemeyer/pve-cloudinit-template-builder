#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Proxmox VE Cloud-Init Template Generator
# =============================================================================

# Prevent sourcing to avoid redirecting your interactive shell into the log file.
prevent_sourcing() {
  if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    echo "ERROR: Do not source this script. Run it via 'bash ${BASH_SOURCE[0]##*/}' instead." >&2
    return 1
  fi

  return 0
}

prevent_sourcing || return 1

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
VERBOSE_LEVEL=1
IMAGES_CONFIG_FILE="${IMAGES_CONFIG_FILE:-${SCRIPT_DIR}/images.json}"
DRY_RUN=false
VALIDATE_ONLY=false

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

log_with_level() {
  local level="$1"
  shift
  local message="$*"
  echo "${message}"
  if (( level <= VERBOSE_LEVEL )); then
    echo "${message}" >&3
  fi
}

log_summary() {
  log_with_level 1 "$@"
}

log_info() {
  log_with_level 2 "$@"
}

log_debug() {
  log_with_level 3 "$@"
}

log_warn() {
  log_summary "Warning: $*"
}

log_err() {
  echo "$@" >&3
  echo "$@" >&2
}

run_step() {
  local description="$1"
  shift || true

  if ${DRY_RUN}; then
    log_info "DRY-RUN: ${description}"
    if (($# > 0)); then
      log_debug "       would run: $*"
    fi
  else
    log_info "${description}"
    if (($# > 0)); then
      log_debug "       running: $*"
      "$@"
    fi
  fi
}

error_handler() {
  local exit_code=$?
  log_err "ERROR: Script failed with exit code ${exit_code}. See log file: ${LOG_FILE}"
  exit "${exit_code}"
}

trap error_handler ERR

log_summary "Log file: ${LOG_FILE}"

compute_template_signature() {
  local base_mtime="$1"
  local download_url="$2"
  local image_file="$3"
  local pkg_list="$4"
  local checksum="$5"

  python3 - <<PY
import hashlib, json, os, pathlib, sys

def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as fh:
        for chunk in iter(lambda: fh.read(8192), b''):
            h.update(chunk)
    return h.hexdigest()

authorized_keys = pathlib.Path("${AUTHORIZED_KEYS}")
payload = {
    "admin_password_hash": hashlib.sha256(os.environ.get("ADMIN_PASSWORD", "").encode()).hexdigest(),
    "authorized_keys_hash": sha256_file(authorized_keys),
    "base_mtime": "${base_mtime}",
    "checksum": "${checksum}",
    "disk_size": "${DISK_SIZE}",
    "download_url": "${download_url}",
    "image_file": "${image_file}",
    "ipconfig": "${IPCONFIG}",
    "nameserver": "${NAMESERVER}",
    "net_bridge": "${NET_BRIDGE}",
    "packages": "${pkg_list}",
    "resize_wait_enabled": "${RESIZE_WAIT_ENABLED}",
    "searchdomain": "${SEARCHDOMAIN}",
    "storage_pool": "${STORAGE_POOL}",
    "sysprep_ops": "${SYSPREP_OPS}",
    "timezone": "${TIMEZONE}",
    "vm_cores": "${VM_CORES}",
    "vm_ram": "${VM_RAM}",
}

print(hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest())
PY
}

verify_checksum() {
  local file_path="$1"
  local checksum_spec="$2"

  if [[ -z "${checksum_spec}" ]]; then
    return 0
  fi

  local algo expected
  if [[ "${checksum_spec}" == *:* ]]; then
    algo="${checksum_spec%%:*}"
    expected="${checksum_spec#*:}"
  else
    algo="sha256"
    expected="${checksum_spec}"
  fi

  if ! python3 - "$file_path" "$algo" "$expected" <<'PY'; then exit 1; fi
import hashlib, pathlib, sys

file_path = pathlib.Path(sys.argv[1])
algo = sys.argv[2].lower()
expected = sys.argv[3].lower()

try:
    hasher = hashlib.new(algo)
except ValueError:
    print(f"Unsupported checksum algorithm: {algo}", file=sys.stderr)
    sys.exit(1)

with file_path.open('rb') as fh:
    for chunk in iter(lambda: fh.read(8192), b''):
        hasher.update(chunk)

actual = hasher.hexdigest().lower()
if actual != expected:
    print(f"Checksum mismatch for {file_path}: expected {expected}, got {actual}", file=sys.stderr)
    sys.exit(1)
PY
}

read_state_file() {
  local path="$1"
  local mtime=""
  local signature=""

  if [[ -f "${path}" ]]; then
    while IFS='=' read -r key value; do
      case "${key}" in
        base_mtime) mtime="${value}" ;;
        signature) signature="${value}" ;;
      esac
    done < "${path}"
  fi

  echo "${mtime}|${signature}"
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    log_err "ERROR: Required command '$1' not found. Please install it and retry."
    exit 1
  }
}

print_usage() {
  log_summary "Usage: $0 [--all|--non-interactive] [--no-resize-wait] [--verbose|--debug|-v|-vv|-vvv] [--dry-run] [--validate] [--help]"
  log_summary
  log_summary "Options:"
  log_summary "  --all, --non-interactive"
  log_summary "      Build all templates without interactive fzf selection."
  log_summary "  --no-resize-wait"
  log_summary "      Disable the sleep before/after disk resize. By default enabled as a"
  log_summary "      workaround for PVE timing issues with disk import/resize."
  log_summary "  --verbose"
  log_summary "      Print detailed progress to the console (level 2)."
  log_summary "  -v"
  log_summary "      Lightly verbose console output (level 2)."
  log_summary "  -vv"
  log_summary "      Full verbosity console output (level 3)."
  log_summary "  -vvv"
  log_summary "      Alias for -vv (maximum available detail)."
  log_summary "  --debug"
  log_summary "      Print all debug output to the console (same as -vvv, level 3)."
  log_summary "  --dry-run"
  log_summary "      Show what would happen without making changes to Proxmox."
  log_summary "  --validate"
  log_summary "      Validate configuration and image catalog, then exit."
  log_summary "  --help, -h"
  log_summary "      Show this help message."
  log_summary
  log_summary "Environment variables (typically set via .env):"
  log_summary "  DOWNLOAD_DIR, STORAGE_POOL, VM_RAM, VM_CORES, DISK_SIZE,"
  log_summary "  NET_BRIDGE, IPCONFIG, SEARCHDOMAIN, NAMESERVER,"
  log_summary "  AUTHORIZED_KEYS, ADMIN_PASSWORD_FILE, ADMIN_PASSWORD, TIMEZONE,"
  log_summary "  SKIP_IF_BASE_UNCHANGED, RESIZE_WAIT_ENABLED, SYSPREP_OPS"
  log_summary "  IMAGES_CONFIG_FILE (optional: path to images.json)"
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
      -vvv)
        VERBOSE_LEVEL=3
        shift
        ;;
      -vv)
        VERBOSE_LEVEL=3
        shift
        ;;
      -v)
        VERBOSE_LEVEL=2
        shift
        ;;
      --verbose)
        VERBOSE_LEVEL=2
        shift
        ;;
      --debug)
        VERBOSE_LEVEL=3
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --validate)
        VALIDATE_ONLY=true
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

if ${DRY_RUN}; then
  log_summary "Mode: dry-run (no changes will be applied)."
fi
if ${VALIDATE_ONLY}; then
  log_summary "Mode: validation only."
fi

log_summary "Checking prerequisites..."
# base tools
BASE_BINS=(qm wget virt-sysprep virt-customize stat pvesm python3)
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
  log_info "No ADMIN_PASSWORD set; 'local-admin' will be SSH-key-only (no password login configured)."
fi

# Basic sanity checks
if [[ ! -f "${AUTHORIZED_KEYS}" ]]; then
  log_err "ERROR: authorized_keys file not found at: ${AUTHORIZED_KEYS}"
  exit 1
fi

# =============================================================================
# Image configuration loading
# =============================================================================

declare -a IMAGE_LABELS=()
declare -a IMAGE_VM_IDS=()
declare -a IMAGE_NAMES=()
declare -a IMAGE_FILES=()
declare -a IMAGE_URLS=()
declare -a IMAGE_PACKAGES=()
declare -a IMAGE_CHECKSUMS=()
declare -A IMAGE_INDEX_BY_LABEL=()

load_image_config() {
  if [[ ! -f "${IMAGES_CONFIG_FILE}" ]]; then
    log_err "ERROR: Image configuration file not found at ${IMAGES_CONFIG_FILE}"
    exit 1
  fi

  local parsed
  if ! parsed=$(python3 - "${IMAGES_CONFIG_FILE}" <<'PY'
import json, sys
path = sys.argv[1]
try:
    with open(path, 'r', encoding='utf-8') as fh:
        data = json.load(fh)
except Exception as exc:  # noqa: BLE001
    print(f"Failed to read {path}: {exc}", file=sys.stderr)
    sys.exit(1)

if not isinstance(data, list):
    print("Top-level JSON must be a list of image definitions", file=sys.stderr)
    sys.exit(1)

required = ["label", "vm_id", "vm_name", "image_file", "image_url"]

for idx, item in enumerate(data):
    if not isinstance(item, dict):
        print(f"Entry #{idx + 1} must be an object", file=sys.stderr)
        sys.exit(1)
    for key in required:
        value = item.get(key)
        if value is None or str(value).strip() == "":
            print(f"Entry #{idx + 1} missing required key '{key}'", file=sys.stderr)
            sys.exit(1)
    packages = item.get("packages", "")
    checksum = item.get("checksum", "")
    fields = [
        item["label"],
        str(item["vm_id"]),
        item["vm_name"],
        item["image_file"],
        item["image_url"],
        packages,
        checksum,
    ]
    print("|".join(fields))
PY
  ); then
    log_err "ERROR: Failed to parse image configuration (${IMAGES_CONFIG_FILE})."
    exit 1
  fi

    local index=0
  while IFS='|' read -r label vm_id vm_name image_file image_url packages checksum; do
    IMAGE_LABELS+=("${label}")
    IMAGE_VM_IDS+=("${vm_id}")
    IMAGE_NAMES+=("${vm_name}")
    IMAGE_FILES+=("${image_file}")
    IMAGE_URLS+=("${image_url}")
    IMAGE_PACKAGES+=("${packages}")
    IMAGE_CHECKSUMS+=("${checksum}")
    IMAGE_INDEX_BY_LABEL["${label}"]=${index}
    ((index++))
  done <<<"${parsed}"

  if (( ${#IMAGE_LABELS[@]} == 0 )); then
    log_err "ERROR: No images defined in ${IMAGES_CONFIG_FILE}"
    exit 1
  fi
}

load_image_config

validate_image_catalog() {
  local ok=true
  declare -A seen_labels=()
  declare -A seen_vm_ids=()

  for idx in "${!IMAGE_LABELS[@]}"; do
    local label="${IMAGE_LABELS[idx]}"
    local vm_id="${IMAGE_VM_IDS[idx]}"
    local vm_name="${IMAGE_NAMES[idx]}"
    local image_file="${IMAGE_FILES[idx]}"
    local image_url="${IMAGE_URLS[idx]}"

    if [[ -n "${seen_labels[${label}]+x}" ]]; then
      log_err "ERROR: Duplicate label '${label}' in image catalog."
      ok=false
    fi
    seen_labels["${label}"]=1

    if [[ -n "${seen_vm_ids[${vm_id}]+x}" ]]; then
      log_err "ERROR: Duplicate VM ID '${vm_id}' in image catalog."
      ok=false
    fi
    seen_vm_ids["${vm_id}"]=1

    if [[ ! "${vm_id}" =~ ^[0-9]+$ ]]; then
      log_err "ERROR: VM ID for '${label}' must be numeric. Found '${vm_id}'."
      ok=false
    fi

    if [[ -z "${image_file}" || -z "${image_url}" || -z "${vm_name}" ]]; then
      log_err "ERROR: Incomplete definition for '${label}'."
      ok=false
    fi
  done

  if ! ${ok}; then
    exit 1
  fi
}

validate_image_catalog

if ${VALIDATE_ONLY}; then
  log_summary "Validation completed successfully."
  exit 0
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
  local checksum="$6"

  local base_image_file="${DOWNLOAD_DIR}/${base_image_name}"
  local work_image_file="${DOWNLOAD_DIR}/${vm_name}-work.qcow2"
  local state_file="${STATE_DIR}/vm-${vm_id}.state"

  log_info "Ensuring base image '${base_image_name}' is up-to-date..."

  if ${DRY_RUN}; then
    log_info "DRY-RUN: would fetch ${download_url} into ${base_image_file}"
  else
    (
      cd "${DOWNLOAD_DIR}" || exit 1

      if [[ -f "${base_image_name}" ]]; then
        log_debug "Local base image exists, checking for updates (wget -N, quiet)..."
      else
        log_debug "No local base image, downloading (wget -N, quiet)..."
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

    log_info "Base image '${base_image_name}' ready."

    if [[ -n "${checksum}" ]]; then
      run_step "Verify checksum for ${base_image_name}" verify_checksum "${base_image_file}" "${checksum}"
    else
      log_warn "No checksum provided for ${base_image_name}; download integrity is unchecked."
    fi
  fi

  local base_mtime=""
  if [[ -f "${base_image_file}" ]]; then
    base_mtime="$(stat -c %Y "${base_image_file}")"
  fi

  local current_signature=""
  current_signature="$(compute_template_signature "${base_mtime}" "${download_url}" "${base_image_name}" "${pkg_list}" "${checksum}")"

  # Optional: skip rebuild if base image hasn't changed and VM already exists
  if [[ "${SKIP_IF_BASE_UNCHANGED}" == "true" ]]; then
    if qm config "${vm_id}" &>/dev/null; then
      local state_data=""
      state_data="$(read_state_file "${state_file}")"
      IFS='|' read -r last_mtime last_signature <<<"${state_data}"

      if [[ "${last_mtime}" == "${base_mtime}" ]] && [[ "${last_signature}" == "${current_signature}" ]]; then
        log_summary "Base image and configuration unchanged; skipping VM ${vm_id} rebuild (SKIP_IF_BASE_UNCHANGED=true)."
        return 0
      fi
    fi
  fi

  log_info "Preparing working copy for ${vm_name}..."
  run_step "Remove existing working image" rm -f "${work_image_file}"
  run_step "Copy base image to working file" cp --reflink=auto --sparse=always "${base_image_file}" "${work_image_file}"

  run_step "Remove any existing VM ${vm_id}" qm destroy "${vm_id}" --purge || true

  run_step "Run virt-sysprep on working copy" virt-sysprep -a "${work_image_file}" --operations "${SYSPREP_OPS}"

  if [[ -n "${pkg_list}" ]]; then
    run_step "Customize image and install packages" \
      virt-customize -a "${work_image_file}" \
        --install "${pkg_list}" \
        --run-command "echo ${TIMEZONE} > /etc/timezone || true" \
        --run-command "ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime"
  else
    run_step "Customize image with timezone" \
      virt-customize -a "${work_image_file}" \
        --run-command "echo ${TIMEZONE} > /etc/timezone || true" \
        --run-command "ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime"
  fi

  run_step "Create VM ${vm_id} (${vm_name})" qm create "${vm_id}" \
    --name "${vm_name}" \
    --memory "${VM_RAM}" \
    --cores "${VM_CORES}" \
    --net0 "virtio,bridge=${NET_BRIDGE}"

  run_step "Import disk into storage pool '${STORAGE_POOL}'" qm importdisk "${vm_id}" "${work_image_file}" "${STORAGE_POOL}"

  # Figure out the actual volume ID that qm importdisk created.
  local disk_vol_id
  if ! ${DRY_RUN}; then
    disk_vol_id="$(qm config "${vm_id}" --format json | python3 -c 'import json, sys

config = json.load(sys.stdin)
target_storage = sys.argv[1]

unused_disks = []
for key, value in config.items():
    if key.startswith("unused") and isinstance(value, str) and value.startswith(target_storage + ":"):
        unused_disks.append((key, value))

if unused_disks:
    # Use the highest unused index to favor the most recent import
    selected = sorted(unused_disks, key=lambda item: item[0])[-1][1]
    print(selected)
' "${STORAGE_POOL}")"

    if [[ -z "${disk_vol_id}" ]]; then
      log_err "ERROR: Could not find imported disk for VM ${vm_id} on storage ${STORAGE_POOL}"
      exit 1
    fi
  fi

  log_info "Configuring disks, boot, and cloud-init..."
  run_step "Attach virtio disk" qm set "${vm_id}" --virtio0 "${disk_vol_id},cache=writeback,discard=on"
  run_step "Attach cloud-init drive" qm set "${vm_id}" --ide2 "${STORAGE_POOL}:cloudinit"
  run_step "Enable QEMU guest agent" qm set "${vm_id}" --agent enabled=1
  run_step "Configure boot settings" qm set "${vm_id}" --boot c --bootdisk virtio0
  run_step "Configure hotplug" qm set "${vm_id}" --hotplug disk,network,usb
  run_step "Configure serial console" qm set "${vm_id}" --serial0 socket
  run_step "Configure VGA" qm set "${vm_id}" --vga serial0
  run_step "Use host CPU type" qm set "${vm_id}" --cpu cputype=host
  run_step "Set OS type" qm set "${vm_id}" --ostype l26
  run_step "Configure ballooning" qm set "${vm_id}" --balloon $(( VM_RAM / 2 ))
  run_step "Enable cloud-init upgrade" qm set "${vm_id}" --ciupgrade 1
  run_step "Set default user" qm set "${vm_id}" --ciuser "local-admin"
  run_step "Install SSH keys" qm set "${vm_id}" --sshkeys "${AUTHORIZED_KEYS}"

  # Only set password if configured
  if [[ -n "${ADMIN_PASSWORD}" ]]; then
    run_step "Set admin password" qm set "${vm_id}" --cipassword "${ADMIN_PASSWORD}"
  fi

  # Only set searchdomain/nameserver if non-empty
  if [[ -n "${SEARCHDOMAIN}" ]]; then
    run_step "Configure search domain" qm set "${vm_id}" --searchdomain "${SEARCHDOMAIN}"
  fi
  if [[ -n "${NAMESERVER}" ]]; then
    run_step "Configure nameserver" qm set "${vm_id}" --nameserver "${NAMESERVER}"
  fi

  run_step "Configure networking" qm set "${vm_id}" --ipconfig0 "ip=${IPCONFIG}"

  log_info "Resizing primary disk to ${DISK_SIZE}..."
  if [[ "${RESIZE_WAIT_ENABLED}" == "true" ]]; then
    log_debug "Waiting 30 seconds before resize (PVE import/resize timing workaround)..."
    run_step "Pre-resize wait" sleep 30
  fi
  run_step "Resize disk" qm resize "${vm_id}" virtio0 "${DISK_SIZE}"
  if [[ "${RESIZE_WAIT_ENABLED}" == "true" ]]; then
    log_debug "Waiting 60 seconds after resize..."
    run_step "Post-resize wait" sleep 60
  fi

  log_info "Converting VM ${vm_id} to a template..."
  run_step "Convert to template" qm template "${vm_id}"
  if ! ${DRY_RUN} && [[ -n "${base_mtime}" ]]; then
    {
      echo "base_mtime=${base_mtime}"
      echo "signature=${current_signature}"
    } > "${state_file}"
  fi
  log_summary "Template created: ${vm_name}"

  # Optional: remove working copy to save space
  run_step "Remove working image" rm -f "${work_image_file}" || true
}

# =============================================================================
# Template selection (interactive via fzf or non-interactive)
# =============================================================================
options=("ALL" "${IMAGE_LABELS[@]}")

choices=()

if ${NON_INTERACTIVE}; then
  log_summary "Non-interactive mode: building all known images."
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
    log_summary "'ALL' selected – all known images will be built."
    choices=("${options[@]:1}")
  fi
fi

log_summary "Selected images:"
for item in "${choices[@]}"; do
  log_summary " - ${item}"
done

log_summary "Starting template creation..."

build_image_by_index() {
  local idx="$1"
  local label="${IMAGE_LABELS[${idx}]}"
  local vm_id="${IMAGE_VM_IDS[${idx}]}"
  local vm_name="${IMAGE_NAMES[${idx}]}"
  local image_file="${IMAGE_FILES[${idx}]}"
  local image_url="${IMAGE_URLS[${idx}]}"
  local packages="${IMAGE_PACKAGES[${idx}]}"
  local checksum="${IMAGE_CHECKSUMS[${idx}]}"

  log_summary "Building ${label} (VMID ${vm_id})..."
  create_template_vm "${vm_id}" "${vm_name}" "${image_file}" "${image_url}" "${packages}" "${checksum}"
}

for item in "${choices[@]}"; do
  if [[ -z "${IMAGE_INDEX_BY_LABEL["${item}"]+x}" ]]; then
    log_warn "Unknown selection '${item}' – skipping."
    continue
  fi
  build_image_by_index "${IMAGE_INDEX_BY_LABEL["${item}"]}"
done

if ${DRY_RUN}; then
  log_summary "Dry-run completed; no changes were applied."
else
  log_summary "All selected templates processed."
fi
log_summary "Full log available at: ${LOG_FILE}"
