# BINI V2 RC3 — Source and Evidence Reality

Checked at: `2026-08-03T12:50:49Z`

## Gate result

`SOURCE_AND_EVIDENCE_RECONCILED`

The exact RC3 baseline is present and internally consistent. No source drift was
found. The next mandatory gate, script coverage, is evaluated separately in
`01_SCRIPT_INVENTORY.md`.

This check was restricted to the standalone `Binibit/bini-token-v2` repository.
No Mainnet or Sepolia transaction was submitted.

## Repository identity

| Field | Verified value |
| --- | --- |
| Repository | `Binibit/bini-token-v2` |
| Remote | `https://github.com/Binibit/bini-token-v2.git` |
| Visibility | private |
| Default/local branch | `main` |
| Local HEAD | `7093d18e66dfc0f1f394b8c274bb551c8cd5c5c6` |
| Fetched `origin/main` | `7093d18e66dfc0f1f394b8c274bb551c8cd5c5c6` |
| Tag at HEAD | none |
| Working tree at the source gate | clean |

`git fetch origin main` completed immediately before the equality check. The
working tree was clean before these RC3 review records were created.

## Exact-SHA CI

| Field | Verified value |
| --- | --- |
| Workflow | `CI` / `Release gates` |
| Run | `30760016510` |
| Event | `push` |
| Head SHA | `7093d18e66dfc0f1f394b8c274bb551c8cd5c5c6` |
| Status | completed |
| Conclusion | success |
| Run URL | `https://github.com/Binibit/bini-token-v2/actions/runs/30760016510` |

The repository is private and GitHub returned HTTP 403 for both branch
protection and repository rulesets: the current plan does not expose those
features. Exact-source repository protection therefore remains unavailable.

## Retained evidence artifact

| Field | Verified value |
| --- | --- |
| Artifact | `bini-v2-release-evidence-7093d18e66dfc0f1f394b8c274bb551c8cd5c5c6` |
| Artifact ID | `8837168810` |
| Size | `3,068,462` bytes |
| Expiry | `2026-10-31T17:57:26Z` |
| GitHub digest | `sha256:a81b7da8106b6f8933dc18c2acbe73beccfb456f273fc20b975cad56d7864428` |
| Independently downloaded ZIP digest | `a81b7da8106b6f8933dc18c2acbe73beccfb456f273fc20b975cad56d7864428` |
| Internal `SHA256SUMS` entries | `49/49 OK` |
| Artifact `GIT_COMMIT` | exact HEAD |
| Artifact `GIT_STATUS` | empty (`0` bytes) |

All committed release artifacts and retained copies matched byte-for-byte:

- token ABI, selectors, ERC-7201/compiler storage record and build descriptor;
- Migration Vault ABI and build descriptor;
- `foundry.lock`, `package-lock.json` and `remappings.txt`;
- Phase 1 release manifests.

## Toolchain and dependency pins

| Component | Verified pin |
| --- | --- |
| Foundry | `1.5.1` |
| Solidity used by Foundry project | `0.8.24` |
| EVM version | `cancun` |
| Optimizer | enabled, `200` runs |
| Metadata bytecode hash | `none` |
| OpenZeppelin Contracts | `5fd1781b1454fd1ef8e722282f86f9293cacf256` (`v5.6.1` lock entry) |
| OpenZeppelin Contracts Upgradeable | `7bf4727aacdbfaa0f36cbd664654d0c9e1dc52bf` (`v5.6.1`) |
| forge-std | `bf647bd6046f2f7da30d0c2bf435e5c76a780c1b` (`v1.16.2`) |
| OpenZeppelin Upgrades Core | `1.46.0` |
| Slither | `0.11.4` |
| CI Node.js | `22` |

The standalone `solc` binary installed on the operator machine is `0.8.36`, but
the Foundry configuration and retained build-info pin and use `0.8.24`. The
local Foundry binary itself exactly matches the required `1.5.1` pin.

## Reproducible contract artifacts

`tools/release-artifacts.sh check` completed successfully against the current
source and locked dependencies.

| Artifact | Verified hash |
| --- | --- |
| Token creation bytecode | `0x6f048525545cc80f49c8c203f65d605beae18a4b0cc2d24bafaa9a57efebe872` |
| Token runtime bytecode | `0xf13d1d3cbd25af356a9d23a55e5be1e053fc84f9fd478a78d9761b3e8f81f5c2` |
| Token canonical ABI | `0x01661dddf5536c8d75adacf0ab371afa794407a051beff5af5ba30ad6b0c5882` |
| Migration Vault creation bytecode | `0x92af2dc53fc34d116fe0fa8062b920dcb5cd4b0fd2dc89f610f5e582c7d1e4e0` |
| Migration Vault runtime bytecode | `0x1d6c0ba26c697d8f8381b6c54893bbf85aa115a7d2ac82436a4a6e34f03634e6` |
| Migration Vault canonical ABI | `0x6c25e3afaad27b95728c633209c5555c0ac8f8d89dc1761c7c2087e8a30763b9` |
| Selector artifact SHA-256 | `25d3cecbcd07df5cfa1344a0e8cf084421e4e8dacce0ef95ace1b5f60dc6bb61` |
| Storage artifact SHA-256 | `40126f24dd577a533213fff9617b57f7a7df0ce49426e0585c46545305b9d39c` |

## Retained security evidence reality

| Check | Verified retained result |
| --- | --- |
| Solidity suites | `77 passed, 0 failed, 0 skipped` |
| Release CLI | `17 passed` |
| Pinned fork suite | `4 passed, 0 failed, 0 skipped` after RPC fallback |
| BiniTokenV2 coverage | lines `100%`, branches `100%`, functions `100%` |
| Migration Vault coverage | lines `97.65%`, branches `87.50%`, functions `90%` |
| Slither | `0` findings under the recorded exclusions |
| UUPS positive validation | passed |
| Incompatible-storage negative validation | rejected as expected |
| npm audit gate | passed at `high`; five low-severity transitive advisories remain |
| Receipt-backed Anvil rehearsal | retained and sealed |

The pinned fork log records an initial archive-RPC failure and a successful
fallback run. The terminal suite result is four passing tests; the failed
attempt was not silently represented as green.

## Source-gate conclusion

The retained evidence belongs to the exact current source and its external and
internal seals verify. `BLOCKED_SOURCE_DRIFT` does not apply.

The contract's market-protection boundary remains unchanged:

```text
UNIVERSAL_AMM_BLOCKING = BLOCKED
SUPPORTED_AND_REGISTERED_DEX_BLOCKING = PARTIAL
```

Unknown/custom AMMs and pre-funded future CREATE2 destinations cannot be
universally blocked without restricting ordinary transfers.
