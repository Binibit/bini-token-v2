# RC2 Phase 2 Accounting Review

Status: `DESIGN_GREEN_NOT_EXECUTED`.

The holder schema and CLI now require source allocation and source Safe on every
record. Funding is represented as `fundingSources`, not an arbitrary single
economic pool. The CLI reconciles holder liabilities against every source,
checks the source Safe against Phase 1 config, enforces the 12-to-18 decimal
conversion and prevents any source from exceeding its original allocation.

The complete rule is in `BINI_V2_PHASE2_MIGRATION_ACCOUNTING_CANON.md`. Phase 2
contracts were not deployed or funded during RC2.
