// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {DeployTimelock} from "../../script/DeployTimelock.s.sol";
import {ActorContract} from "../mocks/MarketMocks.sol";

contract DeployTimelockTest is Test {
    DeployTimelock internal script;
    address internal governanceSafe;
    address internal securitySafe;
    address internal deployer;

    function setUp() public {
        script = new DeployTimelock();
        governanceSafe = address(new ActorContract());
        securitySafe = address(new ActorContract());
        deployer = makeAddr("sepolia-deployer");

        vm.setEnv("BINI_V2_EXPECTED_CHAIN_ID", vm.toString(block.chainid));
        vm.setEnv("BINI_GOVERNANCE_SAFE", vm.toString(governanceSafe));
        vm.setEnv("BINI_SECURITY_SAFE", vm.toString(securitySafe));
        vm.setEnv("BINI_TIMELOCK_DEPLOYER", vm.toString(deployer));
        vm.setEnv("BINI_TIMELOCK_MIN_DELAY", "600");
    }

    function test_RunUsesBroadcastSignerAsTemporaryAdminAndRenouncesIt() public {
        TimelockController timelock = script.run();

        assertEq(timelock.getMinDelay(), 600);
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), governanceSafe));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), governanceSafe));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), securitySafe));
        assertFalse(timelock.hasRole(timelock.CANCELLER_ROLE(), governanceSafe));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), deployer));
    }
}
