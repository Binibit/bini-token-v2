# BINI V2 Ethereum Sepolia full-cycle report

Status: **SEPOLIA FULL TOKEN LIFECYCLE GREEN** (no Mainnet deployment).

## Canonical contracts and control plane

- BINI V2 proxy: `0xde486a7480fe33dbc3fdfb66ac98f371b5d4393a`
- implementation: `0x6c07b57807e5c7a5941b981ee7fa11aa1d4f9d0b`
- Timelock: `0xfcb25e92d5d4e70b28adea5af2311d0efd9c652d`
- Governance Safe: `0xcfaafb61d53524e91a26702f2895a43af567163e`
- Security Safe: `0xb7c3bb02512a8ba610cb627b30a16eb65554107d`
- topology: 12 distinct 2-of-3 Safe proxies

## OPEN_MARKET recovery and execution

The ambiguous schedule was recovered; it was not resent. Schedule transaction `0xca086a0c20c8f182c501b23e7dc570cbacbcce4bb1773435743303eaec9cce3a` succeeded in block 11,413,193 and created operation `0xc624cae477d10290ffcb0e5689e627ca6947e55c7995d1d83d9b1ad433ba4969`.

Governance Safe executed the ready operation in transaction `0xa7b911a5bd950fb1bd15047bf3c8795b264ff072e9092c5446435eb61d5fd531` (block 11,416,391). Verification proves `marketOpen=true`, market state `OPEN_MARKET`, and operation `DONE`. The transition is one-way; no close-market path exists.

Post-open transfers into all previously protected supported fixtures succeeded and their policy getters returned unblocked:

- V2 pool: `0x64054f695ff4eb4050b48e5064344e87eea2948afda735c72cc4cca880a0366c`
- V3 pool: `0xe12f772e719b7e6695bd812f0721d7c9fb744fe098f1439a87a99c4f9da4f90a`
- router: `0xa50453e0f1fc4e7b14a617a48b47436b2773472a9eb85dcc95ee440bace8a980`
- pool manager: `0x0065a7275fb1b6887810d3b593703a3fc52aba933fff469041ca64c59d6e8ca7`

## Post-open pause and delayed unpause

Security Safe paused the token in `0x2f56345ece7068024b8b3a039f61bb9ab3a6f2f16694aa10685d2da7c2ad4156`; verification proved `paused=true` and a transfer reverted.

A fresh, nonce-bound Timelock operation was used to avoid reusing the earlier completed deterministic unpause salt:

- operation: `0x455257e5f9939caaf0a7013b05a1e264b55ff3b27bc643945a5de3c857606f83`
- schedule: `0xeb2984056a997e205735adec5170bcffe0b2b7850b51e5a34534f553b9c19486`
- early execution: rejected
- Governance Safe execution: `0xa5edeb6cd3ff1c2f9ed0159e87d7c071f3b6bebd7f609115c6a36c33e1561608`, block 11,416,464, Safe nonce 13
- SafeTxHash: `0x0a0feab55d82bec2ca2670664bc9bdc0176e72db1427a36d59531d195823b568`
- signers: `0x2eEcCC48Cc7b08484b07EbD09E6828054A7A790D`, `0x407549b41a4Ae3d9aDb816e7153940c62c5D919D`

Final checks prove operation `DONE`, `marketOpen=true`, and `paused=false`. A one-raw-unit actor-to-actor transfer then succeeded in `0xef652d5be80f427c01752ed71d4eca5a713e5428c76e756e30147018074b4747`.

## Accounting seal

Final total supply remains exactly `1,000,000,000e18` raw (`1000000000000000000000000000`). The ERC-1967 implementation slot remains `0x6c07b57807e5c7a5941b981ee7fa11aa1d4f9d0b`.

All nine allocation Safe balances match the before-open baseline exactly:

| Allocation | Final raw balance |
|---|---:|
| Rewards Y1 | 210000000000000000000000000 |
| Rewards Y2 reserve | 180000000000000000000000000 |
| Rewards Y3 reserve | 120000000000000000000000000 |
| Rewards Y4 reserve | 90000000000000000000000000 |
| Team/founders reserve | 150000000000000000000000000 |
| Marketing operations | 4999890000000000000000000 |
| Marketing milestone reserve | 95000000000000000000000000 |
| Ecosystem reserve | 100000000000000000000000000 |
| DEX liquidity reserve | 50000000000000000000000000 |

The 110 BINI marketing-operations delta predates OPEN_MARKET and is already represented in the before-open baseline. Post-open policy probes used actor fixture funds and did not debit an allocation Safe.

## Migration alternative and production model

The five-holder Migration Vault rehearsal remains valid Sepolia research evidence: V1 locked `15,000,000,000,000`, V2 released `15,000,000,000,000,000,000`, remaining liability zero. It is labeled:

- `MIGRATION_VAULT_REHEARSAL_COMPLETED`
- `PRODUCTION_MIGRATION_VAULT_DEFERRED/REMOVED`
- `PRODUCTION_MODEL_DIRECT_SAFE_DISTRIBUTION`

No production holder distribution was executed because the owner-approved source allocation, V1 freeze/deprecation evidence, and final holder manifest are not yet supplied.

## Bytecode and evidence

RC3D changed Python automation, schemas, tests, and documentation only. Solidity paths have no diff. `forge inspect BiniTokenV2 bytecode | cast keccak` remains `0x6f048525545cc80f49c8c203f65d605beae18a4b0cc2d24bafaa9a57efebe872`; build deployed-bytecode hash remains `0xf13d1d3cbd25af356a9d23a55e5be1e053fc84f9fd478a78d9761b3e8f81f5c2`. The implementation address and proxy implementation slot are unchanged.

Canonical Safe receipts and verification artifacts are retained under `artifacts/sepolia/` and are locally evidence-sealed without secrets.
