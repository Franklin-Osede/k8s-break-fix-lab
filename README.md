# k8s-break-fix-lab

A small, reproducible break-and-fix lab for practising Kubernetes troubleshooting on a
disposable local kubeadm cluster. A script breaks something, you diagnose and fix it with
the usual tools (`kubectl`, `ssh`, `systemctl`, `journalctl`, ...), and another script
checks your fix.

I built it for CKA preparation. It grows only with scenarios that come out of my own
practice.

> **Warning:** this lab deliberately breaks clusters. Use it **only** on disposable local
> training clusters. Never point it at a shared, staging or production cluster.

## Prerequisites

- A kubeadm cluster with at least one worker node that you can reach by `ssh <node-name>`
  from where you run the scripts, with passwordless `sudo` on that node.
- `kubectl` configured for that cluster, and `bash`.
- Developed on 3 Ubuntu VMs (1 control plane, 2 workers) created with
  [multipass](https://multipass.run/) on Apple Silicon.

Cluster creation is intentionally manual for now: installing a cluster with kubeadm is an
exam skill worth practising by hand. Automation may come later.

## Safety switches

Every injection goes through the checks in [scripts/lib.sh](scripts/lib.sh):

| Check | Behaviour |
| --- | --- |
| `K8S_BREAK_FIX_LAB=1` | Must be set, or nothing is broken. |
| `LAB_CONTEXT` | The current kubeconfig context must equal it. Default: `kubernetes-admin@kubernetes`. |
| Control-plane guard | Nodes with a control-plane/master role label or a kube-apiserver pod are refused as targets. |
| One at a time | A new injection is refused while a previous one is still `injecting`, `active` or `failed`. |

State is kept in `~/.k8s-break-fix/state` (mode 600): scenario, target node, timestamp and
status (`injecting`, `active`, `failed`, `recovered`). It is written **before** anything is
broken, so an interrupted injection (for example a dropped ssh session) is still recorded
and can be reset.

```bash
export K8S_BREAK_FIX_LAB=1
export LAB_CONTEXT=kubernetes-admin@kubernetes   # only if yours differs
```

## Usage

### Blind mode

```bash
scripts/random.sh [node]     # inject a random scenario (default node: node01), name not shown
scripts/random.sh check      # run the scenario's verify.sh; marks it recovered on success
scripts/random.sh reveal     # show the recorded scenario and status
scripts/random.sh reset      # restore the healthy state
```

With only one scenario, blind mode is not really blind yet. It becomes useful as more
scenarios are added.

### A specific scenario

```bash
scenarios/kubelet-down/inject.sh [node]
scenarios/kubelet-down/verify.sh [node]   # exit 0 fixed, 1 not fixed, 2 error
scenarios/kubelet-down/reset.sh [node]
```

`verify.sh` waits up to `VERIFY_TIMEOUT` seconds (default 60) for the fix to take effect.

### Exam terminal setup

[setup/exam-shell.sh](setup/exam-shell.sh) adds only what you can also type by hand in
the exam terminal: `alias k=kubectl`, completion for `k`, `$do` and `$now`, plus 2-space
indentation in vim. It only appends missing lines and never overwrites existing files.

```bash
bash setup/exam-shell.sh && source ~/.bashrc
```

## Scenarios

| Scenario | Symptom |
| --- | --- |
| [kubelet-down](scenarios/kubelet-down/README.md) | A worker node is `NotReady`. |

## Adding a scenario

Create `scenarios/<name>/` (lowercase letters, digits and dashes) with:

- `README.md`: describes the **symptom only** (what you would observe), never the cause
  or the fix.
- `inject.sh`: breaks the cluster. It must source `scripts/lib.sh`, call
  `require_lab_switch`, `require_lab_context`, `require_no_active_injection` (and
  `require_worker_node` for node scenarios), then `state_write <name> <node> injecting`
  **before** breaking anything, and `active` or `failed` afterwards.
- `verify.sh`: exits `0` when fixed, `1` when not fixed yet, `2` on connection or permission
  errors, and calls `state_mark_recovered` on success. Its output should describe symptoms,
  not the cause.
- `reset.sh`: restores the healthy state. It must be safe to run repeatedly and must not
  change anything the scenario did not change.

Conventions: `set -euo pipefail`, comments, an optional target node argument (default
`node01`), node-level actions over `ssh`. Make the scripts executable; `random.sh` picks up
any folder with an executable `inject.sh`.

## License

[MIT](LICENSE)
