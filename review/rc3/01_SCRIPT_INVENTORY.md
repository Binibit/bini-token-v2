# BINI V2 RC3 — Script Inventory and Coverage Gate

Checked against commit:
`7093d18e66dfc0f1f394b8c274bb551c8cd5c5c6`

## Gate result

`BLOCKED_SCRIPT_COVERAGE`

> RC3A supersession: the missing rows below were implemented on
> `feature/rc3-release-automation`. The executable coverage, tests and final
> verdict are recorded in `review/rc3a/` and `BINI_V2_RC3A_VERDICT.md`. This
> document remains the unchanged-baseline analysis except for this pointer.

The repository has a strong Phase 1 planning/verifier CLI and a receipt-backed
local Anvil rehearsal, but it does not contain executable release scripts for
every mandatory RC3 Sepolia lifecycle step. Under the RC3 stop condition, no
Sepolia signer was generated, no Safe or Timelock was deployed, and no
transaction was submitted.

## Stable release CLI

All commands default to non-transacting `PLAN`. `SIMULATE` and `SAFE_PROPOSAL`
can write immutable JSON packages. Only `deploy` supports `BROADCAST`; the Safe
and Timelock-owned commands deliberately refuse direct broadcast.

| Command | Phase | Inputs and signer | Writes / expected output | Idempotency and recovery | Receipt path |
| --- | --- | --- | --- | --- | --- |
| `./bin/bini-v2 preflight --network sepolia [--config ...]` | source/Phase 1 input gate | config, ledger, `EXPECTED_GIT_COMMIT`, `SEPOLIA_RPC_URL`, `DEPLOYER_ADDRESS`; read-only | JSON to stdout: source, toolchain, chain, Safe threshold and deployer-balance checks | repeatable; fails closed on drift | none |
| `./bin/bini-v2 deploy --network sepolia [--config ...]` | Timelock + token deploy | deployer encrypted Foundry account in `BROADCAST`; config and RPC | simulation evidence or `artifacts/deployments/sepolia/deployment.json` | returns `ALREADY_RECORDED` if manifest exists and verifies; refuses overwrite | `broadcast/DeployBiniV2.s.sol/11155111/run-latest.json` plus deployment manifest |
| `./bin/bini-v2 configure-market --network sepolia [--policy ...]` | Phase 3 DEX policy | Governance Safe proposer/executor packages; config, deployment and DEX policy | Timelock schedule/execute Safe Transaction Builder package | omits already configured entries; returns `DEX_POLICY_COMPLETE` or `ALREADY_PLANNED` | `artifacts/deployments/sepolia/pre-market-policy-<hash>.json`; no execution receipt |
| `./bin/bini-v2 open-market --network sepolia [--policy ...]` | Phase 3 market opening | Governance Safe proposer/executor packages; verified PRE_MARKET policy | Timelock schedule/execute package for `openMarket()` | stable deployment-derived artifact; returns `ALREADY_PLANNED`; direct broadcast forbidden | `artifacts/deployments/sepolia/open-market-<hash>.json`; no execution receipt |
| `./bin/bini-v2 distribute --network sepolia --ledger ...` | Phase 1 distribution | Genesis Distribution Safe package; deployment, ledger and RPC | exact nine-transfer Safe Transaction Builder JSON | detects fully distributed and partial/inconsistent states; stable ledger-version path | `artifacts/distributions/sepolia/distribution-<ledger-version>.json`; no executed Safe receipt |
| `./bin/bini-v2 migration-plan --network sepolia --holders ... [--migration-config ...]` | Phase 2 entitlements | Timelock Safe packages; migration config and holder CSV | source-attributed liabilities, entitlement calls and seal operation | immutable hash-derived path; validates exact accounting | `artifacts/migrations/sepolia/migration-plan-<hash>.json`; no execution receipt |
| `./bin/bini-v2 migrate --network sepolia --holders ... --batch ...` | Phase 2 holder calls | each holder or Safe-native authorization | holder migration calldata package | skips completed on-chain actions; refuses direct batch broadcast | `artifacts/migrations/sepolia/batch-<batch>-<hash>.json`; no holder execution receipt |
| `./bin/bini-v2 verify --network sepolia [--ledger ...]` | Phase 1 verification | RPC, deployment manifest, config and ledger | immutable verification JSON for metadata, roles, proxy slot, supply and distribution state | repeatable with timestamped artifact; requires `PRE_MARKET` | `artifacts/verification/sepolia/verification-<timestamp>.json` |
| `./bin/bini-v2 verify-migration --network sepolia [--migration-config ...]` | Phase 2 verification | RPC, config, deployment and vault | locked/released/liability reconciliation JSON | repeatable with timestamped artifact | `artifacts/verification/sepolia/migration-<timestamp>.json` |
| `./bin/bini-v2 status --network sepolia` | summary | config; RPC only outside `PLAN` when deployment exists | JSON artifact inventory; optionally market flag and Phase 1 balance state | read-only and repeatable | none |

## Foundry script entry points

| Script | Function and write boundary |
| --- | --- |
| `script/DeployBiniV2.s.sol:DeployBiniV2` | deploys one Timelock, implementation and atomic ERC1967 proxy; broadcast-capable through the CLI |
| `script/DeployBiniTokenV2.s.sol:DeployBiniTokenV2` | deploys implementation/proxy against an already deployed Timelock; not wired into the stable CLI |
| `script/BootstrapDistribution.s.sol:BootstrapDistribution` | generates one ERC-20 transfer calldata tuple; never broadcasts |
| `script/MigrateKnownHolders.s.sol:MigrateKnownHolders` | generates one holder migration calldata tuple; never broadcasts |
| `script/VerifyBiniV2.s.sol:VerifyBiniV2` | read-only token/vault checks; not a full RC3 verifier |

## Make and tool entry points

| Entry point | Purpose | Writes / evidence behavior |
| --- | --- | --- |
| `make build` | Foundry build and contract sizes | Foundry `out/` and cache |
| `make test`, `make test-local`, `make test-cli`, `make test-anvil`, `make test-fork` | aggregate or narrow test suites | test logs only when CI wraps them; Anvil test creates then cleans temporary artifacts |
| `make coverage` / `tools/coverage-gate.sh` | enforce token and Migration Vault coverage | `lcov.info` |
| `make audit` | UUPS validation and Slither | console output; incompatible fixture uses a temporary log |
| `make artifacts` / `tools/release-artifacts.sh write` | regenerate committed ABI/build/storage artifacts | overwrites canonical release artifacts by design |
| `tools/release-artifacts.sh check` | reproduce ABI, selectors, storage and bytecode hashes | temporary worktree only; read-only comparison |
| `make release-check` / `tools/release-gate.sh` | full local source/test gate | build/cache/coverage outputs; no Sepolia writes |
| `make deploy-preflight` / `tools/deploy-preflight.sh` | legacy deployment RPC/code check | stdout only; does not verify full Safe topology |
| `tools/test-release-anvil.sh` | local receipt-backed lifecycle rehearsal using Anvil mocks/impersonation | temporary local receipts copied into CI evidence and then cleaned |
| `tools/test-mainnet-fork.sh` | pinned read-only Ethereum fork suite with RPC fallback | no chain writes |
| `tools/validate-upgrades.sh` | positive UUPS and negative incompatible-storage validation | temporary negative-case log; optional CI evidence copy |
| `tools/export-ci-build-evidence.sh` | export exact build/source inputs into `BINI_EVIDENCE_DIR` | CI evidence directory |
| `tools/finalize-ci-evidence.sh` | require all CI evidence and seal it | `SHA256SUMS` in CI evidence directory |

## Mandatory RC3 coverage matrix

| Required lifecycle capability | Coverage | Finding |
| --- | --- | --- |
| Source preflight | covered | exact commit, clean tree, bytecode, RPC chain, configured Safe code/threshold and deployer balance |
| Three encrypted signer bootstrap | **missing** | no command creates three keystores, verifies encryption, records only addresses, or checks signer funding |
| Twelve Safe deployments | **missing** | no Safe proxy deployment command or Safe factory integration |
| Full Safe verification | **missing** | preflight checks only runtime-code presence and `getThreshold()`; it does not verify owners, singleton, proxy factory, version, runtime hash, modules, guard or fallback handler |
| Standalone RC3 Timelock deployment | **insufficient** | Timelock is coupled to token deployment; no infrastructure-only receipt/verification command |
| RC3 Timelock role topology | **incompatible** | `DeployBiniV2` passes Governance as proposer and gives no independent canceller input; OpenZeppelin grants cancellation to the proposer, so the required `CANCELLER_ROLE -> SECURITY_SAFE` topology is not produced |
| Timelock cancel/delay rehearsal | **missing** | no Safe-native schedule/early-fail/cancel/re-schedule/wait/execute workflow or receipt verifier |
| Token deployment | partial | repository script deploys Timelock + implementation + proxy and verifies core postconditions; explorer verification and RC3 role manifest are absent |
| Explorer source verification | **missing** | no Etherscan/Sepolia `forge verify-contract` release command, status check or verification receipt path |
| DEX policy plan | covered | deterministic Timelock/Safe packages with runtime-code-hash checks |
| DEX policy apply/receipt/verify | partial | repository creates packages and can detect completion, but does not sign/execute Safes or export execution receipts and behavior evidence |
| Nine-Safe distribution plan/proposal | covered | exact ordered nine-transfer Safe batch and pre-state checks |
| Distribution execution and event reconciliation | **missing** | no 2-of-3 Safe signing/execution command, Safe transaction receipt import, or exact-nine-`Transfer` event verifier |
| PRE_MARKET behavior matrix | **missing** | no Sepolia fixture deployer/operator covering ordinary Safe/proxy wallet, Permit, unknown AMM and future CREATE2 cases |
| Emergency pause | **missing** | no release CLI command/package for Security Safe pause or its receipt verification |
| Timelock unpause | **missing** | no schedule/early-fail/execute/unpause package and postcondition verifier |
| Migration V1 fixture | **missing** | no explicit Sepolia-only 12-decimal V1 fixture deployment command |
| Migration Vault deployment | **missing from release workflow** | local Anvil test uses direct `forge create`; no repository deployment script/CLI receipt flow for Sepolia |
| Source-Safe migration funding | **missing** | no per-allocation Safe proposal/execution/reconciliation workflow |
| Five-holder migration execution | **missing** | calldata planning exists, but signer/Safe execution and consolidated receipt validation do not |
| `openMarket()` schedule package | covered | deterministic Governance Safe schedule and execute packages |
| `openMarket()` execution/post-open verification | **missing** | no Safe execution or receipt import; `verify` explicitly requires `marketOpen == false`, while `status` checks only the flag and balances |
| Global status | partial | omits Safe owners/modules, Timelock roles/operations, DEX policy, migration, pause and receipt reconciliation |
| RC3 evidence export/seal | **missing** | CI source evidence exporter exists, but no command exports and seals the full Sepolia RC3 manifests/logs/transactions/balances/roles |

## Canon/config reconciliation findings

The committed Sepolia files are deliberately illustrative and cannot be used
for RC3 execution:

- `config/sepolia.phase1.json` has placeholder addresses,
  `illustrativeInputs: true`, and a `172800` second Timelock delay instead of
  the RC3 rehearsal's `600` seconds;
- `config/governance.sepolia.json` contains no ratified Safe, owner, signer or
  Timelock address;
- `config/sepolia.dex-policy.json` contains placeholder addresses and hashes;
- `config/sepolia.migration.json` contains placeholder token/vault addresses and
  a zero holder-manifest hash;
- no required Safe signer account variables or Safe owner sets are accepted by
  the current CLI.

Those inputs must not be patched ad hoc during a release run. They require a
new reviewed implementation/plan and a new exact-SHA evidence bundle.

## Required recovery scope

Before restarting RC3, a new reviewed commit needs release scripts and tests
for at least:

1. encrypted signer bootstrap/address-only manifest and balance checks;
2. twelve Safe proxy deployments plus full owner/threshold/module/guard/runtime
   verification;
3. infrastructure-only Timelock deployment with Governance proposer/executor,
   Security canceller, 600-second delay, self-admin and no deployer privilege;
4. Safe-native schedule/cancel/execute receipt import and verification;
5. explorer verification;
6. pause and Timelock-unpause lifecycle;
7. Sepolia PRE_MARKET actor/DEX/CREATE2 behavior fixtures;
8. V1 fixture, Migration Vault deployment and per-source-Safe funding;
9. post-open verification and full RC3 evidence export/seal.

After those changes, CI and retained evidence must be regenerated for the new
SHA before any on-chain action.

## Stop decision

Per RC3 section 6, the missing executable lifecycle steps require an immediate
stop before chain execution.

`BLOCKED_SCRIPT_COVERAGE`
