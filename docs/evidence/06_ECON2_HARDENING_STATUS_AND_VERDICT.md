# ECON-2 — Guarded Core Hardening: Status & Verdict

**Scope:** close the two P0 risk classes the ECON-2 audit raised against the ECON-1 `BiniTokenV2Guarded`
reference **before any further contract is built on top of it**:

1. **Privilege bypass** between `PARTICIPANT_MANAGER` and the sensitive class managers
   (`SYSTEM`/`CUSTODY`/`ENDPOINT`/`OPERATOR`).
2. **Trapped balances** at the `BOOTSTRAP → GUARDED` transition.

**Status:** PARTIAL. Two of the four P0 classes are code-closed with executable proof; one is now closed by
the ECON-2.1 genesis fix; **one architectural P0 remains OPEN** (participant misclassification — a trust
decision, not code-fixable here). Real Foundry build + 61 tests green. Slither: no High/Medium in the guarded
core. **Not audited, not deployed. No mainnet. Downstream production implementation is BLOCKED** until ECON-2.1
closes the remaining gates.

Provenance: forge repo `/tmp/binibit-p1`, commit `17904dc` (genesis fix; parents `27b1029` role/bootstrap
hardening, `e594127` V4 entry-control). **Not yet in the canonical production repository** — a provenance gap
that ECON-2.1 Wave 0 must close. Source + tests mirrored under `docs/bini-v2/econ1/src` and `.../test`.

### P0 status board (corrected — earlier "all P0 closed" was premature)

| P0 | Status | Basis |
|---|---|---|
| Role separation / cross-class manager writes | ✅ code-closed | boundary + role tests + invariants |
| Bootstrap recipient trap | ✅ code-closed | `BootstrapRecipientNotApproved` |
| Freeze mis-disclosed as "no blacklist" | ✅ disclosure-closed | header + doc 07 |
| Genesis activation self-trap | ✅ code-closed (ECON-2.1, `17904dc`) | `GenesisNotReady` gate + 3 tests |
| **Participant misclassification** | ⚠️ **ACCEPTED TRUST ASSUMPTION (pending sign-off)** | Ops can class ANY address `PARTICIPANT`; token cannot verify address nature. P1 (Ops Safe approval) is the **recommended** model — NOT eliminated, formally accepted + managed. Requires business ratification + ops controls + rehearsal (doc 08) |

---

## What the audit flagged and what changed

| # | Audit finding (ECON-1 reference) | Fix (ECON-2) | Proof |
|---|---|---|---|
| P0.1 | Account classes decorative — one manager could reclassify/revoke any address, so `PARTICIPANT_MANAGER` (Ops) could mark a rogue pool as `SYSTEM`/`CUSTODY`, or strip a `SYSTEM` address. | `_manageClass` boundary: a manager may only move an address between `NONE` and its **own** `managed` class. `cur != NONE && cur != managed → revert ClassBoundaryViolation`. | `test_Ops_CannotCrossClassBoundary`; invariant `SystemAddrClassPreserved` (runs 64 / calls 4096 / reverts 0) |
| P0.5/P0.6 | Roles didn't match governance; Operations Safe too broad. | Per-class managers split: `SYSTEM/CUSTODY/ENDPOINT/OPERATOR_MANAGER → Timelock`; `PARTICIPANT_MANAGER → Ops` only. New 6-arg `initialize`. | `test_Ops_HasOnlyParticipantManager`, `test_Ops_CannotSetSystem/Endpoint/Operator`; invariant `OpsNeverGainsSensitiveRoles` |
| P0.3 | Bootstrap could send to non-approved recipients → balances trapped once `GUARDED`. | BOOTSTRAP transfers must originate from `BOOTSTRAP_OPERATOR` **and** land on an already-approved recipient, else `BootstrapRecipientNotApproved`. Mint (`from==0`) exempt. | `test_Bootstrap_ToUnapproved_Reverts`, `test_Bootstrap_ToApproved_Ok` |
| P0.2 | "No blacklist" disclosure was misleading — `emergencyRevoke` is an effective freeze. | Header + disclosure doc state plainly: `emergencyRevoke` sets class `NONE`, **balance unchanged** — governed transfer freeze, not confiscation; restorable via the normal manager. | `test_EmergencyRevoke_FreezesButKeepsBalance` |

---

## The hardened policy (authoritative)

`_update` order **pause > guard > cap**. `from == address(0)` (mint) bypasses the guard.

- **BOOTSTRAP:** `from` MUST hold `BOOTSTRAP_OPERATOR_ROLE` AND `class[to] != NONE`. Onboarding precedes
  distribution; nothing can be sent to an address that would be stranded after activation.
- **GUARDED:** `class[from] != NONE && class[to] != NONE` (both inside the perimeter) AND sender check:
  - `to` is a `MARKET_ENDPOINT` → `msg.sender` MUST be an approved operator (the V4 lever: no direct
    user→PoolManager, closing the ERC-6909 claims entry).
  - otherwise → `msg.sender == from` OR an approved operator.
- **Mode is one-way:** `activateGuardedMode` is irreversible; there is no `OPEN`. (`AlreadyGuarded`.)

Roles → holders:

| Role | Holder | Power |
|---|---|---|
| `DEFAULT_ADMIN`, `UPGRADER`, `POLICY_MANAGER`, `SYSTEM/CUSTODY/ENDPOINT/OPERATOR_MANAGER` | **adminTimelock** | upgrade, activate guarded, manage sensitive classes + operators |
| `PARTICIPANT_MANAGER` | **operationsSafe** | onboard/off-board retail participants **only** |
| `PAUSER`, `EMERGENCY_REVOKER` | **securitySafe** | pause; emergency freeze (revoke-fast) |
| `UNPAUSER` | **governanceUnpauserSafe** | unpause — ⚠️ topology UNRESOLVED (U1 direct Governance Safe vs U2 UNPAUSER→Timelock); current wiring = U1, pending ratification |
| `BOOTSTRAP_OPERATOR` + 1B genesis supply | **genesisDistributionSafe** | seed approved recipients pre-launch; emptied + role revoked at go-live |

---

## Test evidence (58 green)

- **`GuardedUnit.t.sol` (14):** role separation, boundary, bootstrap-to-approved, guarded participant/unknown,
  emergency-freeze-keeps-balance-and-restorable, mode one-way, pause precedence, supply.
- **`invariant/GuardedPolicyInvariant.t.sol` (6, runs 64 / calls 4096 / reverts 0):**
  `OpsNeverGainsSensitiveRoles`, `SystemAddrClassPreserved` (across Ops-bypass attempts **and** UUPS upgrade),
  `SupplyConstant`, `BalanceConservation`, `CapNeverExceeded`, `GuardedMonotonic`.
- **`fork/GuardedV2Fork.t.sol` (2)** on real mainnet Uniswap V2 factory: official approved-endpoint pair
  seedable via operator; unknown pair permanently blocked.
- **`fork/V4GatewayFork.t.sol` (4)** on real mainnet V4 PoolManager `0x0000…8A90`: direct user→PoolManager
  blocked, via non-operator blocked, gateway(operator)→PoolManager allowed, PoolManager has code.
- Plus the retained minimal-reference `BiniTokenV2` suites (unaffected).

---

## Exact guarantee (corrected — the earlier "unknown pool cannot receive BINI forever" was too strong)

> An **unapproved** address cannot send or receive real BINI. An ordinary third-party pool stays blocked —
> **unless** a trusted manager approves or *misclassifies* its address (e.g. Ops classing it `PARTICIPANT`),
> or an already-approved address implements economically-equivalent market logic.

The protection therefore depends on: contract code **+** manager integrity **+** onboarding quality **+**
monitoring **+** incident response. It is a **governed perimeter, not a trustless market firewall.** No design
here stops fake/look-alike tokens, empty pools, OTC, CEX-internal books, or a compromised-but-approved address.

## Is it safe to build migration / vesting on top yet?

- **Design them as consumers of the ABI — yes.**
- **Start production implementation on the current ABI — NO.** The ABI is not frozen. First close: participant
  trust model (Agent 2), canonical repo move (Wave 0), guarantee/disclosure sign-off, adversarial authorization
  tests, V3 evidence, full-V4 verdict (or explicit defer), governance rehearsal — then freeze the guarded ABI.

## Still OWED before any go-live (unchanged, do NOT skip)

- External security audit of the guarded core.
- Full V4 gateway PoC against `v4-core` (build a custom `BiniV4Gateway` that validates PoolKey/PoolId and
  never issues user claims) — V4 remains OPTIONAL to launch.
- V3 fork PoC.
- Written CEX / custody / market-maker feedback on the permissioned perimeter + emergency freeze (listing risk).
- Supply-ledger freeze reconciliation.
- Gate A sign-off.

## Not guaranteed (must stay disclosed)

Fake look-alike tokens, empty pools, OTC, CEX-internal books, economically-equivalent synthetic markets, and a
**compromised approved address** running arbitrary logic. The guard keeps *real BINI* inside a governed
perimeter; it is not an absolute market ban.
