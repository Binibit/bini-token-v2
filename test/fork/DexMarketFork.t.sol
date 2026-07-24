// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BiniTokenV2} from "../../src/BiniTokenV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IUniswapV3Factory {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}

contract ForkMockToken is ERC20 {
    constructor() ERC20("Fork Mock USD", "fmUSD") {
        _mint(msg.sender, 1_000_000 ether);
    }
}

contract DexMarketForkTest is Test {
    address internal constant V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address internal constant V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address internal constant V4_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    BiniTokenV2 internal token;
    ForkMockToken internal quote;

    address internal timelock = address(0x700);
    address internal pauser = address(0x701);
    address internal genesis = address(0x703);
    address internal alice = address(0xA11CE);

    function setUp() public {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com");
        BiniTokenV2 impl = new BiniTokenV2();
        token = BiniTokenV2(
            address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(BiniTokenV2.initialize, (timelock, pauser, genesis, uint48(3 days)))
                )
            )
        );
        quote = new ForkMockToken();

        vm.startPrank(timelock);
        token.setDexFactory(V2_FACTORY, BiniTokenV2.FactoryKind.UNISWAP_V2);
        token.setDexFactory(V3_FACTORY, BiniTokenV2.FactoryKind.UNISWAP_V3);
        address[] memory infrastructure = new address[](1);
        infrastructure[0] = V4_POOL_MANAGER;
        token.setMarketInfrastructure(infrastructure, true);
        vm.stopPrank();

        vm.prank(genesis);
        token.transfer(alice, 100_000 ether);
    }

    function test_MainnetV2PairBlockedPreMarketAndAllowedAfterOpen() public {
        address pair = IUniswapV2Factory(V2_FACTORY).createPair(address(token), address(quote));
        assertTrue(token.isRecognizedDexPool(pair));

        vm.expectRevert(abi.encodeWithSelector(BiniTokenV2.DexMarketClosed.selector, pair));
        vm.prank(alice);
        token.transfer(pair, 1_000 ether);

        vm.prank(timelock);
        token.openMarket();
        vm.prank(alice);
        token.transfer(pair, 1_000 ether);
        assertEq(token.balanceOf(pair), 1_000 ether);
    }

    function test_MainnetV3PoolBlockedPreMarketAndAllowedAfterOpen() public {
        address pool = IUniswapV3Factory(V3_FACTORY).createPool(address(token), address(quote), 3000);
        assertTrue(token.isRecognizedDexPool(pool));

        vm.expectRevert(abi.encodeWithSelector(BiniTokenV2.DexMarketClosed.selector, pool));
        vm.prank(alice);
        token.transfer(pool, 1_000 ether);

        vm.prank(timelock);
        token.openMarket();
        vm.prank(alice);
        token.transfer(pool, 1_000 ether);
        assertEq(token.balanceOf(pool), 1_000 ether);
    }

    function test_MainnetV4PoolManagerBlockedPreMarketAndAllowedAfterOpen() public {
        assertGt(V4_POOL_MANAGER.code.length, 0);
        vm.expectRevert(abi.encodeWithSelector(BiniTokenV2.DexMarketClosed.selector, V4_POOL_MANAGER));
        vm.prank(alice);
        token.transfer(V4_POOL_MANAGER, 1_000 ether);

        vm.prank(timelock);
        token.openMarket();
        vm.prank(alice);
        token.transfer(V4_POOL_MANAGER, 1_000 ether);
        assertEq(token.balanceOf(V4_POOL_MANAGER), 1_000 ether);
    }
}
