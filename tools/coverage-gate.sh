#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

forge coverage \
  --no-match-coverage '(script|test)' \
  --report summary \
  --report lcov \
  --no-match-path 'test/fork/*'

awk '
  /^SF:.*src\/BiniTokenV2.sol$/ { in_file=1; next }
  /^end_of_record$/ { in_file=0 }
  in_file && /^LF:/ { split($0, a, ":"); lf=a[2] }
  in_file && /^LH:/ { split($0, a, ":"); lh=a[2] }
  in_file && /^BRF:/ { split($0, a, ":"); brf=a[2] }
  in_file && /^BRH:/ { split($0, a, ":"); brh=a[2] }
  in_file && /^FNF:/ { split($0, a, ":"); fnf=a[2] }
  in_file && /^FNH:/ { split($0, a, ":"); fnh=a[2] }
  END {
    if (!lf || !brf || !fnf) exit 2
    line=100*lh/lf
    branch=100*brh/brf
    funcs=100*fnh/fnf
    printf "BiniTokenV2 coverage: lines %.2f%%, branches %.2f%%, functions %.2f%%\n", line, branch, funcs
    if (line < 100 || branch < 80 || funcs < 100) exit 1
  }
' lcov.info

awk '
  /^SF:.*src\/BiniMigrationVault.sol$/ { in_file=1; next }
  /^end_of_record$/ { in_file=0 }
  in_file && /^LF:/ { split($0, a, ":"); lf=a[2] }
  in_file && /^LH:/ { split($0, a, ":"); lh=a[2] }
  in_file && /^BRF:/ { split($0, a, ":"); brf=a[2] }
  in_file && /^BRH:/ { split($0, a, ":"); brh=a[2] }
  in_file && /^FNF:/ { split($0, a, ":"); fnf=a[2] }
  in_file && /^FNH:/ { split($0, a, ":"); fnh=a[2] }
  END {
    if (!lf || !brf || !fnf) exit 2
    line=100*lh/lf
    branch=100*brh/brf
    funcs=100*fnh/fnf
    printf "BiniMigrationVault coverage: lines %.2f%%, branches %.2f%%, functions %.2f%%\n", line, branch, funcs
    if (line < 95 || branch < 80 || funcs < 90) exit 1
  }
' lcov.info
