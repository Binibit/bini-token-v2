#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

npx openzeppelin-upgrades-core validate out/build-info \
  --contract src/BiniTokenV2.sol:BiniTokenV2

if npx openzeppelin-upgrades-core validate out/build-info \
  --contract test/upgrade/fixtures/IncompatibleStorage.sol:StorageLayoutIncompatible \
  --reference test/upgrade/fixtures/IncompatibleStorage.sol:StorageLayoutBaseline \
  > /tmp/bini-v2-incompatible-storage.log 2>&1; then
    echo "OpenZeppelin validator unexpectedly accepted the incompatible storage fixture" >&2
    exit 1
fi

grep -Eq 'Bad upgrade|Upgraded .* to an incompatible type|storage layout' /tmp/bini-v2-incompatible-storage.log || {
  cat /tmp/bini-v2-incompatible-storage.log >&2
  echo "OpenZeppelin validator failed without a storage-incompatibility diagnostic" >&2
  exit 1
}
rm -f /tmp/bini-v2-incompatible-storage.log
echo "OpenZeppelin validator rejected the incompatible storage fixture as expected"
