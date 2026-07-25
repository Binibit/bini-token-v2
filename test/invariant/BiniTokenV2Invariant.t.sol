// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BiniTokenV2} from "../../src/BiniTokenV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ActorContract, MockV2Factory} from "../mocks/MarketMocks.sol";

contract MarketHandler is Test {
    BiniTokenV2 public token;
    address public timelock;
    address[] public actors;
    address public v2Pair;
    address public infrastructure;
    bool public everOpened;
    bool public preMarketDexTransferSucceeded;

    constructor(
        BiniTokenV2 token_,
        address timelock_,
        address[] memory actors_,
        address v2Pair_,
        address infrastructure_
    ) {
        token = token_;
        timelock = timelock_;
        actors = actors_;
        v2Pair = v2Pair_;
        infrastructure = infrastructure_;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 balance = token.balanceOf(from);
        if (balance == 0) return;
        vm.prank(from);
        token.transfer(to, bound(amount, 0, balance));
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 balance = token.balanceOf(owner);
        if (balance == 0) return;
        amount = bound(amount, 0, balance);
        vm.prank(owner);
        token.approve(spender, amount);
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
    }

    function transferToV2Pair(uint256 fromSeed, uint256 amount) external {
        _transferToDex(actors[fromSeed % actors.length], v2Pair, amount);
    }

    function transferToInfrastructure(uint256 fromSeed, uint256 amount) external {
        _transferToDex(actors[fromSeed % actors.length], infrastructure, amount);
    }

    function openMarket() external {
        vm.prank(timelock);
        try token.openMarket() {
            everOpened = true;
        } catch {}
    }

    function _transferToDex(address from, address destination, uint256 amount) private {
        uint256 balance = token.balanceOf(from);
        if (balance == 0) return;
        amount = bound(amount, 0, balance);
        bool wasPreMarket = !token.marketOpen();
        vm.prank(from);
        try token.transfer(destination, amount) {
            if (wasPreMarket && amount != 0) preMarketDexTransferSucceeded = true;
        } catch {}
    }
}

contract BiniTokenV2InvariantTest is Test {
    BiniTokenV2 internal token;
    MarketHandler internal handler;
    MockV2Factory internal v2Factory;
    address[] internal actors;

    address internal timelock;
    address internal pauser;
    address internal genesis;
    address internal v2Pair;
    address internal infrastructure;

    uint256 internal constant MAX = 1_000_000_000 ether;

    function setUp() public {
        timelock = address(new ActorContract());
        pauser = address(new ActorContract());
        genesis = address(new ActorContract());
        infrastructure = address(new ActorContract());

        BiniTokenV2 impl = new BiniTokenV2();
        token = BiniTokenV2(
            address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(BiniTokenV2.initialize, (timelock, pauser, genesis, uint48(3 days)))
                )
            )
        );

        v2Factory = new MockV2Factory();
        v2Pair = v2Factory.createPair(address(token), address(0xC01));
        vm.startPrank(timelock);
        token.setDexFactory(address(v2Factory), BiniTokenV2.FactoryKind.UNISWAP_V2);
        address[] memory infrastructureAccounts = new address[](1);
        infrastructureAccounts[0] = infrastructure;
        token.setMarketInfrastructure(infrastructureAccounts, true);
        vm.stopPrank();

        actors.push(genesis);
        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCA401));
        handler = new MarketHandler(token, timelock, actors, v2Pair, infrastructure);
        targetContract(address(handler));
    }

    function invariant_TotalSupplyAndCapAreFixed() public view {
        assertEq(token.totalSupply(), MAX);
        assertEq(token.cap(), MAX);
    }

    function invariant_BalancesAreConserved() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            sum += token.balanceOf(actors[i]);
        }
        sum += token.balanceOf(v2Pair);
        sum += token.balanceOf(infrastructure);
        assertEq(sum, MAX);
    }

    function invariant_PreMarketDexDestinationsRemainEmpty() public view {
        if (!token.marketOpen()) {
            assertEq(token.balanceOf(v2Pair), 0);
            assertEq(token.balanceOf(infrastructure), 0);
            assertFalse(handler.preMarketDexTransferSucceeded());
        }
    }

    function invariant_OpenMarketIsMonotonicAndPermissionless() public view {
        if (handler.everOpened()) {
            assertTrue(token.marketOpen());
            assertFalse(token.isBlockedDexDestination(v2Pair));
            assertFalse(token.isBlockedDexDestination(infrastructure));
        }
    }

    function invariant_GovernanceConfigurationIsStable() public view {
        assertEq(uint256(token.dexFactoryKind(address(v2Factory))), uint256(BiniTokenV2.FactoryKind.UNISWAP_V2));
        assertTrue(token.isMarketInfrastructure(infrastructure));
        assertTrue(token.hasRole(token.MARKET_MANAGER_ROLE(), timelock));
        assertTrue(token.hasRole(token.UPGRADER_ROLE(), timelock));
    }
}
