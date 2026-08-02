# RC2 Repository Governance

`CODEOWNERS` now covers Solidity, scripts, tests, tools, CI, configs, manifests,
policy and the audit package. CI uploads an exact-SHA evidence bundle retained
for 90 days, including ABI, selectors, storage, bytecode, build-info, Slither,
coverage, UUPS, test/fork/Anvil logs, Anvil receipts and receipt schemas.

Required `main` policy:

- pull request required;
- required status check `Release gates`;
- one independent approval;
- stale approvals dismissed;
- conversations resolved;
- force push and deletion prohibited;
- administrator enforcement, with no bypass until separately ratified.

Activation is blocked. Both GitHub branch-protection and repository-ruleset APIs
returned HTTP 403: the current plan requires GitHub Pro or a public repository.
The repository was not made public and billing was not changed without owner
authorization. `CODEOWNERS` therefore exists but is not enforceable yet.

No RC2 annotated tag is created while protection, real Sepolia rehearsal and
independent review remain incomplete.
