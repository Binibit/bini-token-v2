// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BiniTokenV2Guarded as G} from "../src/BiniTokenV2Guarded.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract GuardedUnitTest is Test {
    G internal t;
    address internal timelock = address(0x700); // POLICY + ENDPOINT + UPGRADER
    address internal pauser = address(0x701); // PAUSER + EMERGENCY_REVOKER
    address internal unpauser = address(0x702);
    address internal genesis = address(0x703); // supply + PARTICIPANT_MANAGER + BOOTSTRAP_OPERATOR
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401); // operator
    address internal dave = address(0xDA5E);

    function setUp() public {
        G impl = new G();
        t = G(address(new ERC1967Proxy(address(impl), abi.encodeCall(
            G.initialize, (timelock, pauser, unpauser, genesis, uint48(3 days))
        ))));
    }

    function _addr1(address a) internal pure returns (address[] memory r) { r = new address[](1); r[0] = a; }

    function test_InitialModeBootstrap() public view {
        assertEq(uint256(t.transferMode()), uint256(G.TransferMode.BOOTSTRAP));
        assertEq(t.totalSupply(), 1_000_000_000 ether);
        assertEq(t.balanceOf(genesis), 1_000_000_000 ether);
    }

    function _toGuarded() internal {
        // approve genesis(SYSTEM) + alice/bob(PARTICIPANT); then activate guarded
        vm.startPrank(genesis);
        t.setSystemAccounts(_addr1(genesis), true);
        address[] memory ps = new address[](2); ps[0] = alice; ps[1] = bob;
        t.setParticipants(ps, true);
        vm.stopPrank();
        vm.prank(timelock);
        t.activateGuardedMode();
        // seed alice
        vm.prank(genesis);
        t.transfer(alice, 1000 ether);
    }

    function test_Guarded_ParticipantToParticipant_Ok() public {
        _toGuarded();
        vm.prank(alice);
        t.transfer(bob, 10 ether);
        assertEq(t.balanceOf(bob), 10 ether);
    }

    function test_Guarded_ToUnknown_Blocked() public {
        _toGuarded();
        vm.expectRevert(abi.encodeWithSelector(G.TransferNotAllowed.selector, alice, dave, alice));
        vm.prank(alice);
        t.transfer(dave, 1 ether); // dave is NONE
    }

    function test_Guarded_FromUnknown_Blocked() public {
        _toGuarded();
        vm.prank(pauser);
        t.emergencyRevoke(_addr1(alice)); // alice -> NONE
        vm.expectRevert(abi.encodeWithSelector(G.TransferNotAllowed.selector, alice, bob, alice));
        vm.prank(alice);
        t.transfer(bob, 1 ether);
    }

    function test_Guarded_Operator_ApprovedVsNot() public {
        _toGuarded();
        vm.prank(alice);
        t.approve(carol, 100 ether);
        vm.prank(alice);
        t.approve(dave, 100 ether);
        // carol as approved operator -> ok
        vm.prank(genesis);
        t.setOperators(_addr1(carol), true);
        vm.prank(carol);
        t.transferFrom(alice, bob, 5 ether);
        assertEq(t.balanceOf(bob), 5 ether);
        // dave not an operator -> blocked
        vm.expectRevert(abi.encodeWithSelector(G.TransferNotAllowed.selector, alice, bob, dave));
        vm.prank(dave);
        t.transferFrom(alice, bob, 5 ether);
    }

    function test_Mode_OneWay_NoOpen() public {
        vm.prank(timelock);
        t.activateGuardedMode();
        vm.expectRevert(G.AlreadyGuarded.selector);
        vm.prank(timelock);
        t.activateGuardedMode();
        // no function returns to BOOTSTRAP / no OPEN mode exists (enum has only 2 states)
        assertEq(uint256(t.transferMode()), uint256(G.TransferMode.GUARDED));
    }

    function test_Bootstrap_OnlyOperatorSends() public {
        // pre-guarded: genesis (operator) can send; alice cannot
        vm.prank(genesis);
        t.transfer(alice, 100 ether); // from=operator -> ok
        vm.expectRevert(abi.encodeWithSelector(G.TransferNotAllowed.selector, alice, bob, alice));
        vm.prank(alice);
        t.transfer(bob, 1 ether);
    }

    function test_PausePrecedence() public {
        _toGuarded();
        vm.prank(pauser);
        t.pause();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(alice);
        t.transfer(bob, 1 ether);
    }
}
