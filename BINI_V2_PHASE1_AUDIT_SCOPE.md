# BINI V2 Phase 1 Audit Scope

## Included

- `src/BiniTokenV2.sol` and its UUPS/AccessControl/OpenZeppelin inheritance.
- `script/DeployBiniV2.s.sol` and Phase 1 CLI deployment, distribution and verification paths.
- Fixed supply, initializer, roles, pause and `PRE_MARKET` lifecycle.
- V2/V3 factory recognition and explicit DEX infrastructure registry.
- Timelock schedule and execution topology.
- Exact nine-Safe Phase 1 ledger and receipt schemas.
- ABI, selectors, ERC-7201 storage, bytecode and upgrade validation.

## Excluded

- Real Sepolia addresses and receipts until the rehearsal is executed.
- Phase 2 Migration Vault deployment, funding and holder execution.
- Phase 3 policy registration, liquidity, `openMarket()`, bridge and staking.
- Universal detection of unknown, future, custom or pre-funded CREATE2 AMMs.
- Safe implementation internals and signer operational security.

## Trust assumptions

Timelock and its Safe proposers/executors can upgrade the token and modify the
supported DEX registry after the configured delay. The emergency Security Safe
can pause transfers immediately but cannot unpause, upgrade or open the market.

```text
UNIVERSAL_AMM_BLOCKING = BLOCKED
SUPPORTED_AND_REGISTERED_DEX_BLOCKING = PARTIAL
```
