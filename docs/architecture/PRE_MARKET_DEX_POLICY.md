# PRE_MARKET DEX Policy

## Decision

The exact universal statement, "allow every ordinary address but block every
present and future AMM automatically," is **BLOCKED** at the ERC-20 layer.

The implemented compromise is:

1. users and system contracts are never required to join an allowlist;
2. deployed V2/V3 pools are detected through governance-registered factories;
3. V4 `PoolManager`, routers, liquidity managers and gateways are registered as
   concrete contract destinations;
4. transfers into those destinations revert during `PRE_MARKET`;
5. `openMarket()` irreversibly bypasses every DEX restriction.

## Transfer Rule

For every mint, transfer or `transferFrom`, pause is checked first. The initial
mint is exempt from DEX policy. A normal transfer follows:

```text
OPEN_MARKET
    -> standard ERC-20 update

PRE_MARKET
    -> destination is explicit market infrastructure? revert
    -> destination is a factory-confirmed V2/V3 pool? revert
    -> otherwise standard ERC-20 update
```

The sender, operator and ordinary recipient do not need token-specific approval.
An infrastructure entry must have deployed code, which prevents adding EOAs to
the explicit registry. This is a guardrail, not proof that a contract is a DEX:
governance must not register Safe, custody, vesting or other ordinary contract
wallets.

## V2 Recognition

For a deployed candidate, the token reads `factory()`, `token0()` and `token1()`.
It blocks the destination only when:

- the factory is registered as `UNISWAP_V2`;
- one pool token is BINI;
- `factory.getPair(token0, token1)` returns the candidate address.

This covers deployed pools of registered V2-compatible factories without
registering every pair.

### V2 CREATE2 Limit

A hostile actor can derive a future pair address, transfer BINI to it before
deployment, and create the pair later. Before deployment the address has no code
and is indistinguishable from an EOA. Blocking every code-less destination would
break wallet-to-wallet transfers and is forbidden by the product requirement.

Therefore the contract cannot prove that real BINI never reaches every possible
V2 pair. Monitoring planned factory deployments and incident response are
required residual controls.

## V3 Recognition

V3 recognition additionally reads `fee()` and confirms the candidate with
`factory.getPool(token0, token1, fee)`.

V3 mint settlement requires a balance increase during the callback, so simple
pre-funding does not satisfy the normal mint payment check. Nevertheless, the
token claims only destination blocking, not universal control of arbitrary V3
forks.

## V4

V4 uses a singleton `PoolManager`; a token transfer does not expose a pool id.
The launch configuration therefore registers the concrete PoolManager and any
market gateways or liquidity managers as explicit infrastructure. BINI cannot
be transferred into those contracts during `PRE_MARKET`.

## Unknown AMMs

An unknown AMM contract is technically indistinguishable from a custody,
vesting, Safe or smart-account contract. It remains transferable until
governance registers it. Adding participant allowlists would widen the guarantee
but directly violate the product requirement and is not an accepted fallback.

## Governance Boundary

`MARKET_MANAGER_ROLE` belongs to the Timelock. It may configure factories and
deployed infrastructure only during `PRE_MARKET`. After `openMarket()`:

- configuration calls revert;
- historical entries remain observable but are ignored;
- no function can restore `PRE_MARKET`.

UUPS authority remains a governance master capability. An upgrade can change
these properties and therefore requires Timelock delay, independent review,
storage validation and an external audit.

## Reference Protocol Sources

- [Uniswap V2 Factory](https://github.com/Uniswap/v2-core/blob/master/contracts/UniswapV2Factory.sol)
- [Uniswap V3 Factory](https://github.com/Uniswap/v3-core/blob/main/contracts/UniswapV3Factory.sol)
- [Uniswap V3 Pool](https://github.com/Uniswap/v3-core/blob/main/contracts/UniswapV3Pool.sol)
- [Uniswap V4 Core](https://github.com/Uniswap/v4-core)
- [EIP-1014: CREATE2](https://eips.ethereum.org/EIPS/eip-1014)
