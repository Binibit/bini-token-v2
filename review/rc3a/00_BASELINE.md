# RC3A Baseline

RC3A starts from `7093d18e66dfc0f1f394b8c274bb551c8cd5c5c6` and the historical
`BLOCKED_SCRIPT_COVERAGE` finding in `review/rc3/01_SCRIPT_INVENTORY.md`.
The implementation is isolated on `feature/rc3-release-automation` in the
standalone `Binibit/bini-token-v2` repository. The two RC3 review records were
preserved unchanged as baseline evidence.

No token-core change was required. The fixed supply, one initial mint,
PRE_MARKET to OPEN_MARKET one-way transition and documented DEX boundary are
unchanged:

```text
UNIVERSAL_AMM_BLOCKING = BLOCKED
SUPPORTED_AND_REGISTERED_DEX_BLOCKING = PARTIAL
```

No Sepolia or Mainnet transaction was submitted during RC3A. All broadcast
tests target a disposable Anvil chain with chain ID 31337 and an explicit
`BINI_RC3A_LOCAL_REHEARSAL=1` opt-in.
