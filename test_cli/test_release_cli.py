import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "tools" / "bini_v2_cli.py"
SPEC = importlib.util.spec_from_file_location("bini_v2_cli", MODULE_PATH)
cli = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = cli
SPEC.loader.exec_module(cli)


ADDRESS_1 = "0x0000000000000000000000000000000000000001"
ADDRESS_2 = "0x0000000000000000000000000000000000000002"


class ReleaseCliTest(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)

    def tearDown(self):
        self.tempdir.cleanup()

    def write_json(self, name, value):
        path = self.root / name
        path.write_text(json.dumps(value), encoding="utf-8")
        return path

    def ledger(self):
        return {
            "ledgerVersion": "test-v1",
            "totalSupplyRaw": str(cli.TOTAL_SUPPLY_RAW),
            "allocations": [
                {
                    "allocationId": "treasury",
                    "category": "Treasury",
                    "recipient": ADDRESS_1,
                    "amountRaw": str(cli.TOTAL_SUPPLY_RAW),
                    "sourceBucket": "Genesis",
                    "vestingRequired": False,
                    "immediatelyLiquid": False,
                }
            ],
        }

    def test_exact_ledger_is_accepted(self):
        document, allocations = cli.validate_ledger(self.write_json("ledger.json", self.ledger()))
        self.assertEqual(document["ledgerVersion"], "test-v1")
        self.assertEqual(len(allocations), 1)

    def test_ledger_below_or_above_supply_is_rejected(self):
        for delta in (-1, 1):
            ledger = self.ledger()
            ledger["allocations"][0]["amountRaw"] = str(cli.TOTAL_SUPPLY_RAW + delta)
            with self.subTest(delta=delta), self.assertRaises(cli.ReleaseError):
                cli.validate_ledger(self.write_json(f"ledger-{delta}.json", ledger))

    def test_duplicate_and_zero_recipients_are_rejected(self):
        ledger = self.ledger()
        first = ledger["allocations"][0]
        first["amountRaw"] = str(cli.TOTAL_SUPPLY_RAW // 2)
        ledger["allocations"].append({**first, "allocationId": "second"})
        with self.assertRaises(cli.ReleaseError):
            cli.validate_ledger(self.write_json("duplicate.json", ledger))
        ledger = self.ledger()
        ledger["allocations"][0]["recipient"] = cli.ZERO_ADDRESS
        with self.assertRaises(cli.ReleaseError):
            cli.validate_ledger(self.write_json("zero.json", ledger))

    def test_direct_team_transfer_without_vesting_is_rejected(self):
        ledger = self.ledger()
        ledger["allocations"][0]["category"] = "Team Vesting"
        with self.assertRaises(cli.ReleaseError):
            cli.validate_ledger(self.write_json("team.json", ledger))

    def test_exact_erc20_safe_calldata(self):
        data = cli.erc20_transfer_data(ADDRESS_2, 42)
        self.assertEqual(data[:10], "0xa9059cbb")
        self.assertEqual(data[10:74], ADDRESS_2[2:].rjust(64, "0"))
        self.assertEqual(int(data[74:], 16), 42)

    def holder_csv(self, *, duplicate=False, wrong_conversion=False):
        second_address = ADDRESS_1 if duplicate else ADDRESS_2
        v2_amount = "999" if wrong_conversion else "2000000"
        return (
            ",".join(cli.CSV_COLUMNS)
            + "\n"
            + f"one,INVESTOR,{ADDRESS_1},{ADDRESS_1},1,1000000,1000000,VERIFIED,SELF_SERVICE,,batch-01,PLANNED,\n"
            + f"two,PARTNER,{second_address},{second_address},2,{v2_amount},1000000,VERIFIED,OPERATOR_ASSISTED,,batch-01,PLANNED,\n"
        )

    def test_holder_conversion_and_duplicates(self):
        path = self.root / "holders.csv"
        path.write_text(self.holder_csv(), encoding="utf-8")
        self.assertEqual(len(cli.load_holders(path)), 2)
        path.write_text(self.holder_csv(duplicate=True), encoding="utf-8")
        with self.assertRaises(cli.ReleaseError):
            cli.load_holders(path)
        path.write_text(self.holder_csv(wrong_conversion=True), encoding="utf-8")
        with self.assertRaises(cli.ReleaseError):
            cli.load_holders(path)

    def test_artifact_cannot_be_silently_overwritten(self):
        path = self.root / "receipt.json"
        cli.checked_write(path, {"txHash": "0x01"})
        with self.assertRaises(cli.ReleaseError):
            cli.checked_write(path, {"txHash": "0x02"})

    def test_mainnet_broadcast_requires_all_guards(self):
        context = cli.Context("mainnet", "BROADCAST", self.root / "mainnet.json", {"chainId": 1})
        with mock.patch.dict(os.environ, {}, clear=True), self.assertRaises(cli.ReleaseError):
            cli.guard_execution(context)
        env = {"EXECUTION_MODE": "BROADCAST", "CONFIRM_MAINNET": "yes", "EXPECTED_CHAIN_ID": "1"}
        with mock.patch.dict(os.environ, env, clear=True):
            cli.guard_execution(context)

    def test_incorrect_bytecode_hash_is_rejected(self):
        config = {
            "expectedTokenCreationBytecodeHash": "0x" + "1" * 64,
            "expectedVaultCreationBytecodeHash": "0x" + "2" * 64,
        }
        with mock.patch.object(cli, "inspect_hash", return_value="0x" + "0" * 64):
            with self.assertRaises(cli.ReleaseError):
                cli.check_bytecode_hashes(config)

    def test_distribution_destination_must_match_custody_manifest(self):
        config = {
            "treasurySafe": ADDRESS_1,
            "rewardsSafe": ADDRESS_1,
            "liquiditySafe": ADDRESS_1,
            "strategicReserveSafe": ADDRESS_1,
        }
        context = cli.Context("test", "PLAN", self.root / "test.json", config)
        deployment = {"migrationVault": ADDRESS_1}
        allocation = {"allocationId": "treasury", "category": "Treasury", "recipient": ADDRESS_2}
        with self.assertRaises(cli.ReleaseError):
            cli.validate_distribution_destinations(context, deployment, [allocation])

    def test_receipt_integer_supports_foundry_hex(self):
        self.assertEqual(cli.receipt_int("0x2a", "block"), 42)

    def test_integer_parser_rejects_float_and_negative(self):
        for value in (1.5, "1.0", "-1", True):
            with self.subTest(value=value), self.assertRaises(cli.ReleaseError):
                cli.strict_int(value, "amount")


if __name__ == "__main__":
    unittest.main()
