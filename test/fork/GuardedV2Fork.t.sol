// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BiniTokenV2Guarded as G} from "../../src/BiniTokenV2Guarded.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IV2Factory {
    function createPair(address, address) external returns (address);
}

interface IV2Pair {
    function mint(address to) external returns (uint256);
}

contract MockUSD is ERC20 {
    constructor(address to) ERC20("MockUSD", "mUSD") {
        _mint(to, 1_000_000 ether);
    }
}

/// MODEL C decisive PoC — permanently guarded BINI vs REAL mainnet Uniswap V2 (ECON-2 role model).
contract GuardedV2ForkTest is Test {
    address constant V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;

    G internal t;
    MockUSD internal usd;
    MockUSD internal usd2;
    address internal timelock = address(0x700);
    address internal ops = address(0x704);
    address internal security = address(0x701);
    address internal unpauser = address(0x702);
    address internal genesis = address(0x703);
    address internal alice = address(0xA11CE);

    function _a(address x) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = x;
    }

    function setUp() public {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com"); // latest block (archive-gated for pinned)
        G impl = new G();
        t = G(
            address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(G.initialize, (timelock, ops, security, genesis, uint48(3 days)))
                )
            )
        );
        usd = new MockUSD(genesis);
        usd2 = new MockUSD(genesis);

        vm.prank(timelock);
        t.setSystemAccounts(_a(genesis), true); // genesis = SYSTEM
        vm.prank(ops);
        t.setParticipants(_a(alice), true); // alice = PARTICIPANT
    }

    function test_Guarded_Official_Pair_Seedable() public {
        address official = IV2Factory(V2_FACTORY).createPair(address(t), address(usd));
        vm.prank(timelock);
        t.setMarketEndpoints(_a(official), true); // ENDPOINT_MANAGER = Timelock
        vm.prank(timelock);
        t.setOperators(_a(genesis), true); // feeding a MARKET_ENDPOINT requires an operator
        vm.prank(timelock);
        t.activateGuardedMode();

        vm.startPrank(genesis);
        t.transfer(official, 100_000 ether); // genesis(operator) -> official(MARKET_ENDPOINT): allowed
        usd.transfer(official, 100_000 ether);
        vm.stopPrank();
        IV2Pair(official).mint(genesis);
        assertEq(t.balanceOf(official), 100_000 ether);
    }

    function test_Guarded_Unknown_Pair_PermanentlyBlocked() public {
        vm.prank(timelock);
        t.activateGuardedMode();
        vm.prank(genesis);
        t.transfer(alice, 50_000 ether); // genesis(SYSTEM) -> alice(PARTICIPANT): ok
        address rogue = IV2Factory(V2_FACTORY).createPair(address(t), address(usd2)); // NOT approved
        vm.expectRevert(abi.encodeWithSelector(G.TransferNotAllowed.selector, alice, rogue, alice));
        vm.prank(alice);
        t.transfer(rogue, 1_000 ether); // blocked forever — rogue is class NONE
        assertEq(t.balanceOf(rogue), 0);
    }
}
