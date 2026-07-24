// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BiniTokenV2Guarded as G} from "../../src/BiniTokenV2Guarded.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract AdvInvV2 is G {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// A HOSTILE contract that a COMPROMISED Operations Safe has approved as a PARTICIPANT (the accepted trust
/// risk: the token cannot tell a contract/pool from a user). It continuously tries to exfiltrate BINI to an
/// address OUTSIDE the perimeter. The point: even a malicious in-perimeter contract is CONTAINED — it can
/// never move BINI to a non-approved address.
contract MaliciousParticipant {
    G public t;

    constructor(G _t) {
        t = _t;
    }

    function exfil(address to, uint256 amt) external {
        try t.transfer(to, amt) {} catch {}
    }

    function exfilFrom(address from, address to, uint256 amt) external {
        try t.transferFrom(from, to, amt) {} catch {}
    }
}

/// ECON-2.2 Agent 6 — adversarial authorization harness. Models COMPROMISED Ops + Security safes, a hostile
/// approved participant contract, operator abuse, freeze/restore races, and UUPS upgrade. Asserts the
/// properties that hold EVEN UNDER full adversarial control of Ops+Security. It does NOT claim the contract
/// can detect an address's economic nature — a compromised Ops CAN approve a malicious contract; what it
/// cannot do is breach supply, escalate class, or leak BINI outside the perimeter. See doc 10 for the
/// PREVENTED / MITIGATED / ACCEPTED classification.
contract Handler is Test {
    G public t;
    address public timelock;
    address public ops; // COMPROMISED in this model
    address public security; // COMPROMISED in this model
    address public genesis;
    MaliciousParticipant public m;
    address public outsider; // NEVER approved by anyone — the "unknown pool" analogue
    address[] public tracked; // conservation set: genesis, p1, p2, address(m), outsider
    bool public everGuarded = true;

    constructor(
        G _t,
        address _timelock,
        address _ops,
        address _security,
        address _genesis,
        MaliciousParticipant _m,
        address _outsider,
        address[] memory _tracked
    ) {
        t = _t;
        timelock = _timelock;
        ops = _ops;
        security = _security;
        genesis = _genesis;
        m = _m;
        outsider = _outsider;
        tracked = _tracked;
    }

    function _pick(uint256 s) internal view returns (address) {
        return tracked[s % tracked.length];
    }

    function _a(address x) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = x;
    }

    // hostile approved contract tries to push BINI out of the perimeter
    function malExfil(uint256 amt) external {
        m.exfil(outsider, bound(amt, 0, t.balanceOf(address(m))));
    }

    // compromised Ops approves an arbitrary NEW contract as participant (accepted risk — must SUCCEED, but the
    // new address is untracked so we never route BINI to it; we only assert it cannot gain a sensitive class)
    function opsApproveArbitrary(uint256 s) external {
        vm.prank(ops);
        try t.setParticipants(_a(address(uint160(0xDEAD0000 + (s % 512)))), true) {} catch {}
    }

    // compromised Ops tries to ESCALATE the malicious contract to SYSTEM (must always fail)
    function opsTryEscalateM() external {
        vm.prank(ops);
        try t.setSystemAccounts(_a(address(m)), true) {} catch {}
    }

    // compromised Security freezes a random tracked actor, then maybe Ops restores it
    function securityFreeze(uint256 s) external {
        vm.prank(security);
        try t.emergencyRevoke(_a(_pick(s))) {} catch {}
    }

    function opsRestore(uint256 s) external {
        address a = _pick(s);
        if (a == genesis || a == outsider) return;
        vm.prank(ops);
        try t.setParticipants(_a(a), true) {} catch {}
    }

    // normal-ish perimeter transfers among tracked (approved) actors
    function transfer(uint256 fs, uint256 ts, uint256 amt) external {
        address from = _pick(fs);
        address to = _pick(ts);
        uint256 bal = t.balanceOf(from);
        if (bal == 0) return;
        vm.prank(from);
        try t.transfer(to, bound(amt, 0, bal)) {} catch {}
    }

    function upgrade() external {
        AdvInvV2 impl = new AdvInvV2();
        vm.prank(timelock);
        try t.upgradeToAndCall(address(impl), "") {} catch {}
    }
}

contract AdversarialAuthzInvariantTest is Test {
    G internal t;
    Handler internal h;
    MaliciousParticipant internal m;
    address[] internal tracked;

    address internal timelock = address(0x700);
    address internal ops = address(0x704);
    address internal security = address(0x701);
    address internal genesis = address(0x703);
    address internal p1 = address(0xA11CE);
    address internal p2 = address(0xB0B);
    address internal outsider = address(0x0FF5); // never approved

    uint256 internal constant MAX = 1_000_000_000 ether;

    function _a(address x) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = x;
    }

    function setUp() public {
        G impl = new G();
        t = G(
            address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(G.initialize, (timelock, ops, security, genesis, uint48(3 days)))
                )
            )
        );
        m = new MaliciousParticipant(t);

        vm.prank(timelock);
        t.setSystemAccounts(_a(genesis), true);
        // COMPROMISED Ops approves p1, p2, and the MALICIOUS CONTRACT as participants (accepted risk)
        vm.startPrank(ops);
        t.setParticipants(_a(p1), true);
        t.setParticipants(_a(p2), true);
        t.setParticipants(_a(address(m)), true);
        vm.stopPrank();
        // seed everyone while BOOTSTRAP (all approved recipients)
        vm.startPrank(genesis);
        t.transfer(p1, 100_000 ether);
        t.transfer(p2, 100_000 ether);
        t.transfer(address(m), 100_000 ether);
        vm.stopPrank();
        vm.prank(timelock);
        t.activateGuardedMode();

        tracked = [genesis, p1, p2, address(m), outsider];
        h = new Handler(t, timelock, ops, security, genesis, m, outsider, tracked);
        targetContract(address(h));
    }

    /// Supply is inviolable even with Ops+Security fully compromised.
    function invariant_SupplyConstant() public view {
        assertEq(t.totalSupply(), MAX);
    }

    /// No BINI leaves the tracked set — a hostile approved contract cannot mint/burn/leak.
    function invariant_Conservation() public view {
        uint256 sum;
        for (uint256 i; i < tracked.length; ++i) {
            sum += t.balanceOf(tracked[i]);
        }
        assertEq(sum, MAX);
    }

    /// PERIMETER CONTAINMENT: a never-approved outside address can NEVER receive real BINI, even though a
    /// compromised Ops approved a malicious contract that keeps trying to send to it.
    function invariant_OutsiderNeverReceives() public view {
        assertEq(t.balanceOf(outsider), 0);
    }

    /// The malicious contract, approved only as PARTICIPANT, can never be escalated by a compromised Ops.
    function invariant_MaliciousNeverEscalated() public view {
        G.AccountClass c = t.accountClassOf(address(m));
        assertTrue(c == G.AccountClass.PARTICIPANT || c == G.AccountClass.NONE);
    }

    function invariant_GuardedMonotonic() public view {
        assertTrue(t.transferMode() == G.TransferMode.GUARDED);
    }
}
