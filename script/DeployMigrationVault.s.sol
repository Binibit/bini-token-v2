// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {BiniMigrationVault} from "../src/BiniMigrationVault.sol";

contract DeployMigrationVault is Script {
    function run() external returns (BiniMigrationVault vault) {
        require(block.chainid == vm.envUint("BINI_V2_EXPECTED_CHAIN_ID"), "UNEXPECTED_CHAIN_ID");
        require(block.chainid != 1, "MAINNET_FORBIDDEN");
        address v1Token = vm.envAddress("BINI_MIGRATION_V1_TOKEN");
        address v2Token = vm.envAddress("BINI_MIGRATION_V2_TOKEN");
        address timelock = vm.envAddress("BINI_MIGRATION_TIMELOCK");
        require(
            v1Token.code.length > 0 && v2Token.code.length > 0 && timelock.code.length > 0, "DEPENDENCY_NOT_DEPLOYED"
        );
        vm.startBroadcast();
        vault = new BiniMigrationVault(v1Token, v2Token, timelock);
        vm.stopBroadcast();
        require(address(vault.v1Token()) == v1Token, "BAD_V1");
        require(address(vault.v2Token()) == v2Token, "BAD_V2");
        require(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), timelock), "BAD_ADMIN");
    }
}
