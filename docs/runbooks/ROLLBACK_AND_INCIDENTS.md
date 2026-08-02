# Rollback and Incident Runbook

On-chain deployment, distribution and completed migrations are irreversible.
"Rollback" means stop, preserve evidence, contain further actions and prepare a
new governance-approved remediation. Never delete receipts or rewrite a used
ledger version.

## Immediate response

1. Stop CLI/Safe execution and do not retry a reverted transaction blindly.
2. Record UTC time, chain, block, Safe nonce, transaction/proposal hashes,
   release commit, input hashes and operator.
3. Compare on-chain state with the last confirmed receipt.
4. If token integrity is at risk, the Emergency Pauser Safe may call `pause()`.
   Pause is global and independent of `PRE_MARKET`; only Timelock can unpause.
5. Notify Safe owners, Timelock governance, release lead and security contacts.

## Cases

- Deployment mismatch: do not distribute. Quarantine the addresses and produce
  a root-cause report.
- Partial Safe distribution: preserve the executed Safe nonce, reconcile each
  transfer/event and create a new proposal only for proven missing actions.
- Migration failure: successful holder calls remain final; diagnose the failed
  holder's allowance/signature/token behavior and issue a new reviewed package.
- Wrong recipient request: do not act without valid EIP-712/EIP-1271 evidence.
- Suspected key compromise: remove/rotate the affected Safe owner using Safe
  governance; the deployer has no permanent production role.

`openMarket()` is never an incident response and is outside this workflow. Do
not schedule or execute it while resolving a deployment/distribution/migration
incident.
