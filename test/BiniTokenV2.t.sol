// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BiniTokenV2} from "../src/BiniTokenV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract PlainContractWallet {}

contract MockV2Pool {
    address public immutable factory;
    address public immutable token0;
    address public immutable token1;

    constructor(address tokenA, address tokenB) {
        factory = msg.sender;
        token0 = tokenA;
        token1 = tokenB;
    }
}

contract MockV2Factory {
    mapping(address => mapping(address => address)) public getPair;

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        pair = address(new MockV2Pool(tokenA, tokenB));
        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
    }
}

contract MockV3Pool {
    address public immutable factory;
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;

    constructor(address tokenA, address tokenB, uint24 poolFee) {
        factory = msg.sender;
        token0 = tokenA;
        token1 = tokenB;
        fee = poolFee;
    }
}

contract MockV3Factory {
    mapping(address => mapping(address => mapping(uint24 => address))) public getPool;

    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool) {
        pool = address(new MockV3Pool(tokenA, tokenB, fee));
        getPool[tokenA][tokenB][fee] = pool;
        getPool[tokenB][tokenA][fee] = pool;
    }
}

contract BiniTokenV2Test is Test {
    BiniTokenV2 internal token;

    address internal timelock = address(0x700);
    address internal pauser = address(0x701);
    address internal genesis = address(0x703);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal otherToken = address(0xC01);

    uint256 internal constant MAX = 1_000_000_000 ether;

    function setUp() public {
        BiniTokenV2 impl = new BiniTokenV2();
        token = BiniTokenV2(
            address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(BiniTokenV2.initialize, (timelock, pauser, genesis, uint48(3 days)))
                )
            )
        );
        vm.prank(genesis);
        token.transfer(alice, 10_000 ether);
    }

    function _one(address account) internal pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }

    function test_MetadataAndFixedSupply() public view {
        assertEq(token.name(), "Binibit");
        assertEq(token.symbol(), "BINI");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), MAX);
        assertEq(token.cap(), MAX);
        assertEq(token.balanceOf(genesis) + token.balanceOf(alice), MAX);
    }

    function test_InitialStateAndRoles() public view {
        assertEq(uint256(token.marketState()), uint256(BiniTokenV2.MarketState.PRE_MARKET));
        assertFalse(token.marketOpen());
        assertEq(token.defaultAdmin(), timelock);
        assertTrue(token.hasRole(token.UPGRADER_ROLE(), timelock));
        assertTrue(token.hasRole(token.MARKET_MANAGER_ROLE(), timelock));
        assertTrue(token.hasRole(token.UNPAUSER_ROLE(), timelock));
        assertTrue(token.hasRole(token.PAUSER_ROLE(), pauser));
    }

    function test_ImplementationAndProxyCannotReinitialize() public {
        BiniTokenV2 impl = new BiniTokenV2();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(timelock, pauser, genesis, uint48(3 days));

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        token.initialize(timelock, pauser, genesis, uint48(3 days));
    }

    function test_InitializeRejectsZeroAddress() public {
        BiniTokenV2 impl = new BiniTokenV2();
        bytes memory data = abi.encodeCall(BiniTokenV2.initialize, (address(0), pauser, genesis, uint48(3 days)));
        vm.expectRevert(BiniTokenV2.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), data);
    }

    function test_PreMarketWalletToWalletIsFree() public {
        vm.prank(alice);
        token.transfer(bob, 123 ether);
        assertEq(token.balanceOf(bob), 123 ether);
    }

    function test_PreMarketWalletToContractWalletIsFree() public {
        PlainContractWallet safe = new PlainContractWallet();
        vm.prank(alice);
        token.transfer(address(safe), 123 ether);
        assertEq(token.balanceOf(address(safe)), 123 ether);
    }

    function test_PreMarketTransferFromUsesStandardApprovalOnly() public {
        vm.prank(alice);
        token.approve(bob, 55 ether);
        vm.prank(bob);
        token.transferFrom(alice, genesis, 55 ether);
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_PermitUsesStandardEip2612Flow() public {
        uint256 ownerKey = 0xA11CE5EED;
        address owner = vm.addr(ownerKey);
        uint256 deadline = block.timestamp + 1 days;
        bytes32 typehash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash = keccak256(abi.encode(typehash, owner, bob, 42 ether, 0, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);

        token.permit(owner, bob, 42 ether, deadline, v, r, s);
        assertEq(token.allowance(owner, bob), 42 ether);
        assertEq(token.nonces(owner), 1);
    }

    function test_ExplicitInfrastructureBlockedPreMarket() public {
        address poolManager = address(new PlainContractWallet());
        vm.prank(timelock);
        token.setMarketInfrastructure(_one(poolManager), true);

        vm.expectRevert(abi.encodeWithSelector(BiniTokenV2.DexMarketClosed.selector, poolManager));
        vm.prank(alice);
        token.transfer(poolManager, 1 ether);
    }

    function test_ExplicitInfrastructureBlockedThroughTransferFrom() public {
        address liquidityManager = address(new PlainContractWallet());
        vm.prank(timelock);
        token.setMarketInfrastructure(_one(liquidityManager), true);
        vm.prank(alice);
        token.approve(bob, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(BiniTokenV2.DexMarketClosed.selector, liquidityManager));
        vm.prank(bob);
        token.transferFrom(alice, liquidityManager, 1 ether);
    }

    function test_ExplicitInfrastructureCanBeRemovedPreMarket() public {
        address custodyMistake = address(new PlainContractWallet());
        vm.startPrank(timelock);
        token.setMarketInfrastructure(_one(custodyMistake), true);
        token.setMarketInfrastructure(_one(custodyMistake), false);
        vm.stopPrank();

        vm.prank(alice);
        token.transfer(custodyMistake, 1 ether);
        assertEq(token.balanceOf(custodyMistake), 1 ether);
    }

    function test_EoaCannotBeAddedAsMarketInfrastructureOrFactory() public {
        vm.expectRevert(abi.encodeWithSelector(BiniTokenV2.NotContract.selector, bob));
        vm.prank(timelock);
        token.setMarketInfrastructure(_one(bob), true);

        vm.expectRevert(abi.encodeWithSelector(BiniTokenV2.NotContract.selector, bob));
        vm.prank(timelock);
        token.setDexFactory(bob, BiniTokenV2.FactoryKind.UNISWAP_V2);
    }

    function test_RegisteredV2FactoryPoolAutomaticallyBlocked() public {
        MockV2Factory factory = new MockV2Factory();
        address pair = factory.createPair(address(token), otherToken);

        vm.prank(timelock);
        token.setDexFactory(address(factory), BiniTokenV2.FactoryKind.UNISWAP_V2);

        assertTrue(token.isRecognizedDexPool(pair));
        vm.expectRevert(abi.encodeWithSelector(BiniTokenV2.DexMarketClosed.selector, pair));
        vm.prank(alice);
        token.transfer(pair, 1 ether);
    }

    function test_RegisteredV3FactoryPoolAutomaticallyBlocked() public {
        MockV3Factory factory = new MockV3Factory();
        address pool = factory.createPool(address(token), otherToken, 3000);

        vm.prank(timelock);
        token.setDexFactory(address(factory), BiniTokenV2.FactoryKind.UNISWAP_V3);

        assertTrue(token.isRecognizedDexPool(pool));
        vm.expectRevert(abi.encodeWithSelector(BiniTokenV2.DexMarketClosed.selector, pool));
        vm.prank(alice);
        token.transfer(pool, 1 ether);
    }

    function test_UnknownFactoryPoolRemainsOrdinaryContract() public {
        MockV2Factory factory = new MockV2Factory();
        address pool = factory.createPair(address(token), otherToken);

        assertFalse(token.isRecognizedDexPool(pool));
        vm.prank(alice);
        token.transfer(pool, 1 ether);
        assertEq(token.balanceOf(pool), 1 ether);
    }

    function test_PoolLookalikeNotConfirmedByFactoryIsAllowed() public {
        MockV2Factory factory = new MockV2Factory();
        MockV2Pool lookalike = new MockV2Pool(address(token), otherToken);
        vm.prank(timelock);
        token.setDexFactory(address(factory), BiniTokenV2.FactoryKind.UNISWAP_V2);

        assertFalse(token.isRecognizedDexPool(address(lookalike)));
        vm.prank(alice);
        token.transfer(address(lookalike), 1 ether);
    }

    function test_OnlyMarketManagerCanConfigureOrOpen() public {
        address manager = address(new PlainContractWallet());
        bytes memory unauthorized = abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, alice, token.MARKET_MANAGER_ROLE()
        );
        vm.expectRevert(unauthorized);
        vm.prank(alice);
        token.setMarketInfrastructure(_one(manager), true);

        vm.expectRevert(unauthorized);
        vm.prank(alice);
        token.openMarket();
    }

    function test_OpenMarketIsIrreversibleAndDisablesAllDexChecks() public {
        address poolManager = address(new PlainContractWallet());
        vm.prank(timelock);
        token.setMarketInfrastructure(_one(poolManager), true);
        vm.prank(timelock);
        token.openMarket();

        assertTrue(token.marketOpen());
        assertFalse(token.isBlockedDexDestination(poolManager));
        vm.prank(alice);
        token.transfer(poolManager, 1 ether);

        vm.expectRevert(BiniTokenV2.MarketAlreadyOpen.selector);
        vm.prank(timelock);
        token.openMarket();

        vm.expectRevert(BiniTokenV2.MarketAlreadyOpen.selector);
        vm.prank(timelock);
        token.setMarketInfrastructure(_one(poolManager), false);
    }

    function test_MarketStateUsesDocumentedErc7201Slot() public {
        bytes32 expected =
            keccak256(abi.encode(uint256(keccak256("binibit.storage.BiniTokenV2")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(expected, 0xb919b0c0062827d20ad4293e3018837a27a74d3431061c198bdaffa48b665b00);
        assertEq(vm.load(address(token), expected), bytes32(0));

        vm.prank(timelock);
        token.openMarket();
        assertEq(vm.load(address(token), expected), bytes32(uint256(1)));
        assertEq(vm.load(address(token), bytes32(0)), bytes32(0));
    }

    function test_PauseIsIndependentAndTakesPrecedence() public {
        address poolManager = address(new PlainContractWallet());
        vm.prank(timelock);
        token.setMarketInfrastructure(_one(poolManager), true);
        vm.prank(pauser);
        token.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(alice);
        token.transfer(poolManager, 1 ether);

        vm.prank(timelock);
        token.openMarket();
        vm.prank(timelock);
        token.unpause();
        vm.prank(alice);
        token.transfer(poolManager, 1 ether);
    }

    function test_NoRuntimeMintOrBurnSurface() public {
        (bool mintOk,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", alice, 1 ether));
        (bool burnOk,) = address(token).call(abi.encodeWithSignature("burn(uint256)", 1 ether));
        assertFalse(mintOk);
        assertFalse(burnOk);
        assertEq(token.totalSupply(), MAX);
    }
}
