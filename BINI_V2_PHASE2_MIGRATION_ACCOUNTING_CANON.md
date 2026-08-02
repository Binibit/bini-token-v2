# BINI V2 Phase 2 Migration Accounting Canon

Phase 2 is excluded from RC2 execution. Migration is an attribution-preserving
distribution from the nine Phase 1 allocations, never a tenth economic pool.

Every holder record contains `holderId`, `v1Address`, `v2Recipient`,
`v1RawAmount`, `v2RawAmount`, `sourceAllocationId`, `sourceTopLevelSafe`,
`beneficiaryType`, `ownershipProof`, `migrationMethod`, `vestingTreatment`,
`batch`, and `status`.

`sourceAllocationId` must identify one canonical Phase 1 allocation and
`sourceTopLevelSafe` must equal that allocation's ratified Safe. The CLI rejects
duplicate holders, inexact 12-to-18 decimal conversions, mismatched source
Safes, source liabilities above the original allocation, and funding manifests
that do not exactly match holder liabilities per source.

For each allocation `A`:

```text
migratedV2[A] + remainingReserve[A] + laterDistributions[A]
= originalPhase1Allocation[A]
```

A generic Migration Vault may receive funds from several top-level Safes only
when each funding transfer and receipt records its source allocation. The
aggregate vault balance is not sufficient accounting evidence.

Canonical machine controls are implemented in
`data/v1-v2-known-holders.schema.json`, `config/migration.schema.json`, and
`tools/bini_v2_cli.py`.
