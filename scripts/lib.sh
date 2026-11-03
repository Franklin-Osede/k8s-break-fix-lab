#!/usr/bin/env bash
# Shared safety checks and state handling for k8s-break-fix-lab.
# This file is meant to be sourced by the other scripts, not executed.

# Repository root (one level above scripts/).
LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export LAB_ROOT

# The only kubeconfig context the lab will ever act on.
LAB_CONTEXT="${LAB_CONTEXT:-kubernetes-admin@kubernetes}"

# Local state file: one injection at a time.
STATE_DIR="${HOME}/.k8s-break-fix"
STATE_FILE="${STATE_DIR}/state"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

log() { printf '[lab] %s\n' "$*" >&2; }

# Errors and refusals exit with 2 so they are never confused with
# "not fixed yet" (exit 1) from a verify.sh script.
die() {
  printf '[lab] ERROR: %s\n' "$*" >&2
  exit 2
}

# ---------------------------------------------------------------------------
# Safety checks
# ---------------------------------------------------------------------------

# Explicit opt-in switch, so nothing breaks by accident.
require_lab_switch() {
  [[ "${K8S_BREAK_FIX_LAB:-}" == "1" ]] ||
    die "Refusing to run: set K8S_BREAK_FIX_LAB=1 to confirm this is a disposable training cluster."
}

# Never touch any cluster other than the configured lab context.
require_lab_context() {
  local current
  current="$(kubectl config current-context 2>/dev/null)" ||
    die "Could not read the current kubeconfig context."
  [[ "$current" == "$LAB_CONTEXT" ]] ||
    die "Refusing to run: current context is '${current}', expected '${LAB_CONTEXT}' (override with LAB_CONTEXT)."
}

# Node scenarios must target workers only. A node counts as control plane if it
# carries a control-plane/master role label or runs a kube-apiserver pod.
require_worker_node() {
  local node="$1"
  kubectl get node "$node" >/dev/null 2>&1 ||
    die "Node '${node}' not found (or the API server is unreachable)."

  local label hits
  for label in node-role.kubernetes.io/control-plane node-role.kubernetes.io/master; do
    hits="$(kubectl get nodes -l "$label" -o name)" || die "Could not list nodes."
    if grep -qxF "node/${node}" <<<"$hits"; then
      die "Refusing to target '${node}': it is a control-plane node."
    fi
  done

  hits="$(kubectl get pods -n kube-system -l component=kube-apiserver \
    --field-selector "spec.nodeName=${node}" -o name)" || die "Could not list kube-system pods."
  [[ -z "$hits" ]] ||
    die "Refusing to target '${node}': it runs kube-apiserver."
}

# Prints the node's Ready condition status: True, False or Unknown.
node_ready_status() {
  kubectl get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
}

# Only inject into a healthy node, so the scenario starts from a known state.
require_node_ready() {
  local node="$1" status
  status="$(node_ready_status "$node")" || die "Could not read the status of node '${node}'."
  [[ "$status" == "True" ]] ||
    die "Node '${node}' is not Ready (status: ${status:-unknown}); refusing to inject."
}

# Run a command on a node over ssh. BatchMode and `sudo -n` in callers make it
# fail fast instead of hanging on a password prompt.
lab_ssh() {
  local node="$1"
  shift
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$node" "$@"
}

# ---------------------------------------------------------------------------
# State handling
# ---------------------------------------------------------------------------
# Format (plain key=value lines, never sourced):
#   scenario=<name>
#   node=<node>
#   timestamp=<UTC ISO 8601 of the last change>
#   status=injecting|active|failed|recovered

# Write the state file atomically with mode 600.
state_write() {
  local scenario="$1" node="$2" status="$3" tmp
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  tmp="$(umask 077 && mktemp "${STATE_DIR}/state.XXXXXX")"
  printf 'scenario=%s\nnode=%s\ntimestamp=%s\nstatus=%s\n' \
    "$scenario" "$node" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$status" >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

# Print one value from the state file (empty if missing).
state_get() {
  [[ -f "$STATE_FILE" ]] || return 0
  sed -n "s/^${1}=//p" "$STATE_FILE" | head -n 1
}

# Refuse a new injection while a previous one is not recovered. "failed" and
# "injecting" count as active: the cluster may be half-broken.
require_no_active_injection() {
  local status
  status="$(state_get status)"
  case "$status" in
    "" | recovered) ;;
    *) die "A previous injection is still recorded as '${status}'. Fix it and run 'scripts/random.sh check', or run 'scripts/random.sh reset' (see 'scripts/random.sh reveal')." ;;
  esac
}

# Mark the recorded injection as recovered, but only if it matches.
state_mark_recovered() {
  local scenario="$1" node="$2"
  if [[ "$(state_get scenario)" == "$scenario" && "$(state_get node)" == "$node" ]]; then
    state_write "$scenario" "$node" recovered
  fi
}
