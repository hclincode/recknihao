# Iter 347 — Q2 Score: Iceberg column rename through Debezium CDC

## Question recap
SaaS engineer renamed `user_name` → `username` in Postgres; Debezium is streaming. Worried whether Iceberg sees this as a rename (safe) or as drop-plus-add (historical data stranded, queries broken).

## Score table

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5.0 | Every load-bearing claim verified against official docs. (1) Iceberg tracks columns by field ID, rename is metadata-only — confirmed at iceberg.apache.org/docs/latest/evolution. (2) Postgres pgoutput does NOT emit DDL events for column renames — confirmed at debezium.io PostgreSQL connector docs. (3) Debezium learns the new column name via the WAL RELATION message on the next DML — confirmed. (4) Trino `ALTER TABLE … RENAME COLUMN old TO new` syntax — confirmed at trino.io/docs/current/sql/alter-table.html. (5) Auto-evolution risk (mergeSchema=true might create a brand-new column with a new field ID instead of recognizing rename intent) — accurate; auto-evolution cannot infer rename semantics. (6) Historical data accessibility under the new name via field-ID preservation — confirmed by Iceberg spec. No false statements detected. |
| Beginner clarity | 5.0 | Opens with a direct one-sentence answer to the engineer's exact worry ("rename, not drop-plus-add"). Each section is short, headed, and explains the "why" (field ID tracking) before the "how" (ALTER syntax). Uses the engineer's own column names (`user_name`/`username`) throughout. Jargon (field ID, RELATION message, mergeSchema) introduced with context. The 5-step timeline reads as a story the engineer can follow with zero OLAP background. |
| Practical applicability | 5.0 | Gives the exact ALTER statement, exact runbook (pause → ALTER → update consumer → resume), and a concrete warning about auto-evolution producing two columns. Trino syntax matches the prod stack (Trino 467). Uses the catalog name pattern (`iceberg.analytics.events`) consistent with prior answers. The "explicit ALTER first, do not rely on auto-evolution" prescription is exactly the operational rule the engineer needs. |
| Completeness | 5.0 | Answers the literal question (rename vs drop-plus-add), explains the Postgres-side DDL invisibility, explains how Debezium discovers the rename, explains the consumer failure mode if the engineer does nothing, gives the fix, gives the safety guarantee for historical data, and warns about the auto-evolution two-column trap. Nothing material is missing for this question. |
| **Average** | **5.00** | STRONG PASS (PERFECT) |

## What Worked

- Direct answer to the engineer's framing in the first paragraph — no preamble, no hedging.
- Explicit field-ID explanation tied to *why* the rename is metadata-only and *why* historical data is preserved.
- Correct three-layer separation: Postgres catalog (instant, no WAL DDL) → Debezium discovery (via WAL RELATION on next DML) → Iceberg ALTER (metadata-only, field ID preserved).
- Auto-evolution warning is technically precise: mergeSchema cannot infer rename intent and will produce a duplicate column with a new field ID. This is the exact subtle production bug that wrecks data.
- Trino/Spark syntax convergence call-out ("syntax is identical in both") matches the prod stack and resource file's section at line 4039.
- Runbook is 4 numbered steps with realistic timing ("seconds").

## What Missed

- Nothing critical. Minor opportunities (non-deductive):
  - Could mention that the column ID can be verified via `SELECT * FROM iceberg.analytics."events$files"` or via the table's `schema.json` metadata, for engineers who want to confirm field-ID preservation after the rename.
  - Could mention LSN/snapshot-id checkpoint as a safety net for the pause/resume step.
  - The answer says "syntax is identical in both" Trino and Spark — this is true for RENAME COLUMN specifically but the resource (line 4039) notes the divergence concentrates in type changes. Not a flaw, just a minor opportunity to nuance.

## Technical Accuracy Verification

Verified via WebSearch against official docs:

1. **Iceberg rename is metadata-only via field ID** — confirmed at iceberg.apache.org/docs/latest/evolution. "Renaming a column updates the metadata mapping without touching data files. The column's unique ID stays the same."
2. **Postgres pgoutput emits no DDL for column renames** — confirmed at debezium.io PostgreSQL connector docs: "logical decoding does not support DDL changes." Also: "no changes are recorded in the WAL for existing records when a column is renamed."
3. **Debezium detects rename via RELATION message on next DML** — confirmed: Debezium relies on the pgoutput RELATION message that accompanies the next DML; it cannot detect the rename from the DDL itself.
4. **Trino `ALTER TABLE … RENAME COLUMN old TO new` syntax** — confirmed at trino.io/docs/current/sql/alter-table.html: `ALTER TABLE [IF EXISTS] name RENAME COLUMN [IF EXISTS] old_name TO new_name`.
5. **Auto-evolution mergeSchema cannot infer rename intent** — accurate per Iceberg spec: schema merge applies field-ID matching for known IDs and assigns a new field ID for any column name not in the existing schema. There is no name-similarity heuristic to detect rename intent.
6. **Historical data accessible under new name via field-ID preservation** — confirmed; this is the core schema evolution guarantee from the Iceberg spec.

## Resource Fix Applied

None required. Resource `13-postgres-to-iceberg-ingestion.md` (lines 3751–3786, 4006, 4039) already covers this scenario in detail:
- Line 3762: Postgres rename does NOT generate WAL DDL event.
- Line 3775–3779: Iceberg native rename is metadata-only and preserves column ID.
- Line 3786: Auto-evolution can create orphan column with new field ID — exactly the warning the responder surfaced.
- Line 4006: Summary table entry for RENAME COLUMN.
- Line 4039: Trino/Spark RENAME COLUMN syntax convergence.

The responder's answer is a faithful, well-organized synthesis of the resource. No teacher action needed.

## Rubric Update

**Postgres-to-Iceberg ingestion topic** running average:

(4.509 × 127 + 5.00) / 128 = **4.513 / 128 questions** — PASSED (continuing recovery; 4th consecutive perfect 5.00 on Debezium CDC schema-change scenarios across iter343–347: MERGE_CARDINALITY_VIOLATION, ADD COLUMN, INT→BIGINT type widening, and now RENAME COLUMN).

Subtopic coverage this iteration: column rename through CDC end-to-end (Postgres DDL invisibility, Debezium RELATION discovery, Iceberg field-ID preservation, Trino ALTER syntax, mergeSchema orphan-column trap).
