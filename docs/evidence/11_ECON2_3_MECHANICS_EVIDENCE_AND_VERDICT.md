# ECON-2.3 — Governance Mechanics & Release Evidence — Bundle + Verdict

**Scope:** prove the governance MECHANICS (not just role wiring), finish the V3 release matrix, prove the
global-operator threat, and validate upgrade safety — correcting the ECON-2.2 overclaims. Originally executed
in the isolated Foundry repo `/tmp/binibit-p1`; the complete commit lineage is now published in
`https://github.com/Binibit/bini-token-v2`. **Suite: 119 green (93 non-fork + 26 fork).** Review-only, no mainnet.

## Commit lineage (this epic)

| Commit | Agent | Evidence |
|---|---|---|
| `d33c463` | Agent 2 | Real TimelockController rehearsal, 12/12 |
| `3af4606` | Agent 5 | Global-operator threat proof, 10/10 |
| `b8a3b7d` | Agent 4 | Complete V3 release matrix, 14/14 |
| `b0e3172` | Agent 3 | Freeze blast-radius + recovery, 7/7 |
| `a8c4f95` | Agent 6 | Upgrade safety + state preservation, 6/6 |

Parents (prior epics): `bdda641` (adversarial authz), `273f82e` (U2), `47bb25b` (V3 PoC), `17904dc` (genesis gate).

## Toolchain (rehearsal — final pin owed at Agent 8/CI)

```
forge 1.5.1-stable ; solc 0.8.24 (pragma floor; 0.8.36 = candidate, NOT final)
OZ contracts v5.6.1 @ 5fd1781b ; OZ upgradeable @ 7bf4727a
ERC-7201 namespaced storage slot 0x8f8334c8...f000 (no ambient storage — forge storage-layout empty by design)
creation-bytecode keccak (rehearsal build) 0x33bf0335...ed4f
```
Reproducible-build gaps (owed before freeze): container build + digest, bytecode_hash=none pin verification,
selector/ABI diff gate in CI, OZ storage-layout validator in CI. ABI + selectors exported to `artifacts/`.

## What is now PROVEN (corrects ECON-2.2)

| ECON-2.2 gap | ECON-2.3 status | Evidence |
|---|---|---|
| U2 GOVERNANCE MECHANICS owed (role-wiring only) | ✅ real Timelock schedule→delay→execute; early-exec reverts; cancel works; timelock is msg.sender for unpause/endpoint/operator/upgrade; deployer holds nothing; not bricked | `TimelockGovernance.t.sol` 12/12 |
| GLOBAL OPERATOR abuse not proven | ✅ real `transferFrom` via a MaliciousOperator, 9 rows classified | `GlobalOperatorInvariant.t.sol` 10/10 |
| V3 RELEASE MATRIX partial | ✅ increase/decrease/collect, pause-during-mint+swap+recovery, allowance/deadline/slippage, 2nd-tier approved/unapproved, operator revoke; **Permit2 confirmed unused** | `GuardedV3ReleaseMatrix.t.sol` 14/14 |
| Freeze blast-radius undocumented | ✅ per-class freeze+recovery, balance-invariant, pause-override | `FreezeRecovery.t.sol` 7/7 + runbook |
| Upgrade preservation partial | ✅ 14 fields preserved across upgrade; structural rejects (non-UUPS, wrong UUID, non-UPGRADER); policy-prohibited evil-impl demonstrated | `UpgradeStatePreservation.t.sol` 6/6 |

## Two findings that sharpen the model

1. **Global operator is broader than "feed the pool."** An approved operator can move BINI **participant→participant**,
   not only holder→endpoint (the endpoint-requires-operator rule is *additive* only for MARKET_ENDPOINT
   destinations; for any other in-perimeter destination an approved operator alone satisfies `senderOk`). Bounded
   only by each holder's ERC20 allowance + the perimeter. Kill-switches proven: freeze, operator/endpoint revoke.
   ⇒ Only vetted, immutable, well-known periphery may EVER be an operator (registry in
   `config/governance-manifest.rehearsal.json`).
2. **The proxy does not stop a storage-compatible malicious upgrade.** It enforces only UUPS structure + UPGRADER
   auth. An UPGRADER-approved evil impl can mint past cap / confiscate by writing the ERC-7201 ledger directly.
   ⇒ Defenses are governance (UPGRADER = Timelock, delayed + cancellable), external audit, and CI storage-layout
   validation — never the proxy alone.

## Freeze recovery hazard (runbook item)

Recovering a frozen SYSTEM/CUSTODY/ENDPOINT via Ops `setParticipants` mis-classifies it as `PARTICIPANT`.
Recovery MUST route through the class manager. See `docs/runbooks/CLASS_SPECIFIC_FREEZE.md`.

---

# VERDICT: `MECHANICS_GREEN_RATIFICATIONS_REQUIRED`

Technical mechanics pass; business ratifications, canonical repo, and final build/audit remain open.

### Green (technical)
- U2 real Timelock mechanics ✅ · V2 core ✅ · V3 complete matrix ✅ · global-operator threat ✅ ·
  freeze/recovery ✅ · upgrade safety + state preservation ✅ · adversarial authz ✅ · genesis gate ✅ ·
  Slither no High/Medium in core ✅ · V4 explicitly deferred ✅

### Blocking freeze → audit (owed)
- **Business ratifications** (Gate A): P1 owner sign-off; Ops/Security/Governance thresholds; Timelock delay;
  operator allowlist; exact public guarantee wording. (`docs/release/00_BUSINESS_RATIFICATIONS.md` — not yet created.)
- **Canonical publication**: established at `https://github.com/Binibit/bini-token-v2`; final audit binding to
  one frozen commit remains owed.
- **Reproducible build**: container build + digest, toolchain lock, CI selector/ABI/storage diff + OZ validator.
- **External audit**: required, not started.
- **Independent release review** bound to one clean canonical commit.

### Do NOT start yet
Production Migration Vault, Vesting Factory, bridge, WrappedBINI, staking, V4 gateway, backend admin.
Read-only downstream interface design only.

## Honest status line

```
GUARDED CORE:               HARDENED REFERENCE (not frozen)
U2 GOVERNANCE MECHANICS:    GREEN (real Timelock)
V2 / V3 RELEASE MATRIX:     GREEN
GLOBAL OPERATOR THREAT:     PROVEN + governed via registry
FREEZE BLAST-RADIUS:        GREEN + runbook
UPGRADE SAFETY:             GREEN (structural) ; evil-impl = governance-gated
ADVERSARIAL AUTHZ:          GREEN
V4:                         DEFERRED (non-blocking)
P1 / THRESHOLDS / DELAY:    RECOMMENDED — NOT RATIFIED
CANONICAL REPO:             ESTABLISHED (release freeze still owed)
REPRODUCIBLE BUILD / AUDIT: OWED
ABI FREEZE / DOWNSTREAM:    BLOCKED
MAINNET:                    PROHIBITED
```
