# Market Open Runbook

This runbook is a release template. Every address and code hash must be ratified
for Ethereum mainnet before execution.

## 1. Deploy

Deploy the implementation and atomically initialize the UUPS proxy using
`./bin/bini-v2 deploy` and `script/DeployBiniV2.s.sol`.

Required values:

- `BINI_V2_EXPECTED_CHAIN_ID`;
- `BINI_V2_TIMELOCK_MIN_DELAY`;
- `BINI_V2_TIMELOCK_PROPOSER`;
- `BINI_V2_TIMELOCK_EXECUTOR`;
- `BINI_V2_EMERGENCY_PAUSER_SAFE`;
- `BINI_V2_GENESIS_DISTRIBUTION_SAFE`;
- `BINI_V2_ADMIN_TRANSFER_DELAY`.

Verify metadata, fixed supply, proxy implementation, ERC-7201 storage slot and
all roles immediately after deployment.

## 2. Configure PRE_MARKET

Through scheduled Timelock operations:

1. register the ratified V2 factories as `UNISWAP_V2`;
2. register the ratified V3 factories as `UNISWAP_V3`;
3. add V4 PoolManager, liquidity managers, routers and gateways that can receive
   BINI as market infrastructure;
4. record chain id, address, runtime code hash, proxy implementation and
   governance transaction for each entry.

Ethereum candidates used by the fork tests:

| Component | Candidate address |
| --- | --- |
| Uniswap V2 Factory | `0x5C69...aA6f`, code hash `0xbab145...b4e0` |
| Uniswap V3 Factory | `0x1F984...F984`, code hash `0x4d7b85...fd69` |
| Uniswap V4 PoolManager | `0x000000...8A90`, code hash `0x785f10...1293` |

The full addresses and hashes are recorded in
`config/governance-manifest.rehearsal.json` at pinned block `25,603,294`.
Candidate addresses are not automatically production-ratified.

Generate the reviewed schedule/execute payloads with:

```sh
EXECUTION_MODE=SAFE_PROPOSAL ./bin/bini-v2 configure-market --network <network> \
  --policy config/<network>.dex-policy.json
```

## 3. PRE_MARKET Verification

Confirm on-chain:

- wallet -> wallet succeeds;
- wallet -> Safe succeeds;
- wallet -> custody and vesting succeeds;
- standard allowance + `transferFrom` succeeds;
- transfer and `transferFrom` into every registered infrastructure address
  revert with `DexMarketClosed`;
- a new V2 pair from every registered V2 factory is recognized and blocked;
- a new V3 pool from every registered V3 factory is recognized and blocked;
- total supply remains `1,000,000,000 ether`;
- token is not paused unless an incident is active.

## 4. Schedule OPEN_MARKET

Generate the deterministic Timelock schedule and execute proposals:

```sh
EXECUTION_MODE=SAFE_PROPOSAL ./bin/bini-v2 open-market --network <network> \
  --policy config/<network>.dex-policy.json
```

The package contains exactly:

```solidity
BiniTokenV2.openMarket()
```

Publish the calldata, target proxy, salt, predecessor and Timelock ETA. Require
independent sign-off that:

- launch time and communications are approved;
- DEX and liquidity operations are ready;
- no active security incident exists;
- proxy implementation and configuration match the reviewed release.

## 5. Execute And Verify

After the Timelock delay:

1. execute `openMarket()`;
2. verify `marketState() == OPEN_MARKET`;
3. verify `marketOpen() == true`;
4. verify transfers into former DEX destinations succeed;
5. verify a second `openMarket()` reverts `MarketAlreadyOpen`;
6. archive transaction hashes and emitted `MarketOpened` event.

There is no rollback to `PRE_MARKET`. Emergency response uses the separate global
pause, followed by a Timelock-controlled unpause.
