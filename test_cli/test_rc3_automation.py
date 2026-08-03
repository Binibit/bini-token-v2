import importlib.util
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
                {"accountName": name, "address": ADDR[index]}
                for index, name in enumerate(rc3.TEST_ACCOUNT_NAMES)
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
        with mock.patch.object(rc3, "test_keystore_dir", return_value=self.root / "keys"), mock.patch.object(
            rc3, "find_account_file", return_value=self.root / "key"
        ), mock.patch.object(rc3, "read_public_keystore_address", return_value=ADDR[0]), mock.patch.object(
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
        evidence = self.root / "evidence"
        evidence.mkdir()
        payload = evidence / "payload.json"
        payload.write_text("{}\n", encoding="utf-8")
        manifest = {
            "schemaVersion": "1.0", "network": "sepolia", "chainId": rc3.SEPOLIA_CHAIN_ID,
            "sourceCommit": "a" * 40, "workingTreeClean": True, "files": [],
            "requiredCategories": ["bootstrap"], "presentCategories": [], "createdAt": "now",
        }
        self.write_json("unused.json", {})
        (evidence / "RC3_EVIDENCE_MANIFEST.json").write_text(json.dumps(manifest), encoding="utf-8")
        with mock.patch.object(rc3, "run", return_value="a" * 40), self.assertRaises(rc3.RC3Error):
            rc3.command_evidence_seal(Namespace(directory=str(evidence)))
        manifest["presentCategories"] = ["bootstrap"]
        (evidence / "RC3_EVIDENCE_MANIFEST.json").write_text(json.dumps(manifest), encoding="utf-8")
        with mock.patch.object(rc3, "run", return_value="b" * 40), self.assertRaises(rc3.RC3Error):
            rc3.command_evidence_seal(Namespace(directory=str(evidence)))
        with mock.patch.object(rc3, "run", return_value="a" * 40):
            rc3.command_evidence_seal(Namespace(directory=str(evidence)))
        payload.write_text("tampered\n", encoding="utf-8")
        with mock.patch.object(rc3, "run", return_value="a" * 40), self.assertRaises(rc3.RC3Error):
            rc3.command_evidence_seal(Namespace(directory=str(evidence)))


if __name__ == "__main__":
    unittest.main()
