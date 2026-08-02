# RC2 DEX Policy Security

Verdict: `SUPPORTED_DEX_POLICY_PARTIAL`.

```text
UNIVERSAL_AMM_BLOCKING = BLOCKED
SUPPORTED_AND_REGISTERED_DEX_BLOCKING = PARTIAL
```

BINI V2 blocks real BINI transfers involving supported V2/V3 pools discovered
through approved factories and explicitly registered DEX infrastructure,
including configured routers, managers, gateways and the configured V4
PoolManager. It does not universally detect every unknown, future or custom AMM.

Ordinary transfers contain no participant allowlist. Pool recognition performs
a bounded sequence of static calls, each capped at 30,000 gas. Factory revert,
gas exhaustion, short return data and oversized return data fail closed for
recognition without reverting an ordinary transfer. There is no factory loop in
the transfer path. Registry mutation and `openMarket()` require the Timelock-held
`MARKET_MANAGER_ROLE`; Timelock delay applies equally to removal.

Tests prove normal Safe, proxy wallet, ERC-4337-like account and an
EIP-7702-style code-bearing account are transferable. Tests also cover fake
pools, malicious factories, V2/V3 confirmation, V4 registration, unknown custom
AMM bypass, and state preservation across irreversible `openMarket()`.

The partial verdict is required because a CREATE2 address can be funded before
pool code exists. After canonical deployment it becomes recognized and further
transfers are blocked, but the pre-funded balance already exists. Preventing
that universally would require restrictions inconsistent with free ordinary
transfers or exhaustive advance registration.

After `OPEN_MARKET`, market checks are bypassed permanently. Emergency pause
remains independent and preserves its prior state.
