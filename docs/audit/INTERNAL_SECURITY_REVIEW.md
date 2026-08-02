# Internal Security Review

Review date: `2026-07-25`

Status: `INTERNAL_REVIEW_COMPLETE_EXTERNAL_AUDIT_REQUIRED`

## Scope

- `src/BiniTokenV2.sol`
- ERC-1967/UUPS deployment and upgrade path
- access control and emergency pause
- PRE_MARKET V2/V3/V4 destination policy
- ABI, storage and release tooling
- unit, E2E, invariant, governance, upgrade and mainnet-fork tests

This is an engineering security review, not an independent external audit.

## Resolved Findings

### ISR-01: Unbounded return-data copy from a configured factory

Severity: Medium. Status: Fixed.

The original low-level `staticcall` used Solidity dynamic return bytes. A
malicious or compromised registered factory could return excessive data and
consume caller gas during an ordinary transfer. The implementation now copies
exactly 32 bytes in assembly under a `30,000` gas stipend. Return-bomb,
short-return and reverting-target regression tests cover the behavior.

### ISR-02: Governance endpoints accepted EOAs at initialization

Severity: Medium. Status: Fixed.

An accidental EOA for Timelock, pauser or genesis custody would violate the
declared authority model. Initialization now requires deployed code for all
three roles and tests each rejection path.

### ISR-03: Fork evidence depended on mutable provider state

Severity: Medium. Status: Fixed for repository evidence.

The fork suite is pinned to block `25,603,294`. It asserts canonical runtime code
hashes for Uniswap V2 Factory, V3 Factory and V4 PoolManager, matching the
governance rehearsal manifest. A controlled archive RPC is still required for
deployment sign-off.

### ISR-04: Upgrade safety validation was not automated

Severity: Medium. Status: Fixed.

OpenZeppelin Upgrades Core `1.46.0` is lockfile-pinned and validates Foundry
build-info in CI. Tests reject non-UUPS implementations, wrong UUIDs, direct
implementation calls, zero implementations and unauthorized callers.

### ISR-05: Lifecycle was tested in isolated slices only

Severity: Low. Status: Fixed.

The E2E suite now covers deployment, Timelock configuration, distribution,
ordinary transfers, V2/V3/V4 blocking, delayed opening, post-open DEX transfer,
pause/unpause and post-open UUPS state preservation. Stateful invariants run
with `fail_on_revert = true`.

## Automated Results

- `69` local Solidity, `15` CLI and `4` pinned mainnet-fork tests pass;
- receipt-backed local Anvil release rehearsal: pass;
- token coverage: `100%` lines, branches and functions;
- migration-vault coverage: `97.65%` lines, `87.50%` branches and `90%` functions;
- Slither `0.11.4`: `0` findings after documented informational exclusions;
- OpenZeppelin upgrade validation: pass;
- release artifact, storage slot and selector policy consistency: pass;
- npm production runtime dependencies: none;
- npm audit: `5` low, `0` moderate/high/critical, all transitive development
  tooling under OpenZeppelin Upgrades Core.

Excluded Slither detectors are `assembly`, `low-level-calls` and
`unindexed-event-address`. The assembly and low-level calls implement the
bounded DEX probes reviewed in ISR-01; address fields are intentionally indexed
in BINI's own events.

## Residual Risks

- universal unknown/future AMM blocking is impossible under the free-transfer
  requirement;
- a V2 CREATE2 destination can be pre-funded before deployment;
- governance can omit or misclassify DEX infrastructure;
- UUPS governance can alter every token guarantee;
- global pause can temporarily stop all transfers;
- public RPC availability can fail independently of contract correctness.

## External Audit Brief

An external reviewer should prioritize bounded probe assembly, pool
authentication assumptions, UUPS/storage compatibility, role topology,
Timelock deployment configuration, CREATE2 pre-funding and the operational
completeness of the DEX manifest.
