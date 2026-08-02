# BINI V2 Phase 3 Market Opening Backlog

Phase 3 is a separately authorized irreversible market launch.

- Ratify supported V2/V3 factories and every explicit router, liquidity/position
  manager, gateway, and V4 PoolManager.
- Verify chain, implementation/proxy, runtime bytecode hash, ownership, upgrade
  authority, and operational purpose for every registry address.
- Set `illustrativeInputs: false` in `config/sepolia.dex-policy.json` only after
  review; generate and execute Timelock policy packages.
- Rehearse that registered V2/V3 pools and V4/infrastructure reject BINI during
  PRE_MARKET while wallets, Safes, custody, vesting, and OTC transfers work.
- Define official quote assets, fee tiers, initial prices, liquidity amounts,
  slippage limits, LP custody, transaction ordering, and monitoring.
- Confirm the 50M allocation is a maximum reserve, not mandatory immediate LP
  funding; approve each actual liquidity transfer separately.
- Obtain external audit and formal owner/governance authorization.
- Generate `open-market` Timelock schedule/execute packages, wait the complete
  delay, re-simulate immediately before execution, then execute once.
- Verify market state is irreversible, a second call reverts, DEX transfers work,
  supply/balances/allowances are unchanged, and emergency pause remains usable.
- Treat unknown/future AMMs as outside the guaranteed PRE_MARKET boundary.

Bridge, staking, and downstream systems remain later independent projects.
