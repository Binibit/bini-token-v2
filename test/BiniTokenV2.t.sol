// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BiniTokenV2} from "../src/BiniTokenV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {
    ActorContract,
    Create2V2Factory,
    EIP7702DelegateLike,
    ERC4337AccountLike,
    GasGriefV2Factory,
    MockV2Factory,
    MockV2Pool,
    MockV3Factory,
    ProxyWalletImplementation,
    ReturnBombV2Factory,
    ReturnBombV2Pool,
    RevertingV2Factory,
    RevertingProbeWallet,
    SafeLikeWallet,
    ShortReturnV2Factory
} from "./mocks/MarketMocks.sol";

contract BiniTokenV2Test is Test {
    BiniTokenV2 internal token;

    address internal timelock;
    address internal pauser;
    address internal genesis;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal otherToken = address(0xC01);

    uint256 internal constant MAX = 1_000_000_000 ether;

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

    function test_InitializeRejectsEoaGovernanceAddresses() public {
        BiniTokenV2 impl = new BiniTokenV2();
        vm.expectRevert(abi.encodeWithSelector(BiniTokenV2.NotContract.selector, alice));
        new ERC1967Proxy(
            address(impl), abi.encodeCall(BiniTokenV2.initialize, (alice, pauser, genesis, uint48(3 days)))
        );

        vm.expectRevert(abi.encodeWithSelector(BiniTokenV2.NotContract.selector, alice));
        new ERC1967Proxy(
            address(impl), abi.encodeCall(BiniTokenV2.initialize, (timelock, alice, genesis, uint48(3 days)))
        );

        vm.expectRevert(abi.encodeWithSelector(BiniTokenV2.NotContract.selector, alice));
        new ERC1967Proxy(
            address(impl), abi.encodeCall(BiniTokenV2.initialize, (timelock, pauser, alice, uint48(3 days)))
        );
    }

    function test_PreMarketWalletToWalletIsFree() public {
        vm.prank(alice);
        token.transfer(bob, 123 ether);
        assertEq(token.balanceOf(bob), 123 ether);
    }

    function test_PreMarketWalletToContractWalletIsFree() public {
        ActorContract safe = new ActorContract();
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

    function test_PreMarketOrdinarySafeProxyAnd4337AccountsAreFree() public {
        SafeLikeWallet safe = new SafeLikeWallet();
        ProxyWalletImplementation walletImplementation = new ProxyWalletImplementation();
        ERC1967Proxy proxyWallet =
            new ERC1967Proxy(address(walletImplementation), abi.encodeCall(ProxyWalletImplementation.initialize, ()));
        ERC4337AccountLike account4337 = new ERC4337AccountLike();

        vm.startPrank(alice);
        token.transfer(address(safe), 1 ether);
        token.transfer(address(proxyWallet), 2 ether);
        token.transfer(address(account4337), 3 ether);
        vm.stopPrank();

        assertEq(token.balanceOf(address(safe)), 1 ether);
        assertEq(token.balanceOf(address(proxyWallet)), 2 ether);
        assertEq(token.balanceOf(address(account4337)), 3 ether);
    }

    function test_PreMarketEip7702StyleProgrammableAccountAssumptionIsFree() public {
        address delegatedAccount = address(0x7702);
        EIP7702DelegateLike delegate = new EIP7702DelegateLike();
        vm.etch(delegatedAccount, address(delegate).code);

        vm.prank(alice);
        token.transfer(delegatedAccount, 1 ether);
        assertEq(token.balanceOf(delegatedAccount), 1 ether);
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

    function test_ExpiredPermitIsRejected() public {
        uint256 deadline = block.timestamp - 1;
        vm.expectRevert(abi.encodeWithSelector(ERC20PermitUpgradeable.ERC2612ExpiredSignature.selector, deadline));
        token.permit(alice, bob, 1 ether, deadline, 27, bytes32(0), bytes32(0));
    }

    function test_PermitCannotBeReplayed() public {
        uint256 ownerKey = 0xA11CE5EED;
        address owner = vm.addr(ownerKey);
        uint256 deadline = block.timestamp + 1 days;
        bytes32 typehash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash = keccak256(abi.encode(typehash, owner, bob, 42 ether, 0, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);

        token.permit(owner, bob, 42 ether, deadline, v, r, s);
        vm.expectRevert();
        token.permit(owner, bob, 42 ether, deadline, v, r, s);
        assertEq(token.nonces(owner), 1);
    }

    function test_ExplicitInfrastructureBlockedPreMarket() public {
        address poolManager = address(new ActorContract());
        vm.prank(timelock);
        token.setMarketInfrastructure(_one(poolManager), true);

        vm.expectRevert(abi.encodeWithSelector(BiniTokenV2.DexMarketClosed.selector, poolManager));
        vm.prank(alice);
        token.transfer(poolManager, 1 ether);
    }

    function test_ExplicitInfrastructureBlockedThroughTransferFrom() public {
        address liquidityManager = address(new ActorContract());
        vm.prank(timelock);
        token.setMarketInfrastructure(_one(liquidityManager), true);
        vm.prank(alice);
        token.approve(bob, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(BiniTokenV2.DexMarketClosed.selector, liquidityManager));
        vm.prank(bob);
        token.transferFrom(alice, liquidityManager, 1 ether);
    }

    function test_ExplicitInfrastructureCanBeRemovedPreMarket() public {
        address custodyMistake = address(new ActorContract());
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

    function test_ZeroAddressConfigurationIsRejectedAtomically() public {
        address validManager = address(new ActorContract());
        address[] memory accounts = new address[](2);
        accounts[0] = validManager;
        accounts[1] = address(0);

        vm.expectRevert(BiniTokenV2.ZeroAddress.selector);
        vm.prank(timelock);
        token.setMarketInfrastructure(accounts, true);
        assertFalse(token.isMarketInfrastructure(validManager));

        vm.expectRevert(BiniTokenV2.ZeroAddress.selector);
        vm.prank(timelock);
        token.setDexFactory(address(0), BiniTokenV2.FactoryKind.UNISWAP_V2);
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

    function test_FactoryCanBeRemovedBeforeMarketOpen() public {
        MockV2Factory factory = new MockV2Factory();
        address pair = factory.createPair(address(token), otherToken);
        vm.startPrank(timelock);
        token.setDexFactory(address(factory), BiniTokenV2.FactoryKind.UNISWAP_V2);
        token.setDexFactory(address(factory), BiniTokenV2.FactoryKind.NONE);
        vm.stopPrank();

        assertFalse(token.isRecognizedDexPool(pair));
        vm.prank(alice);
        token.transfer(pair, 1 ether);
    }

    function test_RegisteredFactoryPoolWithoutBiniIsNotBlocked() public {
        MockV2Factory factory = new MockV2Factory();
        address pair = factory.createPair(address(0xC02), otherToken);
        vm.prank(timelock);
        token.setDexFactory(address(factory), BiniTokenV2.FactoryKind.UNISWAP_V2);

        assertFalse(token.isRecognizedDexPool(pair));
        vm.prank(alice);
        token.transfer(pair, 1 ether);
    }

    function test_V3FactoryDoesNotMisclassifyPoolWithoutFeeGetter() public {
        MockV2Factory poolDeployer = new MockV2Factory();
        address pair = poolDeployer.createPair(address(token), otherToken);
        vm.prank(timelock);
        token.setDexFactory(address(poolDeployer), BiniTokenV2.FactoryKind.UNISWAP_V3);

        assertFalse(token.isRecognizedDexPool(pair));
        vm.prank(alice);
        token.transfer(pair, 1 ether);
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

    function test_ReturnBombFactoryCannotDenialOfServicePoolDetection() public {
        ReturnBombV2Factory factory = new ReturnBombV2Factory();
        ReturnBombV2Pool pair = new ReturnBombV2Pool(address(factory), address(token), otherToken);
        factory.setPair(address(pair));
        vm.prank(timelock);
        token.setDexFactory(address(factory), BiniTokenV2.FactoryKind.UNISWAP_V2);

        assertTrue(token.isRecognizedDexPool(address(pair)));
        vm.expectRevert(abi.encodeWithSelector(BiniTokenV2.DexMarketClosed.selector, address(pair)));
        vm.prank(alice);
        token.transfer(address(pair), 1 ether);
    }

    function test_ShortFactoryReturnDoesNotBreakOrdinaryTransfer() public {
        ShortReturnV2Factory factory = new ShortReturnV2Factory();
        ReturnBombV2Pool pair = new ReturnBombV2Pool(address(factory), address(token), otherToken);
        vm.prank(timelock);
        token.setDexFactory(address(factory), BiniTokenV2.FactoryKind.UNISWAP_V2);

        assertFalse(token.isRecognizedDexPool(address(pair)));
        vm.prank(alice);
        token.transfer(address(pair), 1 ether);
        assertEq(token.balanceOf(address(pair)), 1 ether);
    }

    function test_RevertingFactoryCannotDenialOfServiceOrdinaryTransfer() public {
        RevertingV2Factory factory = new RevertingV2Factory();
        ReturnBombV2Pool pair = new ReturnBombV2Pool(address(factory), address(token), otherToken);
        vm.prank(timelock);
        token.setDexFactory(address(factory), BiniTokenV2.FactoryKind.UNISWAP_V2);

        assertFalse(token.isRecognizedDexPool(address(pair)));
        vm.prank(alice);
        token.transfer(address(pair), 1 ether);
        assertEq(token.balanceOf(address(pair)), 1 ether);
    }

    function test_GasGriefFactoryIsBoundedAndCannotDenialOfServiceOrdinaryTransfer() public {
        GasGriefV2Factory factory = new GasGriefV2Factory();
        ReturnBombV2Pool pair = new ReturnBombV2Pool(address(factory), address(token), otherToken);
        vm.prank(timelock);
        token.setDexFactory(address(factory), BiniTokenV2.FactoryKind.UNISWAP_V2);

        uint256 gasBefore = gasleft();
        vm.prank(alice);
        token.transfer(address(pair), 1 ether);
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 150_000);
        assertEq(token.balanceOf(address(pair)), 1 ether);
    }

    function test_PreFundedFutureCreate2PoolIsDisclosedBoundary() public {
        Create2V2Factory factory = new Create2V2Factory();
        bytes32 salt = keccak256("BINI_FUTURE_POOL");
        address futurePair = factory.predictedPair(address(token), otherToken, salt);
        vm.prank(timelock);
        token.setDexFactory(address(factory), BiniTokenV2.FactoryKind.UNISWAP_V2);

        assertEq(futurePair.code.length, 0);
        vm.prank(alice);
        token.transfer(futurePair, 1 ether);

        address deployedPair = factory.createPair(address(token), otherToken, salt);
        assertEq(deployedPair, futurePair);
        assertTrue(token.isRecognizedDexPool(deployedPair));
        assertEq(token.balanceOf(deployedPair), 1 ether);

        vm.expectRevert(abi.encodeWithSelector(BiniTokenV2.DexMarketClosed.selector, deployedPair));
        vm.prank(alice);
        token.transfer(deployedPair, 1 ether);
    }

    function test_UnknownCustomAmmBypassIsExplicitlyOutsideSupportedBoundary() public {
        MockV2Factory unknownFactory = new MockV2Factory();
        address customPool = unknownFactory.createPair(address(token), otherToken);

        vm.prank(alice);
        token.transfer(customPool, 1 ether);
        assertEq(token.balanceOf(customPool), 1 ether);
        assertFalse(token.isBlockedDexDestination(customPool));
    }

    function test_RevertingContractProbeRemainsFreelyTransferable() public {
        RevertingProbeWallet wallet = new RevertingProbeWallet();
        vm.prank(alice);
        token.transfer(address(wallet), 1 ether);
        assertEq(token.balanceOf(address(wallet)), 1 ether);
    }

    function test_OnlyMarketManagerCanConfigureOrOpen() public {
        address manager = address(new ActorContract());
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
        address poolManager = address(new ActorContract());
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

        vm.expectRevert(BiniTokenV2.MarketAlreadyOpen.selector);
        vm.prank(timelock);
        token.setDexFactory(poolManager, BiniTokenV2.FactoryKind.UNISWAP_V2);
    }

    function test_OpenMarketPreservesBalancesAllowancesPermitNoncesSupplyAndPause() public {
        uint256 ownerKey = 0xB1A1;
        address owner = vm.addr(ownerKey);
        uint256 deadline = block.timestamp + 1 days;
        bytes32 typehash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash = keccak256(abi.encode(typehash, owner, bob, 7 ether, 0, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);
        token.permit(owner, bob, 7 ether, deadline, v, r, s);

        vm.prank(alice);
        token.approve(bob, 11 ether);
        vm.prank(pauser);
        token.pause();
        uint256 aliceBalance = token.balanceOf(alice);
        uint256 supply = token.totalSupply();

        vm.prank(timelock);
        token.openMarket();

        assertEq(token.balanceOf(alice), aliceBalance);
        assertEq(token.allowance(alice, bob), 11 ether);
        assertEq(token.allowance(owner, bob), 7 ether);
        assertEq(token.nonces(owner), 1);
        assertEq(token.totalSupply(), supply);
        assertTrue(token.paused());
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
        address poolManager = address(new ActorContract());
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

    function test_ApprovalsRemainAvailableWhileTransfersArePaused() public {
        vm.prank(pauser);
        token.pause();
        vm.prank(alice);
        token.approve(bob, 1 ether);
        assertEq(token.allowance(alice, bob), 1 ether);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(bob);
        token.transferFrom(alice, genesis, 1 ether);
    }

    function test_TransferToZeroAddressUsesStandardErc20Error() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(alice);
        token.transfer(address(0), 1 ether);
    }

    function test_NoRuntimeMintOrBurnSurface() public {
        (bool mintOk,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", alice, 1 ether));
        (bool burnOk,) = address(token).call(abi.encodeWithSignature("burn(uint256)", 1 ether));
        assertFalse(mintOk);
        assertFalse(burnOk);
        assertEq(token.totalSupply(), MAX);
    }
}
