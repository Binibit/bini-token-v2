// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BiniTokenV2Guarded as G} from "../../src/BiniTokenV2Guarded.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev Dedicated adversary contract. Every `transferFrom` is executed with `msg.sender == address(this)`,
///      so inside `_update` the ERC20 caller ("operator") is THIS contract — exactly the global-operator
///      lever we are attacking. `pull` bubbles the revert; `tryPull` swallows it and returns success.
contract MaliciousOperator {
    G t;
    constructor(G _t) { t = _t; }
    function pull(address from, address to, uint256 amt) external { t.transferFrom(from, to, amt); }
    function tryPull(address from, address to, uint256 amt) external returns (bool ok) {
        try t.transferFrom(from, to, amt) { ok = true; } catch { ok = false; }
    }
}

/// ADVERSARIAL PROOF of the GLOBAL-OPERATOR threat model for BiniTokenV2Guarded.
///
/// The `approvedOperator[op]` flag is GLOBAL, not per-holder and not per-destination. Once the Timelock
/// approves an operator, that operator can move BINI out of ANY allowance-granting approved holder. The
/// guard bounds this in exactly two independent dimensions and NOTHING else:
///   (a) ERC20 allowance   — the holder must have approved the operator for >= amount (standard ERC20).
///   (b) perimeter/class   — both `from` and `to` must be approved (class != NONE); a MARKET_ENDPOINT
///                           destination additionally REQUIRES the caller be an approved operator.
///
/// What is NOT bounded (accepted risk): an approved operator with unlimited allowance can (1) drain a
/// holder to an approved endpoint, (2) do so across MANY holders simultaneously, and (3) also shuffle
/// tokens participant->participant. The operator's power is emphatically NOT endpoint-only.
///
/// Every row below executes a REAL `transferFrom` through `MaliciousOperator` (msg.sender == operator).
contract GlobalOperatorThreatTest is Test {
    G internal t;
    MaliciousOperator internal mop;

    address internal timelock = address(0x700); // POLICY/SYSTEM/ENDPOINT/OPERATOR managers
    address internal ops = address(0x704);      // PARTICIPANT_MANAGER
    address internal security = address(0x701); // EMERGENCY_REVOKER + PAUSER
    address internal genesis = address(0x703);  // SYSTEM + BOOTSTRAP_OPERATOR + supply

    address internal p1 = address(0xA11CE);     // PARTICIPANT, seeded holder
    address internal p2 = address(0xB0B);       // PARTICIPANT, seeded holder
    address internal endpoint = address(0xE9D); // MARKET_ENDPOINT (approved pool/PoolManager)
    address internal outsider = address(0xDEAD);// never approved, class NONE forever

    uint256 internal constant SEED = 1_000 ether;

    function _a(address x) internal pure returns (address[] memory r) { r = new address[](1); r[0] = x; }

    function setUp() public {
        G impl = new G();
        t = G(address(new ERC1967Proxy(address(impl), abi.encodeCall(
            G.initialize, (timelock, ops, security, genesis, uint48(3 days))
        ))));

        // Build the perimeter. Sensitive classes -> Timelock; PARTICIPANT -> Ops.
        vm.startPrank(timelock);
        t.setSystemAccounts(_a(genesis), true);      // genesis is a SYSTEM sender (also lets it activate)
        t.setMarketEndpoints(_a(endpoint), true);    // the one approved market endpoint
        vm.stopPrank();

        vm.startPrank(ops);
        t.setParticipants(_a(p1), true);
        t.setParticipants(_a(p2), true);
        vm.stopPrank();

        // Seed both holders while still in BOOTSTRAP (genesis == BOOTSTRAP_OPERATOR, recipients approved).
        vm.startPrank(genesis);
        t.transfer(p1, SEED);
        t.transfer(p2, SEED);
        vm.stopPrank();

        // Lock the perimeter: BOOTSTRAP -> GUARDED (one-way).
        vm.prank(timelock);
        t.activateGuardedMode();

        // Deploy the adversary and have the Timelock bless it as a GLOBAL operator.
        mop = new MaliciousOperator(t);
        vm.prank(timelock);
        t.setOperators(_a(address(mop)), true);

        // Sanity on the fixture.
        assertTrue(t.isApprovedOperator(address(mop)));
        assertEq(uint256(t.accountClassOf(p1)), uint256(G.AccountClass.PARTICIPANT));
        assertEq(uint256(t.accountClassOf(p2)), uint256(G.AccountClass.PARTICIPANT));
        assertEq(uint256(t.accountClassOf(endpoint)), uint256(G.AccountClass.MARKET_ENDPOINT));
        assertEq(uint256(t.accountClassOf(outsider)), uint256(G.AccountClass.NONE));
        assertEq(t.balanceOf(p1), SEED);
        assertEq(t.balanceOf(p2), SEED);
    }

    // ROW 1 — NO ALLOWANCE.  [prevented-by-allowance]
    // p1 has granted the operator ZERO allowance. Even though mop is a global operator and endpoint is a
    // valid destination, the standard ERC20 allowance check fires first and blocks the pull.
    function test_Row1_NoAllowance_PreventedByAllowance() public {
        assertEq(t.allowance(p1, address(mop)), 0);
        vm.expectRevert(abi.encodeWithSelector(
            IERC20Errors.ERC20InsufficientAllowance.selector, address(mop), 0, 100 ether
        ));
        mop.pull(p1, endpoint, 100 ether);
    }

    // ROW 2 — BOUNDED ALLOWANCE.  [bounded-by-allowance]
    // p1 approves exactly 100. The operator can pull up to 100 to the endpoint; the 101st unit reverts
    // because the allowance is now exhausted. The allowance is a hard ceiling on operator extraction.
    function test_Row2_BoundedAllowance_BoundedByAllowance() public {
        vm.prank(p1);
        t.approve(address(mop), 100 ether);

        mop.pull(p1, endpoint, 100 ether); // OK: within allowance, endpoint is approved, mop is operator
        assertEq(t.balanceOf(endpoint), 100 ether);
        assertEq(t.allowance(p1, address(mop)), 0);

        vm.expectRevert(abi.encodeWithSelector(
            IERC20Errors.ERC20InsufficientAllowance.selector, address(mop), 0, 1
        ));
        mop.pull(p1, endpoint, 1); // 1 wei over the ceiling -> blocked
    }

    // ROW 3 — UNLIMITED ALLOWANCE + APPROVED ENDPOINT.  [accepted-global-operator-risk] (CORE EXPOSURE)
    // With an unlimited allowance the guard imposes NO extra ceiling: the operator drains p1 wholesale to
    // an approved endpoint. This is the accepted risk of the global-operator design.
    function test_Row3_UnlimitedAllowance_AcceptedGlobalOperatorRisk() public {
        vm.prank(p1);
        t.approve(address(mop), type(uint256).max);

        mop.pull(p1, endpoint, SEED); // move the ENTIRE holder balance
        assertEq(t.balanceOf(p1), 0);
        assertEq(t.balanceOf(endpoint), SEED);
    }

    // ROW 4 — CROSS-HOLDER (the flag is GLOBAL).  [accepted-global-operator-risk]
    // A SINGLE approved-operator flag reaches EVERY holder that grants it allowance. Here the same mop
    // drains BOTH p1 and p2 to the endpoint in one test, proving the flag is not scoped to any one holder.
    function test_Row4_CrossHolder_AcceptedGlobalOperatorRisk() public {
        vm.prank(p1);
        t.approve(address(mop), type(uint256).max);
        vm.prank(p2);
        t.approve(address(mop), type(uint256).max);

        mop.pull(p1, endpoint, SEED);
        mop.pull(p2, endpoint, SEED);

        assertEq(t.balanceOf(p1), 0);
        assertEq(t.balanceOf(p2), 0);
        assertEq(t.balanceOf(endpoint), 2 * SEED); // both holders' funds, one operator flag
    }

    // ROW 5 — CANNOT REDIRECT TO AN OUTSIDER.  [prevented-by-endpoint/perimeter — the containment]
    // Even with unlimited allowance, the operator cannot exfiltrate to a class-NONE address: `bothApproved`
    // fails because `outsider` is not in the perimeter. This is the containment boundary.
    function test_Row5_CannotRedirectToOutsider_PreventedByPerimeter() public {
        vm.prank(p1);
        t.approve(address(mop), type(uint256).max);

        bool ok = mop.tryPull(p1, outsider, 100 ether);
        assertFalse(ok);                       // reverted: TransferNotAllowed (to == NONE)
        assertEq(t.balanceOf(outsider), 0);
        assertEq(t.balanceOf(p1), SEED);       // nothing moved
    }

    // ROW 6 — PARTICIPANT -> PARTICIPANT VIA OPERATOR.  [accepted-global-operator-risk — NOT endpoint-only]
    // *** KEY FINDING ***  The destination p2 is a PARTICIPANT, not a MARKET_ENDPOINT. Per policy, for a
    // non-endpoint destination `senderOk = (msg.sender == from || approvedOperator[msg.sender])`. Because
    // mop IS an approved operator, THIS SUCCEEDS: an approved operator can shuffle BINI between two
    // participants without either participant initiating the transfer. Operator power is NOT endpoint-only.
    function test_Row6_ParticipantToParticipant_ViaOperator_SUCCEEDS() public {
        vm.prank(p1);
        t.approve(address(mop), type(uint256).max);

        uint256 p2Before = t.balanceOf(p2);
        mop.pull(p1, p2, 250 ether); // p2 is a PARTICIPANT; operator moves p1 -> p2 anyway
        assertEq(t.balanceOf(p1), SEED - 250 ether);
        assertEq(t.balanceOf(p2), p2Before + 250 ether); // FINDING: succeeded, operator reached p2 (non-endpoint)
    }

    // ROW 7 — REVOKED ENDPOINT.  [prevented-by-endpoint-class]
    // Revoking the endpoint drops it to class NONE; the previously-drainable destination is no longer a
    // valid perimeter member, so the pull now fails even with unlimited allowance and an active operator.
    function test_Row7_RevokedEndpoint_PreventedByEndpointClass() public {
        vm.prank(p1);
        t.approve(address(mop), type(uint256).max);

        vm.prank(timelock);
        t.setMarketEndpoints(_a(endpoint), false); // endpoint -> NONE
        assertEq(uint256(t.accountClassOf(endpoint)), uint256(G.AccountClass.NONE));

        bool ok = mop.tryPull(p1, endpoint, 100 ether);
        assertFalse(ok);                   // reverted: to is now class NONE
        assertEq(t.balanceOf(p1), SEED);
    }

    // ROW 8 — REVOKED OPERATOR.  [prevented-by-operator-revocation]
    // With the endpoint still approved, revoking the operator flag alone is sufficient: an endpoint
    // destination REQUIRES an approved operator, and mop no longer qualifies (msg.sender not an operator).
    function test_Row8_RevokedOperator_PreventedByOperatorRevocation() public {
        vm.prank(p1);
        t.approve(address(mop), type(uint256).max);

        vm.prank(timelock);
        t.setOperators(_a(address(mop)), false); // demote the operator
        assertFalse(t.isApprovedOperator(address(mop)));
        assertEq(uint256(t.accountClassOf(endpoint)), uint256(G.AccountClass.MARKET_ENDPOINT)); // endpoint still valid

        bool ok = mop.tryPull(p1, endpoint, 100 ether);
        assertFalse(ok);                   // reverted: endpoint dest needs an operator, mop no longer one
        assertEq(t.balanceOf(p1), SEED);
    }

    // ROW 9 — FROZEN HOLDER.  [prevented-by-freeze]
    // Emergency-freezing the holder sets its class to NONE (balance untouched). `bothApproved` now fails on
    // the `from` leg, so the operator cannot move the frozen holder's tokens despite an unlimited allowance.
    function test_Row9_FrozenHolder_PreventedByFreeze() public {
        vm.prank(p1);
        t.approve(address(mop), type(uint256).max);

        vm.prank(security);
        t.emergencyRevoke(_a(p1));         // freeze: class -> NONE, balance kept
        assertEq(uint256(t.accountClassOf(p1)), uint256(G.AccountClass.NONE));
        assertEq(t.balanceOf(p1), SEED);   // balance unchanged (freeze, not confiscation)

        bool ok = mop.tryPull(p1, endpoint, 100 ether);
        assertFalse(ok);                   // reverted: from is now class NONE
        assertEq(t.balanceOf(p1), SEED);
    }

    // Small stateful assertion tying the model together: the outsider (class NONE) NEVER holds BINI, i.e.
    // the perimeter containment (row 5) is not merely incidental to one path.
    function test_Containment_OutsiderNeverReceives() public {
        vm.prank(p1);
        t.approve(address(mop), type(uint256).max);
        assertFalse(mop.tryPull(p1, outsider, SEED));
        assertEq(t.balanceOf(outsider), 0);
    }
}
