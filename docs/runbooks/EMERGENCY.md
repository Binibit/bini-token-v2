# Emergency Runbook

## Pause Criteria

The Emergency Pauser Safe may call `pause()` when an active incident threatens
balances, governance integrity, proxy safety or a critical integration.
Market-launch timing alone is not a reason to use the emergency pause.

## Response

1. Confirm the proxy address, chain id and incident severity.
2. Simulate `pause()` from the Pauser Safe.
3. Execute and verify the `Paused` event and `paused() == true`.
4. Publish the incident scope and note that approvals remain writable while
   transfers and `transferFrom` are stopped.
5. Preserve traces, logs, Safe transaction data and relevant block hashes.
6. Investigate whether an upgrade, role response or off-chain mitigation is
   required.

## Recovery

Only the Timelock holds `UNPAUSER_ROLE`. Recovery requires a scheduled
`unpause()` after the incident is understood, fixes are reviewed and the
Timelock delay expires. Verify the existing market state separately; pausing or
unpausing never reopens or recloses the market.

If governance keys or the proxy itself are suspected compromised, do not
unpause until independent incident responders validate the recovery plan.
