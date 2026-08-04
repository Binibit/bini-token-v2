# BINI V1 holder distribution key table

Status: `OWNER_REVIEW_DRAFT_NOT_EXECUTABLE`

This document freezes a reviewable holder universe and a draft distribution scenario. It is not an owner approval, production manifest, Safe proposal, or authorization to broadcast transactions.

## Canonical snapshot

| Field | Value |
|---|---|
| Network | Ethereum Mainnet (`chainId 1`) |
| V1 token | `0x445d03f499f1c150615957bb87588fb465fc91cc` |
| Symbol / decimals | `BINI` / `12` |
| Snapshot block | `25680981` |
| Block hash | `0x962176abacf23d24fbbaacfb7d1e28570685ccbfd7f90a061af97b2fde77af78` |
| Snapshot time | `2026-08-04T10:34:11Z` |
| Holders | `497` |
| Reconciled supply | `1,000,000,000.000000000000 BINI` |
| Raw-balance sum | `1000000000000000000000` |
| Snapshot SHA-256 | `f5ea5f0b44c38f7e9d154804f32f3c9182aa9db80b65caa73652dc55b8689c98` |

The holder-address index was discovered from Etherscan. Every balance, contract-code check, total and ranking was then resolved through pinned-block Mainnet RPC reads. The 497 balances reconcile exactly to `totalSupply`; no Mainnet transaction was sent.

## Classification

| Class | Count | V1 BINI | Draft action |
|---|---:|---:|---|
| Top-five owner classification required | 5 | 988,424,252.009994323982 | Hold until wallet ownership/tokenomics mapping is signed |
| Ordinary EOA candidates | 480 | 10,778,070.305310606302 | Eligible only after owner policy approval |
| Uniswap V4 PoolManager | 1 | 796,919.500028702821 | Exclude from direct-holder distribution |
| Custodial exchange deposits | 3 | 554.873050000000 | Hold pending alternate destination and custody proof |
| Smart contracts | 2 | 104.073564052836 | Hold pending ownership/recovery/compatibility review |
| EIP-7702 delegated accounts | 6 | 99.238052314059 | Hold pending account-control and destination review |

## Draft scenario: ordinary EOAs with at least 1,000 V1 BINI

This cutoff is a scenario inferred from the supplied table ending at rank 32 / exactly 1,000 BINI. It is not an approved eligibility rule.

| Metric | Value |
|---|---:|
| Draft recipients | 26 |
| Draft V1 amount | 10,770,323.813620009096 BINI |
| Draft V2 amount | 10,770,323.813620009096000000 BINI |
| Exact V2 raw amount | 10770323813620009096000000 |
| Draft batches | 2 (`20 + 6`) |
| Ordinary EOAs below cutoff | 454 |
| Amount below cutoff | 7,746.491690597206 BINI |

Conversion is exact: `v2RawAmount = v1RawAmount × 1,000,000` for the 12-to-18 decimal change. The human-readable BINI amount is unchanged.

| Batch | Index | V1 rank | Draft destination | V1/V2 human amount |
|---:|---:|---:|---|---:|
| 1 | 1 | 6 | `0xd15749a7ae26cbab8f56831e029471d4cc756082` | 5020982.682245025491 |
| 1 | 2 | 7 | `0x83ff1cd3ae8e7a2d55a43815985b11d41540ac65` | 1524956.194156863776 |
| 1 | 3 | 8 | `0xad711454019916c9c170426c7c8f38bde739de57` | 948059.794773655813 |
| 1 | 4 | 9 | `0xa22d7cb335dfbdd6338be3dafa46284e71effdc2` | 865000.044816488073 |
| 1 | 5 | 10 | `0xfd00644213cc50dab420298ac4a103a11d79d4f1` | 852437.731810681454 |
| 1 | 6 | 11 | `0x0a80a5921ff574795a9c4e01aed176d6276d3820` | 840605.974156609188 |
| 1 | 7 | 13 | `0x5a57ee9a7439f665639c25520d20c06b6a4cb20a` | 215335.945204563372 |
| 1 | 8 | 14 | `0xbefa5f098ab2804e7e409b8d683994e1b0e45849` | 111450.000000000000 |
| 1 | 9 | 15 | `0x873816603bd7eb400ef89364e2d8ea4ac5c490e2` | 105753.848404187421 |
| 1 | 10 | 16 | `0xcf89b519825876c7ac6dfe56a1caa35abfce565f` | 71243.791691435985 |
| 1 | 11 | 17 | `0x7c83a7e99f039ee9a699c3d8f04906d373f5fc36` | 66402.948578945192 |
| 1 | 12 | 18 | `0x219d05ac1ccff122495cfea25a8fc059e19fae94` | 43116.827566299812 |
| 1 | 13 | 19 | `0x5eeed48afb574271d5150aaaa254dc791a5d981a` | 25620.000000000000 |
| 1 | 14 | 20 | `0x7637b9b75f7036683dd92664bfd693401be04b67` | 23000.000000000000 |
| 1 | 15 | 21 | `0x2eed6597e3f4762b907e194a62ac678de1186120` | 17725.299374436916 |
| 1 | 16 | 22 | `0xaa41d96d5ca0a9e4a1537988469e918c620ae445` | 7341.061149199077 |
| 1 | 17 | 23 | `0xda4368a900a6010493f30639c5f71ccb79ad53da` | 4000.000000000000 |
| 1 | 18 | 24 | `0x5192f343e7d494d65d50c5c75ec185bf8ae26f85` | 3818.957837226085 |
| 1 | 19 | 25 | `0xcb17ea8c4b0f869d1a5837e6764b355f1dbb90cb` | 3655.622955813256 |
| 1 | 20 | 26 | `0xf20fee5b0233c67c1377013937c893188f85e412` | 3655.622955813256 |
| 2 | 1 | 27 | `0x7e77b27607f6736beb767078ca27c5249a1e37df` | 3641.569697193433 |
| 2 | 2 | 28 | `0xb2c23eed316e7ee29a758dcc194616a03b5cbe57` | 3619.896252215723 |
| 2 | 3 | 29 | `0x92070978459b129f2a3c0206a7ce8ce1420dc241` | 3499.999993355773 |
| 2 | 4 | 30 | `0x1699520ace8741c9359126f3cecf5b800abe689f` | 3000.000000000000 |
| 2 | 5 | 31 | `0x2bd0dc9b2e0463b2bfd1dfd558b32e8a467967fa` | 1400.000000000000 |
| 2 | 6 | 32 | `0x0f99f38ddc828216b9d7ab3ecfe2509cd88507fd` | 1000.000000000000 |

## Top-five hold

| Rank | Address | V1 BINI | Required decision |
|---:|---|---:|---|
| 1 | `0x876146f9e8863ba09a7eff0d8209e708a3fee802` | 883718640.903163448882 | Identify treasury/tokenomics/holder ownership |
| 2 | `0x6be007b1befd60624a55b901095dc2f4218a6211` | 56753033.525215692135 | Identify treasury/tokenomics/holder ownership |
| 3 | `0x37c441d73308f0778f73664a6ee1be96c43745ab` | 19948969.216406505657 | Identify treasury/tokenomics/holder ownership |
| 4 | `0xe32cfba7afd85c04d7c608c98e429cc6a000858a` | 18003608.365208677308 | Identify treasury/tokenomics/holder ownership |
| 5 | `0x706df7f43f2d552928c72c04f6bd7b056d76b336` | 10000000.000000000000 | Identify treasury/tokenomics/holder ownership |

## Owner gates before an executable manifest

1. Classify the top-five addresses and assign each approved amount to a named V2 allocation.
2. Approve the holder eligibility rule: all eligible holders, the draft `>= 1,000` scenario, or another documented threshold/remediation path.
3. Freeze V1 eligibility/deprecation rules and prevent V1/V2 double exposure.
4. Resolve PoolManager, exchange-deposit, contract and EIP-7702 destinations.
5. Select `SOURCE_ALLOCATION_ID`, the matching existing V2 allocation Safe, and an owner approval reference.
6. Regenerate and validate the production manifest, then simulate Safe batches before any proposal or broadcast.

Alternative ordinary-EOA scenarios are retained in the workbook: `>=100` (42 recipients), `>=10` (66), `>=1` (476), and all 480 EOAs.
