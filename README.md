# BINI Token V2

Canonical Ethereum implementation candidate for Binibit (`BINI`).

## Product Model

`BINI` is freely transferable between users and system contracts from genesis.
The only temporary restriction is the movement of real BINI into recognized
DEX/AMM infrastructure:

```text
PRE_MARKET  -- Timelock: openMarket() -->  OPEN_MARKET
```

- `PRE_MARKET`: wallet, Safe, custody, vesting, rewards, migration and OTC
  transfers use the standard ERC-20 flow. Transfers into configured DEX
  infrastructure and recognized V2/V3 pools are blocked.
- `OPEN_MARKET`: the DEX check is bypassed forever. BINI behaves as a standard
  permissionless ERC-20, subject only to the independent emergency global pause.

There is no participant allowlist, KYC, transfer tax, max-wallet rule, runtime
mint, burn, confiscation, forced transfer or post-opening blacklist.

## Fixed Properties

- Name: `Binibit`
- Symbol: `BINI`
- Decimals: `18`
- Supply: `1,000,000,000 BINI`, minted once during initialization
- Upgrade model: UUPS, authorized by the governance Timelock
- Emergency pause: Security Safe pauses; Timelock unpauses

## Security Boundary

The token automatically recognizes deployed V2/V3-style pools only when their
factory has been registered by governance. V4 `PoolManager`, routers, liquidity
managers and gateways are explicit infrastructure entries.

An ERC-20 cannot reliably identify every unknown or future AMM. In particular,
an undeployed CREATE2 pool address can be pre-funded while it has no code and is
indistinguishable from an ordinary wallet address. The absolute universal
requirement is therefore `BLOCKED`; this repository implements the narrow,
no-user-allowlist compromise described in
[`PRE_MARKET_DEX_POLICY.md`](docs/architecture/PRE_MARKET_DEX_POLICY.md).

## Status

`IMPLEMENTATION_CANDIDATE_NOT_DEPLOY_AUTHORIZED`

The implementation and tests are ready for independent review. Mainnet
deployment still requires ratified governance addresses, reproducible
deployment evidence and an external audit.

## Build And Test

Foundry `1.5.1` and Solidity `0.8.24` are pinned for the current candidate.

```sh
git submodule update --init --recursive
forge fmt --check
forge build --sizes
forge test --no-match-path "test/fork/*"
forge test --match-path "test/fork/*"
```

The fork suite uses `https://ethereum-rpc.publicnode.com`.

## Repository Layout

- `src/BiniTokenV2.sol`: canonical token implementation
- `test/`: unit, invariant, governance, upgrade and mainnet-fork evidence
- `script/DeployBiniTokenV2.s.sol`: environment-driven UUPS deployment
- `config/governance-manifest.rehearsal.json`: non-production governance template
- `docs/PRODUCT_REQUIREMENT.md`: product canon
- `docs/architecture/PRE_MARKET_DEX_POLICY.md`: feasibility and threat boundary
- `docs/runbooks/MARKET_OPEN.md`: configuration and one-way opening procedure
- `artifacts/release/`: generated ABI, selectors and storage layout
