# Role Matrix

| Capability | Holder | Governance Timelock | Security Safe | Genesis Safe |
| --- | --- | --- | --- | --- |
| ERC-20 transfer/approve/Permit | Yes | Yes | Yes | Yes |
| Upgrade | No | Yes | No | No |
| Configure DEX policy | No | Yes | No | No |
| Open market | No | Yes, delayed | No | No |
| Pause | No | No | Yes | No |
| Unpause | No | Yes, delayed | No | No |
| Initial nine-Safe distribution | No | No | No | Yes |

Timelock holds default admin, upgrader, market manager and unpauser roles.
Security Safe holds only pauser. Deployment must prove the deployer has no role.
