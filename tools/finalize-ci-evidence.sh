#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${BINI_EVIDENCE_DIR:?BINI_EVIDENCE_DIR is required}"
cd "$ROOT"

required=(
    BINI_V2_CREATION_BYTECODE.txt
    BINI_V2_RUNTIME_BYTECODE.txt
    GIT_COMMIT
    GIT_STATUS
    SOURCE_FILE_INVENTORY
    DEPENDENCY_COMMITS
    anvil-rehearsal.log
    build.log
    cli-tests.log
    coverage.lcov
    coverage.log
    fork-tests.log
    npm-audit.log
    release-artifacts.log
    slither-report.json
    slither.log
    solidity-tests.log
    uups-incompatible-storage.log
    uups-validation.log
)

for path in "${required[@]}"; do
    [[ -e "$TARGET/$path" ]] || {
        echo "missing release evidence: $path" >&2
        exit 1
    }
done

[[ "$(<"$TARGET/GIT_COMMIT")" == "$(git rev-parse HEAD)" ]] || {
    echo "release evidence commit does not match checkout" >&2
    exit 1
}
[[ ! -s "$TARGET/GIT_STATUS" ]] || {
    echo "release evidence was generated from a dirty checkout" >&2
    cat "$TARGET/GIT_STATUS" >&2
    exit 1
}
compgen -G "$TARGET/build-info/*.json" >/dev/null || {
    echo "compiler build-info is missing" >&2
    exit 1
}
compgen -G "$TARGET/anvil-release/*.json" >/dev/null || {
    echo "Anvil receipt evidence is missing" >&2
    exit 1
}

(
    cd "$TARGET"
    find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 shasum -a 256 >SHA256SUMS
    shasum -a 256 -c SHA256SUMS >/dev/null
)

echo "release evidence sealed for $(git rev-parse HEAD)"
