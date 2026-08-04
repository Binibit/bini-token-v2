# BINI V2 migration decision record

Decision status: binding production canon.

The BiniMigrationVault alternative was deployed and tested on Ethereum Sepolia with five disposable representative holders. That evidence is retained as `MIGRATION_VAULT_REHEARSAL_COMPLETED`, but the component is now `TESTNET_PROTOTYPE_ONLY`, `NOT_IN_MAINNET_LAUNCH_SCOPE`, and `NOT_REQUIRED_FOR_PRODUCTION_AUDIT_SCOPE`.

Production will use direct ERC-20 transfers from one owner-approved existing top-level allocation Safe to approximately 50 known final holder addresses. It creates no tenth pool. No entitlement, approval, claim, holder migration transaction, replacement-recipient authorization, V1 locking, Vault funding, or unclaimed-liability custody is part of production.

This change removes the entitlement batching burden (about 20+20+10 governance records), immutable-entitlement correction risk, unclaimed-V2 recovery design, and default-recipient mempool griefing from the launch path. It is a custodial snapshot distribution, not a trustless migration.

V1 is not burned or locked. Explicit owner-approved V1 deprecation and a frozen eligibility snapshot are mandatory prerequisites. One approved `SOURCE_ALLOCATION_ID` and its matching `SOURCE_SAFE` are also mandatory. Mixed historical origins funded from one allocation are an explicit tokenomics reclassification requiring owner approval.

Current labels:

- `MIGRATION_VAULT_REHEARSAL_COMPLETED`
- `PRODUCTION_MIGRATION_VAULT_DEFERRED/REMOVED`
- `PRODUCTION_MODEL_DIRECT_SAFE_DISTRIBUTION`
