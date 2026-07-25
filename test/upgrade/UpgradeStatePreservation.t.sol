// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BiniTokenV2} from "../../src/BiniTokenV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ActorContract} from "../mocks/MarketMocks.sol";

contract BiniTokenV2UpgradeMock is BiniTokenV2 {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract UpgradeDummyContract {}

contract WrongUUID {
    function proxiableUUID() external pure returns (bytes32) {
        return keccak256("WRONG_UUID");
    }
}

contract UpgradeStatePreservationTest is Test {
    BiniTokenV2 internal token;

    address internal timelock;
    address internal pauser;
    address internal genesis;
    address internal alice = address(0xA11CE);
    address internal poolManager;
    address internal factory;

    function setUp() public {
        timelock = address(new ActorContract());
        pauser = address(new ActorContract());
        genesis = address(new ActorContract());
        BiniTokenV2 impl = new BiniTokenV2();
        token = BiniTokenV2(
            address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(BiniTokenV2.initialize, (timelock, pauser, genesis, uint48(3 days)))
                )
            )
        );
        poolManager = address(new UpgradeDummyContract());
        factory = address(new UpgradeDummyContract());
    }

    function test_UUPSUpgradePreservesTokenAndMarketState() public {
        address[] memory infrastructure = new address[](1);
        infrastructure[0] = poolManager;
        vm.startPrank(timelock);
        token.setMarketInfrastructure(infrastructure, true);
        token.setDexFactory(factory, BiniTokenV2.FactoryKind.UNISWAP_V2);
        vm.stopPrank();
        vm.prank(genesis);
        token.transfer(alice, 123 ether);
        vm.prank(alice);
        token.approve(poolManager, 77 ether);
        vm.prank(pauser);
        token.pause();

        BiniTokenV2UpgradeMock next = new BiniTokenV2UpgradeMock();
        vm.prank(timelock);
        token.upgradeToAndCall(address(next), "");

        assertEq(BiniTokenV2UpgradeMock(address(token)).version(), 2);
        assertEq(token.balanceOf(alice), 123 ether);
        assertEq(token.allowance(alice, poolManager), 77 ether);
        assertEq(token.totalSupply(), token.MAX_SUPPLY());
        assertEq(uint256(token.marketState()), uint256(BiniTokenV2.MarketState.PRE_MARKET));
        assertTrue(token.isMarketInfrastructure(poolManager));
        assertEq(uint256(token.dexFactoryKind(factory)), uint256(BiniTokenV2.FactoryKind.UNISWAP_V2));
        assertTrue(token.paused());
        assertTrue(token.hasRole(token.UPGRADER_ROLE(), timelock));
    }

    function test_NonUpgraderCannotUpgrade() public {
        BiniTokenV2UpgradeMock next = new BiniTokenV2UpgradeMock();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, token.UPGRADER_ROLE()
            )
        );
        vm.prank(alice);
        token.upgradeToAndCall(address(next), "");
    }

    function test_NonUUPSImplementationIsRejected() public {
        UpgradeDummyContract invalid = new UpgradeDummyContract();
        vm.expectRevert(abi.encodeWithSelector(ERC1967Utils.ERC1967InvalidImplementation.selector, address(invalid)));
        vm.prank(timelock);
        token.upgradeToAndCall(address(invalid), "");
    }

    function test_WrongProxiableUUIDIsRejected() public {
        WrongUUID invalid = new WrongUUID();
        vm.expectRevert(
            abi.encodeWithSelector(UUPSUpgradeable.UUPSUnsupportedProxiableUUID.selector, keccak256("WRONG_UUID"))
        );
        vm.prank(timelock);
        token.upgradeToAndCall(address(invalid), "");
    }

    function test_DirectImplementationUpgradeCallIsRejected() public {
        BiniTokenV2 implementation = new BiniTokenV2();
        BiniTokenV2UpgradeMock next = new BiniTokenV2UpgradeMock();
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        vm.prank(timelock);
        implementation.upgradeToAndCall(address(next), "");
    }

    function test_ZeroImplementationIsRejectedByAuthorization() public {
        vm.expectRevert(BiniTokenV2.ZeroAddress.selector);
        vm.prank(timelock);
        token.upgradeToAndCall(address(0), "");
    }
}
