# Token and DEX Policy

## Core behavior

`BiniTokenV2` initializes atomically behind ERC-1967, locks the implementation
initializer, mints exactly `1_000_000_000 ether` once to Genesis Safe, and exposes
no runtime mint or burn. The ABI/policy gates contain no tax, confiscation,
forced transfer, wallet limit, blacklist, KYC, or participant allowlist.

PRE_MARKET ordinary `transfer`, `transferFrom`, and EIP-2612 permit use standard
ERC-20 flows. Emergency pause is independent. Timelock owns admin, upgrade,
market-manager, and unpause roles; the emergency Safe only owns pause. The sole
`openMarket()` transition is role-controlled and reverts after the first call.

## Market path matrix

| Destination | PRE_MARKET | OPEN_MARKET | Recognition and residual bypass |
| --- | --- | --- | --- |
| Supported V2 factory pool | Blocked | Allowed | Pool metadata plus registered factory `getPair`; unknown factories bypass |
| Supported V3 factory pool | Blocked | Allowed | Pool metadata/fee plus registered factory `getPool`; unknown factories bypass |
| Explicitly registered pool | Blocked | Allowed | Explicit infrastructure registry; omission bypasses |
| Registered router | Blocked | Allowed | Explicit registry; only direct BINI transfer is covered |
| Registered liquidity manager | Blocked | Allowed | Explicit registry; unregistered manager bypasses |
| V4 PoolManager | Blocked when registered | Allowed | Shared manager must be explicitly registered |
| Registered gateway | Blocked | Allowed | Explicit registry; unregistered gateway bypasses |
| Unknown custom AMM | Allowed | Allowed | ERC-20 cannot reliably infer AMM semantics |
| Unknown factory pool | Allowed | Allowed | Factory is outside approved registry |
| Ordinary contract wallet | Allowed | Allowed | Probe failure/lookalike is not enough to block |
| Future CREATE2 address | Allowed until deployed and registered/detectable | Allowed | No code exists to classify before deployment |

Registry changes are permitted only in PRE_MARKET. After OPEN_MARKET all stored
entries are permanently ignored. A malicious or mistaken governance registration
can block an ordinary contract during PRE_MARKET, so code-hash review and Safe
governance remain operational controls.

`UNIVERSAL_AMM_BLOCKING = BLOCKED`

`SUPPORTED_AND_REGISTERED_DEX_BLOCKING = PROVEN`

Proof sources: unit, invariant, E2E, Anvil, and pinned V2/V3/V4 fork tests. The
guarantee is deliberately limited to supported factories and registered
infrastructure.
