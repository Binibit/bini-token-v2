# Initial Distribution Runbook

## Inputs

`data/bini-v2-supply-ledger.json` is the sole Phase 1 amount ledger. It binds the
exact order, IDs, config keys and raw amounts for nine top-level Safes and sums
to exactly `1,000,000,000 * 10^18`. Replace all illustrative Safe addresses
before rehearsal.

Phase 1 contains no V1 migration, beneficiary vesting, pool transfer, DEX
configuration or market opening. The 50M liquidity allocation goes only to the
Liquidity Reserve Safe.

## Plan and Safe package

```sh
./bin/bini-v2 distribute --network sepolia \
  --ledger data/bini-v2-supply-ledger.json

EXECUTION_MODE=SAFE_PROPOSAL ./bin/bini-v2 distribute --network sepolia \
  --ledger data/bini-v2-supply-ledger.json
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
6. Run `./bin/bini-v2 verify --network sepolia` and archive its receipt.

Required post-state: every recipient equals its canonical amount, Genesis is
zero, total supply remains one billion BINI, and `marketOpen()` remains false.
Any partial state is rejected and handled as an incident; do not rebuild inputs
under the same ledger version.
