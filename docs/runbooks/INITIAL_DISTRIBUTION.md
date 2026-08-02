# Initial Distribution Runbook

## Inputs

`data/bini-v2-supply-ledger.json` is the sole executable amount ledger and must
sum to exactly `1,000,000,000 * 10^18`. `data/vesting-grants.json` binds every
non-liquid team/partner allocation to an approved, predeployed vesting contract
and exact schedule. Replace all illustrative records before rehearsal.

The migration destination must be the deployed `BiniMigrationVault`; Treasury,
Liquidity, Rewards and Strategic reserves must use their dedicated Safes or
approved contracts. Do not combine these custody boundaries.

## Plan and Safe package

```sh
./bin/bini-v2 distribute --network sepolia \
  --ledger data/bini-v2-supply-ledger.json

EXECUTION_MODE=SAFE_PROPOSAL ./bin/bini-v2 distribute --network sepolia \
  --ledger data/bini-v2-supply-ledger.json \
  --vesting data/vesting-grants.json
```

The package contains the network, chain ID, source Safe, ledger hash, totals,
deterministic action IDs and exact ERC-20 transfer calldata in Safe Transaction
Builder format. Direct `BROADCAST` is rejected because the supply belongs to the
Genesis Safe.

## Review and execute

1. Compare package hash and human-readable allocations with signed approvals.
2. Simulate the whole Safe batch against the target chain/fork.
3. Submit through the official Safe interface or transaction service.
4. Collect the configured threshold; never automate signer keys.
5. Execute once, archive Safe proposal ID, nonce and confirmed transaction.
6. Reconcile every recipient balance/vesting funding and Genesis balance.

Required invariant: distributed supply plus remaining Genesis balance equals
exactly one billion BINI. `marketOpen()` must remain false. A failed or partial
Safe execution is handled as an incident; do not rebuild inputs under the same
ledger version.
