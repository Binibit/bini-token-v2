# ECON-2 — Holder Disclosure Correction + Privilege/Policy Audit

Two deliverables the ECON-2 audit required: (A) an honest holder-facing disclosure of the guard's real powers,
correcting the earlier "no blacklist" framing; (B) a manager-by-manager privilege audit proving no cross-class
authority remains.

---

## A. Disclosure correction — what BINI V2 CAN and CANNOT do to a holder

BINI V2 is a **permanently permissioned** ERC-20. This must be disclosed to holders, CEX listing/compliance,
custodians, market makers, auditors, and legal **before** any distribution. The earlier ECON-1 phrasing
("no blacklist / no confiscation") was **incomplete** — corrected below.

### The token CANNOT (verified from source — no such code path exists)

- **Confiscate / forcibly transfer** a balance. No admin-move, no `transferFrom` without allowance.
- **Mint** beyond the fixed 1,000,000,000 genesis supply (capped, no mint function).
- **Burn / rewrite** a holder's balance. `emergencyRevoke` touches *class*, never balance.

### The token CAN (governed powers — must be disclosed)

- **Gate transfer eligibility.** In `GUARDED` mode a transfer settles only when both parties are inside the
  approved perimeter and the sender is authorized. An address that is not approved simply **cannot send or
  receive real BINI** on-chain.
- **Emergency FREEZE (`emergencyRevoke`).** The Security Safe can set any address's class to `NONE`. Effect:
  the address **keeps its full balance** but cannot send or receive until a governed manager re-approves it.
  This is a **freeze, not a confiscation** — the tokens are never taken, moved, or destroyed. It is the
  **emergency revoke-fast** half of the asymmetry: freeze is instant. (Grant is a *controlled* grant, not a
  slow one — see doc 08. Unpause topology is a separate, unresolved governance decision — U1 vs U2.)
- **Pause** all transfers (Security Safe), **unpause** (Governance Safe).
- **Upgrade** the implementation (Timelock, UUPS).

### Plain-language line for holder docs

> BINI is a permissioned token. To hold or trade real BINI on-chain your address must be part of the approved
> Binibit network. Binibit can freeze an address's ability to transfer in an emergency; your balance is never
> taken or destroyed, and transfer ability is restored when the address is re-approved.

### What the guard does NOT protect against (must also be disclosed)

Look-alike/fake tokens, empty pools, OTC deals, CEX-internal order books, economically-equivalent synthetic
markets, and a **compromised but still-approved address** executing arbitrary logic.

---

## B. Privilege / policy audit — cross-class authority is closed

**Method:** exhaustive per-manager reasoning + a stateful fuzz campaign (`GuardedPolicyInvariant`, 64 runs ×
4096 calls, 0 reverts on the invariants) that repeatedly has Ops attempt every sensitive action.

### B.1 Authority matrix (who can change what)

| Actor / role | PARTICIPANT | SYSTEM | CUSTODY | MARKET_ENDPOINT | operator flag | freeze | pause | unpause | upgrade | activate guarded |
|---|---|---|---|---|---|---|---|---|---|---|
| Ops (`PARTICIPANT_MANAGER`) | ✅ own class only | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Timelock (`SYSTEM/CUSTODY/ENDPOINT/OPERATOR_MANAGER`, `POLICY`, `UPGRADER`) | ❌ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ | ✅ | ✅ |
| Security (`PAUSER`, `EMERGENCY_REVOKER`) | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ (→NONE, any class) | ✅ | ❌ | ❌ | ❌ |
| Governance (`UNPAUSER`) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ |
| Genesis (`BOOTSTRAP_OPERATOR`) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |

Key point (P0.1): the class managers are boundary-scoped, so ✅ in a class column means **only** moves between
`NONE ↔ that class`. No manager can pull an address held in a *different* class. `emergencyRevoke` is the sole
authority that crosses classes, and it only ever moves **toward** `NONE` (freeze) — never sideways or upward,
and never touches balance.

### B.2 The specific bypasses the audit named, now blocked

1. **Ops marks a rogue pool as SYSTEM/CUSTODY** → `setSystemAccounts`/`setCustodyAccounts` require
   `SYSTEM/CUSTODY_MANAGER_ROLE`, which Ops does not hold → `AccessControlUnauthorizedAccount`.
2. **Ops strips a Timelock-approved SYSTEM address** → `setParticipants(sysAddr, false)` hits
   `ClassBoundaryViolation(sysAddr, SYSTEM, PARTICIPANT)`. Fuzz-proven: `SystemAddrClassPreserved` never
   observes `sysAcct` leave `SYSTEM` across 4096 hostile calls **and** a live UUPS upgrade.
3. **Ops self-approves an operator to feed a pool** → `setOperators` requires `OPERATOR_MANAGER_ROLE` (Timelock).
4. **Bootstrap strands a balance** → `BootstrapRecipientNotApproved` forces onboarding-before-distribution.

### B.3 Residual risks (accepted, not code-fixable here)

- **Timelock/Security key compromise.** Mitigation is operational: timelock delay, multisig thresholds,
  role separation across distinct signer sets (already reflected in the 6-arg init: 4 distinct safes + timelock).
- **Approved address turns malicious.** In-perimeter but hostile. Mitigation: emergency freeze + monitoring.
- **Upgrade risk.** `UPGRADER = Timelock`; new implementation must re-pass audit + storage-layout check.

**Verdict:** the ECON-2 privilege-bypass and trapped-balance P0s are closed at the contract layer with
executable proof. Remaining risk is operational (key management) and must be handled by the governance
runbook, not the token.
