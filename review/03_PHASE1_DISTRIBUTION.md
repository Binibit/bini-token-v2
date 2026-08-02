# Phase 1 Distribution

## Canon binding

`data/bini-v2-supply-ledger.json` is the versioned source of truth. CLI validation
hard-binds all nine rows by order, allocation ID, economic pool, category,
recipient config key, and exact raw amount. Generic or reordered allocations,
duplicates, zero recipients, and later-phase fields are rejected.

| Order | Allocation | BINI | Raw amount |
| ---: | --- | ---: | ---: |
| 1 | Rewards Year 1 | 210,000,000 | 210000000000000000000000000 |
| 2 | Rewards Year 2 Reserve | 180,000,000 | 180000000000000000000000000 |
| 3 | Rewards Year 3 Reserve | 120,000,000 | 120000000000000000000000000 |
| 4 | Rewards Year 4 Reserve | 90,000,000 | 90000000000000000000000000 |
| 5 | Team & Founders Reserve | 150,000,000 | 150000000000000000000000000 |
| 6 | Marketing Operations | 5,000,000 | 5000000000000000000000000 |
| 7 | Marketing Milestone Reserve | 95,000,000 | 95000000000000000000000000 |
| 8 | Ecosystem Reserve | 100,000,000 | 100000000000000000000000000 |
| 9 | DEX Liquidity Reserve | 50,000,000 | 50000000000000000000000000 |

The Phase 1 config requires nine distinct destination contracts, excludes
Genesis from destinations, and requires a configured threshold for every Safe.
Runtime preflight verifies code and `getThreshold()`.

## Execution safety

- Default is `PLAN`; `BROADCAST` is rejected for Genesis-owned funds.
- `SAFE_PROPOSAL` emits one Safe Transaction Builder batch with nine exact
  ERC-20 transfers and deterministic action IDs.
- Executable inputs must have `illustrativeInputs: false`.
- Before proposal, balances must be exactly `DEPLOYED_UNDISTRIBUTED`.
- Re-run after complete execution returns `ALREADY_DISTRIBUTED`.
- Any partial/mixed state is rejected.
- `verify` accepts only the exact pre-distribution or exact post-distribution
  state; post-state requires Genesis zero and every Safe at its exact amount.
- Artifacts are create-only and cannot be silently overwritten.

No DEX registration, pool transfer, migration, vesting, or `openMarket()` action
is part of Phase 1.

## Verdict

`PHASE1_DISTRIBUTION_GREEN`

Mechanics are green; production/Sepolia addresses remain owner inputs.
