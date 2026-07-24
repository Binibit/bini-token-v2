# BINI V2 Core Product Requirement

## Канон

**BINI V2 свободно переводится между пользователями и системными контрактами с
первого дня. До необратимого `openMarket()` блокируется только перемещение
настоящего BINI в распознанную DEX/AMM-инфраструктуру. После `openMarket()` токен
становится полностью permissionless ERC-20.**

## Жизненный цикл

```text
PRE_MARKET
    |
    | one-way governance action: openMarket()
    v
OPEN_MARKET
```

### PRE_MARKET

Без дополнительных пользовательских действий разрешены:

- wallet -> wallet;
- wallet -> Safe или smart account;
- wallet -> custody;
- wallet -> vesting, migration, rewards, staking и другие системные контракты;
- system contract -> wallet;
- OTC transfers;
- стандартные `approve`, `transfer` и `transferFrom`.

Блокируются переводы BINI в:

- pools V2/V3, подтверждённые зарегистрированной factory;
- Uniswap V4 `PoolManager`;
- зарегистрированные routers, liquidity managers и market gateways.

### OPEN_MARKET

`openMarket()` вызывается только Timelock и только один раз. После этого:

- все DEX-проверки навсегда перестают влиять на transfers;
- разрешены V2/V3/V4, агрегаторы и сторонние pools;
- нельзя вернуть `PRE_MARKET`;
- отдельный emergency global pause продолжает работать.

## Fixed Token Properties

- Ethereum canonical token;
- `name = Binibit`;
- `symbol = BINI`;
- `decimals = 18`;
- fixed supply `1,000,000,000 BINI`;
- один initial mint;
- no runtime mint;
- no burn в launch version;
- no tax;
- no confiscation или forced transfer;
- UUPS upgrade, разрешённый только Timelock;
- migration, bridge, vesting, staking и liquidity custody являются отдельными
  системами.

## Запрещённые модели

В launch-версии нет:

- participant allowlist;
- KYC внутри ERC-20;
- постоянного approved perimeter;
- пользовательского onboarding transaction;
- max-wallet или max-transaction;
- permanent blacklist;
- `BOOTSTRAP -> PERMANENTLY_GUARDED`.
