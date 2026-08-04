#!/usr/bin/env python3
"""Build an owner-reviewable BINI V1 -> V2 direct-distribution candidate table."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
from pathlib import Path
from typing import Any


POOL_MANAGER = "0x000000000004444c5dc75cb358380d2e3de08a90"
V1_TO_V2_SCALE = 1_000_000
DEFAULT_DRAFT_THRESHOLD_RAW = 1_000 * 10**12
MAX_BATCH_SIZE = 20


def exact_decimal(raw: int, decimals: int) -> str:
    whole, fraction = divmod(raw, 10**decimals)
    return f"{whole}.{fraction:0{decimals}d}"


def classify(holder: dict[str, Any]) -> tuple[str, str, str]:
    address = holder["address"].lower()
    label = holder.get("label") or ""
    if int(holder["rank"]) <= 5:
        return (
            "TOP5_OWNER_CLASSIFICATION_REQUIRED",
            "HOLD_OWNER_DECISION_REQUIRED",
            "Top-five balances represent 98.84% of V1 supply and cannot be treated as ordinary holder payouts without wallet ownership/tokenomics mapping.",
        )
    if address == POOL_MANAGER:
        return (
            "DEX_INFRASTRUCTURE",
            "EXCLUDE_DEX_INFRASTRUCTURE",
            "Uniswap V4 PoolManager balance is protocol liquidity/infrastructure, not a direct holder recipient.",
        )
    if "Binance Dep" in label or "ByBit Dep" in label:
        return (
            "CUSTODIAL_EXCHANGE_DEPOSIT",
            "HOLD_DESTINATION_PROOF_REQUIRED",
            "Exchange deposit addresses must not receive V2 without a signed alternate-destination instruction and custody review.",
        )
    if holder.get("isContract") and int(holder.get("codeBytes", 0)) == 23:
        return (
            "EIP7702_DELEGATED_ACCOUNT",
            "HOLD_ACCOUNT_CONTROL_REVIEW",
            "23-byte delegated account code requires control and destination review before inclusion.",
        )
    if holder.get("isContract"):
        return (
            "SMART_CONTRACT",
            "HOLD_CONTRACT_RECIPIENT_REVIEW",
            "Contract recipients require ownership, recovery and token-compatibility review.",
        )
    return (
        "EOA_CANDIDATE",
        "PENDING_OWNER_ELIGIBILITY_APPROVAL",
        "Ordinary EOA candidate; inclusion still depends on V1 deprecation, threshold policy and owner approval.",
    )


def build(snapshot: dict[str, Any], source_sha256: str, threshold_raw: int) -> dict[str, Any]:
    if snapshot.get("holderBalanceSumRaw") != snapshot.get("totalSupplyRaw"):
        raise ValueError("snapshot holder balances do not reconcile to total supply")
    if int(snapshot.get("holderCount", 0)) != len(snapshot.get("holders", [])):
        raise ValueError("snapshot holder count mismatch")

    records: list[dict[str, Any]] = []
    draft_candidates: list[dict[str, Any]] = []
    for holder in snapshot["holders"]:
        v1_raw = int(holder["balanceRaw"])
        holder_type, disposition, reason = classify(holder)
        draft_eligible = holder_type == "EOA_CANDIDATE" and v1_raw >= threshold_raw
        record = {
            "rank": int(holder["rank"]),
            "holderId": f"v1-mainnet-{int(holder['rank']):04d}",
            "legacyV1Address": holder["address"].lower(),
            "etherscanLabel": holder.get("label") or "",
            "holderType": holder_type,
            "isContractAtSnapshot": bool(holder.get("isContract")),
            "codeBytesAtSnapshot": int(holder.get("codeBytes", 0)),
            "v1RawAmount": str(v1_raw),
            "v1Amount": exact_decimal(v1_raw, 12),
            "v2RawAmount": str(v1_raw * V1_TO_V2_SCALE),
            "v2Amount": exact_decimal(v1_raw * V1_TO_V2_SCALE, 18),
            "conversionRule": "v2RawAmount = v1RawAmount * 1000000 (12->18 decimals)",
            "proposedDisposition": disposition,
            "dispositionReason": reason,
            "draftThresholdEligible": draft_eligible,
            "destinationAddress": holder["address"].lower() if draft_eligible else "",
            "addressOverride": False,
            "addressOverrideProofHash": "0x" + "0" * 64,
            "ownerDecision": "PENDING",
            "ownerDecisionReference": "",
            "draftBatch": "",
            "draftIndexInBatch": "",
            "sourceAllocationId": "OWNER_SELECTION_REQUIRED",
            "sourceSafe": "OWNER_SELECTION_REQUIRED",
            "status": "DRAFT_NOT_EXECUTABLE",
        }
        records.append(record)
        if draft_eligible:
            draft_candidates.append(record)

    for index, record in enumerate(draft_candidates):
        record["draftBatch"] = str(index // MAX_BATCH_SIZE + 1)
        record["draftIndexInBatch"] = str(index % MAX_BATCH_SIZE + 1)

    groups: dict[str, dict[str, Any]] = {}
    for record in records:
        group = groups.setdefault(record["holderType"], {"holderType": record["holderType"], "count": 0, "v1RawAmount": 0, "v2RawAmount": 0})
        group["count"] += 1
        group["v1RawAmount"] += int(record["v1RawAmount"])
        group["v2RawAmount"] += int(record["v2RawAmount"])
    summary = []
    for group in groups.values():
        summary.append({
            "holderType": group["holderType"],
            "count": group["count"],
            "v1RawAmount": str(group["v1RawAmount"]),
            "v1Amount": exact_decimal(group["v1RawAmount"], 12),
            "v2RawAmount": str(group["v2RawAmount"]),
            "v2Amount": exact_decimal(group["v2RawAmount"], 18),
        })

    draft_total_v1 = sum(int(record["v1RawAmount"]) for record in draft_candidates)
    return {
        "schemaVersion": "1.0",
        "status": "OWNER_REVIEW_DRAFT_NOT_EXECUTABLE",
        "sourceSnapshotSha256": f"sha256:{source_sha256}",
        "network": snapshot["network"],
        "chainId": snapshot["chainId"],
        "v1Token": snapshot["token"],
        "v1Decimals": snapshot["decimals"],
        "snapshotBlock": snapshot["snapshotBlock"],
        "snapshotBlockHash": snapshot["snapshotBlockHash"],
        "snapshotTimestamp": snapshot["snapshotTimestamp"],
        "snapshotHolderCount": snapshot["holderCount"],
        "snapshotTotalSupplyRaw": snapshot["totalSupplyRaw"],
        "draftScenario": {
            "name": "USER_SUPPLIED_TOP_TABLE_BOUNDARY_GE_1000_BINI",
            "minimumV1RawAmount": str(threshold_raw),
            "minimumV1Amount": exact_decimal(threshold_raw, 12),
            "eligibleHolderType": "EOA_CANDIDATE",
            "recipientCount": len(draft_candidates),
            "totalV1RawAmount": str(draft_total_v1),
            "totalV1Amount": exact_decimal(draft_total_v1, 12),
            "totalV2RawAmount": str(draft_total_v1 * V1_TO_V2_SCALE),
            "totalV2Amount": exact_decimal(draft_total_v1 * V1_TO_V2_SCALE, 18),
            "batchSizeLimit": MAX_BATCH_SIZE,
            "batchCount": (len(draft_candidates) + MAX_BATCH_SIZE - 1) // MAX_BATCH_SIZE,
            "approvalStatus": "NOT_APPROVED",
        },
        "classificationSummary": sorted(summary, key=lambda item: item["holderType"]),
        "records": records,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--snapshot", required=True, type=Path)
    parser.add_argument("--json-output", required=True, type=Path)
    parser.add_argument("--csv-output", required=True, type=Path)
    parser.add_argument("--draft-threshold-raw", default=str(DEFAULT_DRAFT_THRESHOLD_RAW))
    args = parser.parse_args()
    source_bytes = args.snapshot.read_bytes()
    snapshot = json.loads(source_bytes)
    result = build(snapshot, hashlib.sha256(source_bytes).hexdigest(), int(args.draft_threshold_raw))
    args.json_output.parent.mkdir(parents=True, exist_ok=True)
    args.csv_output.parent.mkdir(parents=True, exist_ok=True)
    args.json_output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    fieldnames = list(result["records"][0])
    with args.csv_output.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(result["records"])
    print(json.dumps({"json": str(args.json_output), "csv": str(args.csv_output), "draftScenario": result["draftScenario"]}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
