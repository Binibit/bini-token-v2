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
        allocations = []
        for index, (allocation_id, pool, category, config_key, amount) in enumerate(cli.PHASE1_CANON, start=1):
            allocations.append(
                {
                    "allocationId": allocation_id,
                    "economicPool": pool,
                    "category": category,
                    "recipientConfigKey": config_key,
                    "recipient": "0x" + f"{index:040x}",
                    "amountRaw": str(amount),
                }
            )
        return {
            "ledgerVersion": "test-v1",
            "phase": "PHASE_1",
            "totalSupplyRaw": str(cli.TOTAL_SUPPLY_RAW),
            "allocations": allocations,
        }

    def test_exact_ledger_is_accepted(self):
        document, allocations = cli.validate_ledger(self.write_json("ledger.json", self.ledger()))
        self.assertEqual(document["ledgerVersion"], "test-v1")
        self.assertEqual(len(allocations), 9)

    def test_ledger_below_or_above_supply_is_rejected(self):
        for delta in (-1, 1):
            ledger = self.ledger()
            current = int(ledger["allocations"][0]["amountRaw"])
            ledger["allocations"][0]["amountRaw"] = str(current + delta)
            with self.subTest(delta=delta), self.assertRaises(cli.ReleaseError):
                cli.validate_ledger(self.write_json(f"ledger-{delta}.json", ledger))

    def test_duplicate_and_zero_recipients_are_rejected(self):
        ledger = self.ledger()
        ledger["allocations"][1]["recipient"] = ledger["allocations"][0]["recipient"]
        with self.assertRaises(cli.ReleaseError):
            cli.validate_ledger(self.write_json("duplicate.json", ledger))
        ledger = self.ledger()
        ledger["allocations"][0]["recipient"] = cli.ZERO_ADDRESS
        with self.assertRaises(cli.ReleaseError):
            cli.validate_ledger(self.write_json("zero.json", ledger))

    def test_later_phase_fields_are_rejected(self):
        ledger = self.ledger()
        ledger["allocations"][4]["vestingGrantId"] = "team-v1"
        with self.assertRaises(cli.ReleaseError):
            cli.validate_ledger(self.write_json("team.json", ledger))

    def test_noncanonical_allocation_is_rejected(self):
        ledger = self.ledger()
        ledger["allocations"][8]["amountRaw"] = str(int(ledger["allocations"][8]["amountRaw"]) - 1)
        with self.assertRaises(cli.ReleaseError):
            cli.validate_ledger(self.write_json("noncanonical.json", ledger))

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
            + f"one,{ADDRESS_1},{ADDRESS_1},1,1000000,rewards-year-1,{ADDRESS_1},INVESTOR,VERIFIED_SIGNATURE,SELF_SERVICE,NONE,batch-01,PLANNED\n"
            + f"two,{second_address},{second_address},2,{v2_amount},rewards-year-2-reserve,{ADDRESS_2},PARTNER,SAFE_RECORD,OPERATOR_ASSISTED,PRESERVE_EXISTING_SCHEDULE,batch-01,PLANNED\n"
        )

    def test_holder_conversion_and_duplicates(self):
        path = self.root / "holders.csv"
        path.write_text(self.holder_csv(), encoding="utf-8")
        self.assertEqual(len(cli.load_holders(path)), 2)
        path.write_text(self.holder_csv(duplicate=True), encoding="utf-8")
        with self.assertRaises(cli.ReleaseError):
            cli.load_holders(path)

    def test_migration_accounting_is_bound_to_each_phase1_source(self):
        path = self.root / "holders.csv"
        path.write_text(self.holder_csv(), encoding="utf-8")
        rows = cli.load_holders(path)
        config = {}
        for index, (_, _, _, config_key, _) in enumerate(cli.PHASE1_CANON, start=1):
            config[config_key] = "0x" + f"{index:040x}"
        context = cli.Context("test", "PLAN", self.root / "test.json", config)
        rows[0]["sourceTopLevelSafe"] = config["rewardsY1Safe"]
        rows[1]["sourceTopLevelSafe"] = config["rewardsY2ReserveSafe"]
        migration = {
            "fundingSources": [
                {
                    "sourceAllocationId": "rewards-year-1",
                    "sourceTopLevelSafe": config["rewardsY1Safe"],
                    "fundingRaw": "1000000",
                },
                {
                    "sourceAllocationId": "rewards-year-2-reserve",
                    "sourceTopLevelSafe": config["rewardsY2ReserveSafe"],
                    "fundingRaw": "2000000",
                },
            ]
        }
        self.assertEqual(
            cli.validate_migration_accounting(rows, context, migration),
            {"rewards-year-1": 1000000, "rewards-year-2-reserve": 2000000},
        )
        migration["fundingSources"][1]["fundingRaw"] = "1"
        with self.assertRaises(cli.ReleaseError):
            cli.validate_migration_accounting(rows, context, migration)
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
        ledger = self.ledger()
        config = {
            config_key: allocation["recipient"]
            for allocation, (_, _, _, config_key, _) in zip(ledger["allocations"], cli.PHASE1_CANON)
        }
        context = cli.Context("test", "PLAN", self.root / "test.json", config)
        ledger["allocations"][0]["recipient"] = ADDRESS_2
        with self.assertRaises(cli.ReleaseError):
            cli.validate_distribution_destinations(context, ledger["allocations"])

    def test_receipt_integer_supports_foundry_hex(self):
        self.assertEqual(cli.receipt_int("0x2a", "block"), 42)

    def test_cast_json_call_decodes_large_integer_and_bool(self):
        self.assertEqual(cli.decode_cast_call('["1000000000000000000000000000"]', "supply"), "1000000000000000000000000000")
        self.assertEqual(cli.decode_cast_call("[true]", "market state"), "true")
        with self.assertRaises(cli.ReleaseError):
            cli.decode_cast_call('["one", "two"]', "unexpected tuple")

    def test_dex_policy_requires_v2_v3_and_unique_addresses(self):
        policy = {
            "phase": "PHASE_3",
            "expectedPolicyState": "PRE_MARKET_BLOCKED",
            "factories": [
                {"name": "v2", "kind": "UNISWAP_V2", "address": ADDRESS_1, "runtimeCodeHash": "0x" + "1" * 64}
            ],
            "infrastructure": [
                {"name": "v4", "kind": "POOL_MANAGER", "address": ADDRESS_2, "runtimeCodeHash": "0x" + "2" * 64}
            ],
        }
        with self.assertRaises(cli.ReleaseError):
            cli.validate_dex_policy(policy)
        policy["factories"].append(
            {"name": "v3", "kind": "UNISWAP_V3", "address": ADDRESS_2, "runtimeCodeHash": "0x" + "3" * 64}
        )
        with self.assertRaises(cli.ReleaseError):
            cli.validate_dex_policy(policy)

    def test_timelock_package_contains_schedule_and_execute_safe_transactions(self):
        context = cli.Context(
            "test",
            "PLAN",
            self.root / "test.json",
            {
                "chainId": 31337,
                "timelockMinDelay": 172800,
                "timelockProposerSafe": ADDRESS_1,
                "timelockExecutorSafe": ADDRESS_2,
            },
        )
        deployment = {"timelock": "0x0000000000000000000000000000000000000003"}
        calls = [
            {
                "to": "0x0000000000000000000000000000000000000004",
                "value": "0",
                "data": cli.erc20_transfer_data(ADDRESS_1, 1),
            }
        ]
        package = cli.timelock_package(context, deployment, "test", calls, "input-v1")
        self.assertEqual(package["scheduleProposal"]["transactions"][0]["data"][:10], "0x8f2a0bb0")
        self.assertEqual(package["executeProposal"]["transactions"][0]["data"][:10], "0xe38335e5")
        self.assertEqual(package["scheduleProposal"]["meta"]["createdFromSafeAddress"], ADDRESS_1)

    def test_integer_parser_rejects_float_and_negative(self):
        for value in (1.5, "1.0", "-1", True):
            with self.subTest(value=value), self.assertRaises(cli.ReleaseError):
                cli.strict_int(value, "amount")


if __name__ == "__main__":
    unittest.main()
