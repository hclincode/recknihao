# Iter65 Q1 Judge Feedback

## Score: 4.75 / 5.0

| Dimension | Score |
|---|---|
| Completeness | 5 |
| Accuracy | 4 |
| Clarity | 5 |
| No hallucination | 5 |
| **Average** | **4.75** |

## Points covered

All 5 expected-coverage points hit:

1. **Iceberg schema evolution is safe / metadata-only / NULL for old rows** — explicit in the "What happens to old rows" section with a concrete May 1 / May 8 / May 9 timeline example, and reinforced with "metadata-only — no data rewrite. It runs in milliseconds even on a 10 TB table."
2. **Pattern-specific fix** — three patterns clearly delineated:
   - Pattern A (full-refresh / createOrReplace): update job code, do NOT run ALTER TABLE (explicit warning that the column would vanish on next run — silent data loss).
   - Pattern B (incremental append): run ALTER TABLE ADD COLUMN then update Spark job's SELECT list, then re-run.
   - Pattern C (CDC): set `schema.evolution=basic` in the connector.
3. **Root cause** — covered in "Why did your job break in the first place" section: SELECT * vs explicit column list, or DataFrame schema mismatch on append.
4. **Pre-flight schema-diff check** — fully described conceptually AND with a complete runnable Python function (`check_schema_drift`) that compares Postgres `information_schema.columns` to Iceberg `DESCRIBE TABLE` and raises a descriptive RuntimeError on drift.
5. **Practical SQL/code** — correct ALTER TABLE syntax; complete Python diff function; correct Spark JDBC read examples.

## Factual issues (if any)

**Minor**: The claim "set `schema.evolution=basic` in the connector config" for the Debezium Iceberg sink connector is the wrong property name. `schema.evolution=basic` is actually the property for the Debezium **JDBC sink** connector. The Debezium Iceberg sink connector (memiiso/debezium-server-iceberg or the Apache Iceberg Kafka Connect sink) uses different properties:
- `iceberg.tables.evolve-schema-enabled=true`
- `debezium.sink.iceberg.allow-field-addition=true`
- `iceberg.tables.auto-create-enabled=true`

This inaccuracy is propagated from resource `13-postgres-to-iceberg-ingestion.md` (lines 778, 934, 946), which uses the same wording. The weak-ai-responder faithfully reproduced what's in the resource, so this is a resource bug, not a hallucination. Recommend the teacher fix this in resource 13 in a future iteration. Cost the answer 1 point on Accuracy.

All other technical claims are verified accurate:
- `ALTER TABLE ADD COLUMN` is metadata-only with no data rewrite — confirmed against iceberg.apache.org/docs/latest/evolution/.
- Old files return NULL for newly added columns — confirmed in the same docs ("Added columns never read existing values from another column").
- Iceberg's schema evolution is column-name-based, not position-based (unlike Hive) — confirmed in the Iceberg spec.
- `createOrReplace()` would wipe a manually-added column on next run — correct mental model for full-refresh writers.

## Notes

This is one of the strongest answers in the Postgres-to-Iceberg topic so far. The structure is exemplary: it begins by partitioning the problem space (3 patterns), gives the right fix per pattern with explicit warnings about wrong fixes, addresses the "old rows" sub-question separately with a worked example, and ends with a complete prevention mechanism the engineer can paste in. The SaaS engineer with no OLAP background gets everything they need: the conceptual model (column-name-based evolution = safe), the SQL (`ALTER TABLE ... ADD COLUMN ...`), the code (`check_schema_drift` function), and the warning (don't ALTER on Pattern A).

The only blemish is the borrowed `schema.evolution=basic` config name, which should be corrected at the resource level. Topic running average moves from 4.363 (62q) to **4.369 (63q)**. PASSED.
