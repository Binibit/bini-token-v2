# CLI and Execution Safety

## Commands and boundaries

| Phase | Commands |
| --- | --- |
| Phase 1 | `preflight`, `deploy`, `distribute`, `verify`, `status` |
| Phase 2 | `migration-plan`, `migrate`, `verify-migration` with separate migration config |
| Phase 3 | `configure-market`, `open-market` with separate DEX policy |

All commands default to `PLAN`. Deployment broadcast requires an encrypted
Foundry keystore account; the CLI never accepts a raw private key. Mainnet also
requires `EXECUTION_MODE=BROADCAST`, `CONFIRM_MAINNET=yes`, and chain ID 1.
Safe-controlled token and Timelock actions reject direct broadcast.

Preflight checks clean Git state, exact expected commit, chain ID, bytecode hash,
deployer balance/address, contract code, Safe thresholds, and illustrative-input
gates. RPC/Foundry failures propagate; there are no silent retries. Deployment
manifests are reconstructed from confirmed receipts and verify code, roles,
ERC-1967 slot, runtime hash, initializer lock, supply, and PRE_MARKET state.

Distribution, migration, and Timelock packages are create-only. Existing files
must match identity/hash fields; overwrite is refused. On-chain balance/action
state provides idempotency and partial-state detection.

## Secret handling

Use:

```sh
cast wallet import bini-deployer --interactive
export DEPLOYER_ACCOUNT=bini-deployer
export DEPLOYER_ADDRESS="$(cast wallet address --account bini-deployer)"
```

The hidden prompt imports the key into an encrypted keystore. Never put a raw
key, mnemonic, password, or Safe signer key in `.env`, command history, source,
CI, chat, or manifests. `.env.example` contains public endpoints/account labels
only and `.env` is ignored.

## Result

Execution safety mechanics are green for scripted rehearsal. No command grants
deployment authorization; owner approval and ratified inputs remain external.
