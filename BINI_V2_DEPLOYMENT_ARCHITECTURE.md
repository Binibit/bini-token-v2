# BINI V2 Deployment Architecture

## Components

| Component | Responsibility | Authority |
| --- | --- | --- |
| `BiniTokenV2` proxy | Fixed ERC-20 supply and PRE/OPEN market lifecycle | Timelock; Pauser Safe only pauses |
| Frozen implementation | UUPS logic with disabled initializer | No direct state |
| `TimelockController` | Upgrade, market registry, unpause and later `openMarket()` | Proposer/Executor Safes |
| `BiniMigrationVault` | Immutable V1 lock and exact V2 release | Timelock config before seal |
| Genesis Safe | Receives the one initial mint | Safe threshold |
| Dedicated Safes | Treasury/liquidity/rewards/strategic custody | Separate Safe thresholds |
| Approved vesting contracts | Time-based beneficiary release | Existing audited scope only |

Deployment is atomic at the proxy initializer boundary. The deployer creates
contracts but retains no production role. `openMarket()` is deliberately absent
from every release script.

## Lifecycle

`PRE_MARKET` permits ordinary wallet, Safe, custody, vesting, rewards, OTC and
migration transfers. It blocks registered V2/V3 pools and explicit V4/DEX
infrastructure. Unknown future AMMs cannot be universally detected by an ERC-20;
the documented registry compromise avoids a permanent holder allowlist. After
the one-way Timelock action, DEX checks are permanently bypassed.

## Evidence

The CLI pins chain/commit/tooling, checks Safe code and thresholds, produces
deterministic action IDs, refuses artifact overwrite and derives deployment
addresses/hashes from confirmed receipts. Mainnet broadcast has an additional
three-variable guard and still requires separate written authorization.
