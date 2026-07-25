# Changelog

## Unreleased Engineering Final Candidate

- replaced the permanently guarded model with one-way
  `PRE_MARKET -> OPEN_MARKET`;
- kept ordinary user, Safe, custody, vesting and OTC transfers free from
  genesis;
- added registered V2/V3 pool recognition and explicit V4/DEX infrastructure
  blocking;
- bounded all external probes against reverting, short-return and return-bomb
  contracts;
- required contract-based Timelock, pauser and genesis custody endpoints;
- added full lifecycle E2E, stateful invariant, upgrade and pinned mainnet-fork
  coverage;
- added OpenZeppelin upgrade validation, Slither, coverage and reproducible
  release gates;
- added architecture, standards, threat model, internal review and operator
  runbooks.
