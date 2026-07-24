// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BiniTokenV2Guarded as G} from "../src/BiniTokenV2Guarded.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract GuardedUnitTest is Test {
    G internal t;
    address internal timelock = address(0x700); // POLICY/SYSTEM/CUSTODY/ENDPOINT/OPERATOR/UPGRADER
    address internal ops = address(0x704); // PARTICIPANT_MANAGER only
    address internal security = address(0x701); // PAUSER + EMERGENCY_REVOKER
    address internal unpauser = address(0x702);
    address internal genesis = address(0x703); // supply + BOOTSTRAP_OPERATOR
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal poolish = address(0xC0FFEE);

    function setUp() public {
        G impl = new G();
        t = G(
            address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(G.initialize, (timelock, ops, security, genesis, uint48(3 days)))
                )
            )
        );
    }

    function _a(address x) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = x;
    }

    function _unauth(bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(0x704), role);
    }

    // ---------- P0.6 / P0.1: role separation + class boundaries ----------
    function test_Ops_HasOnlyParticipantManager() public view {
        assertTrue(t.hasRole(t.PARTICIPANT_MANAGER_ROLE(), ops));
        assertFalse(t.hasRole(t.SYSTEM_MANAGER_ROLE(), ops));
        assertFalse(t.hasRole(t.ENDPOINT_MANAGER_ROLE(), ops));
        assertFalse(t.hasRole(t.OPERATOR_MANAGER_ROLE(), ops));
        assertFalse(t.hasRole(t.CUSTODY_MANAGER_ROLE(), ops));
    }

    function test_Ops_CannotSetSystem() public {
        vm.expectRevert(_unauth(t.SYSTEM_MANAGER_ROLE()));
        vm.prank(ops);
        t.setSystemAccounts(_a(poolish), true);
    }

    function test_Ops_CannotSetEndpoint() public {
        vm.expectRevert(_unauth(t.ENDPOINT_MANAGER_ROLE()));
        vm.prank(ops);
        t.setMarketEndpoints(_a(poolish), true);
    }

    function test_Ops_CannotSetOperator() public {
        vm.expectRevert(_unauth(t.OPERATOR_MANAGER_ROLE()));
        vm.prank(ops);
        t.setOperators(_a(poolish), true);
    }

    // P0.1 core: Ops cannot reclassify/revoke a Timelock-approved SYSTEM address via its participant setter
    function test_Ops_CannotCrossClassBoundary() public {
        vm.prank(timelock);
        t.setSystemAccounts(_a(poolish), true); // poolish = SYSTEM (Timelock)
        vm.expectRevert(
            abi.encodeWithSelector(
                G.ClassBoundaryViolation.selector, poolish, G.AccountClass.SYSTEM, G.AccountClass.PARTICIPANT
            )
        );
        vm.prank(ops);
        t.setParticipants(_a(poolish), false); // Ops tries to revoke a SYSTEM addr -> blocked
    }

    function test_Security_CannotApprove() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, security, t.PARTICIPANT_MANAGER_ROLE()
            )
        );
        vm.prank(security);
        t.setParticipants(_a(alice), true); // security only revokes, cannot approve
    }

    // ---------- P0.3: bootstrap cannot create trapped balances ----------
    function test_Bootstrap_ToUnapproved_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(G.BootstrapRecipientNotApproved.selector, bob));
        vm.prank(genesis);
        t.transfer(bob, 1 ether); // bob not onboarded -> blocked in BOOTSTRAP
    }

    function test_Bootstrap_ToApproved_Ok() public {
        vm.prank(ops);
        t.setParticipants(_a(alice), true);
        vm.prank(genesis);
        t.transfer(alice, 100 ether);
        assertEq(t.balanceOf(alice), 100 ether);
    }

    // ---------- GUARDED policy ----------
    function _guarded() internal {
        vm.prank(timelock);
        t.setSystemAccounts(_a(genesis), true);
        vm.startPrank(ops);
        t.setParticipants(_a(alice), true);
        t.setParticipants(_a(bob), true);
        vm.stopPrank();
        vm.prank(genesis);
        t.transfer(alice, 1000 ether); // seed while BOOTSTRAP (alice approved)
        vm.prank(timelock);
        t.activateGuardedMode();
    }

    function test_Guarded_ParticipantToParticipant() public {
        _guarded();
        vm.prank(alice);
        t.transfer(bob, 10 ether);
        assertEq(t.balanceOf(bob), 10 ether);
    }

    function test_Guarded_ToUnknown_Blocked() public {
        _guarded();
        vm.expectRevert(abi.encodeWithSelector(G.TransferNotAllowed.selector, alice, poolish, alice));
        vm.prank(alice);
        t.transfer(poolish, 1 ether);
    }

    // ---------- P0.2: emergency freeze keeps balance, blocks movement, restorable ----------
    function test_EmergencyRevoke_FreezesButKeepsBalance() public {
        _guarded();
        vm.prank(security);
        t.emergencyRevoke(_a(alice));
        assertEq(uint256(t.accountClassOf(alice)), uint256(G.AccountClass.NONE));
        assertEq(t.balanceOf(alice), 1000 ether); // balance UNCHANGED (freeze, not confiscation)
        vm.expectRevert(abi.encodeWithSelector(G.TransferNotAllowed.selector, alice, bob, alice));
        vm.prank(alice);
        t.transfer(bob, 1 ether); // frozen: cannot send
        // restore via normal manager
        vm.prank(ops);
        t.setParticipants(_a(alice), true);
        vm.prank(alice);
        t.transfer(bob, 1 ether);
        assertEq(t.balanceOf(bob), 1 ether);
    }

    // ---------- P0: genesis activation self-trap gate ----------
    function test_Activate_Blocked_WhenGenesisHoldsAndUnapproved() public {
        // genesis holds full supply, not classified -> activation must refuse (else 1B stranded)
        assertFalse(t.activationReady());
        vm.expectRevert(abi.encodeWithSelector(G.GenesisNotReady.selector, genesis, 1_000_000_000 ether));
        vm.prank(timelock);
        t.activateGuardedMode();
    }

    function test_Activate_Ok_WhenGenesisApproved() public {
        vm.prank(timelock);
        t.setSystemAccounts(_a(genesis), true);
        assertTrue(t.activationReady());
        vm.prank(timelock);
        t.activateGuardedMode();
        assertEq(uint256(t.transferMode()), uint256(G.TransferMode.GUARDED));
    }

    function test_Activate_Ok_WhenGenesisEmptied() public {
        // onboard alice, move ALL supply out of genesis, then activate with genesis unclassified
        vm.prank(ops);
        t.setParticipants(_a(alice), true);
        vm.prank(genesis);
        t.transfer(alice, 1_000_000_000 ether);
        assertEq(t.balanceOf(genesis), 0);
        assertTrue(t.activationReady());
        vm.prank(timelock);
        t.activateGuardedMode();
        assertEq(uint256(t.transferMode()), uint256(G.TransferMode.GUARDED));
    }

    // ---------- mode one-way / supply ----------
    function test_Mode_OneWay_NoOpen() public {
        vm.prank(timelock);
        t.setSystemAccounts(_a(genesis), true); // genesis ready so activation is allowed
        vm.prank(timelock);
        t.activateGuardedMode();
        vm.expectRevert(G.AlreadyGuarded.selector);
        vm.prank(timelock);
        t.activateGuardedMode();
        assertEq(uint256(t.transferMode()), uint256(G.TransferMode.GUARDED));
    }

    function test_Supply() public view {
        assertEq(t.totalSupply(), 1_000_000_000 ether);
        assertEq(t.cap(), 1_000_000_000 ether);
        assertEq(t.balanceOf(genesis), 1_000_000_000 ether);
    }

    function test_PausePrecedence() public {
        _guarded();
        vm.prank(security);
        t.pause();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(alice);
        t.transfer(bob, 1 ether);
    }

    // ---------- U2 unpause topology: Security pauses, only Timelock unpauses ----------
    function test_Unpause_U2_OnlyTimelock() public {
        vm.prank(security);
        t.pause();
        // Security holds PAUSER but NOT UNPAUSER -> cannot unpause
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, security, t.UNPAUSER_ROLE()
            )
        );
        vm.prank(security);
        t.unpause();
        // Timelock (U2 unpauser, reached via the Timelock delay off-chain) can unpause
        vm.prank(timelock);
        t.unpause();
        assertFalse(t.paused());
    }
}
