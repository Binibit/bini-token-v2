# Class-Specific Freeze And Recovery

## Purpose

`emergencyRevoke(address[])` is the immediate Security action for isolating an
address. It sets the account class to `NONE`, clears an operator flag when present,
and leaves balances and allowances unchanged.

Freezing is not confiscation. It blocks transfers involving the frozen address
until the correct normal manager restores its original class.

## Required Incident Record

Before execution, record:

- incident ID and affected address;
- current account class and operator status;
- reason and supporting evidence;
- expected affected and unaffected flows;
- Security Safe proposal and signer approvals;
- original class manager responsible for recovery.

For an active exploit, Security may freeze first and complete the incident record
immediately afterward.

## Class Matrix

| Target | Freeze effect | Recovery authority | Required recovery action |
|---|---|---|---|
| `PARTICIPANT` | Address cannot send or receive | Operations Safe | `setParticipants(addresses, true)` |
| `SYSTEM` | Only flows involving that system stop | Timelock | `setSystemAccounts(addresses, true)` |
| `CUSTODY` | Deposits and withdrawals involving that address stop | Timelock | `setCustodyAccounts(addresses, true)` |
| `MARKET_ENDPOINT` | Pool feeding and transfers involving the endpoint stop | Timelock | `setMarketEndpoints(addresses, true)` |
| Approved operator | Operator flag is cleared; its account class is also cleared | Timelock for operator flag; original class manager for account class | `setOperators(addresses, true)`, then restore the original class if required |

Security has revoke-only authority and must never perform restoration.

## Misclassification Hazard

After a freeze, every target has class `NONE`. Operations can technically call
`setParticipants` on a formerly `SYSTEM`, `CUSTODY`, or `MARKET_ENDPOINT` address
and incorrectly restore it as `PARTICIPANT`.

Recovery must therefore use the incident record and the original class manager.
Do not use `setParticipants` as a generic unfreeze function.

## Recovery Order

1. Confirm the incident is contained and the address is safe to restore.
2. Confirm the expected original class and operator status from on-chain history.
3. Schedule the class restoration through the responsible manager.
4. For an operator, restore the operator flag separately through the Timelock.
5. Verify class, operator status, balance, allowance, and pause state on-chain.
6. Execute a minimal post-recovery transfer or integration smoke test.
7. Close the incident with transaction hashes and reviewer approval.

## Global Pause

A global pause overrides all class-specific recovery. If the token is paused,
complete class restoration first, then use the delayed and cancellable Timelock
unpause flow. Neither Governance nor Security may bypass the Timelock by calling
`unpause()` directly.

## Executable Evidence

The behavior above is covered by:

- `test/governance/FreezeRecovery.t.sol`;
- `test/governance/TimelockGovernance.t.sol`;
- `test/invariant/GlobalOperatorInvariant.t.sol`.
