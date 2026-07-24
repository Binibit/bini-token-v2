// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {BiniTokenV2} from "../src/BiniTokenV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployBiniTokenV2 is Script {
    function run() external returns (BiniTokenV2 implementation, BiniTokenV2 token) {
        address adminTimelock = vm.envAddress("ADMIN_TIMELOCK");
        address emergencyPauserSafe = vm.envAddress("EMERGENCY_PAUSER_SAFE");
        address genesisDistributionSafe = vm.envAddress("GENESIS_DISTRIBUTION_SAFE");
        uint256 rawAdminTransferDelay = vm.envUint("ADMIN_TRANSFER_DELAY");
        require(rawAdminTransferDelay <= type(uint48).max, "ADMIN_TRANSFER_DELAY_OVERFLOW");
        uint48 adminTransferDelay = uint48(rawAdminTransferDelay);

        vm.startBroadcast();
        implementation = new BiniTokenV2();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                BiniTokenV2.initialize,
                (adminTimelock, emergencyPauserSafe, genesisDistributionSafe, adminTransferDelay)
            )
        );
        vm.stopBroadcast();

        token = BiniTokenV2(address(proxy));
        require(token.totalSupply() == token.MAX_SUPPLY(), "BAD_SUPPLY");
        require(token.balanceOf(genesisDistributionSafe) == token.MAX_SUPPLY(), "BAD_GENESIS_BALANCE");
        require(token.defaultAdmin() == adminTimelock, "BAD_ADMIN");
        require(token.hasRole(token.UPGRADER_ROLE(), adminTimelock), "BAD_UPGRADER");
        require(token.hasRole(token.MARKET_MANAGER_ROLE(), adminTimelock), "BAD_MARKET_MANAGER");
        require(token.hasRole(token.PAUSER_ROLE(), emergencyPauserSafe), "BAD_PAUSER");
        require(!token.marketOpen(), "MARKET_ALREADY_OPEN");
    }
}
