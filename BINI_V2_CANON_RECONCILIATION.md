# BINI V2 Canon Reconciliation

## Resolved conflicts

| Previous behavior | RC1 canon |
| --- | --- |
| Phase 1 deploy required V1 and deployed Migration Vault | Phase 1 deploys only Timelock, implementation, and proxy |
| One `config/sepolia.json` mixed all phases | Separate Phase 1, migration, and DEX-policy configs |
| Generic/mixed allocation ledger | Exactly nine hard-bound top-level Safe allocations |
| Migration/vesting recipients in initial distribution | No migration, vesting, or individual recipients in Phase 1 |
| Distribution required DEX policy first | Phase 1 has no DEX-address prerequisite |
| Verification mixed token, migration, and DEX | Separate `verify` and `verify-migration`; DEX verified by Phase 3 commands |
| Liquidity could be treated as immediate pool funding | 50M goes only to Liquidity Reserve Safe; zero to AMMs in Phase 1 |

## Canonical supply

Rewards total 600M across four custody Safes (210M, 180M, 120M, 90M); Team &
Founders 150M; Marketing 100M split 5M operations and 95M milestones; Ecosystem
100M; DEX Liquidity Reserve 50M. Total is exactly 1B BINI.

The four Rewards balances are organizational custody separation, not on-chain
vesting. Detailed grants, vesting, migration, liquidity, bridge, and staking are
later phases.

## Requirement result

Token core, PRE_MARKET user transfers, supported DEX blocking, and Phase 1
mechanics conform. Universal AMM blocking remains impossible and explicitly
blocked as a claim. Sepolia inputs, rehearsal, external audit, branch protection,
retained CI artifacts, and owner authorization remain outstanding.
