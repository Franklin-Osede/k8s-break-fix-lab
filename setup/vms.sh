#!/usr/bin/env bash
# Manages the disposable lab VMs with multipass (developed on Apple Silicon).
# It prepares plain Ubuntu VMs only: it does NOT install Kubernetes, containerd
# or any Kubernetes tooling. Installing the cluster with kubeadm is done by hand.
#
# Usage:
#   setup/vms.sh create            create controlplane, node01, node02
#   setup/vms.sh snapshot <name>   stop, snapshot all 3, start again
#   setup/vms.sh restore <name>    stop, restore all 3 to <name>, start again
#   setup/vms.sh status            show the 3 VMs and their snapshots
#   setup/vms.sh destroy           delete and purge the 3 VMs (asks first)
#
# Sizing (env overrides): CP_CPUS=2 CP_MEM=4G CP_DISK=20G
#                         WORKER_CPUS=2 WORKER_MEM=3G WORKER_DISK=15G
#                         UBUNTU_IMAGE=24.04
set -euo pipefail

# shellcheck source=SCRIPTDIR/../scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/lib.sh"

CP="controlplane"
WORKERS=(node01 node02)
VMS=("$CP" "${WORKERS[@]}")

UBUNTU_IMAGE="${UBUNTU_IMAGE:-24.04}"
CP_CPUS="${CP_CPUS:-2}"
CP_MEM="${CP_MEM:-4G}"
CP_DISK="${CP_DISK:-20G}"
WORKER_CPUS="${WORKER_CPUS:-2}"
WORKER_MEM="${WORKER_MEM:-3G}"
WORKER_DISK="${WORKER_DISK:-15G}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

require_multipass() {
  command -v multipass >/dev/null 2>&1 ||
    die "multipass is not installed (https://multipass.run/)."
}

vm_exists() { multipass info "$1" >/dev/null 2>&1; }

snapshot_exists() { multipass info "${1}.${2}" >/dev/null 2>&1; }

# Run a script (read from stdin) inside a VM. Passing the script on stdin
# avoids any quoting problems with multipass exec arguments.
vm_script() { multipass exec "$1" -- bash -s; }
vm_sudo_script() { multipass exec "$1" -- sudo bash -s; }

vm_ip() { multipass info "$1" | awk '/IPv4/ {print $2; exit}'; }

# Convert a size like 4G or 3072M to MiB.
to_mib() {
  if [[ "$1" =~ ^([0-9]+)[Gg]$ ]]; then
    echo $((BASH_REMATCH[1] * 1024))
  elif [[ "$1" =~ ^([0-9]+)[Mm]$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    die "Invalid memory size '$1' (use e.g. 4G or 3072M)."
  fi
}

# Memory the host can hand out now, in MiB (free + inactive + speculative pages on macOS).
host_free_mib() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    local page_size pages
    page_size="$(sysctl -n hw.pagesize)"
    pages="$(vm_stat | awk '/Pages (free|inactive|speculative)/ {gsub(/\./, "", $NF); s += $NF} END {print s + 0}')"
    echo $((pages * page_size / 1024 / 1024))
  else
    awk '/MemAvailable/ {print int($2 / 1024)}' /proc/meminfo
  fi
}

require_snapshot_name() {
  [[ "${1:-}" =~ ^[A-Za-z][A-Za-z0-9-]*$ ]] ||
    die "Give a snapshot name (letters, digits, dashes; starting with a letter)."
}

require_all_vms() {
  local vm
  for vm in "${VMS[@]}"; do
    vm_exists "$vm" || die "VM '${vm}' does not exist. Run: setup/vms.sh create"
  done
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

cmd_create() {
  local vm entry cp_mib worker_mib needed free entries=() pubkey

  # Refuse if any of the VMs already exists: never touch an existing VM.
  for vm in "${VMS[@]}"; do
    if vm_exists "$vm"; then
      die "VM '${vm}' already exists. Use 'status', or 'destroy' first."
    fi
  done

  # Check the host has enough free memory for all three VMs.
  cp_mib="$(to_mib "$CP_MEM")"
  worker_mib="$(to_mib "$WORKER_MEM")"
  needed=$((cp_mib + ${#WORKERS[@]} * worker_mib))
  free="$(host_free_mib)"
  if ((free < needed)); then
    die "Not enough free RAM: need ${needed} MiB, ${free} MiB available. Close apps or lower CP_MEM/WORKER_MEM."
  fi
  log "Free RAM ${free} MiB, need ${needed} MiB: OK."

  # Launch the VMs.
  log "Launching ${CP} (${CP_CPUS} CPU, ${CP_MEM}, ${CP_DISK})."
  multipass launch "$UBUNTU_IMAGE" --name "$CP" --cpus "$CP_CPUS" \
    --memory "$CP_MEM" --disk "$CP_DISK" --timeout 600
  for vm in "${WORKERS[@]}"; do
    log "Launching ${vm} (${WORKER_CPUS} CPU, ${WORKER_MEM}, ${WORKER_DISK})."
    multipass launch "$UBUNTU_IMAGE" --name "$vm" --cpus "$WORKER_CPUS" \
      --memory "$WORKER_MEM" --disk "$WORKER_DISK" --timeout 600
  done

  # /etc/hosts on every VM. cloud-init regenerates /etc/hosts on boot when
  # manage_etc_hosts is on, so turn that off first or the entries get lost.
  for vm in "${VMS[@]}"; do
    entries+=("$(vm_ip "$vm") ${vm}")
  done
  for vm in "${VMS[@]}"; do
    log "Updating /etc/hosts on ${vm}."
    {
      echo 'set -eu'
      echo "echo 'manage_etc_hosts: false' > /etc/cloud/cloud.cfg.d/99-k8s-break-fix-lab.cfg"
      for entry in "${entries[@]}"; do
        printf 'grep -qxF %q /etc/hosts || echo %q >> /etc/hosts\n' "$entry" "$entry"
      done
    } | vm_sudo_script "$vm"
  done

  # Disable swap now and permanently (comment out swap lines in /etc/fstab).
  for vm in "${VMS[@]}"; do
    log "Disabling swap on ${vm}."
    vm_sudo_script "$vm" <<'EOF'
set -eu
swapoff -a
sed -i -E '/^[[:space:]]*[^#[:space:]].*[[:space:]]swap[[:space:]]/ s/^/#/' /etc/fstab
EOF
  done

  # ssh key for ubuntu on the control plane, authorised on the workers.
  log "Setting up ssh from ${CP} to the workers."
  vm_script "$CP" <<'EOF'
set -eu
mkdir -p ~/.ssh && chmod 700 ~/.ssh
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -f ~/.ssh/id_ed25519 -C ubuntu@controlplane
EOF
  pubkey="$(multipass exec "$CP" -- cat /home/ubuntu/.ssh/id_ed25519.pub)"
  for vm in "${WORKERS[@]}"; do
    {
      echo 'set -eu'
      echo 'mkdir -p ~/.ssh && chmod 700 ~/.ssh'
      echo 'touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'
      printf 'grep -qxF %q ~/.ssh/authorized_keys || echo %q >> ~/.ssh/authorized_keys\n' "$pubkey" "$pubkey"
    } | vm_script "$vm"
  done

  # Trust the workers' host keys so non-interactive ssh (BatchMode) works.
  {
    echo 'set -eu'
    for vm in "${WORKERS[@]}"; do
      printf 'ssh-keygen -F %q >/dev/null || ssh-keyscan -H %q >> ~/.ssh/known_hosts 2>/dev/null\n' "$vm" "$vm"
    done
  } | vm_script "$CP"

  for vm in "${WORKERS[@]}"; do
    multipass exec "$CP" -- ssh -o BatchMode=yes "$vm" true ||
      die "ssh from ${CP} to ${vm} does not work."
  done

  log "Done. VMs are ready for a manual kubeadm install (see README, 'Lab VMs')."
  cmd_status
}

cmd_snapshot() {
  local name="${1:-}" vm
  require_snapshot_name "$name"
  require_all_vms

  # Check first, so we never stop the VMs for nothing.
  for vm in "${VMS[@]}"; do
    if snapshot_exists "$vm" "$name"; then
      die "Snapshot '${name}' already exists on ${vm}."
    fi
  done

  log "Stopping VMs."
  multipass stop "${VMS[@]}"
  for vm in "${VMS[@]}"; do
    log "Snapshotting ${vm} as '${name}'."
    if ! multipass snapshot --name "$name" "$vm"; then
      multipass start "${VMS[@]}" || true
      die "Snapshot of ${vm} failed; VMs restarted."
    fi
  done
  log "Starting VMs."
  multipass start "${VMS[@]}"
}

cmd_restore() {
  local name="${1:-}" vm
  require_snapshot_name "$name"
  require_all_vms

  # All three snapshots must exist before anything is stopped.
  for vm in "${VMS[@]}"; do
    snapshot_exists "$vm" "$name" || die "Snapshot '${name}' not found on ${vm}."
  done

  log "Stopping VMs."
  multipass stop "${VMS[@]}"
  for vm in "${VMS[@]}"; do
    log "Restoring ${vm} to '${name}'."
    # --destructive: discard the current state without taking another snapshot.
    if ! multipass restore --destructive "${vm}.${name}"; then
      multipass start "${VMS[@]}" || true
      die "Restore of ${vm} failed; VMs restarted."
    fi
  done
  log "Starting VMs."
  multipass start "${VMS[@]}"
}

# Filter multipass tables to the header plus rows for our 3 VMs.
filter_lab_rows() {
  awk -v names="${VMS[*]}" 'BEGIN {split(names, n, " "); for (i in n) want[n[i]] = 1}
    NR == 1 || ($1 in want)'
}

cmd_status() {
  multipass list | filter_lab_rows
  echo
  multipass list --snapshots 2>/dev/null | filter_lab_rows || true
}

cmd_destroy() {
  local answer vm
  echo "This deletes and purges these VMs: ${VMS[*]}"
  read -r -p 'Type "destroy" to confirm: ' answer
  [[ "$answer" == "destroy" ]] || die "Not confirmed; nothing deleted."

  # Only our VMs; --purge with names never touches other deleted instances.
  for vm in "${VMS[@]}"; do
    if vm_exists "$vm"; then
      log "Deleting ${vm}."
      multipass delete --purge "$vm"
    fi
  done
  log "Done."
}

# ---------------------------------------------------------------------------

case "${1:-}" in
  create) require_multipass && cmd_create ;;
  snapshot) require_multipass && cmd_snapshot "${2:-}" ;;
  restore) require_multipass && cmd_restore "${2:-}" ;;
  status) require_multipass && cmd_status ;;
  destroy) require_multipass && cmd_destroy ;;
  *) sed -n '2,15p' "$0" ;;
esac
