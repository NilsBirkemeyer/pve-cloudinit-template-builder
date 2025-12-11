# Proxmox VE Cloud-Init Template Builder

This repository contains a Bash script that automates the creation of Proxmox VE VM templates based on upstream cloud-init images (Debian, Ubuntu, openSUSE).
The script downloads and caches cloud images, customizes them, and converts the resulting VMs into reusable Proxmox templates.

The script is designed to be:

* Repeatable (idempotent-ish with `SKIP_IF_BASE_UNCHANGED`)
* Non-interactive friendly (for automation) but with an interactive `fzf` mode
* Quiet on the terminal while writing full details to a log file
* Configurable via a `.env` file instead of editing the script itself

---

## Features

* Downloads official cloud-init images for:

  * Debian 12 (bookworm)
  * Debian 13 (trixie)
  * Ubuntu 22.04 LTS (jammy)
  * Ubuntu 24.04 LTS (noble)
  * openSUSE Leap 15.6
  * openSUSE Tumbleweed
* Caches base images in a configurable directory and only re-downloads if needed
* Runs `virt-sysprep` and `virt-customize` to:

  * Clean logs, machine IDs, SSH host keys, package caches
  * Install `qemu-guest-agent` and cloud-init/cloud-utils (depending on OS)
  * Set timezone
* Creates Proxmox VMs with:

  * VirtIO disk, cloud-init drive, QEMU guest agent enabled
  * `local-admin` cloud-init user
  * SSH key injection
  * Optional admin password
* Converts VMs into templates after resizing disks to a configurable size
* Optional sleeps around disk resize as a workaround for Proxmox disk import/resize timing issues
* Idempotence helper: skip rebuilding templates if the base image has not changed

---

## How it works (high-level)

1. Load configuration from `.env` (paths, storage, resources, network, etc.).
2. For every selected distribution:

   * Download or update the corresponding cloud image into `DOWNLOAD_DIR`.
   * Make a working copy of the image.
   * Run `virt-sysprep` and `virt-customize`.
   * Create a VM with the configured VMID and resources.
   * Import the disk into the selected `STORAGE_POOL`.
   * Attach cloud-init drive and configure Proxmox VM options.
   * Resize the disk to `DISK_SIZE` (with optional sleeps before/after).
   * Convert the VM into a template.
3. Store template state (base image mtime) so later runs can skip unchanged images if desired.
4. Log all actions and command output to a timestamped log file.

---

## Requirements

### Proxmox VE

* Proxmox VE node with:

  * `qm`
  * `pvesm`
  * A configured storage pool (e.g. `local-lvm`, `local-zfs`, …)

### Packages on the Proxmox node

The script expects at least:

* `wget`
* `virt-sysprep` (usually from `libguestfs-tools` or equivalent)
* `virt-customize`
* `stat`
* `fzf` (only needed for interactive mode)
* `bash`

Cloud-init packages (`qemu-guest-agent`, `cloud-init`, `cloud-guest-utils`) are installed inside the guest images by `virt-customize`.

---

## Installation

On your Proxmox node:

1. Clone the repository:

   git clone [https://github.com/](https://github.com/)<your-user>/proxmox-template-generator.git
   cd proxmox-template-generator

2. Make the script executable:

   chmod +x pve-cloudinit-template-builder.sh

3. Create an `.env` file (see next section) based on `.env.example`.

---

## Configuration via `.env`

All configuration is expected to be provided via a `.env` file located next to the script.

The `.env` file is a simple shell-compatible file that defines environment variables.
Example:

DOWNLOAD_DIR="/tmp/templates"
STORAGE_POOL="local-lvm"

VM_RAM="4096"
VM_CORES="2"
DISK_SIZE="8G"

NET_BRIDGE="vmbr0"
SEARCHDOMAIN="example.com"
NAMESERVER="10.0.0.1"
IPCONFIG="dhcp"

AUTHORIZED_KEYS="/root/templates/authorized_keys"
ADMIN_PASSWORD_FILE="/root/templates/admin_password"

## Optional override:

### ADMIN_PASSWORD="supersecret"

TIMEZONE="Europe/Berlin"

SYSPREP_OPS="bash-history,logfiles,ssh-hostkeys,machine-id,package-manager-cache"

SKIP_IF_BASE_UNCHANGED="false"
RESIZE_WAIT_ENABLED="true"

### Important variables

* `DOWNLOAD_DIR`
  Directory where base images, logs and state are stored.

* `STORAGE_POOL`
  Proxmox storage pool name (e.g. `local-lvm`, `local-zfs`). Must exist on the node.

* `VM_RAM`, `VM_CORES`, `DISK_SIZE`
  Template defaults for memory (MB), vCPUs and disk size.

* `NET_BRIDGE`
  Proxmox bridge interface to use (e.g. `vmbr0`, `vmbr1`, `vmbr04`).

* `SEARCHDOMAIN`, `NAMESERVER`
  Optional cloud-init DNS settings. Can be empty strings if you do not want the script to set them.

* `IPCONFIG`
  IP configuration for `ipconfig0` (e.g. `dhcp` or `192.168.10.50/24,gw=192.168.10.1`).

* `AUTHORIZED_KEYS`
  Path to a file containing SSH public keys to inject for the `local-admin` user.

* `ADMIN_PASSWORD_FILE` / `ADMIN_PASSWORD`

  * If `ADMIN_PASSWORD` is set in the environment or `.env`, it is used as the password for `local-admin`.
  * Otherwise, if `ADMIN_PASSWORD_FILE` points to a readable file, its content is used.
  * If both are missing/empty, the `local-admin` user is configured as SSH-key-only (no password login).

* `TIMEZONE`
  Timezone to set inside the templates, e.g. `Europe/Berlin`.

* `SYSPREP_OPS`
  Comma-separated list of `virt-sysprep` operations to run on the images.

* `SKIP_IF_BASE_UNCHANGED`
  If set to `true`, the script skips rebuilding a template when:

  * a VM with the target VMID already exists, and
  * the base image file has the same modification time as recorded in the last run.

* `RESIZE_WAIT_ENABLED`
  If set to `true`, the script waits before and after disk resize (sleep 30s + 60s).
  This is a workaround for Proxmox disk import/resize timing issues.
  You can disable it either by setting `RESIZE_WAIT_ENABLED="false"` in `.env` or by using `--no-resize-wait`.

---

## Usage

From the repository directory:

### Interactive mode (default, using fzf)

./pve-cloudinit-template-builder.sh

You will be presented with a list of base images (Debian, Ubuntu, openSUSE).
Use SPACE to select multiple entries and ENTER to start template creation.
Selecting `ALL` will build all supported images.

### Non-interactive mode

Build all templates without interaction:

./pve-cloudinit-template-builder.sh --non-interactive

(You can also use `--all`, which is treated the same.)

### Disabling resize waits

If you know your environment does not suffer from the Proxmox disk import/resize timing issue, you can skip the sleeps:

./pve-cloudinit-template-builder.sh --no-resize-wait

Alternatively, set in `.env`:

RESIZE_WAIT_ENABLED="false"

### Help

./pve-cloudinit-template-builder.sh --help

---

## Logging

The script writes:

* Human-readable progress messages to the terminal (high-level status).
* Full command output and details (including `wget`, `virt-sysprep`, `virt-customize`, `qm`, `pvesm` messages) into a log file.

Logs are stored in:

* `${DOWNLOAD_DIR}/logs/template-creation-YYYYMMDD-HHMMSS.log`

If something goes wrong, you will see a short error message in the terminal with the path to the log file. The log contains all the underlying command output for troubleshooting.

State files for `SKIP_IF_BASE_UNCHANGED` are stored in:

* `${DOWNLOAD_DIR}/state/`

---

## VM IDs

The script uses fixed VMIDs for each template (one VMID per distribution).
You should ensure these VMIDs are free on your Proxmox node before running the script for the first time.

If you want to change VMIDs, adjust them in the script (or extend the script to read them from `.env` as well).

---

## CI and Shellcheck

This repository includes a GitHub Actions workflow that:

* Runs `shellcheck` against `pve-cloudinit-template-builder.sh`
* Is triggered on:

  * Changes to the script,
  * Changes to `.env.example`,
  * Changes to the workflow file itself.

This helps keep the script shellcheck-clean and maintainable over time.

---

## Known limitations / notes

* The script assumes it is running on a trusted Proxmox node (no hardening of secrets, no untrusted input handling).
* The resize sleeps are a pragmatic workaround for Proxmox timing/locking behavior on some setups. If you disable them and see sporadic resize errors, re-enable the waits.
* The script focuses on KVM/cloud-init images and does not handle ISOs or non-cloud-init templates.
* The openSUSE image URLs may change over time; if downloads fail with `404`, check the upstream images and adjust the URLs in the script accordingly.

---

## Contributing

Contributions are welcome. Typical ways to contribute:

* Fix or update image URLs when upstream changes.
* Add support for additional distributions or images.
* Improve error handling, logging, or configuration flexibility.
* Extend `.env` handling (e.g. make VMIDs configurable).

Please:

1. Fork the repository.
2. Create a feature branch.
3. Run `shellcheck` locally or rely on the provided GitHub Actions workflow.
4. Open a pull request with a clear description of the change.

---

## License

This project is provided under the MIT License.
