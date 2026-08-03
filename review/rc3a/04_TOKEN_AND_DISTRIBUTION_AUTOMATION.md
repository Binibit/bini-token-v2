# Token and Distribution Automation

Token deployment now accepts an independently deployed and verified Timelock
and selects `DeployBiniTokenV2.s.sol` for that topology. The initializer remains
atomic through ERC1967Proxy and the token core is byte-for-byte unchanged.

The canonical local rehearsal deploys the real UUPS implementation/proxy,
checks roles and implementation slot, then executes the canonical nine-transfer
distribution through the Genesis Distribution Safe and official MultiSend.
The real-Safe test records exactly nine token Transfer events, exact recipient
balances, zero remaining Genesis balance and unchanged total supply.

Partial or inconsistent distribution state is rejected and replay is detected
through Safe nonce/hash receipts and on-chain balance reconciliation.
