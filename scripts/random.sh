#!/usr/bin/env bash
# Blind mode: injects a random scenario without saying which one.
#
# Usage:
#   K8S_BREAK_FIX_LAB=1 scripts/random.sh [node]   inject a random scenario (default node: node01)
#   scripts/random.sh reveal                       print the recorded scenario and status
#   scripts/random.sh check                        run its verify.sh; mark recovered on success
#   K8S_BREAK_FIX_LAB=1 scripts/random.sh reset    run its reset.sh
set -euo pipefail

# shellcheck source=SCRIPTDIR/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# Load scenario and node from the state file and validate them, since the
# scenario name becomes part of a path we execute.
load_recorded() {
  SCENARIO="$(state_get scenario)"
  NODE="$(state_get node)"
  [[ -n "$SCENARIO" ]] || die "No injection recorded in ${STATE_FILE}."
  [[ "$SCENARIO" =~ ^[a-z0-9-]+$ && -d "${LAB_ROOT}/scenarios/${SCENARIO}" ]] ||
    die "Recorded scenario '${SCENARIO}' is not valid."
}

cmd_inject() {
  local node="${1:-node01}" scenarios=() dir chosen log_file rc

  require_lab_switch
  require_lab_context
  require_no_active_injection

  # Every folder under scenarios/ with an inject.sh is a candidate.
  for dir in "${LAB_ROOT}"/scenarios/*/; do
    if [[ -x "${dir}inject.sh" ]]; then scenarios+=("${dir%/}"); fi
  done
  ((${#scenarios[@]} > 0)) || die "No scenarios found."
  chosen="${scenarios[RANDOM % ${#scenarios[@]}]}"

  # The scenario's own output would give it away, so keep it in a private log.
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  log_file="${STATE_DIR}/last-inject.log"
  (umask 077 && : >"$log_file")

  rc=0
  "${chosen}/inject.sh" "$node" >"$log_file" 2>&1 || rc=$?
  if ((rc != 0)); then
    log "Injection failed (exit ${rc}). Details, with spoilers: ${log_file}"
    log "Then run: scripts/random.sh reveal / reset"
    exit 2
  fi
  log "A random scenario is active on ${node}. Start troubleshooting."
  log "When done: scripts/random.sh check"
}

cmd_reveal() {
  [[ -f "$STATE_FILE" ]] || {
    echo "No injection recorded."
    return 0
  }
  cat "$STATE_FILE"
}

cmd_check() {
  local rc=0
  load_recorded
  "${LAB_ROOT}/scenarios/${SCENARIO}/verify.sh" "$NODE" || rc=$?
  # verify.sh already updates the state; doing it here too keeps check's
  # contract explicit and is harmless.
  ((rc == 0)) && state_mark_recovered "$SCENARIO" "$NODE"
  return "$rc"
}

cmd_reset() {
  load_recorded
  "${LAB_ROOT}/scenarios/${SCENARIO}/reset.sh" "$NODE"
}

case "${1:-}" in
  reveal) cmd_reveal ;;
  check) cmd_check ;;
  reset) cmd_reset ;;
  -h | --help) sed -n '2,9p' "$0" ;;
  *) cmd_inject "${1:-}" ;;
esac
