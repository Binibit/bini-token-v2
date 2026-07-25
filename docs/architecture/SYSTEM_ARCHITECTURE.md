# System Architecture

## Scope

The token owns balances, standard ERC-20 approvals and permit, the one-way
market state, emergency pause and DEX destination policy. Vesting, migration,
bridge, staking, custody, rewards and liquidity custody are separate systems.

```mermaid
flowchart LR
  Users["Users, Safes and system contracts"] --> Token["BiniTokenV2 proxy"]
  Token --> Balances["ERC-20 balances and permit"]
  Timelock["Governance Timelock"] --> Token
  Pauser["Emergency Pauser Safe"] --> Token
  Token -. "PRE_MARKET destination probes" .-> V2V3["Registered V2/V3 factories"]
  Token -. "explicit block" .-> Infra["V4 PoolManager and DEX infrastructure"]
  Token --> Impl["UUPS implementation"]
```

## Lifecycle

```mermaid
stateDiagram-v2
  [*] --> PRE_MARKET: initialize and one-time mint
  PRE_MARKET --> OPEN_MARKET: Timelock openMarket()
  OPEN_MARKET --> OPEN_MARKET: no reverse transition
```

Pause is orthogonal to the market lifecycle. `pause()` stops transfers in both
states. `unpause()` does not change market state.

## Transfer Decision

```mermaid
flowchart TD
  A["ERC-20 _update(from, to, value)"] --> P{"Paused?"}
  P -- Yes --> R1["Revert"]
  P -- No --> M{"Mint/burn path or OPEN_MARKET?"}
  M -- Yes --> U["Standard OpenZeppelin update"]
  M -- No --> I{"Explicit infrastructure?"}
  I -- Yes --> R2["Revert DexMarketClosed"]
  I -- No --> D{"Factory-confirmed V2/V3 pool?"}
  D -- Yes --> R2
  D -- No --> U
```

Pool probes are capped at `30,000` gas each and copy only one 32-byte word.
Malformed, reverting, short-return and return-bomb contracts are treated as
unrecognized ordinary recipients unless explicitly registered.

## Authority

| Capability | Required holder |
| --- | --- |
| Default admin | Governance Timelock |
| Upgrade | Governance Timelock |
| Configure DEX policy | Governance Timelock, PRE_MARKET only |
| Open market | Governance Timelock, one-way |
| Pause | Emergency Pauser Safe |
| Unpause | Governance Timelock |
| Initial supply custody | Genesis Distribution Safe |

All three initializer addresses must already contain contract code. The default
admin additionally uses OpenZeppelin's delayed two-step transfer rules.

## Upgrade Boundary

The proxy follows ERC-1967 and the implementation follows UUPS/ERC-1822. BINI's
own state uses the ERC-7201 namespace `binibit.storage.BiniTokenV2`. UUPS is a
governance master capability: a future implementation can alter lifecycle
semantics, so upgrade review is part of the security boundary.
