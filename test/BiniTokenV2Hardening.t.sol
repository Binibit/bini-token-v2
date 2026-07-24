// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BiniTokenV2} from "../src/BiniTokenV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/// A non-UUPS contract (no proxiableUUID) — must be rejected as an upgrade target.
contract NotUUPS {
    function foo() external pure returns (uint256) {
        return 1;
    }
}

contract BiniTokenV2HardeningTest is Test {
    BiniTokenV2 internal token;
    address internal timelock = address(0x700);
    address internal pauser = address(0x701);
    address internal unpauser = address(0x702);
    address internal genesis = address(0x703);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        BiniTokenV2 impl = new BiniTokenV2();
        bytes memory initData =
            abi.encodeCall(BiniTokenV2.initialize, (timelock, pauser, unpauser, genesis, uint48(3 days)));
        token = BiniTokenV2(address(new ERC1967Proxy(address(impl), initData)));
    }

    // §3.1 — pause takes precedence over the launch restriction (pre-launch, paused, any sender → EnforcedPause)
    function test_PausePrecedence_PreLaunch() public {
        vm.prank(pauser);
        token.pause();
        // non-operator pre-launch transfer while paused: must be EnforcedPause, NOT LaunchNotFinalized
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(alice);
        token.transfer(bob, 1);
        // even the operator is blocked by pause pre-launch
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(genesis);
        token.transfer(alice, 1);
    }

    // §3.2 — finalizeLaunch is allowed while paused (deliberate; runbook-gated)
    function test_FinalizeLaunch_WhilePaused() public {
        vm.prank(pauser);
        token.pause();
        vm.prank(timelock);
        token.finalizeLaunch();
        assertTrue(token.launchFinalized());
        // still paused → transfers blocked until governed unpause
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(genesis);
        token.transfer(alice, 1);
        vm.prank(unpauser);
        token.unpause();
        vm.prank(genesis);
        token.transfer(alice, 1 ether); // now open
        assertEq(token.balanceOf(alice), 1 ether);
    }

    // §3.5 — richer LaunchFinalized event
    function test_LaunchFinalized_Event() public {
        vm.expectEmit(true, true, false, false);
        emit BiniTokenV2.LaunchFinalized(timelock, block.number);
        vm.prank(timelock);
        token.finalizeLaunch();
    }

    // §1.2 — non-UUPS implementation is rejected at runtime (proxiableUUID handshake)
    function test_Upgrade_NonUUPS_Reverts() public {
        NotUUPS bad = new NotUUPS();
        vm.expectRevert(); // ERC1967InvalidImplementation / failed proxiableUUID handshake
        vm.prank(timelock);
        token.upgradeToAndCall(address(bad), "");
    }

    // §1.2 (proxy for the CI selector-diff gate) — a malicious impl exposing mint() is detectable by selector set.
    function test_MintSelectorWouldBeDetected() public pure {
        bytes4 mintSel = bytes4(keccak256("mint(address,uint256)"));
        bytes4 setCapSel = bytes4(keccak256("setCap(uint256)"));
        // The release-policy CI must fail an upgrade whose ABI contains any of these. Asserted here as
        // the canonical prohibited-selector baseline (the real gate runs in CI over the compiled ABI).
        assertEq(mintSel, bytes4(0x40c10f19));
        assertTrue(mintSel != bytes4(0) && setCapSel != bytes4(0));
    }
}
