// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 *  @notice Deploys and bootstraps the RC3 Timelock without leaving deployer authority.
 */
contract DeployTimelock is Script {
    function run() external returns (TimelockController timelock) {
        require(block.chainid == vm.envUint("BINI_V2_EXPECTED_CHAIN_ID"), "UNEXPECTED_CHAIN_ID");
        require(block.chainid != 1, "MAINNET_FORBIDDEN");
        address governanceSafe = vm.envAddress("BINI_GOVERNANCE_SAFE");
        address securitySafe = vm.envAddress("BINI_SECURITY_SAFE");
        uint256 minimumDelay = vm.envUint("BINI_TIMELOCK_MIN_DELAY");
        require(governanceSafe.code.length > 0 && securitySafe.code.length > 0, "SAFE_NOT_DEPLOYED");
        require(minimumDelay > 0, "ZERO_DELAY");

        address[] memory noProposers = new address[](0);
        address[] memory executors = new address[](1);
        executors[0] = governanceSafe;

        vm.startBroadcast();
        timelock = new TimelockController(minimumDelay, noProposers, executors, msg.sender);
        timelock.grantRole(timelock.PROPOSER_ROLE(), governanceSafe);
        timelock.grantRole(timelock.CANCELLER_ROLE(), securitySafe);
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), msg.sender);
        vm.stopBroadcast();

        require(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)), "NOT_SELF_ADMIN");
        require(timelock.hasRole(timelock.PROPOSER_ROLE(), governanceSafe), "BAD_PROPOSER");
        require(timelock.hasRole(timelock.EXECUTOR_ROLE(), governanceSafe), "BAD_EXECUTOR");
        require(timelock.hasRole(timelock.CANCELLER_ROLE(), securitySafe), "BAD_CANCELLER");
        require(!timelock.hasRole(timelock.CANCELLER_ROLE(), governanceSafe), "PROPOSER_IS_CANCELLER");
        require(!timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), msg.sender), "DEPLOYER_ADMIN");
    }
}
