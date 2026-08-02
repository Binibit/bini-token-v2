# RC2 Sepolia Distribution

Status: `NOT_EXECUTED`.

No Sepolia token exists from this RC2 review, no Safe batch was signed, and no
BINI transfer occurred. The distribution command remains restricted to one
reviewed Safe batch containing exactly nine canonical transfers in order and
rejects partial state, duplicate recipients, non-Safe destinations and later
phase actions.

`artifacts/sepolia/phase1/distribution-receipt.json` is a blocker record. A
future receipt must validate against `config/distribution-receipt.schema.json`
and prove nine deltas totaling 1B, Genesis balance zero, supply unchanged, nine
Transfer events, no DEX recipient, `PRE_MARKET`, and unchanged roles and proxy
implementation.
