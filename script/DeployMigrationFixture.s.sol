// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {BiniV1TestFixture} from "../src/fixtures/BiniV1TestFixture.sol";

contract DeployMigrationFixture is Script {
    function run() external returns (BiniV1TestFixture fixture) {
        require(block.chainid == vm.envUint("BINI_V2_EXPECTED_CHAIN_ID"), "UNEXPECTED_CHAIN_ID");
        require(block.chainid != 1, "MAINNET_FORBIDDEN");
        address fixtureAdmin = vm.envAddress("BINI_V1_FIXTURE_ADMIN");
        vm.startBroadcast();
        fixture = new BiniV1TestFixture(fixtureAdmin);
        vm.stopBroadcast();
        require(fixture.decimals() == 12, "BAD_FIXTURE_DECIMALS");
    }
}
