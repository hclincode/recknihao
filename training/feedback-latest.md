# Judge Feedback — Iter 324

Date: 2026-05-27
Phase: extended
Topics: Trino 467 Iceberg maintenance — what runs where (Q1) + JSONB column ingestion (Q2)

---

## Q1 — Trino 467 vs Spark for Iceberg maintenance

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | Every claim verifies against official Trino docs: (1) Trino 467 `expire_snapshots` accepts ONLY `retention_threshold`; `retain_last` + `clean_expired_metadata` added in Trino 479 (Dec 2025) — verified via PR #27357 / Release 479 notes. (2) `optimize_manifests` was added in Trino 470 (Feb 5, 2025), so Trino 467 has no native manifest rewrite — Spark `CALL iceberg.system.rewrite_manifests` is the only path. Answer correctly says "added in Trino 470." (3) Trino's `ALTER TABLE ... EXECUTE remove_orphan_files` has no `dry_run` per current docs; only Spark CALL form supports it. (4) Trino's default `iceberg.expire-snapshots.min-retention` and `iceberg.remove-orphan-files.min-retention` are both `7d`. (5) Spark's named-arg form `CALL iceberg.system.expire_snapshots(table => ..., older_than => ..., retain_last => N)` is correct. No fabrications. |
| Beginner clarity | 4 | Plain-language framing of the version mismatch up front ("That syntax... was added in Trino 479 (December 2025). On Trino 467, those parameters don't exist — which is exactly the error you saw") directly resolves the user's confusion. Code blocks are clean, comments are useful. The matrix table consolidates the cross-engine story. Minor gap: doesn't define "snapshot" or "manifest" for a true beginner — acceptable here because the user has hands-on experience already (they mentioned running statements against the cluster). |
| Practical applicability | 5 | Engineer knows exactly what to run on prod Trino 467 today: a copy-pasteable cheat sheet, a "what runs where" decision matrix, a 3-step cleanup sequence, AND a follow-up note ("After the one-time cleanup, schedule these weekly"). Storage-cost framing (the user's actual problem) is addressed by the optimize -> expire -> orphan sequence. Spark-only escape hatches (`retain_last`, `dry_run`, `rewrite_manifests`, sub-7-day retention) are each shown with the exact Spark CALL form. No abstract advice — every recommendation is a runnable statement. |
| Completeness | 5 | Covers the four asked-about dimensions: (a) why the parameters don't exist on 467 (version explanation); (b) what Trino 467 CAN do (full working syntax); (c) what is Spark-only (`retain_last`, `clean_expired_metadata`, `rewrite_manifests`, `dry_run`, sub-7-day retention); (d) recommended cleanup sequence for the user's stated storage-cost situation. The 7-day floor is called out explicitly for both procedures, which is a subtle gotcha most answers miss. |
| **Average** | **4.75** | **PASS** |

### What Worked
- Opens with the direct answer to the user's error ("That syntax was added in Trino 479") — no preamble.
- Explicit Trino-version-to-procedure-version mapping (467 = retention_threshold only; 479 = +retain_last +clean_expired_metadata; 470 = +optimize_manifests). All three version cutoffs verified correct against trino.io release notes.
- Clear "what requires Spark" section with the exact CALL forms — and the right reasons for each (retain_last, dry_run preview, manifest rewrite, sub-7-day floor).
- The 7-day Trino floor on BOTH `expire_snapshots` AND `remove_orphan_files` is called out, which is the second-most-common Trino-467 maintenance gotcha after the wrong-parameter error.
- The decision matrix table is a clean reference the engineer can save and reuse.
- The recommended 3-step cleanup sequence (compact -> expire -> orphan) gives the engineer a concrete next action that directly addresses their stated storage problem.
- "Run step 3 from Spark with `dry_run => true` first if you want to preview" is responsible safety guidance for an irreversible operation.

### What Missed
- Minor: no explicit mention of `rollback_to_snapshot` being Trino-native via the positional `CALL iceberg.system.rollback_to_snapshot('schema','table',id)` form — but this is outside the scope of what the user asked, and including it could clutter the answer. Acceptable omission.
- Minor: doesn't mention that `optimize` and `expire_snapshots` can also use a `WHERE` partition predicate on Trino 467 for per-tenant scoping — again, outside the scope of the question. Acceptable.
- Minor: the answer states "`optimize_manifests` was added in Trino 470" via comment in the matrix, but doesn't explicitly note that the Iceberg-side procedure name is `rewrite_manifests` and the Trino-side EXECUTE name will be `optimize_manifests` (a naming mismatch some readers find confusing). Resource 17 explains this; the answer just uses `rewrite_manifests` consistently because Trino 467 only has the Spark form available.

### Technical Accuracy (verified)
WebSearch verification confirms every load-bearing claim:

1. **`retain_last` and `clean_expired_metadata` are Trino 479+** — verified against the Trino docs and Release 479 notes (Dec 14, 2025; PR #27362 / issue #27357). On Trino 467, only `retention_threshold` is accepted. The answer is correct.
2. **`optimize_manifests` was added in Trino 470 (Feb 5, 2025)** — verified against Release 470 notes ("Add the optimize_manifests table procedure. [#14821]"). The answer states "added in Trino 470" which matches. (The answer uses the name `rewrite_manifests` for the Spark side and labels Trino as not having it; technically the Trino EXECUTE procedure name is `optimize_manifests`, but since Trino 467 doesn't have it at all, this isn't a user-visible distinction here.)
3. **Trino's `remove_orphan_files` does NOT support `dry_run`** — verified: current Trino Iceberg connector docs list `remove_orphan_files` with only `retention_threshold` as a parameter; `dry_run` is only on the Spark `CALL iceberg.system.remove_orphan_files` form. The answer is correct.
4. **7-day floor for BOTH `expire_snapshots` and `remove_orphan_files`** — verified: Trino docs confirm `iceberg.expire-snapshots.min-retention` and `iceberg.remove-orphan-files.min-retention` both default to `7d`. The answer is correct.
5. **Spark `CALL iceberg.system.expire_snapshots(table => '...', older_than => ..., retain_last => N)`** — verified against Apache Iceberg Spark procedures docs. The named-argument form with `older_than` as a timestamp expression is the canonical Spark form. The answer is correct.

No technical errors found.

### Rubric Update
- Iceberg table maintenance: prior avg 4.552 across 21 questions → (4.552 × 21 + 4.75) / 22 = (95.592 + 4.75) / 22 = 100.342 / 22 = **4.561 across 22 questions**. Status: **PASSED**.

---

## Q2 — JSONB column ingestion into Iceberg

### Score
| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | Every load-bearing claim verifies. (1) `JSON_VALUE(details, '$.plan_tier' RETURNING varchar NULL ON EMPTY NULL ON ERROR)` is valid Trino SQL/JSON syntax (verified against Trino 481 JSON functions docs — RETURNING + ON EMPTY/ON ERROR clauses are documented). (2) `json_extract_scalar(col, '$.field')` is a real Trino function with the exact signature shown (verified). (3) PySpark `get_json_object(col, path)` signature matches PySpark 4.x docs — `ColumnOrName` first arg accepts a plain string column name, so `get_json_object("details", "$.plan_tier")` is valid. (4) The Parquet/JSON statistics claim is correct: per Parquet logical type spec, "no min/max statistics should be saved for [JSON] type and if such non-compliant statistics are found during reading, they must be ignored" — so file/row-group pruning on nested JSON fields is genuinely impossible. (5) Iceberg `ADD COLUMN` as metadata-only with NULL for existing rows is verified against the Iceberg evolution docs. Minor nit (does not affect score): "Parquet stores JSON as an opaque string" — technically Parquet stores JSON as BYTE_ARRAY (annotated with JSON logical type), not a string per se, but the functional consequence is identical and the simplification is fair for a SaaS engineer. |
| Beginner clarity | 4.5 | Strong scaffolding for a beginner. Opens with "The Core Problem" framing that names the failure mode in plain language ("the dashboard killer pattern for JSONB stored as-is"). Two options labeled with explicit trade-off phrasing ("Simplest, Slowest" / "Recommended for Dashboards"). The "Decision Rule" one-liner ("Flatten anything you GROUP BY, WHERE, or JOIN ON") is the kind of takeaway a beginner will remember and apply. The trade-off matrix at the end is scannable. Minor: terms like "row-groups," "column statistics," and "file skipping" appear without one-line gloss — a true beginner would benefit from "row-group = Parquet's internal chunk of rows, typically ~100k rows; column statistics let Trino skip whole row-groups without reading them." Not a serious gap because the context makes the meaning recoverable. |
| Practical applicability | 5 | The engineer knows exactly what to do in the production stack (Spark + Iceberg 1.5.2 + Trino 467 + MinIO): (a) add `get_json_object` calls to the existing Spark ingestion job to extract `plan_tier`, `feature_flags`, `region`; (b) rename the original column to `details_raw`; (c) Trino queries become simple equality predicates with column pruning. The `ALTER TABLE ... ADD COLUMN` workflow for late-added fields is concrete and matches Iceberg's actual metadata-only semantics. The COALESCE backfill bridge during transitions is the operationally correct pattern. Quantified benefit ("the difference between sub-second and 30-second dashboard queries") sets realistic expectations. Fits the stated environment (Debezium + Kafka + Iceberg + Trino on prem) without recommending anything incompatible. |
| Completeness | 4.5 | Both halves of the engineer's question are answered: (1) "extract during ingestion vs query JSON from Trino" → clearly "flatten hot fields, keep raw blob for the rest"; (2) "is there a way to query the JSON string from Trino that performs well enough?" → "yes for ad-hoc, no for interactive dashboards" with the actual functions shown. The follow-up question that engineers always have next ("what about new fields later?") is anticipated and answered with both forward-only and backfill paths. Minor gaps: (a) does not mention the `from_json` + STRUCT alternative for cases where the JSON shape is stable (resource 13 has a decision table for STRUCT vs flat-VARCHAR — answer doesn't surface that there's a middle option); (b) doesn't note that `get_json_object` returns NULL silently on parse failure for the whole row's blob, whereas per-key extraction degrades more gracefully; (c) does not call out the on-prem production stack explicitly (no Spark version, no Iceberg 1.5.2 nod) — though the advice fits it naturally. None of these are deal-breakers for a clear, focused answer. |
| **Average** | **4.75** | **PASS** |

### What Worked
- Opens with the root cause in one sentence ("Parquet stores JSON as an opaque string with no per-field indexing or statistics") — directly explains WHY the Trino queries can't filter efficiently.
- Two-option framing with explicit performance trade-off labels makes the decision crisp.
- The "Decision Rule" one-liner ("Flatten anything you GROUP BY, WHERE, or JOIN ON") is the takeaway every SaaS engineer needs and will remember.
- COALESCE pattern during backfill is the production-correct way to add a new flattened field without breaking dashboards mid-flight.
- The forward-only path with `ALTER TABLE ADD COLUMN` (metadata-only, instant) and the explicit "historical rows return NULL — usually acceptable for analytics" honestly describes the trade-off most teams choose.
- Quantified the benefit ("sub-second vs 30-second", "<5% of files for a selective filter") — realistic numbers that match resource 13's "45s → 1-3s" example.
- Shows both `JSON_VALUE` (strict, SQL-standard) and `json_extract_scalar` (simpler, error-tolerant) for the keep-as-VARCHAR option — exactly the distinction resource 13 draws.

### What Missed
- Does not surface the third option from resource 13's decision table: Iceberg `STRUCT<...>` for genuinely stable JSON shapes, which gives typed columns + per-field statistics WITHOUT having to maintain a separate flattening step in Spark. For the user's case (controlled fields like `plan_tier`/`region`/`feature_flags`), STRUCT might actually be the better answer.
- Doesn't mention the `from_json` + struct-schema alternative that's documented in resource 13 as the "all keys at once" pattern when you control the producer.
- "Row-groups," "column statistics," and "file skipping" used without one-line gloss for a true beginner.
- No explicit nod to the production environment (Spark + Iceberg 1.5.2, on-prem MinIO, Trino 467). The Spark code is generic — fine, but explicitly framing it as "in your Debezium consumer / Spark Structured Streaming job" would help the engineer see exactly where to put it.
- Does not flag that `get_json_object` returns NULL silently on malformed JSON for the whole row's blob (a graceful-degradation note that resource 13 calls out explicitly).
- Schema-evolution edge case missed: if Postgres `JSONB` actually arrives as Debezium-produced JSON-typed Kafka value, the Spark consumer may need to cast/decode before applying `get_json_object` — not directly addressed.

### Technical Accuracy (verified)

WebSearch verification against trino.io, spark.apache.org, iceberg.apache.org, and parquet.apache.org:

1. **`JSON_VALUE(col, '$.field' RETURNING varchar NULL ON EMPTY NULL ON ERROR)`**: **VERIFIED**. Trino 481 JSON functions docs document the full SQL/JSON `JSON_VALUE` syntax with `RETURNING <type>` and `[NULL | ERROR | DEFAULT <value>] ON EMPTY` / `[NULL | ERROR | DEFAULT <value>] ON ERROR` clauses. The form in the answer is valid Trino SQL. Trino 467 also supports this (SQL/JSON support landed well before 467).
2. **`json_extract_scalar(col, '$.field')`**: **VERIFIED**. Real Trino function. Docs: "Returns the result value as a string... The value referenced by json_path must be a scalar." Exact signature shown in the answer.
3. **PySpark `get_json_object(col, path)`**: **VERIFIED**. PySpark docs confirm signature `get_json_object(col: ColumnOrName, path: str) → Column`. The answer's `get_json_object("details", "$.plan_tier")` uses a string column name, which is accepted by ColumnOrName. Returns NULL for invalid JSON input.
4. **Parquet JSON logical type opaque, no per-field statistics**: **VERIFIED**. Parquet logical type spec explicitly states: "When writing data, no min/max statistics should be saved for [JSON] type and if such non-compliant statistics are found during reading, they must be ignored." So predicate pushdown / row-group skipping on nested JSON keys is genuinely impossible — Trino must re-parse every row. The answer's claim is correct.
5. **Iceberg `ADD COLUMN` metadata-only with NULL for existing rows**: **VERIFIED**. Apache Iceberg evolution docs: "ADD COLUMN is a metadata-only operation where the values of newly added columns on existing rows are NULL... Added columns never read existing values from another column." Matches the answer exactly.

Sources:
- [JSON functions and operators — Trino 481 Documentation](https://trino.io/docs/current/functions/json.html)
- [pyspark.sql.functions.get_json_object — PySpark 4.1.1 documentation](https://spark.apache.org/docs/latest/api/python/reference/pyspark.sql/api/pyspark.sql.functions.get_json_object.html)
- [Logical Types — Apache Parquet](https://parquet.apache.org/docs/file-format/types/logicaltypes/)
- [Evolution — Apache Iceberg](https://iceberg.apache.org/docs/latest/evolution/)

### Rubric Update
- Postgres-to-Iceberg ingestion: prior avg 4.492 across 113 questions → (4.492 × 113 + 4.75) / 114 = (507.596 + 4.75) / 114 = 512.346 / 114 = **4.494 across 114 questions**. Status: **PASSED**.

---

## Iter 324 Summary

**Iter 324 average: (4.75 + 4.75) / 2 = 4.75 — PASS** ✓ (Q1 PASS / Q2 PASS — clean iteration)

### Notable
- Q1 4.75: Trino 467 vs Spark for Iceberg maintenance — sharp recovery from Iter 323's `retain_last`/`clean_expired_metadata` fabrication. Responder now correctly maps version-to-parameter (467 = retention_threshold only; 470 = +optimize_manifests; 479 = +retain_last/+clean_expired_metadata) and gives the exact Spark CALL fallbacks. The resource/17 fix (Trino version availability table) from Iter 323 paid off cleanly.
- Q2 4.75: JSONB column ingestion into Iceberg — strong, focused answer. Correct trade-off framing (flatten hot keys, keep raw blob). Verified `JSON_VALUE` syntax, `json_extract_scalar`, PySpark `get_json_object`, Parquet's no-stats-on-JSON behavior, and Iceberg `ADD COLUMN` metadata-only semantics. One topic-completeness gap: the `from_json` + STRUCT alternative for stable-shape JSON is omitted but documented in resource 13.

### Resource fixes applied this iteration
None needed. Both answers pass cleanly. The Iter 323 resources/17 version-availability table is holding under Q1's direct probe.

### Suggested focus for Iter 325
- **Iceberg table maintenance** (4.561/22): probe `retain_last` as a standalone parameter (different angle from Q1) to confirm the version-gate framing extends across phrasings, not just to the joint `retain_last + clean_expired_metadata` pair. Could also probe `optimize_manifests` directly (the third Trino-version-gated procedure mentioned).
- **Postgres-to-Iceberg ingestion** (4.494/114): probe the STRUCT vs flat-VARCHAR vs MAP decision specifically — Q2 left STRUCT and `from_json` off the table. A question framed as "the JSON shape IS stable and we control the producer — is flatten still the right call?" would force the trade-off comparison.
- **Version-skew audit (continuing)**: any topic that recommends Trino procedure parameters should still cross-check against Trino 467 docs. Q1 shows the fix held; one more probe at a different version-gated parameter (e.g., a recently added Iceberg connector procedure or property) would lock the pattern.
