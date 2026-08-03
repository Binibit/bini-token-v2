# Timelock Automation

`DeployTimelock.s.sol` deploys a standalone OpenZeppelin TimelockController.
The final topology is:

| Role | Holder |
| --- | --- |
| proposer | Governance Safe |
| executor | Governance Safe |
| canceller | Security Safe |
| default admin | Timelock itself |

The deployer renounces its temporary admin role and retains no Timelock role.
Governance does not retain the canceller role.

Strict operation documents bind target, value, calldata, predecessor, salt,
delay and computed operation ID. The CLI generates role-correct Safe packages
for schedule, cancel and execute and reports UNSET, PENDING, READY, CANCELLED or
DONE from on-chain state and logs.

The canonical rehearsal proves cancellation, rescheduling, early-execution
rejection and delayed execution with real 2-of-3 Safe signatures.
