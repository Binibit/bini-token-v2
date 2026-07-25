# Contributing

Changes must preserve the product canon in `docs/PRODUCT_REQUIREMENT.md`.

Before opening a pull request:

```sh
git submodule update --init --recursive
npm ci --ignore-scripts
make artifacts
make release-check
```

Do not update `policy/allowed-selectors.json` mechanically. Any public ABI
change needs an explicit product and security review. Storage changes require an
updated ERC-7201 schema, upgrade validation and state-preservation tests.

Pull requests should describe product impact, authority changes, storage/ABI
changes, tests added, threat-model changes and release artifact diffs.
