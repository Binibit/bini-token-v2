// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BiniMigrationVault} from "../../src/BiniMigrationVault.sol";
import {MigrateKnownHolders} from "../../script/MigrateKnownHolders.s.sol";

contract MigrateKnownHoldersTest is Test {
    function test_GeneratesExactMigrationCalldata() public {
        address vault = address(0xB111);
        address holder = address(0xA11CE);
        address recipient = address(0xB0B);
        uint256 amount = 123_000_000_000;
        uint256 deadline = 1_800_000_000;
        vm.setEnv("MIGRATION_VAULT", vm.toString(vault));
        vm.setEnv("MIGRATION_HOLDER", vm.toString(holder));
        vm.setEnv("MIGRATION_V1_RAW_AMOUNT", vm.toString(amount));
        vm.setEnv("MIGRATION_RECIPIENT", vm.toString(recipient));
        vm.setEnv("MIGRATION_AUTHORIZATION_DEADLINE", vm.toString(deadline));

        (address target, uint256 value, bytes memory data) = new MigrateKnownHolders().run();
        assertEq(target, vault);
        assertEq(value, 0);
        assertEq(data, abi.encodeCall(BiniMigrationVault.migrate, (holder, amount, recipient, deadline, bytes(""))));
    }
}
