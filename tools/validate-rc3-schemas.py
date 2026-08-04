#!/usr/bin/env python3
"""Validate RC3 schemas themselves and every recognized generated receipt."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker


ROOT = Path(__file__).resolve().parents[1]
SCHEMA_DIR = ROOT / "config"


def load_object(path: Path) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"JSON input must be a regular non-symlink file: {path}")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"JSON input must be an object: {path}")
    return value


def schema_for(path: Path, value: dict[str, Any]) -> str | None:
    name = path.name
    keys = set(value)
    if name == "test-accounts.public.json":
        return "test-accounts.public.schema.json"
    if name == "safes.json" and {"safeVersion", "safes", "singleton"} <= keys:
        return "safe-topology.schema.json"
    if name == "timelock.json" and {"minimumDelaySeconds", "proposer", "canceller"} <= keys:
        return "timelock-deployment-receipt.schema.json"
    if name == "fixture.json" and value.get("fixture") is True:
        return "migration-fixture-receipt.schema.json"
    if name == "behavior.json" and "cases" in value:
        return "pre-market-behavior-receipt.schema.json"
    if name == "RC3_EVIDENCE_MANIFEST.json":
        return "rc3-evidence-manifest.schema.json"
    if {"safeTxHash", "signatures", "transaction"} <= keys:
        return "safe-signature-bundle.schema.json"
    if value.get("status") == "EXECUTED" and {"safeTxHash", "rawReceipt", "signers"} <= keys:
        return "safe-execution-receipt.schema.json"
    if {"operationId", "timelock", "target", "predecessor", "salt", "delaySeconds"} <= keys:
        return "timelock-operation.schema.json"
    if {"fundingSources", "totalRaw", "vault"} <= keys:
        return "migration-funding-verification-receipt.schema.json" if "verifiedAt" in value else "migration-funding-receipt.schema.json"
    if {"marketState", "irreversible", "replayRejected", "operationId"} <= keys:
        return "open-market-verification-receipt.schema.json"
    if value.get("network") == "sepolia" and {"deployment", "results", "verifiedAt"} <= keys:
        return "source-verification-receipt.schema.json"
    if {"manifestVersion", "manifestHash", "sourceAllocationId", "sourceSafe", "records"} <= keys:
        return "direct-holder-distribution.schema.json"
    return None


def validate(paths: list[Path]) -> tuple[int, int]:
    schemas: dict[str, dict[str, Any]] = {}
    for schema_path in sorted(SCHEMA_DIR.glob("*.schema.json")):
        schema = load_object(schema_path)
        Draft202012Validator.check_schema(schema)
        schemas[schema_path.name] = schema
    checked = 0
    recognized = 0
    for root in paths:
        if not root.exists():
            continue
        for path in sorted(root.rglob("*.json")):
            if path.is_symlink():
                raise ValueError(f"schema validation refuses symlink: {path}")
            value = load_object(path)
            checked += 1
            schema_name = schema_for(path, value)
            if schema_name is None:
                continue
            schema = schemas[schema_name]
            Draft202012Validator(schema, format_checker=FormatChecker()).validate(value)
            recognized += 1
    return checked, recognized


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="*", type=Path)
    args = parser.parse_args()
    paths = args.paths or [ROOT / "artifacts"]
    try:
        checked, recognized = validate(paths)
    except Exception as exc:
        print(f"RC3 schema validation failed: {exc}", file=sys.stderr)
        return 1
    print(f"RC3 schema validation green: schemas={len(list(SCHEMA_DIR.glob('*.schema.json')))} json={checked} recognized={recognized}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
