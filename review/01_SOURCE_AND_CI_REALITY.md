# Source and CI Reality

Review date: 2026-08-02. Repository: `Binibit/bini-token-v2` (private).

## Independently observed

- Default branch: `main`.
- Reported and inspected baseline: `c305a0b675e29f7107afe87584c1d72f42c51fea`.
- At review start, local `HEAD` and `origin/main` both equaled that SHA, the tree
  was clean, and the commit was its own verified ancestry point.
- Workflow: `.github/workflows/test.yml`, event `push`, no `continue-on-error`,
  conditional skip, or allow-failure setting.
- GitHub Actions run `30752474663`, attempt 1, ran on the exact baseline SHA and
  concluded `success`. Every reported job step concluded `success`.
- GitHub retained zero run artifacts. Logs exist in Actions but no immutable
  downloadable build/evidence bundle was uploaded.
- `main` was reported by the GitHub API as `protected: false`.

The RC1 reconciliation is a successor change to that independently checked
baseline. Its authoritative identity is the commit containing this report and
the corresponding GitHub Actions run, not the earlier run.

## Control findings

The source claim for the reported baseline is real. A green workflow is not a
security proof, and unprotected `main` plus absent retained artifacts are release
governance gaps. Before mainnet, require branch protection, review requirements,
required CI checks, and retained release evidence with hashes.

## Verdict

`SOURCE_REALITY_GREEN`

This verdict confirms repository/run identity only. It does not authorize
Sepolia or mainnet deployment.
