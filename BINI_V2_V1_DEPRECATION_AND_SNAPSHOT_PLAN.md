# BINI V2 V1 deprecation and snapshot plan

Direct V2 distribution leaves every V1 balance intact. Execution must stop with `BLOCKED_V1_DOUBLE_EXPOSURE` if V1 remains economically active or redeemable.

Before manifest freeze, the owner must approve and evidence:

1. the final V1 snapshot block number and block hash;
2. the exact end of V1 eligibility changes;
3. Binibit/CEX V1 deposit and withdrawal policy at and after the cutoff;
4. V1 market and liquidity deprecation steps and dates;
5. an official statement that V1 is no longer redeemable after the frozen snapshot;
6. the 12-decimal V1 to 18-decimal V2 rule (`v2RawAmount = v1RawAmount * 1,000,000`);
7. a unique-holder/destination reconciliation proving no duplicate direct record or later claim can pay the same entitlement twice;
8. signed legacy-holder instructions for every alternate destination.

The snapshot extractor, raw dataset, transformation script/version, canonical manifest hash, reviewer identities, and owner approval reference must be archived together. Any correction after freeze requires a new manifest version, a new hash, full re-review, and new Safe packages. Previously signed batches must never be edited in place.

Open owner inputs: final snapshot/deprecation approval and operational CEX policy evidence have not been supplied in this repository.
