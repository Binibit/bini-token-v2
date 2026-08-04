import copy
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "tools" / "holder_distribution.py"
sys.path.insert(0, str(MODULE_PATH.parent))
SPEC = importlib.util.spec_from_file_location("holder_distribution", MODULE_PATH)
hd = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = hd
SPEC.loader.exec_module(hd)

SOURCE = "0x2000000000000000000000000000000000000001"
TOKEN = "0x2000000000000000000000000000000000000002"
MULTISEND = "0x2000000000000000000000000000000000000003"


def manifest(count=50):
    records = []
    for offset in range(count):
        address = "0x" + f"{offset + 1000:040x}"
        records.append(
            {
                "holderId": f"holder-{offset + 1:03d}",
                "legacyV1Address": address,
                "destinationAddress": address,
                "v1RawAmount": str(offset + 1),
                "v2RawAmount": str((offset + 1) * 1_000_000),
                "sourceAllocationId": "rewards-year-1",
                "sourceSafe": SOURCE,
                "proofType": "SNAPSHOT_BALANCE",
                "addressOverride": False,
                "addressOverrideProofHash": hd.ZERO_HASH,
                "batch": str(offset // 20 + 1),
                "indexInBatch": str(offset % 20 + 1),
                "status": "PLANNED",
            }
        )
    value = {
        "manifestVersion": "test-v1",
        "network": "sepolia",
        "chainId": "11155111",
        "snapshotBlock": "123",
        "snapshotBlockHash": "0x" + "1" * 64,
        "sourceAllocationId": "rewards-year-1",
        "sourceSafe": SOURCE,
        "tokenProxy": TOKEN,
        "conversionRule": "v2RawAmount = v1RawAmount * 1000000 (12->18 decimals)",
        "recipientCount": str(count),
        "totalAmountRaw": str(sum((i + 1) * 1_000_000 for i in range(count))),
        "batchSizeLimit": "20",
        "manifestHash": "",
        "ownerApprovalReference": "OWNER-TEST-APPROVAL-1",
        "records": records,
    }
    value["manifestHash"] = hd.manifest_hash(value)
    return value


def refreeze(value):
    value["manifestHash"] = hd.manifest_hash(value)
    return value


class HolderDistributionTest(unittest.TestCase):
    def test_valid_50_records_and_20_20_10_batches(self):
        value = manifest()
        self.assertEqual(len(hd.validate_manifest(value)), 50)
        self.assertEqual([len(batch) for batch in hd.grouped_records(value)], [20, 20, 10])

    def test_duplicate_holder_legacy_and_destination_rejected(self):
        for field in ("holderId", "legacyV1Address", "destinationAddress"):
            value = manifest(2)
            value["records"][1][field] = value["records"][0][field]
            refreeze(value)
            with self.subTest(field=field), self.assertRaises(hd.DistributionError):
                hd.validate_manifest(value)

    def test_zero_and_forbidden_destination_rejected(self):
        value = manifest(1)
        value["records"][0]["destinationAddress"] = hd.ZERO_ADDRESS
        refreeze(value)
        with self.assertRaises(hd.DistributionError):
            hd.validate_manifest(value)
        value = manifest(1)
        value["records"][0]["destinationAddress"] = MULTISEND
        value["records"][0]["legacyV1Address"] = MULTISEND
        refreeze(value)
        with self.assertRaises(hd.DistributionError):
            hd.validate_manifest(value, forbidden={MULTISEND})

    def test_wrong_conversion_and_total_rejected(self):
        value = manifest(1)
        value["records"][0]["v2RawAmount"] = "999"
        value["totalAmountRaw"] = "999"
        refreeze(value)
        with self.assertRaises(hd.DistributionError):
            hd.validate_manifest(value)
        value = manifest(1)
        value["totalAmountRaw"] = "1"
        refreeze(value)
        with self.assertRaises(hd.DistributionError):
            hd.validate_manifest(value)

    def test_manifest_tampering_rejected(self):
        value = manifest(1)
        value["records"][0]["v1RawAmount"] = "2"
        with self.assertRaisesRegex(hd.DistributionError, "manifestHash"):
            hd.validate_manifest(value)

    def test_batch_order_and_move_tampering_rejected(self):
        value = manifest(21)
        value["records"][1]["indexInBatch"] = "3"
        refreeze(value)
        with self.assertRaises(hd.DistributionError):
            hd.validate_manifest(value)
        value = manifest(21)
        value["records"][19]["batch"] = "2"
        refreeze(value)
        with self.assertRaises(hd.DistributionError):
            hd.validate_manifest(value)

    def test_source_safe_insufficient_balance_rejected(self):
        value = manifest(1)
        with (
            mock.patch.object(hd.rc3, "default_deployment", return_value={"proxy": TOKEN}),
            mock.patch.object(hd.rc3, "default_safes", return_value={"safes": [{"purpose": "REWARDS_Y1_SAFE", "address": SOURCE}]}),
            mock.patch.object(hd.rc3, "token_address", return_value=TOKEN),
            mock.patch.object(hd.rc3, "safe_by_purpose", return_value=SOURCE),
            mock.patch.object(hd.rc3, "rpc_url", return_value="rpc"),
            mock.patch.object(hd.rc3, "run", return_value="11155111"),
            mock.patch.object(hd.rc3, "cast_call", return_value="0"),
        ):
            with self.assertRaisesRegex(hd.DistributionError, "insufficient"):
                hd._operational_preflight(value, "sepolia")

    def test_safe_nonce_drift_partial_and_already_executed_rejected(self):
        value = manifest(21)
        safes = {"multiSend": MULTISEND, "multiSendRuntimeCodeHash": "0x" + "2" * 64}
        packages = hd._packages(value, safes)
        receipts = []
        for nonce, package in ((5, packages[0]), (7, packages[1])):
            receipts.append({"safe": SOURCE, "nonce": nonce, "transactionHash": "0x" + f"{nonce:064x}", "transaction": hd.rc3.normalize_safe_transaction(package, nonce), "rawReceipt": {"logs": []}})
        with (
            mock.patch.object(hd.rc3, "validate_safe_execution_receipt"),
            mock.patch.object(hd, "_decode_transfer_logs", side_effect=[[(SOURCE, r["destinationAddress"], int(r["v2RawAmount"])) for r in batch] for batch in hd.grouped_records(value)]),
        ):
            with self.assertRaisesRegex(hd.DistributionError, "nonce drift"):
                hd.verify_receipts(value, receipts, "sepolia", "rpc", safes)
            with self.assertRaisesRegex(hd.DistributionError, "partial"):
                hd.verify_receipts(value, receipts[:1], "sepolia", "rpc", safes)
        receipts[1]["nonce"] = 6
        receipts[1]["transaction"] = hd.rc3.normalize_safe_transaction(packages[1], 6)
        receipts[1]["transactionHash"] = receipts[0]["transactionHash"]
        with mock.patch.object(hd.rc3, "validate_safe_execution_receipt"), mock.patch.object(hd, "_decode_transfer_logs", return_value=[]):
            with self.assertRaises(hd.DistributionError):
                hd.verify_receipts(value, receipts, "sepolia", "rpc", safes)

    def test_modified_calldata_delegatecall_and_event_mismatch_rejected(self):
        value = manifest(1)
        safes = {"multiSend": MULTISEND, "multiSendRuntimeCodeHash": "0x" + "2" * 64}
        package = hd._packages(value, safes)[0]
        receipt = {"safe": SOURCE, "nonce": 1, "transactionHash": "0x" + "3" * 64, "transaction": hd.rc3.normalize_safe_transaction(package, 1), "rawReceipt": {"logs": []}}
        receipt["transaction"]["data"] = hd.transfer_data(value["records"][0]["destinationAddress"], 2)
        with mock.patch.object(hd.rc3, "validate_safe_execution_receipt"):
            with self.assertRaisesRegex(hd.DistributionError, "calldata"):
                hd.verify_receipts(value, [receipt], "sepolia", "rpc", safes)
        receipt["transaction"] = hd.rc3.normalize_safe_transaction(package, 1)
        receipt["transaction"]["operation"] = 1
        with mock.patch.object(hd.rc3, "validate_safe_execution_receipt"):
            with self.assertRaisesRegex(hd.DistributionError, "calldata"):
                hd.verify_receipts(value, [receipt], "sepolia", "rpc", safes)
        receipt["transaction"] = hd.rc3.normalize_safe_transaction(package, 1)
        with mock.patch.object(hd.rc3, "validate_safe_execution_receipt"), mock.patch.object(hd, "_decode_transfer_logs", return_value=[]):
            with self.assertRaisesRegex(hd.DistributionError, "transfer-event"):
                hd.verify_receipts(value, [receipt], "sepolia", "rpc", safes)

    def test_exact_event_reconciliation_and_idempotent_verification(self):
        value = manifest(1)
        safes = {"multiSend": MULTISEND, "multiSendRuntimeCodeHash": "0x" + "2" * 64}
        package = hd._packages(value, safes)[0]
        receipt = {"safe": SOURCE, "nonce": 1, "safeTxHash": "0x" + "5" * 64, "signers": ["0x" + "6" * 40, "0x" + "7" * 40], "blockNumber": 100, "transactionHash": "0x" + "4" * 64, "transaction": hd.rc3.normalize_safe_transaction(package, 1), "rawReceipt": {"logs": [], "gasUsed": "0x5208"}}
        events = [(SOURCE, value["records"][0]["destinationAddress"], int(value["records"][0]["v2RawAmount"]))]
        invariant = {"totalSupplyRaw": "1000", "marketOpen": "true", "paused": "false", "implementationSlot": "0x01", "roleBindings": {}}
        with mock.patch.object(hd.rc3, "validate_safe_execution_receipt"), mock.patch.object(hd, "_decode_transfer_logs", return_value=events), mock.patch.object(hd, "_balance_at", side_effect=[2_000_000, 1_000_000, 0, 1_000_000, 2_000_000, 1_000_000, 0, 1_000_000]), mock.patch.object(hd, "_distribution_invariants", side_effect=[invariant, invariant, invariant, invariant]):
            first = hd.verify_receipts(value, [copy.deepcopy(receipt)], "sepolia", "rpc", safes)
            second = hd.verify_receipts(value, [copy.deepcopy(receipt)], "sepolia", "rpc", safes)
        self.assertEqual(first, second)
        self.assertEqual(first["status"], "VERIFIED_IDEMPOTENT")


if __name__ == "__main__":
    unittest.main()
