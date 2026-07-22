// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BiniTokenV2Guarded as G} from "../../src/BiniTokenV2Guarded.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IV3Factory { function createPool(address, address, uint24) external returns (address); }
interface IV3Pool { function initialize(uint160) external; }

interface INPM {
    struct MintParams {
        address token0; address token1; uint24 fee;
        int24 tickLower; int24 tickUpper;
        uint256 amount0Desired; uint256 amount1Desired;
        uint256 amount0Min; uint256 amount1Min;
        address recipient; uint256 deadline;
    }
    function mint(MintParams calldata) external payable returns (uint256, uint128, uint256, uint256);
}

interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256);
}

contract MockUSD is ERC20 {
    constructor(address to) ERC20("MockUSD", "mUSD") { _mint(to, 100_000_000 ether); }
}

/// MODEL C — guarded BINI vs REAL mainnet Uniswap V3 (ECON-2.2 Agent 5).
/// Proves approved-vs-unknown across the real periphery: an approved V3 pool is fully usable (mint liquidity +
/// swap both directions) ONLY because NPM + SwapRouter are approved OPERATORS and the pool is a MARKET_ENDPOINT;
/// an unknown pool cannot receive BINI even through the real NonfungiblePositionManager.
contract GuardedV3ForkTest is Test {
    address constant V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant NPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;        // NonfungiblePositionManager
    address constant ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;     // SwapRouter02
    uint160 constant SQRT_1_1 = 79228162514264337593543950336;               // price 1:1
    uint24 constant FEE = 3000; int24 constant SPACING = 60;

    G internal t;
    MockUSD internal usd;
    address internal timelock = address(0x700);
    address internal ops = address(0x704);
    address internal security = address(0x701);
    address internal unpauser = address(0x702);
    address internal genesis = address(0x703);

    function _a(address x) internal pure returns (address[] memory r) { r = new address[](1); r[0] = x; }
    function _round(int24 t_) internal pure returns (int24) { return (t_ / SPACING) * SPACING; }

    function setUp() public {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com"); // latest block
        G impl = new G();
        t = G(address(new ERC1967Proxy(address(impl), abi.encodeCall(
            G.initialize, (timelock, ops, security, unpauser, genesis, uint48(3 days))
        ))));
        usd = new MockUSD(genesis);
        vm.prank(timelock);
        t.setSystemAccounts(_a(genesis), true); // genesis = SYSTEM (payer/holder inside perimeter)
    }

    function _sorted() internal view returns (address t0, address t1) {
        (t0, t1) = address(t) < address(usd) ? (address(t), address(usd)) : (address(usd), address(t));
    }

    function _approveOfficialInfra(address pool) internal {
        vm.startPrank(timelock);
        t.setMarketEndpoints(_a(pool), true); // pool = MARKET_ENDPOINT
        t.setOperators(_a(NPM), true);        // NPM may feed endpoints (mint liquidity)
        t.setOperators(_a(ROUTER), true);     // Router may feed endpoints (swap)
        vm.stopPrank();
    }

    function test_Guarded_Official_V3_Pool_MintAndSwap() public {
        (address t0, address t1) = _sorted();
        address pool = IV3Factory(V3_FACTORY).createPool(address(t), address(usd), FEE);
        IV3Pool(pool).initialize(SQRT_1_1);
        _approveOfficialInfra(pool);
        vm.prank(timelock);
        t.activateGuardedMode();

        // genesis funds liquidity through the REAL NPM (guard allows: pool=endpoint, NPM=operator, genesis in perimeter)
        vm.startPrank(genesis);
        t.approve(NPM, type(uint256).max);
        usd.approve(NPM, type(uint256).max);
        INPM(NPM).mint(INPM.MintParams({
            token0: t0, token1: t1, fee: FEE,
            tickLower: _round(-6000), tickUpper: _round(6000),
            amount0Desired: 200_000 ether, amount1Desired: 200_000 ether,
            amount0Min: 0, amount1Min: 0, recipient: genesis, deadline: block.timestamp + 1
        }));
        vm.stopPrank();
        assertGt(t.balanceOf(pool), 0, "approved pool holds BINI liquidity");

        // swap USD -> BINI (BINI flows pool -> genesis): pool is msg.sender==from on the BINI leg
        uint256 biniBefore = t.balanceOf(genesis);
        vm.startPrank(genesis);
        usd.approve(ROUTER, type(uint256).max);
        ISwapRouter02(ROUTER).exactInputSingle(ISwapRouter02.ExactInputSingleParams({
            tokenIn: address(usd), tokenOut: address(t), fee: FEE, recipient: genesis,
            amountIn: 1_000 ether, amountOutMinimum: 0, sqrtPriceLimitX96: 0
        }));
        vm.stopPrank();
        assertGt(t.balanceOf(genesis), biniBefore, "genesis received BINI out of approved pool");

        // swap BINI -> USD (BINI flows genesis -> pool via Router operator)
        vm.startPrank(genesis);
        t.approve(ROUTER, type(uint256).max);
        ISwapRouter02(ROUTER).exactInputSingle(ISwapRouter02.ExactInputSingleParams({
            tokenIn: address(t), tokenOut: address(usd), fee: FEE, recipient: genesis,
            amountIn: 1_000 ether, amountOutMinimum: 0, sqrtPriceLimitX96: 0
        }));
        vm.stopPrank();
    }

    function test_Guarded_Unknown_V3_Pool_CannotReceiveBINI() public {
        MockUSD usd2 = new MockUSD(genesis);
        address pool2 = IV3Factory(V3_FACTORY).createPool(address(t), address(usd2), 500);
        IV3Pool(pool2).initialize(SQRT_1_1); // initialized, so the ONLY failure is the guard
        vm.prank(timelock);
        t.activateGuardedMode(); // pool2 NOT approved as endpoint, NPM NOT approved operator

        (address t0, address t1) = address(t) < address(usd2) ? (address(t), address(usd2)) : (address(usd2), address(t));
        vm.startPrank(genesis);
        t.approve(NPM, type(uint256).max);
        usd2.approve(NPM, type(uint256).max);
        vm.expectRevert(); // NPM mint callback pulls BINI -> to=unapproved pool2 -> TransferNotAllowed bubbles up
        INPM(NPM).mint(INPM.MintParams({
            token0: t0, token1: t1, fee: 500,
            tickLower: -10, tickUpper: 10,
            amount0Desired: 100_000 ether, amount1Desired: 100_000 ether,
            amount0Min: 0, amount1Min: 0, recipient: genesis, deadline: block.timestamp + 1
        }));
        vm.stopPrank();
        assertEq(t.balanceOf(pool2), 0, "unknown pool never receives BINI");
    }

    function test_Guarded_Endpoint_Revocation_BlocksFurtherFeeding() public {
        address pool = IV3Factory(V3_FACTORY).createPool(address(t), address(usd), FEE);
        IV3Pool(pool).initialize(SQRT_1_1);
        _approveOfficialInfra(pool);
        vm.prank(timelock);
        t.activateGuardedMode();

        // revoke the pool endpoint -> operator can no longer feed it
        vm.prank(timelock);
        t.setMarketEndpoints(_a(pool), false);

        (address t0, address t1) = _sorted();
        vm.startPrank(genesis);
        t.approve(NPM, type(uint256).max);
        usd.approve(NPM, type(uint256).max);
        vm.expectRevert();
        INPM(NPM).mint(INPM.MintParams({
            token0: t0, token1: t1, fee: FEE,
            tickLower: _round(-6000), tickUpper: _round(6000),
            amount0Desired: 200_000 ether, amount1Desired: 200_000 ether,
            amount0Min: 0, amount1Min: 0, recipient: genesis, deadline: block.timestamp + 1
        }));
        vm.stopPrank();
    }
}
