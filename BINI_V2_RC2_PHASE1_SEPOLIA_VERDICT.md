# BINI V2 RC2 Phase 1 Sepolia Verdict

## Verdict

`BLOCKED`

Repository access and the RC1 baseline were independently verified. RC2 adds
adversarial DEX tests, source-attributed migration accounting, CODEOWNERS,
receipt schemas and retained exact-SHA CI evidence.

The higher verdict `SEPOLIA_PHASE1_GREEN_EXTERNAL_AUDIT_REQUIRED` is forbidden
because repository rules are unavailable on the current GitHub plan and no real
Safe topology, deployer keystore, RPC, deployment receipt or distribution
receipt exists.

```text
UNIVERSAL_AMM_BLOCKING = BLOCKED
SUPPORTED_AND_REGISTERED_DEX_BLOCKING = PARTIAL
```

The supported policy is partial because a future CREATE2 pool address can hold
BINI before code exists. Unknown and custom AMMs are also outside automatic
detection. These limitations are tested and disclosed.

No Sepolia or Mainnet deployment was performed. `openMarket()` was not called.
No immutable RC2 release tag may be created until all RC2 checks, real Sepolia
rehearsal and independent review pass.
