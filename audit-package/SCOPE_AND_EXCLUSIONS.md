# Scope and Exclusions

Primary scope is `src/BiniTokenV2.sol`, Phase 1 deployment/distribution scripts,
governance tests, CLI safety, storage and upgrade controls. The detailed scope is
`BINI_V2_PHASE1_AUDIT_SCOPE.md`.

Phase 2 execution, Phase 3 registration/opening, unknown AMMs, Safe internals and
Mainnet operations are excluded. Slither excludes dependencies and paths
`lib|test|script`, plus detectors `assembly`, `low-level-calls` and
`unindexed-event-address`; reviewers must inspect the intentional low-level
bounded probes manually.
