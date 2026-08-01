# Deployment Runbook

## Inputs

The deployment script requires:

- `EXPECTED_CHAIN_ID`
- `ADMIN_TIMELOCK`
- `EMERGENCY_PAUSER_SAFE`
- `GENESIS_DISTRIBUTION_SAFE`
- `ADMIN_TRANSFER_DELAY`
- an RPC URL and broadcaster key supplied through the normal Foundry flow

All three addresses must contain deployed code before execution.

## Credential Model

The deployment signer and token administration are different things:

- the deployer account signs the implementation and proxy deployment
  transactions;
- `ADMIN_TIMELOCK` is the address of an already deployed `TimelockController`,
  not the deployer's EOA;
- `EMERGENCY_PAUSER_SAFE` and `GENESIS_DISTRIBUTION_SAFE` are already deployed
  contract wallets;
- a Safe owner mnemonic or private key is never passed to the token
  initializer.

Never place a mnemonic or raw private key in `.env`, shell history, a command
argument, source control, CI variables or chat. Prefer a hardware wallet for
mainnet. For a dedicated Sepolia/deployer key, import it into Foundry's encrypted
keystore through the hidden prompt:

```sh
cast wallet import bini-deployer --interactive
cast wallet address --account bini-deployer
cast wallet list
```

The first command asks for the raw private key and then a new keystore password
without writing the key into command history. If the only available credential
is a seed phrase, do not convert or paste it on an online machine; use the
hardware wallet that holds it or create a separate, limited deployer account.

Create the non-secret environment file:

```sh
cp .env.example .env
chmod 600 .env
${EDITOR:-nano} .env
set -a
source .env
set +a
```

`.env` contains RPC, contract addresses, delay, account name and deployer
address. It must not contain the keystore password, mnemonic or private key.

## Preflight

1. Check out the reviewed release commit and initialize submodules.
2. Run `npm ci --ignore-scripts` and `make release-check`.
3. Match every address and delay to the ratified governance manifest.
4. Confirm chain id, deployer balance, nonce and expected proxy address.
5. Load `.env` and run `make deploy-preflight`.
6. Simulate the exact command without broadcast and archive the trace.

## Deploy

Example for a simulation:

```sh
forge script script/DeployBiniTokenV2.s.sol:DeployBiniTokenV2 \
  --rpc-url "$DEPLOY_RPC_URL" \
  --account "$DEPLOYER_ACCOUNT" \
  --sender "$DEPLOYER_ADDRESS" \
  -vvvv
```

The simulation does not publish transactions. After its trace, addresses and
gas estimate have been independently reviewed, the separately approved
broadcast command is:

```sh
forge script script/DeployBiniTokenV2.s.sol:DeployBiniTokenV2 \
  --rpc-url "$DEPLOY_RPC_URL" \
  --account "$DEPLOYER_ACCOUNT" \
  --sender "$DEPLOYER_ADDRESS" \
  --broadcast \
  --verify \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  -vvvv
```

For a hardware wallet, replace `--account "$DEPLOYER_ACCOUNT"` with `--ledger`
or `--trezor`. Never add `--private-key` or `--mnemonic` to a production command.

## Immediate Verification

- proxy implementation slot equals the deployed implementation;
- implementation initializers are disabled;
- `name`, `symbol`, `decimals`, cap and total supply match the fixed properties;
- the genesis Safe owns the entire initial supply;
- Timelock and pauser roles match the manifest;
- `marketState() == PRE_MARKET`;
- token is not paused;
- implementation and proxy source are explorer-verified;
- bytecode hashes match `artifacts/release/BINI_V2_BUILD.json`.

No DEX configuration or distribution should begin until this verification is
signed off.
