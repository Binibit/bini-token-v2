#!/usr/bin/env bash
set -euo pipefail

run_fork_suite() {
  MAINNET_RPC_URL="$1" forge test --match-path 'test/fork/*' -vv
}

if [[ -n "${MAINNET_RPC_URL:-}" ]]; then
  echo "running pinned fork suite with configured archive RPC"
  if run_fork_suite "$MAINNET_RPC_URL"; then
    exit 0
  fi
  echo "configured archive RPC failed; trying public fallbacks" >&2
fi

for rpc_url in https://eth.drpc.org https://1rpc.io/eth; do
  echo "running pinned fork suite with public archive fallback"
  if run_fork_suite "$rpc_url"; then
    exit 0
  fi
done

echo "pinned mainnet-fork suite failed on every archive RPC" >&2
exit 1
