// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BiniTokenV2} from "../src/BiniTokenV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// Append-only upgrade mock (no new storage) to exercise the UUPS path + state preservation.
contract BiniTokenV2MockV2 is BiniTokenV2 {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract BiniTokenV2Test is Test {
    BiniTokenV2 internal token;

    address internal timelock = address(0x700); // DEFAULT_ADMIN + UPGRADER + LAUNCH_MANAGER
    address internal pauser = address(0x701); // PAUSER
    address internal unpauser = address(0x702); // UNPAUSER
    address internal genesis = address(0x703); // BOOTSTRAP_OPERATOR + full supply
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint256 internal constant MAX = 1_000_000_000 ether;

    function setUp() public {
        BiniTokenV2 impl = new BiniTokenV2();
        bytes memory initData =
            abi.encodeCall(BiniTokenV2.initialize, (timelock, pauser, unpauser, genesis, uint48(3 days)));
        // Atomic deploy+init: init calldata passed to the proxy constructor (single tx).
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        token = BiniTokenV2(address(proxy));
    }

    // ---- metadata / supply / cap ----
    function test_Metadata() public view {
        assertEq(token.name(), "Binibit");
        assertEq(token.symbol(), "BINI");
        assertEq(token.decimals(), 18);
    }

    function test_SupplyAndCap() public view {
        assertEq(token.totalSupply(), MAX);
        assertEq(token.cap(), MAX);
        assertEq(token.balanceOf(genesis), MAX);
    }

    // ---- initializer / atomic init ----
    function test_ImplementationCannotInitialize() public {
        BiniTokenV2 impl = new BiniTokenV2();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(timelock, pauser, unpauser, genesis, uint48(3 days));
    }

    function test_ProxyCannotInitializeTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        token.initialize(timelock, pauser, unpauser, genesis, uint48(3 days));
    }

    function test_InitRejectsZeroAddress() public {
        BiniTokenV2 impl = new BiniTokenV2();
        bytes memory bad =
            abi.encodeCall(BiniTokenV2.initialize, (address(0), pauser, unpauser, genesis, uint48(3 days)));
        vm.expectRevert(BiniTokenV2.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), bad);
    }

    // ---- roles ----
    function test_Roles() public view {
        assertEq(token.defaultAdmin(), timelock);
        assertTrue(token.hasRole(token.UPGRADER_ROLE(), timelock));
        assertTrue(token.hasRole(token.LAUNCH_MANAGER_ROLE(), timelock));
        assertTrue(token.hasRole(token.PAUSER_ROLE(), pauser));
        assertTrue(token.hasRole(token.UNPAUSER_ROLE(), unpauser));
        assertTrue(token.hasRole(token.BOOTSTRAP_OPERATOR_ROLE(), genesis));
        // deployer (this test contract) holds nothing
        assertFalse(token.hasRole(token.UPGRADER_ROLE(), address(this)));
        assertFalse(token.hasRole(token.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    // ---- launch guard ----
    function test_PreLaunch_OperatorCanSend() public {
        vm.prank(genesis);
        token.transfer(alice, 100 ether);
        assertEq(token.balanceOf(alice), 100 ether);
    }

    function test_PreLaunch_NonOperatorCannotSend() public {
        vm.prank(genesis);
        token.transfer(alice, 100 ether); // seed alice (allowed: from=operator)
        vm.prank(alice);
        vm.expectRevert(BiniTokenV2.LaunchNotFinalized.selector);
        token.transfer(bob, 1 ether); // alice not operator, not finalized
    }

    function test_FinalizeLaunch_OpensTransfers() public {
        vm.prank(genesis);
        token.transfer(alice, 100 ether);
        vm.prank(timelock);
        token.finalizeLaunch();
        assertTrue(token.launchFinalized());
        vm.prank(alice);
        token.transfer(bob, 1 ether); // now allowed
        assertEq(token.balanceOf(bob), 1 ether);
    }

    function test_FinalizeLaunch_OnlyManager() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, token.LAUNCH_MANAGER_ROLE()
            )
        );
        vm.prank(alice);
        token.finalizeLaunch();
    }

    function test_FinalizeLaunch_Twice_Reverts() public {
        vm.startPrank(timelock);
        token.finalizeLaunch();
        vm.expectRevert(BiniTokenV2.LaunchAlreadyFinalized.selector);
        token.finalizeLaunch();
        vm.stopPrank();
    }

    // ---- pause split ----
    function test_Pause_BlocksTransfer_ButNotApprove() public {
        vm.prank(timelock);
        token.finalizeLaunch();
        vm.prank(genesis);
        token.transfer(alice, 100 ether);

        vm.prank(pauser);
        token.pause();

        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        token.transfer(bob, 1 ether);

        // approve stays live while paused
        vm.prank(alice);
        token.approve(bob, 5 ether);
        assertEq(token.allowance(alice, bob), 5 ether);
    }

    function test_PauserCannotUnpause() public {
        vm.prank(pauser);
        token.pause();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, pauser, token.UNPAUSER_ROLE()
            )
        );
        vm.prank(pauser);
        token.unpause();
    }

    function test_UnpauserUnpauses() public {
        vm.prank(pauser);
        token.pause();
        vm.prank(unpauser);
        token.unpause();
        assertFalse(token.paused());
    }

    // ---- permit (live pre-launch and while paused) ----
    function test_Permit() public {
        uint256 pk = 0xA11CE5EED;
        address owner = vm.addr(pk);
        uint256 deadline = block.timestamp + 1 days;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                bob,
                42 ether,
                token.nonces(owner),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        token.permit(owner, bob, 42 ether, deadline, v, r, s); // pre-launch: approve path, not _update
        assertEq(token.allowance(owner, bob), 42 ether);
        assertEq(token.nonces(owner), 1);
    }

    // ---- upgrade ----
    function test_Upgrade_OnlyUpgrader_PreservesState() public {
        vm.prank(genesis);
        token.transfer(alice, 123 ether);

        BiniTokenV2MockV2 newImpl = new BiniTokenV2MockV2();
        vm.prank(timelock);
        token.upgradeToAndCall(address(newImpl), "");

        assertEq(BiniTokenV2MockV2(address(token)).version(), 2);
        assertEq(token.totalSupply(), MAX);
        assertEq(token.balanceOf(alice), 123 ether);
        assertTrue(token.hasRole(token.UPGRADER_ROLE(), timelock));
    }

    function test_Upgrade_Unauthorized_Reverts() public {
        BiniTokenV2MockV2 newImpl = new BiniTokenV2MockV2();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, token.UPGRADER_ROLE()
            )
        );
        vm.prank(alice);
        token.upgradeToAndCall(address(newImpl), "");
    }

    function test_Upgrade_ZeroImpl_Reverts() public {
        vm.prank(timelock);
        vm.expectRevert(BiniTokenV2.ZeroAddress.selector);
        token.upgradeToAndCall(address(0), "");
    }

    // ---- ERC-7201 storage slot: real, non-zero, and used ----
    function test_StorageSlotIsRealAndUsed() public {
        bytes32 expected =
            keccak256(abi.encode(uint256(keccak256("binibit.storage.BiniTokenV2")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(expected, 0xb919b0c0062827d20ad4293e3018837a27a74d3431061c198bdaffa48b665b00);
        assertTrue(expected != bytes32(0));
        vm.prank(timelock);
        token.finalizeLaunch();
        // launchFinalized (a bool = true) must live at the computed ERC-7201 slot, not slot 0.
        assertEq(vm.load(address(token), expected), bytes32(uint256(1)));
        assertEq(vm.load(address(token), bytes32(0)), bytes32(0)); // slot 0 untouched
    }

    // ---- no runtime mint: fuzz that supply is constant under transfers ----
    function testFuzz_SupplyConstantUnderTransfer(uint96 amt) public {
        vm.prank(timelock);
        token.finalizeLaunch();
        uint256 a = bound(uint256(amt), 0, MAX);
        vm.prank(genesis);
        token.transfer(alice, a);
        assertEq(token.totalSupply(), MAX);
        assertEq(token.balanceOf(genesis) + token.balanceOf(alice), MAX);
    }
}
