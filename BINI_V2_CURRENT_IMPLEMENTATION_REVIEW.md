# BINI V2 Current Implementation Review

## Product value

BINI V2 is an Ethereum-canonical ERC-20 settlement and incentive asset. From
genesis it can connect normal wallets, Safes, custody, vesting, rewards, internal
payments, OTC workflows, smart accounts, and applications through standard
ERC-20 transfers, allowances, and EIP-2612 permit. Integrations do not need a
BINI-specific user allowlist or extra onboarding transaction.

Its distinctive launch control is narrow: during PRE_MARKET, real BINI cannot
be transferred into pools recognized through approved V2/V3 factories or into
explicitly registered DEX infrastructure such as a V4 PoolManager, router,
position/liquidity manager, or gateway. A Timelock calls `openMarket()` once;
afterward those market restrictions are permanently bypassed.

This can integrate with any website, chat, bot, platform, custody service, or
backend that can submit or observe Ethereum ERC-20 transactions. The token does
not itself provide chat identity, cross-site accounts, fiat payments, bridge,
staking, vesting, rewards calculation, or API orchestration; those are separate
systems that can use BINI as their asset.

## Final feature set

- Binibit / BINI / 18 decimals; fixed one-time 1B supply.
- Standard transfers, allowances, `transferFrom`, and EIP-2612 permit.
- No runtime mint, burn, tax, confiscation, forced transfer, wallet limits,
  blacklist, KYC, or permanent participant allowlist.
- PRE_MARKET and irreversible OPEN_MARKET lifecycle.
- Registered-factory V2/V3 pool detection plus explicit infrastructure registry.
- Independent global pause, split pause/unpause authority.
- UUPS/ERC-1967 upgradeability controlled by Timelock with ERC-7201 storage.
- Separate Phase 2 Migration Vault with exact 12-to-18 decimal conversion.
- Phase-separated CLI, Safe packages, receipts, verification, and reconciliation.

## Boundary

Unknown/future AMMs and unregistered infrastructure cannot be universally
identified by an ERC-20. The implementation intentionally permits those
addresses to preserve ordinary user and contract-wallet transfers.

Current release verdict: `SCRIPTS_GREEN_SEPOLIA_REQUIRED`. The code package is
not deployed and is not mainnet-authorized.
