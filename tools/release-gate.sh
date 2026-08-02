#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

bash -n tools/*.sh
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
python3 -m unittest discover -s test_cli -p 'test_*.py' -v
tools/test-release-anvil.sh
tools/test-mainnet-fork.sh
tools/coverage-gate.sh

jq empty \
  BINI_V2_PHASE1_RELEASE_MANIFEST.json \
  artifacts/release/*.json \
  artifacts/examples/*.json \
  artifacts/sepolia/phase1/*.json \
  config/*.json \
  data/*.json \
  policy/*.json
