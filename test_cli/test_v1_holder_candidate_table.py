import importlib.util
import json
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "tools" / "build-v1-holder-candidate-table.py"
SPEC = importlib.util.spec_from_file_location("build_v1_holder_candidate_table", MODULE_PATH)
candidate_table = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = candidate_table
SPEC.loader.exec_module(candidate_table)


class V1HolderCandidateTableTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.snapshot_path = ROOT / "data" / "bini-v1-holder-snapshot-25680981.json"
        cls.snapshot = json.loads(cls.snapshot_path.read_text(encoding="utf-8"))
        cls.result = candidate_table.build(
            cls.snapshot,
            "test-source-sha256",
            candidate_table.DEFAULT_DRAFT_THRESHOLD_RAW,
        )

    def test_snapshot_reconciles_exactly(self):
        self.assertEqual(self.snapshot["holderCount"], 497)
        self.assertEqual(self.snapshot["holderBalanceSumRaw"], self.snapshot["totalSupplyRaw"])
        self.assertEqual(self.snapshot["totalSupplyRaw"], "1000000000000000000000")

    def test_classification_counts_are_stable(self):
        counts = {item["holderType"]: item["count"] for item in self.result["classificationSummary"]}
        self.assertEqual(
            counts,
            {
                "CUSTODIAL_EXCHANGE_DEPOSIT": 3,
                "DEX_INFRASTRUCTURE": 1,
                "EIP7702_DELEGATED_ACCOUNT": 6,
                "EOA_CANDIDATE": 480,
                "SMART_CONTRACT": 2,
                "TOP5_OWNER_CLASSIFICATION_REQUIRED": 5,
            },
        )

    def test_default_draft_is_26_recipients_in_20_plus_6_batches(self):
        draft = [record for record in self.result["records"] if record["draftThresholdEligible"]]
        self.assertEqual(self.result["draftScenario"]["recipientCount"], 26)
        self.assertEqual(self.result["draftScenario"]["totalV1RawAmount"], "10770323813620009096")
        self.assertEqual(self.result["draftScenario"]["totalV2RawAmount"], "10770323813620009096000000")
        self.assertEqual([sum(record["draftBatch"] == batch for record in draft) for batch in ("1", "2")], [20, 6])
        self.assertTrue(all(record["holderType"] == "EOA_CANDIDATE" for record in draft))

    def test_conversion_is_exact_for_every_holder(self):
        for record in self.result["records"]:
            self.assertEqual(
                int(record["v2RawAmount"]),
                int(record["v1RawAmount"]) * candidate_table.V1_TO_V2_SCALE,
            )

    def test_non_reconciling_snapshot_is_rejected(self):
        broken = dict(self.snapshot)
        broken["holderBalanceSumRaw"] = "1"
        with self.assertRaisesRegex(ValueError, "do not reconcile"):
            candidate_table.build(broken, "test", candidate_table.DEFAULT_DRAFT_THRESHOLD_RAW)


if __name__ == "__main__":
    unittest.main()
