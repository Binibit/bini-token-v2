// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 *  @notice Produces one Safe-compatible ERC-20 transfer transaction. It never broadcasts.
 */
contract BootstrapDistribution is Script {
    function run() external view returns (address target, uint256 value, bytes memory data) {
        target = vm.envAddress("BINI_V2_PROXY");
        address recipient = vm.envAddress("DISTRIBUTION_RECIPIENT");
        uint256 amount = vm.envUint("DISTRIBUTION_RAW_AMOUNT");
        require(recipient != address(0) && amount != 0, "INVALID_DISTRIBUTION");
        value = 0;
        data = abi.encodeCall(IERC20.transfer, (recipient, amount));
    }
}
