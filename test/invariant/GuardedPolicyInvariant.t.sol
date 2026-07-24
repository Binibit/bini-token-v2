// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BiniTokenV2Guarded as G} from "../../src/BiniTokenV2Guarded.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// Append-only upgrade target to exercise the UUPS path under invariant fuzzing (class preservation).
contract GuardedInvV2 is G {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// ECON-2 policy fuzz driver. Random sequences of: participant onboarding (Ops), sensitive-class
/// management (Timelock), operator approval (Timelock), emergency freeze (Security), guarded activation,
/// transfers among a fixed actor set, and authorized/unauthorized upgrades + PRIVILEGE-BYPASS attempts
/// (Ops trying to touch SYSTEM/CUSTODY/ENDPOINT/OPERATOR). All privilege bypasses MUST fail silently.
contract Handler is Test {
    G public t;
    address public timelock;
    address public ops;
    address public security;
    address public genesis; // actors[0], SYSTEM + BOOTSTRAP_OPERATOR + supply
    address public sysAcct; // pre-approved SYSTEM, NOT in the random pool — boundary/upgrade probe only
    address[] public actors;
    bool public everGuarded;

    constructor(G _t, address _timelock, address _ops, address _security, address[] memory _actors, address _sysAcct) {
        t = _t;
        timelock = _timelock;
        ops = _ops;
        security = _security;
        actors = _actors;
        genesis = _actors[0];
        sysAcct = _sysAcct;
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    function _a(address x) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = x;
    }

    function onboardParticipant(uint256 s) external {
        vm.prank(ops);
        try t.setParticipants(_a(_actor(s)), true) {} catch {}
    }

    // PRIVILEGE-BYPASS attempts — Ops has ONLY PARTICIPANT_MANAGER; every one must revert.
    function opsTrySystem(uint256 s) external {
        vm.prank(ops);
        try t.setSystemAccounts(_a(_actor(s)), true) {} catch {}
    }

    function opsTryEndpoint(uint256 s) external {
        vm.prank(ops);
        try t.setMarketEndpoints(_a(_actor(s)), true) {} catch {}
    }

    function opsTryOperator(uint256 s) external {
        vm.prank(ops);
        try t.setOperators(_a(_actor(s)), true) {} catch {}
    }

    // Ops attacking a live SYSTEM address — both directions must revert (boundary), leaving it SYSTEM.
    function opsTryRevokeSystem() external {
        vm.prank(ops);
        try t.setParticipants(_a(sysAcct), false) {} catch {}
    }

    function opsTryReclassSystem() external {
        vm.prank(ops);
        try t.setParticipants(_a(sysAcct), true) {} catch {}
    }

    function approveOperator(uint256 s) external {
        vm.prank(timelock);
        try t.setOperators(_a(_actor(s)), true) {} catch {}
    }

    function freeze(uint256 s) external {
        vm.prank(security);
        try t.emergencyRevoke(_a(_actor(s))) {} catch {}
    }

    function activate() external {
        vm.prank(timelock);
        try t.activateGuardedMode() {
            everGuarded = true;
        } catch {}
    }

    function transfer(uint256 fs, uint256 ts, uint256 amt) external {
        address from = _actor(fs);
        address to = _actor(ts);
        uint256 bal = t.balanceOf(from);
        if (bal == 0) return;
        amt = bound(amt, 0, bal);
        vm.prank(from);
        try t.transfer(to, amt) {} catch {}
    }

    function upgrade() external {
        GuardedInvV2 impl = new GuardedInvV2();
        vm.prank(timelock);
        try t.upgradeToAndCall(address(impl), "") {} catch {}
    }

    function actorList() external view returns (address[] memory) {
        return actors;
    }
}

contract GuardedPolicyInvariantTest is Test {
    G internal t;
    Handler internal h;
    address[] internal actors;

    address internal timelock = address(0x700);
    address internal ops = address(0x704);
    address internal security = address(0x701);
    address internal unpauser = address(0x702);
    address internal genesis = address(0x703);
    address internal sysAcct = address(0x5757);

    uint256 internal constant MAX = 1_000_000_000 ether;

    function setUp() public {
        G impl = new G();
        t = G(
            address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(G.initialize, (timelock, ops, security, genesis, uint48(3 days)))
                )
            )
        );

        vm.startPrank(timelock);
        t.setSystemAccounts(_a(genesis), true); // genesis is a SYSTEM sender for guarded transfers
        t.setSystemAccounts(_a(sysAcct), true); // pre-approved SYSTEM — boundary/upgrade preservation probe
        vm.stopPrank();

        actors.push(genesis); // 0
        actors.push(address(0xA11CE)); // 1
        actors.push(address(0xB0B)); // 2
        actors.push(address(0xCA401)); // 3

        h = new Handler(t, timelock, ops, security, actors, sysAcct);
        targetContract(address(h));
    }

    function _a(address x) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = x;
    }

    // --- P0.6: Ops role is confined forever ---
    function invariant_OpsNeverGainsSensitiveRoles() public view {
        assertFalse(t.hasRole(t.SYSTEM_MANAGER_ROLE(), ops));
        assertFalse(t.hasRole(t.CUSTODY_MANAGER_ROLE(), ops));
        assertFalse(t.hasRole(t.ENDPOINT_MANAGER_ROLE(), ops));
        assertFalse(t.hasRole(t.OPERATOR_MANAGER_ROLE(), ops));
    }

    // --- P0.1 + upgrade preservation: a live SYSTEM address stays SYSTEM under every Ops bypass attempt
    //     and across UUPS upgrades (never downgraded to PARTICIPANT/CUSTODY/ENDPOINT/NONE by a non-owner) ---
    function invariant_SystemAddrClassPreserved() public view {
        assertTrue(t.accountClassOf(sysAcct) == G.AccountClass.SYSTEM);
    }

    // --- P0.2: freeze is not confiscation — supply constant, tokens never leave the actor set ---
    function invariant_SupplyConstant() public view {
        assertEq(t.totalSupply(), MAX);
    }

    function invariant_BalanceConservation() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            sum += t.balanceOf(actors[i]);
        }
        assertEq(sum, MAX);
    }

    function invariant_CapNeverExceeded() public view {
        assertLe(t.totalSupply(), t.cap());
    }

    // --- mode one-way: once GUARDED, never returns to BOOTSTRAP ---
    function invariant_GuardedMonotonic() public view {
        if (h.everGuarded()) assertTrue(t.transferMode() == G.TransferMode.GUARDED);
    }
}
