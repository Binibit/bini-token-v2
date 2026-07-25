// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BiniTokenV2} from "../../src/BiniTokenV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ActorContract, MockV2Factory, MockV3Factory} from "../mocks/MarketMocks.sol";

interface IUUPSUpgrade {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

contract BiniTokenV2E2EUpgrade is BiniTokenV2 {
    function releaseVersion() external pure returns (uint256) {
        return 2;
    }
}

contract ReleaseLifecycleE2ETest is Test {
    uint256 internal constant TIMELOCK_DELAY = 2 days;
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    BiniTokenV2 internal token;
    TimelockController internal timelock;
    MockV2Factory internal v2Factory;
    MockV3Factory internal v3Factory;

    address internal proposer = address(0xA01);
    address internal executor = address(0xE01);
    address internal pauser;
    address internal genesis;
    address internal safe;
    address internal custody;
    address internal vesting;
    address internal poolManager;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal quote = address(0xC01);

    function setUp() public {
        pauser = address(new ActorContract());
        genesis = address(new ActorContract());
        safe = address(new ActorContract());
        custody = address(new ActorContract());
        vesting = address(new ActorContract());
        poolManager = address(new ActorContract());

        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = executor;
        timelock = new TimelockController(TIMELOCK_DELAY, proposers, executors, address(0));

        BiniTokenV2 implementation = new BiniTokenV2();
        token = BiniTokenV2(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(BiniTokenV2.initialize, (address(timelock), pauser, genesis, uint48(TIMELOCK_DELAY)))
                )
            )
        );

        v2Factory = new MockV2Factory();
        v3Factory = new MockV3Factory();
    }

    function _scheduleAndExecute(bytes memory data, bytes32 salt) internal {
        vm.prank(proposer);
        timelock.schedule(address(token), 0, data, bytes32(0), salt, TIMELOCK_DELAY);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(executor);
        timelock.execute(address(token), 0, data, bytes32(0), salt);
    }

    function test_FullReleaseLifecycle() public {
        address v2Pair = v2Factory.createPair(address(token), quote);
        address v3Pool = v3Factory.createPool(address(token), quote, 3000);

        _scheduleAndExecute(
            abi.encodeCall(BiniTokenV2.setDexFactory, (address(v2Factory), BiniTokenV2.FactoryKind.UNISWAP_V2)),
            keccak256("CONFIG_V2")
        );
        _scheduleAndExecute(
            abi.encodeCall(BiniTokenV2.setDexFactory, (address(v3Factory), BiniTokenV2.FactoryKind.UNISWAP_V3)),
            keccak256("CONFIG_V3")
        );
        address[] memory infrastructure = new address[](1);
        infrastructure[0] = poolManager;
        _scheduleAndExecute(
            abi.encodeCall(BiniTokenV2.setMarketInfrastructure, (infrastructure, true)), keccak256("CONFIG_V4")
        );

        vm.startPrank(genesis);
        token.transfer(alice, 100_000 ether);
        token.transfer(safe, 100_000 ether);
        token.transfer(custody, 100_000 ether);
        token.transfer(vesting, 100_000 ether);
        vm.stopPrank();

        vm.prank(alice);
        token.transfer(bob, 1_000 ether);
        vm.prank(alice);
        token.approve(bob, 500 ether);
        vm.prank(bob);
        token.transferFrom(alice, custody, 500 ether);

        assertEq(token.balanceOf(bob), 1_000 ether);
        assertEq(token.balanceOf(custody), 100_500 ether);
        assertTrue(token.isRecognizedDexPool(v2Pair));
        assertTrue(token.isRecognizedDexPool(v3Pool));
        assertTrue(token.isBlockedDexDestination(poolManager));

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(BiniTokenV2.DexMarketClosed.selector, v2Pair));
        token.transfer(v2Pair, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(BiniTokenV2.DexMarketClosed.selector, v3Pool));
        token.transfer(v3Pool, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(BiniTokenV2.DexMarketClosed.selector, poolManager));
        token.transfer(poolManager, 1 ether);
        vm.stopPrank();

        _scheduleAndExecute(abi.encodeCall(BiniTokenV2.openMarket, ()), keccak256("OPEN_MARKET"));
        assertTrue(token.marketOpen());

        vm.startPrank(alice);
        token.transfer(v2Pair, 1 ether);
        token.transfer(v3Pool, 1 ether);
        token.transfer(poolManager, 1 ether);
        vm.stopPrank();

        vm.prank(pauser);
        token.pause();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(alice);
        token.transfer(bob, 1 ether);

        _scheduleAndExecute(abi.encodeCall(BiniTokenV2.unpause, ()), keccak256("UNPAUSE"));
        vm.prank(alice);
        token.transfer(bob, 1 ether);

        BiniTokenV2E2EUpgrade next = new BiniTokenV2E2EUpgrade();
        _scheduleAndExecute(
            abi.encodeCall(IUUPSUpgrade.upgradeToAndCall, (address(next), bytes(""))), keccak256("UPGRADE_V2")
        );

        assertEq(BiniTokenV2E2EUpgrade(address(token)).releaseVersion(), 2);
        assertTrue(token.marketOpen());
        assertEq(token.totalSupply(), token.MAX_SUPPLY());
        assertEq(address(uint160(uint256(vm.load(address(token), IMPLEMENTATION_SLOT)))), address(next));
        assertFalse(token.isBlockedDexDestination(v2Pair));
    }

    function test_CancelledOpenMarketOperationCannotExecute() public {
        bytes memory data = abi.encodeCall(BiniTokenV2.openMarket, ());
        bytes32 salt = keccak256("CANCELLED_OPEN");
        bytes32 operationId = timelock.hashOperation(address(token), 0, data, bytes32(0), salt);

        vm.prank(proposer);
        timelock.schedule(address(token), 0, data, bytes32(0), salt, TIMELOCK_DELAY);
        vm.prank(proposer);
        timelock.cancel(operationId);

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert();
        vm.prank(executor);
        timelock.execute(address(token), 0, data, bytes32(0), salt);
        assertFalse(token.marketOpen());
    }
}
