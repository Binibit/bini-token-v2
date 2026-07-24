# ECON-1 — Canon Decision + Guarded (Model C) Executed Proof

> Records the product-canon pivot to a **permanently guarded** BINI and the executed evidence for it.
> Repo `/tmp/binibit-p1`, commit **`9b9d39b`**. Not an authorized release (Gate A unsigned; V3/V4/audit owed).

## Canon decision (business-selected)

**BINI V2 = fixed 1B ERC-20 with a PERMANENT governed transfer perimeter: `BOOTSTRAP → GUARDED`, no `OPEN` mode.** This is **Model C** from `market-protection/mc1/`. It **supersedes** the minimal `BOOTSTRAP → OPEN` reference (`docs/bini-v2/p1-rc1/`), which is retained as an **evidence branch** and must **not** be developed further as production (its `OPEN` state contradicts the requirement).

- **Guarantee (target):** real BINI can move only inside a governed on-chain perimeter; an unknown V2 pair / V3 pool / contract / protocol endpoint **cannot receive or send real BINI** unless governance approves its address.
- **Explicitly NOT guaranteed:** no ban on fake `Binibit/BINI` tokens, empty pools, scam frontends, OTC, CEX-internal markets, receipts/derivatives, or abuse of an already-approved/compromised address. A token controls only **when and between which on-chain addresses real BINI moves.**

## Implemented + tested this pass — `BiniTokenV2Guarded`

`econ1/src/BiniTokenV2Guarded.sol` (real ERC-7201 slot `0x8f8334c8…f000`, asserted). OZ-first (ERC20+Permit+Capped+Pausable+AccessControlDefaultAdminRules+UUPS) + a minimal perimeter:

- `enum TransferMode { BOOTSTRAP, GUARDED }` — **one-way, no OPEN, no return path.**
- `enum AccountClass { NONE, PARTICIPANT, SYSTEM, CUSTODY, MARKET_ENDPOINT }` + `approvedOperator`.
- **Policy in `_update` (pause > guard > cap):** BOOTSTRAP → only `BOOTSTRAP_OPERATOR` sends; GUARDED → `class[from]≠NONE && class[to]≠NONE && (msg.sender==from || approvedOperator[msg.sender])`; mint(from=0) exempt.
- Role split: `POLICY_MANAGER`/`ENDPOINT_MANAGER`/`UPGRADER`=Timelock, `PARTICIPANT_MANAGER`=Ops, `EMERGENCY_REVOKER`+`PAUSER`=Security, `UNPAUSER`=Governance. Single genesis recipient. No mint/burn/tax/blacklist/forced-transfer.

## Executed evidence (real)

**Unit: 8/8** (`econ1/test/GuardedUnit.t.sol`) — mode starts BOOTSTRAP; participant→participant ok; **to-unknown blocked**; **from-unknown (revoked) blocked**; operator approved-vs-not; **mode one-way (AlreadyGuarded, no OPEN)**; bootstrap only-operator; pause precedence.

**V2 fork (real mainnet Uniswap V2 factory `0x5C69…`, latest block): 2/2** (`econ1/test/fork/GuardedV2Fork.t.sol`):
| Test | Result | Proves |
|---|---|---|
| `test_Guarded_Official_Pair_Seedable` | ✅ | in GUARDED mode, an **approved MARKET_ENDPOINT** pair receives real BINI (`createPair`+`mint` on real factory) |
| `test_Guarded_Unknown_Pair_PermanentlyBlocked` | ✅ | in GUARDED mode, a **normal holder cannot move real BINI into an unknown pair — permanently** (reverts `TransferNotAllowed`), not just pre-launch |

**This is the Model C win over Model A, now fork-proven for V2:** the permanent guard keeps real BINI out of unauthorized standard pools forever. Full repo: **37 unit/invariant + 5 fork = 42 tests green**.

## Status vs the full ECON-1 canon (the user's Master doc)

| Area | Status |
|---|---|
| Guarded product model (Model C) | **SELECTED** (business) + **V2-fork-proven** |
| Guarded token contract | **IMPLEMENTED + TESTED** (reference; not audited) |
| V2 enforcement | **FORK-PROVEN** |
| V3 enforcement | owed (per-pool-address, like V2 — now runnable on fork) |
| **V4 gateway + ERC-6909 feasibility** | **owed — the decisive `CONDITIONAL`; if it fails, launch without V4** |
| Supply ledger (Σ==1B), migration Model A, buckets | owed — needs Q1/Q2 + business freeze |
| Vesting/rewards/staking, bridge/WrappedBINI, governance rosters, API/data | design canon in prior phases; freeze owed |
| CEX/custody compatibility (written) | owed (business/venue) |
| External audit · Gate A · mainnet | owed / prohibited |

## Now-runnable next (fork works here)

1. **V3 enforcement fork PoC** (approve official V3 pool as MARKET_ENDPOINT; unknown pool blocked; router/PositionManager/Permit2 as approved operators).
2. **V4 gateway + ERC-6909 PoC** — the key open question: can a gateway keep real BINI out of unauthorized PoolIds without issuing user claims / allowing direct PoolManager access? If not → **defer V4**, launch with guarded V2/V3 + CEX.
3. Freeze the supply ledger once Q1/Q2 + business decisions close.

**No mainnet deploy. The `BOOTSTRAP→OPEN` reference is superseded (evidence only).**
