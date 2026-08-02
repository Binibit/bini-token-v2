# Evidence Manifest

Version-controlled evidence:

- `artifacts/release/BINI_V2_CORE_ABI.json`
- `artifacts/release/BINI_V2_CORE_SELECTORS.json`
- `artifacts/release/BINI_V2_CORE_STORAGE.json`
- `artifacts/release/BINI_V2_BUILD.json`
- Migration Vault ABI and build descriptors in the same directory
- `config/deployment-receipt.schema.json`
- `config/distribution-receipt.schema.json`
- `BINI_V2_PHASE1_RELEASE_MANIFEST.json`

CI-only raw evidence:

- compiler build-info and creation/runtime bytecode;
- SHA-256 inventory;
- Slither JSON and log;
- LCOV and coverage summary;
- UUPS positive and incompatible-storage reports;
- Solidity, CLI, fork and dependency logs;
- receipt-backed Anvil logs and generated receipts.

The final CI step regenerates `SHA256SUMS` only after every gate has completed,
verifies the checkout is clean and checks every file before upload. GitHub then
records a separate digest for the uploaded archive.

Sepolia blocker records are under `artifacts/sepolia/phase1/`; they are not
confirmed receipts.
