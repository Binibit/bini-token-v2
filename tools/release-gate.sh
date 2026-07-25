#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

forge fmt --check
forge clean
forge build --sizes
npm run validate:upgrades
slither . \
  --filter-paths 'lib|test|script' \
  --exclude-dependencies \
  --exclude assembly,low-level-calls,unindexed-event-address
tools/release-artifacts.sh check
forge test --no-match-path 'test/fork/*' -vv
forge test --match-path 'test/fork/*' -vv
tools/coverage-gate.sh

jq empty \
  artifacts/release/*.json \
  config/*.json \
  policy/*.json
