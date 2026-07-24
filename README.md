# BINI Token V2

Hardened reference implementation of the permanently guarded BINI V2 token.

## Status

`MECHANICS_GREEN_RATIFICATIONS_REQUIRED`

This repository is review and audit material. It is not an authorized production
release and must not be deployed to Mainnet.

- Fixed genesis supply: 1,000,000,000 BINI.
- Permanent `BOOTSTRAP -> GUARDED` lifecycle; no `OPEN` mode.
- Address classes and approved operators define the on-chain transfer perimeter.
- Emergency freeze preserves balances and removes transfer eligibility.
- Security can pause immediately; unpause and sensitive actions execute through
  an OpenZeppelin `TimelockController`.
- Uniswap V2 and V3 paths have fork-test coverage. V4 is deferred from launch.

The current technical evidence reports 119 passing tests: 93 local and 26 mainnet
fork tests. Business ratifications, reproducible build controls, independent
review, and an external audit remain required before an ABI or release freeze.

## Repository Layout

- `src/BiniTokenV2Guarded.sol`: guarded-core reference.
- `test/`: unit, invariant, governance, upgrade, and mainnet-fork tests.
- `policy/`: allowed and prohibited selector policy.
- `config/governance-manifest.rehearsal.json`: candidate governance values only.
- `artifacts/release/`: generated ABI, method identifiers, and storage layout.
- `docs/evidence/`: executed engineering evidence and status history.
- `docs/runbooks/`: operational controls derived from the test evidence.

## Build And Test

Foundry 1.5.1 and Solidity 0.8.24 were used for the recorded rehearsal.

```sh
git submodule update --init --recursive
forge build
forge test --no-match-path "test/fork/*"
forge test --match-path "test/fork/*"
```

Fork tests currently use `https://ethereum-rpc.publicnode.com` and may need to be
rerun if the public endpoint is temporarily unavailable.

## Security Boundary

The token enforces a governed transfer perimeter. It does not prevent fake tokens,
OTC activity, CEX-internal markets, synthetic markets, or malicious behavior by an
already approved address. An approved operator is a global capability bounded by
ERC-20 allowance and the destination perimeter.

See
[`11_ECON2_3_MECHANICS_EVIDENCE_AND_VERDICT.md`](docs/evidence/11_ECON2_3_MECHANICS_EVIDENCE_AND_VERDICT.md)
for the current evidence-backed verdict.
