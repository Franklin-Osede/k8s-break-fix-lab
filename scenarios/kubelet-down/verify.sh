#!/usr/bin/env bash
# Checks whether the kubelet-down scenario has been fixed.
# Usage: ./verify.sh [node]   (default node: node01)
# Env:   VERIFY_TIMEOUT=<seconds>  how long to wait for Ready (default 60)
# Exit:  0 recovered | 1 still NotReady | 2 connection/permission error
set -euo pipefail

SCENARIO="kubelet-down"
NODE="${1:-node01}"
TIMEOUT="${VERIFY_TIMEOUT:-60}"
INTERVAL=5

# shellcheck source=SCRIPTDIR/../../scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../scripts/lib.sh"

[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || die "VERIFY_TIMEOUT must be a whole number of seconds."

# Read-only, but still only ever look at the lab cluster (exits 2 otherwise).
require_lab_context

deadline=$((SECONDS + TIMEOUT))
while true; do
  # Any kubectl failure here means we cannot tell: connection or RBAC problem.
  if ! status="$(node_ready_status "$NODE" 2>&1)"; then
    printf 'ERROR: cannot read node %s: %s\n' "$NODE" "$status" >&2
    exit 2
  fi

  if [[ "$status" == "True" ]]; then
    printf 'RECOVERED: node %s is Ready.\n' "$NODE"
    state_mark_recovered "$SCENARIO" "$NODE"
    exit 0
  fi

  ((SECONDS < deadline)) || break
  sleep "$INTERVAL"
done

printf 'NOT FIXED: node %s is still NotReady after %ss (Ready=%s).\n' "$NODE" "$TIMEOUT" "${status:-unknown}"
exit 1
