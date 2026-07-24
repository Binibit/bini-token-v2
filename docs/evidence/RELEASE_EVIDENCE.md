# BINI V2 Release Evidence

## Candidate

- Contract: `src/BiniTokenV2.sol`
- Lifecycle: `PRE_MARKET -> OPEN_MARKET`
- Compiler: Solidity `0.8.24`
- Toolchain: Foundry `1.5.1`
- Status: `IMPLEMENTATION_CANDIDATE_NOT_DEPLOY_AUTHORIZED`

## Implemented Claims

- fixed one-time genesis mint of `1,000,000,000 BINI`;
- free ordinary transfers during `PRE_MARKET`;
- standard allowance and permit surface;
- deployed V2/V3 pool recognition through registered factories;
- explicit V4/manager/router/gateway destination blocking;
- no EOA entries in the explicit infrastructure registry;
- one-way Timelock-controlled `openMarket()`;
- all DEX checks bypassed after opening;
- independent emergency pause;
- Timelock-authorized UUPS upgrades with state-preservation coverage.

## Test Matrix

| Suite | Purpose |
| --- | --- |
| `test/BiniTokenV2.t.sol` | metadata, roles, free transfers, DEX blocking, opening, pause, forbidden surface |
| `test/invariant/BiniTokenV2Invariant.t.sol` | fixed supply, conservation, monotonic opening |
| `test/governance/TimelockGovernance.t.sol` | real delayed Timelock execution |
| `test/upgrade/UpgradeStatePreservation.t.sol` | UUPS authorization and namespaced-state preservation |
| `test/fork/DexMarketFork.t.sol` | real mainnet Uniswap V2, V3 and V4 destinations |

The exact command results are recorded in the release commit and GitHub Actions.

Current release run:

- local suites: `28 passed, 0 failed`;
- mainnet-fork suite: `3 passed, 0 failed`;
- total: `31 passed, 0 failed`.

## Residual Risks

- universal automatic AMM detection is impossible at the ERC-20 layer;
- an undeployed CREATE2 address can be pre-funded;
- unknown AMMs remain ordinary contract recipients until registered;
- governance can misclassify a contract wallet as infrastructure;
- UUPS governance can replace token logic;
- public-RPC fork tests are mutable and should be rerun against a pinned,
  production-controlled archive endpoint before deployment.

## Remaining Release Gates

- ratify all governance Safe, Timelock and genesis addresses;
- ratify Timelock and default-admin delays;
- ratify factories and infrastructure with runtime code hashes;
- add reproducible deployment and explorer-verification evidence;
- run independent storage-layout and upgrade validation;
- complete external audit;
- execute a Sepolia rehearsal and archive the transaction bundle.
