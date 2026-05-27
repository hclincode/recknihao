# Iter126 Q2 — Judge Score

**Score**: 4.75 / 5 (Tech 5, Clarity 5, Practical 5, Completeness 4)

## Verdict
A strong, production-ready answer. It correctly distinguishes the metadata-only rename from the unsupported VARCHAR -> DECIMAL change, gives the right four-step add/backfill/swap/drop pattern, and includes practical guardrails (TRY_CAST validation, per-partition backfill, parallel-live columns, Debezium upstream fix). Only minor gaps: it does not explicitly call out that the partition transform must not be affected by the rename (cosmetic safety note), and it does not note that under prod's Hive Metastore + Iceberg 1.5.2 the rename is propagated via Iceberg metadata (not HMS column rename) — both minor for this specific question.

## What was verified correct (via WebSearch)
- Iceberg tracks columns by unique field ID, rename is metadata-only, projection by field ID — confirmed (iceberg.apache.org/docs/latest/evolution/, iceberg.apache.org/spec/).
- The exact three safe promotions: int -> long, float -> double, decimal(P,S) -> decimal(P2,S) where P2 > P, scale fixed — verbatim match with Iceberg spec.
- Trino Iceberg connector supports ALTER TABLE RENAME COLUMN — confirmed (trino.io/docs/current/connector/iceberg.html).
- TRY_CAST exists in Trino and returns NULL on failure — confirmed (trino.io/docs/current/functions/conversion.html).
- UPDATE is supported on Iceberg v2 tables in Trino (Trino's MERGE machinery powers DELETE/UPDATE) — confirmed; Trino 467 has this.
- DROP COLUMN supported on Iceberg in Trino — confirmed.
- VARCHAR -> DECIMAL direct ALTER COLUMN SET DATA TYPE is NOT supported (only widening, and Trino 450+ added the opposite direction: decimal/int -> varchar). The answer correctly says the direct change is not allowed and prescribes the add-new-column migration pattern.

## Errors or gaps
- LOW: Does not mention the partition-transform caveat from the Iceberg spec (type promotion is rejected if the field is the source of a partition transform that would hash/bucket differently). Not directly relevant here (rename is unaffected; type change is being done via new column), but worth a passing mention for completeness.
- LOW: Does not mention that on Hive Metastore-backed Iceberg the rename is purely an Iceberg metadata.json change and Hive Metastore's own column list is irrelevant for Iceberg queries — could pre-empt confusion from engineers who check HMS and see stale column names.
- LOW: Does not mention `ALTER TABLE ... ALTER COLUMN ... SET DATA TYPE` as the Trino syntax for the supported widening cases, so an engineer might not realize the API exists for the legal promotions.
- LOW: Could note that after Step 4 DROP COLUMN, the column ID is retired permanently (cannot be re-added with same name to recover) — minor reinforcement of "do not drop until all consumers migrated".
- LOW: Postgres analogy in "Why Iceberg behaves like Postgres here" is slightly imprecise — Postgres tracks columns by `attnum` (not OID); OID is a table/object identifier. Does not affect the SaaS engineer's decision but is a small factual slip.

## Resource fix recommendations
- Add a short note in the schema-evolution resource: "Type promotion is rejected if the field is the source-id of a partition transform that would produce different values after promotion (e.g., bucket[N] on an int promoted to long is fine; int promoted to string is not)."
- Add the Trino-specific syntax `ALTER TABLE ... ALTER COLUMN col SET DATA TYPE BIGINT` for the legal widening cases so engineers know how to invoke the supported promotions from Trino.
- Add a one-liner: "Column IDs are never reused — once you DROP COLUMN, the old column ID is retired; re-adding the same name creates a brand-new column ID with NULLs for old rows."
- Tighten the Postgres analogy: prefer "Postgres tracks columns by `attnum`, not by name" over "internal OID".

## Topic state
- Iceberg schema evolution (rename, add, drop, type promotion rules): PASS — this answer demonstrates the topic is well-covered by current resources.

Sources:
- [Evolution — Apache Iceberg](https://iceberg.apache.org/docs/latest/evolution/)
- [Iceberg Spec — Schema Evolution / Type Promotion](https://iceberg.apache.org/spec/)
- [Iceberg connector — Trino docs](https://trino.io/docs/current/connector/iceberg.html)
- [ALTER TABLE — Trino docs](https://trino.io/docs/current/sql/alter-table.html)
- [Conversion functions (TRY_CAST) — Trino docs](https://trino.io/docs/current/functions/conversion.html)
- [Release 450 — Trino docs (decimal/int -> varchar)](https://trino.io/docs/current/release/release-450.html)
- [Release 467 — Trino docs](https://trino.io/docs/current/release/release-467.html)
