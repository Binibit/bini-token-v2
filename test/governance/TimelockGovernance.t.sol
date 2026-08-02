// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BiniTokenV2} from "../../src/BiniTokenV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ActorContract} from "../mocks/MarketMocks.sol";

contract TimelockGovernanceTest is Test {
    uint256 internal constant DELAY = 2 days;

    BiniTokenV2 internal token;
    TimelockController internal timelock;

    address internal proposer = address(0xA01);
    address internal executor = address(0xE01);
    address internal pauser;
    address internal genesis;

    function setUp() public {
        pauser = address(new ActorContract());
        genesis = address(new ActorContract());
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = executor;
        timelock = new TimelockController(DELAY, proposers, executors, address(0));

        BiniTokenV2 impl = new BiniTokenV2();
        token = BiniTokenV2(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(BiniTokenV2.initialize, (address(timelock), pauser, genesis, uint48(3 days)))
                )
            )
        );
    }

    function test_OpenMarketRequiresScheduledOneWayTimelockExecution() public {
        bytes memory data = abi.encodeCall(BiniTokenV2.openMarket, ());
        bytes32 predecessor;
        bytes32 salt = keccak256("BINI_OPEN_MARKET");

        vm.prank(proposer);
        timelock.schedule(address(token), 0, data, predecessor, salt, DELAY);

        vm.expectRevert();
        vm.prank(executor);
        timelock.execute(address(token), 0, data, predecessor, salt);

        vm.warp(block.timestamp + DELAY);
        vm.prank(executor);
        timelock.execute(address(token), 0, data, predecessor, salt);
        assertTrue(token.marketOpen());
    }

    function test_ScheduleEarlyRejectCancelRescheduleAndExecutePrivilegedCall() public {
        ActorContract infrastructure = new ActorContract();
        address[] memory accounts = new address[](1);
        accounts[0] = address(infrastructure);
        bytes memory data = abi.encodeCall(BiniTokenV2.setMarketInfrastructure, (accounts, true));
        bytes32 predecessor;
        bytes32 salt = keccak256("BINI_POLICY_CHANGE");

        vm.prank(proposer);
        timelock.schedule(address(token), 0, data, predecessor, salt, DELAY);
        vm.expectRevert();
        vm.prank(executor);
        timelock.execute(address(token), 0, data, predecessor, salt);

        bytes32 operationId = timelock.hashOperation(address(token), 0, data, predecessor, salt);
        vm.prank(proposer);
        timelock.cancel(operationId);
        assertFalse(token.isMarketInfrastructure(address(infrastructure)));

        vm.prank(proposer);
        timelock.schedule(address(token), 0, data, predecessor, salt, DELAY);
        vm.warp(block.timestamp + DELAY);
        vm.prank(executor);
        timelock.execute(address(token), 0, data, predecessor, salt);

        assertTrue(token.isMarketInfrastructure(address(infrastructure)));
        assertFalse(token.hasRole(token.MARKET_MANAGER_ROLE(), proposer));
        assertFalse(token.hasRole(token.MARKET_MANAGER_ROLE(), executor));
    }

    function test_PauserCannotOpenOrUnpause() public {
        vm.prank(pauser);
        token.pause();

        vm.expectRevert();
        vm.prank(pauser);
        token.openMarket();

        vm.expectRevert();
        vm.prank(pauser);
        token.unpause();
    }
}
