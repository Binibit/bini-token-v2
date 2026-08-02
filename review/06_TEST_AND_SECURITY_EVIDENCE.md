# Test and Security Evidence

Evidence reproduced locally on 2026-08-02 with Foundry 1.5.1, Solidity 0.8.24,
OpenZeppelin Upgrades Core 1.46.0, and Slither 0.11.4.

## Tests

- `forge test --no-match-path 'test/fork/*' -vv`: 10 suites, 69 passed, 0
  failed, 0 skipped. The only exclusion is the separately run fork directory.
- `python3 -m unittest discover -s test_cli -p 'test_*.py' -v`: 16 passed.
- `tools/test-mainnet-fork.sh`: 4 passed, 0 failed, block `25,603,294`; V2/V3
  factory and V4 PoolManager runtime hashes are asserted. Local reproduction used
  a public archive fallback, so the run is engineering evidence, not controlled
  deployment evidence.
- `tools/test-release-anvil.sh`: clean-tree, receipt-backed three-phase lifecycle
  is enforced by CI. The reconciled version is rerun after commit because the
  script intentionally refuses a dirty worktree.
- Invariant configuration: 64 runs, depth 64, `fail_on_revert = true`; five
  invariants passed with 4,096 calls each.

No expected-failure masking or skipped tests were observed. Local tests exclude
fork tests explicitly; the fork command runs exactly that excluded path.

## Coverage

`tools/coverage-gate.sh` reported:

| Contract | Lines | Statements | Branches | Functions |
| --- | ---: | ---: | ---: | ---: |
| BiniTokenV2 | 100.00% (101/101) | 100.00% (123/123) | 100.00% (19/19) | 100.00% (22/22) |
| BiniMigrationVault | 97.65% (83/85) | 97.64% (124/127) | 87.50% (21/24) | 90.00% (9/10) |

## Slither

Command:

```sh
slither . --filter-paths 'lib|test|script' --exclude-dependencies \
  --exclude assembly,low-level-calls,unindexed-event-address
```

Result: 55 contracts, 97 detectors, 0 results. Production `src/` was not path-
excluded, but the three named detectors were suppressed. The low-level assembly
DEX probes therefore require manual review and are covered by return-bomb,
revert, short-return, ordinary-wallet, and factory-confirmation tests.

## UUPS

`tools/validate-upgrades.sh` validates the exact
`src/BiniTokenV2.sol:BiniTokenV2` build info and then requires OpenZeppelin CLI
to reject `StorageLayoutIncompatible` against `StorageLayoutBaseline`. Current
implementation passed; the negative fixture failed with `Bad upgrade from
uint256 to address`. Solidity tests also reject non-UUPS, wrong UUID, direct
implementation, zero-address, and unauthorized upgrades and prove state
preservation across a compatible upgrade.

## Residual evidence limits

No independent external audit exists. GitHub CI retains no uploaded evidence
artifact. The final successor commit must pass CI before this RC1 evidence is
considered complete.
