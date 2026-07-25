// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BiniTokenV2} from "../../src/BiniTokenV2.sol";
import {DeployBiniTokenV2} from "../../script/DeployBiniTokenV2.s.sol";
import {ActorContract} from "../mocks/MarketMocks.sol";

contract DeployBiniTokenV2Test is Test {
    DeployBiniTokenV2 internal deployer;
    address internal timelock;
    address internal pauser;
    address internal genesis;

    function setUp() public {
        deployer = new DeployBiniTokenV2();
        timelock = address(new ActorContract());
        pauser = address(new ActorContract());
        genesis = address(new ActorContract());

        vm.setEnv("EXPECTED_CHAIN_ID", vm.toString(block.chainid));
        vm.setEnv("ADMIN_TIMELOCK", vm.toString(timelock));
        vm.setEnv("EMERGENCY_PAUSER_SAFE", vm.toString(pauser));
        vm.setEnv("GENESIS_DISTRIBUTION_SAFE", vm.toString(genesis));
        vm.setEnv("ADMIN_TRANSFER_DELAY", "172800");
    }

    function test_RunRejectsWrongChainThenDeploysAndVerifiesProxy() public {
        vm.setEnv("EXPECTED_CHAIN_ID", vm.toString(block.chainid + 1));
        vm.expectRevert(bytes("UNEXPECTED_CHAIN_ID"));
        deployer.run();

        vm.setEnv("EXPECTED_CHAIN_ID", vm.toString(block.chainid));
        (BiniTokenV2 implementation, BiniTokenV2 token) = deployer.run();

        assertGt(address(implementation).code.length, 0);
        assertGt(address(token).code.length, 0);
        assertEq(token.totalSupply(), token.MAX_SUPPLY());
        assertEq(token.balanceOf(genesis), token.MAX_SUPPLY());
        assertEq(token.defaultAdmin(), timelock);
        assertTrue(token.hasRole(token.PAUSER_ROLE(), pauser));
        assertFalse(token.marketOpen());
    }
}
