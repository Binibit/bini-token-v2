# V1 to V2 Migration Runbook

## Model

Migration is not a snapshot airdrop. The holder grants the vault a finite V1
allowance; the vault locks the exact V1 amount and atomically releases
`v1Raw * 1,000,000` V2. Locked V1 has no rescue path. Entitlements are loaded by
Timelock and irreversibly sealed only after the vault holds the full V2 reserve.

The same address is the default recipient. A replacement recipient requires an
EIP-712 signature from the V1 EOA or EIP-1271 validation by the V1 contract
wallet. Telegram, email and spreadsheet edits are not authorization.

## Prepare

```sh
./bin/bini-v2 migration-plan --network sepolia \
  --migration-config config/sepolia.migration.json \
  --holders data/v1-v2-known-holders.csv
```

Review duplicate checks, ownership evidence, exact 12-to-18 conversion, input
hash, source allocation, source top-level Safe and batches of at most 20
holders. `fundingSources` must exactly match holder liabilities for every source
allocation. Timelock must execute
`setEntitlements(...)` for the reviewed action IDs and then
`sealEntitlements()` after exact reserve funding.

When a deployment manifest exists, `migration-plan` wraps these calls in
deterministic Timelock `scheduleBatch` and `executeBatch` Safe packages. Fund
the reserve before executing that batch; sealing an empty entitlement set is
rejected on-chain.

Migration is never a tenth economic pool. For every Phase 1 allocation, preserve
the identity `migrated V2 + remaining reserve + later distributions = original
Phase 1 allocation`. A shared vault is operationally acceptable only when each
funding transfer and receipt preserves that source attribution.

## Per-batch packages

```sh
EXECUTION_MODE=SAFE_PROPOSAL ./bin/bini-v2 migrate --network sepolia \
  --migration-config config/sepolia.migration.json \
  --holders data/v1-v2-known-holders.csv --batch batch-01
```

- `SELF_SERVICE`: holder approves V1 and submits the vault call.
- `OPERATOR_ASSISTED`: operator prepares calldata; holder still authorizes V1.
- `PROJECT_CONTROLLED_WALLET`: approval/migration is executed through the
  owning Safe or approved project signer.

The CLI never imports external holder keys and rejects direct batch broadcast.
Each holder is a separate migration call, so one failure cannot corrupt another
holder's accounting.

## Reconcile

For each confirmed receipt verify the vault `Migrated` event and action ID. The
aggregate invariants are `totalReleasedV2 == totalLockedV1 * 1,000,000`, vault
V2 balance covers remaining liability, no holder migrated twice and
`marketOpen() == false`. Preserve failed receipts; never mark a reverted call as
successful or retry it under a changed row/hash.

Generate the machine-readable reconciliation receipt with:

```sh
EXECUTION_MODE=SIMULATE ./bin/bini-v2 verify-migration --network sepolia \
  --migration-config config/sepolia.migration.json
```
