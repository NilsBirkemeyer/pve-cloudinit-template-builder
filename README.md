# PVE Cloud-Init Template Builder

This repository provides a Bash script that automates the creation of cloud-init–enabled VM templates for Proxmox VE. It downloads official cloud images (Debian, Ubuntu, openSUSE), applies customization via `virt-sysprep` and `virt-customize`, and then converts the resulting VMs into reusable templates.

The script supports both interactive template selection (via `fzf`) and fully non-interactive batch mode, and includes basic caching and state tracking to avoid unnecessary rebuilds.

---

## Features

* Automated creation of Proxmox VE templates for:

  * Debian 12 (Bookworm)
  * Debian 13 (Trixie)
  * Ubuntu 22.04 LTS (Jammy)
  * Ubuntu 24.04 LTS (Noble)
  * openSUSE Leap 15.6
  * openSUSE Tumbleweed
* Uses official cloud images (QCOW2/IMG) with timestamp-based update checks (`wget -N`)
* Leverages `virt-sysprep` to clean up machine-specific data
* Uses `virt-customize` to:

  * Install guest tools (e.g., `qemu-guest-agent`)
  * Configure the timezone
* Proxmox VM configuration:

  * VirtIO disk and network
  * Cloud-Init drive
  * QEMU Guest Agent enabled
  * Ballooning configured
* SSH-key–only admin user by default, with optional password
* State tracking to skip template rebuilds if the base image has not changed
* Interactive multi-select of distributions via `fzf`
* Non-interactive `--all` mode
* Optional sleep-based workaround around Proxmox disk import/resize timing quirks

---

## Warning

This script will destroy and recreate VMs using the configured VMIDs.

For each template, it runs:

* `qm destroy <VMID> --purge`

before creating a new VM and converting it into a template. Make sure the VMIDs you configure are not used by anything important in your environment.

---

## Requirements

On the Proxmox VE node where you run the script:

* Proxmox VE with:

  * `qm` binary available (standard on Proxmox)
  * A configured storage pool (e.g., `local-zfs`, `local-lvm`)
* Installed tools:

  * `wget`
  * `virt-sysprep`
  * `virt-customize`
  * `stat`
  * `pvesm`
  * `fzf` (only required for interactive mode)
* Network access to the official cloud image mirrors (Debian, Ubuntu, openSUSE)
* Sufficient disk space in:

  * The template download directory
  * The selected Proxmox storage pool

The script assumes you are running it as `root` on a trusted Proxmox host.

Tested on:

* Proxmox VE 9.1.2 (single node; homogeneous CPU environment)

---

## Repository layout

* `pve-cloudinit-template-builder.sh`

  * Main script that creates and updates the templates.
* `.github/workflows/shellcheck.yml` (optional)

  * GitHub Actions workflow to run `shellcheck` against the script.

---

## Configuration

Most configuration is done by editing the header section of `pve-cloudinit-template-builder.sh`.

### Base paths and storage

Set these to match your environment:

* `DOWNLOAD_DIR`

  * Directory on the Proxmox node where base cloud images, logs, and state are stored.
  * Example: `/local-zfs/templates`
* `STORAGE_POOL`

  * Name of the Proxmox storage where VM disks and the cloud-init drive will be created.
  * Example: `local-zfs` or `local-lvm`

Both variables must be set to non-placeholder values. The script will abort if they are left as the default placeholders.

### VM IDs

Each template uses a fixed VMID by default:

* `DEBIAN_12_VMID=9000`
* `DEBIAN_13_VMID=9001`
* `UBUNTU_2204_VMID=9002`
* `UBUNTU_2404_VMID=9003`
* `OPENSUSE_LEAP_156_VMID=9004`
* `OPENSUSE_TUMBLEWEED_VMID=9005`

You can adjust these IDs in the script header to match your own VMID planning. The script will destroy any existing VM with those IDs before recreating templates.

### Resources (RAM, CPU, disk size)

Adjust as appropriate for your typical workloads:

* `VM_RAM`

  * RAM in MB for each template (e.g., `2048`, `4096`, `8192`)
* `VM_CORES`

  * Number of CPU cores (e.g., `2`, `4`)
* `DISK_SIZE`

  * Size of the main disk after resize (e.g., `"8G"`, `"16G"`, `"32G"`)

### Network / Cloud-Init

* `NET_BRIDGE`

  * Proxmox bridge to attach (e.g., `vmbr0`)
* `SEARCHDOMAIN`

  * Optional DNS search domain; can be empty (`""`)
* `NAMESERVER`

  * Optional DNS server IP; can be empty (`""`)
* `IPCONFIG`

  * Cloud-Init IP configuration, either DHCP or static.
  * Examples:

    * `IPCONFIG="dhcp"`
    * `IPCONFIG="192.168.10.50/24,gw=192.168.10.1"`

If `SEARCHDOMAIN` or `NAMESERVER` are left as placeholders, the script will abort. If you do not want to set them via Cloud-Init, set them to an empty string.

### Authentication

* `AUTHORIZED_KEYS`

  * Path to a file containing the SSH public keys for the `local-admin` user.
  * This file must exist; otherwise, the script will abort.
* `ADMIN_PASSWORD_FILE`

  * Optional path to a file containing the admin password.
* `ADMIN_PASSWORD`

  * Optional environment variable to provide the admin password.
  * If not set, and `ADMIN_PASSWORD_FILE` does not exist, `local-admin` will be created without a password (SSH-key only).

On a trusted host, using `ADMIN_PASSWORD` or `ADMIN_PASSWORD_FILE` is acceptable, but keep in mind that:

* The password is passed to `qm set --cipassword`, which means it may briefly appear in the process list.

If you want SSH-key–only logins, simply do not set `ADMIN_PASSWORD` and do not create `ADMIN_PASSWORD_FILE`.

### Timezone

* `TIMEZONE`

  * Timezone string used during `virt-customize`.
  * Example: `Europe/Berlin`

---

## Behavior toggles (environment variables)

### SKIP_IF_BASE_UNCHANGED

* `SKIP_IF_BASE_UNCHANGED=true`

  * If set, the script compares the modification time of the downloaded base image with a stored timestamp in the state directory.
  * If the image timestamp is unchanged and the VMID already exists, the template rebuild is skipped.
* Default: `false`

Example:

SKIP_IF_BASE_UNCHANGED=true ./pve-cloudinit-template-builder.sh --all

### RESIZE_WAIT_ENABLED

There is a timing issue, at least for me, around disk import and resize operations on some Proxmox setups. To work around this, the script:

* Waits 30 seconds before `qm resize`
* Waits 60 seconds after `qm resize`

This behavior is controlled by:

* `RESIZE_WAIT_ENABLED=true` (default)

  * Enables the sleep calls.
* `RESIZE_WAIT_ENABLED=false`

  * Disables the sleep calls.

You can also override this via a CLI flag (`--no-resize-wait`), see below.

---

## Command-line usage

Clone the repository to your Proxmox node, for example:

git clone [https://github.com/](https://github.com/)<your-username>/pve-cloudinit-template-builder.git
cd pve-cloudinit-template-builder
chmod +x pve-cloudinit-template-builder.sh

Basic usage:

./pve-cloudinit-template-builder.sh

This will:

* Run in interactive mode.
* Use `fzf` to let you select which templates to build.

### Options

* `--all` / `--non-interactive`

  * Build all templates without an interactive `fzf` prompt.
  * Equivalent to selecting `ALL` in the interactive menu.
* `--no-resize-wait`

  * Disables the wait before/after disk resize, overriding `RESIZE_WAIT_ENABLED`.
* `--help` / `-h`

  * Print usage information and exit.

Examples:

1. Interactive selection:

   ./pve-cloudinit-template-builder.sh

2. Build all templates non-interactively:

   ./pve-cloudinit-template-builder.sh --all

3. Build all templates, skip rebuilds if base images are unchanged:

   SKIP_IF_BASE_UNCHANGED=true ./pve-cloudinit-template-builder.sh --all

4. Build all templates without any disk resize waits:

   RESIZE_WAIT_ENABLED=false ./pve-cloudinit-template-builder.sh --all

   or:

   ./pve-cloudinit-template-builder.sh --all --no-resize-wait

5. Provide an admin password via environment variable:

   ADMIN_PASSWORD='your-secure-password' ./pve-cloudinit-template-builder.sh --all

---

## Templates created

For each selected distribution, the script will:

1. Download or update the cloud image into `${DOWNLOAD_DIR}`.
2. Create a working copy and run `virt-sysprep` and `virt-customize`.
3. Create a Proxmox VM with the configured VMID.
4. Import the disk to `STORAGE_POOL`.
5. Attach the disk as `virtio0` with writeback cache and discard enabled.
6. Attach a Cloud-Init drive (`ide2`).
7. Configure VM options:

   * `--agent enabled=1`
   * `--boot c --bootdisk virtio0`
   * `--hotplug disk,network,usb`
   * `--serial0 socket`
   * `--vga serial0`
   * `--cpu cputype=host`
   * `--ostype l26`
   * `--balloon` to half of `VM_RAM`
   * `--ciuser local-admin`
   * `--sshkeys` set from `AUTHORIZED_KEYS`
   * `--cipassword` if configured
   * Optional `--searchdomain` and `--nameserver` if configured
   * `--ipconfig0` set from `IPCONFIG`
8. Resize the main disk to `DISK_SIZE`.
9. Convert the VM to a template via `qm template`.

The resulting template names are:

* `cloudinit-template-debian-12`
* `cloudinit-template-debian-13`
* `cloudinit-template-ubuntu-22.04`
* `cloudinit-template-ubuntu-24.04`
* `cloudinit-template-opensuse-leap-15.6`
* `cloudinit-template-opensuse-tumbleweed`

---

## Logging and state

* Logs:

  * Written to `${DOWNLOAD_DIR}/logs/template-creation-YYYYMMDD-HHMMSS.log`
  * All script output goes both to the console and to the log file.
* State:

  * A simple state file is maintained in `${DOWNLOAD_DIR}/state/vm-<VMID>.state`.
  * It stores the `stat -c %Y` modification time of the underlying base image.
  * Used in combination with `SKIP_IF_BASE_UNCHANGED`.

On error, the script prints a short error message and the log file path.

---

## Security considerations

* The script is intended to run on a trusted Proxmox VE host.
* SSH keys are required for the `local-admin` user via `AUTHORIZED_KEYS`.
* Admin password:

  * Using `ADMIN_PASSWORD` or `ADMIN_PASSWORD_FILE` will configure a cloud-init password for `local-admin`.
  * As with any CLI-based password handling, the password may appear briefly in the process list during `qm set --cipassword`.
* If you want to avoid password exposure:

  * Do not set `ADMIN_PASSWORD`.
  * Do not create `ADMIN_PASSWORD_FILE`.
  * Use SSH keys only.

---

## Troubleshooting

* `ERROR: STORAGE_POOL '<YOUR_STORAGE_POOL>' does not exist on this node.`

  * Ensure the storage name matches `Datacenter -> Storage` in the Proxmox web UI.
* `ERROR: authorized_keys file not found`

  * Check that the path in `AUTHORIZED_KEYS` is correct and the file contains at least one valid SSH public key.
* `ERROR: Base image <file> not found after download.`

  * Check file permissions and free space in `DOWNLOAD_DIR`.
  * Ensure the host can reach the respective cloud image URLs.
* `ERROR: Could not find imported disk for VM <ID> on storage <STORAGE_POOL>`

  * Verify that `pvesm list <STORAGE_POOL>` returns the expected `vm-<ID>-disk-*` volumes.
  * Check storage type and permissions.

---

## Notes

* The script sets `cputype=host`. This is usually fine on a single node or homogeneous cluster. On heterogeneous clusters or when heavy live-migration is required, you may want to adjust this in the script.
* The disk import/resize waits are present as a workaround for timing issues observed on some Proxmox setups. They can be disabled if your environment does not need them.
