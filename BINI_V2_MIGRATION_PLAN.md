# BINI V2 Migration Plan

Known holders are versioned in `data/v1-v2-known-holders.csv`. Every row binds a
V1 address, V2 recipient, exact raw amounts, ownership evidence, method and
small batch. The committed rows are examples and must be replaced by the
approved holder manifest.

The vault enforces:

- V1 decimals `12`, V2 decimals `18`, raw scale exactly `1,000,000`;
- Timelock-configured unique entitlement and deterministic action ID;
- full V2 reserve before irreversible entitlement sealing;
- V1 `transferFrom` before V2 transfer in one atomic transaction;
- exact balance deltas, preventing fee-on-transfer underpayment;
- EIP-712/EIP-1271 authorization for a replacement recipient;
- one migration per holder and no V1 rescue function.

Initial batches are limited to 20 and should be reduced if Sepolia/fork gas
simulation indicates operational risk. Each holder remains a separate call,
allowing receipt-level resume without reverting successful holders.
