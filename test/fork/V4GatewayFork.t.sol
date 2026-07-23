// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BiniTokenV2Guarded as G} from "../../src/BiniTokenV2Guarded.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// MODEL C — Uniswap V4 GATEWAY feasibility PoC vs the REAL mainnet V4 PoolManager singleton (ECON-2 roles).
/// Proves: a plain participant CANNOT feed the singleton PoolManager (feeding a MARKET_ENDPOINT needs an
/// approved operator) -> no direct settlement -> no BINI balance in PoolManager -> no BINI ERC-6909 claim
/// entry. The official route goes through the approved gateway operator.
contract V4GatewayForkTest is Test {
    address constant V4_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    G internal t;
    address internal timelock = address(0x700);
    address internal ops = address(0x704);
    address internal security = address(0x701);
    address internal unpauser = address(0x702);
    address internal genesis = address(0x703);
    address internal user = address(0xA11CE); // participant
    address internal gateway = address(0x6A7E); // approved gateway (SYSTEM + operator)

    function _a(address x) internal pure returns (address[] memory r) { r = new address[](1); r[0] = x; }

    function setUp() public {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com"); // latest block
        G impl = new G();
        t = G(address(new ERC1967Proxy(address(impl), abi.encodeCall(
            G.initialize, (timelock, ops, security, genesis, uint48(3 days))
        ))));

        vm.startPrank(timelock);
        t.setSystemAccounts(_a(genesis), true);
        t.setSystemAccounts(_a(gateway), true);
        t.setOperators(_a(gateway), true); // gateway is the approved operator that may feed PoolManager
        t.setMarketEndpoints(_a(V4_POOL_MANAGER), true);
        vm.stopPrank();
        vm.prank(ops);
        t.setParticipants(_a(user), true);
        vm.prank(timelock);
        t.activateGuardedMode();

        vm.startPrank(genesis);
        t.transfer(user, 10_000 ether);
        t.transfer(gateway, 10_000 ether);
        vm.stopPrank();
    }

    function test_PoolManager_HasCode() public view {
        assertGt(V4_POOL_MANAGER.code.length, 0);
    }

    // DECISIVE: a plain participant cannot transfer real BINI into the real V4 PoolManager.
    function test_Direct_User_To_PoolManager_Blocked() public {
        vm.expectRevert(abi.encodeWithSelector(G.TransferNotAllowed.selector, user, V4_POOL_MANAGER, user));
        vm.prank(user);
        t.transfer(V4_POOL_MANAGER, 1_000 ether);
        assertEq(t.balanceOf(V4_POOL_MANAGER), 0);
    }

    function test_Direct_User_To_PoolManager_viaNonOperator_Blocked() public {
        vm.prank(user);
        t.approve(address(0xBADD), 1_000 ether);
        vm.expectRevert(abi.encodeWithSelector(G.TransferNotAllowed.selector, user, V4_POOL_MANAGER, address(0xBADD)));
        vm.prank(address(0xBADD));
        t.transferFrom(user, V4_POOL_MANAGER, 1_000 ether);
    }

    function test_Gateway_To_PoolManager_Allowed() public {
        vm.prank(gateway);
        t.transfer(V4_POOL_MANAGER, 1_000 ether); // gateway = approved operator -> allowed
        assertEq(t.balanceOf(V4_POOL_MANAGER), 1_000 ether);
    }
}
