#!/usr/bin/env python3
"""Fail-closed direct holder distribution manifest and Safe package tooling."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path
from typing import Any

import rc3_automation as rc3

ROOT = Path(__file__).resolve().parents[1]
ZERO_ADDRESS = "0x" + "0" * 40
ZERO_HASH = "0x" + "0" * 64
ADDRESS_RE = re.compile(r"^0x[0-9a-fA-F]{40}$")
HASH_RE = re.compile(r"^(?:0x|sha256:)[0-9a-fA-F]{64}$")
TRANSFER_SELECTOR = "0xa9059cbb"
MAX_RECIPIENTS_PER_BATCH = 20
TOP_FIELDS = {
    "manifestVersion", "network", "chainId", "snapshotBlock", "snapshotBlockHash",
    "sourceAllocationId", "sourceSafe", "tokenProxy", "conversionRule", "recipientCount",
    "totalAmountRaw", "batchSizeLimit", "manifestHash", "ownerApprovalReference", "records",
}
RECORD_FIELDS = {
    "holderId", "legacyV1Address", "destinationAddress", "v1RawAmount", "v2RawAmount",
    "sourceAllocationId", "sourceSafe", "proofType", "addressOverride",
    "addressOverrideProofHash", "batch", "indexInBatch", "status",
}
ALLOCATION_TO_SAFE_PURPOSE = {
    "rewards-year-1": "REWARDS_Y1_SAFE",
    "rewards-year-2-reserve": "REWARDS_Y2_RESERVE_SAFE",
    "rewards-year-3-reserve": "REWARDS_Y3_RESERVE_SAFE",
    "rewards-year-4-reserve": "REWARDS_Y4_RESERVE_SAFE",
    "team-founders-reserve": "TEAM_FOUNDERS_RESERVE_SAFE",
    "marketing-operations": "MARKETING_OPERATIONS_SAFE",
    "marketing-milestone-reserve": "MARKETING_MILESTONE_RESERVE_SAFE",
    "ecosystem-reserve": "ECOSYSTEM_RESERVE_SAFE",
    "dex-liquidity-reserve": "LIQUIDITY_RESERVE_SAFE",
}


class DistributionError(rc3.RC3Error):
    pass


def _int(value: Any, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, (str, int)) or not str(value).isdigit():
        raise DistributionError(f"{field} must be an unsigned decimal integer")
    return int(value)


def _address(value: Any, field: str) -> str:
    if not isinstance(value, str) or not ADDRESS_RE.fullmatch(value) or value.lower() == ZERO_ADDRESS:
        raise DistributionError(f"{field} must be a nonzero Ethereum address")
    return value


def _hash(value: Any, field: str) -> str:
    if not isinstance(value, str) or not HASH_RE.fullmatch(value):
        raise DistributionError(f"{field} must be a 32-byte hash")
    return value


def load_manifest(path: str | Path) -> dict[str, Any]:
    resolved = Path(path)
    if not resolved.is_absolute():
        resolved = ROOT / resolved
    try:
        value = json.loads(resolved.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise DistributionError(f"cannot read distribution manifest {resolved}: {exc}") from exc
    if not isinstance(value, dict):
        raise DistributionError("distribution manifest must be a JSON object")
    return value


def manifest_hash(document: dict[str, Any]) -> str:
    frozen = {key: value for key, value in document.items() if key != "manifestHash"}
    encoded = json.dumps(frozen, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    return "sha256:" + hashlib.sha256(encoded).hexdigest()


def _forbidden_for_network(network: str) -> set[str]:
    forbidden: set[str] = set()
    paths = [
        ROOT / "artifacts" / "deployments" / network / "deployment.json",
        ROOT / "artifacts" / network / "infrastructure" / "timelock.json",
        ROOT / "artifacts" / network / "migration" / "vault.json",
    ]
    for path in paths:
        if path.is_file():
            value = json.loads(path.read_text(encoding="utf-8"))
            for key in ("proxy", "token", "timelock", "address"):
                candidate = value.get(key)
                if isinstance(candidate, str) and ADDRESS_RE.fullmatch(candidate):
                    forbidden.add(candidate.lower())
    policies = [
        ROOT / "config" / f"{network}.dex-policy.json",
        ROOT / "artifacts" / network / "rc3b" / "pre-market" / "dex-policy.runtime.json",
    ]
    for policy in policies:
        if policy.is_file():
            value = json.loads(policy.read_text(encoding="utf-8"))
            for group in ("factories", "infrastructure", "pools", "routers"):
                for item in value.get(group, []):
                    candidate = item.get("address") if isinstance(item, dict) else None
                    if isinstance(candidate, str) and ADDRESS_RE.fullmatch(candidate):
                        forbidden.add(candidate.lower())
    return forbidden


def validate_manifest(document: dict[str, Any], *, forbidden: set[str] | None = None) -> list[dict[str, Any]]:
    if set(document) != TOP_FIELDS:
        raise DistributionError(f"manifest fields mismatch; missing={sorted(TOP_FIELDS-set(document))}, extra={sorted(set(document)-TOP_FIELDS)}")
    if not isinstance(document["manifestHash"], str) or document["manifestHash"].lower() != manifest_hash(document).lower():
        raise DistributionError("manifestHash mismatch (manifest was changed after freeze)")
    if not isinstance(document["manifestVersion"], str) or not document["manifestVersion"].strip():
        raise DistributionError("manifestVersion is required")
    if document["network"] not in {"sepolia", "mainnet"}:
        raise DistributionError("network must be sepolia or mainnet")
    expected_chain = 11_155_111 if document["network"] == "sepolia" else 1
    if _int(document["chainId"], "chainId") != expected_chain:
        raise DistributionError("network/chainId mismatch")
    _int(document["snapshotBlock"], "snapshotBlock")
    _hash(document["snapshotBlockHash"], "snapshotBlockHash")
    source = _address(document["sourceSafe"], "sourceSafe")
    token = _address(document["tokenProxy"], "tokenProxy")
    if document["sourceAllocationId"] not in ALLOCATION_TO_SAFE_PURPOSE:
        raise DistributionError("sourceAllocationId is not one of the nine canonical allocations")
    if document["conversionRule"] != "v2RawAmount = v1RawAmount * 1000000 (12->18 decimals)":
        raise DistributionError("conversionRule is not the canonical exact 12->18 rule")
    limit = _int(document["batchSizeLimit"], "batchSizeLimit")
    if limit < 1 or limit > MAX_RECIPIENTS_PER_BATCH:
        raise DistributionError("batchSizeLimit must be between 1 and 20")
    records = document["records"]
    if not isinstance(records, list) or not records:
        raise DistributionError("records must be a non-empty array")
    if _int(document["recipientCount"], "recipientCount") != len(records):
        raise DistributionError("recipientCount does not equal records length")
    forbidden_addresses = {value.lower() for value in (forbidden or set())} | {source.lower(), token.lower()}
    seen_holders: set[str] = set()
    seen_legacy: set[str] = set()
    seen_destinations: set[str] = set()
    batches: dict[int, list[int]] = {}
    total = 0
    for position, record in enumerate(records):
        if not isinstance(record, dict) or set(record) != RECORD_FIELDS:
            raise DistributionError(f"record {position} fields mismatch")
        holder = record["holderId"]
        if not isinstance(holder, str) or not holder.strip() or holder in seen_holders:
            raise DistributionError(f"record {position} holderId is empty or duplicate")
        legacy = _address(record["legacyV1Address"], f"record {position} legacyV1Address")
        destination = _address(record["destinationAddress"], f"record {position} destinationAddress")
        if legacy.lower() in seen_legacy:
            raise DistributionError("duplicate legacyV1Address; pre-aggregate only with explicit owner review")
        if destination.lower() in seen_destinations:
            raise DistributionError("duplicate destinationAddress; pre-aggregate only with explicit owner review")
        if destination.lower() in forbidden_addresses:
            raise DistributionError(f"record {position} destinationAddress is forbidden")
        if record["sourceAllocationId"] != document["sourceAllocationId"] or str(record["sourceSafe"]).lower() != source.lower():
            raise DistributionError(f"record {position} source binding differs from manifest")
        v1 = _int(record["v1RawAmount"], f"record {position} v1RawAmount")
        v2 = _int(record["v2RawAmount"], f"record {position} v2RawAmount")
        if v1 <= 0 or v2 != v1 * 1_000_000:
            raise DistributionError(f"record {position} violates exact conversion")
        override = record["addressOverride"]
        if not isinstance(override, bool):
            raise DistributionError(f"record {position} addressOverride must be boolean")
        proof = _hash(record["addressOverrideProofHash"], f"record {position} addressOverrideProofHash")
        if override:
            if destination.lower() == legacy.lower() or proof.lower() in {ZERO_HASH, "sha256:" + "0" * 64}:
                raise DistributionError(f"record {position} override requires alternate address and signed proof hash")
        elif destination.lower() != legacy.lower() or proof.lower() not in {ZERO_HASH, "sha256:" + "0" * 64}:
            raise DistributionError(f"record {position} default destination/proof mismatch")
        if not isinstance(record["proofType"], str) or not record["proofType"].strip():
            raise DistributionError(f"record {position} proofType is required")
        if record["status"] != "PLANNED":
            raise DistributionError(f"record {position} status must be PLANNED before execution")
        batch = _int(record["batch"], f"record {position} batch")
        index = _int(record["indexInBatch"], f"record {position} indexInBatch")
        if batch < 1 or index < 1:
            raise DistributionError("batch and indexInBatch are one-based")
        batches.setdefault(batch, []).append(index)
        seen_holders.add(holder)
        seen_legacy.add(legacy.lower())
        seen_destinations.add(destination.lower())
        total += v2
    expected_batches = list(range(1, len(batches) + 1))
    if sorted(batches) != expected_batches:
        raise DistributionError("batch numbers must be contiguous from 1")
    for batch, indexes in batches.items():
        if len(indexes) > limit or indexes != list(range(1, len(indexes) + 1)):
            raise DistributionError(f"batch {batch} order/size is invalid")
    if _int(document["totalAmountRaw"], "totalAmountRaw") != total:
        raise DistributionError("totalAmountRaw does not equal record sum")
    if not isinstance(document["ownerApprovalReference"], str) or not document["ownerApprovalReference"].strip():
        raise DistributionError("ownerApprovalReference is required")
    return records


def grouped_records(document: dict[str, Any]) -> list[list[dict[str, Any]]]:
    records = validate_manifest(document, forbidden=_forbidden_for_network(document["network"]))
    batches: dict[int, list[dict[str, Any]]] = {}
    for record in records:
        batches.setdefault(int(record["batch"]), []).append(record)
    return [batches[index] for index in sorted(batches)]


def transfer_data(destination: str, amount: int) -> str:
    return TRANSFER_SELECTOR + destination[2:].lower().rjust(64, "0") + hex(amount)[2:].rjust(64, "0")


def _operational_preflight(document: dict[str, Any], network: str) -> tuple[str, int, dict[str, Any], dict[str, Any]]:
    validate_manifest(document, forbidden=_forbidden_for_network(network))
    if document["network"] != network:
        raise DistributionError("CLI network differs from manifest")
    if any(word in document["ownerApprovalReference"].upper() for word in ("EXAMPLE", "PLACEHOLDER", "TBD", "UNAPPROVED")):
        raise DistributionError("ownerApprovalReference is not production/testnet execution approval")
    deployment = rc3.default_deployment(network)
    safes = rc3.default_safes(network)
    token = rc3.token_address(deployment)
    if token.lower() != document["tokenProxy"].lower():
        raise DistributionError("manifest tokenProxy differs from canonical deployment")
    expected_safe = rc3.safe_by_purpose(safes, ALLOCATION_TO_SAFE_PURPOSE[document["sourceAllocationId"]])
    if expected_safe.lower() != document["sourceSafe"].lower():
        raise DistributionError("sourceAllocationId/sourceSafe does not match canonical Safe topology")
    rpc = rc3.rpc_url(network)
    chain = _int(rc3.run(["cast", "chain-id", "--rpc-url", rpc]), "RPC chain ID")
    if chain != int(document["chainId"]):
        raise DistributionError("RPC chain differs from manifest")
    balance = _int(rc3.cast_call(rpc, token, "balanceOf(address)(uint256)", document["sourceSafe"]), "source balance")
    if balance < int(document["totalAmountRaw"]):
        raise DistributionError("source Safe has insufficient BINI balance")
    return rpc, balance, deployment, safes


def build_plan(document: dict[str, Any]) -> dict[str, Any]:
    batches = grouped_records(document)
    return {
        "schemaVersion": "1.0", "mode": "PLAN", "network": document["network"],
        "chainId": document["chainId"], "manifestHash": document["manifestHash"],
        "sourceAllocationId": document["sourceAllocationId"], "sourceSafe": document["sourceSafe"],
        "tokenProxy": document["tokenProxy"], "recipientCount": len(document["records"]),
        "totalAmountRaw": document["totalAmountRaw"],
        "batches": [
            {"batchNumber": index, "recordRange": [batch[0]["holderId"], batch[-1]["holderId"]],
             "recipientCount": len(batch), "amountRaw": str(sum(int(r["v2RawAmount"]) for r in batch)),
             "calls": [{"to": document["tokenProxy"], "value": "0", "operation": "CALL",
                        "function": "transfer(address,uint256)", "destination": r["destinationAddress"],
                        "amountRaw": r["v2RawAmount"], "data": transfer_data(r["destinationAddress"], int(r["v2RawAmount"]))}
                       for r in batch]}
            for index, batch in enumerate(batches, 1)
        ],
        "broadcast": "DISABLED_SEPARATE_SAFE_REVIEW_REQUIRED",
    }


def command_validate(args: argparse.Namespace) -> None:
    document = load_manifest(args.manifest)
    validate_manifest(document, forbidden=_forbidden_for_network(document["network"]))
    print(json.dumps({"status": "VALID", "manifestHash": document["manifestHash"], "recipientCount": len(document["records"]), "totalAmountRaw": document["totalAmountRaw"]}, indent=2))


def command_plan(args: argparse.Namespace) -> None:
    if args.mode != "PLAN":
        raise DistributionError("holder-distribution plan supports only --mode PLAN")
    document = load_manifest(args.manifest)
    if document.get("network") != args.network:
        raise DistributionError("CLI network differs from manifest")
    print(json.dumps(build_plan(document), indent=2, sort_keys=True))


def command_simulate(args: argparse.Namespace) -> None:
    if args.network != "sepolia":
        raise DistributionError("holder distribution simulation is Sepolia-only")
    document = load_manifest(args.manifest)
    rpc, balance, _, _ = _operational_preflight(document, args.network)
    plan = build_plan(document)
    estimates = []
    for batch in plan["batches"]:
        gas = 0
        for call in batch["calls"]:
            estimate = rc3.run(["cast", "estimate", document["tokenProxy"], call["data"], "--from", document["sourceSafe"], "--rpc-url", rpc])
            gas += _int(estimate, "gas estimate")
        estimates.append({"batchNumber": batch["batchNumber"], "directCallGasEstimate": gas, "safeTransactionBytes": sum((len(c["data"])-2)//2 + 85 for c in batch["calls"])})
    print(json.dumps({"status": "SIMULATED", "manifestHash": document["manifestHash"], "sourceBalanceRaw": str(balance), "estimates": estimates, "warning": "Each Safe batch still requires separate eth_estimateGas after signatures."}, indent=2))


def _packages(document: dict[str, Any], safes: dict[str, Any]) -> list[dict[str, Any]]:
    multisend = {"address": safes["multiSend"], "runtimeCodeHash": safes["multiSendRuntimeCodeHash"]}
    packages = []
    for batch_number, records in enumerate(grouped_records(document), 1):
        calls = [rc3.safe_call(document["tokenProxy"], transfer_data(r["destinationAddress"], int(r["v2RawAmount"])), method={"name": "transfer", "payable": False, "inputs": [{"name": "to", "type": "address", "internalType": "address"}, {"name": "amount", "type": "uint256", "internalType": "uint256"}]}, inputs={"to": r["destinationAddress"], "amount": r["v2RawAmount"]}) for r in records]
        packages.append(rc3.safe_builder(int(document["chainId"]), document["sourceSafe"], f"BINI V2 direct holder distribution {document['manifestVersion']} batch {batch_number}", calls, multisend=multisend if len(calls) > 1 else None))
    return packages


def command_safe_proposals(args: argparse.Namespace) -> None:
    document = load_manifest(args.manifest)
    rpc, balance, deployment, safes = _operational_preflight(document, args.network)
    source_commit = rc3.run(["git", "rev-parse", "HEAD"])
    protected_commit = os.environ.get("BINI_DIRECT_DISTRIBUTION_PROTECTED_COMMIT", "")
    if protected_commit != source_commit:
        raise DistributionError("BINI_DIRECT_DISTRIBUTION_PROTECTED_COMMIT must equal the reviewed HEAD")
    if rc3.run(["git", "status", "--porcelain", "--untracked-files=all"]):
        raise DistributionError("source tree must be clean before Safe package generation")
    nonce = _int(rc3.cast_call(rpc, document["sourceSafe"], "nonce()(uint256)"), "Safe nonce")
    packages = _packages(document, safes)
    short = document["manifestHash"].split(":", 1)[1][:12]
    directory = ROOT / "artifacts" / args.network / "holder-distribution" / short
    directory.mkdir(parents=True, exist_ok=True)
    receipts_directory = directory / "receipts"
    if receipts_directory.exists() and any(receipts_directory.glob("*.json")):
        raise DistributionError("one or more manifest batches are already receipted; verify/recover instead of regenerating")
    outputs = []
    for index, package in enumerate(packages, 1):
        path = directory / f"batch-{index:03d}-safe-package.json"
        if path.exists():
            if json.loads(path.read_text()) != package:
                raise DistributionError(f"refusing to overwrite existing batch package: {path}")
        else:
            path.write_text(json.dumps(package, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        outputs.append({"batchNumber": index, "expectedSafeNonce": nonce + index - 1, "package": str(path.relative_to(ROOT))})
    recipient_balances = [{"holderId": record["holderId"], "destinationAddress": record["destinationAddress"], "balanceRaw": rc3.cast_call(rpc, document["tokenProxy"], "balanceOf(address)(uint256)", record["destinationAddress"])} for record in document["records"]]
    preflight = {"schemaVersion": "1.0", "network": args.network, "manifestHash": document["manifestHash"], "sourceCommit": source_commit, "sourceTreeClean": True, "sourceSafe": document["sourceSafe"], "sourceBalanceRaw": str(balance), "startingSafeNonce": nonce, "tokenProxy": document["tokenProxy"], "implementation": deployment["implementation"], "totalSupplyRaw": rc3.cast_call(rpc, document["tokenProxy"], "totalSupply()(uint256)"), "marketOpen": rc3.cast_call(rpc, document["tokenProxy"], "marketOpen()(bool)"), "paused": rc3.cast_call(rpc, document["tokenProxy"], "paused()(bool)"), "recipientBalances": recipient_balances, "packages": outputs, "mainnetExecution": "DISABLED_UNTIL_ALL_RELEASE_GATES_AND_EXPLICIT_OWNER_AUTHORIZATION"}
    path = directory / "preflight.json"
    if path.exists() and json.loads(path.read_text()) != preflight:
        raise DistributionError("Safe nonce/source state drifted; review existing proposal set before regeneration")
    if not path.exists():
        path.write_text(json.dumps(preflight, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(path)


def _decode_transfer_logs(receipt: dict[str, Any], token: str) -> list[tuple[str, str, int]]:
    topic = rc3.run(["cast", "keccak", "Transfer(address,address,uint256)"]).lower()
    transfers = []
    for log in receipt.get("rawReceipt", {}).get("logs", []):
        topics = log.get("topics", []) if isinstance(log, dict) else []
        if str(log.get("address", "")).lower() == token.lower() and len(topics) == 3 and str(topics[0]).lower() == topic:
            transfers.append(("0x" + str(topics[1])[-40:], "0x" + str(topics[2])[-40:], int(str(log.get("data", "0x0")), 16)))
    return transfers


def _call_at(rpc: str, token: str, signature: str, args: list[str], block: int) -> str:
    output = rc3.run(["cast", "call", "--json", token, signature, *args, "--block", str(block), "--rpc-url", rpc])
    try:
        value = json.loads(output)
    except json.JSONDecodeError:
        return output.strip()
    if isinstance(value, list) and len(value) == 1:
        return str(value[0]).lower() if isinstance(value[0], bool) else str(value[0])
    raise DistributionError(f"unexpected historical call result for {signature}")


def _balance_at(rpc: str, token: str, account: str, block: int) -> int:
    return _int(_call_at(rpc, token, "balanceOf(address)(uint256)", [account], block), "historical balance")


def _distribution_invariants(rpc: str, document: dict[str, Any], safes: dict[str, Any], block: int) -> dict[str, Any]:
    token = document["tokenProxy"]
    timelock = rc3.default_timelock(document["network"])["address"]
    security = rc3.safe_by_purpose(safes, "SECURITY_SAFE")
    roles = {
        "DEFAULT_ADMIN_ROLE": (ZERO_HASH, timelock),
        "UPGRADER_ROLE": (rc3.run(["cast", "keccak", "UPGRADER_ROLE"]), timelock),
        "UNPAUSER_ROLE": (rc3.run(["cast", "keccak", "UNPAUSER_ROLE"]), timelock),
        "MARKET_MANAGER_ROLE": (rc3.run(["cast", "keccak", "MARKET_MANAGER_ROLE"]), timelock),
        "PAUSER_ROLE": (rc3.run(["cast", "keccak", "PAUSER_ROLE"]), security),
    }
    implementation = rc3.run(["cast", "storage", token, "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc", "--block", str(block), "--rpc-url", rpc])
    return {
        "totalSupplyRaw": _call_at(rpc, token, "totalSupply()(uint256)", [], block),
        "marketOpen": _call_at(rpc, token, "marketOpen()(bool)", [], block),
        "paused": _call_at(rpc, token, "paused()(bool)", [], block),
        "implementationSlot": implementation,
        "roleBindings": {name: _call_at(rpc, token, "hasRole(bytes32,address)(bool)", [role, account], block) for name, (role, account) in roles.items()},
    }


def verify_receipts(document: dict[str, Any], receipts: list[dict[str, Any]], network: str, rpc: str, safes: dict[str, Any]) -> dict[str, Any]:
    packages = _packages(document, safes)
    if len(receipts) != len(packages):
        raise DistributionError("partial execution: exactly one receipt per manifest batch is required")
    receipt_hashes = [str(receipt.get("transactionHash", "")).lower() for receipt in receipts]
    if len(set(receipt_hashes)) != len(receipt_hashes):
        raise DistributionError("execution receipt reused")
    receipt_nonces = [_int(receipt.get("nonce"), f"receipt {index} nonce") for index, receipt in enumerate(receipts, 1)]
    if receipt_nonces != list(range(receipt_nonces[0], receipt_nonces[0] + len(receipt_nonces))):
        raise DistributionError("Safe nonce drift or missing batch receipt")
    all_expected = grouped_records(document)
    seen_txs: set[str] = set()
    executed = 0
    total = 0
    prior_nonce = None
    batch_reconciliation = []
    first_block = None
    last_block = None
    for index, (receipt, package, records) in enumerate(zip(receipts, packages, all_expected), 1):
        rc3.validate_safe_execution_receipt(receipt, network, rpc)
        if receipt["safe"].lower() != document["sourceSafe"].lower():
            raise DistributionError(f"batch {index} executed from unexpected Safe")
        tx_hash = receipt["transactionHash"].lower()
        if tx_hash in seen_txs:
            raise DistributionError("execution receipt reused")
        nonce = int(receipt["nonce"])
        if prior_nonce is not None and nonce != prior_nonce + 1:
            raise DistributionError("Safe nonce drift or missing batch receipt")
        expected_tx = rc3.normalize_safe_transaction(package, nonce)
        if receipt["transaction"] != expected_tx:
            raise DistributionError(f"batch {index} calldata/operation differs from frozen manifest")
        expected_events = [(document["sourceSafe"].lower(), r["destinationAddress"].lower(), int(r["v2RawAmount"])) for r in records]
        actual_events = [(a.lower(), b.lower(), c) for a, b, c in _decode_transfer_logs(receipt, document["tokenProxy"])]
        if actual_events != expected_events:
            raise DistributionError(f"batch {index} transfer-event reconciliation failed")
        block = int(receipt["blockNumber"])
        first_block = block if first_block is None else min(first_block, block)
        last_block = block if last_block is None else max(last_block, block)
        batch_amount = sum(int(r["v2RawAmount"]) for r in records)
        source_before = _balance_at(rpc, document["tokenProxy"], document["sourceSafe"], block - 1)
        source_after = _balance_at(rpc, document["tokenProxy"], document["sourceSafe"], block)
        if source_before - source_after != batch_amount:
            raise DistributionError(f"batch {index} source Safe balance delta mismatch")
        recipient_balances = []
        for record in records:
            before = _balance_at(rpc, document["tokenProxy"], record["destinationAddress"], block - 1)
            after = _balance_at(rpc, document["tokenProxy"], record["destinationAddress"], block)
            if after - before != int(record["v2RawAmount"]):
                raise DistributionError(f"batch {index} recipient balance delta mismatch: {record['holderId']}")
            recipient_balances.append({"holderId": record["holderId"], "destinationAddress": record["destinationAddress"], "beforeRaw": str(before), "afterRaw": str(after)})
        raw = receipt.get("rawReceipt", {})
        batch_reconciliation.append({
            "manifestHash": document["manifestHash"], "batchNumber": index,
            "recordRange": [records[0]["holderId"], records[-1]["holderId"]],
            "safe": receipt["safe"], "safeNonce": nonce, "safeTxHash": receipt["safeTxHash"],
            "signers": receipt["signers"], "executionTransactionHash": receipt["transactionHash"],
            "blockNumber": block, "gasUsed": str(int(str(raw.get("gasUsed", "0")), 0)),
            "transferEventCount": len(actual_events), "batchAmountRaw": str(batch_amount),
            "sourceBalanceBeforeRaw": str(source_before), "sourceBalanceAfterRaw": str(source_after),
            "recipientBalances": recipient_balances,
        })
        seen_txs.add(tx_hash)
        prior_nonce = nonce
        executed += len(records)
        total += sum(int(r["v2RawAmount"]) for r in records)
    if executed != int(document["recipientCount"]) or total != int(document["totalAmountRaw"]):
        raise DistributionError("executed count/total differs from manifest")
    assert first_block is not None and last_block is not None
    invariants_before = _distribution_invariants(rpc, document, safes, first_block - 1)
    invariants_after = _distribution_invariants(rpc, document, safes, last_block)
    if invariants_before != invariants_after:
        raise DistributionError("supply, market/pause state, roles, or implementation changed during distribution")
    return {"status": "VERIFIED_IDEMPOTENT", "manifestHash": document["manifestHash"], "executedRecipientCount": executed, "executedTotalRaw": str(total), "executionTransactions": sorted(seen_txs), "invariantsBefore": invariants_before, "invariantsAfter": invariants_after, "batches": batch_reconciliation}


def command_verify(args: argparse.Namespace) -> None:
    document = load_manifest(args.manifest)
    rpc, _, _, safes = _operational_preflight(document, args.network)
    directory = Path(args.receipts)
    if not directory.is_absolute():
        directory = ROOT / directory
    receipt_files = sorted(directory.glob("*.json"))
    if not receipt_files:
        raise DistributionError("receipt directory contains no JSON receipts")
    receipts = [json.loads(path.read_text(encoding="utf-8")) for path in receipt_files]
    print(json.dumps(verify_receipts(document, receipts, args.network, rpc, safes), indent=2, sort_keys=True))


def add_subcommands(commands: argparse._SubParsersAction[argparse.ArgumentParser]) -> None:
    root = commands.add_parser("holder-distribution")
    sub = root.add_subparsers(dest="holder_distribution_command", required=True)
    validate = sub.add_parser("validate")
    validate.add_argument("--manifest", required=True)
    validate.set_defaults(handler=command_validate)
    plan = sub.add_parser("plan")
    plan.add_argument("--network", choices=("sepolia", "mainnet"), required=True)
    plan.add_argument("--manifest", required=True)
    plan.add_argument("--mode", required=True)
    plan.set_defaults(handler=command_plan)
    simulate = sub.add_parser("simulate")
    simulate.add_argument("--network", choices=("sepolia",), required=True)
    simulate.add_argument("--manifest", required=True)
    simulate.set_defaults(handler=command_simulate)
    proposals = sub.add_parser("safe-proposals")
    proposals.add_argument("--network", choices=("sepolia", "mainnet"), required=True)
    proposals.add_argument("--manifest", required=True)
    proposals.set_defaults(handler=command_safe_proposals)
    verify = sub.add_parser("verify")
    verify.add_argument("--network", choices=("sepolia", "mainnet"), required=True)
    verify.add_argument("--manifest", required=True)
    verify.add_argument("--receipts", required=True)
    verify.set_defaults(handler=command_verify)
