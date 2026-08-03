# Evidence and Security

Twelve strict JSON schemas cover public accounts, Safe topology/signatures/
execution, Timelock operations/execution, source verification, PRE_MARKET,
migration fixture/funding, OPEN_MARKET and the RC3 evidence manifest.
Security-sensitive loaders reject unknown fields.

`evidence export-rc3` copies chain artifacts and release inputs into a
source-commit-bound manifest with per-file SHA-256. `evidence seal-rc3` rejects
missing categories, commit drift, existing checksum drift and file tampering,
then verifies every SHA256SUMS entry.

The clean local rehearsal produced all eleven required categories and sealed
98 files. CI runs the rehearsal from a clean checkout and uploads the RC3A
bundle inside the exact GitHub SHA release evidence artifact.

Mainnet is not accepted by any new execution path. Sepolia execution checks
chain ID 11155111 and requires encrypted accounts. Local unlocked accounts are
accepted only behind the explicit rehearsal environment gate.
