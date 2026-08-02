// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BiniTokenV2} from "../src/BiniTokenV2.sol";

contract DeployBiniV2 is Script {
    struct DeploymentConfig {
        uint256 timelockMinDelay;
        address proposer;
        address executor;
        address emergencyPauserSafe;
        address genesisDistributionSafe;
        uint48 adminTransferDelay;
    }

    struct Deployment {
        TimelockController timelock;
        BiniTokenV2 implementation;
        BiniTokenV2 token;
    }

    function run() external returns (Deployment memory deployed) {
        DeploymentConfig memory config = _loadConfig();
        return _deploy(config);
    }

    function _deploy(DeploymentConfig memory config) internal returns (Deployment memory deployed) {
        require(config.timelockMinDelay > 0, "ZERO_TIMELOCK_DELAY");
        require(config.proposer.code.length > 0, "PROPOSER_NOT_CONTRACT");
        require(config.executor.code.length > 0, "EXECUTOR_NOT_CONTRACT");
        require(config.emergencyPauserSafe.code.length > 0, "PAUSER_NOT_CONTRACT");
        require(config.genesisDistributionSafe.code.length > 0, "GENESIS_NOT_CONTRACT");

        address[] memory proposers = new address[](1);
        proposers[0] = config.proposer;
        address[] memory executors = new address[](1);
        executors[0] = config.executor;

        vm.startBroadcast();
        deployed.timelock = new TimelockController(config.timelockMinDelay, proposers, executors, address(0));
        deployed.implementation = new BiniTokenV2();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(deployed.implementation),
            abi.encodeCall(
                BiniTokenV2.initialize,
                (
                    address(deployed.timelock),
                    config.emergencyPauserSafe,
                    config.genesisDistributionSafe,
                    config.adminTransferDelay
                )
            )
        );
        deployed.token = BiniTokenV2(address(proxy));
        vm.stopBroadcast();

        require(deployed.token.totalSupply() == deployed.token.MAX_SUPPLY(), "BAD_SUPPLY");
        require(
            deployed.token.balanceOf(config.genesisDistributionSafe) == deployed.token.MAX_SUPPLY(),
            "BAD_GENESIS_BALANCE"
        );
        require(deployed.token.defaultAdmin() == address(deployed.timelock), "BAD_TOKEN_ADMIN");
        require(!deployed.token.marketOpen(), "MARKET_ALREADY_OPEN");
        require(!deployed.token.hasRole(deployed.token.DEFAULT_ADMIN_ROLE(), msg.sender), "DEPLOYER_TOKEN_ROLE");
    }

    function _loadConfig() private view returns (DeploymentConfig memory config) {
        require(block.chainid == vm.envUint("BINI_V2_EXPECTED_CHAIN_ID"), "UNEXPECTED_CHAIN_ID");
        config.timelockMinDelay = vm.envUint("BINI_V2_TIMELOCK_MIN_DELAY");
        config.proposer = vm.envAddress("BINI_V2_TIMELOCK_PROPOSER");
        config.executor = vm.envAddress("BINI_V2_TIMELOCK_EXECUTOR");
        config.emergencyPauserSafe = vm.envAddress("BINI_V2_EMERGENCY_PAUSER_SAFE");
        config.genesisDistributionSafe = vm.envAddress("BINI_V2_GENESIS_DISTRIBUTION_SAFE");
        uint256 rawAdminTransferDelay = vm.envUint("BINI_V2_ADMIN_TRANSFER_DELAY");

        require(rawAdminTransferDelay <= type(uint48).max, "ADMIN_TRANSFER_DELAY_OVERFLOW");
        // The preceding bound makes this narrowing conversion exact.
        // forge-lint: disable-next-line(unsafe-typecast)
        config.adminTransferDelay = uint48(rawAdminTransferDelay);
    }
}
