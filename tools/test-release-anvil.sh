#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PORT="${ANVIL_RELEASE_PORT:-18547}"
RPC_URL="http://127.0.0.1:${PORT}"
NETWORK="anvil-release"
TMP_DIR="$(mktemp -d)"
ANVIL_LOG="$TMP_DIR/anvil.log"
CONFIG="$TMP_DIR/config.json"
LEDGER="$TMP_DIR/ledger.json"
HOLDERS="$TMP_DIR/holders.csv"
VESTING="$ROOT/data/vesting-grants.json"

cleanup() {
    if [[ -n "${ANVIL_PID:-}" ]]; then
        kill "$ANVIL_PID" 2>/dev/null || true
        wait "$ANVIL_PID" 2>/dev/null || true
    fi
    rm -rf \
        "$ROOT/artifacts/deployments/$NETWORK" \
        "$ROOT/artifacts/distributions/$NETWORK" \
        "$ROOT/artifacts/migrations/$NETWORK" \
        "$ROOT/artifacts/verification/$NETWORK" \
        "$ROOT/broadcast/DeployBiniV2.s.sol/31337" \
        "$TMP_DIR"
}
trap cleanup EXIT

fail() {
    printf 'Anvil release rehearsal failed: %s\n' "$1" >&2
    if [[ -f "$ANVIL_LOG" ]]; then
        tail -80 "$ANVIL_LOG" >&2
    fi
    exit 1
}

rpc() {
    cast rpc --rpc-url "$RPC_URL" "$@" >/dev/null
}

send_raw() {
    local from="$1"
    local to="$2"
    local data="$3"
    cast send --rpc-url "$RPC_URL" --unlocked --from "$from" "$to" "$data" >/dev/null
}

call_scalar() {
    local target="$1"
    local signature="$2"
    shift 2
    cast call --json --rpc-url "$RPC_URL" "$target" "$signature" "$@" | jq -er '.[0] | tostring'
}

expect_send_revert() {
    local from="$1"
    local to="$2"
    local data="$3"
    if cast send --rpc-url "$RPC_URL" --unlocked --from "$from" "$to" "$data" >/dev/null 2>&1; then
        fail "expected transaction to $to to revert"
    fi
}

deploy_contract() {
    local output
    output="$(forge create --rpc-url "$RPC_URL" --unlocked --from "$DEPLOYER" --broadcast --json "$@")"
    jq -er '.deployedTo' <<<"$output"
}

execute_timelock_package() {
    local artifact="$1"
    local proposer="$2"
    local executor="$3"
    local to data
    to="$(jq -er '.timelockPackage.scheduleProposal.transactions[0].to' "$artifact")"
    data="$(jq -er '.timelockPackage.scheduleProposal.transactions[0].data' "$artifact")"
    send_raw "$proposer" "$to" "$data"
    rpc evm_increaseTime 3
    rpc evm_mine
    to="$(jq -er '.timelockPackage.executeProposal.transactions[0].to' "$artifact")"
    data="$(jq -er '.timelockPackage.executeProposal.transactions[0].data' "$artifact")"
    send_raw "$executor" "$to" "$data"
}

command -v anvil >/dev/null || fail "anvil is not installed"
command -v forge >/dev/null || fail "forge is not installed"
command -v cast >/dev/null || fail "cast is not installed"
command -v jq >/dev/null || fail "jq is not installed"

[[ -z "$(git status --porcelain)" ]] || fail "Git working tree must be clean"

anvil --port "$PORT" --chain-id 31337 --auto-impersonate --silent >"$ANVIL_LOG" 2>&1 &
ANVIL_PID=$!
for _ in $(seq 1 50); do
    if cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done
[[ "$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null)" == "31337" ]] || fail "Anvil did not start"

forge build >/dev/null 2>&1
DEPLOYER="$(cast rpc --rpc-url "$RPC_URL" eth_accounts | jq -er '.[0]')"
HEAD_COMMIT="$(git rev-parse HEAD)"

PROPOSER="0x0000000000000000000000000000000000001001"
EXECUTOR="0x0000000000000000000000000000000000001002"
PAUSER="0x0000000000000000000000000000000000001003"
GENESIS="0x0000000000000000000000000000000000001004"
TREASURY="0x0000000000000000000000000000000000001005"
LIQUIDITY="0x0000000000000000000000000000000000001006"
REWARDS="0x0000000000000000000000000000000000001007"
STRATEGIC="0x0000000000000000000000000000000000001008"
VESTING_TEAM="0x0000000000000000000000000000000000003101"
VESTING_PARTNER="0x0000000000000000000000000000000000003102"
V4_MANAGER="0x0000000000000000000000000000000000006003"

SAFE_RUNTIME="$(forge inspect ReleaseSafeMock deployedBytecode)"
CODE_RUNTIME="$(forge inspect ReleaseCodeMock deployedBytecode)"
for safe in "$PROPOSER" "$EXECUTOR" "$PAUSER" "$GENESIS" "$TREASURY" "$LIQUIDITY" "$REWARDS" "$STRATEGIC"; do
    rpc anvil_setCode "$safe" "$SAFE_RUNTIME"
    rpc anvil_setBalance "$safe" 0x56BC75E2D63100000
done
for contract_address in "$VESTING_TEAM" "$VESTING_PARTNER" "$V4_MANAGER"; do
    rpc anvil_setCode "$contract_address" "$CODE_RUNTIME"
done

V1_TOKEN="$(deploy_contract test/mocks/MockTokens.sol:MockToken --constructor-args 'BINI V1' BINI1 12)"
V2_FACTORY="$(deploy_contract test/mocks/MarketMocks.sol:MockV2Factory)"
V3_FACTORY="$(deploy_contract test/mocks/MarketMocks.sol:MockV3Factory)"
OTHER_TOKEN="$(deploy_contract test/mocks/MockTokens.sol:MockToken --constructor-args 'Other' OTH 18)"
V2_FACTORY_HASH="$(cast keccak "$(cast code --rpc-url "$RPC_URL" "$V2_FACTORY")")"
V3_FACTORY_HASH="$(cast keccak "$(cast code --rpc-url "$RPC_URL" "$V3_FACTORY")")"
V4_MANAGER_HASH="$(cast keccak "$(cast code --rpc-url "$RPC_URL" "$V4_MANAGER")")"

jq \
    --arg network "$NETWORK" \
    --arg commit "$HEAD_COMMIT" \
    --arg v1 "$V1_TOKEN" \
    --arg v2Factory "$V2_FACTORY" \
    --arg v3Factory "$V3_FACTORY" \
    --arg v2Hash "$V2_FACTORY_HASH" \
    --arg v3Hash "$V3_FACTORY_HASH" \
    --arg v4Hash "$V4_MANAGER_HASH" \
    '.network = $network
     | .chainId = 31337
     | .rpcEnv = "ANVIL_RPC_URL"
     | .expectedGitCommit = $commit
     | .illustrativeInputs = false
     | .minDeployerBalanceWei = "1"
     | .timelockMinDelay = 2
     | .adminTransferDelay = 2
     | .biniV1Token = $v1
     | .dexPolicy.factories[0] = {"name":"Anvil V2 factory","kind":"UNISWAP_V2","address":$v2Factory,"runtimeCodeHash":$v2Hash}
     | .dexPolicy.factories[1] = {"name":"Anvil V3 factory","kind":"UNISWAP_V3","address":$v3Factory,"runtimeCodeHash":$v3Hash}
     | .dexPolicy.infrastructure[0] = {"name":"Anvil V4 PoolManager","address":"0x0000000000000000000000000000000000006003","runtimeCodeHash":$v4Hash}' \
    config/sepolia.json >"$CONFIG"

export ANVIL_RPC_URL="$RPC_URL"
export DEPLOYER_ADDRESS="$DEPLOYER"
export EXPECTED_GIT_COMMIT="$HEAD_COMMIT"
export BINI_V2_EXPECTED_CHAIN_ID=31337
export BINI_V2_TIMELOCK_MIN_DELAY=2
export BINI_V2_TIMELOCK_PROPOSER="$PROPOSER"
export BINI_V2_TIMELOCK_EXECUTOR="$EXECUTOR"
export BINI_V2_EMERGENCY_PAUSER_SAFE="$PAUSER"
export BINI_V2_GENESIS_DISTRIBUTION_SAFE="$GENESIS"
export BINI_V2_V1_TOKEN="$V1_TOKEN"
export BINI_V2_ADMIN_TRANSFER_DELAY=2

forge script script/DeployBiniV2.s.sol:DeployBiniV2 \
    --rpc-url "$RPC_URL" --unlocked --sender "$DEPLOYER" --broadcast >/dev/null

python3 - "$CONFIG" "$NETWORK" <<'PY'
import sys
from types import SimpleNamespace

sys.path.insert(0, "tools")
import bini_v2_cli as cli

config, network = sys.argv[1:]
context = cli.load_context(SimpleNamespace(network=network, config=config, mode="BROADCAST"))
evidence = cli.preflight(context, require_rpc=True)
evidence["mode"] = "BROADCAST"
cli.checked_write(cli.deployment_file(network), cli.manifest_from_broadcast(context, evidence))
PY

DEPLOYMENT="$ROOT/artifacts/deployments/$NETWORK/deployment.json"
TOKEN="$(jq -er '.proxy' "$DEPLOYMENT")"
VAULT="$(jq -er '.migrationVault' "$DEPLOYMENT")"
TIMELOCK="$(jq -er '.timelock' "$DEPLOYMENT")"
rpc anvil_setBalance "$TIMELOCK" 0x56BC75E2D63100000

EXECUTION_MODE=SAFE_PROPOSAL ./bin/bini-v2 configure-market \
    --network "$NETWORK" --config "$CONFIG" >/dev/null
POLICY_ARTIFACT="$(find "$ROOT/artifacts/deployments/$NETWORK" -name 'pre-market-policy-*.json' -print -quit)"
[[ -n "$POLICY_ARTIFACT" ]] || fail "PRE_MARKET policy artifact was not generated"
execute_timelock_package "$POLICY_ARTIFACT" "$PROPOSER" "$EXECUTOR"

cast send --rpc-url "$RPC_URL" --unlocked --from "$DEPLOYER" "$V2_FACTORY" \
    'createPair(address,address)(address)' "$TOKEN" "$OTHER_TOKEN" >/dev/null
cast send --rpc-url "$RPC_URL" --unlocked --from "$DEPLOYER" "$V3_FACTORY" \
    'createPool(address,address,uint24)(address)' "$TOKEN" "$OTHER_TOKEN" 3000 >/dev/null
V2_POOL="$(cast call --rpc-url "$RPC_URL" "$V2_FACTORY" 'getPair(address,address)(address)' "$TOKEN" "$OTHER_TOKEN")"
V3_POOL="$(cast call --rpc-url "$RPC_URL" "$V3_FACTORY" 'getPool(address,address,uint24)(address)' "$TOKEN" "$OTHER_TOKEN" 3000)"

SNAPSHOT="$(cast rpc --rpc-url "$RPC_URL" evm_snapshot | jq -er '.')"
TRANSFER_TO_DEPLOYER="$(cast calldata 'transfer(address,uint256)' "$DEPLOYER" 1)"
TRANSFER_TO_GENESIS="$(cast calldata 'transfer(address,uint256)' "$GENESIS" 1)"
send_raw "$GENESIS" "$TOKEN" "$TRANSFER_TO_DEPLOYER"
send_raw "$DEPLOYER" "$TOKEN" "$TRANSFER_TO_GENESIS"
for blocked in "$V2_POOL" "$V3_POOL" "$V4_MANAGER"; do
    expect_send_revert "$GENESIS" "$TOKEN" "$(cast calldata 'transfer(address,uint256)' "$blocked" 1)"
done
rpc evm_revert "$SNAPSHOT"

jq \
    --arg vault "$VAULT" \
    --arg treasury "$TREASURY" \
    --arg liquidity "$LIQUIDITY" \
    --arg rewards "$REWARDS" \
    --arg strategic "$STRATEGIC" \
    '.ledgerVersion = "bini-v2-anvil-release-v1"
     | .illustrativeInputs = false
     | .allocations[0].recipient = $vault
     | .allocations[1].recipient = $treasury
     | .allocations[4].recipient = $rewards
     | .allocations[5].recipient = $liquidity
     | .allocations[6].recipient = $strategic' \
    data/bini-v2-supply-ledger.json >"$LEDGER"

EXECUTION_MODE=SAFE_PROPOSAL ./bin/bini-v2 distribute \
    --network "$NETWORK" --config "$CONFIG" --ledger "$LEDGER" --vesting "$VESTING" >/dev/null
DISTRIBUTION="$ROOT/artifacts/distributions/$NETWORK/distribution-bini-v2-anvil-release-v1.json"
while IFS=$'\t' read -r to data; do
    send_raw "$GENESIS" "$to" "$data"
done < <(jq -er '.safeTransactionBuilder.transactions[] | [.to, .data] | @tsv' "$DISTRIBUTION")
[[ "$(call_scalar "$TOKEN" 'balanceOf(address)(uint256)' "$GENESIS")" == "0" ]] || \
    fail "distribution did not exhaust the Genesis Safe balance"

cat >"$HOLDERS" <<CSV
holderId,category,v1Address,v2Recipient,v1RawAmount,v2RawAmount,conversionRate,ownershipVerification,migrationMethod,vestingGrantId,batch,status,notes
holder-001,KNOWN_HOLDER,$DEPLOYER,$DEPLOYER,1000000000000,1000000000000000000,1000000,VERIFIED,SELF_SERVICE,,batch-01,READY,Anvil release rehearsal
CSV

cast send --rpc-url "$RPC_URL" --unlocked --from "$DEPLOYER" "$V1_TOKEN" \
    'mint(address,uint256)' "$DEPLOYER" 1000000000000 >/dev/null
EXECUTION_MODE=SAFE_PROPOSAL ./bin/bini-v2 migration-plan \
    --network "$NETWORK" --config "$CONFIG" --holders "$HOLDERS" >/dev/null
MIGRATION_PLAN="$(find "$ROOT/artifacts/migrations/$NETWORK" -name 'migration-plan-*.json' -print -quit)"
[[ -n "$MIGRATION_PLAN" ]] || fail "migration governance artifact was not generated"
execute_timelock_package "$MIGRATION_PLAN" "$PROPOSER" "$EXECUTOR"

cast send --rpc-url "$RPC_URL" --unlocked --from "$DEPLOYER" "$V1_TOKEN" \
    'approve(address,uint256)' "$VAULT" 1000000000000 >/dev/null
cast send --rpc-url "$RPC_URL" --unlocked --from "$DEPLOYER" "$VAULT" \
    'migrate(address,uint256,address,uint256,bytes)' "$DEPLOYER" 1000000000000 "$DEPLOYER" 0 0x >/dev/null

EXECUTION_MODE=SIMULATE ./bin/bini-v2 verify --network "$NETWORK" --config "$CONFIG" >/dev/null
[[ "$(call_scalar "$VAULT" 'totalLockedV1()(uint256)')" == "1000000000000" ]] || \
    fail "V1 lock reconciliation failed"
[[ "$(call_scalar "$VAULT" 'totalReleasedV2()(uint256)')" == "1000000000000000000" ]] || \
    fail "V2 release reconciliation failed"

EXECUTION_MODE=SAFE_PROPOSAL ./bin/bini-v2 open-market \
    --network "$NETWORK" --config "$CONFIG" >/dev/null
OPEN_MARKET_ARTIFACT="$(find "$ROOT/artifacts/deployments/$NETWORK" -name 'open-market-*.json' -print -quit)"
[[ -n "$OPEN_MARKET_ARTIFACT" ]] || fail "OPEN_MARKET artifact was not generated"
execute_timelock_package "$OPEN_MARKET_ARTIFACT" "$PROPOSER" "$EXECUTOR"
[[ "$(call_scalar "$TOKEN" 'marketOpen()(bool)')" == "true" ]] || \
    fail "market did not open"
send_raw "$DEPLOYER" "$TOKEN" "$(cast calldata 'transfer(address,uint256)' "$V2_POOL" 1)"
send_raw "$DEPLOYER" "$TOKEN" "$(cast calldata 'transfer(address,uint256)' "$V3_POOL" 1)"
send_raw "$DEPLOYER" "$TOKEN" "$(cast calldata 'transfer(address,uint256)' "$V4_MANAGER" 1)"
expect_send_revert "$TIMELOCK" "$TOKEN" "$(cast calldata 'openMarket()')"

printf 'Anvil release rehearsal passed: deploy -> PRE_MARKET policy -> distribution -> migration -> OPEN_MARKET\n'
