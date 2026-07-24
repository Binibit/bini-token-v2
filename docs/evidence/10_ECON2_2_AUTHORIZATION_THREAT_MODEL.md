# ECON-2.2 Agent 6 — Authorization Threat Model

**Evidence:** `test/invariant/AdversarialAuthzInvariant.t.sol`, 5 invariants × 64 runs × 4096 calls, 0 reverts,
commit `bdda641` (suite 70 green). The harness gives an adversary **full control of the Operations and Security
safes** and a hostile contract approved as a `PARTICIPANT`, then fuzzes exfiltration, escalation, freeze/restore
races, arbitrary approvals, operator abuse, and UUPS upgrades.

This model does **not** claim the contract can detect an address's economic nature. It classifies each threat.

## Classification

### PREVENTED BY CONTRACT (holds even with Ops + Security compromised)

| Threat | Why it fails |
|---|---|
| Mint / burn / supply inflation | No mint path post-genesis; cap enforced. `invariant_SupplyConstant`. |
| Leak BINI outside the perimeter | GUARDED requires `class[to] != NONE`. `invariant_OutsiderNeverReceives` — a never-approved address never receives BINI even while a hostile approved contract spams transfers to it. |
| Hostile approved participant escalates itself | `PARTICIPANT_MANAGER` can't call sensitive setters; `_manageClass` boundary blocks cross-class writes. `invariant_MaliciousNeverEscalated` (M stays PARTICIPANT or NONE, never SYSTEM/CUSTODY/ENDPOINT). |
| Compromised Ops mints a SYSTEM/CUSTODY/ENDPOINT out of thin air | Sensitive class managers are Timelock-only (`AccessControlUnauthorizedAccount`). |
| Freeze becomes confiscation | `emergencyRevoke` touches class only; `invariant_Conservation` holds through freeze storms. |
| Revert GUARDED → BOOTSTRAP | One-way mode. `invariant_GuardedMonotonic`. |

### MITIGATED BY GOVERNANCE (contract allows it; controls + delay + rehearsal contain blast radius)

| Threat | Mitigation |
|---|---|
| Compromised Security Safe freezes critical infra (vault, vesting, custody, endpoint, bridge, MM) | Freeze is instant by design (revoke-fast). Mitigation: Security Safe M-of-N + monitoring + **class-specific freeze runbook** (what/when/blast-radius/who-restores/recovery-check). Restore path exists. |
| Compromised Timelock (upgrade / policy / sensitive classes) | Timelock delay + Governance-Safe proposer + Security-Safe canceller (U2). Upgrade preserves policy state (invariant harness upgrades mid-run without breaking any invariant). |
| Over-broad operator approved (could sweep any participant's allowance into an endpoint) | Only vetted immutable canonical periphery may be operators (NPM/Router/custom V4 gateway). Operator power is global — governance must never approve a generic/mutable router. Bounded by each user's ERC20 allowance. |
| Bad participant batch by compromised Ops | Ops M-of-N + batch limits + monitoring of `AccountClassSet`; emergency freeze is the fast undo. |

### ACCEPTED TRUST RISK (cannot be prevented at the token layer — disclosed, owned by governance)

| Risk | Statement |
|---|---|
| Ops approves a pool / proxy / scam contract as PARTICIPANT | The token cannot verify address nature (user vs Safe vs 4337 vs 7702 vs pool vs future CREATE2). P1 formally accepts trust in the Operations Safe. Contained: a wrongly-approved participant still cannot move BINI *outside* the perimeter, and can be frozen. |
| Approved-then-compromised address runs market logic | An in-perimeter address executing arbitrary/pool-like logic. Not detectable on-chain; handled by monitoring + freeze. |
| Economically-equivalent / synthetic / OTC / CEX-internal markets | Outside the on-chain perimeter entirely. Disclosed, not preventable. |
| Key compromise of any governance safe | Operational security (threshold, signer diversity, rotation), not Solidity. |

## Consequence for the freeze runbook (feeds Agent 3 / Agent 8)

Because `emergencyRevoke` can freeze **any** address including migration vault / vesting / custody / liquidity
endpoint / bridge adapter / market maker, the incident runbook MUST define, per class: what may be frozen, the
authorization to do so, the blast radius, who restores, and how recovery is verified. Freezing a system
contract is a legitimate incident action **and** a self-inflicted-outage risk — it needs a written procedure,
not ad-hoc use.
