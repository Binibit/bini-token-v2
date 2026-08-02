// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployBiniV2} from "../../script/DeployBiniV2.s.sol";
import {ActorContract} from "../mocks/MarketMocks.sol";
import {MockToken} from "../mocks/MockTokens.sol";

contract DeployBiniV2Harness is DeployBiniV2 {
    function deployForTest(DeploymentConfig calldata config) external returns (Deployment memory) {
        return _deploy(config);
    }
}

contract DeployBiniV2Test is Test {
    DeployBiniV2Harness internal script;
    address internal proposer;
    address internal executor;
    address internal pauser;
    address internal genesis;
    MockToken internal v1;

    function setUp() public {
        script = new DeployBiniV2Harness();
        proposer = address(new ActorContract());
        executor = address(new ActorContract());
        pauser = address(new ActorContract());
        genesis = address(new ActorContract());
        v1 = new MockToken("BINI V1", "BINI1", 12);
        _setValidEnv();
    }

    function test_AtomicDeploymentLeavesPreMarketAndNoDeployerRoles() public {
        DeployBiniV2.Deployment memory deployed = script.run();

        assertEq(deployed.token.totalSupply(), 1_000_000_000 ether);
        assertEq(deployed.token.balanceOf(genesis), 1_000_000_000 ether);
        assertEq(deployed.token.defaultAdmin(), address(deployed.timelock));
        assertFalse(deployed.token.marketOpen());
        assertEq(address(deployed.migrationVault.v1Token()), address(v1));
        assertEq(address(deployed.migrationVault.v2Token()), address(deployed.token));
        assertFalse(deployed.token.hasRole(deployed.token.UPGRADER_ROLE(), address(script)));
        assertFalse(deployed.migrationVault.hasRole(deployed.migrationVault.CONFIG_ROLE(), address(script)));
    }

    function test_WrongChainIdReverts() public {
        vm.chainId(block.chainid + 1);
        vm.expectRevert(bytes("UNEXPECTED_CHAIN_ID"));
        script.run();
    }

    function test_ZeroOrNonContractSafeReverts() public {
        DeployBiniV2.DeploymentConfig memory config = _validConfig();
        config.genesisDistributionSafe = address(0);
        vm.expectRevert(bytes("GENESIS_NOT_CONTRACT"));
        script.deployForTest(config);
    }

    function test_ZeroTimelockDelayReverts() public {
        DeployBiniV2.DeploymentConfig memory config = _validConfig();
        config.timelockMinDelay = 0;
        vm.expectRevert(bytes("ZERO_TIMELOCK_DELAY"));
        script.deployForTest(config);
    }

    function test_ImplementationInitializerIsDisabledAndProxyCannotReplay() public {
        DeployBiniV2.Deployment memory deployed = script.run();
        vm.expectRevert();
        deployed.implementation.initialize(address(deployed.timelock), pauser, genesis, uint48(2 days));
        vm.expectRevert();
        deployed.token.initialize(address(deployed.timelock), pauser, genesis, uint48(2 days));
    }

    function _setValidEnv() private {
        vm.setEnv("BINI_V2_EXPECTED_CHAIN_ID", vm.toString(block.chainid));
        vm.setEnv("BINI_V2_TIMELOCK_MIN_DELAY", vm.toString(uint256(2 days)));
        vm.setEnv("BINI_V2_TIMELOCK_PROPOSER", vm.toString(proposer));
        vm.setEnv("BINI_V2_TIMELOCK_EXECUTOR", vm.toString(executor));
        vm.setEnv("BINI_V2_EMERGENCY_PAUSER_SAFE", vm.toString(pauser));
        vm.setEnv("BINI_V2_GENESIS_DISTRIBUTION_SAFE", vm.toString(genesis));
        vm.setEnv("BINI_V2_V1_TOKEN", vm.toString(address(v1)));
        vm.setEnv("BINI_V2_ADMIN_TRANSFER_DELAY", vm.toString(uint256(2 days)));
    }

    function _validConfig() private view returns (DeployBiniV2.DeploymentConfig memory config) {
        config = DeployBiniV2.DeploymentConfig({
            timelockMinDelay: 2 days,
            proposer: proposer,
            executor: executor,
            emergencyPauserSafe: pauser,
            genesisDistributionSafe: genesis,
            v1Token: address(v1),
            adminTransferDelay: uint48(2 days)
        });
    }
}
