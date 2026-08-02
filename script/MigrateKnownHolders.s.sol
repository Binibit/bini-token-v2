// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {BiniMigrationVault} from "../src/BiniMigrationVault.sol";

/**
 *  @notice Produces one migration call. Signing and execution remain explicit CLI stages.
 */
contract MigrateKnownHolders is Script {
    function run() external view returns (address target, uint256 value, bytes memory data) {
        target = vm.envAddress("MIGRATION_VAULT");
        address holder = vm.envAddress("MIGRATION_HOLDER");
        uint256 v1RawAmount = vm.envUint("MIGRATION_V1_RAW_AMOUNT");
        address recipient = vm.envAddress("MIGRATION_RECIPIENT");
        uint256 deadline = vm.envUint("MIGRATION_AUTHORIZATION_DEADLINE");
        bytes memory signature = vm.envOr("MIGRATION_RECIPIENT_SIGNATURE", bytes(""));
        require(holder != address(0) && recipient != address(0) && v1RawAmount != 0, "INVALID_MIGRATION");
        value = 0;
        data = abi.encodeCall(BiniMigrationVault.migrate, (holder, v1RawAmount, recipient, deadline, signature));
    }
}
