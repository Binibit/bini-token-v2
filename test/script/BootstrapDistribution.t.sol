// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BootstrapDistribution} from "../../script/BootstrapDistribution.s.sol";

contract BootstrapDistributionTest is Test {
    function test_GeneratesExactSafeTransfer() public {
        address token = address(0xB111);
        address recipient = address(0xCAFE);
        uint256 amount = 42 ether;
        vm.setEnv("BINI_V2_PROXY", vm.toString(token));
        vm.setEnv("DISTRIBUTION_RECIPIENT", vm.toString(recipient));
        vm.setEnv("DISTRIBUTION_RAW_AMOUNT", vm.toString(amount));

        (address target, uint256 value, bytes memory data) = new BootstrapDistribution().run();
        assertEq(target, token);
        assertEq(value, 0);
        assertEq(data, abi.encodeCall(IERC20.transfer, (recipient, amount)));
    }
}
