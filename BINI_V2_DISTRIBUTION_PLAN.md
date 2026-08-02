# BINI V2 Distribution Plan

The fixed one-billion supply starts in the Genesis Distribution Safe. All
amounts come from `data/bini-v2-supply-ledger.json`; no script contains a second
allocation table.

| Bucket | Required destination/control |
| --- | --- |
| Migration Reserve | Deployed `BiniMigrationVault` |
| Treasury | Treasury Safe |
| Team | Approved funded vesting contracts unless explicitly liquid |
| Partners/Investors | Approved funded vesting contracts unless explicitly liquid |
| Rewards/Ecosystem | Rewards Safe or audited distributor |
| Liquidity/Market Making | Liquidity Safe; PRE_MARKET still blocks real AMM funding |
| Strategic/CEX | Strategic Reserve Safe |
| Other | Explicitly approved named destination |

The committed addresses and allocations are illustrative placeholders, not an
authorization. Before Sepolia they must be replaced with ratified inputs while
preserving exact integer totals. Execution is a Safe threshold operation from a
generated Transaction Builder package; the CLI never handles Safe signer keys.
