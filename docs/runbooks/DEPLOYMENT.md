# BINI V2 Deployment Runbook

## Security boundary

Deployment creates a new `TimelockController`, frozen `BiniTokenV2`
implementation, atomically initialized ERC-1967 proxy and immutable
`BiniMigrationVault`. It does not deploy an unaudited vesting implementation,
distribute supply, configure DEX infrastructure or call `openMarket()`.

The complete fixed supply is minted once to the Genesis Distribution Safe. The
deployer receives no token or vault role. Mainnet requires a separate written
authorization after a successful Sepolia rehearsal.

## Configure

1. Replace every illustrative address in `config/sepolia.json` with ratified
   deployed Safe/V1 addresses and exact thresholds.
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
  --network sepolia --config config/sepolia.json
```

Preflight is fatal on a dirty tree, commit/chain mismatch, missing contract
code, incorrect Safe threshold, invalid ledger, duplicate migration holder or
inexact decimal conversion.

## Authorized Sepolia broadcast

```sh
EXECUTION_MODE=BROADCAST ./bin/bini-v2 deploy \
  --network sepolia --config config/sepolia.json
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
role, supply, vault link or market state differs.
