// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BiniMigrationVault} from "../src/BiniMigrationVault.sol";
import {BiniTokenV2} from "../src/BiniTokenV2.sol";
import {ActorContract} from "./mocks/MarketMocks.sol";
import {FeeOnTransferToken, MockToken, RevertingTransferFromToken} from "./mocks/MockTokens.sol";

contract BiniMigrationVaultTest is Test {
    uint256 internal constant HOLDER_KEY = 0xA11CE;
    uint256 internal constant V1_AMOUNT = 125_500_000_000_000;

    address internal holder;
    address internal recipient = address(0xB0B);
    address internal timelock;
    address internal genesis;
    MockToken internal v1;
    BiniTokenV2 internal v2;
    BiniMigrationVault internal vault;

    function setUp() public {
        holder = vm.addr(HOLDER_KEY);
        timelock = address(new ActorContract());
        genesis = address(new ActorContract());
        address pauser = address(new ActorContract());
        v1 = new MockToken("BINI V1", "BINI1", 12);

        BiniTokenV2 implementation = new BiniTokenV2();
        v2 = BiniTokenV2(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(BiniTokenV2.initialize, (timelock, pauser, genesis, uint48(2 days)))
                )
            )
        );
        vault = new BiniMigrationVault(address(v1), address(v2), timelock);
        v1.mint(holder, V1_AMOUNT);
    }

    function test_ExactConversionAndMigrationReconciliation() public {
        _configureAndFund(vault, v1, V1_AMOUNT);

        vm.prank(holder);
        v1.approve(address(vault), V1_AMOUNT);
        vm.prank(holder);
        uint256 released = vault.migrate(holder, V1_AMOUNT, holder, 0, "");

        assertEq(released, V1_AMOUNT * 1_000_000);
        assertEq(v1.balanceOf(address(vault)), V1_AMOUNT);
        assertEq(v2.balanceOf(holder), released);
        assertEq(vault.totalLockedV1(), V1_AMOUNT);
        assertEq(vault.totalReleasedV2(), released);
        assertEq(vault.remainingV2Liability(), 0);
        assertTrue(vault.completedActions(keccak256("holder-1")));
    }

    function test_InsufficientReservePreventsSealing() public {
        address[] memory holders = _singleAddress(holder);
        uint256[] memory amounts = _singleUint(V1_AMOUNT);
        bytes32[] memory ids = _singleBytes32(keccak256("holder-1"));
        vm.prank(timelock);
        vault.setEntitlements(holders, amounts, ids);

        vm.expectRevert(
            abi.encodeWithSelector(BiniMigrationVault.InsufficientMigrationReserve.selector, V1_AMOUNT * 1_000_000, 0)
        );
        vm.prank(timelock);
        vault.sealEntitlements();
    }

    function test_InsufficientAllowancePreventsV2Release() public {
        _configureAndFund(vault, v1, V1_AMOUNT);

        vm.expectRevert();
        vault.migrate(holder, V1_AMOUNT, holder, 0, "");

        assertEq(v2.balanceOf(holder), 0);
        assertEq(vault.totalReleasedV2(), 0);
        assertEq(vault.migratedV1(holder), 0);
    }

    function test_V1LockFailureAtomicallyPreventsV2Release() public {
        RevertingTransferFromToken brokenV1 = new RevertingTransferFromToken();
        BiniMigrationVault brokenVault = new BiniMigrationVault(address(brokenV1), address(v2), timelock);
        brokenV1.mint(holder, V1_AMOUNT);
        _configureAndFund(brokenVault, brokenV1, V1_AMOUNT);
        vm.prank(holder);
        brokenV1.approve(address(brokenVault), V1_AMOUNT);

        vm.expectRevert(bytes("LOCK_FAILED"));
        brokenVault.migrate(holder, V1_AMOUNT, holder, 0, "");

        assertEq(v2.balanceOf(holder), 0);
        assertEq(brokenVault.migratedV1(holder), 0);
    }

    function test_ReplacementRecipientRequiresValidHolderSignature() public {
        _configureAndFund(vault, v1, V1_AMOUNT);
        vm.prank(holder);
        v1.approve(address(vault), V1_AMOUNT);
        uint256 deadline = block.timestamp + 1 days;

        vm.expectRevert(
            abi.encodeWithSelector(BiniMigrationVault.InvalidRecipientAuthorization.selector, holder, recipient)
        );
        vault.migrate(holder, V1_AMOUNT, recipient, deadline, "");

        bytes32 digest = vault.recipientAuthorizationDigest(holder, recipient, V1_AMOUNT, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(HOLDER_KEY, digest);
        vault.migrate(holder, V1_AMOUNT, recipient, deadline, abi.encodePacked(r, s, v));
        assertEq(v2.balanceOf(recipient), V1_AMOUNT * 1_000_000);
    }

    function test_CompletedHolderCannotMigrateTwice() public {
        _configureAndFund(vault, v1, V1_AMOUNT);
        vm.startPrank(holder);
        v1.approve(address(vault), V1_AMOUNT);
        vault.migrate(holder, V1_AMOUNT, holder, 0, "");
        vm.expectRevert(abi.encodeWithSelector(BiniMigrationVault.MigrationAlreadyCompleted.selector, holder));
        vault.migrate(holder, V1_AMOUNT, holder, 0, "");
        vm.stopPrank();
    }

    function test_DuplicateHolderAndActionAreRejected() public {
        vm.prank(timelock);
        vault.setEntitlements(_singleAddress(holder), _singleUint(V1_AMOUNT), _singleBytes32(keccak256("one")));

        vm.expectRevert(abi.encodeWithSelector(BiniMigrationVault.EntitlementAlreadyConfigured.selector, holder));
        vm.prank(timelock);
        vault.setEntitlements(_singleAddress(holder), _singleUint(V1_AMOUNT), _singleBytes32(keccak256("two")));

        address second = address(0xCAFE);
        vm.expectRevert(abi.encodeWithSelector(BiniMigrationVault.DuplicateAction.selector, keccak256("one")));
        vm.prank(timelock);
        vault.setEntitlements(_singleAddress(second), _singleUint(V1_AMOUNT), _singleBytes32(keccak256("one")));
    }

    function test_EntitlementBatchIsBounded() public {
        address[] memory holders = new address[](21);
        uint256[] memory amounts = new uint256[](21);
        bytes32[] memory ids = new bytes32[](21);
        for (uint256 i; i < 21; ++i) {
            holders[i] = address(uint160(i + 1));
            amounts[i] = 1;
            ids[i] = bytes32(i + 1);
        }
        vm.expectRevert(abi.encodeWithSelector(BiniMigrationVault.EntitlementBatchTooLarge.selector, 21, 20));
        vm.prank(timelock);
        vault.setEntitlements(holders, amounts, ids);
    }

    function test_ConstructorRejectsInvalidAddressesContractsAndDecimals() public {
        vm.expectRevert(BiniMigrationVault.ZeroAddress.selector);
        new BiniMigrationVault(address(0), address(v2), timelock);

        vm.expectRevert(abi.encodeWithSelector(BiniMigrationVault.NotContract.selector, address(0xBAD)));
        new BiniMigrationVault(address(0xBAD), address(v2), timelock);

        MockToken wrongV1 = new MockToken("Wrong", "WRONG", 18);
        vm.expectRevert(abi.encodeWithSelector(BiniMigrationVault.InvalidDecimals.selector, 18, 18));
        new BiniMigrationVault(address(wrongV1), address(v2), timelock);

        MockToken wrongV2 = new MockToken("Wrong", "WRONG", 12);
        vm.expectRevert(abi.encodeWithSelector(BiniMigrationVault.InvalidDecimals.selector, 12, 12));
        new BiniMigrationVault(address(v1), address(wrongV2), timelock);
    }

    function test_EntitlementValidationAndSealingAreIrreversible() public {
        vm.expectRevert(BiniMigrationVault.InvalidArrayLength.selector);
        vm.prank(timelock);
        vault.setEntitlements(new address[](0), new uint256[](0), new bytes32[](0));

        vm.expectRevert(abi.encodeWithSelector(BiniMigrationVault.InvalidEntitlement.selector, address(0), 1));
        vm.prank(timelock);
        vault.setEntitlements(_singleAddress(address(0)), _singleUint(1), _singleBytes32(bytes32(uint256(1))));

        vm.expectRevert(abi.encodeWithSelector(BiniMigrationVault.InvalidEntitlement.selector, holder, 0));
        vm.prank(timelock);
        vault.setEntitlements(_singleAddress(holder), _singleUint(0), _singleBytes32(bytes32(uint256(1))));

        _configureAndFund(vault, v1, V1_AMOUNT);
        vm.expectRevert(BiniMigrationVault.EntitlementsAlreadySealed.selector);
        vm.prank(timelock);
        vault.sealEntitlements();
        vm.expectRevert(BiniMigrationVault.EntitlementsAlreadySealed.selector);
        vm.prank(timelock);
        vault.setEntitlements(_singleAddress(recipient), _singleUint(1), _singleBytes32(bytes32(uint256(2))));
    }

    function test_MigrationRejectsUnsealedZeroWrongAmountAndExpiredAuthorization() public {
        vm.expectRevert(BiniMigrationVault.EntitlementsNotSealed.selector);
        vault.migrate(holder, V1_AMOUNT, holder, 0, "");

        _configureAndFund(vault, v1, V1_AMOUNT);
        vm.expectRevert(BiniMigrationVault.ZeroAddress.selector);
        vault.migrate(address(0), V1_AMOUNT, holder, 0, "");
        vm.expectRevert(
            abi.encodeWithSelector(BiniMigrationVault.AmountDoesNotMatchEntitlement.selector, V1_AMOUNT, V1_AMOUNT - 1)
        );
        vault.migrate(holder, V1_AMOUNT - 1, holder, 0, "");
        vm.expectRevert(abi.encodeWithSelector(BiniMigrationVault.AuthorizationExpired.selector, 0));
        vault.migrate(holder, V1_AMOUNT, recipient, 0, "");
    }

    function test_FeeOnTransferV1AndV2AreRejectedAtomically() public {
        FeeOnTransferToken feeV1 = new FeeOnTransferToken("BINI V1", "BINI1", 12);
        BiniMigrationVault feeV1Vault = new BiniMigrationVault(address(feeV1), address(v2), timelock);
        feeV1.mint(holder, V1_AMOUNT);
        _configureAndFund(feeV1Vault, v1, V1_AMOUNT);
        vm.prank(holder);
        feeV1.approve(address(feeV1Vault), V1_AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(BiniMigrationVault.InexactV1Lock.selector, V1_AMOUNT, V1_AMOUNT - 1));
        feeV1Vault.migrate(holder, V1_AMOUNT, holder, 0, "");
        assertEq(feeV1Vault.totalReleasedV2(), 0);

        FeeOnTransferToken feeV2 = new FeeOnTransferToken("BINI V2", "BINI2", 18);
        BiniMigrationVault feeV2Vault = new BiniMigrationVault(address(v1), address(feeV2), timelock);
        feeV2.mint(address(feeV2Vault), V1_AMOUNT * 1_000_000);
        vm.prank(timelock);
        feeV2Vault.setEntitlements(_singleAddress(holder), _singleUint(V1_AMOUNT), _singleBytes32(bytes32(uint256(3))));
        vm.prank(timelock);
        feeV2Vault.sealEntitlements();
        vm.prank(holder);
        v1.approve(address(feeV2Vault), V1_AMOUNT);
        vm.expectRevert(
            abi.encodeWithSelector(
                BiniMigrationVault.InexactV2Release.selector, V1_AMOUNT * 1_000_000, V1_AMOUNT * 1_000_000 - 1
            )
        );
        feeV2Vault.migrate(holder, V1_AMOUNT, holder, 0, "");
        assertEq(v1.balanceOf(address(feeV2Vault)), 0);
    }

    function _configureAndFund(BiniMigrationVault targetVault, MockToken, uint256 amount) private {
        uint256 reserve = amount * 1_000_000;
        vm.prank(genesis);
        v2.transfer(address(targetVault), reserve);
        vm.prank(timelock);
        targetVault.setEntitlements(_singleAddress(holder), _singleUint(amount), _singleBytes32(keccak256("holder-1")));
        vm.prank(timelock);
        targetVault.sealEntitlements();
    }

    function _singleAddress(address value) private pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = value;
    }

    function _singleUint(uint256 value) private pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = value;
    }

    function _singleBytes32(bytes32 value) private pure returns (bytes32[] memory values) {
        values = new bytes32[](1);
        values[0] = value;
    }
}
