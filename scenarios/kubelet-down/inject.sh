#!/usr/bin/env bash
# Breaks the target node for the kubelet-down scenario.
# Usage: K8S_BREAK_FIX_LAB=1 ./inject.sh [node]   (default node: node01)
set -euo pipefail

SCENARIO="kubelet-down"
NODE="${1:-node01}"

# shellcheck source=SCRIPTDIR/../../scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../scripts/lib.sh"

# Safety first: opt-in switch, right cluster, nothing pending, worker only.
require_lab_switch
require_lab_context
require_no_active_injection
require_worker_node "$NODE"
require_node_ready "$NODE"

# Record the attempt BEFORE touching the node, so an interrupted or failed
# injection (e.g. ssh drops) is still visible and recoverable.
state_write "$SCENARIO" "$NODE" injecting

# Stop (but do not disable) the kubelet on the node.
if lab_ssh "$NODE" 'sudo -n systemctl stop kubelet'; then
  state_write "$SCENARIO" "$NODE" active
  log "Injection complete on ${NODE}."
else
  state_write "$SCENARIO" "$NODE" failed
  die "Injection failed on ${NODE} (ssh or sudo error). Run ./reset.sh ${NODE} to restore."
fi
