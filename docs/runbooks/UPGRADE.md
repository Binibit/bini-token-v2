# Upgrade Runbook

## Required Evidence

- change specification and security impact;
- storage schema diff;
- generated ABI/selectors/build artifact diff;
- OpenZeppelin validation output;
- state-preservation, authorization and rollback analysis;
- independent review and external audit proportional to impact;
- Timelock operation id, predecessor, salt and ETA.

## Procedure

1. Append new fields only within the ERC-7201 namespace or introduce a new
   namespace with an explicit migration design.
2. Never alter the meaning or order of existing namespaced fields.
3. Run `make artifacts`, review policy changes, then run `make release-check`.
4. Deploy the implementation without calling its initializer directly.
5. Confirm `proxiableUUID()` equals the ERC-1967 implementation slot.
6. Simulate `upgradeToAndCall` through the proxy using the Timelock.
7. Schedule, publish and independently verify the operation.
8. Execute only after the delay, then verify implementation slot, balances,
   allowances, permit nonces, market state, pause state and roles.

## Lifecycle Warning

The launch implementation cannot return from OPEN_MARKET to PRE_MARKET. UUPS
governance can technically replace that logic. Governance policy must treat any
upgrade that restores market restrictions, minting, seizure, tax or participant
controls as a new token security model requiring explicit public approval.
