# BINI V2 direct holder distribution canon

## Binding model

One explicitly owner-approved existing Phase 1 allocation Safe sends BINI V2 directly to final holders. Every distribution is economically deducted from that allocation. The source is never auto-selected.

The immutable JSON manifest follows `config/direct-holder-distribution.schema.json`. Its `manifestHash` is SHA-256 of sorted, compact canonical JSON with the `manifestHash` field removed. The example uses disposable Sepolia recipients and is marked non-executable; it is not a production holder list.

Default destination equals the legacy V1 address. An override is accepted only before freeze with a verifiable signed instruction whose hash is stored in `addressOverrideProofHash`. Duplicate legacy or destination addresses must be explicitly reviewed and pre-aggregated into unique final records; the CLI rejects duplicates.

## Batch and Safe rules

Maximum batch size is 20. About 50 holders therefore form 20/20/10. Each inner call must be exactly `BINI.transfer(destinationAddress, v2RawAmount)`, value zero, operation CALL. Multi-call batches use only the pinned canonical Safe MultiSend delegatecall wrapper. Approvals, arbitrary calls, roles, upgrades, DEX actions, lifecycle calls, and Migration Vault dependencies are forbidden.

Commands:

```sh
./bin/bini-v2 holder-distribution validate --manifest data/bini-v2-direct-holder-distribution.json
./bin/bini-v2 holder-distribution plan --network sepolia --manifest data/bini-v2-direct-holder-distribution.json --mode PLAN
./bin/bini-v2 holder-distribution simulate --network sepolia --manifest data/bini-v2-direct-holder-distribution.json
./bin/bini-v2 holder-distribution safe-proposals --network sepolia --manifest data/bini-v2-direct-holder-distribution.json
./bin/bini-v2 holder-distribution verify --network sepolia --manifest data/bini-v2-direct-holder-distribution.json --receipts artifacts/sepolia/holder-distribution/<manifest>/receipts
```

There is deliberately no bulk broadcast command. Each package is inspected, signed, executed, and reconciled separately. Mainnet execution remains disabled pending Sepolia closeout, V1 deprecation, final manifest approval, external audit, and explicit owner authorization.

## Preflight and reconciliation

Before every batch bind network/chain, protected commit and clean tree, token proxy, source allocation/Safe, Safe nonce, source balance, manifest hash, record range, cumulative amount, decoded calls, pinned MultiSend, and absence of earlier execution. Stop on drift.

Receipts bind manifest hash, batch/range, Safe/nonce/SafeTxHash/signers, execution transaction/block/gas, exact Transfer events, batch amount, source before/after, and recipient before/after. Final reconciliation proves count/total, one execution per record, no extra recipient, exact source delta, unchanged supply, market state, roles, and implementation. The allocation identity is:

`original allocation = current source balance + direct holder distributions + all other receipted source outflows`.
