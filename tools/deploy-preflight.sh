#!/usr/bin/env bash
set -euo pipefail

required=(
  DEPLOY_RPC_URL
  EXPECTED_CHAIN_ID
  ADMIN_TIMELOCK
  EMERGENCY_PAUSER_SAFE
  GENESIS_DISTRIBUTION_SAFE
  ADMIN_TRANSFER_DELAY
  DEPLOYER_ADDRESS
)

for name in "${required[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    echo "missing required environment variable: $name" >&2
    exit 1
  fi
done

actual_chain_id="$(cast chain-id --rpc-url "$DEPLOY_RPC_URL")"
if [[ "$actual_chain_id" != "$EXPECTED_CHAIN_ID" ]]; then
  echo "chain id mismatch: expected $EXPECTED_CHAIN_ID, RPC returned $actual_chain_id" >&2
  exit 1
fi

for name in ADMIN_TIMELOCK EMERGENCY_PAUSER_SAFE GENESIS_DISTRIBUTION_SAFE; do
  address="${!name}"
  cast to-checksum "$address" >/dev/null
  code="$(cast code "$address" --rpc-url "$DEPLOY_RPC_URL")"
  if [[ "$code" == "0x" ]]; then
    echo "$name has no deployed contract code: $address" >&2
    exit 1
  fi
done

cast to-checksum "$DEPLOYER_ADDRESS" >/dev/null
balance="$(cast balance "$DEPLOYER_ADDRESS" --ether --rpc-url "$DEPLOY_RPC_URL")"
block_number="$(cast block-number --rpc-url "$DEPLOY_RPC_URL")"

echo "deployment preflight passed"
echo "chain id: $actual_chain_id"
echo "latest block: $block_number"
echo "deployer: $DEPLOYER_ADDRESS"
echo "deployer balance: $balance ETH"
echo "admin timelock: $ADMIN_TIMELOCK"
echo "emergency pauser Safe: $EMERGENCY_PAUSER_SAFE"
echo "genesis distribution Safe: $GENESIS_DISTRIBUTION_SAFE"
