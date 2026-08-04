# BINI V2 production audit scope

Included in the Mainnet launch audit package:

- BINI V2 token core and fixed-supply accounting;
- UUPS upgrade authorization and Timelock/Safe governance;
- pause and delayed unpause;
- one-way PRE_MARKET to OPEN_MARKET lifecycle;
- DEX policy and known infrastructure limits;
- 12-Safe topology and Safe transaction automation;
- exact nine-Safe Phase 1 distribution;
- immutable direct-holder manifest, 20-recipient batching, MultiSend restrictions, receipts, and reconciliation.

Excluded from Mainnet launch scope and retained only in a research/testnet appendix:

- `BiniMigrationVault`;
- the BINI V1 fixture;
- entitlement creation/sealing;
- holder approvals, claims, migrations, alternate-recipient migration signatures;
- Vault funding, liability custody, and recovery design.

Migration Vault removal is a release-process and audit-scope decision. No BINI V2 Solidity source or implementation bytecode change is required or authorized by RC3D. Build/deployed bytecode hashes must be compared in the final evidence seal.
