# Release Checklist

## Engineering Candidate

- [x] Product requirement and BLOCKED boundary documented
- [x] Solidity and dependency versions pinned
- [x] ABI and prohibited-function policy fixed
- [x] ERC-7201 schema version-controlled
- [x] Unit, E2E, invariant, governance and upgrade suites pass
- [x] Pinned mainnet fork and DEX code hashes pass
- [x] Core coverage gate passes
- [x] Slither passes
- [x] OpenZeppelin upgrade validation passes
- [x] Reproducible release artifacts match source
- [x] Deployment, opening, emergency and upgrade runbooks exist

## Deployment Authorization

- [ ] Independent external audit completed and findings resolved
- [ ] Mainnet Timelock address and role topology ratified
- [ ] Emergency Pauser Safe address, threshold and signers ratified
- [ ] Genesis Distribution Safe address, threshold and signers ratified
- [ ] Timelock and default-admin delays ratified
- [ ] DEX factories and infrastructure ratified against runtime code hashes
- [ ] Controlled archive RPC reproduces fork evidence
- [ ] Sepolia deployment and full lifecycle rehearsal archived
- [ ] Mainnet deployment transaction bundle independently simulated
- [ ] Dedicated deployer keystore or hardware wallet prepared and funded
- [ ] `make deploy-preflight` passes against the deployment RPC
- [ ] Explorer verification inputs reproduced
- [ ] Monitoring and incident ownership activated

Do not change repository status to `DEPLOY_AUTHORIZED` until every unchecked
item has named approvers and immutable evidence.
