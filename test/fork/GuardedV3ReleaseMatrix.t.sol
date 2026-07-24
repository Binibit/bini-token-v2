// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BiniTokenV2Guarded as G} from "../../src/BiniTokenV2Guarded.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IV3Factory {
    function createPool(address, address, uint24) external returns (address);
}

interface IV3Pool {
    function initialize(uint160) external;
}

interface INPM {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }
    function mint(MintParams calldata) external payable returns (uint256, uint128, uint256, uint256);

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }
    function increaseLiquidity(IncreaseLiquidityParams calldata) external payable returns (uint128, uint256, uint256);

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }
    function decreaseLiquidity(DecreaseLiquidityParams calldata) external payable returns (uint256, uint256);

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }
    function collect(CollectParams calldata) external payable returns (uint256, uint256);

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}

interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256);
}

contract MockUSD is ERC20 {
    constructor(address to) ERC20("MockUSD", "mUSD") {
        _mint(to, 100_000_000 ether);
    }
}

/// MODEL C — guarded BINI RELEASE MATRIX vs REAL mainnet Uniswap V3 (extends GuardedV3Fork coverage).
/// Proves the full lifecycle of an APPROVED position through the real NonfungiblePositionManager + SwapRouter02:
/// increase / decrease / collect (to SYSTEM and to a PARTICIPANT), pause-mid-mint & pause-mid-swap recovery,
/// allowance & deadline & slippage failure modes, a second APPROVED fee tier, an UNAPPROVED fee tier the guard
/// blocks, and operator revocation mid-life. Every BINI leg is only movable because NPM/Router are approved
/// OPERATORS, the pool is a MARKET_ENDPOINT, and the payer/recipient sit inside the perimeter.
///
/// ROW 14 — PERMIT2 FINDING: Every flow below funds Uniswap via PLAIN ERC-20 `approve(NPM/ROUTER, amount)` +
/// the periphery's own `transferFrom`. No Permit2 (`0x000000000022D473...`) allowance, signature, or
/// `permit()` call appears anywhere in the guarded launch path. The guard's operator check keys on
/// `msg.sender` of the token transfer (the periphery contract itself), which is fully satisfied by classic
/// allowances — Permit2 is NOT required and is NOT exercised. Asserted structurally in test_Row14_NoPermit2Required.
contract GuardedV3ReleaseMatrixTest is Test {
    address constant V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant NPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88; // NonfungiblePositionManager
    address constant ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45; // SwapRouter02
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint160 constant SQRT_1_1 = 79228162514264337593543950336; // price 1:1

    uint24 constant FEE_LOW = 500; // 0.05%
    int24 constant SPACING_LOW = 10;
    uint24 constant FEE_MID = 3000; // 0.30%
    int24 constant SPACING_MID = 60;
    uint24 constant FEE_HIGH = 10000; // 1.00%
    int24 constant SPACING_HIGH = 200;

    G internal t;
    MockUSD internal usd;
    address internal timelock = address(0x700);
    address internal ops = address(0x704);
    address internal security = address(0x701);
    address internal genesis = address(0x703);
    address internal p1 = address(0x9151); // participant (retail) recipient

    function _a(address x) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = x;
    }

    function _round(int24 tick, int24 spacing) internal pure returns (int24) {
        return (tick / spacing) * spacing;
    }

    function setUp() public {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com"); // latest block
        G impl = new G();
        t = G(
            address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(G.initialize, (timelock, ops, security, genesis, uint48(3 days)))
                )
            )
        );
        usd = new MockUSD(genesis);
        vm.prank(timelock);
        t.setSystemAccounts(_a(genesis), true); // genesis = SYSTEM (payer/holder inside perimeter)
    }

    function _sorted(address a, address b) internal pure returns (address t0, address t1) {
        (t0, t1) = a < b ? (a, b) : (b, a);
    }

    function _approveInfra(address pool) internal {
        vm.startPrank(timelock);
        t.setMarketEndpoints(_a(pool), true); // pool = MARKET_ENDPOINT
        t.setOperators(_a(NPM), true); // NPM may feed endpoints (mint / increase liquidity)
        t.setOperators(_a(ROUTER), true); // Router may feed endpoints (swap)
        vm.stopPrank();
    }

    /// Shared: build an APPROVED 0.30% pool with genesis-funded liquidity in GUARDED mode.
    /// Returns pool, position tokenId, and the minted liquidity. Genesis has approved NPM for both tokens.
    function _approvedPoolWithLiquidity() internal returns (address pool, uint256 tokenId, uint128 liq) {
        (address t0, address t1) = _sorted(address(t), address(usd));
        pool = IV3Factory(V3_FACTORY).createPool(address(t), address(usd), FEE_MID);
        IV3Pool(pool).initialize(SQRT_1_1);
        _approveInfra(pool);
        vm.prank(timelock);
        t.activateGuardedMode();

        vm.startPrank(genesis);
        t.approve(NPM, type(uint256).max);
        usd.approve(NPM, type(uint256).max);
        (tokenId, liq,,) = INPM(NPM)
            .mint(
                INPM.MintParams({
                    token0: t0,
                    token1: t1,
                    fee: FEE_MID,
                    tickLower: _round(-6000, SPACING_MID),
                    tickUpper: _round(6000, SPACING_MID),
                    amount0Desired: 200_000 ether,
                    amount1Desired: 200_000 ether,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: genesis,
                    deadline: block.timestamp + 1
                })
            );
        vm.stopPrank();
        assertGt(t.balanceOf(pool), 0, "approved pool holds BINI liquidity");
    }

    function _posLiquidity(uint256 tokenId) internal view returns (uint128 liquidity) {
        (,,,,,,, liquidity,,,,) = INPM(NPM).positions(tokenId);
    }

    // ---------------------------------------------------------------------------------------------
    // ROW 1 — increaseLiquidity on an approved position feeds MORE BINI into the pool (from=genesis).
    // ---------------------------------------------------------------------------------------------
    function test_Row1_IncreaseLiquidity_Works() public {
        (address pool, uint256 tokenId,) = _approvedPoolWithLiquidity();
        uint256 poolBiniBefore = t.balanceOf(pool);
        uint128 liqBefore = _posLiquidity(tokenId);

        vm.prank(genesis);
        (uint128 added,,) = INPM(NPM)
            .increaseLiquidity(
                INPM.IncreaseLiquidityParams({
                    tokenId: tokenId,
                    amount0Desired: 100_000 ether,
                    amount1Desired: 100_000 ether,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp + 1
                })
            );

        assertGt(added, 0, "liquidity added");
        assertGt(_posLiquidity(tokenId), liqBefore, "position liquidity grew");
        assertGt(t.balanceOf(pool), poolBiniBefore, "pool BINI balance grew via NPM operator");
    }

    // ---------------------------------------------------------------------------------------------
    // ROW 2 — decreaseLiquidity reduces position liquidity; tokens become OWED, not yet transferred.
    // ---------------------------------------------------------------------------------------------
    function test_Row2_DecreaseLiquidity_Works() public {
        (address pool, uint256 tokenId, uint128 liq) = _approvedPoolWithLiquidity();
        uint256 poolBiniBefore = t.balanceOf(pool);
        uint256 genesisBiniBefore = t.balanceOf(genesis);

        vm.prank(genesis);
        INPM(NPM)
            .decreaseLiquidity(
                INPM.DecreaseLiquidityParams({
                    tokenId: tokenId, liquidity: liq / 2, amount0Min: 0, amount1Min: 0, deadline: block.timestamp + 1
                })
            );

        assertLt(_posLiquidity(tokenId), liq, "position liquidity reduced");
        // decrease only books tokensOwed inside the pool; no BINI has physically moved yet.
        assertEq(t.balanceOf(pool), poolBiniBefore, "pool BINI unchanged (owed, not transferred)");
        assertEq(t.balanceOf(genesis), genesisBiniBefore, "genesis BINI unchanged until collect");
    }

    // ---------------------------------------------------------------------------------------------
    // ROW 3 — collect after decrease pulls BINI back to genesis (from=pool, msg.sender=pool==from).
    // ---------------------------------------------------------------------------------------------
    function test_Row3_CollectToGenesis_Works() public {
        (, uint256 tokenId, uint128 liq) = _approvedPoolWithLiquidity();

        vm.startPrank(genesis);
        INPM(NPM)
            .decreaseLiquidity(
                INPM.DecreaseLiquidityParams({
                    tokenId: tokenId, liquidity: liq / 2, amount0Min: 0, amount1Min: 0, deadline: block.timestamp + 1
                })
            );
        uint256 genesisBiniBefore = t.balanceOf(genesis);
        INPM(NPM)
            .collect(
                INPM.CollectParams({
                    tokenId: tokenId, recipient: genesis, amount0Max: type(uint128).max, amount1Max: type(uint128).max
                })
            );
        vm.stopPrank();

        assertGt(t.balanceOf(genesis), genesisBiniBefore, "genesis received BINI back from pool via collect");
    }

    // ---------------------------------------------------------------------------------------------
    // ROW 4 — collect to a plain PARTICIPANT recipient (p1) works once p1 is inside the perimeter.
    // ---------------------------------------------------------------------------------------------
    function test_Row4_CollectToParticipant_Works() public {
        (, uint256 tokenId, uint128 liq) = _approvedPoolWithLiquidity();

        vm.prank(ops);
        t.setParticipants(_a(p1), true); // onboard retail recipient (PARTICIPANT class)

        vm.startPrank(genesis);
        INPM(NPM)
            .decreaseLiquidity(
                INPM.DecreaseLiquidityParams({
                    tokenId: tokenId, liquidity: liq / 2, amount0Min: 0, amount1Min: 0, deadline: block.timestamp + 1
                })
            );
        uint256 p1BiniBefore = t.balanceOf(p1);
        INPM(NPM)
            .collect(
                INPM.CollectParams({
                    tokenId: tokenId, recipient: p1, amount0Max: type(uint128).max, amount1Max: type(uint128).max
                })
            );
        vm.stopPrank();

        assertGt(t.balanceOf(p1), p1BiniBefore, "participant received BINI from pool (pool=from is approved endpoint)");
    }

    // ---------------------------------------------------------------------------------------------
    // ROW 5 — PAUSE DURING MINT: paused BINI leg bubbles up; timelock unpause; mint recovers.
    // ---------------------------------------------------------------------------------------------
    function test_Row5_PauseDuringMint_ThenRecover() public {
        (address t0, address t1) = _sorted(address(t), address(usd));
        address pool = IV3Factory(V3_FACTORY).createPool(address(t), address(usd), FEE_MID);
        IV3Pool(pool).initialize(SQRT_1_1);
        _approveInfra(pool);
        vm.prank(timelock);
        t.activateGuardedMode();

        vm.startPrank(genesis);
        t.approve(NPM, type(uint256).max);
        usd.approve(NPM, type(uint256).max);
        vm.stopPrank();

        vm.prank(security);
        t.pause();
        assertTrue(t.paused(), "paused");

        INPM.MintParams memory mp = INPM.MintParams({
            token0: t0,
            token1: t1,
            fee: FEE_MID,
            tickLower: _round(-6000, SPACING_MID),
            tickUpper: _round(6000, SPACING_MID),
            amount0Desired: 200_000 ether,
            amount1Desired: 200_000 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: genesis,
            deadline: block.timestamp + 1
        });
        vm.prank(genesis);
        vm.expectRevert(); // EnforcedPause on the BINI leg bubbles through NPM
        INPM(NPM).mint(mp);

        vm.prank(timelock); // U2: unpause via Timelock (holds UNPAUSER)
        t.unpause();
        assertFalse(t.paused(), "unpaused");

        vm.prank(genesis);
        INPM(NPM).mint(mp);
        assertGt(t.balanceOf(pool), 0, "mint recovers after unpause");
    }

    // ---------------------------------------------------------------------------------------------
    // ROW 6 — PAUSE DURING SWAP: with liquidity present, pause blocks the swap; unpause recovers.
    // ---------------------------------------------------------------------------------------------
    function test_Row6_PauseDuringSwap_ThenRecover() public {
        _approvedPoolWithLiquidity();

        vm.prank(genesis);
        usd.approve(ROUTER, type(uint256).max);

        vm.prank(security);
        t.pause();

        ISwapRouter02.ExactInputSingleParams memory sp = ISwapRouter02.ExactInputSingleParams({
            tokenIn: address(usd),
            tokenOut: address(t),
            fee: FEE_MID,
            recipient: genesis,
            amountIn: 1_000 ether,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        vm.prank(genesis);
        vm.expectRevert(); // BINI out-leg (pool->genesis) reverts while paused
        ISwapRouter02(ROUTER).exactInputSingle(sp);

        vm.prank(timelock);
        t.unpause();

        uint256 biniBefore = t.balanceOf(genesis);
        vm.prank(genesis);
        ISwapRouter02(ROUTER).exactInputSingle(sp);
        assertGt(t.balanceOf(genesis), biniBefore, "swap recovers after unpause");
    }

    // ---------------------------------------------------------------------------------------------
    // ROW 7 — ALLOWANCE ZERO: genesis revokes BINI allowance to NPM; mint cannot pull BINI -> revert.
    // ---------------------------------------------------------------------------------------------
    function test_Row7_AllowanceZero_MintReverts() public {
        (address t0, address t1) = _sorted(address(t), address(usd));
        address pool = IV3Factory(V3_FACTORY).createPool(address(t), address(usd), FEE_MID);
        IV3Pool(pool).initialize(SQRT_1_1);
        _approveInfra(pool);
        vm.prank(timelock);
        t.activateGuardedMode();

        vm.startPrank(genesis);
        t.approve(NPM, 0); // zero BINI allowance
        usd.approve(NPM, type(uint256).max);
        vm.expectRevert(); // STF: NPM.transferFrom(BINI) fails on zero allowance
        INPM(NPM)
            .mint(
                INPM.MintParams({
                    token0: t0,
                    token1: t1,
                    fee: FEE_MID,
                    tickLower: _round(-6000, SPACING_MID),
                    tickUpper: _round(6000, SPACING_MID),
                    amount0Desired: 200_000 ether,
                    amount1Desired: 200_000 ether,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: genesis,
                    deadline: block.timestamp + 1
                })
            );
        vm.stopPrank();
        assertEq(t.balanceOf(pool), 0, "no BINI reached the pool");
    }

    // ---------------------------------------------------------------------------------------------
    // ROW 8 — ALLOWANCE < REQUESTED: BINI allowance smaller than the amount the mint needs -> revert.
    // ---------------------------------------------------------------------------------------------
    function test_Row8_AllowanceLessThanRequested_MintReverts() public {
        (address t0, address t1) = _sorted(address(t), address(usd));
        address pool = IV3Factory(V3_FACTORY).createPool(address(t), address(usd), FEE_MID);
        IV3Pool(pool).initialize(SQRT_1_1);
        _approveInfra(pool);
        vm.prank(timelock);
        t.activateGuardedMode();

        vm.startPrank(genesis);
        t.approve(NPM, 1 ether); // far less than the ~200k BINI required
        usd.approve(NPM, type(uint256).max);
        vm.expectRevert(); // STF: allowance underflow in transferFrom
        INPM(NPM)
            .mint(
                INPM.MintParams({
                    token0: t0,
                    token1: t1,
                    fee: FEE_MID,
                    tickLower: _round(-6000, SPACING_MID),
                    tickUpper: _round(6000, SPACING_MID),
                    amount0Desired: 200_000 ether,
                    amount1Desired: 200_000 ether,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: genesis,
                    deadline: block.timestamp + 1
                })
            );
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------
    // ROW 9 — DEADLINE EXPIRY: mint with a past deadline reverts ("Transaction too old").
    // ---------------------------------------------------------------------------------------------
    function test_Row9_DeadlineExpiry_MintReverts() public {
        (address t0, address t1) = _sorted(address(t), address(usd));
        address pool = IV3Factory(V3_FACTORY).createPool(address(t), address(usd), FEE_MID);
        IV3Pool(pool).initialize(SQRT_1_1);
        _approveInfra(pool);
        vm.prank(timelock);
        t.activateGuardedMode();

        vm.startPrank(genesis);
        t.approve(NPM, type(uint256).max);
        usd.approve(NPM, type(uint256).max);
        vm.expectRevert(); // NPM checkDeadline: "Transaction too old"
        INPM(NPM)
            .mint(
                INPM.MintParams({
                    token0: t0,
                    token1: t1,
                    fee: FEE_MID,
                    tickLower: _round(-6000, SPACING_MID),
                    tickUpper: _round(6000, SPACING_MID),
                    amount0Desired: 200_000 ether,
                    amount1Desired: 200_000 ether,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: genesis,
                    deadline: block.timestamp - 1
                })
            );
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------
    // ROW 10 — SLIPPAGE FAILURE: swap with an impossibly high amountOutMinimum -> "Too little received".
    // ---------------------------------------------------------------------------------------------
    function test_Row10_SlippageSwap_Reverts() public {
        _approvedPoolWithLiquidity();

        vm.startPrank(genesis);
        usd.approve(ROUTER, type(uint256).max);
        vm.expectRevert(); // SwapRouter: "Too little received"
        ISwapRouter02(ROUTER)
            .exactInputSingle(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: address(usd),
                    tokenOut: address(t),
                    fee: FEE_MID,
                    recipient: genesis,
                    amountIn: 1_000 ether,
                    amountOutMinimum: 1_000_000_000 ether,
                    sqrtPriceLimitX96: 0
                })
            );
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------
    // ROW 11 — APPROVED SECOND FEE TIER (0.05%): create+init+endpoint+operators, mint works.
    // ---------------------------------------------------------------------------------------------
    function test_Row11_ApprovedSecondFeeTier_MintWorks() public {
        (address t0, address t1) = _sorted(address(t), address(usd));
        address pool = IV3Factory(V3_FACTORY).createPool(address(t), address(usd), FEE_LOW);
        IV3Pool(pool).initialize(SQRT_1_1);
        _approveInfra(pool); // pool approved as endpoint; NPM/Router as operators
        vm.prank(timelock);
        t.activateGuardedMode();

        vm.startPrank(genesis);
        t.approve(NPM, type(uint256).max);
        usd.approve(NPM, type(uint256).max);
        INPM(NPM)
            .mint(
                INPM.MintParams({
                    token0: t0,
                    token1: t1,
                    fee: FEE_LOW,
                    tickLower: _round(-6000, SPACING_LOW),
                    tickUpper: _round(6000, SPACING_LOW),
                    amount0Desired: 200_000 ether,
                    amount1Desired: 200_000 ether,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: genesis,
                    deadline: block.timestamp + 1
                })
            );
        vm.stopPrank();
        assertGt(t.balanceOf(pool), 0, "approved 0.05% pool holds BINI liquidity");
    }

    // ---------------------------------------------------------------------------------------------
    // ROW 12 — UNAPPROVED SECOND FEE TIER (1%): initialized but NOT an endpoint -> guard blocks mint.
    // ---------------------------------------------------------------------------------------------
    function test_Row12_UnapprovedSecondFeeTier_MintReverts() public {
        (address t0, address t1) = _sorted(address(t), address(usd));
        address pool = IV3Factory(V3_FACTORY).createPool(address(t), address(usd), FEE_HIGH);
        IV3Pool(pool).initialize(SQRT_1_1); // initialized, so the ONLY failure is the guard
        // Approve operators but deliberately NOT this pool as an endpoint.
        vm.startPrank(timelock);
        t.setOperators(_a(NPM), true);
        t.setOperators(_a(ROUTER), true);
        t.activateGuardedMode();
        vm.stopPrank();

        vm.startPrank(genesis);
        t.approve(NPM, type(uint256).max);
        usd.approve(NPM, type(uint256).max);
        vm.expectRevert(); // to=pool is class NONE -> bothApproved false -> TransferNotAllowed
        INPM(NPM)
            .mint(
                INPM.MintParams({
                    token0: t0,
                    token1: t1,
                    fee: FEE_HIGH,
                    tickLower: _round(-6000, SPACING_HIGH),
                    tickUpper: _round(6000, SPACING_HIGH),
                    amount0Desired: 200_000 ether,
                    amount1Desired: 200_000 ether,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: genesis,
                    deadline: block.timestamp + 1
                })
            );
        vm.stopPrank();
        assertEq(t.balanceOf(pool), 0, "unapproved fee-tier pool never receives BINI");
    }

    // ---------------------------------------------------------------------------------------------
    // ROW 13 — OPERATOR REVOCATION mid-life: revoke NPM operator, further increaseLiquidity is blocked.
    // ---------------------------------------------------------------------------------------------
    function test_Row13_OperatorRevocation_BlocksIncrease() public {
        (, uint256 tokenId,) = _approvedPoolWithLiquidity();

        // Sanity: increase works while NPM is still an approved operator.
        vm.prank(genesis);
        INPM(NPM)
            .increaseLiquidity(
                INPM.IncreaseLiquidityParams({
                    tokenId: tokenId,
                    amount0Desired: 10_000 ether,
                    amount1Desired: 10_000 ether,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp + 1
                })
            );

        // Revoke NPM as operator -> it can no longer feed the endpoint pool.
        vm.prank(timelock);
        t.setOperators(_a(NPM), false);
        assertFalse(t.isApprovedOperator(NPM), "NPM operator revoked");

        vm.prank(genesis);
        vm.expectRevert(); // to=pool endpoint requires approvedOperator[msg.sender]=NPM, now false
        INPM(NPM)
            .increaseLiquidity(
                INPM.IncreaseLiquidityParams({
                    tokenId: tokenId,
                    amount0Desired: 10_000 ether,
                    amount1Desired: 10_000 ether,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp + 1
                })
            );
    }

    // ---------------------------------------------------------------------------------------------
    // ROW 14 — PERMIT2 CHECK: the guarded launch path uses plain ERC-20 approve, never Permit2.
    // Structural proof: mint succeeds with a classic allowance to NPM, while genesis's Permit2 allowance
    // to NPM stays at ZERO the whole time (Permit2 is never granted, signed, or called).
    // ---------------------------------------------------------------------------------------------
    function test_Row14_NoPermit2Required() public {
        (address t0, address t1) = _sorted(address(t), address(usd));
        address pool = IV3Factory(V3_FACTORY).createPool(address(t), address(usd), FEE_MID);
        IV3Pool(pool).initialize(SQRT_1_1);
        _approveInfra(pool);
        vm.prank(timelock);
        t.activateGuardedMode();

        // Classic allowance path only. No approval is ever given to the Permit2 singleton.
        vm.startPrank(genesis);
        t.approve(NPM, type(uint256).max);
        usd.approve(NPM, type(uint256).max);
        INPM(NPM)
            .mint(
                INPM.MintParams({
                    token0: t0,
                    token1: t1,
                    fee: FEE_MID,
                    tickLower: _round(-6000, SPACING_MID),
                    tickUpper: _round(6000, SPACING_MID),
                    amount0Desired: 200_000 ether,
                    amount1Desired: 200_000 ether,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: genesis,
                    deadline: block.timestamp + 1
                })
            );
        vm.stopPrank();

        assertGt(t.balanceOf(pool), 0, "mint funded via plain ERC-20 approve");
        assertEq(t.allowance(genesis, PERMIT2), 0, "genesis never approved BINI to Permit2");
        assertEq(usd.allowance(genesis, PERMIT2), 0, "genesis never approved USD to Permit2");
    }
}
