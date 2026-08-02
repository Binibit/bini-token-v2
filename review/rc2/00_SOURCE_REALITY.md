# RC2 Source Reality

Independent repository access succeeded through Git and the GitHub API.

- Repository: private `Binibit/bini-token-v2`.
- Default branch: `main`.
- Viewer permission: `ADMIN` for `Binibit-Labs`.
- RC1 baseline: `20fab25ec9faa29de3676de21574f35cd0012193`.
- Local RC1 HEAD and `origin/main` matched and the tree was clean before RC2 edits.
- RC1 is a descendant of `c305a0b675e29f7107afe87584c1d72f42c51fea`.
- CI run `30754379269` completed successfully for the exact RC1 SHA.
- The workflow had no `continue-on-error`, conditional skips, or skipped release steps.
- RC1 workflow SHA-256: `2ab5ebe6a9a9b8b494a6f6b0f40c40cf0fd957674021f0afa04b27375b9d72a5`.
- `package-lock.json`: `d33e3f85ad3cac1385e12e50139dbb03c1e356c06efcf70d924c635c499e88ca`.
- `foundry.lock`: `83d92f25810f6ae04ab71269788650320afa6774c1a887f4557d0eac8c7755ce`.
- The RC1 run retained zero workflow artifacts.

Production source is `src/BiniTokenV2.sol` and `src/BiniMigrationVault.sol`.
Deployment scripts are `script/DeployBiniV2.s.sol`,
`script/DeployBiniTokenV2.s.sol`, `script/BootstrapDistribution.s.sol`,
`script/MigrateKnownHolders.s.sol`, and `script/VerifyBiniV2.s.sol`.

Tests cover the core token, migration vault, governance, lifecycle, invariants,
forked V2/V3/V4 behavior, deployment/distribution/migration scripts, upgrades,
and the Python release CLI. RC1 review outputs are the seven files under
`review/` plus the top-level RC1 reconciliation, runbook, backlogs, manifest
example, and verdict.

The final RC2 SHA must be taken from the successful CI run and artifact name;
no document claims a self-referential commit hash.
