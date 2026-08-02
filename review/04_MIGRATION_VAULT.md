# Migration Vault

Migration is implemented but belongs exclusively to Phase 2.

## Verified properties

- Constructor requires deployed immutable V1, V2, and Timelock contracts.
- V1 decimals must be 12 and V2 decimals 18.
- Raw conversion is exactly `v1Raw * 1_000_000`, preserving 1 V1 BINI to 1 V2
  BINI economically; Solidity 0.8 checked arithmetic rejects overflow.
- Timelock configures bounded entitlement batches with unique holder/action IDs,
  then seals once only after exact reserve sufficiency is available.
- Migration records completion before external token operations, uses
  `nonReentrant` and `SafeERC20`, locks V1 with `transferFrom`, verifies the exact
  balance delta, then releases the exact V2 delta atomically.
- Failed allowance/transfer or fee-on-transfer behavior reverts the entire
  operation and releases no V2. Rebasing and fee-on-transfer assets are outside
  the accepted token assumptions.
- A holder cannot migrate twice. A changed recipient requires EIP-712
  EOA/EIP-1271 authorization from the holder.
- `totalLockedV1`, `totalReleasedV2`, completed actions, and liability support
  reconciliation. The vault never mints BINI V2.

The token has global emergency pause, so V2 release pauses atomically; the vault
does not have a separate pause. This is acceptable only if Phase 2 owner review
ratifies that incident model.

## Phase status

Contract mechanics and local tests are green. Phase 2 is not release-ready:
ratified V1/V2/vault addresses, holder manifest, funding amount, migration time,
custody source, external audit, and a Sepolia rehearsal are still required.

Phase 2 incompleteness does not block Phase 1.
