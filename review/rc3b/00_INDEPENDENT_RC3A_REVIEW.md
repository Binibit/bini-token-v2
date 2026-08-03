# BINI V2 RC3B — Independent RC3A Review

## Scope and immutable baseline

- Review type: independent, read-only review of the candidate implementation. No production code was changed during this review.
- Base: `7093d18e66dfc0f1f394b8c274bb551c8cd5c5c6`
- Candidate: `5a7d964575fc2cb058db00ce5e4d47c38940e9ca`
- Diff: 46 files, 4,048 insertions, 30 deletions.
- Candidate GitHub Actions run `30821469397` is green and is bound to the exact candidate SHA.
- Candidate CI success is not sufficient to clear this review because the adversarial cases below are absent from the 28 passing CLI tests.
- Ethereum Mainnet and Sepolia writes performed by this review: **none**.

## Result

`BLOCKED_RC3A_REVIEW`

The candidate must not be merged or used for Sepolia transactions until every blocker below is fixed, regression-tested, independently re-reviewed, and exact-SHA CI/evidence is regenerated.

## Blocking findings

### RC3B-R01 — Safe execution receipts can be forged and can bypass idempotency checks

Severity: **BLOCKER**

`validate_safe_execution_receipt()` checks only that a referenced on-chain transaction succeeded and that its `to` field equals the recorded Safe. It does not bind the on-chain `ExecutionSuccess(bytes32,uint256)` event to `safeTxHash`, and it does not reconcile the recorded nonce, block, transaction, signers, status, or embedded raw receipt. A fabricated semantic receipt pointing to any successful transaction to the same Safe is therefore accepted.

The `ALREADY_EXECUTED` branch in `command_safe_tx_execute()` is weaker: if the current nonce is greater than the bundle nonce, the presence of any filename containing the claimed hash causes an immediate success result. The file is not parsed or passed to `validate_safe_execution_receipt()`.

Independent probes confirmed both conditions:

- `forged_safe_receipt_accepted = true`
- `forged_idempotency_receipt_accepted = true`

Affected code: `tools/rc3_automation.py:1121-1125`, `tools/rc3_automation.py:1201-1214`.

Required correction:

1. Use one deterministic receipt path, reject symlinks and non-regular files, parse it, and perform full validation before returning `ALREADY_EXECUTED`.
2. Fetch the canonical transaction receipt by hash and require exact transaction hash, Safe address, successful status, block number, and an `ExecutionSuccess` log emitted by that Safe whose indexed `safeTxHash` equals the recorded hash.
3. Recompute the Safe transaction hash from the recorded normalized transaction and recorded nonce against the recorded Safe.
4. Require `transaction.nonce == receipt.nonce`, canonical transaction fields, distinct owner-sorted signers, current/historical owner and threshold evidence appropriate to the execution block, and exact raw-receipt consistency.
5. Add negative tests for a forged filename, a successful unrelated Safe transaction, a wrong event hash, wrong nonce, wrong block, wrong raw receipt, and receipt replay across Safe/network.

### RC3B-R02 — RC3 evidence sealing does not validate the manifest file inventory

Severity: **BLOCKER**

`command_evidence_seal()` never validates `manifest.files`. It trusts self-declared `presentCategories`, then calculates `SHA256SUMS` over whatever happens to be in the directory. A manifest with `files: []`, fabricated category declarations, and an arbitrary payload is accepted and sealed. It also does not require `workingTreeClean == true`, does not validate the manifest network/chain pair, and does not require the manifest at one canonical location.

Independent probe: `checksum_omission_accepted = true`.

This defeats the intended proof of completeness even though later byte-level tampering of an already sealed directory is detected.

Affected code: `tools/rc3_automation.py:1895-1928`.

Required correction:

1. Strictly validate every manifest entry (`path`, lowercase SHA-256, exact size), reject duplicates, absolute paths, `..`, separators with ambiguous normalization, symlinks, devices, and files outside the evidence root.
2. Require a bijection between manifest entries and all evidence payload files, excluding only the canonical manifest and `SHA256SUMS` according to a documented rule.
3. Derive categories from the verified inventory instead of trusting `presentCategories`.
4. Require `workingTreeClean == true`, exact allowed network/chain, exact current source commit, and one manifest at the expected path.
5. Validate nested receipt schemas and their source-commit/network bindings before sealing.
6. Add omission, extra-file, duplicate-path, traversal, symlink, dirty-tree, wrong-network, and multiple-manifest regression tests.

### RC3B-R03 — MultiSend is not safely pinned on all signing/execution paths

Severity: **BLOCKER**

The MultiSend runtime hash is checked only by `safe-tx inspect`. `safe-tx sign` and `safe-tx execute` do not repeat this check, so inspection is optional and a package can be signed/executed directly. Independent probe confirmed `code_hash()` is not called by the signing path: `multisend_hash_not_checked_before_signing = true`.

In addition, Sepolia Safe infrastructure configuration contains expected runtime-code-hash fields, but `command_safes_deploy()` validates only the three addresses. It ignores `singletonRuntimeCodeHash`, `proxyFactoryRuntimeCodeHash`, and `multiSendRuntimeCodeHash`. `command_safes_verify()` reports observed hashes without comparing them to independently pinned expected values. A caller-supplied address plus a caller-supplied matching hash is not an authoritative pin.

Affected code: `tools/rc3_automation.py:487-511`, `tools/rc3_automation.py:612-660`, `tools/rc3_automation.py:953-963`, `tools/rc3_automation.py:1050-1131`.

Required correction:

1. Pin the official Safe 1.4.1 Sepolia singleton, proxy factory, MultiSend address and expected runtime hashes in reviewed canonical configuration.
2. Verify those hashes before Safe deployment, before every MultiSend signature, and immediately before every MultiSend execution.
3. Make inspect/sign/execute call the same fail-closed validation function.
4. Add wrong target, wrong runtime hash, skipped-inspect, and code-change regression tests.

### RC3B-R04 — Symlink/path handling can place keystores in Git and can copy external secrets into evidence

Severity: **BLOCKER**

Path checks are lexical and do not operate on resolved, trusted roots. A path outside the repository that is a symlink into the repository passes `test_keystore_dir()`. The command can therefore write encrypted keystores into the working tree despite the stated outside-Git invariant. Generic artifact writes also accept `../` traversal.

More critically, `command_evidence_export()` traverses artifact files with `is_file()` and copies them with `shutil.copy2()`. A symlink under `artifacts/<network>` pointing to an external file is followed and its contents are copied into the release evidence.

Independent probes confirmed:

- `relative_path_traversal_writes_outside_root = true`
- `symlink_keystore_path_resolves_inside_repo = true`
- `evidence_export_follows_symlink_and_copies_external_file = true`

Affected code: `tools/rc3_automation.py:89-106`, `tools/rc3_automation.py:188-198`, `tools/rc3_automation.py:286-301`, `tools/rc3_automation.py:1826-1859`.

Required correction:

1. Define explicit trusted roots per input/output class and validate canonical resolved paths.
2. Reject symlinks in every component for keystore, artifact, evidence, receipt, signature, and manifest paths.
3. Use exclusive/atomic regular-file creation with restrictive modes for sensitive files and fail closed on TOCTOU changes.
4. Never follow artifact symlinks during evidence collection.
5. Add traversal, symlink-to-file, symlink-to-directory, race-resistant creation, and external-secret-copy tests.

### RC3B-R05 — Schema files are not actually validated by CI or the release gate

Severity: **HIGH / MERGE BLOCKING**

The candidate adds 20 JSON Schema documents, but CI and `tools/release-gate.sh` run only `jq empty` over JSON files. No JSON Schema engine is invoked and no generated receipt is matched to its declared schema. Several schemas also leave security-critical nested objects as unconstrained generic objects or use unvalidated strings for addresses/hashes.

Affected code: `.github/workflows/test.yml:100-109`, `tools/release-gate.sh:24-31`, `config/*schema.json`.

Required correction:

1. Add a pinned schema validator and a repository-owned mapping from each receipt type to its schema.
2. Validate positive fixtures and adversarial negative fixtures in local and CI gates.
3. Make schema validation a prerequisite for evidence sealing.
4. Tighten nested transaction/raw-receipt/address/hash/count/date-time definitions.

### RC3B-R06 — Source drift can be hidden inside a current-commit evidence wrapper

Severity: **HIGH / MERGE BLOCKING**

The seal compares only the top-level evidence manifest `sourceCommit` with current HEAD. It does not validate the `sourceCommit` or `gitCommit` embedded in Safe, Timelock, fixture, vault, token, or other deployment artifacts. Existing deployment manifests are accepted on idempotent paths without requiring their source commit to equal current HEAD. Consequently, old chain artifacts can be exported and sealed under a new top-level source commit.

Affected code includes `tools/rc3_automation.py:482-486`, `tools/rc3_automation.py:693-746`, `tools/rc3_automation.py:1495-1567`, `tools/rc3_automation.py:1880-1913`.

Required correction:

1. Require exact source-commit bindings for every executable/deployment artifact.
2. Recompute and validate locally built runtime/creation bytecode hashes against the on-chain contracts and receipt metadata.
3. Reject mixed-SHA evidence bundles and add regression coverage.

### RC3B-R07 — Explorer API key is exposed in process arguments

Severity: **HIGH / MERGE BLOCKING**

`ETHERSCAN_API_KEY` is appended to the `forge verify-contract` argv with `--etherscan-api-key`. Process arguments can be visible to other local processes and process telemetry. Independent probe confirmed `explorer_key_exposed_in_process_argv = true`.

Affected code: `tools/rc3_automation.py:1755-1791`.

Required correction: pass the key only through the child environment supported by Foundry, redact tool output before persistence, and add an argv/log leakage test using a sentinel secret.

### RC3B-R08 — Sepolia PRE_MARKET and migration-funding evidence is not receipt-complete

Severity: **HIGH / MERGE BLOCKING**

For Sepolia, PRE_MARKET behavior accepts JSON returned by an arbitrary environment-selected command and later verifies only ordered case names and boolean `passed` values. Transaction hashes are not required to be valid, successful, on the correct chain, emitted by the expected actors/contracts, or linked to each case.

Migration funding verification accepts a single Safe receipt and then checks only that the vault balance is greater than zero. The RC3A rehearsal executes multiple source-Safe funding transactions but verifies only the last receipt. It does not prove that every source allocation, amount, package, execution receipt, and liability reconciles.

Affected code: `tools/rc3_automation.py:1579-1608`, `tools/rc3_automation.py:1623-1679`, `tools/test-rc3a-anvil.sh:169-174`.

Required correction:

1. Add a repository-owned or independently pinned Sepolia harness protocol whose output is fully receipt- and postcondition-validated.
2. Require one validated execution receipt per migration funding source and exact equality between plan liabilities, Safe calldata, Transfer events, vault delta, and recorded source accounting.

## Required RC3B functional correction before any on-chain action

The current bootstrap creates exactly three accounts and `test-accounts verify` requires all three to exceed a fixed balance. RC3B requires four distinct accounts: a separate `BINI_SEPOLIA_DEPLOYER` plus three Safe owners, and explicitly states that off-chain-only owners need not all be funded.

This expected RC3B extension must be implemented and independently reviewed together with the blockers above. It must use encrypted keystores outside Git, a password-file or interactive secret channel, public-address-only manifests, and role-aware balance requirements.

Affected code: `tools/rc3_automation.py:42`, `tools/rc3_automation.py:304-392`, `config/test-accounts.public.schema.json`.

## Explicit adversarial test matrix

| Case | Result | Notes |
|---|---|---|
| Shell/command injection | PASS with caveat | Subprocesses use argv lists and no shell. The external PRE_MARKET command is explicitly environment-authorized but uses naive `.split()` and must be pinned/reviewed. |
| Path traversal | **FAIL** | Relative `../` output escaped the patched repository root. |
| Symlink attacks | **FAIL** | Keystore root can resolve into Git; evidence export copied an external symlink target. |
| Unsafe temporary files | PASS for RC3A harness | `mktemp -d`, quoted paths, trap cleanup; no predictable shared temp filename was found. Sensitive path controls remain blocked by R04. |
| Secret leakage | **FAIL** | Explorer key appears in process argv; symlink export can ingest external secret material. |
| Signature replay | PASS on normal path / **FAIL via receipt bypass** | Chain, Safe hash and nonce are normally bound, but forged idempotency evidence bypasses them. |
| Wrong Safe nonce | PASS on normal path / **FAIL via receipt bypass** | Direct execution rejects nonce mismatch; forged local receipt returns success. |
| Wrong chainId | PASS | Sepolia/local allowlist and RPC chain verification reject mismatches. |
| Modified calldata after signing | PASS on normal path | Execute recomputes normalized transaction/hash and compares the bundle; idempotency bypass remains. |
| Duplicate/non-owner signatures | PASS on normal path | Duplicate/ordering checks and on-chain owner membership are present; receipt evidence does not prove recorded signers. |
| Unexpected delegatecall | PASS for inner calls | Inner operation must be CALL; outer MultiSend delegatecall is explicit. MultiSend target pinning fails R03. |
| Unsafe MultiSend target | **FAIL** | Runtime pin is optional in practice because inspect can be skipped and canonical infra hashes are not enforced. |
| Receipt forgery | **FAIL** | R01 and R08. |
| Checksum omission | **FAIL** | Empty manifest inventory can be sealed. |
| Source-commit mismatch | PARTIAL | Top-level manifest mismatch is rejected; nested/mixed-SHA artifacts are not. |

## Positive checks retained

- Candidate CI run `30821469397` completed successfully on exact SHA `5a7d964575fc2cb058db00ce5e4d47c38940e9ca`.
- All 28 current CLI unit tests passed during this review.
- `git diff --check`, `bash -n tools/*.sh`, and Python bytecode compilation passed.
- Direct shell execution is not used by the Python automation.
- Safe package parsing rejects unknown fields, malformed calldata, and inner delegatecalls.
- Signature bundles reject duplicate and non-sorted owners; direct execution verifies owner membership and signatures.
- Timelock operation IDs are recomputed from target/value/data/predecessor/salt.
- Safe and Timelock deployment scripts reject an unexpected chain ID and the new RC3 scripts explicitly reject chain ID 1.
- The RC3A temp directory is generated with `mktemp -d` and cleaned through a quoted trap.
- Git tracks no RC3 temp JSON, keystore, password, mnemonic, seed, PEM, or private-key file. `.env.example` is the only tracked env-named file and is not a secret-bearing runtime file.

## Recovery plan

1. Keep `feature/rc3-release-automation` unmerged and perform no Sepolia writes.
2. Implement R01-R08 and the four-account correction as a new reviewed candidate commit without rewriting published history.
3. Add all negative probes above to the permanent test suite and add real JSON Schema validation to local/CI gates.
4. Rerun the complete RC3A gates and generate a new exact-SHA artifact.
5. Repeat this independent review against the new base/candidate range.
6. Only after `RC3A_REVIEW_GREEN`, open the canonical PR, obtain independent GitHub approval, merge normally, and bind a new main CI artifact before Gate 1/2 or any Sepolia transaction.

