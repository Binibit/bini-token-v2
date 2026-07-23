// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BiniTokenV2Guarded as G} from "../../src/BiniTokenV2Guarded.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/// @title Emergency-freeze blast radius & recovery, per account class.
/// @notice Proves `emergencyRevoke(address[])` (Security / EMERGENCY_REVOKER) sets each address's class
///         to NONE and clears its approvedOperator flag while LEAVING BALANCE UNTOUCHED, and that
///         recovery is only possible through the CORRECT normal manager (never through Security).
contract FreezeRecoveryTest is Test {
    G internal t;

    // --- governance principals ---
    address internal timelock = address(0x700); // SYSTEM/CUSTODY/ENDPOINT/OPERATOR managers + POLICY + UNPAUSER
    address internal ops = address(0x704);       // PARTICIPANT_MANAGER only
    address internal security = address(0x701);  // PAUSER + EMERGENCY_REVOKER
    address internal genesis = address(0x703);   // BOOTSTRAP_OPERATOR + full supply; also SYSTEM

    // --- perimeter population ---
    address internal p1 = address(0xA11CE);      // PARTICIPANT
    address internal p2 = address(0xB0B);        // PARTICIPANT
    address internal sys1 = address(0x515709);   // SYSTEM (system-contract stand-in)
    address internal cust1 = address(0xC0570D1); // CUSTODY
    address internal endpoint = address(0xE9D0); // MARKET_ENDPOINT (pool / V4 PoolManager stand-in)
    address internal op1 = address(0x0FE9A705);  // PARTICIPANT + approved OPERATOR

    uint256 internal constant SEED = 1_000 ether;
    uint256 internal constant ENDPOINT_SEED = 500 ether;

    // ---------------- helpers ----------------
    function _a(address x) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = x;
    }

    function _cls(address x) internal view returns (uint256) {
        return uint256(t.accountClassOf(x));
    }

    function _unauth(address who, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, who, role);
    }

    function _notAllowed(address from, address to, address operator) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(G.TransferNotAllowed.selector, from, to, operator);
    }

    /// @dev Build a fully-populated, ACTIVATED (GUARDED) fixture.
    ///      During BOOTSTRAP every recipient must already be approved before genesis (BOOTSTRAP_OPERATOR)
    ///      can seed it, so classes are assigned first, then balances flow, then the mode is locked.
    function setUp() public {
        G impl = new G();
        t = G(address(new ERC1967Proxy(address(impl), abi.encodeCall(
            G.initialize, (timelock, ops, security, genesis, uint48(3 days))
        ))));

        // 1) classify the perimeter (timelock owns sensitive classes; ops owns PARTICIPANT)
        vm.startPrank(timelock);
        address[] memory sysAccts = new address[](2);
        sysAccts[0] = genesis; // genesis = SYSTEM so it can participate post-activation & pass the readiness gate
        sysAccts[1] = sys1;
        t.setSystemAccounts(sysAccts, true);
        t.setCustodyAccounts(_a(cust1), true);
        t.setMarketEndpoints(_a(endpoint), true);
        t.setOperators(_a(op1), true); // op1 gets the approved-operator FLAG
        vm.stopPrank();

        vm.startPrank(ops);
        t.setParticipants(_a(p1), true);
        t.setParticipants(_a(p2), true);
        t.setParticipants(_a(op1), true); // op1 is ALSO a participant so it can hold/move as `from`
        vm.stopPrank();

        // 2) seed balances while still in BOOTSTRAP (all recipients approved above)
        vm.startPrank(genesis);
        t.transfer(p1, SEED);
        t.transfer(p2, SEED);
        t.transfer(op1, SEED);
        t.transfer(sys1, SEED);
        t.transfer(cust1, SEED);
        t.transfer(endpoint, ENDPOINT_SEED);
        vm.stopPrank();

        // 3) p1 lets op1 spend, so op1 can act as an OPERATOR feeding the endpoint via transferFrom
        vm.prank(p1);
        t.approve(op1, type(uint256).max);

        // 4) lock the perimeter (genesis is SYSTEM -> readiness gate satisfied)
        vm.prank(timelock);
        t.activateGuardedMode();

        assertEq(uint256(t.transferMode()), uint256(G.TransferMode.GUARDED), "fixture not GUARDED");
    }

    // =====================================================================================
    // A) FREEZE PARTICIPANT p1
    // =====================================================================================
    function test_A_FreezeParticipant_BlastRadiusAndRecovery() public {
        uint256 p1Bal = t.balanceOf(p1);
        uint256 p2Bal = t.balanceOf(p2);
        uint256 gBal = t.balanceOf(genesis);

        // freeze
        vm.prank(security);
        t.emergencyRevoke(_a(p1));
        assertEq(_cls(p1), uint256(G.AccountClass.NONE), "p1 not frozen");
        assertEq(t.balanceOf(p1), p1Bal, "A: frozen balance moved"); // BALANCE UNCHANGED

        // frozen p1 cannot SEND
        vm.expectRevert(_notAllowed(p1, p2, p1));
        vm.prank(p1);
        t.transfer(p2, 1 ether);

        // frozen p1 cannot RECEIVE
        vm.expectRevert(_notAllowed(p2, p1, p2));
        vm.prank(p2);
        t.transfer(p1, 1 ether);

        // unrelated flows UNAFFECTED: p2 <-> genesis
        vm.prank(p2);
        t.transfer(genesis, 5 ether);
        vm.prank(genesis);
        t.transfer(p2, 5 ether);
        assertEq(t.balanceOf(p2), p2Bal, "A: p2 collateral-damaged");
        assertEq(t.balanceOf(genesis), gBal, "A: genesis collateral-damaged");

        // Security CANNOT restore (revoke-only authority)
        vm.expectRevert(_unauth(security, t.PARTICIPANT_MANAGER_ROLE()));
        vm.prank(security);
        t.setParticipants(_a(p1), true);

        // CORRECT authority: ops (PARTICIPANT_MANAGER) restores -> p1 can move again
        vm.prank(ops);
        t.setParticipants(_a(p1), true);
        assertEq(_cls(p1), uint256(G.AccountClass.PARTICIPANT), "A: p1 not restored");
        vm.prank(p1);
        t.transfer(p2, 1 ether);
        assertEq(t.balanceOf(p1), p1Bal - 1 ether, "A: post-restore transfer failed");
    }

    // =====================================================================================
    // B) FREEZE SYSTEM sys1  (recovery ONLY via timelock setSystemAccounts)
    // =====================================================================================
    function test_B_FreezeSystem_RecoveryAuthorityIsTimelock() public {
        uint256 sysBal = t.balanceOf(sys1);

        vm.prank(security);
        t.emergencyRevoke(_a(sys1));
        assertEq(_cls(sys1), uint256(G.AccountClass.NONE), "sys1 not frozen");
        assertEq(t.balanceOf(sys1), sysBal, "B: frozen balance moved"); // BALANCE UNCHANGED

        // transfers involving sys1 blocked (send + receive)
        vm.expectRevert(_notAllowed(sys1, p1, sys1));
        vm.prank(sys1);
        t.transfer(p1, 1 ether);
        vm.expectRevert(_notAllowed(p1, sys1, p1));
        vm.prank(p1);
        t.transfer(sys1, 1 ether);

        // unrelated participant flow unaffected
        vm.prank(p1);
        t.transfer(p2, 3 ether);

        // HAZARD: ops (PARTICIPANT_MANAGER) *could* re-add a now-NONE sys1, but only as PARTICIPANT (WRONG class).
        // The boundary check passes because sys1 is currently NONE. This is exactly why Security must NOT be
        // the restore path and why ops is NOT the correct recovery authority for a SYSTEM account.
        vm.prank(ops);
        t.setParticipants(_a(sys1), true);
        assertEq(_cls(sys1), uint256(G.AccountClass.PARTICIPANT), "B: expected mis-classification demo");
        vm.prank(ops);
        t.setParticipants(_a(sys1), false); // undo the wrong classification
        assertEq(_cls(sys1), uint256(G.AccountClass.NONE));

        // ops lacks the SYSTEM manager authority outright
        vm.expectRevert(_unauth(ops, t.SYSTEM_MANAGER_ROLE()));
        vm.prank(ops);
        t.setSystemAccounts(_a(sys1), true);

        // CORRECT authority: timelock (SYSTEM_MANAGER) restores the SYSTEM class -> flows resume
        vm.prank(timelock);
        t.setSystemAccounts(_a(sys1), true);
        assertEq(_cls(sys1), uint256(G.AccountClass.SYSTEM), "B: sys1 not restored to SYSTEM");
        vm.prank(sys1);
        t.transfer(p1, 1 ether);
        assertEq(t.balanceOf(sys1), sysBal - 1 ether, "B: post-restore transfer failed");
    }

    // =====================================================================================
    // C) FREEZE CUSTODY cust1  (recovery ONLY via timelock setCustodyAccounts)
    // =====================================================================================
    function test_C_FreezeCustody_RecoveryAuthorityIsTimelock() public {
        uint256 custBal = t.balanceOf(cust1);

        vm.prank(security);
        t.emergencyRevoke(_a(cust1));
        assertEq(_cls(cust1), uint256(G.AccountClass.NONE), "cust1 not frozen");
        assertEq(t.balanceOf(cust1), custBal, "C: frozen balance moved"); // BALANCE UNCHANGED

        // transfers involving cust1 blocked (send + receive)
        vm.expectRevert(_notAllowed(cust1, p1, cust1));
        vm.prank(cust1);
        t.transfer(p1, 1 ether);
        vm.expectRevert(_notAllowed(p1, cust1, p1));
        vm.prank(p1);
        t.transfer(cust1, 1 ether);

        // unrelated participant flow unaffected
        vm.prank(p1);
        t.transfer(p2, 3 ether);

        // ops is NOT the recovery authority for CUSTODY
        vm.expectRevert(_unauth(ops, t.CUSTODY_MANAGER_ROLE()));
        vm.prank(ops);
        t.setCustodyAccounts(_a(cust1), true);

        // CORRECT authority: timelock (CUSTODY_MANAGER) restores -> flows resume
        vm.prank(timelock);
        t.setCustodyAccounts(_a(cust1), true);
        assertEq(_cls(cust1), uint256(G.AccountClass.CUSTODY), "C: cust1 not restored to CUSTODY");
        vm.prank(cust1);
        t.transfer(p1, 1 ether);
        assertEq(t.balanceOf(cust1), custBal - 1 ether, "C: post-restore transfer failed");
    }

    // =====================================================================================
    // D) FREEZE MARKET_ENDPOINT endpoint  (the ENDPOINT loses its class; recovery via setMarketEndpoints)
    // =====================================================================================
    function test_D_FreezeEndpoint_OperatorCannotFeed_RecoverViaTimelock() public {
        // baseline: op1 (approved operator) can feed the endpoint via transferFrom(p1 -> endpoint)
        vm.prank(op1);
        t.transferFrom(p1, endpoint, 10 ether);
        assertEq(t.balanceOf(endpoint), ENDPOINT_SEED + 10 ether, "D: baseline feed failed");

        uint256 epBal = t.balanceOf(endpoint);

        // freeze the ENDPOINT
        vm.prank(security);
        t.emergencyRevoke(_a(endpoint));
        assertEq(_cls(endpoint), uint256(G.AccountClass.NONE), "D: endpoint not frozen");
        assertEq(t.balanceOf(endpoint), epBal, "D: frozen balance moved"); // BALANCE UNCHANGED

        // DISTINCTION vs operator-freeze (E): the OPERATOR is untouched here; only the endpoint's class is gone
        assertTrue(t.isApprovedOperator(op1), "D: operator flag must be intact");

        // operator can no longer feed the endpoint (destination is now NONE -> both-approved fails)
        vm.expectRevert(_notAllowed(p1, endpoint, op1));
        vm.prank(op1);
        t.transferFrom(p1, endpoint, 1 ether);

        // recovery via timelock (ENDPOINT_MANAGER); ops is not the authority
        vm.expectRevert(_unauth(ops, t.ENDPOINT_MANAGER_ROLE()));
        vm.prank(ops);
        t.setMarketEndpoints(_a(endpoint), true);

        vm.prank(timelock);
        t.setMarketEndpoints(_a(endpoint), true);
        assertEq(_cls(endpoint), uint256(G.AccountClass.MARKET_ENDPOINT), "D: endpoint not restored");

        // feeding resumes
        vm.prank(op1);
        t.transferFrom(p1, endpoint, 5 ether);
        assertEq(t.balanceOf(endpoint), epBal + 5 ether, "D: feed did not resume");
    }

    // =====================================================================================
    // E) FREEZE OPERATOR op1  (op1 loses its FLAG *and* its class; endpoint keeps its class)
    // =====================================================================================
    function test_E_FreezeOperator_LosesFlag_RecoverViaTimelock() public {
        // baseline: op1 can feed the endpoint
        vm.prank(op1);
        t.transferFrom(p1, endpoint, 10 ether);

        uint256 op1Bal = t.balanceOf(op1);

        // freeze the OPERATOR
        vm.prank(security);
        t.emergencyRevoke(_a(op1));

        // emergencyRevoke clears BOTH the operator flag AND the account class
        assertFalse(t.isApprovedOperator(op1), "E: operator flag not cleared");
        assertEq(_cls(op1), uint256(G.AccountClass.NONE), "E: op1 class not cleared");
        assertEq(t.balanceOf(op1), op1Bal, "E: frozen balance moved"); // BALANCE UNCHANGED

        // DISTINCTION vs endpoint-freeze (D): the ENDPOINT still holds its class here; the operator lost its flag
        assertEq(_cls(endpoint), uint256(G.AccountClass.MARKET_ENDPOINT), "E: endpoint must be untouched");

        // op1 can no longer act as operator to feed the endpoint (sender no longer approved-operator)
        vm.expectRevert(_notAllowed(p1, endpoint, op1));
        vm.prank(op1);
        t.transferFrom(p1, endpoint, 1 ether);

        // recovery of the OPERATOR CAPABILITY is via timelock (OPERATOR_MANAGER), not ops/security
        vm.expectRevert(_unauth(ops, t.OPERATOR_MANAGER_ROLE()));
        vm.prank(ops);
        t.setOperators(_a(op1), true);

        vm.prank(timelock);
        t.setOperators(_a(op1), true);
        assertTrue(t.isApprovedOperator(op1), "E: operator flag not restored");

        // operator capability restored -> feeding resumes (op1's own class is NOT required for this leg)
        vm.prank(op1);
        t.transferFrom(p1, endpoint, 5 ether);

        // full restoration: op1 also regains a class so it can hold/move as `from` again
        assertEq(_cls(op1), uint256(G.AccountClass.NONE), "E: class should still be NONE pre-restore");
        vm.prank(ops);
        t.setParticipants(_a(op1), true);
        assertEq(_cls(op1), uint256(G.AccountClass.PARTICIPANT), "E: op1 class not restored");
        vm.prank(op1);
        t.transfer(p2, 1 ether); // op1 can now move its own balance again
    }

    // =====================================================================================
    // F) GLOBAL PAUSE OVERRIDES THE GUARD (pause precedence)
    // =====================================================================================
    function test_F_GlobalPause_OverridesFullyApprovedTransfer() public {
        // sanity: p1 -> p2 is a fully-approved, normally-legal transfer
        vm.prank(p1);
        t.transfer(p2, 1 ether);

        // Security pauses
        vm.prank(security);
        t.pause();
        assertTrue(t.paused());

        // even a fully-approved participant->participant transfer reverts on pause (pause > guard)
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(p1);
        t.transfer(p2, 1 ether);

        // U2: only the timelock unpauses; then legal flow resumes
        vm.prank(timelock);
        t.unpause();
        assertFalse(t.paused());
        vm.prank(p1);
        t.transfer(p2, 1 ether);
        assertEq(t.balanceOf(p2), SEED + 2 ether, "F: flow did not resume after unpause");
    }

    // =====================================================================================
    // G) FREEZE NEVER MOVES BALANCE (dedicated invariant across a freeze)
    // =====================================================================================
    function test_G_FreezeNeverMovesBalance() public {
        uint256 balBefore = t.balanceOf(sys1);
        uint256 supplyBefore = t.totalSupply();

        vm.prank(security);
        t.emergencyRevoke(_a(sys1));

        assertEq(t.balanceOf(sys1), balBefore, "G: frozen address balance changed");
        assertEq(t.totalSupply(), supplyBefore, "G: totalSupply changed on freeze");
        assertEq(_cls(sys1), uint256(G.AccountClass.NONE), "G: class not set NONE");
    }
}
