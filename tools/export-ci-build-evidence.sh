#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${BINI_EVIDENCE_DIR:?BINI_EVIDENCE_DIR is required}"
cd "$ROOT"

mkdir -p "$TARGET/build-info" "$TARGET/release-artifacts" "$TARGET/release-inputs"
forge inspect BiniTokenV2 bytecode >"$TARGET/BINI_V2_CREATION_BYTECODE.txt"
forge inspect BiniTokenV2 deployedBytecode >"$TARGET/BINI_V2_RUNTIME_BYTECODE.txt"
forge inspect BiniMigrationVault bytecode >"$TARGET/BINI_V2_MIGRATION_VAULT_CREATION_BYTECODE.txt"
forge inspect BiniMigrationVault deployedBytecode >"$TARGET/BINI_V2_MIGRATION_VAULT_RUNTIME_BYTECODE.txt"
cp out/build-info/*.json "$TARGET/build-info/"
cp artifacts/release/*.json "$TARGET/release-artifacts/"
cp BINI_V2_PHASE1_RELEASE_MANIFEST.json BINI_V2_PHASE1_RELEASE_MANIFEST.example.json "$TARGET/release-inputs/"
cp config/deployment-receipt.schema.json config/distribution-receipt.schema.json "$TARGET/release-inputs/"
cp config/phase1.schema.json data/bini-v2-supply-ledger.json "$TARGET/release-inputs/"
git rev-parse HEAD >"$TARGET/GIT_COMMIT"
git status --porcelain=v1 >"$TARGET/GIT_STATUS"
(
    cd "$TARGET"
    find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 shasum -a 256 >SHA256SUMS
)
