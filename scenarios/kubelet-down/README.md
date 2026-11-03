# kubelet-down

## Symptom

After injection, `kubectl get nodes` reports the target node (default `node01`) as
`NotReady`. The status change can take up to about a minute to appear.

## Goal

Bring the node back to `Ready` without deleting, draining or re-joining it.

## Run

```bash
export K8S_BREAK_FIX_LAB=1
./inject.sh [node]    # break it
./verify.sh [node]    # check your fix (VERIFY_TIMEOUT=60 by default)
./reset.sh [node]     # give up and restore the healthy state
```
