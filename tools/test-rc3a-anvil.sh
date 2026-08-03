#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

NETWORK="anvil-rc3a"
RPC_URL="http://127.0.0.1:${BINI_RC3A_ANVIL_PORT:-18545}"
DEPLOYER="0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
TEST_PASSWORD="rc3a-ephemeral-only"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bini-rc3a.XXXXXX")"
KEYSTORE_DIR="$RUN_DIR/keystores"
ARTIFACT_DIR="$ROOT/artifacts/$NETWORK"
ANVIL_PID=""

if [[ -e "$ARTIFACT_DIR" || -e "$ROOT/artifacts/deployments/$NETWORK" || -e "$ROOT/artifacts/distributions/$NETWORK" || -e "$ROOT/artifacts/migrations/$NETWORK" || -e "$ROOT/artifacts/verification/$NETWORK" ]]; then
  echo "RC3A rehearsal refuses to overwrite existing $NETWORK artifacts" >&2
  exit 1
fi

cleanup() {
  if [[ -n "$ANVIL_PID" ]]; then
    kill "$ANVIL_PID" 2>/dev/null || true
    wait "$ANVIL_PID" 2>/dev/null || true
  fi
  rm -rf "$RUN_DIR"
}
trap cleanup EXIT

anvil --chain-id 31337 --port "${BINI_RC3A_ANVIL_PORT:-18545}" --silent >"$RUN_DIR/anvil.log" 2>&1 &
ANVIL_PID=$!
for _ in $(seq 1 50); do
  if cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
[[ "$(cast chain-id --rpc-url "$RPC_URL")" == "31337" ]]

export BINI_RC3A_LOCAL_REHEARSAL=1
export BINI_RC3A_ALLOW_DIRTY_LOCAL=1
export BINI_RC3A_TEST_MODE=1
export BINI_RC3A_TEST_KEYSTORE_PASSWORD="$TEST_PASSWORD"
export BINI_TEST_KEYSTORE_DIR="$KEYSTORE_DIR"
export ANVIL_RPC_URL="$RPC_URL"
export BINI_LOCAL_DEPLOYER="$DEPLOYER"
export BINI_SAFE_EXECUTOR_ADDRESS="$DEPLOYER"
export DEPLOYER_ADDRESS="$DEPLOYER"
export EXPECTED_GIT_COMMIT="$(git rev-parse HEAD)"

ACCOUNT_MANIFEST="$ARTIFACT_DIR/bootstrap/test-accounts.public.json"
./bin/bini-v2 test-accounts init --network "$NETWORK" --output "$ACCOUNT_MANIFEST" --keystore-dir "$KEYSTORE_DIR"
for account in $(jq -r '.accounts[].address' "$ACCOUNT_MANIFEST"); do
  cast rpc anvil_setBalance "$account" 0x21e19e0c9bab2400000 --rpc-url "$RPC_URL" >/dev/null
done
./bin/bini-v2 test-accounts verify --network "$NETWORK" --manifest "$ACCOUNT_MANIFEST" --keystore-dir "$KEYSTORE_DIR"

GOVERNANCE="$RUN_DIR/governance.json"
jq -n \
  --arg network "$NETWORK" \
  --argjson owners "$(jq '.accounts' "$ACCOUNT_MANIFEST")" \
  --argjson purposes "$(jq '.safePurposes' config/governance.sepolia.json)" \
  '{network:$network,chainId:31337,sepoliaRehearsalOnly:true,safeVersion:"1.4.1",safeSaltBase:7000,owners:$owners,threshold:2,safePurposes:$purposes,safeInfrastructure:null,timelockMinimumDelaySeconds:2}' \
  >"$GOVERNANCE"

./bin/bini-v2 safes plan --network "$NETWORK" --governance "$GOVERNANCE" >/dev/null
./bin/bini-v2 safes deploy --network "$NETWORK" --governance "$GOVERNANCE" --mode BROADCAST
SAFES="$ARTIFACT_DIR/infrastructure/safes.json"
./bin/bini-v2 safes verify --network "$NETWORK" --manifest "$SAFES"
./bin/bini-v2 timelock deploy --network "$NETWORK" --governance "$GOVERNANCE" --mode BROADCAST
TIMELOCK="$ARTIFACT_DIR/infrastructure/timelock.json"
./bin/bini-v2 timelock verify --network "$NETWORK" --manifest "$TIMELOCK"

safe_address() {
  jq -r --arg purpose "$1" '.safes[] | select(.purpose == $purpose) | .address' "$SAFES"
}

PHASE_CONFIG="$RUN_DIR/phase1.json"
MULTISEND="$(jq -r '.multiSend' "$SAFES")"
MULTISEND_HASH="$(cast code "$MULTISEND" --rpc-url "$RPC_URL" | cast keccak)"
THRESHOLDS="$(jq 'reduce .safes[] as $safe ({}; .[$safe.address] = 2)' "$SAFES")"
jq -n \
  --arg network "$NETWORK" --arg commit "$EXPECTED_GIT_COMMIT" --arg deployer "$DEPLOYER" \
  --arg timelock "$(jq -r '.address' "$TIMELOCK")" --arg governance "$(safe_address GOVERNANCE_SAFE)" \
  --arg security "$(safe_address SECURITY_SAFE)" --arg genesis "$(safe_address GENESIS_DISTRIBUTION_SAFE)" \
  --arg rewards1 "$(safe_address REWARDS_Y1_SAFE)" --arg rewards2 "$(safe_address REWARDS_Y2_RESERVE_SAFE)" \
  --arg rewards3 "$(safe_address REWARDS_Y3_RESERVE_SAFE)" --arg rewards4 "$(safe_address REWARDS_Y4_RESERVE_SAFE)" \
  --arg team "$(safe_address TEAM_FOUNDERS_RESERVE_SAFE)" --arg marketing "$(safe_address MARKETING_OPERATIONS_SAFE)" \
  --arg milestone "$(safe_address MARKETING_MILESTONE_RESERVE_SAFE)" --arg ecosystem "$(safe_address ECOSYSTEM_RESERVE_SAFE)" \
  --arg liquidity "$(safe_address LIQUIDITY_RESERVE_SAFE)" --arg multiSend "$MULTISEND" --arg multiSendHash "$MULTISEND_HASH" \
  --arg bytecodeHash "$(forge inspect BiniTokenV2 bytecode | cast keccak)" --argjson thresholds "$THRESHOLDS" \
  '{network:$network,phase:"PHASE_1",chainId:31337,rpcEnv:"ANVIL_RPC_URL",deployerAccount:"anvil-unlocked",deployerAddress:$deployer,expectedGitCommit:$commit,illustrativeInputs:false,expectedTokenCreationBytecodeHash:$bytecodeHash,minDeployerBalanceWei:"1",timelockMinDelay:2,adminTransferDelay:2,timelockAddress:$timelock,timelockProposerSafe:$governance,timelockExecutorSafe:$governance,emergencyPauserSafe:$security,genesisDistributionSafe:$genesis,rewardsY1Safe:$rewards1,rewardsY2ReserveSafe:$rewards2,rewardsY3ReserveSafe:$rewards3,rewardsY4ReserveSafe:$rewards4,teamFoundersReserveSafe:$team,marketingOperationsSafe:$marketing,marketingMilestoneReserveSafe:$milestone,ecosystemReserveSafe:$ecosystem,liquidityReserveSafe:$liquidity,safeMultiSend:$multiSend,safeMultiSendRuntimeCodeHash:$multiSendHash,safeThresholds:$thresholds}' \
  >"$PHASE_CONFIG"

LEDGER="$RUN_DIR/ledger.json"
jq --argjson config "$(cat "$PHASE_CONFIG")" '.illustrativeInputs=false | .allocations |= map(.recipient = $config[.recipientConfigKey])' data/bini-v2-supply-ledger.json >"$LEDGER"

./bin/bini-v2 deploy --network "$NETWORK" --config "$PHASE_CONFIG" --mode BROADCAST
./bin/bini-v2 distribute --network "$NETWORK" --config "$PHASE_CONFIG" --ledger "$LEDGER" --mode SAFE_PROPOSAL
DISTRIBUTION_WRAPPER="$ROOT/artifacts/distributions/$NETWORK/distribution-bini-v2-phase1-nine-safe-v1.json"
DISTRIBUTION_PACKAGE="$RUN_DIR/distribution.json"
jq '.safeTransactionBuilder' "$DISTRIBUTION_WRAPPER" >"$DISTRIBUTION_PACKAGE"

safe_execute() {
  local package="$1"
  ./bin/bini-v2 safe-tx inspect --package "$package" >/dev/null
  ./bin/bini-v2 safe-tx sign --package "$package" --account bini-test-signer-1 >/dev/null
  local bundle
  bundle="$(./bin/bini-v2 safe-tx sign --package "$package" --account bini-test-signer-2)"
  local receipt
  receipt="$(./bin/bini-v2 safe-tx execute --package "$package" --signatures "$bundle" --network "$NETWORK")"
  ./bin/bini-v2 safe-tx verify --receipt "$receipt" --network "$NETWORK" >/dev/null
  printf '%s\n' "$receipt"
}

safe_execute "$DISTRIBUTION_PACKAGE" >/dev/null
./bin/bini-v2 verify --network "$NETWORK" --config "$PHASE_CONFIG" --ledger "$LEDGER" --mode SIMULATE --expected-market-state PRE_MARKET
./bin/bini-v2 test-pre-market plan --network "$NETWORK" >/dev/null
./bin/bini-v2 test-pre-market run --network "$NETWORK"
./bin/bini-v2 test-pre-market verify --network "$NETWORK"

PAUSE_PACKAGE="$(./bin/bini-v2 pause plan --network "$NETWORK")"
PAUSE_RECEIPT="$(safe_execute "$PAUSE_PACKAGE")"
./bin/bini-v2 pause verify --network "$NETWORK" --receipt "$PAUSE_RECEIPT"
UNPAUSE_PLAN="$RUN_DIR/unpause-plan.json"
./bin/bini-v2 unpause plan --network "$NETWORK" >"$UNPAUSE_PLAN"
UNPAUSE_OPERATION="$(jq -r '.operation' "$UNPAUSE_PLAN")"
UNPAUSE_SCHEDULE="$(jq -r '.schedulePackage' "$UNPAUSE_PLAN")"
safe_execute "$UNPAUSE_SCHEDULE" >/dev/null
UNPAUSE_EXECUTE="$(./bin/bini-v2 timelock execute --operation "$UNPAUSE_OPERATION")"
EXECUTE_TO="$(jq -r '.transactions[0].to' "$UNPAUSE_EXECUTE")"
EXECUTE_DATA="$(jq -r '.transactions[0].data' "$UNPAUSE_EXECUTE")"
EXECUTE_FROM="$(jq -r '.meta.createdFromSafeAddress' "$UNPAUSE_EXECUTE")"
if cast call "$EXECUTE_TO" "$EXECUTE_DATA" --from "$EXECUTE_FROM" --rpc-url "$RPC_URL" >/dev/null 2>&1; then
  echo "early Timelock execution unexpectedly succeeded" >&2
  exit 1
fi
cast rpc evm_increaseTime 3 --rpc-url "$RPC_URL" >/dev/null
cast rpc evm_mine --rpc-url "$RPC_URL" >/dev/null
UNPAUSE_RECEIPT="$(safe_execute "$UNPAUSE_EXECUTE")"
./bin/bini-v2 unpause verify --network "$NETWORK" --receipt "$UNPAUSE_RECEIPT"

./bin/bini-v2 migration-fixture deploy --network "$NETWORK" --mode BROADCAST
MIGRATION_DEPLOY_CONFIG="$RUN_DIR/migration-deploy.json"
jq -n --arg network "$NETWORK" '{network:$network,chainId:31337,phase:"PHASE_2",v1Token:"FROM_FIXTURE_MANIFEST"}' >"$MIGRATION_DEPLOY_CONFIG"
./bin/bini-v2 migration-vault deploy --network "$NETWORK" --migration-config "$MIGRATION_DEPLOY_CONFIG" --mode BROADCAST
FIXTURE="$(jq -r '.address' "$ARTIFACT_DIR/migration/fixture.json")"
VAULT="$(jq -r '.address' "$ARTIFACT_DIR/migration/vault.json")"
TOKEN="$(jq -r '.proxy' "$ROOT/artifacts/deployments/$NETWORK/deployment.json")"

HOLDER_4="0x70997970c51812dc3a010c7d01b50e0d17dc79c8"
HOLDER_5="0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc"
HOLDERS="$RUN_DIR/holders.csv"
{
  echo 'holderId,v1Address,v2Recipient,v1RawAmount,v2RawAmount,sourceAllocationId,sourceTopLevelSafe,beneficiaryType,ownershipProof,migrationMethod,vestingTreatment,batch,status'
  echo "holder-1,$(jq -r '.accounts[0].address' "$ACCOUNT_MANIFEST"),$(jq -r '.accounts[0].address' "$ACCOUNT_MANIFEST"),1000000000000,1000000000000000000,rewards-year-1,$(safe_address REWARDS_Y1_SAFE),INVESTOR,VERIFIED_SIGNATURE,SELF_SERVICE,NONE,rc3a-five,PLANNED"
  echo "holder-2,$(jq -r '.accounts[1].address' "$ACCOUNT_MANIFEST"),$(jq -r '.accounts[1].address' "$ACCOUNT_MANIFEST"),2000000000000,2000000000000000000,rewards-year-2-reserve,$(safe_address REWARDS_Y2_RESERVE_SAFE),INVESTOR,VERIFIED_SIGNATURE,SELF_SERVICE,NONE,rc3a-five,PLANNED"
  echo "holder-3,$(jq -r '.accounts[2].address' "$ACCOUNT_MANIFEST"),$(jq -r '.accounts[2].address' "$ACCOUNT_MANIFEST"),3000000000000,3000000000000000000,rewards-year-3-reserve,$(safe_address REWARDS_Y3_RESERVE_SAFE),INVESTOR,VERIFIED_SIGNATURE,SELF_SERVICE,NONE,rc3a-five,PLANNED"
  echo "holder-4,$HOLDER_4,$HOLDER_4,4000000000000,4000000000000000000,rewards-year-4-reserve,$(safe_address REWARDS_Y4_RESERVE_SAFE),PARTNER,ONCHAIN_PROOF,SELF_SERVICE,NONE,rc3a-five,PLANNED"
  echo "holder-5,$HOLDER_5,$HOLDER_5,5000000000000,5000000000000000000,team-founders-reserve,$(safe_address TEAM_FOUNDERS_RESERVE_SAFE),TEAM,LEGAL_ATTESTATION,SELF_SERVICE,PRESERVE_EXISTING_SCHEDULE,rc3a-five,PLANNED"
} >"$HOLDERS"

MIGRATION_CONFIG="$RUN_DIR/migration.json"
HOLDER_HASH="sha256:$(shasum -a 256 "$HOLDERS" | awk '{print $1}')"
jq -n --arg network "$NETWORK" --arg v1 "$FIXTURE" --arg v2 "$TOKEN" --arg vault "$VAULT" --arg holderHash "$HOLDER_HASH" --arg vaultBytecodeHash "$(forge inspect BiniMigrationVault bytecode | cast keccak)" \
  --arg s1 "$(safe_address REWARDS_Y1_SAFE)" --arg s2 "$(safe_address REWARDS_Y2_RESERVE_SAFE)" --arg s3 "$(safe_address REWARDS_Y3_RESERVE_SAFE)" --arg s4 "$(safe_address REWARDS_Y4_RESERVE_SAFE)" --arg s5 "$(safe_address TEAM_FOUNDERS_RESERVE_SAFE)" \
  '{network:$network,phase:"PHASE_2",chainId:31337,illustrativeInputs:false,v1Token:$v1,v2Proxy:$v2,migrationVault:$vault,conversionFactor:"1000000",fundingReserveRaw:"15000000000000000000",holderManifestHash:$holderHash,expectedVaultCreationBytecodeHash:$vaultBytecodeHash,fundingSources:[{sourceAllocationId:"rewards-year-1",sourceTopLevelSafe:$s1,fundingRaw:"1000000000000000000"},{sourceAllocationId:"rewards-year-2-reserve",sourceTopLevelSafe:$s2,fundingRaw:"2000000000000000000"},{sourceAllocationId:"rewards-year-3-reserve",sourceTopLevelSafe:$s3,fundingRaw:"3000000000000000000"},{sourceAllocationId:"rewards-year-4-reserve",sourceTopLevelSafe:$s4,fundingRaw:"4000000000000000000"},{sourceAllocationId:"team-founders-reserve",sourceTopLevelSafe:$s5,fundingRaw:"5000000000000000000"}]}' >"$MIGRATION_CONFIG"

FUNDING_PLAN="$(./bin/bini-v2 migration-fund plan --network "$NETWORK" --holders "$HOLDERS")"
LAST_FUNDING_RECEIPT=""
while IFS= read -r package; do
  LAST_FUNDING_RECEIPT="$(safe_execute "$package")"
done < <(jq -r '.fundingSources[].package' "$FUNDING_PLAN")
./bin/bini-v2 migration-fund verify --network "$NETWORK" --receipt "$LAST_FUNDING_RECEIPT"

MIGRATION_PLAN="$RUN_DIR/migration-plan.json"
./bin/bini-v2 migration-plan --network "$NETWORK" --config "$PHASE_CONFIG" --holders "$HOLDERS" --migration-config "$MIGRATION_CONFIG" --mode PLAN >"$MIGRATION_PLAN"
jq '.timelockPackage.scheduleProposal' "$MIGRATION_PLAN" >"$RUN_DIR/migration-schedule.json"
jq '.timelockPackage.executeProposal' "$MIGRATION_PLAN" >"$RUN_DIR/migration-execute.json"
safe_execute "$RUN_DIR/migration-schedule.json" >/dev/null
cast rpc evm_increaseTime 3 --rpc-url "$RPC_URL" >/dev/null
cast rpc evm_mine --rpc-url "$RPC_URL" >/dev/null
safe_execute "$RUN_DIR/migration-execute.json" >/dev/null

for index in 0 1 2; do
  holder="$(jq -r ".accounts[$index].address" "$ACCOUNT_MANIFEST")"
  amount="$(((index + 1) * 1000000000000))"
  keyfile="$(find "$KEYSTORE_DIR" -maxdepth 1 -type f -name "bini-test-signer-$((index + 1))*" | head -1)"
  cast send "$FIXTURE" 'mintFixture(address,uint256)' "$holder" "$amount" --unlocked --from "$DEPLOYER" --rpc-url "$RPC_URL" >/dev/null
  cast send "$FIXTURE" 'approve(address,uint256)' "$VAULT" "$amount" --keystore "$keyfile" --password "$TEST_PASSWORD" --rpc-url "$RPC_URL" >/dev/null
done
for entry in "$HOLDER_4:4000000000000" "$HOLDER_5:5000000000000"; do
  holder="${entry%%:*}"
  amount="${entry##*:}"
  cast send "$FIXTURE" 'mintFixture(address,uint256)' "$holder" "$amount" --unlocked --from "$DEPLOYER" --rpc-url "$RPC_URL" >/dev/null
  cast send "$FIXTURE" 'approve(address,uint256)' "$VAULT" "$amount" --unlocked --from "$holder" --rpc-url "$RPC_URL" >/dev/null
done

MIGRATE_PLAN="$RUN_DIR/migrate.json"
./bin/bini-v2 migrate --network "$NETWORK" --config "$PHASE_CONFIG" --holders "$HOLDERS" --migration-config "$MIGRATION_CONFIG" --batch rc3a-five --mode PLAN >"$MIGRATE_PLAN"
while IFS=$'\t' read -r target data; do
  cast send "$target" "$data" --unlocked --from "$DEPLOYER" --rpc-url "$RPC_URL" >/dev/null
done < <(jq -r '.calls[] | [.to,.data] | @tsv' "$MIGRATE_PLAN")
./bin/bini-v2 verify-migration --network "$NETWORK" --config "$PHASE_CONFIG" --migration-config "$MIGRATION_CONFIG" --mode SIMULATE

DEX_POLICY="$RUN_DIR/dex-policy.json"
jq -n --arg network "$NETWORK" --arg v2 "$(jq -r '.singleton' "$SAFES")" --arg v3 "$(jq -r '.proxyFactory' "$SAFES")" --arg v4 "$MULTISEND" \
  --arg h2 "$(cast code "$(jq -r '.singleton' "$SAFES")" --rpc-url "$RPC_URL" | cast keccak)" --arg h3 "$(cast code "$(jq -r '.proxyFactory' "$SAFES")" --rpc-url "$RPC_URL" | cast keccak)" --arg h4 "$MULTISEND_HASH" \
  '{network:$network,chainId:31337,phase:"PHASE_3",expectedPolicyState:"PRE_MARKET_BLOCKED",illustrativeInputs:false,factories:[{name:"local-v2-fixture",kind:"UNISWAP_V2",address:$v2,runtimeCodeHash:$h2},{name:"local-v3-fixture",kind:"UNISWAP_V3",address:$v3,runtimeCodeHash:$h3}],infrastructure:[{name:"local-v4-fixture",kind:"POOL_MANAGER",address:$v4,runtimeCodeHash:$h4}]}' >"$DEX_POLICY"

OPEN_PACKAGE="$ARTIFACT_DIR/open-market/operation.json"
mkdir -p "$(dirname "$OPEN_PACKAGE")"
./bin/bini-v2 open-market --network "$NETWORK" --config "$PHASE_CONFIG" --policy "$DEX_POLICY" --mode PLAN >"$OPEN_PACKAGE"
jq '.timelockPackage.scheduleProposal' "$OPEN_PACKAGE" >"$RUN_DIR/open-schedule.json"
jq '.timelockPackage.executeProposal' "$OPEN_PACKAGE" >"$RUN_DIR/open-execute.json"
BALANCES_BEFORE="$RUN_DIR/open-balances-before.json"
jq -n --arg token "$TOKEN" --argjson safes "$(jq '[.safes[].address]' "$SAFES")" '$safes | map({address:.,balance:null})' >"$BALANCES_BEFORE"
jq -r '.[].address' "$BALANCES_BEFORE" | while read -r address; do cast call "$TOKEN" 'balanceOf(address)(uint256)' "$address" --rpc-url "$RPC_URL"; done >"$RUN_DIR/balances-before.txt"
safe_execute "$RUN_DIR/open-schedule.json" >/dev/null
if cast call "$(jq -r '.transactions[0].to' "$RUN_DIR/open-execute.json")" "$(jq -r '.transactions[0].data' "$RUN_DIR/open-execute.json")" --from "$(safe_address GOVERNANCE_SAFE)" --rpc-url "$RPC_URL" >/dev/null 2>&1; then
  echo "early openMarket execution unexpectedly succeeded" >&2
  exit 1
fi
cast rpc evm_increaseTime 3 --rpc-url "$RPC_URL" >/dev/null
cast rpc evm_mine --rpc-url "$RPC_URL" >/dev/null
safe_execute "$RUN_DIR/open-execute.json" >/dev/null
jq -r '.[].address' "$BALANCES_BEFORE" | while read -r address; do cast call "$TOKEN" 'balanceOf(address)(uint256)' "$address" --rpc-url "$RPC_URL"; done >"$RUN_DIR/balances-after.txt"
cmp "$RUN_DIR/balances-before.txt" "$RUN_DIR/balances-after.txt"
./bin/bini-v2 verify-open-market --network "$NETWORK" --operation "$OPEN_PACKAGE"

mkdir -p "$ARTIFACT_DIR/source-verification" "$ARTIFACT_DIR/test-logs"
tools/release-artifacts.sh check >"$ARTIFACT_DIR/source-verification/local-build.log"
jq -n --arg commit "$EXPECTED_GIT_COMMIT" --arg token "$TOKEN" '{schemaVersion:"1.0",network:"anvil-rc3a",chainId:31337,sourceCommit:$commit,token:$token,status:"LOCAL_BUILD_MATCHED"}' >"$ARTIFACT_DIR/source-verification/local-build.json"
forge test --match-contract RC3RealSafeLifecycle -vv >"$ARTIFACT_DIR/test-logs/real-safe-timelock-lifecycle.log"
./bin/bini-v2 status --network "$NETWORK" --full >"$ARTIFACT_DIR/full-status.json"

EVIDENCE_DIR="$ARTIFACT_DIR/rc3/evidence"
./bin/bini-v2 evidence export-rc3 --network "$NETWORK" --output "$EVIDENCE_DIR"
./bin/bini-v2 evidence seal-rc3 --directory "$ARTIFACT_DIR/rc3"

if [[ -n "${BINI_EVIDENCE_DIR:-}" ]]; then
  mkdir -p "$BINI_EVIDENCE_DIR/rc3a"
  cp -R "$ARTIFACT_DIR/rc3/." "$BINI_EVIDENCE_DIR/rc3a/"
  cp "$ARTIFACT_DIR/test-logs/real-safe-timelock-lifecycle.log" "$BINI_EVIDENCE_DIR/rc3a/"
fi

echo "RC3A_LOCAL_REHEARSAL_GREEN"
