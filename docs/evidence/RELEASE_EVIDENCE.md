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
| `test/script/DeployBiniTokenV2.t.sol` | environment validation and initialized proxy deployment |
| `test/e2e/ReleaseLifecycle.t.sol` | complete deployment-to-upgrade release lifecycle |
| `test/invariant/BiniTokenV2Invariant.t.sol` | fixed supply, conservation, monotonic opening |
| `test/governance/TimelockGovernance.t.sol` | real delayed Timelock execution |
| `test/upgrade/UpgradeStatePreservation.t.sol` | UUPS authorization and namespaced-state preservation |
| `test/fork/DexMarketFork.t.sol` | real mainnet Uniswap V2, V3 and V4 destinations |
| `test_cli/test_release_cli.py` | input validation, exact calldata, immutable artifacts and Timelock packages |
| `tools/test-release-anvil.sh` | receipt-backed deploy, policy, distribution, migration and market lifecycle |

The exact command results are recorded in the release commit and GitHub Actions.

Current release run:

- local Solidity suites: `69 passed, 0 failed`;
- mainnet-fork suite: `4 passed, 0 failed`;
- release CLI suite: `15 passed, 0 failed`;
- local Anvil release rehearsal: passed;
- token coverage: `100%` lines, branches and functions;
- migration-vault coverage: `97.65%` lines, `87.50%` branches and `90%` functions;
- Slither `0.11.4`: `0` findings under documented exclusions;
- OpenZeppelin Upgrades Core `1.46.0`: validation passed.

## Revalidation 2026-08-02

- local `main` and `origin/main` were synchronized before the run;
- `make release-check` passed again on the final contract tree;
- `69` local Solidity, `15` CLI and `4` pinned mainnet-fork tests passed;
- the local Anvil release rehearsal completed the full lifecycle using actual
  receipts and delayed Timelock execution;
- coverage remained above every enforced token and migration-vault threshold;
- Slither and OpenZeppelin upgrade validation passed again;
- release ABI, selectors, bytecode hashes and storage schema remained consistent;
- deployment preflight and manifest recovery passed against local Anvil
  contracts, including role, implementation-slot and initializer-replay checks.

GitHub Actions run `30712720161` passed every release gate on commit `26da1ae`,
including the pinned mainnet-fork suite. The preceding run exposed a pruned
public Flashbots archive response; CI now prefers a configured archive RPC and
retries independent public archive endpoints without weakening test assertions.

## Residual Risks

- universal automatic AMM detection is impossible at the ERC-20 layer;
- an undeployed CREATE2 address can be pre-funded;
- unknown AMMs remain ordinary contract recipients until registered;
- governance can misclassify a contract wallet as infrastructure;
- UUPS governance can replace token logic;
- public RPC availability is external; deployment sign-off must rerun the pinned
  block and code hashes against a production-controlled archive endpoint.

## Remaining Release Gates

- ratify all governance Safe, Timelock and genesis addresses;
- ratify Timelock and default-admin delays;
- ratify factories and infrastructure with runtime code hashes;
- add reproducible deployment and explorer-verification evidence;
- complete external audit;
- execute a Sepolia rehearsal and archive the transaction bundle.
