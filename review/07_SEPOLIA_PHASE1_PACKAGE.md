# Sepolia Phase 1 Package

## Code package

Phase 1 now requires only token/governance deployment, Genesis mint, exact
nine-Safe distribution, and reconciliation. `config/sepolia.phase1.json` has no
V1, vesting, migration, DEX, or market-opening fields. The ledger is hard-bound
to the approved 1B allocation.

## Inputs still required

- Owner-approved Timelock delay, proposer Safe, and executor Safe.
- Owner-approved emergency pauser and Genesis Safes.
- Owner-approved nine distinct top-level Safe contracts and thresholds.
- Funded `bini-deployer` encrypted-keystore account and approved address.
- Controlled Sepolia RPC; explorer API key only if source verification is used.
- Exact clean release commit and matching token creation-bytecode hash.
- `illustrativeInputs: false` in approved config and ledger.
- Explicit external audit status and owner authorization.

V1 holder records, vesting addresses, migration vault, DEX factories, pools,
routers, PoolManager, and `openMarket()` are not Phase 1 prerequisites.

## Stop conditions

Do not broadcast when Git is dirty, commit/hash/chain differs, a configured Safe
has no code or wrong threshold, an address is an EOA, Genesis/destinations
overlap, the ledger differs, or external authorization is absent. Do not proceed
from a partial distribution state.

## Verdict

`PHASE1_CODE_GREEN_INPUTS_REQUIRED`

No Sepolia or mainnet transaction was sent during this review.
