# ECON-2.2 Agent 5 — Uniswap V3 Fork Evidence

**Executed** against real mainnet contracts on a `publicnode` fork (latest block), commit `47bb25b`,
`test/fork/GuardedV3Fork.t.sol` — **3/3 pass**. Full suite 64 green.

| Contract | Address |
|---|---|
| V3 Factory | `0x1F98431c8aD98523631AE4a59f267346ea31F984` |
| NonfungiblePositionManager (NPM) | `0xC36442b4a4522E871399CD717aBDD847Ab11FE88` |
| SwapRouter02 | `0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45` |

## What was proven

1. **Approved pool is fully usable** (`test_Guarded_Official_V3_Pool_MintAndSwap`): create + initialize a real
   BINI/mUSD 0.3% pool, approve it as `MARKET_ENDPOINT`, approve NPM + Router as operators, then via the **real
   NPM** mint liquidity (BINI lands in the pool) and via the **real Router** swap both directions
   (mUSD→BINI pays BINI out of the pool to the user; BINI→mUSD pulls BINI into the pool).
2. **Unknown pool cannot receive BINI** (`test_Guarded_Unknown_V3_Pool_CannotReceiveBINI`): a second,
   initialized-but-unapproved 0.05% pool. The real NPM mint callback attempts to pull BINI into it →
   `TransferNotAllowed` bubbles up through NPM → mint reverts, pool BINI balance stays `0`.
3. **Endpoint revocation blocks further feeding** (`test_Guarded_Endpoint_Revocation_BlocksFurtherFeeding`):
   after revoking the pool's `MARKET_ENDPOINT` class, the same operator-driven mint reverts.

## Observed BINI transfer legs (who moves what)

| Action | `from` | `to` | ERC20 `msg.sender` | Passes because |
|---|---|---|---|---|
| Mint liquidity (NPM) | genesis (SYSTEM) | pool (ENDPOINT) | NPM | `to`=ENDPOINT → `approvedOperator[NPM]` |
| Swap mUSD→BINI (out) | pool (ENDPOINT) | genesis (SYSTEM) | pool | `to`≠ENDPOINT → `msg.sender==from` (pool) |
| Swap BINI→mUSD (in) | genesis (SYSTEM) | pool (ENDPOINT) | Router | `to`=ENDPOINT → `approvedOperator[Router]` |

## Smallest required operator + endpoint set (per official V3 pool)

- Each official pool address → `MARKET_ENDPOINT`.
- `NonfungiblePositionManager` → operator (liquidity add/collect legs that push BINI into the pool).
- `SwapRouter02` → operator (swap legs that push BINI into the pool).
- Nothing else. The pool paying BINI *out* needs no operator (pool is both `from` and `msg.sender`).
- Permit2 was **not** required in these flows (NPM/Router pull via standard ERC20 allowance to themselves).

## Residual — `approvedOperator` is GLOBAL (must be disclosed + governed)

An approved operator (NPM, Router) can move BINI **from any participant to any approved MARKET_ENDPOINT**,
bounded only by (a) the participant's ERC20 allowance to that operator and (b) the destination being an approved
endpoint. It is **not** scoped per-holder or per-pool. Consequences:

- A user is only exposed to the extent they grant allowance to NPM/Router (standard DEX trust).
- Approving a *malicious or overly-broad* operator would let it sweep any allowance-granting participant's BINI
  into any approved endpoint. **Only vetted, immutable, well-known periphery** (canonical NPM/Router) should be
  operators. This is the V3 analogue of the V4 "do not approve a generic router as V4 operator" caveat, and
  must be an item in the participant/governance runbook.
- Revoking an operator is immediate and global.

## Status

```
V3 GUARDED INTEGRATION: FEASIBILITY GREEN (real periphery, 3/3)
RELEASE EVIDENCE:       still needs canonical repo + pinned-fork rerun + audit
```
