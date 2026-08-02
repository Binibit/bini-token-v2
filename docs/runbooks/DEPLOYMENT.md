# BINI V2 Deployment Runbook

## Security boundary

Phase 1 deployment creates a new `TimelockController`, frozen `BiniTokenV2`
implementation and atomically initialized ERC-1967 proxy. It does not deploy a
Migration Vault or vesting implementation, distribute supply, configure DEX
infrastructure or call `openMarket()`.

The complete fixed supply is minted once to the Genesis Distribution Safe. The
deployer receives no token role. Mainnet requires a separate written
authorization after a successful Sepolia rehearsal.

## Configure

1. Replace every illustrative address in `config/sepolia.phase1.json` with the
   ratified governance, Genesis and nine destination Safe addresses and exact
   thresholds. V1 and DEX addresses are not Phase 1 inputs.
2. Export the reviewed commit independently:

   ```sh
   export EXPECTED_GIT_COMMIT="$(git rev-parse HEAD)"
   export SEPOLIA_RPC_URL="https://..."
   ```

3. Import a dedicated deployer private key through Foundry's hidden prompt:

   ```sh
   cast wallet import bini-deployer --interactive
   export DEPLOYER_ACCOUNT=bini-deployer
   export DEPLOYER_ADDRESS="$(cast wallet address --account bini-deployer)"
   ```

Never put a raw key, mnemonic, keystore password or Safe signer key in `.env`, a
command argument, source control, CI, chat or a deployment manifest. Prefer a
hardware wallet for mainnet.

## Gates and simulation

```sh
make release-check
./bin/bini-v2 preflight --network sepolia
EXECUTION_MODE=SIMULATE ./bin/bini-v2 deploy \
  --network sepolia --config config/sepolia.phase1.json
```

Preflight is fatal on a dirty tree, commit/chain mismatch, missing contract
code, incorrect Safe threshold, invalid ledger, duplicate migration holder or
inexact decimal conversion.

## Authorized Sepolia broadcast

```sh
EXECUTION_MODE=BROADCAST ./bin/bini-v2 deploy \
  --network sepolia --config config/sepolia.phase1.json
```

The CLI uses the encrypted keystore, reads confirmed Foundry receipts, refuses
to overwrite an existing manifest, verifies code and `PRE_MARKET`, then writes
`artifacts/deployments/sepolia/deployment.json`. Re-running checks the recorded
contracts on-chain and reports `ALREADY_RECORDED`.

## Immediate verification

```sh
./bin/bini-v2 verify --network sepolia
./bin/bini-v2 status --network sepolia
```

Archive the manifest, broadcast receipts, verification artifact, explorer
links, Safe owner confirmations and release commit. Stop if any address, hash,
role, supply or market state differs.

Verification includes the ERC-1967 implementation slot, implementation runtime
hash, Timelock/Pauser roles, initializer replay rejection and the Phase 1
distribution state. DEX policy and migration have separate Phase 3 and Phase 2
commands.
