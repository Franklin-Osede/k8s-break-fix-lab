#!/usr/bin/env bash
# Restores the healthy state for the kubelet-down scenario.
# Safe to run repeatedly. Uses `systemctl start` only: it never enables a
# service, so a kubelet that was disabled before the scenario stays disabled.
# Usage: K8S_BREAK_FIX_LAB=1 ./reset.sh [node]   (default node: node01)
set -euo pipefail

NODE="${1:-node01}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=SCRIPTDIR/../../scripts/lib.sh
source "${SCRIPT_DIR}/../../scripts/lib.sh"

require_lab_switch
require_lab_context
require_worker_node "$NODE"

# Start the kubelet only if it is not already running.
lab_ssh "$NODE" 'systemctl is-active --quiet kubelet || sudo -n systemctl start kubelet' ||
  die "Could not start the kubelet on ${NODE} (ssh or sudo error)."
log "kubelet start requested on ${NODE}; waiting for the node to become Ready."

# Confirm recovery; verify.sh marks the state as recovered on success.
"${SCRIPT_DIR}/verify.sh" "$NODE"
