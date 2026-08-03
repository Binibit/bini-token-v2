// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Safe} from "safe-smart-account/contracts/Safe.sol";
import {Enum} from "safe-smart-account/contracts/common/Enum.sol";
import {SafeProxy} from "safe-smart-account/contracts/proxies/SafeProxy.sol";
import {SafeProxyFactory} from "safe-smart-account/contracts/proxies/SafeProxyFactory.sol";
import {MultiSend} from "safe-smart-account/contracts/libraries/MultiSend.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BiniMigrationVault} from "../../src/BiniMigrationVault.sol";
import {BiniTokenV2} from "../../src/BiniTokenV2.sol";
import {BiniV1TestFixture} from "../../src/fixtures/BiniV1TestFixture.sol";

contract RC3RealSafeLifecycleTest is Test {
    uint256 internal constant DELAY = 600;
    uint256 internal constant OWNER_PK_1 = 0xA11CE;
    uint256 internal constant OWNER_PK_2 = 0xB0B;
    uint256 internal constant OWNER_PK_3 = 0xCAFE;

    Safe internal singleton;
    SafeProxyFactory internal factory;
    MultiSend internal multiSend;
    Safe[12] internal safes;
    address[3] internal owners;
    uint256[3] internal ownerKeys;
    TimelockController internal timelock;
    BiniTokenV2 internal token;

    function setUp() external {
        _sortOwnersAndKeys();
        singleton = new Safe();
        factory = new SafeProxyFactory();
        multiSend = new MultiSend();
        bytes memory initializer = abi.encodeCall(
            Safe.setup, (_owners(), 2, address(0), bytes(""), address(0), address(0), 0, payable(address(0)))
        );
        for (uint256 i = 0; i < safes.length; ++i) {
            SafeProxy proxy = factory.createChainSpecificProxyWithNonce(address(singleton), initializer, 3_000_000 + i);
            safes[i] = Safe(payable(address(proxy)));
        }

        address[] memory noProposers = new address[](0);
        address[] memory executors = new address[](1);
        executors[0] = address(safes[0]);
        timelock = new TimelockController(DELAY, noProposers, executors, address(this));
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(safes[0]));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(safes[1]));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), address(this));

        BiniTokenV2 implementation = new BiniTokenV2();
        token = BiniTokenV2(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        BiniTokenV2.initialize, (address(timelock), address(safes[1]), address(safes[2]), uint48(DELAY))
                    )
                )
            )
        );
    }

    function test_RealSafeTopologyAndFullGovernanceLifecycle() external {
        for (uint256 i = 0; i < safes.length; ++i) {
            assertEq(safes[i].VERSION(), "1.4.1");
            assertEq(safes[i].getThreshold(), 2);
            assertEq(safes[i].getOwners(), _owners());
            (address[] memory modules, address next) = safes[i].getModulesPaginated(address(0x1), 10);
            assertEq(modules.length, 0);
            assertEq(next, address(0x1));
            for (uint256 j = i + 1; j < safes.length; ++j) {
                assertNotEq(address(safes[i]), address(safes[j]));
            }
        }
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(safes[0])));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(safes[0])));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), address(safes[1])));
        assertFalse(timelock.hasRole(timelock.CANCELLER_ROLE(), address(safes[0])));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(this)));

        _executeNineTransferDistribution();
        _rehearseCancelAndDelay();
        _rehearsePauseAndDelayedUnpause();
        _rehearseFiveHolderMigration();
        _rehearseOpenMarket();
    }

    function _executeNineTransferDistribution() internal {
        uint256[9] memory amounts = [
            uint256(210_000_000 ether),
            180_000_000 ether,
            120_000_000 ether,
            90_000_000 ether,
            150_000_000 ether,
            5_000_000 ether,
            95_000_000 ether,
            100_000_000 ether,
            50_000_000 ether
        ];
        bytes memory transactions;
        for (uint256 i = 0; i < 9; ++i) {
            bytes memory data = abi.encodeCall(token.transfer, (address(safes[i + 3]), amounts[i]));
            transactions =
                bytes.concat(transactions, abi.encodePacked(uint8(0), address(token), uint256(0), data.length, data));
        }
        bytes memory multiSendCall = abi.encodeCall(MultiSend.multiSend, (transactions));
        vm.recordLogs();
        _safeExec(safes[2], address(multiSend), 0, multiSendCall, Enum.Operation.DelegateCall);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 transferTopic = keccak256("Transfer(address,address,uint256)");
        uint256 transferCount;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(token) && logs[i].topics[0] == transferTopic) ++transferCount;
        }
        assertEq(transferCount, 9);
        assertEq(token.balanceOf(address(safes[2])), 0);
        for (uint256 i = 0; i < 9; ++i) {
            assertEq(token.balanceOf(address(safes[i + 3])), amounts[i]);
        }
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertFalse(token.marketOpen());
    }

    function _rehearseCancelAndDelay() internal {
        bytes memory callData = abi.encodeCall(token.setMarketInfrastructure, (_oneAddress(address(multiSend)), true));
        bytes32 salt = keccak256("RC3-CANCEL");
        bytes32 operationId = timelock.hashOperation(address(token), 0, callData, bytes32(0), salt);
        _safeExec(
            safes[0],
            address(timelock),
            0,
            abi.encodeCall(timelock.schedule, (address(token), 0, callData, bytes32(0), salt, DELAY)),
            Enum.Operation.Call
        );
        assertTrue(timelock.isOperationPending(operationId));
        _safeExec(safes[1], address(timelock), 0, abi.encodeCall(timelock.cancel, (operationId)), Enum.Operation.Call);
        assertFalse(timelock.isOperation(operationId));

        salt = keccak256("RC3-RESCHEDULE");
        operationId = timelock.hashOperation(address(token), 0, callData, bytes32(0), salt);
        _safeExec(
            safes[0],
            address(timelock),
            0,
            abi.encodeCall(timelock.schedule, (address(token), 0, callData, bytes32(0), salt, DELAY)),
            Enum.Operation.Call
        );
        bytes memory executeCall = abi.encodeCall(timelock.execute, (address(token), 0, callData, bytes32(0), salt));
        _safeExecExpectRevert(safes[0], address(timelock), executeCall);
        vm.warp(block.timestamp + DELAY);
        _safeExec(safes[0], address(timelock), 0, executeCall, Enum.Operation.Call);
        assertTrue(timelock.isOperationDone(operationId));
    }

    function _rehearsePauseAndDelayedUnpause() internal {
        _safeExec(safes[1], address(token), 0, abi.encodeCall(token.pause, ()), Enum.Operation.Call);
        assertTrue(token.paused());
        bytes memory callData = abi.encodeCall(token.unpause, ());
        bytes32 salt = keccak256("RC3-UNPAUSE");
        _safeExec(
            safes[0],
            address(timelock),
            0,
            abi.encodeCall(timelock.schedule, (address(token), 0, callData, bytes32(0), salt, DELAY)),
            Enum.Operation.Call
        );
        vm.warp(block.timestamp + DELAY);
        _safeExec(
            safes[0],
            address(timelock),
            0,
            abi.encodeCall(timelock.execute, (address(token), 0, callData, bytes32(0), salt)),
            Enum.Operation.Call
        );
        assertFalse(token.paused());
    }

    function _rehearseOpenMarket() internal {
        bytes memory callData = abi.encodeCall(token.openMarket, ());
        bytes32 salt = keccak256("RC3-OPEN");
        _safeExec(
            safes[0],
            address(timelock),
            0,
            abi.encodeCall(timelock.schedule, (address(token), 0, callData, bytes32(0), salt, DELAY)),
            Enum.Operation.Call
        );
        vm.warp(block.timestamp + DELAY);
        _safeExec(
            safes[0],
            address(timelock),
            0,
            abi.encodeCall(timelock.execute, (address(token), 0, callData, bytes32(0), salt)),
            Enum.Operation.Call
        );
        assertTrue(token.marketOpen());
        vm.expectRevert(BiniTokenV2.MarketAlreadyOpen.selector);
        vm.prank(address(timelock));
        token.openMarket();
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function _rehearseFiveHolderMigration() internal {
        BiniV1TestFixture v1 = new BiniV1TestFixture(address(this));
        BiniMigrationVault vault = new BiniMigrationVault(address(v1), address(token), address(timelock));
        address[] memory holders = new address[](5);
        uint256[] memory amounts = new uint256[](5);
        bytes32[] memory actionIds = new bytes32[](5);
        uint256 totalV1;
        uint256 totalV2;
        for (uint256 i = 0; i < holders.length; ++i) {
            holders[i] = address(uint160(0x1001 + i));
            amounts[i] = (i + 1) * 1_000_000_000_000;
            actionIds[i] = keccak256(abi.encode("RC3-MIGRATION-HOLDER", i));
            totalV1 += amounts[i];
            totalV2 += amounts[i] * 1_000_000;
            v1.mintFixture(holders[i], amounts[i]);
            _safeExec(
                safes[i + 3],
                address(token),
                0,
                abi.encodeCall(token.transfer, (address(vault), amounts[i] * 1_000_000)),
                Enum.Operation.Call
            );
        }

        address[] memory targets = new address[](2);
        targets[0] = address(vault);
        targets[1] = address(vault);
        uint256[] memory values = new uint256[](2);
        bytes[] memory payloads = new bytes[](2);
        payloads[0] = abi.encodeCall(vault.setEntitlements, (holders, amounts, actionIds));
        payloads[1] = abi.encodeCall(vault.sealEntitlements, ());
        bytes32 salt = keccak256("RC3-MIGRATION-ENTITLEMENTS");
        _safeExec(
            safes[0],
            address(timelock),
            0,
            abi.encodeCall(timelock.scheduleBatch, (targets, values, payloads, bytes32(0), salt, DELAY)),
            Enum.Operation.Call
        );
        vm.warp(block.timestamp + DELAY);
        _safeExec(
            safes[0],
            address(timelock),
            0,
            abi.encodeCall(timelock.executeBatch, (targets, values, payloads, bytes32(0), salt)),
            Enum.Operation.Call
        );

        for (uint256 i = 0; i < holders.length; ++i) {
            vm.startPrank(holders[i]);
            v1.approve(address(vault), amounts[i]);
            vault.migrate(holders[i], amounts[i], holders[i], 0, "");
            vm.expectRevert(abi.encodeWithSelector(BiniMigrationVault.MigrationAlreadyCompleted.selector, holders[i]));
            vault.migrate(holders[i], amounts[i], holders[i], 0, "");
            vm.stopPrank();
            assertEq(token.balanceOf(holders[i]), amounts[i] * 1_000_000);
            assertTrue(vault.completedActions(actionIds[i]));
        }
        assertEq(vault.totalLockedV1(), totalV1);
        assertEq(vault.totalReleasedV2(), totalV2);
        assertEq(vault.remainingV2Liability(), 0);
        assertEq(v1.balanceOf(address(vault)), totalV1);
    }

    function _safeExec(Safe safe, address to, uint256 value, bytes memory data, Enum.Operation operation) internal {
        uint256 nonce = safe.nonce();
        bytes32 txHash =
            safe.getTransactionHash(to, value, data, operation, 0, 0, 0, address(0), payable(address(0)), nonce);
        bytes memory signatures = _twoSignatures(txHash);
        bool success =
            safe.execTransaction(to, value, data, operation, 0, 0, 0, address(0), payable(address(0)), signatures);
        assertTrue(success);
    }

    function _safeExecExpectRevert(Safe safe, address to, bytes memory data) internal {
        uint256 nonce = safe.nonce();
        bytes32 txHash =
            safe.getTransactionHash(to, 0, data, Enum.Operation.Call, 0, 0, 0, address(0), payable(address(0)), nonce);
        bytes memory signatures = _twoSignatures(txHash);
        vm.expectRevert();
        safe.execTransaction(to, 0, data, Enum.Operation.Call, 0, 0, 0, address(0), payable(address(0)), signatures);
    }

    function _twoSignatures(bytes32 txHash) internal view returns (bytes memory signatures) {
        (uint8 v0, bytes32 r0, bytes32 s0) = vm.sign(ownerKeys[0], txHash);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(ownerKeys[1], txHash);
        signatures = abi.encodePacked(r0, s0, v0, r1, s1, v1);
    }

    function _sortOwnersAndKeys() internal {
        owners = [vm.addr(OWNER_PK_1), vm.addr(OWNER_PK_2), vm.addr(OWNER_PK_3)];
        ownerKeys = [OWNER_PK_1, OWNER_PK_2, OWNER_PK_3];
        for (uint256 i = 0; i < owners.length; ++i) {
            for (uint256 j = i + 1; j < owners.length; ++j) {
                if (owners[j] < owners[i]) {
                    (owners[i], owners[j]) = (owners[j], owners[i]);
                    (ownerKeys[i], ownerKeys[j]) = (ownerKeys[j], ownerKeys[i]);
                }
            }
        }
    }

    function _owners() internal view returns (address[] memory result) {
        result = new address[](3);
        for (uint256 i = 0; i < 3; ++i) {
            result[i] = owners[i];
        }
    }

    function _oneAddress(address value) internal pure returns (address[] memory result) {
        result = new address[](1);
        result[0] = value;
    }
}
