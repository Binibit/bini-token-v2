# Deployment Runbook

## Inputs

The deployment script requires:

- `EXPECTED_CHAIN_ID`
- `ADMIN_TIMELOCK`
- `EMERGENCY_PAUSER_SAFE`
- `GENESIS_DISTRIBUTION_SAFE`
- `ADMIN_TRANSFER_DELAY`
- an RPC URL and broadcaster key supplied through the normal Foundry flow

All three addresses must contain deployed code before execution.

## Preflight

1. Check out the reviewed release commit and initialize submodules.
2. Run `npm ci --ignore-scripts` and `make release-check`.
3. Match every address and delay to the ratified governance manifest.
4. Confirm chain id, deployer balance, nonce and expected proxy address.
5. Simulate the exact command without broadcast and archive the trace.

## Deploy

Example for a simulation:

```sh
EXPECTED_CHAIN_ID=1 \
ADMIN_TIMELOCK=0x... \
EMERGENCY_PAUSER_SAFE=0x... \
GENESIS_DISTRIBUTION_SAFE=0x... \
ADMIN_TRANSFER_DELAY=172800 \
forge script script/DeployBiniTokenV2.s.sol:DeployBiniTokenV2 \
  --rpc-url "$MAINNET_RPC_URL"
```

Add the explicitly approved broadcast and verification flags only after the
simulation has been reviewed.

## Immediate Verification

- proxy implementation slot equals the deployed implementation;
- implementation initializers are disabled;
- `name`, `symbol`, `decimals`, cap and total supply match the fixed properties;
- the genesis Safe owns the entire initial supply;
- Timelock and pauser roles match the manifest;
- `marketState() == PRE_MARKET`;
- token is not paused;
- implementation and proxy source are explorer-verified;
- bytecode hashes match `artifacts/release/BINI_V2_BUILD.json`.

No DEX configuration or distribution should begin until this verification is
signed off.
