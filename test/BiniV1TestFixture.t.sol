// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BiniV1TestFixture} from "../src/fixtures/BiniV1TestFixture.sol";

contract BiniV1TestFixtureTest is Test {
    function test_IsExplicitTwelveDecimalFixture() external {
        BiniV1TestFixture fixture = new BiniV1TestFixture(address(this));
        assertEq(fixture.name(), "BINI V1 Test Fixture");
        assertEq(fixture.symbol(), "BINI-V1-TEST");
        assertEq(fixture.decimals(), 12);
        fixture.mintFixture(address(0xBEEF), 5_000_000_000_000);
        assertEq(fixture.balanceOf(address(0xBEEF)), 5_000_000_000_000);
    }

    function test_RejectsUnauthorizedFixtureMint() external {
        BiniV1TestFixture fixture = new BiniV1TestFixture(address(this));
        vm.prank(address(0xBAD));
        vm.expectRevert(BiniV1TestFixture.NotFixtureAdmin.selector);
        fixture.mintFixture(address(0xBEEF), 1);
    }
}
