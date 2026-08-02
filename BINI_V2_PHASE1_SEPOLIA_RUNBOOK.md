# BINI V2 Phase 1 Sepolia Runbook

No command below authorizes deployment. Owner approval is required before the
first broadcast.

## 1. Ratify inputs

Replace placeholders in `config/sepolia.phase1.json` and
`data/bini-v2-supply-ledger.json`, confirm all 13 configured governance/custody
addresses are Safe contracts with approved thresholds, set
`illustrativeInputs: false`, and pin the exact release commit and bytecode hash.

## 2. Import deployer securely

```sh
cast wallet import bini-deployer --interactive
export DEPLOYER_ACCOUNT=bini-deployer
export DEPLOYER_ADDRESS="$(cast wallet address --account bini-deployer)"
export SEPOLIA_RPC_URL="https://approved-sepolia-rpc"
export EXPECTED_GIT_COMMIT="$(git rev-parse HEAD)"
```

The interactive command uses a hidden private-key prompt and encrypted Foundry
keystore. Never put the raw key or password in `.env` or shell arguments.

## 3. Gate and simulate

```sh
git status --short
make release-check
./bin/bini-v2 preflight --network sepolia --config config/sepolia.phase1.json
EXECUTION_MODE=SIMULATE ./bin/bini-v2 deploy \
  --network sepolia --config config/sepolia.phase1.json
```

Stop unless the tree is clean, origin and reviewed commit match, CI is green,
the external-audit status is recorded, and owner authorization is signed.

## 4. Authorized deployment

```sh
EXECUTION_MODE=BROADCAST ./bin/bini-v2 deploy \
  --network sepolia --config config/sepolia.phase1.json

EXECUTION_MODE=SIMULATE ./bin/bini-v2 verify \
  --network sepolia --config config/sepolia.phase1.json
```

Archive receipts and verify source/code, proxy implementation slot, roles,
supply, PRE_MARKET, and full Genesis balance.

## 5. Nine-Safe distribution

```sh
EXECUTION_MODE=SAFE_PROPOSAL ./bin/bini-v2 distribute \
  --network sepolia --config config/sepolia.phase1.json \
  --ledger data/bini-v2-supply-ledger.json
```

Review and simulate the complete nine-transfer Safe batch, collect the approved
threshold, execute once, then run:

```sh
EXECUTION_MODE=SIMULATE ./bin/bini-v2 verify \
  --network sepolia --config config/sepolia.phase1.json \
  --ledger data/bini-v2-supply-ledger.json
```

Required result: Genesis zero, nine exact balances, total supply 1B, PRE_MARKET.
Archive deployment, Safe transaction, blocks, logs, hashes, and verification.
