// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BiniTokenV2Guarded as G} from "../../src/BiniTokenV2Guarded.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// MODEL C — Uniswap V4 GATEWAY feasibility PoC vs the REAL mainnet V4 PoolManager singleton.
///
/// The V4 problem: all pools share one PoolManager; real BINI enters it via `sync → BINI.transfer(PM) →
/// settle`. If PoolManager is a plain approved endpoint, ANY participant could transfer BINI in and fund a
/// rogue PoolId (the "all-or-nothing" trap), and could mint a BINI ERC-6909 claim to shuttle between pools.
///
/// The guarded lever proven here: **feeding a MARKET_ENDPOINT requires an approved OPERATOR**. So a plain
/// participant CANNOT `transfer` real BINI into the PoolManager — only the approved gateway/router can.
/// Consequence: a user can never create a BINI balance inside PoolManager, hence can never mint a BINI
/// ERC-6909 claim → the claims bypass has no entry. Official V4 flows go through the approved gateway.
contract V4GatewayForkTest is Test {
    // Uniswap V4 PoolManager singleton (Ethereum mainnet) — same singleton the rogue BINI honeypots used.
    address constant V4_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    G internal t;
    address internal timelock = address(0x700);
    address internal pauser = address(0x701);
    address internal unpauser = address(0x702);
    address internal genesis = address(0x703);
    address internal user = address(0xA11CE); // ordinary participant
    address internal gateway = address(0x6A7E); // the official BINI V4 gateway (approved operator)

    function _a(address x) internal pure returns (address[] memory r) { r = new address[](1); r[0] = x; }

    function setUp() public {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com"); // latest block
        G impl = new G();
        t = G(address(new ERC1967Proxy(address(impl), abi.encodeCall(
            G.initialize, (timelock, pauser, unpauser, genesis, uint48(3 days))
        ))));

        // perimeter
        vm.startPrank(genesis);
        t.setSystemAccounts(_a(genesis), true);
        t.setParticipants(_a(user), true);
        t.setSystemAccounts(_a(gateway), true); // gateway is an approved account
        t.setOperators(_a(gateway), true); // ...AND an approved operator (may feed endpoints)
        vm.stopPrank();

        // The PoolManager is approved as a MARKET_ENDPOINT (so the gateway CAN settle into it)...
        vm.prank(timelock);
        t.setMarketEndpoints(_a(V4_POOL_MANAGER), true);
        // ...and guarded mode is permanent.
        vm.prank(timelock);
        t.activateGuardedMode();

        // seed the user + gateway with real BINI (genesis is a system account; to non-endpoint = ok)
        vm.startPrank(genesis);
        t.transfer(user, 10_000 ether);
        t.transfer(gateway, 10_000 ether);
        vm.stopPrank();
    }

    // sanity: the real V4 PoolManager exists on the fork
    function test_PoolManager_HasCode() public view {
        assertGt(V4_POOL_MANAGER.code.length, 0);
    }

    // DECISIVE: a plain participant CANNOT transfer real BINI into the real V4 PoolManager
    // → cannot sync/settle → cannot fund a rogue PoolId → cannot mint a BINI ERC-6909 claim.
    function test_Direct_User_To_PoolManager_Blocked() public {
        vm.expectRevert(abi.encodeWithSelector(G.TransferNotAllowed.selector, user, V4_POOL_MANAGER, user));
        vm.prank(user);
        t.transfer(V4_POOL_MANAGER, 1_000 ether);
        assertEq(t.balanceOf(V4_POOL_MANAGER), 0);
    }

    // even transferFrom via a NON-operator spender is blocked (no back-door)
    function test_Direct_User_To_PoolManager_viaNonOperator_Blocked() public {
        vm.prank(user);
        t.approve(address(0xBADD), 1_000 ether);
        vm.expectRevert(abi.encodeWithSelector(G.TransferNotAllowed.selector, user, V4_POOL_MANAGER, address(0xBADD)));
        vm.prank(address(0xBADD));
        t.transferFrom(user, V4_POOL_MANAGER, 1_000 ether);
    }

    // the OFFICIAL route works: the approved gateway (operator) CAN settle real BINI into the PoolManager.
    function test_Gateway_To_PoolManager_Allowed() public {
        vm.prank(gateway);
        t.transfer(V4_POOL_MANAGER, 1_000 ether); // gateway is an approved operator → allowed
        assertEq(t.balanceOf(V4_POOL_MANAGER), 1_000 ether);
    }
}
