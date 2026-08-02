#!/usr/bin/env python3
"""BINI V2 release CLI. Uses only Python's standard library and Foundry."""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

ROOT = Path(__file__).resolve().parents[1]
TOTAL_SUPPLY_RAW = 1_000_000_000 * 10**18
V1_TO_V2_SCALE = 1_000_000
MODES = ("PLAN", "SIMULATE", "SAFE_PROPOSAL", "BROADCAST")
ADDRESS_RE = re.compile(r"^0x[0-9a-fA-F]{40}$")
HASH_RE = re.compile(r"^0x[0-9a-fA-F]{64}$")
ZERO_ADDRESS = "0x" + "0" * 40
ZERO_HASH = "0x" + "0" * 64
ERC1967_IMPLEMENTATION_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
CSV_COLUMNS = (
    "holderId",
    "category",
    "v1Address",
    "v2Recipient",
    "v1RawAmount",
    "v2RawAmount",
    "conversionRate",
    "ownershipVerification",
    "migrationMethod",
    "vestingGrantId",
    "batch",
    "status",
    "notes",
)


class ReleaseError(RuntimeError):
    pass


@dataclass(frozen=True)
class Context:
    network: str
    mode: str
    config_path: Path
    config: dict[str, Any]

    @property
    def chain_id(self) -> int:
        return strict_int(self.config.get("chainId"), "config.chainId")

    @property
    def rpc_url(self) -> str:
        env_name = self.config.get("rpcEnv", f"{self.network.upper()}_RPC_URL")
        value = os.environ.get(env_name, "")
        if not value:
            raise ReleaseError(f"missing RPC environment variable: {env_name}")
        return value


def strict_int(value: Any, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, (int, str)):
        raise ReleaseError(f"{field} must be an integer or decimal integer string")
    text = str(value)
    if not text.isdigit():
        raise ReleaseError(f"{field} must be an unsigned decimal integer")
    return int(text)


def receipt_int(value: Any, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, (int, str)):
        raise ReleaseError(f"{field} must be an integer")
    try:
        return int(str(value), 0)
    except ValueError as exc:
        raise ReleaseError(f"{field} must be a decimal or 0x-prefixed integer") from exc


def require_address(value: Any, field: str, *, allow_zero: bool = False) -> str:
    if not isinstance(value, str) or not ADDRESS_RE.fullmatch(value):
        raise ReleaseError(f"{field} is not a valid Ethereum address")
    if not allow_zero and value.lower() == ZERO_ADDRESS:
        raise ReleaseError(f"{field} must not be the zero address")
    return value


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ReleaseError(f"file not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ReleaseError(f"invalid JSON {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ReleaseError(f"top-level JSON value must be an object: {path}")
    return value


def load_json_from_output(output: str, field: str) -> dict[str, Any]:
    try:
        value = json.loads(output)
    except json.JSONDecodeError as exc:
        raise ReleaseError(f"{field} did not return valid JSON") from exc
    if not isinstance(value, dict):
        raise ReleaseError(f"{field} JSON must be an object")
    return value


def decode_cast_call(output: str, field: str) -> str:
    try:
        value = json.loads(output)
    except json.JSONDecodeError as exc:
        raise ReleaseError(f"{field} did not return valid JSON") from exc
    if not isinstance(value, list) or len(value) != 1 or not isinstance(value[0], (str, int, bool)):
        raise ReleaseError(f"{field} must return exactly one scalar value")
    if isinstance(value[0], bool):
        return str(value[0]).lower()
    return str(value[0])


def canonical_hash(path: Path) -> str:
    return "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()


def run(command: list[str], *, env: dict[str, str] | None = None, capture: bool = True) -> str:
    try:
        completed = subprocess.run(
            command,
            cwd=ROOT,
            env=env,
            check=True,
            text=True,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
        )
    except FileNotFoundError as exc:
        raise ReleaseError(f"required executable not found: {command[0]}") from exc
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or "").strip()
        raise ReleaseError(f"command failed: {' '.join(command)}\n{detail}") from exc
    return (completed.stdout or "").strip()


def command_reverts(command: list[str]) -> bool:
    try:
        completed = subprocess.run(
            command,
            cwd=ROOT,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except FileNotFoundError as exc:
        raise ReleaseError(f"required executable not found: {command[0]}") from exc
    return completed.returncode != 0


def checked_write(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        with path.open("x", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
    except FileExistsError as exc:
        raise ReleaseError(f"refusing to overwrite existing artifact: {path}") from exc


def now_utc() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()


def artifact_path(kind: str, network: str, name: str) -> Path:
    return ROOT / "artifacts" / kind / network / name


def load_context(args: argparse.Namespace) -> Context:
    mode = (args.mode or os.environ.get("EXECUTION_MODE", "PLAN")).upper()
    if mode not in MODES:
        raise ReleaseError(f"invalid execution mode {mode}; expected one of {', '.join(MODES)}")
    config_path = Path(args.config) if getattr(args, "config", None) else ROOT / "config" / f"{args.network}.json"
    if not config_path.is_absolute():
        config_path = ROOT / config_path
    config = load_json(config_path)
    if config.get("network") != args.network:
        raise ReleaseError("network argument does not match config.network")
    context = Context(args.network, mode, config_path, config)
    guard_execution(context)
    return context


def guard_execution(context: Context) -> None:
    if context.network != "mainnet" or context.mode != "BROADCAST":
        return
    if os.environ.get("EXECUTION_MODE") != "BROADCAST":
        raise ReleaseError("mainnet requires EXECUTION_MODE=BROADCAST")
    if os.environ.get("CONFIRM_MAINNET") != "yes":
        raise ReleaseError("mainnet requires CONFIRM_MAINNET=yes")
    if os.environ.get("EXPECTED_CHAIN_ID") != "1" or context.chain_id != 1:
        raise ReleaseError("mainnet requires EXPECTED_CHAIN_ID=1 and config chainId 1")


def validate_config(context: Context) -> None:
    config = context.config
    if strict_int(config.get("chainId"), "config.chainId") <= 0:
        raise ReleaseError("config.chainId must be positive")
    if strict_int(config.get("timelockMinDelay"), "config.timelockMinDelay") <= 0:
        raise ReleaseError("timelockMinDelay must be positive")
    strict_int(config.get("adminTransferDelay"), "config.adminTransferDelay")
    strict_int(config.get("minDeployerBalanceWei"), "config.minDeployerBalanceWei")
    safe_keys = (
        "timelockProposerSafe",
        "timelockExecutorSafe",
        "emergencyPauserSafe",
        "genesisDistributionSafe",
        "treasurySafe",
        "liquiditySafe",
        "rewardsSafe",
        "strategicReserveSafe",
    )
    for key in (*safe_keys, "biniV1Token"):
        require_address(config.get(key), f"config.{key}")
    custody_keys = (
        "genesisDistributionSafe",
        "treasurySafe",
        "liquiditySafe",
        "rewardsSafe",
        "strategicReserveSafe",
    )
    custody_addresses = [config[key].lower() for key in custody_keys]
    if len(set(custody_addresses)) != len(custody_addresses):
        raise ReleaseError("Genesis, Treasury, Liquidity, Rewards and Strategic custody addresses must be distinct")
    thresholds = config.get("safeThresholds")
    if not isinstance(thresholds, dict) or not thresholds:
        raise ReleaseError("config.safeThresholds must be a non-empty object")
    for safe, threshold in thresholds.items():
        require_address(safe, "safeThresholds key")
        if strict_int(threshold, f"safeThresholds[{safe}]") <= 0:
            raise ReleaseError("Safe threshold must be positive")
    threshold_addresses = {address.lower() for address in thresholds}
    missing_thresholds = [key for key in safe_keys if config[key].lower() not in threshold_addresses]
    if missing_thresholds:
        raise ReleaseError(f"safeThresholds is missing configured Safes: {', '.join(missing_thresholds)}")
    validate_dex_policy(config)


def validate_dex_policy(config: dict[str, Any]) -> None:
    policy = config.get("dexPolicy")
    if not isinstance(policy, dict):
        raise ReleaseError("config.dexPolicy must be an object")
    factories = policy.get("factories")
    infrastructure = policy.get("infrastructure")
    if not isinstance(factories, list) or not factories:
        raise ReleaseError("dexPolicy.factories must be a non-empty array")
    if not isinstance(infrastructure, list) or not infrastructure:
        raise ReleaseError("dexPolicy.infrastructure must be a non-empty array")
    kinds: set[str] = set()
    addresses: set[str] = set()
    for index, entry in enumerate(factories):
        if not isinstance(entry, dict):
            raise ReleaseError(f"DEX factory {index} must be an object")
        kind = entry.get("kind")
        if kind not in {"UNISWAP_V2", "UNISWAP_V3"}:
            raise ReleaseError(f"invalid DEX factory kind: {kind}")
        kinds.add(kind)
        address = require_address(entry.get("address"), f"DEX factory {index} address").lower()
        if address in addresses:
            raise ReleaseError(f"duplicate DEX policy address: {address}")
        addresses.add(address)
        require_hash(entry.get("runtimeCodeHash"), f"DEX factory {index} runtimeCodeHash")
    if kinds != {"UNISWAP_V2", "UNISWAP_V3"}:
        raise ReleaseError("DEX policy must include both V2 and V3 factories")
    for index, entry in enumerate(infrastructure):
        if not isinstance(entry, dict):
            raise ReleaseError(f"DEX infrastructure {index} must be an object")
        address = require_address(entry.get("address"), f"DEX infrastructure {index} address").lower()
        if address in addresses:
            raise ReleaseError(f"duplicate DEX policy address: {address}")
        addresses.add(address)
        require_hash(entry.get("runtimeCodeHash"), f"DEX infrastructure {index} runtimeCodeHash")


def require_hash(value: Any, field: str) -> str:
    if not isinstance(value, str) or not HASH_RE.fullmatch(value):
        raise ReleaseError(f"{field} is not a bytes32 hash")
    return value


def validate_ledger(path: Path, vesting_path: Path | None = None) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    ledger = load_json(path)
    version = ledger.get("ledgerVersion")
    if not isinstance(version, str) or not version:
        raise ReleaseError("ledgerVersion is required")
    if strict_int(ledger.get("totalSupplyRaw"), "totalSupplyRaw") != TOTAL_SUPPLY_RAW:
        raise ReleaseError("totalSupplyRaw must equal exactly 1,000,000,000 BINI")
    allocations = ledger.get("allocations")
    if not isinstance(allocations, list) or not allocations:
        raise ReleaseError("allocations must be a non-empty array")
    ids: set[str] = set()
    recipients: set[str] = set()
    total = 0
    grants = load_vesting(vesting_path) if vesting_path else {}
    for index, allocation in enumerate(allocations):
        if not isinstance(allocation, dict):
            raise ReleaseError(f"allocation {index} must be an object")
        allocation_id = allocation.get("allocationId")
        if not isinstance(allocation_id, str) or not allocation_id or allocation_id in ids:
            raise ReleaseError(f"duplicate or invalid allocationId: {allocation_id}")
        ids.add(allocation_id)
        recipient = require_address(allocation.get("recipient"), f"allocation[{allocation_id}].recipient")
        normalized = recipient.lower()
        if normalized in recipients:
            raise ReleaseError(f"duplicate allocation recipient: {recipient}")
        recipients.add(normalized)
        amount = strict_int(allocation.get("amountRaw"), f"allocation[{allocation_id}].amountRaw")
        if amount <= 0:
            raise ReleaseError(f"allocation {allocation_id} amount must be positive")
        total += amount
        category = str(allocation.get("category", "")).upper()
        vesting_required = allocation.get("vestingRequired", False)
        immediately_liquid = allocation.get("immediatelyLiquid", False)
        if not isinstance(vesting_required, bool) or not isinstance(immediately_liquid, bool):
            raise ReleaseError(f"allocation {allocation_id} vesting flags must be booleans")
        if category in {"TEAM VESTING", "PARTNER/INVESTOR VESTING"} and not immediately_liquid:
            if not vesting_required:
                raise ReleaseError(f"allocation {allocation_id} must use vesting")
            grant_id = allocation.get("vestingGrantId")
            grant = grants.get(grant_id)
            if grant is None:
                raise ReleaseError(f"missing vesting grant {grant_id} for allocation {allocation_id}")
            if require_address(grant.get("vestingContract"), f"grant[{grant_id}].vestingContract").lower() != normalized:
                raise ReleaseError(f"vesting recipient mismatch for allocation {allocation_id}")
            if strict_int(grant.get("amountRaw"), f"grant[{grant_id}].amountRaw") != amount:
                raise ReleaseError(f"vesting amount mismatch for allocation {allocation_id}")
    if total != TOTAL_SUPPLY_RAW:
        raise ReleaseError(f"ledger sum {total} does not equal fixed supply {TOTAL_SUPPLY_RAW}")
    required_categories = {
        "MIGRATION RESERVE",
        "TREASURY",
        "TEAM VESTING",
        "PARTNER/INVESTOR VESTING",
        "REWARDS/ECOSYSTEM",
        "LIQUIDITY AND MARKET MAKING",
        "STRATEGIC/CEX RESERVE",
    }
    present_categories = {str(item.get("category", "")).upper() for item in allocations}
    missing_categories = sorted(required_categories - present_categories)
    if missing_categories:
        raise ReleaseError(f"ledger is missing required categories: {', '.join(missing_categories)}")
    return ledger, allocations


def load_vesting(path: Path | None) -> dict[str, dict[str, Any]]:
    if path is None:
        return {}
    document = load_json(path)
    grants = document.get("grants")
    if not isinstance(grants, list):
        raise ReleaseError("vesting grants must be an array")
    result: dict[str, dict[str, Any]] = {}
    for grant in grants:
        grant_id = grant.get("grantId") if isinstance(grant, dict) else None
        if not isinstance(grant_id, str) or not grant_id or grant_id in result:
            raise ReleaseError(f"duplicate or invalid vesting grant: {grant_id}")
        require_address(grant.get("beneficiary"), f"grant[{grant_id}].beneficiary")
        require_address(grant.get("vestingContract"), f"grant[{grant_id}].vestingContract")
        amount = strict_int(grant.get("amountRaw"), f"grant[{grant_id}].amountRaw")
        start = strict_int(grant.get("start"), f"grant[{grant_id}].start")
        cliff = strict_int(grant.get("cliff"), f"grant[{grant_id}].cliff")
        duration = strict_int(grant.get("duration"), f"grant[{grant_id}].duration")
        if amount <= 0 or duration <= 0 or cliff > duration or start <= 0:
            raise ReleaseError(f"invalid vesting schedule for {grant_id}")
        if grant.get("auditedImplementationApproved") is not True:
            raise ReleaseError(f"vesting implementation is not approved for {grant_id}")
        result[grant_id] = grant
    return result


def load_holders(path: Path) -> list[dict[str, str]]:
    try:
        with path.open(newline="", encoding="utf-8") as handle:
            reader = csv.DictReader(handle)
            if tuple(reader.fieldnames or ()) != CSV_COLUMNS:
                raise ReleaseError("migration CSV columns do not match the required schema")
            rows = list(reader)
    except FileNotFoundError as exc:
        raise ReleaseError(f"file not found: {path}") from exc
    if not rows:
        raise ReleaseError("migration CSV must contain at least one holder")
    holder_ids: set[str] = set()
    addresses: set[str] = set()
    for row_number, row in enumerate(rows, start=2):
        holder_id = row["holderId"].strip()
        if not holder_id or holder_id in holder_ids:
            raise ReleaseError(f"duplicate or missing holderId at row {row_number}")
        holder_ids.add(holder_id)
        v1_address = require_address(row["v1Address"].strip(), f"row {row_number} v1Address")
        if v1_address.lower() in addresses:
            raise ReleaseError(f"duplicate V1 holder address at row {row_number}")
        addresses.add(v1_address.lower())
        recipient = row["v2Recipient"].strip() or v1_address
        require_address(recipient, f"row {row_number} v2Recipient")
        row["v2Recipient"] = recipient
        v1_raw = strict_int(row["v1RawAmount"].strip(), f"row {row_number} v1RawAmount")
        v2_raw = strict_int(row["v2RawAmount"].strip(), f"row {row_number} v2RawAmount")
        if v1_raw <= 0 or v2_raw != v1_raw * V1_TO_V2_SCALE:
            raise ReleaseError(f"inexact 12-to-18 decimal conversion at row {row_number}")
        if row["conversionRate"].strip() != "1000000":
            raise ReleaseError(f"conversionRate must be 1000000 at row {row_number}")
        if row["migrationMethod"].strip() not in {
            "SELF_SERVICE",
            "OPERATOR_ASSISTED",
            "PROJECT_CONTROLLED_WALLET",
        }:
            raise ReleaseError(f"invalid migrationMethod at row {row_number}")
        if not row["batch"].strip():
            raise ReleaseError(f"batch is required at row {row_number}")
    return rows


def action_id(chain_id: int, stage: str, recipient: str, amount: int, source_version: str) -> str:
    require_address(recipient, "action recipient")
    encoded = run(
        [
            "cast",
            "abi-encode",
            "f(uint256,string,address,uint256,string)",
            str(chain_id),
            stage,
            recipient,
            str(amount),
            source_version,
        ]
    )
    return run(["cast", "keccak", encoded])


def erc20_transfer_data(recipient: str, amount: int) -> str:
    address_word = recipient[2:].lower().rjust(64, "0")
    amount_word = hex(amount)[2:].rjust(64, "0")
    return "0xa9059cbb" + address_word + amount_word


def safe_batch(chain_id: int, safe: str, name: str, transactions: Iterable[dict[str, Any]]) -> dict[str, Any]:
    require_address(safe, "Safe address")
    return {
        "version": "1.0",
        "chainId": str(chain_id),
        "createdAt": now_utc(),
        "meta": {
            "name": name,
            "description": "Generated by ./bin/bini-v2",
            "txBuilderVersion": "1.18.0",
            "createdFromSafeAddress": safe,
        },
        "transactions": list(transactions),
    }


def timelock_package(
    context: Context,
    deployment: dict[str, Any],
    name: str,
    calls: list[dict[str, Any]],
    salt_source: str,
) -> dict[str, Any]:
    if not calls:
        raise ReleaseError("cannot create an empty Timelock operation")
    targets = "[" + ",".join(require_address(item["to"], "Timelock target") for item in calls) + "]"
    values = "[" + ",".join(str(strict_int(item.get("value", 0), "Timelock value")) for item in calls) + "]"
    datas = "[" + ",".join(item["data"] for item in calls) + "]"
    salt = run(["cast", "keccak", f"BINI_V2:{context.chain_id}:{name}:{salt_source}"])
    delay = strict_int(context.config["timelockMinDelay"], "timelockMinDelay")
    schedule_data = run(
        [
            "cast",
            "calldata",
            "scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)",
            targets,
            values,
            datas,
            ZERO_HASH,
            salt,
            str(delay),
        ]
    )
    execute_data = run(
        [
            "cast",
            "calldata",
            "executeBatch(address[],uint256[],bytes[],bytes32,bytes32)",
            targets,
            values,
            datas,
            ZERO_HASH,
            salt,
        ]
    )
    encoded_operation = run(
        [
            "cast",
            "abi-encode",
            "f(address[],uint256[],bytes[],bytes32,bytes32)",
            targets,
            values,
            datas,
            ZERO_HASH,
            salt,
        ]
    )
    operation_id = run(["cast", "keccak", encoded_operation])
    timelock = deployment["timelock"]
    schedule_tx = {
        "to": timelock,
        "value": "0",
        "data": schedule_data,
        "contractMethod": None,
        "contractInputsValues": None,
    }
    execute_tx = {
        "to": timelock,
        "value": "0",
        "data": execute_data,
        "contractMethod": None,
        "contractInputsValues": None,
    }
    return {
        "operationId": operation_id,
        "salt": salt,
        "predecessor": ZERO_HASH,
        "minimumDelaySeconds": delay,
        "calls": calls,
        "scheduleProposal": safe_batch(
            context.chain_id, context.config["timelockProposerSafe"], f"Schedule {name}", [schedule_tx]
        ),
        "executeProposal": safe_batch(
            context.chain_id, context.config["timelockExecutorSafe"], f"Execute {name}", [execute_tx]
        ),
    }


def validate_distribution_destinations(
    context: Context, deployment: dict[str, Any], allocations: list[dict[str, Any]]
) -> None:
    expected = {
        "MIGRATION RESERVE": deployment["migrationVault"],
        "TREASURY": context.config["treasurySafe"],
        "REWARDS/ECOSYSTEM": context.config["rewardsSafe"],
        "LIQUIDITY AND MARKET MAKING": context.config["liquiditySafe"],
        "STRATEGIC/CEX RESERVE": context.config["strategicReserveSafe"],
    }
    for allocation in allocations:
        category = str(allocation["category"]).upper()
        if category in expected and allocation["recipient"].lower() != expected[category].lower():
            raise ReleaseError(
                f"{allocation['allocationId']} destination does not match the approved {category} custody address"
            )


def deployment_file(network: str) -> Path:
    return artifact_path("deployments", network, "deployment.json")


def load_deployment(network: str) -> dict[str, Any]:
    path = deployment_file(network)
    deployment = load_json(path)
    for key in ("proxy", "migrationVault", "timelock"):
        require_address(deployment.get(key), f"deployment.{key}")
    return deployment


def inspect_hash(contract: str, field: str) -> str:
    return run(["cast", "keccak", run(["forge", "inspect", contract, field])])


def check_bytecode_hashes(config: dict[str, Any]) -> None:
    expected = {
        "BiniTokenV2": config.get("expectedTokenCreationBytecodeHash"),
        "BiniMigrationVault": config.get("expectedVaultCreationBytecodeHash"),
    }
    for contract, expected_hash in expected.items():
        if not isinstance(expected_hash, str) or inspect_hash(contract, "bytecode") != expected_hash:
            raise ReleaseError(f"creation bytecode hash mismatch for {contract}")


def dependency_shas() -> dict[str, str]:
    result = {}
    for name in ("openzeppelin-contracts", "openzeppelin-contracts-upgradeable", "forge-std"):
        result[name] = run(["git", "-C", str(ROOT / "lib" / name), "rev-parse", "HEAD"])
    return result


def manifest_from_broadcast(context: Context, evidence: dict[str, Any]) -> dict[str, Any]:
    receipt_path = ROOT / "broadcast" / "DeployBiniV2.s.sol" / str(context.chain_id) / "run-latest.json"
    receipt = load_json(receipt_path)
    transactions = receipt.get("transactions")
    receipts = receipt.get("receipts")
    if not isinstance(transactions, list) or not isinstance(receipts, list) or not receipts:
        raise ReleaseError(f"incomplete Foundry broadcast receipt: {receipt_path}")
    addresses: dict[str, str] = {}
    transaction_hashes: list[str] = []
    for transaction in transactions:
        if not isinstance(transaction, dict):
            continue
        tx_hash = transaction.get("hash")
        if isinstance(tx_hash, str) and tx_hash not in transaction_hashes:
            transaction_hashes.append(tx_hash)
        name = transaction.get("contractName")
        address = transaction.get("contractAddress")
        if isinstance(name, str) and isinstance(address, str):
            if name == "BiniTokenV2" and "implementation" not in addresses:
                addresses["implementation"] = address
            elif name == "ERC1967Proxy":
                addresses["proxy"] = address
            elif name == "BiniMigrationVault":
                addresses["migrationVault"] = address
            elif name == "TimelockController":
                addresses["timelock"] = address
    for item in receipts:
        if isinstance(item, dict):
            tx_hash = item.get("transactionHash")
            if isinstance(tx_hash, str) and tx_hash not in transaction_hashes:
                transaction_hashes.append(tx_hash)
    required = {"implementation", "proxy", "migrationVault", "timelock"}
    if set(addresses) != required:
        raise ReleaseError(f"could not recover all deployment addresses from {receipt_path}: {addresses}")
    block_values = [receipt_int(item.get("blockNumber"), "receipt blockNumber") for item in receipts if isinstance(item, dict)]
    if not block_values:
        raise ReleaseError("broadcast has no confirmed receipt block")
    abi = run(["forge", "inspect", "BiniTokenV2", "abi", "--json"])
    storage = run(["forge", "inspect", "BiniTokenV2", "storageLayout", "--json"])
    block_number = max(block_values)
    block = load_json_from_output(
        run(["cast", "block", str(block_number), "--json", "--rpc-url", context.rpc_url]),
        "confirmed deployment block",
    )
    block_timestamp = receipt_int(block.get("timestamp"), "deployment block timestamp")
    manifest = {
        "chainId": context.chain_id,
        "network": context.network,
        "deploymentTimestamp": dt.datetime.fromtimestamp(block_timestamp, dt.timezone.utc).replace(microsecond=0).isoformat(),
        "deploymentBlock": block_number,
        "deployer": require_address(os.environ.get("DEPLOYER_ADDRESS"), "DEPLOYER_ADDRESS"),
        **addresses,
        "safes": {key: value for key, value in context.config.items() if key.endswith("Safe")},
        "transactionHashes": transaction_hashes,
        "compilerVersion": "0.8.24",
        "foundryVersion": evidence["foundryVersion"],
        "openzeppelinDependencyShas": dependency_shas(),
        "creationBytecodeHash": inspect_hash("BiniTokenV2", "bytecode"),
        "runtimeBytecodeHash": runtime_code_hash(context, addresses["implementation"], "token implementation"),
        "buildRuntimeBytecodeHash": inspect_hash("BiniTokenV2", "deployedBytecode"),
        "abiHash": run(["cast", "keccak", abi]),
        "storageLayoutHash": run(["cast", "keccak", storage]),
        "gitCommit": evidence["gitCommit"],
        "workingTreeStatus": "clean",
        "broadcastReceipt": str(receipt_path.relative_to(ROOT)),
    }
    verify_recorded_deployment(context, manifest)
    genesis_balance = strict_int(
        call_args(
            context,
            manifest["proxy"],
            "balanceOf(address)(uint256)",
            context.config["genesisDistributionSafe"],
        ),
        "Genesis balance",
    )
    if genesis_balance != TOTAL_SUPPLY_RAW:
        raise ReleaseError("Genesis Safe did not receive the complete fixed supply")
    return manifest


def verify_recorded_deployment(context: Context, deployment: dict[str, Any]) -> None:
    for key in ("implementation", "proxy", "migrationVault", "timelock"):
        address = require_address(deployment.get(key), f"deployment.{key}")
        if run(["cast", "code", address, "--rpc-url", context.rpc_url]) in ("", "0x"):
            raise ReleaseError(f"recorded deployment has no code at {key}: {address}")
    if call(context, deployment["proxy"], "marketOpen()(bool)").lower() != "false":
        raise ReleaseError("recorded deployment is not in PRE_MARKET")
    if strict_int(call(context, deployment["proxy"], "totalSupply()(uint256)"), "total supply") != TOTAL_SUPPLY_RAW:
        raise ReleaseError("recorded deployment has incorrect total supply")
    if call(context, deployment["proxy"], "defaultAdmin()(address)").lower() != deployment["timelock"].lower():
        raise ReleaseError("token default admin is not the recorded Timelock")
    delay = strict_int(call(context, deployment["timelock"], "getMinDelay()(uint256)"), "Timelock delay")
    if delay != strict_int(context.config["timelockMinDelay"], "configured Timelock delay"):
        raise ReleaseError("recorded Timelock delay does not match config")
    if call(context, deployment["migrationVault"], "v2Token()(address)").lower() != deployment["proxy"].lower():
        raise ReleaseError("migration vault is linked to the wrong V2 token")
    if call(context, deployment["migrationVault"], "v1Token()(address)").lower() != context.config["biniV1Token"].lower():
        raise ReleaseError("migration vault is linked to the wrong V1 token")
    implementation_word = run(
        [
            "cast",
            "storage",
            deployment["proxy"],
            ERC1967_IMPLEMENTATION_SLOT,
            "--rpc-url",
            context.rpc_url,
        ]
    )
    implementation_from_slot = "0x" + implementation_word[-40:]
    if implementation_from_slot.lower() != deployment["implementation"].lower():
        raise ReleaseError("ERC-1967 implementation slot does not match deployment manifest")
    implementation_runtime_hash = runtime_code_hash(context, deployment["implementation"], "token implementation")
    expected_runtime_hash = deployment.get("runtimeBytecodeHash")
    if isinstance(expected_runtime_hash, str) and implementation_runtime_hash.lower() != expected_runtime_hash.lower():
        raise ReleaseError("token implementation runtime hash mismatch")
    role_bindings = (
        ("UPGRADER_ROLE()(bytes32)", deployment["timelock"]),
        ("MARKET_MANAGER_ROLE()(bytes32)", deployment["timelock"]),
        ("UNPAUSER_ROLE()(bytes32)", deployment["timelock"]),
        ("PAUSER_ROLE()(bytes32)", context.config["emergencyPauserSafe"]),
    )
    for role_signature, account in role_bindings:
        role = call(context, deployment["proxy"], role_signature)
        if call_args(context, deployment["proxy"], "hasRole(bytes32,address)(bool)", role, account).lower() != "true":
            raise ReleaseError(f"missing token role {role_signature} for {account}")
    vault_admin_role = call(context, deployment["migrationVault"], "DEFAULT_ADMIN_ROLE()(bytes32)")
    if (
        call_args(
            context,
            deployment["migrationVault"],
            "hasRole(bytes32,address)(bool)",
            vault_admin_role,
            deployment["timelock"],
        ).lower()
        != "true"
    ):
        raise ReleaseError("Timelock does not hold migration vault admin role")
    initializer_data = run(
        [
            "cast",
            "calldata",
            "initialize(address,address,address,uint48)",
            deployment["timelock"],
            context.config["emergencyPauserSafe"],
            context.config["genesisDistributionSafe"],
            str(context.config["adminTransferDelay"]),
        ]
    )
    for target in (deployment["implementation"], deployment["proxy"]):
        if not command_reverts(["cast", "call", target, initializer_data, "--rpc-url", context.rpc_url]):
            raise ReleaseError(f"initializer replay unexpectedly succeeded for {target}")


def preflight(context: Context, *, require_rpc: bool) -> dict[str, Any]:
    validate_config(context)
    if context.config.get("illustrativeInputs") is not False:
        raise ReleaseError("configuration still contains illustrative inputs")
    required = ("forge", "cast", "git")
    for executable in required:
        if shutil.which(executable) is None:
            raise ReleaseError(f"required executable not found: {executable}")
    status = run(["git", "status", "--porcelain"])
    if status:
        raise ReleaseError("Git working tree is dirty")
    head = run(["git", "rev-parse", "HEAD"])
    expected = os.environ.get("EXPECTED_GIT_COMMIT") or context.config.get("expectedGitCommit")
    if not isinstance(expected, str) or expected != head:
        raise ReleaseError("config.expectedGitCommit must exactly match HEAD")
    check_bytecode_hashes(context.config)
    result: dict[str, Any] = {
        "network": context.network,
        "chainId": context.chain_id,
        "gitCommit": head,
        "foundryVersion": run(["forge", "--version"]).splitlines()[0],
        "compilerVersion": "0.8.24",
        "checkedAt": now_utc(),
    }
    if require_rpc:
        actual_chain = strict_int(run(["cast", "chain-id", "--rpc-url", context.rpc_url]), "RPC chain ID")
        if actual_chain != context.chain_id:
            raise ReleaseError(f"RPC chain ID {actual_chain} does not match config {context.chain_id}")
        result["rpcChainId"] = actual_chain
        check_safe_contracts(context)
        deployer = require_address(os.environ.get("DEPLOYER_ADDRESS"), "DEPLOYER_ADDRESS")
        balance = strict_int(run(["cast", "balance", deployer, "--rpc-url", context.rpc_url]), "deployer balance")
        minimum = strict_int(context.config["minDeployerBalanceWei"], "minDeployerBalanceWei")
        if balance < minimum:
            raise ReleaseError(f"deployer balance {balance} is below required minimum {minimum}")
        result["deployer"] = deployer
        result["deployerBalanceWei"] = str(balance)
    return result


def check_safe_contracts(context: Context) -> None:
    for safe, expected_threshold in context.config["safeThresholds"].items():
        code = run(["cast", "code", safe, "--rpc-url", context.rpc_url])
        if code in ("", "0x"):
            raise ReleaseError(f"Safe has no contract code: {safe}")
        actual = strict_int(call(context, safe, "getThreshold()(uint256)"), f"Safe threshold {safe}")
        if actual != strict_int(expected_threshold, f"Safe threshold {safe}"):
            raise ReleaseError(f"Safe threshold mismatch for {safe}: expected {expected_threshold}, got {actual}")


def check_contract_code(context: Context, address: str, field: str) -> None:
    require_address(address, field)
    if run(["cast", "code", address, "--rpc-url", context.rpc_url]) in ("", "0x"):
        raise ReleaseError(f"{field} has no contract code: {address}")


def runtime_code_hash(context: Context, address: str, field: str) -> str:
    code = run(["cast", "code", require_address(address, field), "--rpc-url", context.rpc_url])
    if code in ("", "0x"):
        raise ReleaseError(f"{field} has no contract code: {address}")
    return run(["cast", "keccak", code])


def dex_configuration_calls(context: Context, token: str, *, only_pending: bool) -> list[dict[str, Any]]:
    calls: list[dict[str, Any]] = []
    kind_values = {"UNISWAP_V2": 1, "UNISWAP_V3": 2}
    for entry in context.config["dexPolicy"]["factories"]:
        expected_hash = entry["runtimeCodeHash"].lower()
        if only_pending:
            actual_hash = runtime_code_hash(context, entry["address"], f"DEX factory {entry['name']}")
            if actual_hash.lower() != expected_hash:
                raise ReleaseError(f"runtime code hash mismatch for DEX factory {entry['name']}")
            current = strict_int(
                call_args(context, token, "dexFactoryKind(address)(uint8)", entry["address"]),
                f"factory kind {entry['name']}",
            )
            if current == kind_values[entry["kind"]]:
                continue
        data = run(
            [
                "cast",
                "calldata",
                "setDexFactory(address,uint8)",
                entry["address"],
                str(kind_values[entry["kind"]]),
            ]
        )
        calls.append({"name": entry["name"], "to": token, "value": "0", "data": data})
    pending_infrastructure = []
    for entry in context.config["dexPolicy"]["infrastructure"]:
        expected_hash = entry["runtimeCodeHash"].lower()
        if only_pending:
            actual_hash = runtime_code_hash(context, entry["address"], f"DEX infrastructure {entry['name']}")
            if actual_hash.lower() != expected_hash:
                raise ReleaseError(f"runtime code hash mismatch for DEX infrastructure {entry['name']}")
            if call_args(context, token, "isMarketInfrastructure(address)(bool)", entry["address"]).lower() == "true":
                continue
        pending_infrastructure.append(entry["address"])
    if pending_infrastructure:
        addresses = "[" + ",".join(pending_infrastructure) + "]"
        data = run(["cast", "calldata", "setMarketInfrastructure(address[],bool)", addresses, "true"])
        calls.append({"name": "DEX infrastructure", "to": token, "value": "0", "data": data})
    return calls


def verify_dex_policy_onchain(context: Context, token: str) -> dict[str, Any]:
    if call(context, token, "marketOpen()(bool)").lower() != "false":
        raise ReleaseError("DEX policy verification requires PRE_MARKET")
    pending = dex_configuration_calls(context, token, only_pending=True)
    if pending:
        names = ", ".join(item["name"] for item in pending)
        raise ReleaseError(f"PRE_MARKET DEX policy is incomplete: {names}")
    return {
        "factories": [entry["address"] for entry in context.config["dexPolicy"]["factories"]],
        "infrastructure": [entry["address"] for entry in context.config["dexPolicy"]["infrastructure"]],
        "complete": True,
    }


def command_preflight(args: argparse.Namespace) -> None:
    context = load_context(args)
    evidence = preflight(context, require_rpc=True)
    ledger_path = ROOT / "data" / "bini-v2-supply-ledger.json"
    holders_path = ROOT / "data" / "v1-v2-known-holders.csv"
    vesting_path = ROOT / "data" / "vesting-grants.json"
    _, allocations = validate_ledger(ledger_path, vesting_path)
    for grant_id, grant in load_vesting(vesting_path).items():
        check_contract_code(context, grant["vestingContract"], f"vesting grant {grant_id}")
    rows = load_holders(holders_path)
    migration_reserve = sum(
        strict_int(item["amountRaw"], "migration reserve")
        for item in allocations
        if str(item["category"]).upper() == "MIGRATION RESERVE"
    )
    planned_migration = sum(strict_int(row["v2RawAmount"], "planned migration") for row in rows)
    if migration_reserve < planned_migration:
        raise ReleaseError("migration reserve does not cover all planned holders")
    evidence["ledgerHash"] = canonical_hash(ledger_path)
    evidence["migrationInputHash"] = canonical_hash(holders_path)
    evidence["migrationHolders"] = len(rows)
    print(json.dumps(evidence, indent=2, sort_keys=True))


def command_deploy(args: argparse.Namespace) -> None:
    context = load_context(args)
    if deployment_file(context.network).exists():
        deployment = load_deployment(context.network)
        if context.mode != "PLAN":
            verify_recorded_deployment(context, deployment)
        print(json.dumps({"status": "ALREADY_RECORDED", "deployment": deployment}, indent=2))
        return
    if context.mode == "PLAN":
        validate_config(context)
        print(json.dumps({"mode": "PLAN", "network": context.network, "stage": "DEPLOY", "config": str(context.config_path)}, indent=2))
        return
    evidence = preflight(context, require_rpc=True)
    env = os.environ.copy()
    mapping = {
        "BINI_V2_EXPECTED_CHAIN_ID": context.chain_id,
        "BINI_V2_TIMELOCK_MIN_DELAY": context.config["timelockMinDelay"],
        "BINI_V2_TIMELOCK_PROPOSER": context.config["timelockProposerSafe"],
        "BINI_V2_TIMELOCK_EXECUTOR": context.config["timelockExecutorSafe"],
        "BINI_V2_EMERGENCY_PAUSER_SAFE": context.config["emergencyPauserSafe"],
        "BINI_V2_GENESIS_DISTRIBUTION_SAFE": context.config["genesisDistributionSafe"],
        "BINI_V2_V1_TOKEN": context.config["biniV1Token"],
        "BINI_V2_ADMIN_TRANSFER_DELAY": context.config["adminTransferDelay"],
    }
    env.update({key: str(value) for key, value in mapping.items()})
    command = ["forge", "script", "script/DeployBiniV2.s.sol:DeployBiniV2", "--rpc-url", context.rpc_url, "-vvvv"]
    if context.mode == "BROADCAST":
        account = os.environ.get("DEPLOYER_ACCOUNT")
        if not account:
            raise ReleaseError("BROADCAST requires DEPLOYER_ACCOUNT pointing to an encrypted Foundry keystore")
        command.extend(["--broadcast", "--account", account])
    elif context.mode == "SAFE_PROPOSAL":
        raise ReleaseError("deployment is not a Safe-owned operation; use SIMULATE or separately authorized BROADCAST")
    run(command, env=env, capture=False)
    evidence["mode"] = context.mode
    evidence["note"] = "Simulation completed; BROADCAST receipts are in Foundry broadcast/ and must be imported before verify."
    if context.mode == "SIMULATE":
        checked_write(artifact_path("deployments", context.network, f"simulation-{int(dt.datetime.now().timestamp())}.json"), evidence)
    else:
        checked_write(deployment_file(context.network), manifest_from_broadcast(context, evidence))


def command_configure_market(args: argparse.Namespace) -> None:
    context = load_context(args)
    validate_config(context)
    deployment = load_deployment(context.network)
    token = deployment["proxy"]
    if context.mode == "BROADCAST":
        raise ReleaseError("DEX policy is Timelock-controlled; use SAFE_PROPOSAL and execute after the delay")
    if context.mode == "PLAN":
        calls = dex_configuration_calls(context, token, only_pending=False)
    else:
        preflight(context, require_rpc=True)
        verify_recorded_deployment(context, deployment)
        calls = dex_configuration_calls(context, token, only_pending=True)
        if not calls:
            print(json.dumps({"status": "DEX_POLICY_COMPLETE", "token": token}, indent=2))
            return
    policy_hash = "sha256:" + hashlib.sha256(
        json.dumps(context.config["dexPolicy"], sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    package = {
        "network": context.network,
        "chainId": context.chain_id,
        "policyHash": policy_hash,
        "token": token,
        "timelockPackage": timelock_package(
            context, deployment, "BINI V2 PRE_MARKET DEX policy", calls, policy_hash
        ),
        "postcondition": "All configured factories and infrastructure must be active while marketOpen() is false.",
    }
    if context.mode == "PLAN":
        print(json.dumps(package, indent=2, sort_keys=True))
        return
    output = artifact_path("deployments", context.network, f"pre-market-policy-{policy_hash.split(':')[1][:12]}.json")
    if output.exists():
        existing = load_json(output)
        if existing.get("policyHash") != policy_hash or existing.get("token", "").lower() != token.lower():
            raise ReleaseError("existing PRE_MARKET policy artifact is inconsistent")
        print(json.dumps({"status": "ALREADY_PLANNED", "artifact": str(output)}, indent=2))
        return
    checked_write(output, package)
    print(output)


def command_open_market(args: argparse.Namespace) -> None:
    context = load_context(args)
    validate_config(context)
    deployment = load_deployment(context.network)
    token = deployment["proxy"]
    if context.mode == "BROADCAST":
        raise ReleaseError("market opening is Timelock-controlled; use SAFE_PROPOSAL and execute after the delay")
    if context.mode != "PLAN":
        preflight(context, require_rpc=True)
        verify_recorded_deployment(context, deployment)
        verify_dex_policy_onchain(context, token)
    call_data = run(["cast", "calldata", "openMarket()"])
    deployment_identity = ":".join(
        (
            str(context.chain_id),
            token.lower(),
            str(deployment.get("deploymentBlock", "unknown")),
            str(deployment.get("gitCommit", "unknown")),
        )
    )
    package = {
        "network": context.network,
        "chainId": context.chain_id,
        "token": token,
        "lifecycleTransition": "PRE_MARKET_TO_OPEN_MARKET_IRREVERSIBLE",
        "timelockPackage": timelock_package(
            context,
            deployment,
            "BINI V2 OPEN_MARKET",
            [{"to": token, "value": "0", "function": "openMarket()", "data": call_data}],
            deployment_identity,
        ),
        "postconditions": [
            "marketOpen() == true",
            "marketState() == OPEN_MARKET",
            "transfers into former DEX destinations succeed",
            "a second openMarket() call reverts",
        ],
    }
    if context.mode == "PLAN":
        print(json.dumps(package, indent=2, sort_keys=True))
        return
    package_hash = hashlib.sha256(deployment_identity.encode()).hexdigest()[:12]
    output = artifact_path("deployments", context.network, f"open-market-{package_hash}.json")
    if output.exists():
        existing = load_json(output)
        if existing.get("token", "").lower() != token.lower():
            raise ReleaseError("existing OPEN_MARKET artifact is inconsistent")
        print(json.dumps({"status": "ALREADY_PLANNED", "artifact": str(output)}, indent=2))
        return
    checked_write(output, package)
    print(output)


def command_distribute(args: argparse.Namespace) -> None:
    context = load_context(args)
    ledger_path = Path(args.ledger)
    if not ledger_path.is_absolute():
        ledger_path = ROOT / ledger_path
    vesting_path = Path(args.vesting)
    if not vesting_path.is_absolute():
        vesting_path = ROOT / vesting_path
    ledger, allocations = validate_ledger(ledger_path, vesting_path)
    if deployment_file(context.network).exists():
        deployment = load_deployment(context.network)
        token = require_address(deployment["proxy"], "deployment.proxy")
    elif context.mode == "PLAN":
        token = ZERO_ADDRESS
    else:
        raise ReleaseError("confirmed deployment manifest is required")
    transactions = []
    actions = []
    for allocation in allocations:
        recipient = allocation["recipient"]
        amount = strict_int(allocation["amountRaw"], "amountRaw")
        identifier = action_id(context.chain_id, "DISTRIBUTION", recipient, amount, ledger["ledgerVersion"])
        actions.append({**allocation, "actionId": identifier})
        transactions.append(
            {
                "to": token,
                "value": "0",
                "data": erc20_transfer_data(recipient, amount),
                "contractMethod": {"inputs": [{"name": "to", "type": "address"}, {"name": "value", "type": "uint256"}], "name": "transfer", "payable": False},
                "contractInputsValues": {"to": recipient, "value": str(amount)},
            }
        )
    plan = {
        "mode": context.mode,
        "network": context.network,
        "chainId": context.chain_id,
        "ledgerVersion": ledger["ledgerVersion"],
        "ledgerHash": canonical_hash(ledger_path),
        "sourceSafe": context.config["genesisDistributionSafe"],
        "recipientCount": len(actions),
        "totalRaw": str(sum(strict_int(item["amountRaw"], "amountRaw") for item in allocations)),
        "actions": actions,
    }
    if context.mode == "PLAN":
        print(json.dumps(plan, indent=2, sort_keys=True))
        return
    if context.config.get("illustrativeInputs") is not False or ledger.get("illustrativeInputs") is not False:
        raise ReleaseError("configuration or ledger still contains illustrative inputs")
    validate_distribution_destinations(context, deployment, allocations)
    if context.mode == "BROADCAST":
        raise ReleaseError("Genesis funds are Safe-controlled; use SAFE_PROPOSAL and execute at the Safe threshold")
    if context.mode in {"SIMULATE", "SAFE_PROPOSAL"}:
        preflight(context, require_rpc=True)
        verify_dex_policy_onchain(context, token)
        for grant_id, grant in load_vesting(vesting_path).items():
            check_contract_code(context, grant["vestingContract"], f"vesting grant {grant_id}")
        plan["simulation"] = "calldata validated; execute the generated Safe batch in a Sepolia fork/Safe simulation"
    proposal = safe_batch(context.chain_id, context.config["genesisDistributionSafe"], f"BINI V2 distribution {ledger['ledgerVersion']}", transactions)
    package = {"plan": plan, "safeTransactionBuilder": proposal}
    output = artifact_path("distributions", context.network, f"distribution-{ledger['ledgerVersion']}.json")
    if output.exists():
        existing = load_json(output)
        existing_plan = existing.get("plan", {})
        if (
            not isinstance(existing_plan, dict)
            or existing_plan.get("ledgerHash") != plan["ledgerHash"]
            or existing_plan.get("chainId") != context.chain_id
            or existing_plan.get("sourceSafe", "").lower() != plan["sourceSafe"].lower()
        ):
            raise ReleaseError("existing distribution artifact is inconsistent with current inputs")
        print(json.dumps({"status": "ALREADY_PLANNED", "artifact": str(output)}, indent=2))
        return
    checked_write(output, package)
    print(output)


def migration_actions(context: Context, rows: list[dict[str, str]], source_hash: str) -> list[dict[str, Any]]:
    actions = []
    for row in rows:
        amount = strict_int(row["v2RawAmount"], "v2RawAmount")
        actions.append(
            {
                **row,
                "actionId": action_id(context.chain_id, "MIGRATION", row["v2Recipient"], amount, source_hash),
            }
        )
    return actions


def command_migration_plan(args: argparse.Namespace) -> None:
    context = load_context(args)
    holders_path = Path(args.holders)
    if not holders_path.is_absolute():
        holders_path = ROOT / holders_path
    rows = load_holders(holders_path)
    source_hash = canonical_hash(holders_path)
    actions = migration_actions(context, rows, source_hash)
    batches: dict[str, list[dict[str, Any]]] = {}
    for action in actions:
        batches.setdefault(action["batch"], []).append(action)
    for batch_id, batch in batches.items():
        if len(batch) > 20:
            raise ReleaseError(f"batch {batch_id} has {len(batch)} holders; maximum is 20 before gas simulation")
    deployment = load_deployment(context.network) if deployment_file(context.network).exists() else None
    vault = deployment["migrationVault"] if deployment else ZERO_ADDRESS
    governance_calls = []
    for batch_id, batch in batches.items():
        holders = "[" + ",".join(item["v1Address"] for item in batch) + "]"
        amounts = "[" + ",".join(item["v1RawAmount"] for item in batch) + "]"
        action_ids = "[" + ",".join(item["actionId"] for item in batch) + "]"
        governance_calls.append(
            {
                "batchId": batch_id,
                "to": vault,
                "value": "0",
                "function": "setEntitlements(address[],uint256[],bytes32[])",
                "data": run(
                    [
                        "cast",
                        "calldata",
                        "setEntitlements(address[],uint256[],bytes32[])",
                        holders,
                        amounts,
                        action_ids,
                    ]
                ),
            }
        )
    governance_calls.append(
        {
            "batchId": "seal-after-all-entitlements-and-reserve-funding",
            "to": vault,
            "value": "0",
            "function": "sealEntitlements()",
            "data": run(["cast", "calldata", "sealEntitlements()"]),
        }
    )
    plan = {
        "network": context.network,
        "chainId": context.chain_id,
        "inputFileHash": source_hash,
        "holderCount": len(actions),
        "totalV1Raw": str(sum(strict_int(row["v1RawAmount"], "v1RawAmount") for row in rows)),
        "totalV2Raw": str(sum(strict_int(row["v2RawAmount"], "v2RawAmount") for row in rows)),
        "batches": batches,
        "governanceCalls": governance_calls,
        "governanceRequired": "Timelock must set all entitlements and seal only after exact V2 reserve funding.",
    }
    if deployment:
        plan["timelockPackage"] = timelock_package(
            context,
            deployment,
            "BINI V1 holder entitlements",
            governance_calls,
            source_hash,
        )
    output = artifact_path("migrations", context.network, f"migration-plan-{source_hash.split(':')[1][:12]}.json")
    if context.mode == "PLAN":
        print(json.dumps(plan, indent=2, sort_keys=True))
    else:
        if deployment is None:
            raise ReleaseError("confirmed deployment manifest is required")
        preflight(context, require_rpc=True)
        checked_write(output, plan)
        print(output)


def command_migrate(args: argparse.Namespace) -> None:
    context = load_context(args)
    holders_path = Path(args.holders)
    if not holders_path.is_absolute():
        holders_path = ROOT / holders_path
    source_hash = canonical_hash(holders_path)
    rows = [row for row in load_holders(holders_path) if row["batch"] == args.batch]
    if not rows:
        raise ReleaseError(f"batch not found: {args.batch}")
    if deployment_file(context.network).exists():
        deployment = load_deployment(context.network)
        vault = deployment["migrationVault"]
    elif context.mode == "PLAN":
        vault = ZERO_ADDRESS
    else:
        raise ReleaseError("confirmed deployment manifest is required")
    calls = []
    for action in migration_actions(context, rows, source_hash):
        if action["v2Recipient"].lower() != action["v1Address"].lower():
            authorization = "REQUIRED_EIP712_OR_EIP1271_SIGNATURE"
            calldata = None
            deadline = "SET_BY_HOLDER_FOR_REPLACEMENT_RECIPIENT"
        else:
            authorization = "0x"
            deadline = "0"
            calldata = run(
                [
                    "cast",
                    "calldata",
                    "migrate(address,uint256,address,uint256,bytes)",
                    action["v1Address"],
                    action["v1RawAmount"],
                    action["v2Recipient"],
                    deadline,
                    authorization,
                ]
            )
        calls.append(
            {
                "actionId": action["actionId"],
                "holderId": action["holderId"],
                "method": action["migrationMethod"],
                "to": vault,
                "function": "migrate(address,uint256,address,uint256,bytes)",
                "data": calldata,
                "inputs": {
                    "holder": action["v1Address"],
                    "v1RawAmount": action["v1RawAmount"],
                    "recipient": action["v2Recipient"],
                    "deadline": deadline,
                    "recipientAuthorization": authorization,
                },
            }
        )
    package = {
        "network": context.network,
        "chainId": context.chain_id,
        "batchId": args.batch,
        "inputFileHash": source_hash,
        "recipientCount": len(calls),
        "totalV1Raw": str(sum(strict_int(row["v1RawAmount"], "v1RawAmount") for row in rows)),
        "totalV2Raw": str(sum(strict_int(row["v2RawAmount"], "v2RawAmount") for row in rows)),
        "calls": calls,
        "executionBoundary": "Holder approval/authorization is mandatory. The CLI never imports holder keys.",
    }
    if context.mode == "BROADCAST":
        raise ReleaseError("migration requires holder or Safe-native authorization; direct batch broadcast is forbidden")
    if context.mode == "PLAN":
        print(json.dumps(package, indent=2, sort_keys=True))
        return
    if context.config.get("illustrativeInputs") is not False:
        raise ReleaseError("configuration still contains illustrative inputs")
    pending = [row["holderId"] for row in rows if row["ownershipVerification"] not in {"VERIFIED", "SAFE_RECORD"}]
    if pending:
        raise ReleaseError(f"ownership verification is incomplete for: {', '.join(pending)}")
    if context.mode in {"SIMULATE", "SAFE_PROPOSAL"}:
        preflight(context, require_rpc=True)
        if call(context, vault, "entitlementsSealed()(bool)").lower() != "true":
            raise ReleaseError("migration entitlements are not sealed")
        pending_calls = []
        completed_holders = []
        for planned_call in calls:
            action = planned_call["actionId"]
            holder = planned_call["inputs"]["holder"]
            expected_v1 = strict_int(planned_call["inputs"]["v1RawAmount"], "planned V1 amount")
            configured = call_args(context, vault, "configuredActions(bytes32)(bool)", action).lower() == "true"
            recorded_action = call_args(context, vault, "migrationActionId(address)(bytes32)", holder)
            entitlement = strict_int(
                call_args(context, vault, "entitlementV1(address)(uint256)", holder), "on-chain entitlement"
            )
            if not configured or recorded_action.lower() != action.lower() or entitlement != expected_v1:
                raise ReleaseError(f"on-chain entitlement is inconsistent for {planned_call['holderId']}")
            completed = call_args(context, vault, "completedActions(bytes32)(bool)", action).lower() == "true"
            if completed:
                migrated = strict_int(
                    call_args(context, vault, "migratedV1(address)(uint256)", holder), "migrated V1"
                )
                if migrated != expected_v1:
                    raise ReleaseError(f"completed migration is inconsistent for {planned_call['holderId']}")
                completed_holders.append(planned_call["holderId"])
            else:
                pending_calls.append(planned_call)
        package["calls"] = pending_calls
        package["completedHoldersSkipped"] = completed_holders
        package["recipientCount"] = len(pending_calls)
    output = artifact_path("migrations", context.network, f"batch-{args.batch}-{source_hash.split(':')[1][:12]}.json")
    checked_write(output, package)
    print(output)


def call(context: Context, target: str, signature: str) -> str:
    output = run(["cast", "call", "--json", target, signature, "--rpc-url", context.rpc_url])
    return decode_cast_call(output, f"call {signature}")


def call_args(context: Context, target: str, signature: str, *args: str) -> str:
    output = run(["cast", "call", "--json", target, signature, *args, "--rpc-url", context.rpc_url])
    return decode_cast_call(output, f"call {signature}")


def command_verify(args: argparse.Namespace) -> None:
    context = load_context(args)
    deployment = load_deployment(context.network)
    preflight_evidence = preflight(context, require_rpc=True)
    token = deployment["proxy"]
    vault = deployment["migrationVault"]
    checks = {
        "name": call(context, token, "name()(string)"),
        "symbol": call(context, token, "symbol()(string)"),
        "decimals": call(context, token, "decimals()(uint8)"),
        "totalSupply": call(context, token, "totalSupply()(uint256)"),
        "marketOpen": call(context, token, "marketOpen()(bool)"),
        "vaultV1": call(context, vault, "v1Token()(address)"),
        "vaultV2": call(context, vault, "v2Token()(address)"),
        "totalLockedV1": call(context, vault, "totalLockedV1()(uint256)"),
        "totalReleasedV2": call(context, vault, "totalReleasedV2()(uint256)"),
    }
    if checks["name"] != "Binibit" or checks["symbol"] != "BINI":
        raise ReleaseError("token metadata mismatch")
    if strict_int(checks["decimals"], "token decimals") != 18:
        raise ReleaseError("token decimals mismatch")
    if strict_int(checks["totalSupply"], "total supply") != TOTAL_SUPPLY_RAW:
        raise ReleaseError("token supply mismatch")
    if checks["marketOpen"].lower() != "false":
        raise ReleaseError("PRE_MARKET is not active")
    if checks["vaultV2"].lower() != token.lower() or checks["vaultV1"].lower() != context.config["biniV1Token"].lower():
        raise ReleaseError("migration vault token link mismatch")
    released = strict_int(checks["totalReleasedV2"], "released V2")
    locked = strict_int(checks["totalLockedV1"], "locked V1")
    if released != locked * V1_TO_V2_SCALE:
        raise ReleaseError("migration reconciliation mismatch")
    dex_policy = verify_dex_policy_onchain(context, token)
    evidence = {
        "preflight": preflight_evidence,
        "deployment": deployment,
        "checks": checks,
        "dexPolicy": dex_policy,
        "verifiedAt": now_utc(),
    }
    output = artifact_path("verification", context.network, f"verification-{int(dt.datetime.now().timestamp())}.json")
    checked_write(output, evidence)
    print(output)


def command_status(args: argparse.Namespace) -> None:
    context = load_context(args)
    result: dict[str, Any] = {"network": context.network, "mode": context.mode, "artifacts": {}}
    for kind in ("deployments", "distributions", "migrations", "verification"):
        directory = ROOT / "artifacts" / kind / context.network
        result["artifacts"][kind] = sorted(str(path.relative_to(ROOT)) for path in directory.glob("*.json")) if directory.exists() else []
    if deployment_file(context.network).exists() and context.mode != "PLAN":
        deployment = load_deployment(context.network)
        result["onChain"] = {
            "marketOpen": call(context, deployment["proxy"], "marketOpen()(bool)"),
            "migrationLiability": call(context, deployment["migrationVault"], "remainingV2Liability()(uint256)"),
        }
        try:
            verify_dex_policy_onchain(context, deployment["proxy"])
            result["onChain"]["dexPolicy"] = "COMPLETE"
        except ReleaseError as exc:
            result["onChain"]["dexPolicy"] = f"INCOMPLETE: {exc}"
    print(json.dumps(result, indent=2, sort_keys=True))


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(prog="./bin/bini-v2", description="BINI V2 secure release workflow")
    commands = root.add_subparsers(dest="command", required=True)

    def common(name: str) -> argparse.ArgumentParser:
        command = commands.add_parser(name)
        command.add_argument("--network", required=True)
        command.add_argument("--config")
        command.add_argument("--mode", choices=MODES)
        return command

    common("preflight").set_defaults(handler=command_preflight)
    common("deploy").set_defaults(handler=command_deploy)
    common("configure-market").set_defaults(handler=command_configure_market)
    common("open-market").set_defaults(handler=command_open_market)
    distribute = common("distribute")
    distribute.add_argument("--ledger", required=True)
    distribute.add_argument("--vesting", default="data/vesting-grants.json")
    distribute.set_defaults(handler=command_distribute)
    migration_plan = common("migration-plan")
    migration_plan.add_argument("--holders", required=True)
    migration_plan.set_defaults(handler=command_migration_plan)
    migrate = common("migrate")
    migrate.add_argument("--holders", required=True)
    migrate.add_argument("--batch", required=True)
    migrate.set_defaults(handler=command_migrate)
    common("verify").set_defaults(handler=command_verify)
    common("status").set_defaults(handler=command_status)
    return root


def main() -> int:
    try:
        args = parser().parse_args()
        args.handler(args)
        return 0
    except ReleaseError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
