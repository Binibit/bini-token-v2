import importlib.util
import hashlib
import json
import os
import sys
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "tools" / "rc3_automation.py"
SPEC = importlib.util.spec_from_file_location("rc3_automation_test_target", MODULE_PATH)
rc3 = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = rc3
SPEC.loader.exec_module(rc3)

ADDR = ["0x" + f"{index:040x}" for index in range(1, 30)]
HASH = "0x" + "1" * 64


class RC3AutomationTest(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)

    def tearDown(self):
        self.tempdir.cleanup()

    def write_json(self, name, value):
        path = self.root / name
        path.write_text(json.dumps(value), encoding="utf-8")
        return path

    def accounts_manifest(self):
        return {
            "schemaVersion": "1.0",
            "network": "sepolia",
            "chainId": rc3.SEPOLIA_CHAIN_ID,
            "sepoliaRehearsalOnly": True,
            "accounts": [
                {
                    "accountName": name,
                    "label": rc3.TEST_ACCOUNT_METADATA[name][0],
                    "role": rc3.TEST_ACCOUNT_METADATA[name][1],
                    "address": ADDR[index],
                }
                for index, name in enumerate(rc3.ALL_TEST_ACCOUNT_NAMES)
            ],
            "createdAt": "2026-08-03T00:00:00+00:00",
        }

    def safes_manifest(self):
        return {
            "schemaVersion": "1.0",
            "network": "sepolia",
            "chainId": rc3.SEPOLIA_CHAIN_ID,
            "sepoliaRehearsalOnly": True,
            "safeVersion": rc3.SAFE_VERSION,
            "singleton": ADDR[0],
            "proxyFactory": ADDR[1],
            "multiSend": ADDR[2],
            "singletonRuntimeCodeHash": HASH,
            "proxyFactoryRuntimeCodeHash": HASH,
            "multiSendRuntimeCodeHash": HASH,
            "safeProxyRuntimeCodeHash": HASH,
            "owners": ADDR[3:6],
            "threshold": 2,
            "safes": [
                {"purpose": purpose, "address": ADDR[index + 6], "creationTransaction": HASH}
                for index, purpose in enumerate(rc3.SAFE_PURPOSES)
            ],
            "deploymentBlockStart": 1,
            "deploymentBlockEnd": 12,
            "broadcastReceipt": "broadcast/example.json",
            "sourceCommit": "a" * 40,
            "createdAt": "2026-08-03T00:00:00+00:00",
        }

    def safe_package(self):
        return {
            "version": "1.0",
            "chainId": str(rc3.SEPOLIA_CHAIN_ID),
            "createdAt": "2026-08-03T00:00:00+00:00",
            "meta": {
                "name": "test",
                "description": "test",
                "txBuilderVersion": "1.18.0",
                "createdFromSafeAddress": ADDR[0],
            },
            "transactions": [
                {
                    "to": ADDR[1],
                    "value": "0",
                    "data": "0x12345678",
                    "contractMethod": None,
                    "contractInputsValues": None,
                    "operation": 0,
                }
            ],
        }

    def test_public_account_manifest_has_no_secret_surface(self):
        manifest = self.accounts_manifest()
        rc3.validate_public_accounts_manifest(manifest, "sepolia")
        rendered = json.dumps(manifest).lower()
        for forbidden in ("privatekey", "mnemonic", "seedphrase"):
            self.assertNotIn(forbidden, rendered)
        manifest["mnemonic"] = "forbidden"
        with self.assertRaises(rc3.RC3Error):
            rc3.validate_public_accounts_manifest(manifest, "sepolia")

    def test_duplicate_account_and_address_are_rejected(self):
        manifest = self.accounts_manifest()
        manifest["accounts"][1]["address"] = manifest["accounts"][0]["address"]
        with self.assertRaises(rc3.RC3Error):
            rc3.validate_public_accounts_manifest(manifest, "sepolia")
        manifest = self.accounts_manifest()
        manifest["accounts"][1]["accountName"] = manifest["accounts"][0]["accountName"]
        with self.assertRaises(rc3.RC3Error):
            rc3.validate_public_accounts_manifest(manifest, "sepolia")

    def test_wrong_network_is_rejected(self):
        with self.assertRaises(rc3.RC3Error):
            rc3.validate_public_accounts_manifest(self.accounts_manifest(), "mainnet")
        with mock.patch.dict(os.environ, {}, clear=True), self.assertRaises(rc3.RC3Error):
            rc3.network_chain_id("anvil-rc3a")

    def test_missing_signer_funding_is_detected(self):
        manifest = self.write_json("accounts.json", self.accounts_manifest())
        args = Namespace(network="sepolia", manifest=str(manifest), keystore_dir=str(self.root / "keys"))
        with mock.patch.dict(os.environ, {"BINI_REQUIRED_FUNDED_ACCOUNTS": rc3.SEPOLIA_DEPLOYER_ACCOUNT_NAME}), mock.patch.object(rc3, "test_keystore_dir", return_value=self.root / "keys"), mock.patch.object(
            rc3, "find_account_file", return_value=self.root / "key"
        ), mock.patch.object(rc3, "read_public_keystore_address", side_effect=ADDR[:4]), mock.patch.object(
            rc3, "rpc_url", return_value="rpc"
        ), mock.patch.object(rc3, "run", return_value="0"), self.assertRaises(rc3.RC3Error):
            rc3.command_test_accounts_verify(args)

    def test_safe_topology_requires_twelve_distinct_canonical_proxies(self):
        manifest = self.safes_manifest()
        rc3.validate_safes_manifest(manifest, "sepolia")
        manifest["safes"][1]["address"] = manifest["safes"][0]["address"]
        with self.assertRaises(rc3.RC3Error):
            rc3.validate_safes_manifest(manifest, "sepolia")

    def test_safe_topology_owner_threshold_and_singleton_fields_are_strict(self):
        manifest = self.safes_manifest()
        manifest["threshold"] = 1
        with self.assertRaises(rc3.RC3Error):
            rc3.validate_safes_manifest(manifest, "sepolia")
        manifest = self.safes_manifest()
        manifest["singleton"] = rc3.ZERO_ADDRESS
        with self.assertRaises(rc3.RC3Error):
            rc3.validate_safes_manifest(manifest, "sepolia")
        manifest = self.safes_manifest()
        manifest["unexpectedModule"] = ADDR[-1]
        with self.assertRaises(rc3.RC3Error):
            rc3.validate_safes_manifest(manifest, "sepolia")

    def test_safe_package_rejects_unknown_fields_and_delegatecall(self):
        package = self.safe_package()
        path = self.write_json("package.json", package)
        rc3.load_safe_package(path)
        package["transactions"][0]["operation"] = 1
        with self.assertRaises(rc3.RC3Error):
            rc3.load_safe_package(self.write_json("delegate.json", package))
        package = self.safe_package()
        package["transactions"][0]["hiddenCalldata"] = "0xdead"
        with self.assertRaises(rc3.RC3Error):
            rc3.load_safe_package(self.write_json("hidden.json", package))

    def test_multisend_requires_explicit_pinned_policy(self):
        package = self.safe_package()
        package["transactions"].append(dict(package["transactions"][0], to=ADDR[2]))
        with self.assertRaises(rc3.RC3Error):
            rc3.normalize_safe_transaction(package, 0)

    def test_multisend_runtime_pin_is_mandatory_on_every_path(self):
        package = self.safe_package()
        package["transactions"].append(dict(package["transactions"][0], to=ADDR[2]))
        package["rc3"] = {
            "schemaVersion": "1.0",
            "allowDelegateCall": True,
            "multiSend": ADDR[2],
            "multiSendRuntimeCodeHash": HASH,
        }
        manifest_path = self.root / "artifacts" / "sepolia" / "infrastructure" / "safes.json"
        manifest_path.parent.mkdir(parents=True)
        manifest_path.write_text(json.dumps(self.safes_manifest()), encoding="utf-8")
        with mock.patch.object(rc3, "ROOT", self.root), mock.patch.object(rc3, "code_hash", return_value="0x" + "2" * 64):
            with self.assertRaises(rc3.RC3Error):
                rc3.validate_multisend_target(package, "sepolia", "rpc")

    def signature_bundle(self):
        transaction = {
            "to": ADDR[1], "value": "0", "data": "0x", "operation": 0, "safeTxGas": "0",
            "baseGas": "0", "gasPrice": "0", "gasToken": rc3.ZERO_ADDRESS,
            "refundReceiver": rc3.ZERO_ADDRESS, "nonce": "0",
        }
        return {
            "schemaVersion": "1.0", "network": "sepolia", "chainId": rc3.SEPOLIA_CHAIN_ID,
            "safe": ADDR[0], "safeTxHash": HASH, "nonce": 0, "transaction": transaction,
            "signatures": [
                {"accountName": "one", "owner": ADDR[3], "signature": "0x" + "1" * 130, "createdAt": "now"},
                {"accountName": "two", "owner": ADDR[4], "signature": "0x" + "2" * 130, "createdAt": "now"},
            ],
            "createdAt": "now",
        }

    def test_signature_bundle_rejects_duplicate_and_unsorted_owners(self):
        bundle = self.signature_bundle()
        rc3.validate_signature_bundle(bundle, "sepolia")
        bundle["signatures"][1]["owner"] = bundle["signatures"][0]["owner"]
        with self.assertRaises(rc3.RC3Error):
            rc3.validate_signature_bundle(bundle, "sepolia")
        bundle = self.signature_bundle()
        bundle["signatures"].reverse()
        with self.assertRaises(rc3.RC3Error):
            rc3.validate_signature_bundle(bundle, "sepolia")

    def execution_receipt(self):
        bundle = self.signature_bundle()
        return {
            "schemaVersion": "1.0", "network": "sepolia", "chainId": rc3.SEPOLIA_CHAIN_ID,
            "safe": bundle["safe"], "safeTxHash": bundle["safeTxHash"], "nonce": 0,
            "transactionHash": "0x" + "2" * 64, "blockNumber": 10, "status": "EXECUTED",
            "signers": [ADDR[3], ADDR[4]], "transaction": bundle["transaction"],
            "rawReceipt": {"transactionHash": "0x" + "2" * 64, "to": bundle["safe"], "status": "0x1", "blockNumber": "0xa", "logs": []},
            "verifiedAt": "2026-08-03T00:00:00+00:00",
        }

    def test_safe_receipt_requires_matching_execution_success_event(self):
        receipt = self.execution_receipt()
        chain_receipt = {
            "transactionHash": receipt["transactionHash"], "to": receipt["safe"], "status": "0x1",
            "blockNumber": "0xa", "logs": [],
        }
        with mock.patch.object(rc3, "safe_tx_hash", return_value=HASH), mock.patch.object(
            rc3, "run_json", return_value=chain_receipt
        ), mock.patch.object(rc3, "run", return_value="0x" + "9" * 64):
            with self.assertRaises(rc3.RC3Error):
                rc3.validate_safe_execution_receipt(receipt, "sepolia", "rpc")

    def test_idempotency_does_not_trust_a_forged_filename(self):
        package = self.safe_package()
        bundle = self.signature_bundle()
        receipt_dir = self.root / "artifacts" / "sepolia" / "safe-tx" / "receipts"
        receipt_dir.mkdir(parents=True)
        path = receipt_dir / f"safe-execution-{HASH[2:]}.json"
        path.write_text("{}", encoding="utf-8")
        with mock.patch.object(rc3, "ROOT", self.root), mock.patch.object(rc3, "load_safe_package", return_value=package), mock.patch.object(
            rc3, "safe_package_network", return_value="sepolia"
        ), mock.patch.object(rc3, "ensure_write_network"), mock.patch.object(rc3, "load_json", return_value=bundle), mock.patch.object(
            rc3, "validate_signature_bundle"
        ), mock.patch.object(rc3, "rpc_url", return_value="rpc"), mock.patch.object(rc3, "validate_multisend_target"), mock.patch.object(
            rc3, "cast_call", return_value="1"
        ), mock.patch.object(rc3, "validate_safe_execution_receipt", side_effect=rc3.RC3Error("forged")):
            with self.assertRaises(rc3.RC3Error):
                rc3.command_safe_tx_execute(Namespace(package="package", signatures="bundle", network="sepolia"))
    def test_operation_rejects_modified_operation_id(self):
        operation = {
            "schemaVersion": "1.0", "network": "sepolia", "chainId": rc3.SEPOLIA_CHAIN_ID,
            "timelock": ADDR[0], "proposerSafe": ADDR[1], "cancellerSafe": ADDR[2],
            "executorSafe": ADDR[1], "target": ADDR[3], "value": "0", "data": "0x",
            "predecessor": rc3.ZERO_HASH, "salt": HASH, "delaySeconds": "600",
            "operationId": "0x" + "2" * 64, "description": "test", "createdAt": "now",
        }
        with mock.patch.object(rc3, "run", side_effect=["0x00", HASH]), self.assertRaises(rc3.RC3Error):
            rc3.validate_timelock_operation(operation)

    def test_evidence_seal_detects_missing_category_commit_and_tampering(self):
        seal_root = self.root / "rc3"
        evidence = seal_root / "evidence"
        payload = evidence / "chain-artifacts" / "sepolia" / "bootstrap" / "payload.json"
        payload.parent.mkdir(parents=True)
        payload.write_text("{}\n", encoding="utf-8")
        manifest = {
            "schemaVersion": "1.0", "network": "sepolia", "chainId": rc3.SEPOLIA_CHAIN_ID,
            "sourceCommit": "a" * 40, "workingTreeClean": True, "files": [],
            "requiredCategories": ["bootstrap"], "presentCategories": [], "createdAt": "2026-08-03T00:00:00+00:00",
        }
        (evidence / "RC3_EVIDENCE_MANIFEST.json").write_text(json.dumps(manifest), encoding="utf-8")
        with mock.patch.object(rc3, "ROOT", self.root), mock.patch.object(rc3, "run", return_value="a" * 40), self.assertRaises(rc3.RC3Error):
            rc3.command_evidence_seal(Namespace(directory=str(seal_root)))
        manifest["files"] = [{
            "path": "chain-artifacts/sepolia/bootstrap/payload.json",
            "sha256": hashlib.sha256(payload.read_bytes()).hexdigest(),
            "size": payload.stat().st_size,
        }]
        manifest["presentCategories"] = ["bootstrap"]
        (evidence / "RC3_EVIDENCE_MANIFEST.json").write_text(json.dumps(manifest), encoding="utf-8")
        with mock.patch.object(rc3, "ROOT", self.root), mock.patch.object(rc3, "run", return_value="b" * 40), self.assertRaises(rc3.RC3Error):
            rc3.command_evidence_seal(Namespace(directory=str(seal_root)))
        with mock.patch.object(rc3, "ROOT", self.root), mock.patch.object(rc3, "run", return_value="a" * 40):
            rc3.command_evidence_seal(Namespace(directory=str(seal_root)))
        payload.write_text("tampered\n", encoding="utf-8")
        with mock.patch.object(rc3, "ROOT", self.root), mock.patch.object(rc3, "run", return_value="a" * 40), self.assertRaises(rc3.RC3Error):
            rc3.command_evidence_seal(Namespace(directory=str(seal_root)))

    def test_keystore_symlink_into_repository_is_rejected(self):
        repository = self.root / "repo"
        repository.mkdir()
        inside = repository / "keys"
        inside.mkdir()
        alias = self.root / "external-keys"
        alias.symlink_to(inside, target_is_directory=True)
        with mock.patch.object(rc3, "ROOT", repository), self.assertRaises(rc3.RC3Error):
            rc3.test_keystore_dir(Namespace(keystore_dir=str(alias)))

    def test_evidence_export_refuses_external_file_symlink(self):
        repository = self.root / "repo"
        source = repository / "artifacts" / "sepolia" / "bootstrap"
        source.mkdir(parents=True)
        secret = self.root / "secret.txt"
        secret.write_text("sentinel", encoding="utf-8")
        (source / "linked-secret.txt").symlink_to(secret)
        with mock.patch.object(rc3, "ROOT", repository), self.assertRaises(rc3.RC3Error):
            rc3.command_evidence_export(Namespace(network="sepolia", output=str(repository / "evidence")))

    def test_explorer_key_is_not_passed_in_process_argv(self):
        repository = self.root / "repo"
        repository.mkdir()
        deployment = repository / "deployment.json"
        deployment.write_text(json.dumps({"chainId": rc3.SEPOLIA_CHAIN_ID, "implementation": ADDR[0], "gitCommit": "a" * 40}), encoding="utf-8")
        commands = []

        def capture(command, **_kwargs):
            commands.append(command)
            if command[:3] == ["git", "rev-parse", "HEAD"]:
                return "a" * 40
            return "verified"

        with mock.patch.object(rc3, "ROOT", repository), mock.patch.dict(os.environ, {"ETHERSCAN_API_KEY": "SENSITIVE_SENTINEL"}), mock.patch.object(rc3, "run", side_effect=capture):
            rc3.command_verify_source(Namespace(network="sepolia", deployment=str(deployment)))
        self.assertFalse(any("SENSITIVE_SENTINEL" in command for command in commands))


if __name__ == "__main__":
    unittest.main()
