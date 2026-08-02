# Documentation Index

## Canon

- [Core product requirement](PRODUCT_REQUIREMENT.md)
- [System architecture](architecture/SYSTEM_ARCHITECTURE.md)
- [PRE_MARKET DEX policy and feasibility boundary](architecture/PRE_MARKET_DEX_POLICY.md)
- [Standards and compliance matrix](STANDARDS.md)

## Security

- [Threat model](security/THREAT_MODEL.md)
- [Internal security review](audit/INTERNAL_SECURITY_REVIEW.md)
- [Release evidence](evidence/RELEASE_EVIDENCE.md)
- [Security reporting policy](../SECURITY.md)

## Operations

- [Release checklist](release/RELEASE_CHECKLIST.md)
- [Deployment runbook](runbooks/DEPLOYMENT.md)
- [Initial distribution runbook](runbooks/INITIAL_DISTRIBUTION.md)
- [V1 to V2 migration runbook](runbooks/V1_V2_MIGRATION.md)
- [Rollback and incidents](runbooks/ROLLBACK_AND_INCIDENTS.md)
- [Market opening runbook](runbooks/MARKET_OPEN.md)
- [Upgrade runbook](runbooks/UPGRADE.md)
- [Emergency runbook](runbooks/EMERGENCY.md)

## RC1 Review

- [Source and CI reality](../review/01_SOURCE_AND_CI_REALITY.md)
- [Token and DEX policy](../review/02_TOKEN_AND_DEX_POLICY.md)
- [Phase 1 distribution](../review/03_PHASE1_DISTRIBUTION.md)
- [Migration Vault](../review/04_MIGRATION_VAULT.md)
- [CLI safety](../review/05_CLI_AND_EXECUTION_SAFETY.md)
- [Test evidence](../review/06_TEST_AND_SECURITY_EVIDENCE.md)
- [Sepolia Phase 1 package](../review/07_SEPOLIA_PHASE1_PACKAGE.md)

## Machine-Readable Sources

- `config/governance-manifest.rehearsal.json`: non-production address and
  DEX-policy candidate data
- `config/bini-storage-schema.json`: canonical ERC-7201 namespace schema
- `policy/allowed-selectors.json`: approved public ABI selectors
- `policy/prohibited-selectors.json`: forbidden launch-version function names
- `artifacts/release/`: generated release fingerprints
