# Safe Automation

`DeploySafeTopology.s.sol` uses the official Safe smart-account repository at
tag `v1.4.1` (`bf943f80fec5ac647159d26161446ac5d716a294`). It deploys exactly the
twelve canonical purpose-specific proxies with three distinct owners and a
2-of-3 threshold.

`safes verify` checks owners, threshold, `VERSION()`, singleton slot, runtime
code hashes, empty modules, zero guard, zero fallback handler, factory,
MultiSend, uniqueness and creation transactions.

The `safe-tx` layer binds signatures to exact chain, Safe, nonce, normalized
calldata and on-chain `getTransactionHash`. Signatures must be distinct owners,
strictly address-sorted and meet threshold. Inner delegatecall is rejected.
Outer delegatecall is accepted only for an explicitly declared, runtime-hash
pinned canonical MultiSend. Execution requires `ExecutionSuccess` and writes an
immutable receipt that is independently reconciled to the chain receipt.

Private keys and mnemonics never enter public manifests or command output.
RC3A tests use only temporary encrypted keystores outside the repository.
