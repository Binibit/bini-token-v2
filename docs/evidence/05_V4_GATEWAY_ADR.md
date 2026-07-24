# ECON-1 — Uniswap V4 Gateway ADR (executed PoC)

> The decisive `CONDITIONAL` for Model C. Executed against the REAL mainnet V4 PoolManager singleton
> (`0x000000000004444c5dc75cB358380D2e3dE08A90`), commit `e594127`, `econ1/test/fork/V4GatewayFork.t.sol`.

## Verdict

```
V4_GATEWAY_CONDITIONALLY_FEASIBLE
```

The **entry-block mechanism is fork-proven**: a guarded BINI can force all V4 settlement through an approved gateway and keep a plain holder from ever putting real BINI into the singleton PoolManager. Full end-to-end gateway (real v4-core swap/liquidity/settle + "never issue user claims") is the remaining depth. **If the full gateway can't be built/audited, V4 is deferred — the token launches guarded on V2/V3 + CEX with no change.**

## The V4 problem (why address allowlisting alone fails)

All V4 pools share ONE `PoolManager`. Real BINI enters it via `sync → BINI.transfer(PoolManager) → settle`. If PoolManager is a plain approved endpoint that any participant may send to, then any participant can fund a rogue PoolId, and can `settle` a positive BINI delta and `mint` a BINI ERC-6909 claim to shuttle between PoolIds — the claims bypass.

## The lever (implemented + proven)

**Rule added to the guarded token:** a transfer whose `to` is a `MARKET_ENDPOINT` requires `msg.sender` to be an **approved OPERATOR** — a plain participant cannot send real BINI into a pool or the PoolManager. Consequence chain:

- User **cannot** `transfer` BINI into PoolManager → cannot `sync/settle` a BINI delta → **cannot mint a BINI ERC-6909 claim** → the claims bypass **has no entry**.
- Only an approved operator (the official gateway) may feed the PoolManager.

## Executed evidence (real mainnet V4 PoolManager)

| Test | Result | Proves |
|---|---|---|
| `test_PoolManager_HasCode` | ✅ | the real V4 singleton is live on the fork |
| `test_Direct_User_To_PoolManager_Blocked` | ✅ | participant `transfer(PoolManager)` reverts `TransferNotAllowed` → no direct funding, no claim entry |
| `test_Direct_User_To_PoolManager_viaNonOperator_Blocked` | ✅ | `transferFrom` by a non-operator spender also blocked (no back-door) |
| `test_Gateway_To_PoolManager_Allowed` | ✅ | the approved gateway (operator) CAN settle real BINI into PoolManager (official route works) |

## CRITICAL governance caveat (found during the PoC)

**Do NOT approve the generic Uniswap Universal Router / PositionManager as an operator for V4.** They route to arbitrary PoolKeys; since the PoolManager is one address for all PoolIds, a generic router-operator feeding it could settle into a **rogue** PoolId. The only safe operator that may feed the PoolManager is a **custom `BiniV4Gateway`** that internally restricts to approved PoolIds and issues no user claims.

- **V2/V3 differ:** pools have distinct addresses, so a generic router *can* be an operator safely — it can only move BINI into `to`-addresses that are approved `MARKET_ENDPOINT`s (a rogue pair is class `NONE` → blocked). V4's singleton is the special case requiring the custom gateway.

## What the custom `BiniV4Gateway` must do (for full feasibility)

Be the **only** approved operator permitted to feed the PoolManager, and internally: validate `PoolKey`/`PoolId`; serve **only approved PoolIds**; validate the hook; `unlock` → `sync`/`settle`/`take` all deltas; **never mint ERC-6909 claims to users**; expose no arbitrary-PoolKey path; log the official route. Its internal correctness is the gateway contract's audit responsibility — the token guarantees only that nothing but this operator can put BINI into the PoolManager.

## Residual bypasses (unchanged, honest)

Fake `Binibit/BINI` tokens · empty pools · scam frontends · OTC · CEX-internal · a compromised approved operator/gateway. The guard controls only on-chain movement of **real** BINI.

## Owed for `V4_GATEWAY_FEASIBLE` (full)

Build the `BiniV4Gateway` + execute against v4-core (needs the v4-core lib; its solc `^0.8.26` vs the token's exact `0.8.24` requires a separate compile unit): initialize an approved pool, swap + add/remove liquidity through the gateway, attempt a rogue PoolKey (must fail), attempt a user ERC-6909 claim mint (must have no BINI entry), multi-PoolId. Then Slither + audit the gateway.

## Bottom line

Model C's V4 story is **viable in principle and its crux (block direct PoolManager access → close claims entry) is fork-proven on the real singleton.** It requires a **custom gateway** (not the generic router) and its full end-to-end proof is owed. V4 is **optional** to the launch: guarded V2/V3 + CEX ship regardless.
