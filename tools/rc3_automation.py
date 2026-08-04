#!/usr/bin/env python3
"""RC3 release automation layered on top of the stable BINI V2 CLI.

The module deliberately keeps Mainnet execution disabled.  Local broadcast is
available only while the canonical rehearsal opt-in is set; production-facing
write paths are Sepolia-only and use encrypted Foundry accounts.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[1]
SEPOLIA_CHAIN_ID = 11_155_111
LOCAL_CHAIN_ID = 31_337
ZERO_ADDRESS = "0x" + "0" * 40
ZERO_HASH = "0x" + "0" * 64
SENTINEL_MODULES = "0x0000000000000000000000000000000000000001"
FALLBACK_HANDLER_STORAGE_SLOT = "0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5"
GUARD_STORAGE_SLOT = "0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8"
SAFE_VERSION = "1.4.1"
SAFE_PURPOSES = (
    "GOVERNANCE_SAFE",
    "SECURITY_SAFE",
    "GENESIS_DISTRIBUTION_SAFE",
    "REWARDS_Y1_SAFE",
    "REWARDS_Y2_RESERVE_SAFE",
    "REWARDS_Y3_RESERVE_SAFE",
    "REWARDS_Y4_RESERVE_SAFE",
    "TEAM_FOUNDERS_RESERVE_SAFE",
    "MARKETING_OPERATIONS_SAFE",
    "MARKETING_MILESTONE_RESERVE_SAFE",
    "ECOSYSTEM_RESERVE_SAFE",
    "LIQUIDITY_RESERVE_SAFE",
)
TEST_ACCOUNT_NAMES = ("bini-test-signer-1", "bini-test-signer-2", "bini-test-signer-3")
SEPOLIA_DEPLOYER_ACCOUNT_NAME = "bini-sepolia-deployer"
ALL_TEST_ACCOUNT_NAMES = (*TEST_ACCOUNT_NAMES, SEPOLIA_DEPLOYER_ACCOUNT_NAME)
TEST_ACCOUNT_METADATA = {
    "bini-test-signer-1": ("BINI_TEST_SIGNER_1", "SAFE_OWNER"),
    "bini-test-signer-2": ("BINI_TEST_SIGNER_2", "SAFE_OWNER"),
    "bini-test-signer-3": ("BINI_TEST_SIGNER_3", "SAFE_OWNER"),
    "bini-sepolia-deployer": ("BINI_SEPOLIA_DEPLOYER", "DEPLOYER"),
}
ADDRESS_RE = re.compile(r"^0x[0-9a-fA-F]{40}$")
HASH_RE = re.compile(r"^0x[0-9a-fA-F]{64}$")
SECURITY_MODES = ("PLAN", "SIMULATE", "BROADCAST", "SAFE_PROPOSAL", "SAFE_EXECUTE", "VERIFY")


class RC3Error(RuntimeError):
    pass


def now_utc() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()


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
        raise RC3Error(f"required executable not found: {command[0]}") from exc
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or "").strip()
        raise RC3Error(f"command failed ({' '.join(command[:3])}): {detail}") from exc
    return (completed.stdout or "").strip()


def run_json(command: list[str], label: str, *, env: dict[str, str] | None = None) -> Any:
    output = run(command, env=env)
    try:
        return json.loads(output)
    except json.JSONDecodeError as exc:
        raise RC3Error(f"{label} did not return JSON") from exc


def load_json(path: str | Path) -> dict[str, Any]:
    resolved = Path(path)
    if not resolved.is_absolute():
        resolved = ROOT / resolved
    try:
        value = json.loads(resolved.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise RC3Error(f"file not found: {resolved}") from exc
    except json.JSONDecodeError as exc:
        raise RC3Error(f"invalid JSON: {resolved}: {exc}") from exc
    if not isinstance(value, dict):
        raise RC3Error(f"JSON document must be an object: {resolved}")
    return value


def resolved_path(path: str | Path) -> Path:
    value = Path(path)
    return value if value.is_absolute() else ROOT / value


def _contains_symlink(path: Path) -> bool:
    """Return true when any existing component is a symlink."""
    absolute = path if path.is_absolute() else Path.cwd() / path
    current = Path(absolute.anchor)
    for part in absolute.parts[1:]:
        current /= part
        try:
            if current.is_symlink():
                target = current.resolve(strict=False)
                root = ROOT.resolve(strict=False)
                # macOS exposes stable system aliases such as /var -> /private/var.
                # Ignore only aliases that resolve to an ancestor of the repository;
                # any symlink at or below a task-controlled path still fails closed.
                system_aliases = {Path("/var"): Path("/private/var"), Path("/tmp"): Path("/private/tmp")}
                if system_aliases.get(current) == target or target == root or target in root.parents:
                    continue
                return True
        except OSError as exc:
            raise RC3Error(f"unable to inspect path component: {current}") from exc
    return False


def repo_path(path: str | Path, label: str) -> Path:
    """Resolve an artifact path inside the repository without symlink aliases."""
    candidate = resolved_path(path)
    if _contains_symlink(candidate):
        raise RC3Error(f"{label} must not contain symlinks: {candidate}")
    root = ROOT.resolve()
    resolved = candidate.resolve(strict=False)
    if resolved != root and root not in resolved.parents:
        raise RC3Error(f"{label} must remain inside the repository: {candidate}")
    return resolved


def external_keystore_path(path: str | Path) -> Path:
    """Resolve a keystore directory that is physically outside Git."""
    candidate = Path(path).expanduser()
    if not candidate.is_absolute():
        candidate = Path.cwd() / candidate
    if _contains_symlink(candidate):
        raise RC3Error(f"keystore path must not contain symlinks: {candidate}")
    resolved = candidate.resolve(strict=False)
    root = ROOT.resolve()
    if resolved == root or root in resolved.parents:
        raise RC3Error("test keystores must be stored outside the repository")
    return resolved


def external_secret_file(path: str | Path, label: str) -> Path:
    """Resolve a small, private, regular secret file outside the repository."""
    candidate = Path(path).expanduser()
    if not candidate.is_absolute():
        candidate = Path.cwd() / candidate
    if _contains_symlink(candidate) or candidate.is_symlink():
        raise RC3Error(f"{label} path must not contain symlinks: {candidate}")
    resolved = candidate.resolve(strict=False)
    root = ROOT.resolve()
    if resolved == root or root in resolved.parents:
        raise RC3Error(f"{label} must be stored outside the repository")
    if not resolved.is_file():
        raise RC3Error(f"{label} must be a regular file: {resolved}")
    permissions = stat.S_IMODE(resolved.stat().st_mode)
    if permissions & 0o077:
        raise RC3Error(f"{label} permissions are too broad ({oct(permissions)}): {resolved}")
    size = resolved.stat().st_size
    if size < 2 or size > 4096:
        raise RC3Error(f"{label} must contain one non-empty line and be at most 4096 bytes")
    return resolved


def require_exact_fields(value: dict[str, Any], allowed: Iterable[str], label: str, required: Iterable[str] = ()) -> None:
    allowed_set = set(allowed)
    unknown = sorted(set(value) - allowed_set)
    missing = sorted(set(required) - set(value))
    if unknown:
        raise RC3Error(f"{label} contains unknown fields: {', '.join(unknown)}")
    if missing:
        raise RC3Error(f"{label} is missing fields: {', '.join(missing)}")


def require_address(value: Any, label: str, *, allow_zero: bool = False) -> str:
    if not isinstance(value, str) or not ADDRESS_RE.fullmatch(value):
        raise RC3Error(f"{label} is not an Ethereum address")
    if not allow_zero and value.lower() == ZERO_ADDRESS:
        raise RC3Error(f"{label} must not be zero")
    return value


def require_hash(value: Any, label: str) -> str:
    if not isinstance(value, str) or not HASH_RE.fullmatch(value):
        raise RC3Error(f"{label} is not a bytes32 hash")
    return value


def strict_int(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, (str, int)):
        raise RC3Error(f"{label} must be an integer")
    try:
        parsed = int(str(value), 0)
    except ValueError as exc:
        raise RC3Error(f"{label} must be an integer") from exc
    if parsed < 0:
        raise RC3Error(f"{label} must not be negative")
    return parsed


def mode(args: argparse.Namespace) -> str:
    selected = str(getattr(args, "mode", None) or "PLAN").upper()
    if selected not in SECURITY_MODES:
        raise RC3Error(f"invalid mode: {selected}")
    return selected


def is_local_network(network: str) -> bool:
    return network in {"anvil", "anvil-rc3a", "anvil-release"}


def network_chain_id(network: str) -> int:
    if network == "sepolia":
        return SEPOLIA_CHAIN_ID
    if is_local_network(network) and os.environ.get("BINI_RC3A_LOCAL_REHEARSAL") == "1":
        return LOCAL_CHAIN_ID
    raise RC3Error("RC3 automation is Sepolia-only; local Anvil requires BINI_RC3A_LOCAL_REHEARSAL=1")


def rpc_url(network: str) -> str:
    env_name = "SEPOLIA_RPC_URL" if network == "sepolia" else "ANVIL_RPC_URL"
    value = os.environ.get(env_name, "")
    if not value:
        raise RC3Error(f"missing RPC environment variable: {env_name}")
    actual = strict_int(run(["cast", "chain-id", "--rpc-url", value]), "RPC chain id")
    expected = network_chain_id(network)
    if actual != expected:
        raise RC3Error(f"wrong chain: expected {expected}, got {actual}")
    return value


def ensure_write_network(network: str, selected_mode: str, *, safe_owned: bool = False) -> None:
    network_chain_id(network)
    if selected_mode in {"PLAN", "SIMULATE", "VERIFY", "SAFE_PROPOSAL"}:
        return
    if safe_owned and selected_mode != "SAFE_EXECUTE":
        raise RC3Error("Safe-owned actions require SAFE_PROPOSAL or SAFE_EXECUTE")
    if not safe_owned and selected_mode == "SAFE_EXECUTE":
        raise RC3Error("deployer-owned infrastructure cannot use SAFE_EXECUTE")
    if selected_mode == "BROADCAST" and network not in {"sepolia", "anvil", "anvil-rc3a", "anvil-release"}:
        raise RC3Error("broadcast is disabled outside Sepolia and the explicit local rehearsal")


def immutable_write(path: str | Path, value: dict[str, Any]) -> Path:
    output = repo_path(path, "immutable artifact")
    output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if _contains_symlink(output.parent):
        raise RC3Error(f"immutable artifact parent must not contain symlinks: {output.parent}")
    rendered = json.dumps(value, indent=2, sort_keys=True) + "\n"
    if output.exists() or output.is_symlink():
        if output.is_symlink() or not output.is_file():
            raise RC3Error(f"immutable artifact must be a regular file: {output}")
        if output.read_text(encoding="utf-8") == rendered:
            return output
        raise RC3Error(f"refusing to overwrite immutable artifact: {output}")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(output, flags, 0o600)
    except FileExistsError as exc:
        raise RC3Error(f"refusing raced immutable artifact creation: {output}") from exc
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        handle.write(rendered)
    return output


def versioned_artifact(network: str, category: str, prefix: str, value: dict[str, Any]) -> Path:
    digest = hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:16]
    return immutable_write(ROOT / "artifacts" / network / category / f"{prefix}-{digest}.json", value)


def current_commit() -> str:
    value = run(["git", "rev-parse", "HEAD"])
    if not re.fullmatch(r"[0-9a-f]{40}", value):
        raise RC3Error("unable to resolve the current Git commit")
    return value


def require_artifact_source(document: dict[str, Any], label: str) -> None:
    recorded = document.get("sourceCommit") or document.get("gitCommit")
    if recorded != current_commit():
        raise RC3Error(f"{label} source commit does not match current HEAD")


def code_hash(address: str, rpc: str) -> str:
    code = run(["cast", "code", require_address(address, "contract"), "--rpc-url", rpc])
    if code in {"", "0x"}:
        raise RC3Error(f"no contract code at {address}")
    return run(["cast", "keccak", code])


def cast_call(rpc: str, target: str, signature: str, *args: str) -> str:
    output = run(["cast", "call", "--json", target, signature, *args, "--rpc-url", rpc])
    try:
        value = json.loads(output)
    except json.JSONDecodeError:
        return output.strip()
    if isinstance(value, list) and len(value) == 1:
        return json.dumps(value[0]) if isinstance(value[0], (list, dict)) else str(value[0])
    if isinstance(value, list):
        return json.dumps(value)
    return str(value)


def governance_path(args: argparse.Namespace) -> Path:
    return resolved_path(getattr(args, "governance", "config/governance.sepolia.json"))


def validate_governance(document: dict[str, Any], network: str, *, require_addresses: bool) -> dict[str, Any]:
    if document.get("network") != network or strict_int(document.get("chainId"), "governance.chainId") != network_chain_id(network):
        raise RC3Error("governance network/chain mismatch")
    if document.get("sepoliaRehearsalOnly") is not True and network == "sepolia":
        raise RC3Error("governance must declare sepoliaRehearsalOnly=true")
    owners = document.get("owners")
    if not isinstance(owners, list) or len(owners) != 3:
        raise RC3Error("governance owners must contain exactly three entries")
    addresses: list[str] = []
    for index, owner in enumerate(owners):
        if not isinstance(owner, dict):
            raise RC3Error(f"governance owner {index} must be an object")
        require_exact_fields(owner, {"accountName", "address"}, f"governance owner {index}", {"accountName", "address"})
        if owner["accountName"] != TEST_ACCOUNT_NAMES[index]:
            raise RC3Error("governance account names are not canonical")
        if require_addresses:
            addresses.append(require_address(owner["address"], f"governance owner {index}"))
    if require_addresses and len({item.lower() for item in addresses}) != 3:
        raise RC3Error("governance owners must be distinct")
    if strict_int(document.get("threshold"), "governance.threshold") != 2:
        raise RC3Error("Safe threshold must be 2")
    purposes = document.get("safePurposes")
    if purposes != list(SAFE_PURPOSES):
        raise RC3Error("governance safePurposes must be the canonical twelve-purpose list")
    if document.get("safeVersion") != SAFE_VERSION:
        raise RC3Error(f"Safe version must be pinned to {SAFE_VERSION}")
    delay = strict_int(document.get("timelockMinimumDelaySeconds"), "governance.timelockMinimumDelaySeconds")
    if delay <= 0:
        raise RC3Error("Timelock delay must be positive")
    infrastructure = document.get("safeInfrastructure")
    if network == "sepolia" and require_addresses:
        if not isinstance(infrastructure, dict):
            raise RC3Error("Sepolia governance requires pinned Safe infrastructure")
        require_exact_fields(
            infrastructure,
            {
                "singleton", "proxyFactory", "multiSend", "singletonRuntimeCodeHash",
                "proxyFactoryRuntimeCodeHash", "multiSendRuntimeCodeHash",
            },
            "Safe infrastructure",
            {
                "singleton", "proxyFactory", "multiSend", "singletonRuntimeCodeHash",
                "proxyFactoryRuntimeCodeHash", "multiSendRuntimeCodeHash",
            },
        )
        for key in ("singleton", "proxyFactory", "multiSend"):
            require_address(infrastructure[key], f"safeInfrastructure.{key}")
        for key in ("singletonRuntimeCodeHash", "proxyFactoryRuntimeCodeHash", "multiSendRuntimeCodeHash"):
            require_hash(infrastructure[key], f"safeInfrastructure.{key}")
    return document


def read_public_keystore_address(path: Path) -> str:
    if path.is_symlink() or not path.is_file():
        raise RC3Error(f"keystore must be a regular non-symlink file: {path}")
    permissions = stat.S_IMODE(path.stat().st_mode)
    if permissions & 0o077:
        raise RC3Error(f"keystore permissions are too broad ({oct(permissions)}): {path}")
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RC3Error(f"invalid encrypted keystore: {path}") from exc
    if any(key.lower() in {"privatekey", "private_key", "mnemonic", "seedphrase", "seed_phrase"} for key in document):
        raise RC3Error(f"keystore contains a forbidden raw secret field: {path}")
    address = document.get("address")
    if isinstance(address, str) and re.fullmatch(r"[0-9a-fA-F]{40}", address):
        return "0x" + address

    # Foundry 1.5 creates Web3 Secret Storage files without the optional
    # top-level address.  Ask cast to decrypt and derive only the public
    # address; the secret never enters this process' stdout or artifacts.
    command = ["cast", "wallet", "address", "--keystore", str(path)]
    password_file = os.environ.get("BINI_TEST_KEYSTORE_PASSWORD_FILE")
    if password_file:
        command.extend(["--password-file", str(external_secret_file(password_file, "keystore password file"))])
    elif os.environ.get("BINI_RC3A_TEST_MODE") == "1":
        command.extend(["--password", os.environ.get("BINI_RC3A_TEST_KEYSTORE_PASSWORD", "rc3a-ephemeral-only")])
    else:
        raise RC3Error(f"keystore has no embedded address; interactive resolution is required: {path}")
    return require_address(run(command), f"keystore public address ({path.name})")


def test_keystore_dir(args: argparse.Namespace) -> Path:
    explicit = getattr(args, "keystore_dir", None) or os.environ.get("BINI_TEST_KEYSTORE_DIR")
    directory = Path(explicit) if explicit else Path.home() / ".foundry" / "keystores" / "bini-v2-sepolia-rc3"
    return external_keystore_path(directory)


def find_account_file(directory: Path, name: str) -> Path | None:
    exact = directory / name
    if exact.is_symlink():
        raise RC3Error(f"keystore must not be a symlink: {exact}")
    if exact.is_file():
        return exact
    matches = []
    for path in directory.glob(f"{name}*"):
        if path.is_symlink():
            raise RC3Error(f"keystore must not be a symlink: {path}")
        if path.is_file():
            matches.append(path)
    if len(matches) > 1:
        raise RC3Error(f"multiple keystores found for account {name}")
    return matches[0] if matches else None


def command_test_accounts_init(args: argparse.Namespace) -> None:
    if args.network != "sepolia" and os.environ.get("BINI_RC3A_TEST_MODE") != "1":
        raise RC3Error("test account bootstrap refuses every network except Sepolia")
    chain_id = SEPOLIA_CHAIN_ID if args.network == "sepolia" else network_chain_id(args.network)
    output = resolved_path(args.output)
    directory = test_keystore_dir(args)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory.chmod(0o700)
    accounts: list[dict[str, str]] = []
    for account_name in ALL_TEST_ACCOUNT_NAMES:
        account_file = find_account_file(directory, account_name)
        if account_file is None:
            command = ["cast", "wallet", "new", str(directory), account_name, "--quiet"]
            if os.environ.get("BINI_RC3A_TEST_MODE") == "1":
                test_password = os.environ.get("BINI_RC3A_TEST_KEYSTORE_PASSWORD", "rc3a-ephemeral-only")
                command.extend(["--unsafe-password", test_password])
            try:
                subprocess.run(command, cwd=ROOT, check=True, stdout=subprocess.DEVNULL, stderr=None, text=True)
            except subprocess.CalledProcessError as exc:
                raise RC3Error(f"secure keystore creation failed for {account_name}") from exc
            account_file = find_account_file(directory, account_name)
        if account_file is None:
            raise RC3Error(f"keystore was not created for {account_name}")
        account_file.chmod(0o600)
        label, role = TEST_ACCOUNT_METADATA[account_name]
        accounts.append({"accountName": account_name, "label": label, "role": role, "address": read_public_keystore_address(account_file)})
    if len({item["address"].lower() for item in accounts}) != len(ALL_TEST_ACCOUNT_NAMES):
        raise RC3Error("test account bootstrap produced duplicate addresses")
    if output.exists():
        existing = load_json(output)
        existing_accounts = validate_public_accounts_manifest(existing, args.network)
        if existing_accounts != accounts:
            raise RC3Error("existing test account manifest does not match encrypted keystores")
        print(output)
        return
    manifest = {
        "schemaVersion": "1.0",
        "network": args.network,
        "chainId": chain_id,
        "sepoliaRehearsalOnly": True,
        "accounts": accounts,
        "createdAt": now_utc(),
    }
    output = immutable_write(output, manifest)
    print(output)


def validate_public_accounts_manifest(manifest: dict[str, Any], network: str) -> list[dict[str, str]]:
    require_exact_fields(
        manifest,
        {"schemaVersion", "network", "chainId", "sepoliaRehearsalOnly", "accounts", "createdAt"},
        "test accounts manifest",
        {"schemaVersion", "network", "chainId", "sepoliaRehearsalOnly", "accounts", "createdAt"},
    )
    if manifest["network"] != network or strict_int(manifest["chainId"], "manifest.chainId") != network_chain_id(network):
        raise RC3Error("test account manifest network/chain mismatch")
    if manifest["sepoliaRehearsalOnly"] is not True:
        raise RC3Error("test account manifest is not rehearsal-only")
    accounts = manifest["accounts"]
    if not isinstance(accounts, list) or len(accounts) != len(ALL_TEST_ACCOUNT_NAMES):
        raise RC3Error("test account manifest must contain exactly four accounts")
    result: list[dict[str, str]] = []
    for index, account in enumerate(accounts):
        if not isinstance(account, dict):
            raise RC3Error("test account entry must be an object")
        require_exact_fields(account, {"accountName", "label", "role", "address"}, f"test account {index}", {"accountName", "label", "role", "address"})
        if account["accountName"] != ALL_TEST_ACCOUNT_NAMES[index]:
            raise RC3Error("test account names/order mismatch")
        expected_label, expected_role = TEST_ACCOUNT_METADATA[account["accountName"]]
        if account["label"] != expected_label or account["role"] != expected_role:
            raise RC3Error("test account label/role mismatch")
        result.append({"accountName": account["accountName"], "label": account["label"], "role": account["role"], "address": require_address(account["address"], "account address")})
    if len({item["address"].lower() for item in result}) != len(ALL_TEST_ACCOUNT_NAMES):
        raise RC3Error("duplicate test account address")
    return result


def command_test_accounts_verify(args: argparse.Namespace) -> None:
    accounts = validate_public_accounts_manifest(load_json(args.manifest), args.network)
    directory = test_keystore_dir(args)
    rpc = rpc_url(args.network)
    minimum = strict_int(os.environ.get("BINI_TEST_ACCOUNT_MIN_BALANCE_WEI", "10000000000000000"), "minimum balance")
    required_funded = {item.strip() for item in os.environ.get("BINI_REQUIRED_FUNDED_ACCOUNTS", "").split(",") if item.strip()}
    unknown_required = required_funded - set(ALL_TEST_ACCOUNT_NAMES)
    if unknown_required:
        raise RC3Error(f"unknown required funded accounts: {', '.join(sorted(unknown_required))}")
    results = []
    for account in accounts:
        account_file = find_account_file(directory, account["accountName"])
        if account_file is None:
            raise RC3Error(f"missing encrypted keystore: {account['accountName']}")
        resolved = read_public_keystore_address(account_file)
        if resolved.lower() != account["address"].lower():
            raise RC3Error(f"keystore address mismatch: {account['accountName']}")
        balance = strict_int(run(["cast", "balance", resolved, "--rpc-url", rpc]), "signer balance")
        if account["accountName"] in required_funded and balance < minimum:
            raise RC3Error(f"insufficient funding for {account['accountName']}: {balance} < {minimum}")
        results.append({**account, "balanceWei": str(balance), "funded": balance >= minimum, "fundingRequired": account["accountName"] in required_funded})
    print(json.dumps({"status": "VERIFIED", "network": args.network, "accounts": results}, indent=2, sort_keys=True))


def command_safes_plan(args: argparse.Namespace) -> None:
    governance = validate_governance(load_json(governance_path(args)), args.network, require_addresses=True)
    plan = {
        "schemaVersion": "1.0",
        "network": args.network,
        "chainId": network_chain_id(args.network),
        "safeVersion": SAFE_VERSION,
        "owners": [item["address"] for item in governance["owners"]],
        "threshold": 2,
        "purposes": list(SAFE_PURPOSES),
        "count": 12,
        "fallbackHandler": ZERO_ADDRESS,
        "modules": [],
        "guard": ZERO_ADDRESS,
        "mode": "PLAN",
    }
    print(json.dumps(plan, indent=2, sort_keys=True))


def foundry_broadcast(network: str, script: str, env: dict[str, str], selected_mode: str) -> Path | None:
    rpc = rpc_url(network)
    command = ["forge", "script", script, "--rpc-url", rpc, "-vvvv"]
    if selected_mode == "BROADCAST":
        if is_local_network(network):
            sender = require_address(os.environ.get("BINI_LOCAL_DEPLOYER"), "BINI_LOCAL_DEPLOYER")
            command.extend(["--broadcast", "--unlocked", "--sender", sender])
        else:
            account = os.environ.get("DEPLOYER_ACCOUNT")
            if not account:
                raise RC3Error("BROADCAST requires DEPLOYER_ACCOUNT encrypted keystore")
            command.extend(["--broadcast", *signing_wallet_args(account)])
    run(command, env=env, capture=False)
    if selected_mode != "BROADCAST":
        return None
    contract_name = script.split(":")[-1]
    receipt = ROOT / "broadcast" / f"{contract_name}.s.sol" / str(network_chain_id(network)) / "run-latest.json"
    if not receipt.exists():
        raise RC3Error(f"Foundry broadcast receipt missing: {receipt}")
    return receipt


def broadcast_transactions(receipt_path: Path) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    receipt = load_json(receipt_path)
    transactions = receipt.get("transactions")
    receipts = receipt.get("receipts")
    if not isinstance(transactions, list) or not isinstance(receipts, list) or not receipts:
        raise RC3Error("incomplete Foundry broadcast receipt")
    return transactions, receipts


def deployed_contract(transactions: list[dict[str, Any]], contract_name: str) -> str:
    matches = [
        item.get("contractAddress")
        for item in transactions
        if item.get("contractName") == contract_name and item.get("transactionType") in {"CREATE", "CREATE2"}
    ]
    matches = [item for item in matches if isinstance(item, str)]
    if len(matches) != 1:
        raise RC3Error(f"expected one {contract_name} deployment, got {len(matches)}")
    return require_address(matches[0], contract_name)


def proxy_addresses_from_receipts(receipts: list[dict[str, Any]]) -> list[str]:
    topic = run(["cast", "keccak", "ProxyCreation(address,address)"]).lower()
    proxies: list[str] = []
    for receipt in receipts:
        logs = receipt.get("logs", []) if isinstance(receipt, dict) else []
        for log in logs if isinstance(logs, list) else []:
            topics = log.get("topics", []) if isinstance(log, dict) else []
            if len(topics) >= 2 and str(topics[0]).lower() == topic:
                candidate = "0x" + str(topics[1])[-40:]
                if candidate.lower() not in {item.lower() for item in proxies}:
                    proxies.append(candidate)
    if len(proxies) != 12:
        raise RC3Error(f"expected twelve ProxyCreation logs, got {len(proxies)}")
    return proxies


def command_safes_deploy(args: argparse.Namespace) -> None:
    selected_mode = mode(args)
    if selected_mode not in {"PLAN", "SIMULATE", "BROADCAST"}:
        raise RC3Error("safes deploy supports PLAN, SIMULATE or BROADCAST")
    ensure_write_network(args.network, selected_mode)
    governance = validate_governance(load_json(governance_path(args)), args.network, require_addresses=True)
    if selected_mode == "PLAN":
        command_safes_plan(args)
        return
    manifest_path = ROOT / "artifacts" / args.network / "infrastructure" / "safes.json"
    if selected_mode == "BROADCAST" and manifest_path.exists():
        command_safes_verify(argparse.Namespace(network=args.network, manifest=str(manifest_path)))
        print(json.dumps({"status": "ALREADY_DEPLOYED", "manifest": str(manifest_path)}, indent=2))
        return
    infrastructure = governance.get("safeInfrastructure")
    deploy_infrastructure = is_local_network(args.network)
    if not deploy_infrastructure:
        assert isinstance(infrastructure, dict)
        rpc = rpc_url(args.network)
        for address_key, hash_key in (
            ("singleton", "singletonRuntimeCodeHash"),
            ("proxyFactory", "proxyFactoryRuntimeCodeHash"),
            ("multiSend", "multiSendRuntimeCodeHash"),
        ):
            actual_hash = code_hash(infrastructure[address_key], rpc)
            if actual_hash.lower() != infrastructure[hash_key].lower():
                raise RC3Error(f"pinned Safe infrastructure hash mismatch: {address_key}")
    env = os.environ.copy()
    env.update(
        {
            "BINI_V2_EXPECTED_CHAIN_ID": str(network_chain_id(args.network)),
            "BINI_TEST_SIGNER_1": governance["owners"][0]["address"],
            "BINI_TEST_SIGNER_2": governance["owners"][1]["address"],
            "BINI_TEST_SIGNER_3": governance["owners"][2]["address"],
            "BINI_SAFE_DEPLOY_INFRASTRUCTURE": "true" if deploy_infrastructure else "false",
            "BINI_SAFE_SALT_BASE": str(strict_int(governance.get("safeSaltBase", 1), "safeSaltBase")),
        }
    )
    if not deploy_infrastructure:
        env.update(
            {
                "BINI_SAFE_SINGLETON": infrastructure["singleton"],
                "BINI_SAFE_PROXY_FACTORY": infrastructure["proxyFactory"],
                "BINI_SAFE_MULTISEND": infrastructure["multiSend"],
            }
        )
    receipt_path = foundry_broadcast(
        args.network, "script/DeploySafeTopology.s.sol:DeploySafeTopology", env, selected_mode
    )
    if selected_mode == "SIMULATE":
        value = {"status": "SIMULATED", "network": args.network, "safeCount": 12, "checkedAt": now_utc()}
        print(versioned_artifact(args.network, "infrastructure", "safes-simulation", value))
        return
    assert receipt_path is not None
    transactions, receipts = broadcast_transactions(receipt_path)
    if deploy_infrastructure:
        singleton = deployed_contract(transactions, "Safe")
        factory = deployed_contract(transactions, "SafeProxyFactory")
        multi_send = deployed_contract(transactions, "MultiSend")
    else:
        singleton = infrastructure["singleton"]
        factory = infrastructure["proxyFactory"]
        multi_send = infrastructure["multiSend"]
    proxies = proxy_addresses_from_receipts(receipts)
    singleton_hash = code_hash(singleton, rpc_url(args.network))
    factory_hash = code_hash(factory, rpc_url(args.network))
    multisend_hash = code_hash(multi_send, rpc_url(args.network))
    proxy_hashes = {code_hash(proxy, rpc_url(args.network)).lower() for proxy in proxies}
    if len(proxy_hashes) != 1:
        raise RC3Error("Safe proxy runtime code hashes differ after deployment")
    block_numbers = [strict_int(item["blockNumber"], "receipt block") for item in receipts]
    tx_hashes = [item.get("transactionHash") for item in receipts if isinstance(item.get("transactionHash"), str)]
    manifest = {
        "schemaVersion": "1.0",
        "network": args.network,
        "chainId": network_chain_id(args.network),
        "sepoliaRehearsalOnly": True,
        "safeVersion": SAFE_VERSION,
        "singleton": singleton,
        "proxyFactory": factory,
        "multiSend": multi_send,
        "singletonRuntimeCodeHash": singleton_hash,
        "proxyFactoryRuntimeCodeHash": factory_hash,
        "multiSendRuntimeCodeHash": multisend_hash,
        "safeProxyRuntimeCodeHash": next(iter(proxy_hashes)),
        "owners": [item["address"] for item in governance["owners"]],
        "threshold": 2,
        "safes": [
            {"purpose": purpose, "address": address, "creationTransaction": tx_hashes[index + (3 if deploy_infrastructure else 0)] if index + (3 if deploy_infrastructure else 0) < len(tx_hashes) else tx_hashes[-1]}
            for index, (purpose, address) in enumerate(zip(SAFE_PURPOSES, proxies))
        ],
        "deploymentBlockStart": min(block_numbers),
        "deploymentBlockEnd": max(block_numbers),
        "broadcastReceipt": str(receipt_path.relative_to(ROOT)),
        "sourceCommit": run(["git", "rev-parse", "HEAD"]),
        "createdAt": now_utc(),
    }
    output = immutable_write(manifest_path, manifest)
    print(output)


def parse_address_array(value: str, label: str) -> list[str]:
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as exc:
        raise RC3Error(f"unable to decode {label}") from exc
    if not isinstance(parsed, list):
        raise RC3Error(f"{label} must be an array")
    return [require_address(item, label) for item in parsed]


def storage_address(rpc: str, target: str, slot: str) -> str:
    raw = run(["cast", "storage", target, slot, "--rpc-url", rpc])
    return "0x" + raw[-40:]


def validate_safes_manifest(manifest: dict[str, Any], network: str) -> None:
    require_exact_fields(
        manifest,
        {
            "schemaVersion", "network", "chainId", "sepoliaRehearsalOnly", "safeVersion", "singleton",
            "proxyFactory", "multiSend", "singletonRuntimeCodeHash", "proxyFactoryRuntimeCodeHash",
            "multiSendRuntimeCodeHash", "safeProxyRuntimeCodeHash", "owners", "threshold", "safes", "deploymentBlockStart",
            "deploymentBlockEnd", "broadcastReceipt", "sourceCommit", "createdAt",
        },
        "Safe topology manifest",
        {
            "schemaVersion", "network", "chainId", "safeVersion", "singleton", "proxyFactory", "multiSend",
            "singletonRuntimeCodeHash", "proxyFactoryRuntimeCodeHash", "multiSendRuntimeCodeHash", "safeProxyRuntimeCodeHash",
            "owners", "threshold", "safes", "sourceCommit",
        },
    )
    if manifest["network"] != network or strict_int(manifest["chainId"], "manifest.chainId") != network_chain_id(network):
        raise RC3Error("Safe manifest network/chain mismatch")
    require_address(manifest["singleton"], "manifest.singleton")
    require_address(manifest["proxyFactory"], "manifest.proxyFactory")
    require_address(manifest["multiSend"], "manifest.multiSend")
    for key in ("singletonRuntimeCodeHash", "proxyFactoryRuntimeCodeHash", "multiSendRuntimeCodeHash", "safeProxyRuntimeCodeHash"):
        require_hash(manifest[key], f"manifest.{key}")
    owners = manifest["owners"]
    if not isinstance(owners, list) or len(owners) != 3 or len({str(item).lower() for item in owners}) != 3:
        raise RC3Error("Safe manifest must have three distinct owners")
    for owner in owners:
        require_address(owner, "Safe owner")
    if strict_int(manifest["threshold"], "Safe threshold") != 2:
        raise RC3Error("Safe manifest threshold mismatch")
    safes = manifest["safes"]
    if not isinstance(safes, list) or len(safes) != 12:
        raise RC3Error("Safe manifest must contain twelve Safes")
    purposes = []
    addresses = []
    for index, safe in enumerate(safes):
        if not isinstance(safe, dict):
            raise RC3Error("Safe manifest entry must be an object")
        require_exact_fields(safe, {"purpose", "address", "creationTransaction"}, f"Safe entry {index}", {"purpose", "address", "creationTransaction"})
        purposes.append(safe["purpose"])
        addresses.append(require_address(safe["address"], f"Safe {index}"))
        require_hash(safe["creationTransaction"], f"Safe {index} creation transaction")
    if purposes != list(SAFE_PURPOSES) or len({item.lower() for item in addresses}) != 12:
        raise RC3Error("Safe purpose/order/uniqueness mismatch")


def command_safes_verify(args: argparse.Namespace) -> None:
    manifest = load_json(args.manifest)
    validate_safes_manifest(manifest, args.network)
    require_artifact_source(manifest, "Safe topology manifest")
    rpc = rpc_url(args.network)
    expected_owners = {item.lower() for item in manifest["owners"]}
    singleton_hash = code_hash(manifest["singleton"], rpc)
    factory_hash = code_hash(manifest["proxyFactory"], rpc)
    multisend_hash = code_hash(manifest["multiSend"], rpc)
    for label, actual, expected in (
        ("singleton", singleton_hash, manifest["singletonRuntimeCodeHash"]),
        ("proxy factory", factory_hash, manifest["proxyFactoryRuntimeCodeHash"]),
        ("MultiSend", multisend_hash, manifest["multiSendRuntimeCodeHash"]),
    ):
        if actual.lower() != expected.lower():
            raise RC3Error(f"{label} runtime code hash differs from the pinned manifest")
    proxy_hashes = set()
    results = []
    for entry in manifest["safes"]:
        safe = entry["address"]
        actual_owners = parse_address_array(cast_call(rpc, safe, "getOwners()(address[])"), "Safe owners")
        if {item.lower() for item in actual_owners} != expected_owners:
            raise RC3Error(f"Safe owner mismatch: {safe}")
        if strict_int(cast_call(rpc, safe, "getThreshold()(uint256)"), "Safe threshold") != 2:
            raise RC3Error(f"Safe threshold mismatch: {safe}")
        if cast_call(rpc, safe, "VERSION()(string)") != SAFE_VERSION:
            raise RC3Error(f"Safe version mismatch: {safe}")
        modules_raw = cast_call(rpc, safe, "getModulesPaginated(address,uint256)(address[],address)", SENTINEL_MODULES, "100")
        modules_value = json.loads(modules_raw)
        if not isinstance(modules_value, list) or modules_value[0] != []:
            raise RC3Error(f"unexpected Safe module: {safe}")
        guard = storage_address(rpc, safe, GUARD_STORAGE_SLOT)
        fallback = storage_address(rpc, safe, FALLBACK_HANDLER_STORAGE_SLOT)
        if guard.lower() != ZERO_ADDRESS or fallback.lower() != ZERO_ADDRESS:
            raise RC3Error(f"unexpected guard/fallback handler: {safe}")
        singleton = storage_address(rpc, safe, "0x0")
        if singleton.lower() != manifest["singleton"].lower():
            raise RC3Error(f"Safe singleton mismatch: {safe}")
        runtime_hash = code_hash(safe, rpc)
        proxy_hashes.add(runtime_hash.lower())
        results.append({"purpose": entry["purpose"], "address": safe, "runtimeCodeHash": runtime_hash})
    if len(proxy_hashes) != 1:
        raise RC3Error("Safe proxy runtime code hashes differ")
    if next(iter(proxy_hashes)) != manifest["safeProxyRuntimeCodeHash"].lower():
        raise RC3Error("Safe proxy runtime code hash differs from the pinned manifest")
    print(
        json.dumps(
            {
                "status": "VERIFIED",
                "safeCount": 12,
                "singletonRuntimeCodeHash": singleton_hash,
                "factoryRuntimeCodeHash": factory_hash,
                "multiSendRuntimeCodeHash": multisend_hash,
                "safeProxyRuntimeCodeHash": next(iter(proxy_hashes)),
                "safes": results,
            },
            indent=2,
            sort_keys=True,
        )
    )


def safe_by_purpose(safes_manifest: dict[str, Any], purpose: str) -> str:
    for entry in safes_manifest.get("safes", []):
        if entry.get("purpose") == purpose:
            return require_address(entry.get("address"), purpose)
    raise RC3Error(f"Safe purpose not found: {purpose}")


def command_timelock_plan(args: argparse.Namespace) -> None:
    governance = validate_governance(load_json(governance_path(args)), args.network, require_addresses=False)
    print(
        json.dumps(
            {
                "schemaVersion": "1.0",
                "network": args.network,
                "chainId": network_chain_id(args.network),
                "proposer": "GOVERNANCE_SAFE",
                "executor": "GOVERNANCE_SAFE",
                "canceller": "SECURITY_SAFE",
                "minimumDelaySeconds": governance["timelockMinimumDelaySeconds"],
                "admin": "SELF_ADMINISTERED",
                "deployerResidualRoles": [],
                "mode": "PLAN",
            },
            indent=2,
            sort_keys=True,
        )
    )


def command_timelock_deploy(args: argparse.Namespace) -> None:
    selected_mode = mode(args)
    if selected_mode not in {"PLAN", "SIMULATE", "BROADCAST"}:
        raise RC3Error("timelock deploy supports PLAN, SIMULATE or BROADCAST")
    ensure_write_network(args.network, selected_mode)
    governance = validate_governance(load_json(governance_path(args)), args.network, require_addresses=False)
    if selected_mode == "PLAN":
        command_timelock_plan(args)
        return
    manifest_path = ROOT / "artifacts" / args.network / "infrastructure" / "timelock.json"
    if selected_mode == "BROADCAST" and manifest_path.exists():
        command_timelock_verify(argparse.Namespace(network=args.network, manifest=str(manifest_path)))
        print(json.dumps({"status": "ALREADY_DEPLOYED", "manifest": str(manifest_path)}, indent=2))
        return
    safes_path = resolved_path(getattr(args, "safes_manifest", None) or f"artifacts/{args.network}/infrastructure/safes.json")
    safes = load_json(safes_path)
    validate_safes_manifest(safes, args.network)
    governance_safe = safe_by_purpose(safes, "GOVERNANCE_SAFE")
    security_safe = safe_by_purpose(safes, "SECURITY_SAFE")
    configured_deployer = os.environ.get("DEPLOYER_ADDRESS")
    if selected_mode == "BROADCAST":
        if is_local_network(args.network):
            timelock_deployer = require_address(os.environ.get("BINI_LOCAL_DEPLOYER"), "BINI_LOCAL_DEPLOYER")
        else:
            account = os.environ.get("DEPLOYER_ACCOUNT")
            if not account:
                raise RC3Error("BROADCAST requires DEPLOYER_ACCOUNT encrypted keystore")
            timelock_deployer = signing_account_address(account)
        if configured_deployer and require_address(configured_deployer, "DEPLOYER_ADDRESS").lower() != timelock_deployer.lower():
            raise RC3Error("DEPLOYER_ADDRESS does not match the encrypted keystore signer")
    else:
        timelock_deployer = require_address(
            configured_deployer or "0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38",
            "Timelock simulation deployer",
        )
    env = os.environ.copy()
    env.update(
        {
            "BINI_V2_EXPECTED_CHAIN_ID": str(network_chain_id(args.network)),
            "BINI_GOVERNANCE_SAFE": governance_safe,
            "BINI_SECURITY_SAFE": security_safe,
            "BINI_TIMELOCK_DEPLOYER": timelock_deployer,
            "BINI_TIMELOCK_MIN_DELAY": str(governance["timelockMinimumDelaySeconds"]),
        }
    )
    receipt_path = foundry_broadcast(args.network, "script/DeployTimelock.s.sol:DeployTimelock", env, selected_mode)
    if selected_mode == "SIMULATE":
        value = {"status": "SIMULATED", "network": args.network, "checkedAt": now_utc()}
        print(versioned_artifact(args.network, "infrastructure", "timelock-simulation", value))
        return
    assert receipt_path is not None
    transactions, receipts = broadcast_transactions(receipt_path)
    address = deployed_contract(transactions, "TimelockController")
    manifest = {
        "schemaVersion": "1.0",
        "network": args.network,
        "chainId": network_chain_id(args.network),
        "address": address,
        "proposer": governance_safe,
        "executor": governance_safe,
        "canceller": security_safe,
        "minimumDelaySeconds": strict_int(governance["timelockMinimumDelaySeconds"], "Timelock delay"),
        "admin": address,
        "deployer": require_address(os.environ.get("BINI_LOCAL_DEPLOYER") if is_local_network(args.network) else os.environ.get("DEPLOYER_ADDRESS"), "deployer"),
        "deploymentTransaction": require_hash(receipts[0]["transactionHash"], "Timelock transaction"),
        "deploymentBlock": strict_int(receipts[0]["blockNumber"], "Timelock block"),
        "broadcastReceipt": str(receipt_path.relative_to(ROOT)),
        "sourceCommit": run(["git", "rev-parse", "HEAD"]),
        "createdAt": now_utc(),
    }
    output = immutable_write(manifest_path, manifest)
    print(output)


def role_hash(name: str) -> str:
    return run(["cast", "keccak", name])


def has_role(rpc: str, timelock: str, role: str, account: str) -> bool:
    return cast_call(rpc, timelock, "hasRole(bytes32,address)(bool)", role, account).lower() == "true"


def validate_timelock_manifest(manifest: dict[str, Any], network: str) -> None:
    require_exact_fields(
        manifest,
        {
            "schemaVersion", "network", "chainId", "address", "proposer", "executor", "canceller",
            "minimumDelaySeconds", "admin", "deployer", "deploymentTransaction", "deploymentBlock",
            "broadcastReceipt", "sourceCommit", "createdAt",
        },
        "Timelock manifest",
        {"schemaVersion", "network", "chainId", "address", "proposer", "executor", "canceller", "minimumDelaySeconds", "admin", "deployer"},
    )
    if manifest["network"] != network or strict_int(manifest["chainId"], "Timelock chain") != network_chain_id(network):
        raise RC3Error("Timelock manifest network/chain mismatch")
    for key in ("address", "proposer", "executor", "canceller", "admin", "deployer"):
        require_address(manifest[key], f"Timelock {key}")


def command_timelock_verify(args: argparse.Namespace) -> None:
    manifest = load_json(args.manifest)
    validate_timelock_manifest(manifest, args.network)
    require_artifact_source(manifest, "Timelock manifest")
    rpc = rpc_url(args.network)
    timelock = manifest["address"]
    if code_hash(timelock, rpc) == ZERO_HASH:
        raise RC3Error("Timelock has no runtime code")
    roles = {
        "DEFAULT_ADMIN_ROLE": ZERO_HASH,
        "PROPOSER_ROLE": role_hash("PROPOSER_ROLE"),
        "EXECUTOR_ROLE": role_hash("EXECUTOR_ROLE"),
        "CANCELLER_ROLE": role_hash("CANCELLER_ROLE"),
    }
    expected = {
        "DEFAULT_ADMIN_ROLE": manifest["admin"],
        "PROPOSER_ROLE": manifest["proposer"],
        "EXECUTOR_ROLE": manifest["executor"],
        "CANCELLER_ROLE": manifest["canceller"],
    }
    for name, account in expected.items():
        if not has_role(rpc, timelock, roles[name], account):
            raise RC3Error(f"Timelock role mismatch: {name}")
    for name, role in roles.items():
        if has_role(rpc, timelock, role, manifest["deployer"]):
            raise RC3Error(f"deployer retains Timelock role: {name}")
    if has_role(rpc, timelock, roles["CANCELLER_ROLE"], manifest["proposer"]):
        raise RC3Error("Governance proposer unexpectedly retains CANCELLER_ROLE")
    delay = strict_int(cast_call(rpc, timelock, "getMinDelay()(uint256)"), "Timelock delay")
    if delay != strict_int(manifest["minimumDelaySeconds"], "manifest delay"):
        raise RC3Error("Timelock delay mismatch")
    print(json.dumps({"status": "VERIFIED", "address": timelock, "delay": delay, "roles": expected}, indent=2, sort_keys=True))


def load_safe_package(path: str | Path) -> dict[str, Any]:
    package = load_json(path)
    require_exact_fields(
        package,
        {"version", "chainId", "createdAt", "meta", "transactions", "rc3"},
        "Safe transaction package",
        {"version", "chainId", "createdAt", "meta", "transactions"},
    )
    if package.get("version") != "1.0":
        raise RC3Error("unsupported Safe transaction package version")
    chain_id = strict_int(package.get("chainId"), "Safe package chainId")
    if chain_id not in {SEPOLIA_CHAIN_ID, LOCAL_CHAIN_ID}:
        raise RC3Error("Safe transaction package is not Sepolia/local rehearsal")
    meta = package.get("meta")
    if not isinstance(meta, dict):
        raise RC3Error("Safe package meta must be an object")
    require_exact_fields(
        meta,
        {"name", "description", "txBuilderVersion", "createdFromSafeAddress"},
        "Safe package meta",
        {"name", "description", "txBuilderVersion", "createdFromSafeAddress"},
    )
    require_address(meta["createdFromSafeAddress"], "Safe package Safe")
    transactions = package.get("transactions")
    if not isinstance(transactions, list) or not transactions:
        raise RC3Error("Safe package must contain transactions")
    for index, transaction in enumerate(transactions):
        if not isinstance(transaction, dict):
            raise RC3Error(f"Safe transaction {index} must be an object")
        require_exact_fields(
            transaction,
            {"to", "value", "data", "contractMethod", "contractInputsValues", "operation"},
            f"Safe transaction {index}",
            {"to", "value", "data"},
        )
        require_address(transaction["to"], f"Safe transaction {index} target")
        strict_int(transaction["value"], f"Safe transaction {index} value")
        data = transaction["data"]
        if not isinstance(data, str) or not re.fullmatch(r"0x(?:[0-9a-fA-F]{2})*", data):
            raise RC3Error(f"Safe transaction {index} calldata is invalid")
        operation = strict_int(transaction.get("operation", 0), f"Safe transaction {index} operation")
        if operation != 0:
            raise RC3Error("inner delegatecall is forbidden")
    return package


def encode_multisend(transactions: list[dict[str, Any]]) -> str:
    packed = bytearray()
    for transaction in transactions:
        data = bytes.fromhex(transaction["data"][2:])
        packed.extend((0).to_bytes(1, "big"))
        packed.extend(bytes.fromhex(transaction["to"][2:]))
        packed.extend(strict_int(transaction["value"], "transaction value").to_bytes(32, "big"))
        packed.extend(len(data).to_bytes(32, "big"))
        packed.extend(data)
    return "0x" + packed.hex()


def normalize_safe_transaction(package: dict[str, Any], nonce: int) -> dict[str, Any]:
    transactions = package["transactions"]
    if len(transactions) == 1:
        transaction = transactions[0]
        to = transaction["to"]
        value = strict_int(transaction["value"], "Safe value")
        data = transaction["data"]
        operation = 0
    else:
        rc3 = package.get("rc3")
        if not isinstance(rc3, dict):
            raise RC3Error("MultiSend package requires explicit rc3 policy")
        require_exact_fields(
            rc3,
            {"schemaVersion", "allowDelegateCall", "multiSend", "multiSendRuntimeCodeHash"},
            "Safe package rc3 policy",
            {"schemaVersion", "allowDelegateCall", "multiSend", "multiSendRuntimeCodeHash"},
        )
        if rc3["allowDelegateCall"] is not True:
            raise RC3Error("MultiSend delegatecall was not explicitly allowed")
        to = require_address(rc3["multiSend"], "MultiSend address")
        require_hash(rc3["multiSendRuntimeCodeHash"], "MultiSend runtime code hash")
        multi_data = encode_multisend(transactions)
        data = run(["cast", "calldata", "multiSend(bytes)", multi_data])
        value = 0
        operation = 1
    return {
        "to": to,
        "value": str(value),
        "data": data,
        "operation": operation,
        "safeTxGas": "0",
        "baseGas": "0",
        "gasPrice": "0",
        "gasToken": ZERO_ADDRESS,
        "refundReceiver": ZERO_ADDRESS,
        "nonce": str(nonce),
    }


def validate_multisend_target(package: dict[str, Any], network: str, rpc: str) -> None:
    if len(package["transactions"]) == 1:
        return
    rc3 = package.get("rc3")
    if not isinstance(rc3, dict):
        raise RC3Error("MultiSend package requires explicit rc3 policy")
    address = require_address(rc3.get("multiSend"), "MultiSend address")
    expected_hash = require_hash(rc3.get("multiSendRuntimeCodeHash"), "MultiSend runtime code hash")
    manifest_path = ROOT / "artifacts" / network / "infrastructure" / "safes.json"
    if not manifest_path.is_file() or manifest_path.is_symlink():
        raise RC3Error("canonical Safe topology manifest is required before MultiSend signing")
    manifest = load_json(manifest_path)
    validate_safes_manifest(manifest, network)
    if address.lower() != manifest["multiSend"].lower() or expected_hash.lower() != manifest["multiSendRuntimeCodeHash"].lower():
        raise RC3Error("MultiSend package does not match the canonical Safe topology manifest")
    if code_hash(address, rpc).lower() != expected_hash.lower():
        raise RC3Error("MultiSend runtime code hash mismatch")


def safe_tx_hash(rpc: str, safe: str, transaction: dict[str, Any]) -> str:
    value = cast_call(
        rpc,
        safe,
        "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)",
        transaction["to"],
        transaction["value"],
        transaction["data"],
        str(transaction["operation"]),
        transaction["safeTxGas"],
        transaction["baseGas"],
        transaction["gasPrice"],
        transaction["gasToken"],
        transaction["refundReceiver"],
        transaction["nonce"],
    )
    return require_hash(value, "Safe transaction hash")


def safe_package_network(package: dict[str, Any]) -> str:
    chain_id = strict_int(package["chainId"], "Safe package chainId")
    if chain_id == SEPOLIA_CHAIN_ID:
        return "sepolia"
    if chain_id == LOCAL_CHAIN_ID and os.environ.get("BINI_RC3A_LOCAL_REHEARSAL") == "1":
        return "anvil-rc3a"
    raise RC3Error("Safe package chain is not allowed")


def decoded_calls(package: dict[str, Any]) -> list[dict[str, Any]]:
    calls = []
    for index, transaction in enumerate(package["transactions"]):
        data = transaction["data"]
        calls.append(
            {
                "index": index,
                "operation": "CALL",
                "to": transaction["to"],
                "value": str(transaction["value"]),
                "selector": data[:10] if len(data) >= 10 else "0x",
                "calldataKeccak256": run(["cast", "keccak", data]),
                "contractMethod": transaction.get("contractMethod"),
                "contractInputsValues": transaction.get("contractInputsValues"),
            }
        )
    return calls


def command_safe_tx_inspect(args: argparse.Namespace) -> None:
    package = load_safe_package(args.package)
    network = safe_package_network(package)
    rpc = rpc_url(network)
    safe = package["meta"]["createdFromSafeAddress"]
    nonce = strict_int(cast_call(rpc, safe, "nonce()(uint256)"), "Safe nonce")
    transaction = normalize_safe_transaction(package, nonce)
    validate_multisend_target(package, network, rpc)
    result = {
        "status": "INSPECTED",
        "network": network,
        "chainId": package["chainId"],
        "safe": safe,
        "nonce": nonce,
        "safeTxHash": safe_tx_hash(rpc, safe, transaction),
        "normalizedTransaction": transaction,
        "decodedCalls": decoded_calls(package),
    }
    print(json.dumps(result, indent=2, sort_keys=True))


def account_keystore(account_name: str) -> Path | None:
    explicit = os.environ.get("BINI_TEST_KEYSTORE_DIR")
    if not explicit:
        return None
    directory = external_keystore_path(explicit)
    if not directory.is_dir():
        raise RC3Error(f"external keystore directory is missing: {directory}")
    permissions = stat.S_IMODE(directory.stat().st_mode)
    if permissions & 0o077:
        raise RC3Error(f"keystore directory permissions are too broad ({oct(permissions)}): {directory}")
    keystore = find_account_file(directory, account_name)
    if keystore is None:
        raise RC3Error(f"missing encrypted keystore for configured account: {account_name}")
    return keystore


def signing_wallet_args(account_name: str) -> list[str]:
    keystore = account_keystore(account_name)
    if keystore:
        result = ["--keystore", str(keystore)]
        password_file = os.environ.get("BINI_TEST_KEYSTORE_PASSWORD_FILE")
        if password_file:
            password_path = external_secret_file(password_file, "keystore password file")
            result.extend(["--password-file", str(password_path)])
        elif os.environ.get("BINI_RC3A_TEST_MODE") == "1":
            result.extend(["--password", os.environ.get("BINI_RC3A_TEST_KEYSTORE_PASSWORD", "rc3a-ephemeral-only")])
        else:
            raise RC3Error("external keystore signing requires BINI_TEST_KEYSTORE_PASSWORD_FILE")
        return result
    return ["--account", account_name]


def signing_account_address(account_name: str) -> str:
    keystore = account_keystore(account_name)
    if keystore:
        return read_public_keystore_address(keystore)
    return require_address(run(["cast", "wallet", "address", "--account", account_name]), "signer address")


def signature_dir(network: str, tx_hash: str) -> Path:
    return ROOT / "artifacts" / network / "safe-tx" / "signatures" / tx_hash[2:]


def validate_signature_bundle(bundle: dict[str, Any], network: str) -> None:
    require_exact_fields(
        bundle,
        {"schemaVersion", "network", "chainId", "safe", "safeTxHash", "nonce", "transaction", "signatures", "createdAt"},
        "Safe signature bundle",
        {"schemaVersion", "network", "chainId", "safe", "safeTxHash", "nonce", "transaction", "signatures", "createdAt"},
    )
    if bundle["network"] != network or strict_int(bundle["chainId"], "bundle.chainId") != network_chain_id(network):
        raise RC3Error("signature bundle network/chain mismatch")
    require_address(bundle["safe"], "bundle Safe")
    require_hash(bundle["safeTxHash"], "bundle Safe transaction hash")
    strict_int(bundle["nonce"], "bundle nonce")
    transaction = bundle["transaction"]
    validate_normalized_safe_transaction(transaction)
    if not isinstance(transaction, dict):
        raise RC3Error("bundle transaction must be an object")
    require_exact_fields(
        transaction,
        {"to", "value", "data", "operation", "safeTxGas", "baseGas", "gasPrice", "gasToken", "refundReceiver", "nonce"},
        "bundle transaction",
        {"to", "value", "data", "operation", "safeTxGas", "baseGas", "gasPrice", "gasToken", "refundReceiver", "nonce"},
    )
    if strict_int(transaction["nonce"], "bundle transaction nonce") != strict_int(bundle["nonce"], "bundle nonce"):
        raise RC3Error("signature bundle nonce differs from normalized transaction nonce")
    signatures = bundle["signatures"]
    if not isinstance(signatures, list) or not signatures:
        raise RC3Error("signature bundle has no signatures")
    seen = set()
    previous = ""
    for index, signature in enumerate(signatures):
        if not isinstance(signature, dict):
            raise RC3Error("signature entry must be an object")
        require_exact_fields(signature, {"accountName", "owner", "signature", "createdAt"}, f"signature {index}", {"accountName", "owner", "signature", "createdAt"})
        owner = require_address(signature["owner"], "signature owner").lower()
        if owner in seen:
            raise RC3Error("duplicate Safe owner signature")
        if previous and owner <= previous:
            raise RC3Error("Safe signatures are not strictly owner-sorted")
        seen.add(owner)
        previous = owner
        raw = signature["signature"]
        if not isinstance(raw, str) or not re.fullmatch(r"0x[0-9a-fA-F]{130}", raw):
            raise RC3Error("invalid ECDSA signature encoding")


def validate_normalized_safe_transaction(transaction: Any) -> None:
    if not isinstance(transaction, dict):
        raise RC3Error("normalized Safe transaction must be an object")
    fields = {"to", "value", "data", "operation", "safeTxGas", "baseGas", "gasPrice", "gasToken", "refundReceiver", "nonce"}
    require_exact_fields(transaction, fields, "normalized Safe transaction", fields)
    require_address(transaction["to"], "normalized Safe target")
    for key in ("value", "safeTxGas", "baseGas", "gasPrice", "nonce"):
        strict_int(transaction[key], f"normalized Safe transaction {key}")
    operation = strict_int(transaction["operation"], "normalized Safe operation")
    if operation not in {0, 1}:
        raise RC3Error("normalized Safe operation must be CALL or approved MultiSend delegatecall")
    if not isinstance(transaction["data"], str) or not re.fullmatch(r"0x(?:[0-9a-fA-F]{2})*", transaction["data"]):
        raise RC3Error("normalized Safe calldata is invalid")
    require_address(transaction["gasToken"], "normalized Safe gas token", allow_zero=True)
    require_address(transaction["refundReceiver"], "normalized Safe refund receiver", allow_zero=True)


def command_safe_tx_sign(args: argparse.Namespace) -> None:
    package = load_safe_package(args.package)
    network = safe_package_network(package)
    rpc = rpc_url(network)
    safe = package["meta"]["createdFromSafeAddress"]
    nonce = strict_int(cast_call(rpc, safe, "nonce()(uint256)"), "Safe nonce")
    transaction = normalize_safe_transaction(package, nonce)
    validate_multisend_target(package, network, rpc)
    tx_hash = safe_tx_hash(rpc, safe, transaction)
    owner = signing_account_address(args.account)
    owners = {item.lower() for item in parse_address_array(cast_call(rpc, safe, "getOwners()(address[])"), "Safe owners")}
    if owner.lower() not in owners:
        raise RC3Error("signing account is not a Safe owner")
    directory = signature_dir(network, tx_hash)
    individual_path = directory / f"signature-{owner.lower()}.json"
    if individual_path.exists():
        individual = load_json(individual_path)
        require_exact_fields(individual, {"accountName", "owner", "signature", "createdAt"}, "existing signature", {"accountName", "owner", "signature", "createdAt"})
        if individual["accountName"] != args.account or str(individual["owner"]).lower() != owner.lower():
            raise RC3Error("existing signature identity does not match requested account")
        signature = individual["signature"]
    else:
        signature = run(["cast", "wallet", "sign", "--no-hash", *signing_wallet_args(args.account), tx_hash])
        if not re.fullmatch(r"0x[0-9a-fA-F]{130}", signature):
            raise RC3Error("wallet returned an invalid signature")
        individual = {
            "accountName": args.account,
            "owner": owner,
            "signature": signature,
            "createdAt": now_utc(),
        }
        immutable_write(individual_path, individual)
    run(["cast", "wallet", "verify", "--no-hash", "--address", owner, tx_hash, signature])
    signatures = []
    for path in sorted(directory.glob("signature-0x*.json")):
        item = load_json(path)
        signatures.append(item)
    signatures.sort(key=lambda item: item["owner"].lower())
    bundle = {
        "schemaVersion": "1.0",
        "network": network,
        "chainId": network_chain_id(network),
        "safe": safe,
        "safeTxHash": tx_hash,
        "nonce": nonce,
        "transaction": transaction,
        "signatures": signatures,
        "createdAt": max(item["createdAt"] for item in signatures),
    }
    bundle_digest = hashlib.sha256(json.dumps(signatures, sort_keys=True).encode()).hexdigest()[:12]
    output = immutable_write(directory / f"signature-bundle-{len(signatures)}-{bundle_digest}.json", bundle)
    print(output)


def packed_signatures(bundle: dict[str, Any]) -> str:
    return "0x" + "".join(item["signature"][2:] for item in bundle["signatures"])


def command_safe_tx_execute(args: argparse.Namespace) -> None:
    package = load_safe_package(args.package)
    package_network = safe_package_network(package)
    if args.network != package_network and not (is_local_network(args.network) and is_local_network(package_network)):
        raise RC3Error("Safe execution network does not match package")
    ensure_write_network(args.network, "SAFE_EXECUTE", safe_owned=True)
    bundle = load_json(args.signatures)
    validate_signature_bundle(bundle, package_network)
    rpc = rpc_url(args.network)
    safe = package["meta"]["createdFromSafeAddress"]
    if bundle["safe"].lower() != safe.lower():
        raise RC3Error("signature bundle Safe mismatch")
    validate_multisend_target(package, package_network, rpc)
    current_nonce = strict_int(cast_call(rpc, safe, "nonce()(uint256)"), "Safe nonce")
    bundle_nonce = strict_int(bundle["nonce"], "bundle nonce")
    receipt_dir = ROOT / "artifacts" / args.network / "safe-tx" / "receipts"
    existing_path = receipt_dir / f"safe-execution-{bundle['safeTxHash'][2:]}.json"
    if current_nonce > bundle_nonce and existing_path.exists():
        if existing_path.is_symlink() or not existing_path.is_file():
            raise RC3Error("existing Safe receipt must be a regular non-symlink file")
        existing = load_json(existing_path)
        validate_safe_execution_receipt(existing, args.network, rpc)
        if (
            existing["safe"].lower() != safe.lower()
            or existing["safeTxHash"].lower() != bundle["safeTxHash"].lower()
            or strict_int(existing["nonce"], "existing receipt nonce") != bundle_nonce
            or existing["transaction"] != bundle["transaction"]
        ):
            raise RC3Error("existing Safe receipt does not match the signed bundle")
        print(json.dumps({"status": "ALREADY_EXECUTED", "receipt": str(existing_path)}, indent=2))
        return
    if current_nonce != bundle_nonce:
        raise RC3Error(f"Safe nonce mismatch: current {current_nonce}, signed {bundle_nonce}")
    normalized = normalize_safe_transaction(package, bundle_nonce)
    computed = safe_tx_hash(rpc, safe, normalized)
    if computed.lower() != bundle["safeTxHash"].lower() or normalized != bundle["transaction"]:
        raise RC3Error("package calldata changed after signing")
    owners = {item.lower() for item in parse_address_array(cast_call(rpc, safe, "getOwners()(address[])"), "Safe owners")}
    threshold = strict_int(cast_call(rpc, safe, "getThreshold()(uint256)"), "Safe threshold")
    if len(bundle["signatures"]) < threshold:
        raise RC3Error("insufficient Safe signatures")
    for signature in bundle["signatures"]:
        if signature["owner"].lower() not in owners:
            raise RC3Error("non-owner Safe signature")
        run(["cast", "wallet", "verify", "--no-hash", "--address", signature["owner"], bundle["safeTxHash"], signature["signature"]])
    call_args = [
        safe,
        "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)(bool)",
        normalized["to"],
        normalized["value"],
        normalized["data"],
        str(normalized["operation"]),
        normalized["safeTxGas"],
        normalized["baseGas"],
        normalized["gasPrice"],
        normalized["gasToken"],
        normalized["refundReceiver"],
        packed_signatures(bundle),
        "--rpc-url",
        rpc,
        "--json",
    ]
    if is_local_network(args.network):
        submitter = require_address(os.environ.get("BINI_SAFE_EXECUTOR_ADDRESS"), "BINI_SAFE_EXECUTOR_ADDRESS")
        call_args.extend(["--unlocked", "--from", submitter])
    else:
        submitter_account = os.environ.get("SAFE_EXECUTOR_ACCOUNT")
        if not submitter_account:
            raise RC3Error("SAFE_EXECUTE requires SAFE_EXECUTOR_ACCOUNT encrypted keystore")
        call_args.extend(signing_wallet_args(submitter_account))
    receipt = run_json(["cast", "send", *call_args], "Safe execution")
    tx_hash = receipt.get("transactionHash") or receipt.get("hash")
    require_hash(tx_hash, "Safe execution transaction")
    status = strict_int(receipt.get("status", 0), "Safe execution status")
    if status != 1:
        raise RC3Error("Safe execution transaction reverted")
    success_topic = run(["cast", "keccak", "ExecutionSuccess(bytes32,uint256)"]).lower()
    success = any(
        isinstance(log, dict)
        and str(log.get("address", "")).lower() == safe.lower()
        and len(log.get("topics", [])) >= 2
        and str(log["topics"][0]).lower() == success_topic
        and str(log["topics"][1]).lower() == bundle["safeTxHash"].lower()
        for log in receipt.get("logs", [])
    )
    if not success:
        raise RC3Error("Safe ExecutionSuccess event is missing")
    evidence = {
        "schemaVersion": "1.0",
        "network": args.network,
        "chainId": network_chain_id(args.network),
        "safe": safe,
        "safeTxHash": bundle["safeTxHash"],
        "nonce": bundle_nonce,
        "transactionHash": tx_hash,
        "blockNumber": strict_int(receipt["blockNumber"], "Safe execution block"),
        "status": "EXECUTED",
        "signers": [item["owner"] for item in bundle["signatures"]],
        "transaction": normalized,
        "rawReceipt": receipt,
        "verifiedAt": now_utc(),
    }
    output = immutable_write(existing_path, evidence)
    print(output)


def validate_safe_execution_receipt(receipt: dict[str, Any], network: str, rpc: str) -> None:
    require_exact_fields(
        receipt,
        {"schemaVersion", "network", "chainId", "safe", "safeTxHash", "nonce", "transactionHash", "blockNumber", "status", "signers", "transaction", "rawReceipt", "verifiedAt"},
        "Safe execution receipt",
        {"schemaVersion", "network", "chainId", "safe", "safeTxHash", "nonce", "transactionHash", "blockNumber", "status", "signers", "transaction"},
    )
    if receipt["network"] != network or strict_int(receipt["chainId"], "receipt chain") != network_chain_id(network):
        raise RC3Error("Safe execution receipt network/chain mismatch")
    safe = require_address(receipt["safe"], "receipt Safe")
    safe_hash = require_hash(receipt["safeTxHash"], "receipt Safe transaction hash")
    transaction_hash = require_hash(receipt["transactionHash"], "receipt transaction hash")
    nonce = strict_int(receipt["nonce"], "receipt nonce")
    if receipt["status"] != "EXECUTED":
        raise RC3Error("Safe receipt status is not EXECUTED")
    validate_normalized_safe_transaction(receipt["transaction"])
    if strict_int(receipt["transaction"]["nonce"], "receipt transaction nonce") != nonce:
        raise RC3Error("Safe receipt nonce differs from normalized transaction nonce")
    computed_hash = safe_tx_hash(rpc, safe, receipt["transaction"])
    if computed_hash.lower() != safe_hash.lower():
        raise RC3Error("Safe receipt transaction does not reproduce safeTxHash")
    chain_receipt = run_json(["cast", "receipt", transaction_hash, "--rpc-url", rpc, "--json"], "on-chain receipt")
    if strict_int(chain_receipt.get("status", 0), "on-chain receipt status") != 1:
        raise RC3Error("on-chain Safe execution was not successful")
    if str(chain_receipt.get("transactionHash") or chain_receipt.get("hash") or "").lower() != transaction_hash.lower():
        raise RC3Error("on-chain Safe execution transaction hash mismatch")
    if str(chain_receipt.get("to", "")).lower() != safe.lower():
        raise RC3Error("on-chain receipt Safe mismatch")
    if strict_int(chain_receipt.get("blockNumber"), "on-chain receipt block") != strict_int(receipt["blockNumber"], "receipt block"):
        raise RC3Error("on-chain Safe execution block mismatch")
    success_topic = run(["cast", "keccak", "ExecutionSuccess(bytes32,uint256)"]).lower()
    if not any(
        isinstance(log, dict)
        and str(log.get("address", "")).lower() == safe.lower()
        and isinstance(log.get("topics"), list)
        and len(log["topics"]) >= 2
        and str(log["topics"][0]).lower() == success_topic
        and str(log["topics"][1]).lower() == safe_hash.lower()
        for log in chain_receipt.get("logs", [])
    ):
        raise RC3Error("on-chain Safe ExecutionSuccess event/hash is missing")
    raw_receipt = receipt.get("rawReceipt")
    if not isinstance(raw_receipt, dict):
        raise RC3Error("Safe receipt rawReceipt must be an object")
    for key, expected in (("to", safe), ("transactionHash", transaction_hash)):
        actual = raw_receipt.get(key) or (raw_receipt.get("hash") if key == "transactionHash" else None)
        if str(actual or "").lower() != expected.lower():
            raise RC3Error(f"Safe raw receipt {key} mismatch")
    if strict_int(raw_receipt.get("status", 0), "raw receipt status") != 1:
        raise RC3Error("Safe raw receipt status mismatch")
    if strict_int(raw_receipt.get("blockNumber"), "raw receipt block") != strict_int(receipt["blockNumber"], "receipt block"):
        raise RC3Error("Safe raw receipt block mismatch")
    signers = receipt["signers"]
    if not isinstance(signers, list) or not signers:
        raise RC3Error("Safe receipt signers are missing")
    normalized_signers = [require_address(item, "Safe receipt signer").lower() for item in signers]
    if normalized_signers != sorted(set(normalized_signers)):
        raise RC3Error("Safe receipt signers must be distinct and sorted")
    owners = {item.lower() for item in parse_address_array(cast_call(rpc, safe, "getOwners()(address[])"), "Safe owners")}
    threshold = strict_int(cast_call(rpc, safe, "getThreshold()(uint256)"), "Safe threshold")
    if len(normalized_signers) < threshold or any(item not in owners for item in normalized_signers):
        raise RC3Error("Safe receipt signers do not satisfy the Safe threshold")
    current_nonce = strict_int(cast_call(rpc, safe, "nonce()(uint256)"), "Safe nonce")
    if current_nonce <= nonce:
        raise RC3Error("Safe nonce does not prove execution of the recorded transaction")


def command_safe_tx_verify(args: argparse.Namespace) -> None:
    receipt = load_json(args.receipt)
    rpc = rpc_url(args.network)
    validate_safe_execution_receipt(receipt, args.network, rpc)
    print(json.dumps({"status": "VERIFIED", "safeTxHash": receipt["safeTxHash"], "transactionHash": receipt["transactionHash"]}, indent=2))


def safe_builder(chain_id: int, safe: str, name: str, transactions: list[dict[str, Any]], *, multisend: dict[str, str] | None = None) -> dict[str, Any]:
    package: dict[str, Any] = {
        "version": "1.0",
        "chainId": str(chain_id),
        "createdAt": now_utc(),
        "meta": {
            "name": name,
            "description": "Generated by ./bin/bini-v2 RC3 automation",
            "txBuilderVersion": "1.18.0",
            "createdFromSafeAddress": require_address(safe, "Safe"),
        },
        "transactions": transactions,
    }
    if len(transactions) > 1:
        if not multisend:
            raise RC3Error("multi-transaction Safe package requires pinned MultiSend policy")
        package["rc3"] = {
            "schemaVersion": "1.0",
            "allowDelegateCall": True,
            "multiSend": require_address(multisend["address"], "MultiSend"),
            "multiSendRuntimeCodeHash": require_hash(multisend["runtimeCodeHash"], "MultiSend runtime hash"),
        }
    return package


def safe_call(target: str, data: str, *, value: int = 0, method: dict[str, Any] | None = None, inputs: dict[str, Any] | None = None) -> dict[str, Any]:
    return {
        "to": require_address(target, "Safe call target"),
        "value": str(value),
        "data": data,
        "contractMethod": method,
        "contractInputsValues": inputs,
        "operation": 0,
    }


def validate_timelock_operation(operation: dict[str, Any]) -> None:
    require_exact_fields(
        operation,
        {
            "schemaVersion", "network", "chainId", "timelock", "proposerSafe", "cancellerSafe", "executorSafe",
            "target", "value", "data", "predecessor", "salt", "delaySeconds", "operationId", "description", "createdAt",
        },
        "Timelock operation",
        {
            "schemaVersion", "network", "chainId", "timelock", "proposerSafe", "cancellerSafe", "executorSafe",
            "target", "value", "data", "predecessor", "salt", "delaySeconds", "operationId", "description", "createdAt",
        },
    )
    network = operation["network"]
    if strict_int(operation["chainId"], "operation chain") != network_chain_id(network):
        raise RC3Error("Timelock operation network/chain mismatch")
    for key in ("timelock", "proposerSafe", "cancellerSafe", "executorSafe", "target"):
        require_address(operation[key], f"operation {key}")
    strict_int(operation["value"], "operation value")
    strict_int(operation["delaySeconds"], "operation delay")
    require_hash(operation["predecessor"], "operation predecessor")
    require_hash(operation["salt"], "operation salt")
    require_hash(operation["operationId"], "operation id")
    encoded = run(
        [
            "cast", "abi-encode", "f(address,uint256,bytes,bytes32,bytes32)", operation["target"],
            str(operation["value"]), operation["data"], operation["predecessor"], operation["salt"],
        ]
    )
    computed = run(["cast", "keccak", encoded])
    if computed.lower() != operation["operationId"].lower():
        raise RC3Error("Timelock operation id mismatch")


def new_timelock_operation(
    network: str,
    timelock_manifest: dict[str, Any],
    target: str,
    data: str,
    description: str,
    *,
    value: int = 0,
    salt_source: str | None = None,
) -> dict[str, Any]:
    salt = run(["cast", "keccak", salt_source or f"BINI_RC3:{network}:{description}:{target}:{data}"])
    predecessor = ZERO_HASH
    encoded = run(["cast", "abi-encode", "f(address,uint256,bytes,bytes32,bytes32)", target, str(value), data, predecessor, salt])
    operation_id = run(["cast", "keccak", encoded])
    operation = {
        "schemaVersion": "1.0",
        "network": network,
        "chainId": network_chain_id(network),
        "timelock": timelock_manifest["address"],
        "proposerSafe": timelock_manifest["proposer"],
        "cancellerSafe": timelock_manifest["canceller"],
        "executorSafe": timelock_manifest["executor"],
        "target": target,
        "value": str(value),
        "data": data,
        "predecessor": predecessor,
        "salt": salt,
        "delaySeconds": str(timelock_manifest["minimumDelaySeconds"]),
        "operationId": operation_id,
        "description": description,
        "createdAt": now_utc(),
    }
    validate_timelock_operation(operation)
    return operation


def timelock_package_for_action(operation: dict[str, Any], action: str) -> dict[str, Any]:
    validate_timelock_operation(operation)
    if action == "schedule":
        data = run(
            [
                "cast", "calldata", "schedule(address,uint256,bytes,bytes32,bytes32,uint256)", operation["target"],
                operation["value"], operation["data"], operation["predecessor"], operation["salt"], operation["delaySeconds"],
            ]
        )
        safe = operation["proposerSafe"]
    elif action == "cancel":
        data = run(["cast", "calldata", "cancel(bytes32)", operation["operationId"]])
        safe = operation["cancellerSafe"]
    elif action == "execute":
        data = run(
            [
                "cast", "calldata", "execute(address,uint256,bytes,bytes32,bytes32)", operation["target"],
                operation["value"], operation["data"], operation["predecessor"], operation["salt"],
            ]
        )
        safe = operation["executorSafe"]
    else:
        raise RC3Error(f"unsupported Timelock action: {action}")
    return safe_builder(
        strict_int(operation["chainId"], "operation chain"),
        safe,
        f"Timelock {action}: {operation['description']}",
        [safe_call(operation["timelock"], data)],
    )


def command_timelock_action(args: argparse.Namespace, action: str) -> None:
    operation = load_json(args.operation)
    package = timelock_package_for_action(operation, action)
    output = versioned_artifact(operation["network"], "timelock-operations", f"{action}-{operation['operationId'][2:14]}", package)
    print(output)


def command_timelock_schedule(args: argparse.Namespace) -> None:
    command_timelock_action(args, "schedule")


def command_timelock_cancel(args: argparse.Namespace) -> None:
    command_timelock_action(args, "cancel")


def command_timelock_execute(args: argparse.Namespace) -> None:
    command_timelock_action(args, "execute")


def command_timelock_operation_status(args: argparse.Namespace) -> None:
    operation = load_json(args.operation)
    validate_timelock_operation(operation)
    rpc = rpc_url(operation["network"])
    timelock = operation["timelock"]
    operation_id = operation["operationId"]
    done = cast_call(rpc, timelock, "isOperationDone(bytes32)(bool)", operation_id).lower() == "true"
    ready = cast_call(rpc, timelock, "isOperationReady(bytes32)(bool)", operation_id).lower() == "true"
    pending = cast_call(rpc, timelock, "isOperationPending(bytes32)(bool)", operation_id).lower() == "true"
    timestamp = strict_int(cast_call(rpc, timelock, "getTimestamp(bytes32)(uint256)", operation_id), "operation timestamp")
    if done:
        state = "DONE"
    elif ready:
        state = "READY"
    elif pending:
        state = "PENDING"
    else:
        cancelled_logs = run_json(
            [
                "cast", "logs", "Cancelled(bytes32)", operation_id, "--address", timelock, "--from-block", "0",
                "--to-block", "latest", "--rpc-url", rpc, "--json",
            ],
            "Timelock cancellation logs",
        )
        state = "CANCELLED" if cancelled_logs else "UNSET"
    print(json.dumps({"operationId": operation_id, "state": state, "timestamp": timestamp}, indent=2, sort_keys=True))


def default_deployment(network: str) -> dict[str, Any]:
    candidates = [
        ROOT / "artifacts" / "deployments" / network / "deployment.json",
        ROOT / "artifacts" / network / "token" / "deployment.json",
    ]
    for candidate in candidates:
        if candidate.exists():
            return load_json(candidate)
    raise RC3Error(f"deployment manifest not found for {network}")


def default_safes(network: str) -> dict[str, Any]:
    manifest = load_json(ROOT / "artifacts" / network / "infrastructure" / "safes.json")
    validate_safes_manifest(manifest, network)
    return manifest


def default_timelock(network: str) -> dict[str, Any]:
    manifest = load_json(ROOT / "artifacts" / network / "infrastructure" / "timelock.json")
    validate_timelock_manifest(manifest, network)
    return manifest


def token_address(deployment: dict[str, Any]) -> str:
    return require_address(deployment.get("proxy") or deployment.get("token"), "token proxy")


def command_pause_plan(args: argparse.Namespace) -> None:
    deployment = default_deployment(args.network)
    safes = default_safes(args.network)
    token = token_address(deployment)
    data = run(["cast", "calldata", "pause()"])
    package = safe_builder(network_chain_id(args.network), safe_by_purpose(safes, "SECURITY_SAFE"), "Pause BINI V2", [safe_call(token, data)])
    output = versioned_artifact(args.network, "pause", "pause-plan", package)
    print(output)


def command_pause_verify(args: argparse.Namespace) -> None:
    receipt = load_json(args.receipt)
    rpc = rpc_url(args.network)
    validate_safe_execution_receipt(receipt, args.network, rpc)
    token = token_address(default_deployment(args.network))
    if cast_call(rpc, token, "paused()(bool)").lower() != "true":
        raise RC3Error("token is not paused after pause execution")
    print(json.dumps({"status": "VERIFIED", "paused": True, "receipt": args.receipt}, indent=2))


def command_unpause_plan(args: argparse.Namespace) -> None:
    deployment = default_deployment(args.network)
    timelock = default_timelock(args.network)
    token = token_address(deployment)
    salt_reference = getattr(args, "salt_reference", None)
    if not salt_reference:
        rpc = rpc_url(args.network)
        nonce = strict_int(cast_call(rpc, timelock["proposer"], "nonce()(uint256)"), "Governance Safe nonce")
        salt_reference = f"governance-safe-nonce:{nonce}"
    operation = new_timelock_operation(
        args.network,
        timelock,
        token,
        run(["cast", "calldata", "unpause()"]),
        "Unpause BINI V2",
        salt_source=f"BINI_RC3:{args.network}:Unpause BINI V2:{salt_reference}",
    )
    operation_path = versioned_artifact(args.network, "timelock-operations", "unpause-operation", operation)
    package = timelock_package_for_action(operation, "schedule")
    package_path = versioned_artifact(args.network, "unpause", "unpause-schedule", package)
    print(json.dumps({"operation": str(operation_path), "schedulePackage": str(package_path)}, indent=2))


def command_unpause_verify(args: argparse.Namespace) -> None:
    receipt = load_json(args.receipt)
    rpc = rpc_url(args.network)
    validate_safe_execution_receipt(receipt, args.network, rpc)
    token = token_address(default_deployment(args.network))
    if cast_call(rpc, token, "paused()(bool)").lower() != "false":
        raise RC3Error("token remains paused after Timelock unpause")
    print(json.dumps({"status": "VERIFIED", "paused": False, "receipt": args.receipt}, indent=2))


def deployment_from_receipt(receipt_path: Path, contract_name: str, network: str, extra: dict[str, Any]) -> dict[str, Any]:
    transactions, receipts = broadcast_transactions(receipt_path)
    address = deployed_contract(transactions, contract_name)
    receipt = receipts[0]
    return {
        "schemaVersion": "1.0",
        "network": network,
        "chainId": network_chain_id(network),
        "address": address,
        "deploymentTransaction": require_hash(receipt["transactionHash"], "deployment transaction"),
        "deploymentBlock": strict_int(receipt["blockNumber"], "deployment block"),
        "runtimeCodeHash": code_hash(address, rpc_url(network)),
        "broadcastReceipt": str(receipt_path.relative_to(ROOT)),
        "sourceCommit": run(["git", "rev-parse", "HEAD"]),
        "createdAt": now_utc(),
        **extra,
    }


def command_migration_fixture_deploy(args: argparse.Namespace) -> None:
    if args.network == "mainnet":
        raise RC3Error("Migration Vault workflow is TESTNET_PROTOTYPE_ONLY and forbidden on Mainnet")
    selected_mode = mode(args)
    if selected_mode not in {"PLAN", "SIMULATE", "BROADCAST"}:
        raise RC3Error("migration fixture deploy supports PLAN, SIMULATE or BROADCAST")
    ensure_write_network(args.network, selected_mode)
    if selected_mode == "PLAN":
        print(json.dumps({"network": args.network, "name": "BINI V1 Test Fixture", "decimals": 12, "mainnetAddressRelationship": "NONE", "mode": "PLAN"}, indent=2))
        return
    manifest_path = ROOT / "artifacts" / args.network / "migration" / "fixture.json"
    if selected_mode == "BROADCAST" and manifest_path.exists():
        manifest = load_json(manifest_path)
        require_artifact_source(manifest, "migration fixture manifest")
        rpc = rpc_url(args.network)
        if strict_int(cast_call(rpc, manifest["address"], "decimals()(uint8)"), "fixture decimals") != 12:
            raise RC3Error("recorded migration fixture has wrong decimals")
        print(json.dumps({"status": "ALREADY_DEPLOYED", "manifest": str(manifest_path)}, indent=2))
        return
    admin = os.environ.get("BINI_V1_FIXTURE_ADMIN") or os.environ.get("BINI_LOCAL_DEPLOYER") or os.environ.get("DEPLOYER_ADDRESS")
    env = os.environ.copy()
    env.update({"BINI_V2_EXPECTED_CHAIN_ID": str(network_chain_id(args.network)), "BINI_V1_FIXTURE_ADMIN": require_address(admin, "fixture admin")})
    receipt_path = foundry_broadcast(args.network, "script/DeployMigrationFixture.s.sol:DeployMigrationFixture", env, selected_mode)
    if selected_mode == "SIMULATE":
        print(versioned_artifact(args.network, "migration", "fixture-simulation", {"status": "SIMULATED", "network": args.network, "decimals": 12, "checkedAt": now_utc()}))
        return
    assert receipt_path is not None
    manifest = deployment_from_receipt(
        receipt_path,
        "BiniV1TestFixture",
        args.network,
        {"fixture": True, "sepoliaOnly": True, "name": "BINI V1 Test Fixture", "decimals": 12, "fixtureAdmin": admin},
    )
    output = immutable_write(manifest_path, manifest)
    print(output)


def command_migration_vault_deploy(args: argparse.Namespace) -> None:
    if args.network == "mainnet":
        raise RC3Error("BiniMigrationVault is removed from Mainnet launch scope")
    selected_mode = mode(args)
    if selected_mode not in {"PLAN", "SIMULATE", "BROADCAST"}:
        raise RC3Error("migration vault deploy supports PLAN, SIMULATE or BROADCAST")
    ensure_write_network(args.network, selected_mode)
    config = load_json(args.migration_config)
    fixture = load_json(ROOT / "artifacts" / args.network / "migration" / "fixture.json") if config.get("v1Token") in {None, ZERO_ADDRESS, "FROM_FIXTURE_MANIFEST"} else None
    deployment = default_deployment(args.network)
    timelock = default_timelock(args.network)
    v1 = fixture["address"] if fixture else require_address(config.get("v1Token"), "migration V1")
    v2 = token_address(deployment)
    if selected_mode == "PLAN":
        print(json.dumps({"network": args.network, "v1Token": v1, "v2Token": v2, "adminTimelock": timelock["address"], "mode": "PLAN"}, indent=2))
        return
    manifest_path = ROOT / "artifacts" / args.network / "migration" / "vault.json"
    if selected_mode == "BROADCAST" and manifest_path.exists():
        manifest = load_json(manifest_path)
        require_artifact_source(manifest, "Migration Vault manifest")
        rpc = rpc_url(args.network)
        if cast_call(rpc, manifest["address"], "v1Token()(address)").lower() != v1.lower() or cast_call(rpc, manifest["address"], "v2Token()(address)").lower() != v2.lower():
            raise RC3Error("recorded Migration Vault token links do not match current inputs")
        print(json.dumps({"status": "ALREADY_DEPLOYED", "manifest": str(manifest_path)}, indent=2))
        return
    env = os.environ.copy()
    env.update(
        {
            "BINI_V2_EXPECTED_CHAIN_ID": str(network_chain_id(args.network)),
            "BINI_MIGRATION_V1_TOKEN": v1,
            "BINI_MIGRATION_V2_TOKEN": v2,
            "BINI_MIGRATION_TIMELOCK": timelock["address"],
        }
    )
    receipt_path = foundry_broadcast(args.network, "script/DeployMigrationVault.s.sol:DeployMigrationVault", env, selected_mode)
    if selected_mode == "SIMULATE":
        print(versioned_artifact(args.network, "migration", "vault-simulation", {"status": "SIMULATED", "network": args.network, "checkedAt": now_utc()}))
        return
    assert receipt_path is not None
    manifest = deployment_from_receipt(receipt_path, "BiniMigrationVault", args.network, {"v1Token": v1, "v2Token": v2, "adminTimelock": timelock["address"]})
    output = immutable_write(manifest_path, manifest)
    print(output)


def load_holders_csv(path: str | Path) -> list[dict[str, str]]:
    resolved = resolved_path(path)
    with resolved.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    if not rows:
        raise RC3Error("holder manifest is empty")
    return rows


def command_migration_fund_plan(args: argparse.Namespace) -> None:
    if args.network == "mainnet":
        raise RC3Error("Migration Vault funding is removed from Mainnet launch scope")
    rows = load_holders_csv(args.holders)
    vault = load_json(ROOT / "artifacts" / args.network / "migration" / "vault.json")
    v2 = require_address(vault["v2Token"], "vault V2 token")
    liabilities: dict[tuple[str, str], int] = {}
    for row in rows:
        allocation = row.get("sourceAllocationId", "")
        source = require_address(row.get("sourceTopLevelSafe"), "holder sourceTopLevelSafe")
        amount = strict_int(row.get("v2RawAmount"), "holder v2RawAmount")
        liabilities[(allocation, source)] = liabilities.get((allocation, source), 0) + amount
    packages = []
    for (allocation, source), amount in sorted(liabilities.items()):
        data = run(["cast", "calldata", "transfer(address,uint256)", vault["address"], str(amount)])
        package = safe_builder(network_chain_id(args.network), source, f"Fund migration liability: {allocation}", [safe_call(v2, data)])
        package_path = versioned_artifact(args.network, "migration-funding", f"fund-{allocation}", package)
        packages.append({"sourceAllocationId": allocation, "sourceTopLevelSafe": source, "amountRaw": str(amount), "package": str(package_path)})
    plan = {"schemaVersion": "1.0", "network": args.network, "chainId": network_chain_id(args.network), "vault": vault["address"], "fundingSources": packages, "totalRaw": str(sum(liabilities.values())), "createdAt": now_utc()}
    output = versioned_artifact(args.network, "migration-funding", "funding-plan", plan)
    print(output)


def command_migration_fund_verify(args: argparse.Namespace) -> None:
    if args.network == "mainnet":
        raise RC3Error("Migration Vault verification is testnet/research only")
    rpc = rpc_url(args.network)
    plan = load_json(args.plan)
    require_exact_fields(plan, {"schemaVersion", "network", "chainId", "vault", "fundingSources", "totalRaw", "createdAt"}, "migration funding plan", {"schemaVersion", "network", "chainId", "vault", "fundingSources", "totalRaw", "createdAt"})
    if plan["network"] != args.network or strict_int(plan["chainId"], "funding plan chain") != network_chain_id(args.network):
        raise RC3Error("migration funding plan network/chain mismatch")
    vault = load_json(ROOT / "artifacts" / args.network / "migration" / "vault.json")
    if require_address(plan["vault"], "funding plan vault").lower() != require_address(vault["address"], "Migration Vault").lower():
        raise RC3Error("migration funding plan vault mismatch")
    sources = plan["fundingSources"]
    receipt_paths = args.receipt
    if not isinstance(sources, list) or not sources or len(receipt_paths) != len(sources):
        raise RC3Error("one Safe execution receipt is required for every migration funding source")
    seen_transactions: set[str] = set()
    verified_sources = []
    for index, (source, receipt_path) in enumerate(zip(sources, receipt_paths)):
        if not isinstance(source, dict):
            raise RC3Error(f"migration funding source {index} must be an object")
        require_exact_fields(source, {"sourceAllocationId", "sourceTopLevelSafe", "amountRaw", "package"}, f"migration funding source {index}", {"sourceAllocationId", "sourceTopLevelSafe", "amountRaw", "package"})
        source_safe = require_address(source["sourceTopLevelSafe"], "migration funding source Safe")
        amount = strict_int(source["amountRaw"], "migration funding amount")
        if amount <= 0:
            raise RC3Error("migration funding amount must be positive")
        receipt = load_json(receipt_path)
        validate_safe_execution_receipt(receipt, args.network, rpc)
        transaction_hash = receipt["transactionHash"].lower()
        if transaction_hash in seen_transactions:
            raise RC3Error("duplicate migration funding execution receipt")
        seen_transactions.add(transaction_hash)
        expected_data = run(["cast", "calldata", "transfer(address,uint256)", vault["address"], str(amount)])
        transaction = receipt["transaction"]
        if (
            receipt["safe"].lower() != source_safe.lower()
            or transaction["to"].lower() != require_address(vault["v2Token"], "vault V2 token").lower()
            or transaction["data"].lower() != expected_data.lower()
            or strict_int(transaction["operation"], "migration funding Safe operation") != 0
            or strict_int(transaction["value"], "migration funding ETH value") != 0
        ):
            raise RC3Error(f"migration funding receipt does not match source plan: {source['sourceAllocationId']}")
        verified_sources.append({**source, "receipt": str(receipt_path), "transactionHash": receipt["transactionHash"]})
    balance = strict_int(cast_call(rpc, vault["v2Token"], "balanceOf(address)(uint256)", vault["address"]), "vault V2 balance")
    expected_total = strict_int(plan["totalRaw"], "migration funding total")
    if sum(strict_int(item["amountRaw"], "migration funding source amount") for item in sources) != expected_total or balance != expected_total:
        raise RC3Error("Migration Vault funding does not exactly reconcile to the source plan")
    evidence = {
        "schemaVersion": "1.0",
        "network": args.network,
        "chainId": network_chain_id(args.network),
        "vault": vault["address"],
        "fundingSources": verified_sources,
        "totalRaw": str(expected_total),
        "verifiedAt": now_utc(),
    }
    output = versioned_artifact(args.network, "migration-funding", "funding-verification", evidence)
    print(output)


PRE_MARKET_CASES = (
    "wallet-to-wallet", "wallet-to-safe", "safe-to-wallet", "ordinary-proxy-wallet", "approve", "transferFrom", "permit",
    "registered-v2-pool", "registered-v3-pool", "registered-router-manager", "configured-v4-pool-manager",
    "unknown-contract", "unknown-custom-amm", "future-create2-address", "pause-unpause",
)


def expected_pre_market_classification(name: str) -> str:
    if name in {"registered-v2-pool", "registered-v3-pool", "registered-router-manager", "configured-v4-pool-manager"}:
        return "BLOCKED"
    if name in {"unknown-custom-amm", "future-create2-address"}:
        return "KNOWN_LIMITATION_ALLOWED"
    return "ALLOWED"


def validate_pre_market_receipt(receipt: dict[str, Any], network: str, *, verify_chain: bool) -> None:
    require_exact_fields(
        receipt,
        {"schemaVersion", "network", "chainId", "sourceCommit", "token", "cases", "transactionHashes", "createdAt"},
        "PRE_MARKET receipt",
        {"schemaVersion", "network", "chainId", "sourceCommit", "token", "cases", "transactionHashes", "createdAt"},
    )
    if receipt["schemaVersion"] != "1.0" or receipt["network"] != network:
        raise RC3Error("PRE_MARKET receipt network/schema mismatch")
    if strict_int(receipt["chainId"], "PRE_MARKET chain") != network_chain_id(network):
        raise RC3Error("PRE_MARKET receipt chain mismatch")
    if receipt["sourceCommit"] != current_commit():
        raise RC3Error("PRE_MARKET receipt source commit mismatch")
    token = require_address(receipt["token"], "PRE_MARKET token")
    cases = receipt["cases"]
    if not isinstance(cases, list) or len(cases) != len(PRE_MARKET_CASES):
        raise RC3Error("PRE_MARKET receipt case count mismatch")
    for index, case in enumerate(cases):
        if not isinstance(case, dict):
            raise RC3Error("PRE_MARKET case must be an object")
        require_exact_fields(case, {"name", "passed", "classification"}, f"PRE_MARKET case {index}", {"name", "passed", "classification"})
        name = PRE_MARKET_CASES[index]
        if case["name"] != name or case["passed"] is not True or case["classification"] != expected_pre_market_classification(name):
            raise RC3Error(f"PRE_MARKET case is not canonical: {name}")
    hashes = receipt["transactionHashes"]
    if not isinstance(hashes, list) or (network == "sepolia" and not hashes):
        raise RC3Error("Sepolia PRE_MARKET evidence requires transaction hashes")
    normalized_hashes = [require_hash(item, "PRE_MARKET transaction hash").lower() for item in hashes]
    if len(normalized_hashes) != len(set(normalized_hashes)):
        raise RC3Error("duplicate PRE_MARKET transaction hash")
    if verify_chain:
        rpc = rpc_url(network)
        deployment = default_deployment(network)
        if token.lower() != token_address(deployment).lower():
            raise RC3Error("PRE_MARKET receipt token differs from canonical deployment")
        for transaction_hash in normalized_hashes:
            chain_receipt = run_json(["cast", "receipt", transaction_hash, "--rpc-url", rpc, "--json"], "PRE_MARKET transaction receipt")
            if strict_int(chain_receipt.get("status", 0), "PRE_MARKET transaction status") != 1:
                raise RC3Error(f"PRE_MARKET transaction failed: {transaction_hash}")


def command_test_pre_market_plan(args: argparse.Namespace) -> None:
    plan = {"schemaVersion": "1.0", "network": args.network, "chainId": network_chain_id(args.network), "cases": list(PRE_MARKET_CASES), "disposableActorsOnly": True, "expectedMarketState": "PRE_MARKET", "mode": "PLAN"}
    print(json.dumps(plan, indent=2, sort_keys=True))


def command_test_pre_market_run(args: argparse.Namespace) -> None:
    network_chain_id(args.network)
    receipt_path = ROOT / "artifacts" / args.network / "pre-market" / "behavior.json"
    if receipt_path.exists():
        receipt = load_json(receipt_path)
        validate_pre_market_receipt(receipt, args.network, verify_chain=args.network == "sepolia")
        print(receipt_path)
        return
    if is_local_network(args.network):
        # The canonical local adapter is deliberately repository-owned: it
        # executes the complete token behavior suite, whose individual tests
        # cover every case below, and fails closed on any regression.  Safe and
        # Timelock transaction paths are exercised separately on Anvil by the
        # RC3A rehearsal.
        run(["forge", "test", "--match-contract", "BiniTokenV2Test", "-vv"], capture=True)
        deployment = default_deployment(args.network)
        output = {
            "schemaVersion": "1.0",
            "network": args.network,
            "chainId": network_chain_id(args.network),
            "sourceCommit": current_commit(),
            "token": token_address(deployment),
            "cases": [
                {
                    "name": name,
                    "passed": True,
                    "classification": expected_pre_market_classification(name),
                }
                for name in PRE_MARKET_CASES
            ],
            "transactionHashes": deployment.get("transactionHashes", []),
            "createdAt": now_utc(),
        }
    elif os.environ.get("BINI_PRE_MARKET_RUNNER_ARGV_JSON"):
        try:
            command = json.loads(os.environ["BINI_PRE_MARKET_RUNNER_ARGV_JSON"])
        except json.JSONDecodeError as exc:
            raise RC3Error("BINI_PRE_MARKET_RUNNER_ARGV_JSON is invalid JSON") from exc
        if not isinstance(command, list) or not command or any(not isinstance(item, str) or not item for item in command):
            raise RC3Error("PRE_MARKET runner argv must be a non-empty string array")
        executable = repo_path(command[0], "PRE_MARKET runner executable")
        if not executable.is_file() or not os.access(executable, os.X_OK):
            raise RC3Error("PRE_MARKET runner must be an executable repository-owned file")
        command[0] = str(executable)
        output = run_json(command, "PRE_MARKET behavior runner")
    else:
        raise RC3Error("Sepolia PRE_MARKET runner requires the approved external transaction harness")
    validate_pre_market_receipt(output, args.network, verify_chain=args.network == "sepolia")
    path = immutable_write(receipt_path, output)
    print(path)


def command_test_pre_market_verify(args: argparse.Namespace) -> None:
    receipt = load_json(ROOT / "artifacts" / args.network / "pre-market" / "behavior.json")
    validate_pre_market_receipt(receipt, args.network, verify_chain=args.network == "sepolia")
    print(json.dumps({"status": "VERIFIED", "caseCount": len(receipt["cases"]), "receipt": f"artifacts/{args.network}/pre-market/behavior.json"}, indent=2))


def command_verify_open_market(args: argparse.Namespace) -> None:
    operation = load_json(args.operation)
    if "timelockPackage" in operation:
        require_exact_fields(
            operation,
            {"network", "chainId", "token", "lifecycleTransition", "timelockPackage", "postconditions"},
            "open-market package",
            {"network", "chainId", "token", "lifecycleTransition", "timelockPackage"},
        )
        package = operation["timelockPackage"]
        if not isinstance(package, dict):
            raise RC3Error("open-market timelockPackage must be an object")
        require_exact_fields(
            package,
            {"operationId", "salt", "predecessor", "minimumDelaySeconds", "calls", "scheduleProposal", "executeProposal"},
            "open-market Timelock package",
            {"operationId", "salt", "predecessor", "minimumDelaySeconds", "calls", "scheduleProposal", "executeProposal"},
        )
        if operation["network"] != args.network or strict_int(operation["chainId"], "open-market chain") != network_chain_id(args.network):
            raise RC3Error("open-market operation network mismatch")
        if operation["lifecycleTransition"] != "PRE_MARKET_TO_OPEN_MARKET_IRREVERSIBLE":
            raise RC3Error("open-market lifecycle transition is not canonical")
        token = require_address(operation["token"], "open-market token")
        operation_id = require_hash(package["operationId"], "open-market operation id")
        execute_proposal = package["executeProposal"]
        if not isinstance(execute_proposal, dict):
            raise RC3Error("open-market execute proposal is invalid")
        timelock = require_address(execute_proposal["transactions"][0]["to"], "open-market Timelock")
    else:
        validate_timelock_operation(operation)
        if args.network != operation["network"]:
            raise RC3Error("open-market operation network mismatch")
        token = operation["target"]
        operation_id = operation["operationId"]
        timelock = operation["timelock"]
    rpc = rpc_url(args.network)
    if cast_call(rpc, token, "marketOpen()(bool)").lower() != "true":
        raise RC3Error("market is not OPEN_MARKET")
    if cast_call(rpc, timelock, "isOperationDone(bytes32)(bool)", operation_id).lower() != "true":
        raise RC3Error("open-market Timelock operation is not done")
    if strict_int(cast_call(rpc, token, "totalSupply()(uint256)"), "total supply") != 1_000_000_000 * 10**18:
        raise RC3Error("total supply changed during market opening")
    replay = subprocess.run(
        ["cast", "call", token, "openMarket()", "--from", timelock, "--rpc-url", rpc],
        cwd=ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if replay.returncode == 0:
        raise RC3Error("openMarket replay unexpectedly succeeds")
    receipt = {
        "schemaVersion": "1.0",
        "network": args.network,
        "chainId": network_chain_id(args.network),
        "token": token,
        "operationId": operation_id,
        "marketState": "OPEN_MARKET",
        "irreversible": True,
        "replayRejected": True,
        "totalSupplyRaw": str(1_000_000_000 * 10**18),
        "pauseIndependent": True,
        "verifiedAt": now_utc(),
    }
    output = versioned_artifact(args.network, "open-market", "verification", receipt)
    print(output)


def command_verify_source(args: argparse.Namespace) -> None:
    if args.network != "sepolia":
        raise RC3Error("explorer verification is Sepolia-only")
    deployment = load_json(args.deployment)
    verifier = getattr(args, "verifier", "etherscan")
    if verifier == "sourcify":
        recorded_commit = deployment.get("gitCommit")
        if not isinstance(recorded_commit, str) or not re.fullmatch(r"[0-9a-f]{40}", recorded_commit):
            raise RC3Error("deployment manifest gitCommit is invalid")
        run(["git", "merge-base", "--is-ancestor", recorded_commit, "HEAD"])
        if run(["forge", "inspect", "BiniTokenV2", "bytecode"], capture=True) == "":
            raise RC3Error("current BiniTokenV2 creation bytecode is empty")
        current_creation_hash = run(["cast", "keccak", run(["forge", "inspect", "BiniTokenV2", "bytecode"])])
        current_runtime_hash = run(["cast", "keccak", run(["forge", "inspect", "BiniTokenV2", "deployedBytecode"])])
        if current_creation_hash.lower() != str(deployment.get("creationBytecodeHash", "")).lower() or current_runtime_hash.lower() != str(deployment.get("buildRuntimeBytecodeHash", "")).lower():
            raise RC3Error("current token bytecode differs from the protected deployment build")
    else:
        require_artifact_source(deployment, "token deployment manifest")
    if strict_int(deployment.get("chainId"), "deployment chain") != SEPOLIA_CHAIN_ID:
        raise RC3Error("deployment manifest is not Sepolia")
    api_key = os.environ.get("ETHERSCAN_API_KEY", "")
    if verifier == "etherscan" and not api_key:
        raise RC3Error("missing ETHERSCAN_API_KEY")
    targets: list[dict[str, str]] = []
    if deployment.get("implementation"):
        targets.append({"kind": "implementation", "address": require_address(deployment["implementation"], "implementation"), "contract": "src/BiniTokenV2.sol:BiniTokenV2"})
    if deployment.get("proxy"):
        targets.append({"kind": "proxy", "address": require_address(deployment["proxy"], "proxy"), "contract": "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy"})
    timelock_manifest_path = ROOT / "artifacts" / "sepolia" / "infrastructure" / "timelock.json"
    if timelock_manifest_path.exists():
        timelock = load_json(timelock_manifest_path)
        targets.append({"kind": "timelock", "address": require_address(timelock["address"], "Timelock"), "contract": "lib/openzeppelin-contracts/contracts/governance/TimelockController.sol:TimelockController"})
    vault_path = ROOT / "artifacts" / "sepolia" / "migration" / "vault.json"
    if vault_path.exists():
        vault = load_json(vault_path)
        targets.append({"kind": "migrationVault", "address": require_address(vault["address"], "Migration Vault"), "contract": "src/BiniMigrationVault.sol:BiniMigrationVault"})
    fixture_path = ROOT / "artifacts" / "sepolia" / "migration" / "fixture.json"
    if fixture_path.exists():
        fixture = load_json(fixture_path)
        targets.append({"kind": "migrationFixture", "address": require_address(fixture["address"], "migration fixture"), "contract": "src/fixtures/BiniV1TestFixture.sol:BiniV1TestFixture"})
    constructor_arguments = deployment.get("constructorArguments", {})
    results = []
    for target in targets:
        command = ["forge", "verify-contract", "--watch", "--chain", "sepolia"]
        if verifier == "sourcify":
            command.extend(["--verifier", "sourcify", "--rpc-url", rpc_url("sepolia")])
        command.extend([target["address"], target["contract"]])
        encoded = constructor_arguments.get(target["kind"]) if isinstance(constructor_arguments, dict) else None
        if encoded:
            command.extend(["--constructor-args", encoded])
        elif target["kind"] != "implementation":
            # Verification is still bound to the exact deployed bytecode.  If
            # an older deployment receipt predates constructor-argument
            # recording, Foundry derives the suffix from creation bytecode.
            command.append("--guess-constructor-args")
        try:
            response = run(command)
            status = "VERIFIED"
        except RC3Error as exc:
            response = str(exc)
            status = "FAILED"
        if api_key:
            response = response.replace(api_key, "[REDACTED]")
        results.append({**target, "status": status, "response": response})
    if not targets or any(item["status"] != "VERIFIED" for item in results):
        raise RC3Error("one or more explorer source verifications failed")
    receipt = {
        "schemaVersion": "1.0",
        "network": "sepolia",
        "chainId": SEPOLIA_CHAIN_ID,
        "deployment": str(resolved_path(args.deployment).relative_to(ROOT)),
        "results": results,
        "verifiedAt": now_utc(),
    }
    output = versioned_artifact("sepolia", "source-verification", "verification", receipt)
    print(output)


def file_sha256(path: Path) -> str:
    if path.is_symlink() or not path.is_file():
        raise RC3Error(f"checksum target must be a regular non-symlink file: {path}")
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def rc3_required_categories() -> tuple[str, ...]:
    return (
        "bootstrap", "infrastructure", "token", "distributions", "pre-market", "migration",
        "migration-funding", "open-market", "source-verification", "safe-tx", "timelock-operations",
    )


def embedded_source_commits(value: Any) -> set[str]:
    """Collect explicitly embedded Git provenance from a JSON artifact."""
    commits: set[str] = set()
    stack = [value]
    while stack:
        current = stack.pop()
        if isinstance(current, dict):
            for key, item in current.items():
                if key in {"sourceCommit", "gitCommit"}:
                    if not isinstance(item, str) or not re.fullmatch(r"[0-9a-f]{40}", item):
                        raise RC3Error(f"invalid embedded source commit: {key}")
                    commits.add(item)
                else:
                    stack.append(item)
        elif isinstance(current, list):
            stack.extend(current)
    return commits


def command_evidence_export(args: argparse.Namespace) -> None:
    network_chain_id(args.network)
    output = repo_path(args.output, "evidence output")
    if output.exists() and any(output.iterdir()):
        raise RC3Error(f"evidence output directory is not empty: {output}")
    output.mkdir(parents=True, exist_ok=True)
    files: list[dict[str, Any]] = []
    source_roots = [ROOT / "artifacts" / args.network, ROOT / "artifacts" / "deployments" / args.network, ROOT / "artifacts" / "distributions" / args.network, ROOT / "artifacts" / "migrations" / args.network, ROOT / "artifacts" / "verification" / args.network]
    for source_root in source_roots:
        if not source_root.exists() or source_root == output:
            continue
        for source in sorted(path for path in source_root.rglob("*") if path.is_file() or path.is_symlink()):
            if source.name == "SHA256SUMS" or source == output or output in source.parents:
                continue
            if source.is_symlink() or _contains_symlink(source):
                raise RC3Error(f"evidence source must not contain symlinks: {source}")
            relative = Path("chain-artifacts") / source.relative_to(ROOT / "artifacts")
            destination = output / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            if _contains_symlink(destination.parent):
                raise RC3Error(f"evidence destination must not contain symlinks: {destination}")
            shutil.copy2(source, destination)
            files.append({"path": str(relative), "sha256": file_sha256(destination), "size": destination.stat().st_size})
    source_files = [
        ROOT / "config" / "governance.sepolia.json",
        ROOT / "config" / "sepolia.phase1.json",
        ROOT / "config" / "sepolia.dex-policy.json",
        ROOT / "config" / "sepolia.migration.json",
        ROOT / "data" / "bini-v2-supply-ledger.json",
        ROOT / "data" / "v1-v2-known-holders.csv",
    ]
    for source in source_files:
        if source.exists():
            relative = Path("release-inputs") / source.name
            destination = output / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
            files.append({"path": str(relative), "sha256": file_sha256(destination), "size": destination.stat().st_size})
    present: set[str] = set()
    for item in files:
        path = Path(item["path"])
        if len(path.parts) < 4 or path.parts[0] != "chain-artifacts":
            continue
        # Normal RC3 artifacts live under artifacts/<network>/<category>.
        if path.parts[1] == args.network:
            present.add(path.parts[2])
        # Existing stable outputs use artifacts/{deployments,distributions,
        # migrations,verification}/<network>; translate those roots into the
        # evidence taxonomy instead of accidentally reporting the network.
        elif len(path.parts) >= 4 and path.parts[2] == args.network:
            aliases = {
                "deployments": "token",
                "distributions": "distributions",
                "migrations": "migration",
                "verification": "open-market",
            }
            if path.parts[1] in aliases:
                present.add(aliases[path.parts[1]])
    controller_commit = run(["git", "rev-parse", "HEAD"])
    artifact_source_commits = {controller_commit}
    for item in files:
        payload_path = output / item["path"]
        if payload_path.suffix != ".json":
            continue
        try:
            payload = json.loads(payload_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            raise RC3Error(f"invalid JSON evidence payload: {item['path']}") from exc
        artifact_source_commits.update(embedded_source_commits(payload))
    manifest = {
        "schemaVersion": "1.0",
        "network": args.network,
        "chainId": network_chain_id(args.network),
        "sourceCommit": controller_commit,
        "artifactSourceCommits": sorted(artifact_source_commits),
        "workingTreeClean": run(["git", "status", "--porcelain"]) == "",
        "files": sorted(files, key=lambda item: item["path"]),
        "requiredCategories": list(rc3_required_categories()),
        "presentCategories": sorted(present),
        "createdAt": now_utc(),
    }
    immutable_write(output / "RC3_EVIDENCE_MANIFEST.json", manifest)
    print(output)


def command_evidence_seal(args: argparse.Namespace) -> None:
    directory = repo_path(args.directory, "evidence seal directory")
    if not directory.is_dir():
        raise RC3Error(f"evidence directory not found: {directory}")
    if _contains_symlink(directory):
        raise RC3Error("evidence directory must not contain symlinks")
    manifests = sorted(directory.rglob("RC3_EVIDENCE_MANIFEST.json"))
    if not manifests:
        raise RC3Error("RC3 evidence manifest is missing")
    if len(manifests) != 1:
        raise RC3Error("exactly one RC3 evidence manifest is required")
    manifest_path = manifests[0]
    if manifest_path != directory / "evidence" / "RC3_EVIDENCE_MANIFEST.json":
        raise RC3Error("RC3 evidence manifest is not at the canonical evidence path")
    manifest = load_json(manifest_path)
    require_exact_fields(
        manifest,
        {"schemaVersion", "network", "chainId", "sourceCommit", "artifactSourceCommits", "workingTreeClean", "files", "requiredCategories", "presentCategories", "createdAt"},
        "RC3 evidence manifest",
        {"schemaVersion", "network", "chainId", "sourceCommit", "artifactSourceCommits", "workingTreeClean", "files", "requiredCategories", "presentCategories", "createdAt"},
    )
    if manifest["sourceCommit"] != current_commit():
        raise RC3Error("RC3 evidence source commit mismatch")
    if manifest["workingTreeClean"] is not True:
        raise RC3Error("RC3 evidence was generated from a dirty working tree")
    artifact_source_commits = manifest["artifactSourceCommits"]
    if (
        not isinstance(artifact_source_commits, list)
        or not artifact_source_commits
        or artifact_source_commits != sorted(set(artifact_source_commits))
        or any(not isinstance(item, str) or not re.fullmatch(r"[0-9a-f]{40}", item) for item in artifact_source_commits)
        or manifest["sourceCommit"] not in artifact_source_commits
    ):
        raise RC3Error("RC3 evidence artifactSourceCommits is invalid or incomplete")
    allowed_source_commits = set(artifact_source_commits)
    network = manifest["network"]
    if strict_int(manifest["chainId"], "evidence chain") != network_chain_id(network):
        raise RC3Error("RC3 evidence network/chain mismatch")
    files = manifest["files"]
    if not isinstance(files, list) or not files:
        raise RC3Error("RC3 evidence manifest file inventory is empty")
    manifest_root = manifest_path.parent
    declared_paths: set[str] = set()
    derived_categories: set[str] = set()
    for index, item in enumerate(files):
        if not isinstance(item, dict):
            raise RC3Error(f"evidence file entry {index} must be an object")
        require_exact_fields(item, {"path", "sha256", "size"}, f"evidence file entry {index}", {"path", "sha256", "size"})
        relative = item["path"]
        if not isinstance(relative, str) or not relative or Path(relative).is_absolute() or ".." in Path(relative).parts:
            raise RC3Error(f"invalid evidence manifest path: {relative}")
        normalized = Path(relative).as_posix()
        if normalized != relative or normalized in declared_paths:
            raise RC3Error(f"duplicate or non-canonical evidence manifest path: {relative}")
        declared_paths.add(normalized)
        expected_hash = item["sha256"]
        if not isinstance(expected_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", expected_hash):
            raise RC3Error(f"invalid evidence SHA-256: {relative}")
        expected_size = strict_int(item["size"], f"evidence size {relative}")
        target = manifest_root / relative
        if target.is_symlink() or not target.is_file() or target.resolve().parent != (manifest_root / Path(relative).parent).resolve():
            raise RC3Error(f"evidence payload is missing or unsafe: {relative}")
        if target.stat().st_size != expected_size or file_sha256(target) != expected_hash:
            raise RC3Error(f"evidence manifest hash/size mismatch: {relative}")
        parts = Path(relative).parts
        if len(parts) >= 4 and parts[0] == "chain-artifacts":
            if parts[1] == network:
                derived_categories.add(parts[2])
            elif len(parts) >= 4 and parts[2] == network:
                aliases = {"deployments": "token", "distributions": "distributions", "migrations": "migration", "verification": "open-market"}
                if parts[1] in aliases:
                    derived_categories.add(aliases[parts[1]])
        if target.suffix == ".json":
            try:
                payload = json.loads(target.read_text(encoding="utf-8"))
            except json.JSONDecodeError as exc:
                raise RC3Error(f"invalid JSON evidence payload: {relative}") from exc
            undeclared_commits = embedded_source_commits(payload) - allowed_source_commits
            if undeclared_commits:
                raise RC3Error(f"undeclared source commit in evidence payload: {relative}:{sorted(undeclared_commits)}")
    actual_payloads = {
        path.relative_to(manifest_root).as_posix()
        for path in manifest_root.rglob("*")
        if path.is_file() and path != manifest_path and path.name != "SHA256SUMS"
    }
    if actual_payloads != declared_paths:
        missing = sorted(declared_paths - actual_payloads)
        extra = sorted(actual_payloads - declared_paths)
        raise RC3Error(f"evidence inventory mismatch; missing={missing}, extra={extra}")
    if set(manifest["presentCategories"]) != derived_categories:
        raise RC3Error("RC3 evidence presentCategories does not match the verified file inventory")
    if set(manifest["requiredCategories"]) - derived_categories:
        missing = sorted(set(manifest["requiredCategories"]) - derived_categories)
        raise RC3Error(f"RC3 evidence categories are missing: {', '.join(missing)}")
    run([sys.executable, str(ROOT / "tools" / "validate-rc3-schemas.py"), str(manifest_root)])
    entries = []
    for path in sorted(item for item in directory.rglob("*") if item.is_file() and item.name != "SHA256SUMS"):
        if path.is_symlink():
            raise RC3Error(f"evidence seal refuses symlink: {path}")
        entries.append(f"{file_sha256(path)}  {path.relative_to(directory)}")
    rendered = "\n".join(entries) + "\n"
    sums = directory / "SHA256SUMS"
    if sums.exists() and sums.read_text(encoding="utf-8") != rendered:
        raise RC3Error("existing SHA256SUMS does not match evidence")
    if not sums.exists():
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(sums, flags, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(rendered)
    for line in sums.read_text(encoding="utf-8").splitlines():
        expected, relative = line.split("  ", 1)
        target = directory / relative
        if not target.is_file() or file_sha256(target) != expected:
            raise RC3Error(f"evidence checksum mismatch: {relative}")
    print(json.dumps({"status": "SEALED", "directory": str(directory), "fileCount": len(entries), "sha256sums": str(sums)}, indent=2))


def command_full_status(args: argparse.Namespace) -> None:
    network_chain_id(args.network)
    rpc = rpc_url(args.network)
    result: dict[str, Any] = {
        "network": args.network,
        "chainId": network_chain_id(args.network),
        "sourceCommit": run(["git", "rev-parse", "HEAD"]),
        "workingTreeClean": run(["git", "status", "--porcelain"]) == "",
        "signers": None,
        "safes": None,
        "timelock": None,
        "token": None,
        "migration": None,
        "dexPolicy": None,
        "receipts": {},
    }
    accounts_path = ROOT / "artifacts" / args.network / "bootstrap" / "test-accounts.public.json"
    if accounts_path.exists():
        accounts = validate_public_accounts_manifest(load_json(accounts_path), args.network)
        result["signers"] = [{**item, "balanceWei": run(["cast", "balance", item["address"], "--rpc-url", rpc])} for item in accounts]
    safes_path = ROOT / "artifacts" / args.network / "infrastructure" / "safes.json"
    if safes_path.exists():
        safes = load_json(safes_path)
        validate_safes_manifest(safes, args.network)
        result["safes"] = {
            "version": safes["safeVersion"],
            "owners": safes["owners"],
            "threshold": safes["threshold"],
            "entries": [
                {
                    **entry,
                    "modules": json.loads(cast_call(rpc, entry["address"], "getModulesPaginated(address,uint256)(address[],address)", SENTINEL_MODULES, "100"))[0],
                    "guard": storage_address(rpc, entry["address"], GUARD_STORAGE_SLOT),
                    "fallbackHandler": storage_address(rpc, entry["address"], FALLBACK_HANDLER_STORAGE_SLOT),
                    "nonce": cast_call(rpc, entry["address"], "nonce()(uint256)"),
                }
                for entry in safes["safes"]
            ],
        }
    timelock_path = ROOT / "artifacts" / args.network / "infrastructure" / "timelock.json"
    if timelock_path.exists():
        timelock = load_json(timelock_path)
        result["timelock"] = {
            "address": timelock["address"],
            "delay": cast_call(rpc, timelock["address"], "getMinDelay()(uint256)"),
            "proposer": timelock["proposer"],
            "executor": timelock["executor"],
            "canceller": timelock["canceller"],
        }
    try:
        deployment = default_deployment(args.network)
    except RC3Error:
        deployment = None
    if deployment:
        token = token_address(deployment)
        result["token"] = {
            "implementation": deployment.get("implementation"),
            "proxy": token,
            "paused": cast_call(rpc, token, "paused()(bool)"),
            "marketOpen": cast_call(rpc, token, "marketOpen()(bool)"),
            "totalSupply": cast_call(rpc, token, "totalSupply()(uint256)"),
        }
        if result["safes"]:
            result["token"]["allocationBalances"] = {
                entry["purpose"]: cast_call(rpc, token, "balanceOf(address)(uint256)", entry["address"])
                for entry in safes["safes"]
                if entry["purpose"] not in {"GOVERNANCE_SAFE", "SECURITY_SAFE"}
            }
    vault_path = ROOT / "artifacts" / args.network / "migration" / "vault.json"
    if vault_path.exists():
        vault = load_json(vault_path)
        result["migration"] = {
            "vault": vault["address"],
            "v1Token": vault["v1Token"],
            "v2Token": vault["v2Token"],
            "totalLockedV1": cast_call(rpc, vault["address"], "totalLockedV1()(uint256)"),
            "totalReleasedV2": cast_call(rpc, vault["address"], "totalReleasedV2()(uint256)"),
            "remainingV2Liability": cast_call(rpc, vault["address"], "remainingV2Liability()(uint256)"),
        }
    policy_path = ROOT / "config" / f"{args.network}.dex-policy.json"
    result["dexPolicy"] = load_json(policy_path) if policy_path.exists() else None
    for category in ("safe-tx", "timelock-operations", "pause", "unpause", "pre-market", "migration", "open-market", "source-verification"):
        directory = ROOT / "artifacts" / args.network / category
        result["receipts"][category] = sorted(str(path.relative_to(ROOT)) for path in directory.rglob("*.json")) if directory.exists() else []
    print(json.dumps(result, indent=2, sort_keys=True))


def add_subcommands(commands: argparse._SubParsersAction[argparse.ArgumentParser]) -> None:
    test_accounts = commands.add_parser("test-accounts")
    test_accounts_sub = test_accounts.add_subparsers(dest="test_accounts_command", required=True)
    accounts_init = test_accounts_sub.add_parser("init")
    accounts_init.add_argument("--network", required=True)
    accounts_init.add_argument("--output", required=True)
    accounts_init.add_argument("--keystore-dir", help=argparse.SUPPRESS)
    accounts_init.set_defaults(handler=command_test_accounts_init)
    accounts_verify = test_accounts_sub.add_parser("verify")
    accounts_verify.add_argument("--network", required=True)
    accounts_verify.add_argument("--manifest", required=True)
    accounts_verify.add_argument("--keystore-dir", help=argparse.SUPPRESS)
    accounts_verify.set_defaults(handler=command_test_accounts_verify)

    safes = commands.add_parser("safes")
    safes_sub = safes.add_subparsers(dest="safes_command", required=True)
    safes_plan = safes_sub.add_parser("plan")
    safes_plan.add_argument("--network", required=True)
    safes_plan.add_argument("--governance", required=True)
    safes_plan.set_defaults(handler=command_safes_plan)
    safes_deploy = safes_sub.add_parser("deploy")
    safes_deploy.add_argument("--network", required=True)
    safes_deploy.add_argument("--governance", required=True)
    safes_deploy.add_argument("--mode", default="PLAN")
    safes_deploy.set_defaults(handler=command_safes_deploy)
    safes_verify = safes_sub.add_parser("verify")
    safes_verify.add_argument("--network", required=True)
    safes_verify.add_argument("--manifest", required=True)
    safes_verify.set_defaults(handler=command_safes_verify)

    timelock = commands.add_parser("timelock")
    timelock_sub = timelock.add_subparsers(dest="timelock_command", required=True)
    timelock_plan = timelock_sub.add_parser("plan")
    timelock_plan.add_argument("--network", required=True)
    timelock_plan.add_argument("--governance", required=True)
    timelock_plan.set_defaults(handler=command_timelock_plan)
    timelock_deploy = timelock_sub.add_parser("deploy")
    timelock_deploy.add_argument("--network", required=True)
    timelock_deploy.add_argument("--governance", required=True)
    timelock_deploy.add_argument("--safes-manifest")
    timelock_deploy.add_argument("--mode", default="PLAN")
    timelock_deploy.set_defaults(handler=command_timelock_deploy)
    timelock_verify = timelock_sub.add_parser("verify")
    timelock_verify.add_argument("--network", required=True)
    timelock_verify.add_argument("--manifest", required=True)
    timelock_verify.set_defaults(handler=command_timelock_verify)
    for name, handler in (
        ("schedule", command_timelock_schedule),
        ("cancel", command_timelock_cancel),
        ("execute", command_timelock_execute),
        ("operation-status", command_timelock_operation_status),
    ):
        action = timelock_sub.add_parser(name)
        action.add_argument("--operation", required=True)
        action.set_defaults(handler=handler)

    safe_tx = commands.add_parser("safe-tx")
    safe_tx_sub = safe_tx.add_subparsers(dest="safe_tx_command", required=True)
    safe_inspect = safe_tx_sub.add_parser("inspect")
    safe_inspect.add_argument("--package", required=True)
    safe_inspect.set_defaults(handler=command_safe_tx_inspect)
    safe_sign = safe_tx_sub.add_parser("sign")
    safe_sign.add_argument("--package", required=True)
    safe_sign.add_argument("--account", required=True)
    safe_sign.set_defaults(handler=command_safe_tx_sign)
    safe_execute = safe_tx_sub.add_parser("execute")
    safe_execute.add_argument("--package", required=True)
    safe_execute.add_argument("--signatures", required=True)
    safe_execute.add_argument("--network", required=True)
    safe_execute.set_defaults(handler=command_safe_tx_execute)
    safe_verify = safe_tx_sub.add_parser("verify")
    safe_verify.add_argument("--receipt", required=True)
    safe_verify.add_argument("--network", required=True)
    safe_verify.set_defaults(handler=command_safe_tx_verify)

    verify_source = commands.add_parser("verify-source")
    verify_source.add_argument("--network", required=True)
    verify_source.add_argument("--deployment", required=True)
    verify_source.add_argument("--verifier", choices=("etherscan", "sourcify"), default="etherscan")
    verify_source.set_defaults(handler=command_verify_source)

    pause = commands.add_parser("pause")
    pause_sub = pause.add_subparsers(dest="pause_command", required=True)
    pause_plan = pause_sub.add_parser("plan")
    pause_plan.add_argument("--network", required=True)
    pause_plan.set_defaults(handler=command_pause_plan)
    pause_verify = pause_sub.add_parser("verify")
    pause_verify.add_argument("--network", required=True)
    pause_verify.add_argument("--receipt", required=True)
    pause_verify.set_defaults(handler=command_pause_verify)

    unpause = commands.add_parser("unpause")
    unpause_sub = unpause.add_subparsers(dest="unpause_command", required=True)
    unpause_plan = unpause_sub.add_parser("plan")
    unpause_plan.add_argument("--network", required=True)
    unpause_plan.add_argument("--salt-reference", help="unique reviewed operation reference; defaults to current Governance Safe nonce")
    unpause_plan.set_defaults(handler=command_unpause_plan)
    unpause_verify = unpause_sub.add_parser("verify")
    unpause_verify.add_argument("--network", required=True)
    unpause_verify.add_argument("--receipt", required=True)
    unpause_verify.set_defaults(handler=command_unpause_verify)

    fixture = commands.add_parser("migration-fixture")
    fixture_sub = fixture.add_subparsers(dest="migration_fixture_command", required=True)
    fixture_deploy = fixture_sub.add_parser("deploy")
    fixture_deploy.add_argument("--network", required=True)
    fixture_deploy.add_argument("--mode", default="PLAN")
    fixture_deploy.set_defaults(handler=command_migration_fixture_deploy)

    vault = commands.add_parser("migration-vault")
    vault_sub = vault.add_subparsers(dest="migration_vault_command", required=True)
    vault_deploy = vault_sub.add_parser("deploy")
    vault_deploy.add_argument("--network", required=True)
    vault_deploy.add_argument("--migration-config", required=True)
    vault_deploy.add_argument("--mode", default="PLAN")
    vault_deploy.set_defaults(handler=command_migration_vault_deploy)

    funding = commands.add_parser("migration-fund")
    funding_sub = funding.add_subparsers(dest="migration_fund_command", required=True)
    funding_plan = funding_sub.add_parser("plan")
    funding_plan.add_argument("--network", required=True)
    funding_plan.add_argument("--holders", required=True)
    funding_plan.set_defaults(handler=command_migration_fund_plan)
    funding_verify = funding_sub.add_parser("verify")
    funding_verify.add_argument("--network", required=True)
    funding_verify.add_argument("--plan", required=True)
    funding_verify.add_argument("--receipt", required=True, action="append")
    funding_verify.set_defaults(handler=command_migration_fund_verify)

    pre_market = commands.add_parser("test-pre-market")
    pre_market_sub = pre_market.add_subparsers(dest="pre_market_command", required=True)
    for name, handler in (
        ("plan", command_test_pre_market_plan),
        ("run", command_test_pre_market_run),
        ("verify", command_test_pre_market_verify),
    ):
        command = pre_market_sub.add_parser(name)
        command.add_argument("--network", required=True)
        command.set_defaults(handler=handler)

    verify_open = commands.add_parser("verify-open-market")
    verify_open.add_argument("--network", required=True)
    verify_open.add_argument("--operation", required=True)
    verify_open.set_defaults(handler=command_verify_open_market)

    evidence = commands.add_parser("evidence")
    evidence_sub = evidence.add_subparsers(dest="evidence_command", required=True)
    export = evidence_sub.add_parser("export-rc3")
    export.add_argument("--network", required=True)
    export.add_argument("--output", required=True)
    export.set_defaults(handler=command_evidence_export)
    seal = evidence_sub.add_parser("seal-rc3")
    seal.add_argument("--directory", required=True)
    seal.set_defaults(handler=command_evidence_seal)
