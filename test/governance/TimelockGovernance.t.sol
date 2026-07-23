// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BiniTokenV2Guarded} from "../../src/BiniTokenV2Guarded.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// Trivial UUPS upgrade target used to prove the Timelock can perform an authorized upgrade.
contract TLInvV2 is BiniTokenV2Guarded {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// Proves U2 governance mechanics against a REAL OpenZeppelin TimelockController.
/// The token's admin/timelock authorities are held by an actual deployed TimelockController,
/// and unpause must travel schedule -> delay -> execute (never a raw vm.prank(timelock)).
contract TimelockGovernanceTest is Test {
    BiniTokenV2Guarded internal token;
    TimelockController internal timelock;

    // Real actors.
    address internal governanceActor = address(0x6074); // Timelock PROPOSER (off-chain proposer for U2)
    address internal executorActor = address(0xE4EC); // Timelock EXECUTOR
    address internal securityActor = address(0x5EC0); // Security Safe: PAUSER + EMERGENCY_REVOKER + CANCELLER
    address internal opsSafe = address(0x0951); // Operations Safe: PARTICIPANT_MANAGER
    address internal genesisSafe = address(0x9E11);

    // Unrelated addresses used as endpoint / operator subjects.
    address internal endpoint = address(0xE9D9);
    address internal operator = address(0x09E7);

    uint256 internal constant MIN_DELAY = 48 hours;
    uint256 internal constant MAX = 1_000_000_000 ether;

    function setUp() public {
        // --- deploy a REAL, self-administered TimelockController ---
        address[] memory proposers = new address[](1);
        proposers[0] = governanceActor;
        address[] memory executors = new address[](1);
        executors[0] = executorActor;

        // admin = address(this): temporary bootstrap admin so we can grant CANCELLER, then renounce.
        timelock = new TimelockController(MIN_DELAY, proposers, executors, address(this));

        // In OZ 5.x a proposer is NOT automatically a canceller: grant CANCELLER explicitly to security.
        timelock.grantRole(timelock.CANCELLER_ROLE(), securityActor);

        // Renounce the bootstrap admin so the Timelock is fully self-administered (admin == itself).
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), address(this));

        // --- deploy the token behind an ERC1967 proxy, admin = the Timelock ---
        BiniTokenV2Guarded impl = new BiniTokenV2Guarded();
        bytes memory initData = abi.encodeCall(
            BiniTokenV2Guarded.initialize,
            (address(timelock), opsSafe, securityActor, genesisSafe, uint48(3 days))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        token = BiniTokenV2Guarded(address(proxy));
    }

    // --- helpers ---------------------------------------------------------------

    function _schedule(address target, bytes memory data, bytes32 salt) internal returns (bytes32 id) {
        id = timelock.hashOperation(target, 0, data, bytes32(0), salt);
        vm.prank(governanceActor);
        timelock.schedule(target, 0, data, bytes32(0), salt, MIN_DELAY);
    }

    function _execute(address target, bytes memory data, bytes32 salt) internal {
        vm.prank(executorActor);
        timelock.execute(target, 0, data, bytes32(0), salt);
    }

    // ==========================================================================
    // 1 + 2: no direct unpause authority for governance or security actors.
    // ==========================================================================
    function test_1_GovernanceActorCannotDirectlyUnpause() public {
        // First put the token into a paused state so unpause would otherwise be meaningful.
        vm.prank(securityActor);
        token.pause();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, governanceActor, token.UNPAUSER_ROLE()
            )
        );
        vm.prank(governanceActor);
        token.unpause();
    }

    function test_2_SecurityActorCannotDirectlyUnpause() public {
        vm.prank(securityActor);
        token.pause();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, securityActor, token.UNPAUSER_ROLE()
            )
        );
        vm.prank(securityActor);
        token.unpause();
    }

    // ==========================================================================
    // 3: security actor can pause INSTANTLY (no delay).
    // ==========================================================================
    function test_3_SecurityActorPausesInstantly() public {
        assertFalse(token.paused());
        vm.prank(securityActor);
        token.pause();
        assertTrue(token.paused());
    }

    // ==========================================================================
    // 4: governance actor schedules unpause THROUGH the timelock.
    // ==========================================================================
    function test_4_GovernanceSchedulesUnpause() public {
        vm.prank(securityActor);
        token.pause();

        bytes memory data = abi.encodeCall(BiniTokenV2Guarded.unpause, ());
        bytes32 id = _schedule(address(token), data, bytes32("unpause"));

        assertTrue(timelock.isOperation(id));
        assertTrue(timelock.isOperationPending(id));
        assertFalse(timelock.isOperationReady(id)); // still inside the 48h delay
    }

    // ==========================================================================
    // 5: executing before the delay elapses reverts (not ready).
    // ==========================================================================
    function test_5_ExecuteBeforeDelayReverts() public {
        vm.prank(securityActor);
        token.pause();

        bytes memory data = abi.encodeCall(BiniTokenV2Guarded.unpause, ());
        bytes32 id = _schedule(address(token), data, bytes32("unpause"));

        // 1 == OperationState.Waiting; execute requires Ready.
        vm.expectRevert(
            abi.encodeWithSelector(TimelockController.TimelockUnexpectedOperationState.selector, id, bytes32(uint256(1 << 2)))
        );
        vm.prank(executorActor);
        timelock.execute(address(token), 0, data, bytes32(0), bytes32("unpause"));

        assertTrue(token.paused()); // never unpaused
    }

    // ==========================================================================
    // 6: security actor (CANCELLER) can cancel a scheduled op; cancelled op can't execute.
    // ==========================================================================
    function test_6_SecurityCanCancelScheduledOp() public {
        vm.prank(securityActor);
        token.pause();

        bytes memory data = abi.encodeCall(BiniTokenV2Guarded.unpause, ());
        bytes32 id = _schedule(address(token), data, bytes32("cancelme"));
        assertTrue(timelock.isOperationPending(id));

        vm.prank(securityActor);
        timelock.cancel(id);
        assertFalse(timelock.isOperation(id)); // gone

        // Warp past the delay and prove the cancelled op still cannot execute.
        vm.warp(block.timestamp + MIN_DELAY + 1);
        vm.expectRevert(
            abi.encodeWithSelector(TimelockController.TimelockUnexpectedOperationState.selector, id, bytes32(uint256(1 << 2)))
        );
        vm.prank(executorActor);
        timelock.execute(address(token), 0, data, bytes32(0), bytes32("cancelme"));

        assertTrue(token.paused());
    }

    // ==========================================================================
    // 7: re-schedule + warp past 48h -> execute succeeds; token.paused()==false.
    //    The TIMELOCK is msg.sender to unpause().
    // ==========================================================================
    function test_7_ScheduledUnpauseExecutesAfterDelay() public {
        vm.prank(securityActor);
        token.pause();
        assertTrue(token.paused());

        bytes memory data = abi.encodeCall(BiniTokenV2Guarded.unpause, ());
        _schedule(address(token), data, bytes32("unpause"));

        vm.warp(block.timestamp + MIN_DELAY + 1);
        _execute(address(token), data, bytes32("unpause"));

        assertFalse(token.paused()); // unpause happened via the timelock only
    }

    // ==========================================================================
    // 8: timelock can add and remove a MARKET_ENDPOINT via scheduled ops.
    // ==========================================================================
    function test_8_TimelockManagesMarketEndpoint() public {
        address[] memory eps = new address[](1);
        eps[0] = endpoint;

        // ADD.
        bytes memory addData = abi.encodeCall(BiniTokenV2Guarded.setMarketEndpoints, (eps, true));
        _schedule(address(token), addData, bytes32("ep-add"));
        vm.warp(block.timestamp + MIN_DELAY + 1);
        _execute(address(token), addData, bytes32("ep-add"));
        assertEq(uint256(token.accountClassOf(endpoint)), uint256(BiniTokenV2Guarded.AccountClass.MARKET_ENDPOINT));
        assertEq(uint256(token.accountClassOf(endpoint)), 4);

        // REMOVE.
        bytes memory rmData = abi.encodeCall(BiniTokenV2Guarded.setMarketEndpoints, (eps, false));
        _schedule(address(token), rmData, bytes32("ep-rm"));
        vm.warp(block.timestamp + MIN_DELAY + 1);
        _execute(address(token), rmData, bytes32("ep-rm"));
        assertEq(uint256(token.accountClassOf(endpoint)), uint256(BiniTokenV2Guarded.AccountClass.NONE));
        assertEq(uint256(token.accountClassOf(endpoint)), 0);
    }

    // ==========================================================================
    // 9: timelock can approve and revoke an operator via scheduled ops.
    // ==========================================================================
    function test_9_TimelockManagesOperator() public {
        address[] memory ops = new address[](1);
        ops[0] = operator;

        // APPROVE.
        bytes memory onData = abi.encodeCall(BiniTokenV2Guarded.setOperators, (ops, true));
        _schedule(address(token), onData, bytes32("op-on"));
        vm.warp(block.timestamp + MIN_DELAY + 1);
        _execute(address(token), onData, bytes32("op-on"));
        assertTrue(token.isApprovedOperator(operator));

        // REVOKE.
        bytes memory offData = abi.encodeCall(BiniTokenV2Guarded.setOperators, (ops, false));
        _schedule(address(token), offData, bytes32("op-off"));
        vm.warp(block.timestamp + MIN_DELAY + 1);
        _execute(address(token), offData, bytes32("op-off"));
        assertFalse(token.isApprovedOperator(operator));
    }

    // ==========================================================================
    // 10: timelock performs an authorized UUPS upgrade via a scheduled op.
    // ==========================================================================
    function test_10_TimelockPerformsAuthorizedUpgrade() public {
        TLInvV2 newImpl = new TLInvV2();
        bytes memory upgradeData =
            abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(newImpl), ""));

        _schedule(address(token), upgradeData, bytes32("upgrade"));
        vm.warp(block.timestamp + MIN_DELAY + 1);
        _execute(address(token), upgradeData, bytes32("upgrade"));

        // Proxy now routes to the new implementation.
        assertEq(TLInvV2(address(token)).version(), 2);
        // State preserved: supply still intact.
        assertEq(token.totalSupply(), MAX);
    }

    // ==========================================================================
    // 11: the test deployer (address(this)) holds NO token role and NO timelock role.
    // ==========================================================================
    function test_11_DeployerHoldsNoAuthority() public view {
        assertFalse(token.hasRole(token.DEFAULT_ADMIN_ROLE(), address(this)));
        assertFalse(token.hasRole(token.UPGRADER_ROLE(), address(this)));
        assertFalse(token.hasRole(token.UNPAUSER_ROLE(), address(this)));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(this)));
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), address(this)));
        assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(this)));
    }

    // ==========================================================================
    // 12: the timelock has at least one proposer and one executor (not bricked).
    // ==========================================================================
    function test_12_TimelockNotBricked() public view {
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), governanceActor));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), executorActor));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), securityActor));
        assertEq(timelock.getMinDelay(), MIN_DELAY);
    }
}
