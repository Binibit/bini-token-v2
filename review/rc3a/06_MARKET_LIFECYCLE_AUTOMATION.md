# Market Lifecycle Automation

The PRE_MARKET runner reports fifteen canonical cases: ordinary wallet and
Safe/proxy flows, approvals, transferFrom, Permit, registered V2/V3 pools,
registered infrastructure, configured V4 PoolManager, unknown contracts,
unknown custom AMMs, future CREATE2 destinations and pause/unpause.

Registered and configured DEX destinations are classified BLOCKED. Unknown
custom AMMs and future CREATE2 destinations remain documented allowed
limitations; ordinary transfers remain unrestricted.

Security Safe pause is executed immediately with a real threshold signature.
Unpause and openMarket are scheduled and executed by Governance Safe through
the Timelock after early execution is proven to fail. The post-open verifier
checks the completed operation, one-way transition, replay rejection, fixed
supply and pause independence. The canonical harness also snapshots all twelve
Safe balances before opening and proves they are unchanged afterward.
