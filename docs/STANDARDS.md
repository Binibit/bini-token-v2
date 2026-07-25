# Standards Matrix

| Standard | Implementation | Evidence |
| --- | --- | --- |
| ERC-20 / EIP-20 | Standard transfer, allowance, metadata and events through OpenZeppelin | Unit and E2E suites |
| ERC-2612 | `permit`, nonces and EIP-712 domain through OpenZeppelin | Valid, expired and replay tests |
| EIP-712 | Domain separator and typed permit signatures | Permit tests |
| ERC-165 | AccessControl interface reporting | Generated ABI |
| ERC-1967 | Canonical implementation slot and proxy | Upgrade and E2E tests |
| ERC-1822 / UUPS | `proxiableUUID`, proxy-only upgrades and compatibility checks | Upgrade rejection matrix |
| ERC-7201 | Namespaced BINI lifecycle and registry storage | Schema artifact and slot test |
| OpenZeppelin AccessControl | Role-based authority | Unit and Timelock tests |
| AccessControlDefaultAdminRules | Delayed two-step default-admin transfer | Initialization and role tests |
| Pausable | Independent transfer circuit breaker | Pause precedence and E2E tests |

## Version Baseline

- Solidity `0.8.24`
- EVM target `cancun`
- optimizer enabled, `200` runs
- bytecode metadata hash disabled
- Foundry `1.5.1`
- OpenZeppelin Contracts and Contracts Upgradeable `5.6.1`
- OpenZeppelin Upgrades Core `1.46.0`
- Slither `0.11.4`

Versions and dependency commits are locked by `foundry.toml`, git submodules and
`package-lock.json`.

## Normative References

- [ERC-20](https://eips.ethereum.org/EIPS/eip-20)
- [ERC-2612](https://eips.ethereum.org/EIPS/eip-2612)
- [ERC-1967](https://eips.ethereum.org/EIPS/eip-1967)
- [ERC-1822](https://eips.ethereum.org/EIPS/eip-1822)
- [ERC-7201](https://eips.ethereum.org/EIPS/eip-7201)
- [OpenZeppelin proxy API](https://docs.openzeppelin.com/contracts/5.x/api/proxy)
- [OpenZeppelin access-control API](https://docs.openzeppelin.com/contracts/5.x/api/access)

## Deliberate Extensions

The PRE_MARKET destination check extends ordinary ERC-20 transfer behavior only
until `openMarket()`. The emergency pause is separate and can remain available
after opening. There is no ERC-20 function that mints or burns supply at
runtime.
