// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BiniTokenV2} from "../../src/BiniTokenV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IV2Factory {
    function createPair(address, address) external returns (address);
}

interface IV2Pair {
    function mint(address to) external returns (uint256 liquidity);
    function getReserves() external view returns (uint112, uint112, uint32);
}

contract MockUSD is ERC20 {
    constructor() ERC20("MockUSD", "mUSD") {
        _mint(msg.sender, 1_000_000 ether);
    }
}

/// MC-1 V2 enforcement PoC — REAL mainnet-fork against the deployed Uniswap V2 factory.
/// Demonstrates the CORRECTED epistemics with executed evidence:
///  (1) pre-launch, the role guard blocks a NORMAL holder from funding ANY V2 pair (rogue or not);
///  (2) the BOOTSTRAP_OPERATOR can seed an official pair;
///  (3) AFTER finalizeLaunch, a free ERC-20 CANNOT stop a holder funding a rogue pair
///      (— exactly why permanent control needs a permanent guard, not a launch guard).
contract V2PolicyForkTest is Test {
    address constant V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f; // Uniswap V2 (mainnet)

    BiniTokenV2 internal bini;
    MockUSD internal usd;
    address internal timelock = address(0x700);
    address internal pauser = address(0x701);
    address internal unpauser = address(0x702);
    address internal genesis = address(0x703); // BOOTSTRAP_OPERATOR + supply
    address internal alice = address(0xA11CE); // ordinary holder

    function setUp() public {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com"); // latest block (archive-gated for pinned)
        BiniTokenV2 impl = new BiniTokenV2();
        bini = BiniTokenV2(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(BiniTokenV2.initialize, (timelock, pauser, unpauser, genesis, uint48(3 days)))
                )
            )
        );
        vm.prank(genesis);
        usd = new MockUSD();
    }

    function _pair(address a, address b) internal returns (address) {
        return IV2Factory(V2_FACTORY).createPair(a, b);
    }

    // (2) operator seeds an OFFICIAL pair on the real factory
    function test_Operator_Can_Seed_Official_Pair() public {
        address pair = _pair(address(bini), address(usd));
        vm.startPrank(genesis); // genesis holds BOOTSTRAP_OPERATOR
        bini.transfer(pair, 100_000 ether);
        usd.transfer(pair, 100_000 ether);
        vm.stopPrank();
        IV2Pair(pair).mint(genesis);
        assertEq(bini.balanceOf(pair), 100_000 ether);
    }

    // (1) pre-launch, a normal holder CANNOT fund a rogue pair — the guard blocks it on real Uniswap
    function test_PreLaunch_Holder_Cannot_Fund_RoguePair() public {
        vm.prank(genesis);
        bini.transfer(alice, 50_000 ether); // from=operator → allowed; alice now holds BINI
        address rogue = _pair(address(bini), address(usd));
        vm.prank(alice);
        vm.expectRevert(BiniTokenV2.LaunchNotFinalized.selector);
        bini.transfer(rogue, 1_000 ether); // from=alice (not operator), pre-launch → blocked
    }

    // (3) AFTER finalizeLaunch, the free ERC-20 CANNOT stop a holder funding a rogue pair
    function test_PostLaunch_Holder_Can_Fund_RoguePair() public {
        vm.prank(genesis);
        bini.transfer(alice, 50_000 ether);
        vm.prank(timelock);
        bini.finalizeLaunch();
        address rogue = _pair(address(bini), address(usd));
        vm.prank(alice);
        bini.transfer(rogue, 1_000 ether); // succeeds — no permanent guard; this is the corrected claim
        assertEq(bini.balanceOf(rogue), 1_000 ether);
    }
}
