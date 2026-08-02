# BINI V2 Script Acceptance Report

## Implemented

- Stable `./bin/bini-v2` commands and PLAN/SIMULATE/SAFE_PROPOSAL/BROADCAST modes.
- Timelock schedule/execute Safe packages and a mandatory DEX-policy gate before distribution.
- Mainnet broadcast triple guard; encrypted keystore deployment; no holder/Safe keys.
- Atomic Timelock/proxy/vault deployment with fixed supply to Genesis Safe.
- Exact ledger and vesting validation plus Safe Transaction Builder output.
- Controlled V1 lock/V2 release vault with signed replacement recipients.
- Deterministic action IDs, immutable artifacts, receipt-derived deployment manifest.
- Unit, governance, upgrade, invariant, E2E, fork, static-analysis, CLI and
  receipt-backed local Anvil release gates.

## Current evidence

The complete local release gate is green: 69 local Solidity tests, 4 pinned
mainnet-fork tests, 15 CLI tests, UUPS validation, Slither with 0 findings and
enforced token/vault coverage thresholds. The local Anvil rehearsal executes
deployment receipts, manifest recovery, delayed PRE_MARKET policy, full supply
distribution, delayed migration entitlements, V1 lock/V2 release and delayed
`openMarket()`. The committed network, allocation, vesting and holder records
are explicitly illustrative because approved production addresses and holder
data were not supplied. No Sepolia deployment or production Safe receipt exists
in this commit.

## Required before mainnet package readiness

1. Ratify and insert real Safe/V1/vesting addresses and thresholds.
2. Replace example allocation and known-holder records; independently sign their hashes.
3. Run clean-commit preflight and full release gate.
4. Deploy and complete distribution/migration rehearsal on Sepolia.
5. Archive receipts, Safe proposal IDs, explorer verification and reconciliation.
6. Obtain independent external audit and explicit owner mainnet authorization.

Verdict: `SCRIPTS_GREEN_SEPOLIA_REQUIRED`.
