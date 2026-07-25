#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-check}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$ROOT/artifacts/release"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ "$MODE" != "check" && "$MODE" != "write" ]]; then
  echo "usage: $0 [check|write]" >&2
  exit 2
fi

cd "$ROOT"
forge build --silent

forge inspect BiniTokenV2 abi --json | jq -S . > "$WORK/BINI_V2_CORE_ABI.json"
forge inspect BiniTokenV2 methods --json | jq -S . > "$WORK/BINI_V2_CORE_SELECTORS.json"
forge inspect BiniTokenV2 storageLayout --json | jq -S . > "$WORK/compiler-storage.json"

creation_hash="$(forge inspect BiniTokenV2 bytecode | cast keccak)"
runtime_hash="$(forge inspect BiniTokenV2 deployedBytecode | cast keccak)"
abi_hash="$(jq -cS . "$WORK/BINI_V2_CORE_ABI.json" | cast keccak)"

jq -n \
  --arg creation "$creation_hash" \
  --arg runtime "$runtime_hash" \
  --arg abi "$abi_hash" \
  '{
    contract: "BiniTokenV2",
    source: "src/BiniTokenV2.sol",
    solidity: "0.8.24",
    foundry: "1.5.1",
    evmVersion: "cancun",
    optimizer: {enabled: true, runs: 200},
    bytecodeHashMode: "none",
    creationBytecodeKeccak256: $creation,
    runtimeBytecodeKeccak256: $runtime,
    abiKeccak256: $abi,
    note: "Regenerate after any source, compiler, dependency or Foundry configuration change."
  }' > "$WORK/BINI_V2_BUILD.json"

jq -nS \
  --slurpfile compiler "$WORK/compiler-storage.json" \
  --slurpfile schema "$ROOT/config/bini-storage-schema.json" \
  '{
    compilerStorageLayout: $compiler[0],
    erc7201Namespaces: {($schema[0].namespace): ($schema[0] | del(.namespace))},
    note: "Solidity reports no conventional storage because BINI uses an explicit ERC-7201 namespace. The namespace schema is version-controlled and must be validated before every upgrade."
  }' > "$WORK/BINI_V2_CORE_STORAGE.json"

rm "$WORK/compiler-storage.json"

if [[ "$MODE" == "write" ]]; then
  mkdir -p "$TARGET"
  cp "$WORK"/*.json "$TARGET/"
  echo "release artifacts updated"
  exit 0
fi

diff -ru "$TARGET" "$WORK"
cmp "$TARGET/BINI_V2_CORE_SELECTORS.json" "$ROOT/policy/allowed-selectors.json"

while IFS= read -r function_name; do
  if jq -e --arg name "$function_name" \
    '.prohibitedFunctionNames | index($name | ascii_downcase) != null' \
    "$ROOT/policy/prohibited-selectors.json" >/dev/null
  then
    echo "prohibited public function: $function_name" >&2
    exit 1
  fi
done < <(jq -r 'keys[] | split("(")[0]' "$WORK/BINI_V2_CORE_SELECTORS.json")

slot="$(jq -r '.slot' "$ROOT/config/bini-storage-schema.json")"
grep -Fq "bytes32 private constant STORAGE_LOCATION = $slot;" "$ROOT/src/BiniTokenV2.sol"

echo "release artifacts and selector policy are consistent"
