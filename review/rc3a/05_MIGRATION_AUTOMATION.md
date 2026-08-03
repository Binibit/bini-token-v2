# Migration Automation

The explicit BINI V1 fixture has 12 decimals, a test-only name/symbol, a
fixture-admin mint function and a constructor-level Mainnet refusal. It has no
relationship to the production V1 address.

Migration Vault deployment records V1, V2, Timelock, code hash, deployment
transaction and fixture status. Funding plans group exact liabilities by both
`sourceAllocationId` and `sourceTopLevelSafe`; each package originates from its
economic source Safe, so migration is not a tenth pool.

The canonical rehearsal funds five source-attributed liabilities through five
real Safe executions, configures and seals five entitlements through a delayed
Governance Safe/Timelock batch, then executes five holder approvals and
migrations. It verifies exact 12-to-18 conversion, locked/released totals and
zero remaining liability. Negative tests cover insufficient reserve/allowance,
duplicate holder/action/migration and unauthorized replacement recipients.
