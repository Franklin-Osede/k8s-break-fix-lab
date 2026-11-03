#!/usr/bin/env bash
# Minimal terminal setup that can be reproduced by hand inside the CKA exam.
# Idempotent: only appends lines that are missing; never overwrites files.
# Usage: bash setup/exam-shell.sh && source ~/.bashrc
set -euo pipefail

BASHRC="${HOME}/.bashrc"
VIMRC="${HOME}/.vimrc"

# Append a line to a file unless that exact line is already present.
append_once() {
  local file="$1" line="$2"
  touch "$file"
  grep -qxF -- "$line" "$file" && return 0
  # Make sure we start on a fresh line if the file lacks a trailing newline.
  if [[ -s "$file" && -n "$(tail -c 1 "$file")" ]]; then
    printf '\n' >>"$file"
  fi
  printf '%s\n' "$line" >>"$file"
  echo "added to ${file}: ${line}"
}

# Short alias and handy flag bundles, e.g. `k run x --image=nginx $do`.
append_once "$BASHRC" 'alias k=kubectl'
append_once "$BASHRC" 'export do="--dry-run=client -o yaml"'
append_once "$BASHRC" 'export now="--force --grace-period=0"'

# Bash completion for kubectl and for the `k` alias, only if it works here.
if command -v kubectl >/dev/null 2>&1 && kubectl completion bash >/dev/null 2>&1; then
  append_once "$BASHRC" 'source <(kubectl completion bash)'
  append_once "$BASHRC" 'complete -o default -F __start_kubectl k'
else
  echo "kubectl completion bash is not available; skipping completion."
fi

# YAML-friendly indentation in vim.
append_once "$VIMRC" 'set expandtab tabstop=2 shiftwidth=2'

echo "Done. Run: source ~/.bashrc"
