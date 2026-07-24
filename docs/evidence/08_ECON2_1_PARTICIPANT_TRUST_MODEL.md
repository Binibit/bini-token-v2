# ECON-2.1 Agent 2 — Participant Trust Model

**The open P0.** In `GUARDED` mode a transfer settles when `class[from] != NONE && class[to] != NONE` (plus
the endpoint/operator rule). `PARTICIPANT_MANAGER` (Operations Safe) can set **any** address to `PARTICIPANT`
via `setParticipants`. The token **cannot** determine whether that address is a real user, a Safe, a smart
wallet, a Uniswap pool, a proxy, a scam contract, or a not-yet-deployed CREATE2 address. If a pool is classed
`PARTICIPANT`, the `MARKET_ENDPOINT` operator rule never fires and it transacts like any holder.

**Therefore, honestly:** the token cannot *prove* an address's economic nature. Keeping real BINI out of
unauthorized markets is a function of **who approves participants and how** — a trust model, not an enum. This
doc compares three; the business has selected **P1 as the lead candidate**.

---

## Dimension comparison

| Dimension | P1 — Ops Safe approval | P2 — Timelocked approval | P3 — Attestation-backed |
|---|---|---|---|
| Mechanism | Ops multisig calls `setParticipants` | Approvals routed through Timelock delay | Authorized attestor signs an approval; contract/Safe verifies before class set |
| Holder scale | High — batch onboarding, no per-address delay | Poor — every onboarding waits the delay | Medium — attestation issuance is the bottleneck |
| Onboarding latency | Seconds (one Safe tx) | Hours–days (timelock delay) | Minutes–hours (attestor turnaround) |
| Gas | Lowest (batched setter) | High (schedule+execute per batch) | Medium (verify signature/proof on-chain or in Safe) |
| Revocation speed | Fast (Ops or emergency freeze) | Slow if revocation also timelocked | Fast (revoke attestation + freeze) |
| Compromised approver | Ops key can approve rogue addresses → **primary risk** | Delay gives a cancel window; still a governance key | Attestor key compromise = forged approvals; contract still trusts verified sig |
| Contract wallets (Safe, smart accounts) | Works — exact address approved | Works | Works if attestor covers contract wallets |
| ERC-4337 accounts | Works — approve the account address (counterfactual code=0 doesn't matter for exact-address allowlist) | Works | Works |
| EIP-7702 EOAs | Works — approval is by exact address; 7702 breaks *type* classification, not exact allowlist. Residual: an approved 7702 EOA can run arbitrary delegated code | Same | Same |
| CEX withdrawals to new users | Smooth — Ops pre-approves or approves on first withdrawal | Painful — user waits the delay before receiving | Depends on attestor SLA |
| Legal / compliance disclosure | "Binibit approves who can hold BINI" — clear, must be disclosed | Same + slower | Strongest compliance story (identity attested) |

---

## Recommendation — P1 (Ops Safe approval), with mandatory mitigations

P1 is the only model that preserves the launch requirement (retail-scale onboarding, CEX withdrawal UX). Its
asymmetry is **controlled-grant + emergency-revoke-fast**: onboarding is fast and cheap (one Ops Safe batch),
and freeze is instant. It is **not** "grant-slow" — a true grant-slow would need an added Timelock / staged /
second-approver / delayed-activation mechanism (see §"If grant-slow is actually required"), which degrades
onboarding + CEX UX. P1's single real weakness is a compromised or careless Operations Safe approving
rogue/pool addresses. P1 is acceptable **only** bundled with these controls, which the business must formally
accept as the trust boundary:

1. **Operations Safe is a real multisig** with an M-of-N threshold and signer diversity — never a single EOA.
   Distinct from the Timelock, Security, Governance, and Genesis safes (already reflected in the 6-arg init).
2. **Onboarding SOP + batch limits.** A documented process for what may be approved. `code.length` is an
   **alert signal only, never a security rule** — smart accounts have code, counterfactual/4337 addresses may
   have none, 7702 changes the EOA model, and code can be deployed *after* approval. The SOP gates on address
   provenance, approved onboarding source, Safe-proposal evidence, known-protocol registries, and
   post-approval behavioral monitoring — with contract-code presence merely raising an alert for review.
3. **Continuous monitoring** of `AccountClassSet` events + on-chain BINI flow; alert on approved addresses that
   subsequently behave like pools (receive both BINI and a counter-asset, mint LP).
4. **Emergency freeze rehearsed.** `emergencyRevoke` (Security Safe) is the fast undo for a bad approval; the
   incident runbook must be tested (Agent 8 governance rehearsal).
5. **Evidence log.** Every participant approval is attributable to an Ops Safe proposal + signer set.
6. **Disclosed trust boundary.** Holder/CEX/custody/legal docs state plainly that Binibit's Operations Safe
   controls participant eligibility and that a compromised Ops Safe is the residual risk.

**P3 remains the upgrade path.** If a compliance regime later requires attested identity, an attestation layer
can sit *in front of* the same `setParticipants` call (attestor → Ops Safe proposal → setter) without changing
the token. Design P1 so P3 is additive, not a rewrite.

---

## What P1 does and does not buy (for the guarantee doc)

- **Does:** keep real BINI inside a governed perimeter; block ordinary unauthorized pools (they're class `NONE`
  unless someone approves them); allow instant freeze of a bad actor.
- **Does not:** prove an approved address is a human; stop a *misclassified* pool once approved; stop fake
  tokens, empty pools, OTC, CEX-internal books, or an approved-then-compromised address running market logic.

## If grant-slow is actually required

If the business wants approvals to *not* be instant, add one of: route `setParticipants` through the Timelock;
a staged pending→active approval; a mandatory second independent approver; or delayed participant activation.
All degrade onboarding latency, gas, and CEX-withdrawal UX. Default recommendation: keep P1 fast; do **not**
label it grant-slow.

## Decision record

- **Recommended lead:** P1 — Ops Safe approval. **BUSINESS APPROVAL REQUIRED** — this is an agent
  recommendation, not a ratified owner decision. Do not treat as canonical until signed in
  `docs/release/00_BUSINESS_RATIFICATIONS.md`.
- **Participant misclassification status:** `ACCEPTED TRUST ASSUMPTION — only after business sign-off`. P1 does
  not *eliminate* the risk; it formally accepts and manages trust in the Operations Safe.
- **No token code change** is required for P1 — the current `PARTICIPANT_MANAGER → Operations Safe` wiring is
  already the P1 mechanism. Remaining work is operational (SOP, monitoring, signer set) + rehearsal, not Solidity.
