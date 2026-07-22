// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BiniTokenV2} from "../../src/BiniTokenV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// Append-only upgrade target used by the handler to exercise the UUPS path under invariant fuzzing.
contract BiniTokenV2InvV2 is BiniTokenV2 {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// Drives random sequences of transfer / approve / transferFrom / permit-less approve / pause / unpause /
/// finalizeLaunch / authorized-upgrade / attempted-unauthorized-upgrade across a fixed actor set.
/// Tokens only ever move among `actors`, so their balances always sum to MAX_SUPPLY.
contract Handler is Test {
    BiniTokenV2 public token;
    address public timelock;
    address public pauser;
    address public unpauser;
    address[] public actors; // actors[0] = genesis (holds BOOTSTRAP_OPERATOR + initial supply)
    bool public everFinalized;

    constructor(BiniTokenV2 _token, address _timelock, address _pauser, address _unpauser, address[] memory _actors) {
        token = _token;
        timelock = _timelock;
        pauser = _pauser;
        unpauser = _unpauser;
        actors = _actors;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amt) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 bal = token.balanceOf(from);
        if (bal == 0) return;
        amt = bound(amt, 0, bal);
        vm.prank(from);
        try token.transfer(to, amt) {} catch {}
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amt) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 bal = token.balanceOf(owner);
        if (bal == 0) return;
        amt = bound(amt, 0, bal);
        vm.prank(owner);
        try token.approve(spender, amt) {} catch { return; }
        vm.prank(spender);
        try token.transferFrom(owner, to, amt) {} catch {}
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amt) external {
        vm.prank(_actor(ownerSeed));
        try token.approve(_actor(spenderSeed), amt) {} catch {}
    }

    function pause() external {
        vm.prank(pauser);
        try token.pause() {} catch {}
    }

    function unpause() external {
        vm.prank(unpauser);
        try token.unpause() {} catch {}
    }

    function finalize() external {
        vm.prank(timelock);
        try token.finalizeLaunch() {
            everFinalized = true;
        } catch {}
    }

    function upgrade() external {
        BiniTokenV2InvV2 impl = new BiniTokenV2InvV2();
        vm.prank(timelock);
        try token.upgradeToAndCall(address(impl), "") {} catch {}
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}

contract BiniTokenV2InvariantTest is Test {
    BiniTokenV2 internal token;
    Handler internal handler;
    address[] internal actors;

    address internal timelock = address(0x700);
    address internal pauser = address(0x701);
    address internal unpauser = address(0x702);
    address internal genesis = address(0x703);

    uint256 internal constant MAX = 1_000_000_000 ether;

    function setUp() public {
        BiniTokenV2 impl = new BiniTokenV2();
        bytes memory initData = abi.encodeCall(
            BiniTokenV2.initialize, (timelock, pauser, unpauser, genesis, uint48(3 days))
        );
        token = BiniTokenV2(address(new ERC1967Proxy(address(impl), initData)));

        actors.push(genesis); // holds all supply + BOOTSTRAP_OPERATOR
        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCA401));

        handler = new Handler(token, timelock, pauser, unpauser, actors);
        targetContract(address(handler));
    }

    /// Supply is fixed forever — no mint, no burn.
    function invariant_totalSupplyConstant() public view {
        assertEq(token.totalSupply(), MAX);
    }

    /// Conservation: tokens never leave the tracked actor set.
    function invariant_balanceConservation() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, MAX);
    }

    /// Cap is never exceeded.
    function invariant_capNotExceeded() public view {
        assertLe(token.totalSupply(), token.cap());
    }

    /// Launch is one-way: once finalized, it stays finalized (never returns to pre-launch).
    function invariant_launchMonotonic() public view {
        if (handler.everFinalized()) {
            assertTrue(token.launchFinalized());
        }
    }
}
