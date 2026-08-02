# BINI Token V2

Ethereum-canonical implementation of Binibit (`BINI`).

## Product Contract

`BINI` is freely transferable between users and system contracts from genesis.
During `PRE_MARKET`, only transfers into recognized DEX/AMM destinations are
blocked. A Timelock can call `openMarket()` once:

```text
PRE_MARKET  -- Timelock: openMarket() -->  OPEN_MARKET
```

After opening, all market checks are permanently bypassed. The token remains
subject only to the independent emergency pause and the explicitly required
Timelock-controlled UUPS upgrade authority.

There is no participant allowlist, KYC, tax, max-wallet rule, runtime mint,
burn, confiscation, forced transfer or post-opening blacklist.

## Fixed Properties

| Property | Value |
| --- | --- |
| Name / symbol / decimals | `Binibit` / `BINI` / `18` |
| Supply | `1,000,000,000 BINI`, minted once |
| Canonical chain | Ethereum |
| Upgrade model | ERC-1967 UUPS, Timelock-authorized |
| Emergency pause | Security Safe pauses, Timelock unpauses |
| Storage | ERC-7201 namespace |

## Security Boundary

Registered V2/V3 factories confirm deployed pools. V4 `PoolManager`, routers,
liquidity managers and gateways are explicit infrastructure entries. Unknown
AMMs and undeployed CREATE2 destinations cannot be universally identified by an
ERC-20 without restricting ordinary transfers. The absolute universal claim is
therefore `BLOCKED`; the implemented minimal compromise is documented in
[PRE_MARKET_DEX_POLICY.md](docs/architecture/PRE_MARKET_DEX_POLICY.md).

## Status

`ENGINEERING_FINAL_CANDIDATE_NOT_DEPLOY_AUTHORIZED`

The implementation, internal review, release gates and test evidence are
complete. Mainnet deployment still requires ratified governance addresses,
Sepolia rehearsal evidence and an independent external audit.

## Verify

Prerequisites: Foundry `1.5.1`, Solidity `0.8.24`, Node.js `22`, `jq`, and
Slither `0.11.4`.

```sh
git submodule update --init --recursive
npm ci --ignore-scripts
make release-check
```

## Release CLI

The root CLI covers deployment, fixed-supply distribution, controlled V1
migration, verification and status. Every command defaults to non-transacting
`PLAN` mode:

```sh
./bin/bini-v2 preflight --network sepolia
./bin/bini-v2 deploy --network sepolia --config config/sepolia.json
./bin/bini-v2 distribute --network sepolia --ledger data/bini-v2-supply-ledger.json
./bin/bini-v2 migration-plan --network sepolia --holders data/v1-v2-known-holders.csv
./bin/bini-v2 migrate --network sepolia --holders data/v1-v2-known-holders.csv --batch batch-01
./bin/bini-v2 verify --network sepolia
./bin/bini-v2 status --network sepolia
```

Committed network and holder data are illustrative and intentionally fail all
executing preflights until ratified values replace them. See the deployment,
distribution and migration runbooks before changing that gate.

Useful narrower commands:

```sh
make test-local
make test-fork
make coverage
make audit
make artifacts
```

The fork suite is pinned to Ethereum block `25,603,294` and verifies the code
hashes in the rehearsal governance manifest. Set `MAINNET_RPC_URL` to a
controlled archive endpoint. Public archive endpoints are retry fallbacks, not
deployment evidence.

## Project Map

- `src/`: canonical token implementation
- `bin/bini-v2`: stable release operator entrypoint
- `data/`: versioned supply, vesting and migration inputs
- `test/`: unit, E2E, invariant, governance, upgrade and pinned fork suites
- `script/`: environment-driven ERC-1967/UUPS deployment
- `config/`: governance rehearsal manifest and ERC-7201 schema
- `policy/`: allowed and prohibited public function policy
- `artifacts/release/`: reproducibly generated ABI, selectors and build hashes
- `tools/`: release, coverage and artifact consistency gates
- `.env.example`: non-secret Sepolia/mainnet deployment configuration template
- `docs/`: requirements, architecture, security evidence and operator runbooks

Start with [docs/INDEX.md](docs/INDEX.md). Security reports follow
[SECURITY.md](SECURITY.md).
