// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {Safe} from "safe-smart-account/contracts/Safe.sol";
import {SafeProxy} from "safe-smart-account/contracts/proxies/SafeProxy.sol";
import {SafeProxyFactory} from "safe-smart-account/contracts/proxies/SafeProxyFactory.sol";
import {MultiSend} from "safe-smart-account/contracts/libraries/MultiSend.sol";

/**
 * @notice Deploys the pinned Safe 1.4.1 singleton/factory/MultiSend when requested and exactly
 * twelve chain-specific 2-of-3 proxies. The fallback handler, modules and guard remain unset.
 */
contract DeploySafeTopology is Script {
    uint256 internal constant SAFE_COUNT = 12;

    event SafeProxyForPurpose(uint256 indexed purposeIndex, address indexed proxy);

    struct Deployment {
        address singleton;
        address factory;
        address multiSend;
        address[SAFE_COUNT] safes;
    }

    function run() external returns (Deployment memory deployed) {
        uint256 expectedChainId = vm.envUint("BINI_V2_EXPECTED_CHAIN_ID");
        require(block.chainid == expectedChainId, "UNEXPECTED_CHAIN_ID");
        require(block.chainid != 1, "MAINNET_FORBIDDEN");

        address[] memory owners = new address[](3);
        owners[0] = vm.envAddress("BINI_TEST_SIGNER_1");
        owners[1] = vm.envAddress("BINI_TEST_SIGNER_2");
        owners[2] = vm.envAddress("BINI_TEST_SIGNER_3");
        require(owners[0] != address(0) && owners[1] != address(0) && owners[2] != address(0), "ZERO_OWNER");
        require(owners[0] != owners[1] && owners[0] != owners[2] && owners[1] != owners[2], "DUPLICATE_OWNER");

        bool deployInfrastructure = vm.envOr("BINI_SAFE_DEPLOY_INFRASTRUCTURE", false);
        uint256 saltBase = vm.envUint("BINI_SAFE_SALT_BASE");

        vm.startBroadcast();
        if (deployInfrastructure) {
            deployed.singleton = address(new Safe());
            deployed.factory = address(new SafeProxyFactory());
            deployed.multiSend = address(new MultiSend());
        } else {
            deployed.singleton = vm.envAddress("BINI_SAFE_SINGLETON");
            deployed.factory = vm.envAddress("BINI_SAFE_PROXY_FACTORY");
            deployed.multiSend = vm.envAddress("BINI_SAFE_MULTISEND");
        }

        require(deployed.singleton.code.length > 0, "SINGLETON_NOT_DEPLOYED");
        require(deployed.factory.code.length > 0, "FACTORY_NOT_DEPLOYED");
        require(deployed.multiSend.code.length > 0, "MULTISEND_NOT_DEPLOYED");

        bytes memory initializer = abi.encodeCall(
            Safe.setup, (owners, 2, address(0), bytes(""), address(0), address(0), 0, payable(address(0)))
        );
        for (uint256 i = 0; i < SAFE_COUNT; ++i) {
            SafeProxy proxy = SafeProxyFactory(deployed.factory)
                .createChainSpecificProxyWithNonce(deployed.singleton, initializer, saltBase + i);
            deployed.safes[i] = address(proxy);
            emit SafeProxyForPurpose(i, address(proxy));
        }
        vm.stopBroadcast();

        for (uint256 i = 0; i < SAFE_COUNT; ++i) {
            Safe safe = Safe(payable(deployed.safes[i]));
            require(safe.getThreshold() == 2, "BAD_THRESHOLD");
            require(safe.getOwners().length == 3, "BAD_OWNER_COUNT");
            require(keccak256(bytes(safe.VERSION())) == keccak256(bytes("1.4.1")), "BAD_SAFE_VERSION");
        }
    }
}
