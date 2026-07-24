// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BiniTokenV2} from "../../src/BiniTokenV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MarketHandler is Test {
    BiniTokenV2 public token;
    address public timelock;
    address[] public actors;
    bool public everOpened;

    constructor(BiniTokenV2 token_, address timelock_, address[] memory actors_) {
        token = token_;
        timelock = timelock_;
        actors = actors_;
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

    function openMarket() external {
        vm.prank(timelock);
        try token.openMarket() {
            everOpened = true;
        } catch {}
    }
}

contract BiniTokenV2InvariantTest is Test {
    BiniTokenV2 internal token;
    MarketHandler internal handler;
    address[] internal actors;

    address internal timelock = address(0x700);
    address internal pauser = address(0x701);
    address internal genesis = address(0x703);

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

        actors.push(genesis);
        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCA401));
        handler = new MarketHandler(token, timelock, actors);
        targetContract(address(handler));
    }

    function invariant_TotalSupplyIsFixed() public view {
        assertEq(token.totalSupply(), MAX);
        assertEq(token.cap(), MAX);
    }

    function invariant_BalancesAreConserved() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, MAX);
    }

    function invariant_OpenMarketIsMonotonic() public view {
        if (handler.everOpened()) assertTrue(token.marketOpen());
    }
}
