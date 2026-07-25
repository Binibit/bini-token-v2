# Threat Model

## Protected Assets

- fixed supply and holder balances;
- free ordinary transferability;
- inability to fund recognized DEX infrastructure during PRE_MARKET;
- one-way transition to OPEN_MARKET;
- proxy implementation integrity;
- governance and emergency authority separation.

## Trust Assumptions

- the governance Timelock and its proposer/executor policy are correctly
  configured and socially secured;
- the Emergency Pauser Safe threshold and signers are independent enough to
  respond to incidents;
- factory and infrastructure entries are ratified against chain id, runtime
  code hash and implementation;
- external protocol contracts behave according to the reviewed deployment;
- users understand that ERC-20 approvals authorize spenders in the standard way.

## Adversaries And Controls

| Threat | Control | Residual |
| --- | --- | --- |
| Runtime mint, burn or seizure | No launch ABI surface; fixed cap and one-time initializer mint | UUPS can change future logic |
| Unauthorized market opening | `MARKET_MANAGER_ROLE` held by Timelock | Timelock compromise |
| Market state reversal | No reverse function; post-open configuration disabled | UUPS can replace logic |
| Funding known V2/V3 pools | Registered factory confirms deployed pool | Unknown factory or undeployed CREATE2 address |
| Funding V4 market | Explicit PoolManager/infrastructure registry | Missing or misclassified infrastructure |
| Probe gas denial | Fixed gas stipend and fixed-size return copy | A valid factory can become unavailable |
| Malformed contract-wallet probe | Failure means ordinary recipient | Lookalike remains transferable by design |
| Emergency actor abuse | Pauser can pause but cannot unpause, open or upgrade | Availability loss until Timelock action |
| Upgrade corruption | Timelock, UUPS UUID checks, ERC-7201 schema and validation gates | Governance remains a master capability |
| Permit replay | ERC-2612 nonce and deadline validation | User key compromise |

## Explicitly Unprovable Claim

The token cannot allow every arbitrary wallet/contract recipient while
automatically recognizing every current, future or undeployed AMM. In
particular, a future CREATE2 address has no code before deployment and is
indistinguishable from an EOA. Universal AMM blocking is `BLOCKED`; no user
allowlist is introduced as a fallback.

## Operational Monitoring

Before opening, monitor:

- BINI transfers to code-less addresses later used by known factories;
- new official DEX deployments and proxy upgrades;
- changes in code hash for registered infrastructure;
- governance queue operations affecting BINI;
- pause, role and upgrade events.
