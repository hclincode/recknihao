# Iter 541 Judge Feedback (2026-06-06, EXTENDED PHASE)

## HEADLINE VERDICTS (urgent)

### A. Trino bucket() arg order — VERIFIED COLUMN-FIRST

Trino 467 Iceberg connector documents the transform as **`bucket(x, nbuckets)`** — column FIRST, bucket-count SECOND. Verbatim from trino.io/docs/current/connector/iceberg.html:

> "The data is hashed into the specified number of buckets. The partition value is an integer hash of `x`, with a value between 0 and `nbuckets - 1` inclusive."

Signature line in the doc: `"bucket(x, nbuckets)"`.

Spark Iceberg DDL uses the OPPOSITE order — `bucket(N, col)`. r10 itself (line 794) already documents this engine difference verbatim: *"Trino syntax: `bucket(column, N)` — column first, bucket count second. … Spark SQL syntax: `bucket(N, column)` — bucket count first, column second."*

### B. Teacher's iter541 LEADING CANONICAL has the WRONG arg order baked in — URGENT iter542 FIX

The iter541 PIN block in `/Users/hclin/github/recknihao/resources/10-lakehouse-partitioning.md` consistently uses **SPARK order inside Trino DDL**:

- Line 36 (header): `"bucket(N, tenant_id) vs identity(tenant_id) …"`
- Line 40 (decision rule prose): `"use `bucket(N, tenant_id)`"`
- Line 53 (Trino DDL example): `partitioning = ARRAY['day(event_time)', 'bucket(32, tenant_id)']`
- Line 59 (pruning paragraph): `bucket(32, tenant_id)`
- Line 68 (DO-NOT-WRITE table): `bucket(N, tenant_id) defeats pruning …`
- Line 70 (DO-NOT-WRITE table): `bucket(1024, tenant_id)`

**This is a parse-correctness bug.** `'bucket(32, tenant_id)'` inside a Trino `WITH (partitioning = ARRAY[...])` clause will fail at parse / planning time on Trino 467 — Trino expects the column-name first. The rest of r10 (lines 23, 24, 26, 72, 86, 90, 252, 477, 794, 823, 827, 833, 900, 938) ALREADY uses the correct column-first Trino form `bucket(tenant_id, 64)` — so the new canonical CONTRADICTS the rest of the file and directly contradicts the engine-difference callout at line 794.

The orchestrator's directive notes also used the wrong order (`bucket(N, tenant_id)`); the teacher faithfully implemented the directive but did not double-check against trino.io. Iter542 must rewrite the entire iter541 leading canonical block to use `bucket(tenant_id, N)` for ALL Trino contexts (DDL, prose, decision-rule text, DO-NOT-WRITE rows). Recommended canonical example line:

```sql
partitioning = ARRAY['day(event_time)', 'bucket(tenant_id, 32)']  -- Trino arg order: bucket(column, N); NOT identity(tenant_id) for high-cardinality tenant_id
```

### C. Q3 `write_delete_mode` property — FABRICATION, also URGENT iter542 FIX

The responder wrote `ALTER TABLE ... SET PROPERTIES write_delete_mode = 'copy-on-write'`. **Not a valid Trino 467 Iceberg table property.** Verified two ways:

1. Trino doc table-property list does NOT include `write_delete_mode`. The full list is: `format`, `compression_codec`, `partitioning`, `sorted_by`, `location`, `format_version`, `max_commit_retry`, `delete_after_commit_enabled`, `max_previous_versions`, `orc_bloom_filter_columns`, `orc_bloom_filter_fpp`, `parquet_bloom_filter_columns`, `object_store_layout_enabled`, `data_location`, `extra_properties`.
2. Per Trino issue #17272 ("Support copy-on-write mode for Iceberg write" — still open) and Starburst forum/blog confirmations through 2025: **Trino's Iceberg writes are merge-on-read ONLY.** Even setting the Iceberg-native `write.delete.mode='copy-on-write'` (via Spark TBLPROPERTIES or Trino `extra_properties`) does NOT switch Trino to CoW — Trino continues to produce position-delete files.

So the responder's "switch to CoW via Trino SET PROPERTIES" advice is doubly wrong: wrong property name AND wrong claim that Trino honors the toggle. iter542 must add a canonical: *"Trino 467 Iceberg writes are merge-on-read only. There is no `write_delete_mode` Trino table property. Engines that read Iceberg can honor CoW if Spark wrote the table that way (`write.delete.mode='copy-on-write'` set via Spark TBLPROPERTIES), but on this on-prem stack ALL Trino-side delete/update/merge produces MoR position-delete files regardless."*

---

## Per-question scores

### Q1 — 8000-tenant Iceberg partitioning: bucket vs identity, no tiny files

| Dimension | Score | Justification |
|---|---|---|
| Accuracy | 4.0 | The DDL example `'bucket(tenant_id, 64)'` is the CORRECT Trino arg order (column-first, matches trino.io). The bucket-vs-identity recommendation, the 2.9M-partitions/year math, the equality-pruning explanation, and the N=64 SaaS sweet-spot are all correct. **BUT** the prose form `bucket(64, tenant_id)`, `bucket(16, tenant_id)`, `bucket(128, tenant_id)` repeatedly uses Spark arg order in a Trino context — internal inconsistency. The DDL would parse; the prose-form invocations would not. |
| Completeness | 4.5 | Covers identity anti-pattern, bucket transform, N sizing, pruning preservation, partition-count math. Misses `write.distribution-mode='hash'` footgun (would be nice-to-have). |
| Clarity | 4.0 | Clear once you ignore the prose/DDL arg-order inconsistency. A beginner would copy the inconsistent form and may pick the wrong one. |
| Actionability | 4.0 | DDL the engineer can paste is correct; prose paragraphs would mislead someone composing the SQL from text. |
| **Avg** | **4.125** | PASS. Score does NOT punish the responder for the teacher's leading-canonical inconsistency — the responder's DDL is correct Trino. |

### Q2 — dbt referential test for plan_id in events → plans

| Dimension | Score | Justification |
|---|---|---|
| Accuracy | 5.0 | `relationships` test signature with `to: ref('plans')` + `field: plan_id` matches docs.getdbt.com verbatim. The four generic tests (not_null/unique/accepted_values/relationships) are exactly right. |
| Completeness | 4.5 | Mentions singular custom tests for complex cases. Minor: did not mention the dbt 1.10+ `arguments:` nesting; pre-1.10 sibling form still parses, so not harmful. |
| Clarity | 4.5 | Clean YAML, plain-English mapping of FK → relationships test. |
| Actionability | 4.5 | Engineer can paste the YAML block as-is. |
| **Avg** | **4.625** | STRONG PASS. |

### Q3 — Iceberg MoR vs CoW

| Dimension | Score | Justification |
|---|---|---|
| Accuracy | 2.5 | CONCEPTUAL part is correct: MoR = position-delete files / fast writes / read amp / compact via `rewrite_position_delete_files`; CoW = rewrite whole data file / read fast / write amp. **HARMFUL FAB**: `ALTER TABLE ... SET PROPERTIES write_delete_mode = 'copy-on-write'` — `write_delete_mode` is NOT a Trino 467 Iceberg table property (verified against trino.io table-property list). Worse, per Trino issue #17272 and Starburst confirmations through 2025, **Trino's Iceberg writes are merge-on-read only**; setting the Iceberg-native `write.delete.mode` does not switch Trino's writer to CoW. Engineer following this advice gets a parse error or silent no-op. |
| Completeness | 3.5 | Misses the Trino-MoR-only reality. Recommends `rewrite_position_delete_files` (Spark procedure) without flagging that Trino has no equivalent. |
| Clarity | 4.0 | Concept explanation is clear. |
| Actionability | 2.5 | The actionable step (`SET PROPERTIES write_delete_mode=…`) is non-functional. |
| **Avg** | **3.125** | PER-QUESTION FAIL (below 3.5). |

### Q4 — CTAS vs CREATE + INSERT INTO for Iceberg loading

| Dimension | Score | Justification |
|---|---|---|
| Accuracy | 4.5 | CTAS atomic single statement, schema inferred; CREATE-then-INSERT two statements, schema explicit. Both produce the same end result on Trino Iceberg. The dbt-first-build-CTAS-then-MERGE-incremental claim is correct conditional on `incremental_strategy='merge'`; default is `append`, which the responder did not flag — minor incompleteness. |
| Completeness | 4.0 | Misses: CTAS picks a default file format / partitioning unless WITH is provided; CTAS+ WITH lets you fix partition spec atomically; CTAS commits in one snapshot, CREATE+INSERT commits in two (auditable in `$snapshots`). |
| Clarity | 4.5 | Side-by-side, easy to follow. |
| Actionability | 4.5 | Engineer can pick the right pattern. |
| **Avg** | **4.375** | STRONG PASS. |

---

## Overall

`(4.125 + 4.625 + 3.125 + 4.375) / 4 = 16.250 / 4 = **4.0625** → PASS (margin +0.5625 above 3.5 floor)`

Per established overall-average protocol (iter530–540), the single Q3 sub-3.5 score does NOT flip the iteration. 136th consecutive overall PASS in extended phase.

---

## iter542 PRIMARY FIX TARGETS

### FIX A (URGENT — Q1 arg-order in the new iter541 leading canonical)
File: `/Users/hclin/github/recknihao/resources/10-lakehouse-partitioning.md`
Lines to rewrite for column-first Trino syntax (`bucket(col, N)`):
- L36 (header): "bucket(tenant_id, N) vs identity(tenant_id) …"
- L40 (decision rule): "use `bucket(tenant_id, N)`"
- L53 (DDL — currently `'bucket(32, tenant_id)'`): change to `'bucket(tenant_id, 32)'` and update the EOL comment to read "Trino arg order: bucket(column, N); NOT identity(tenant_id) for high-cardinality tenant_id (10k tenants -> partition/tiny-file explosion)"
- L59 (pruning prose `bucket(32, tenant_id)`): → `bucket(tenant_id, 32)`
- L68 (DO-NOT-WRITE row): `bucket(N, tenant_id)` → `bucket(tenant_id, N)`
- L70 (DO-NOT-WRITE row): `bucket(1024, tenant_id)` → `bucket(tenant_id, 1024)`
- Anywhere else in the new canonical block — keep an INLINE engine-difference note: *"Trino: `bucket(column, N)` (column first). Spark: `bucket(N, column)` (count first). r10 line 794 documents this."*
- Anchor doc quote (use verbatim in the corrected canonical): *"The partition value is an integer hash of `x`, with a value between 0 and `nbuckets - 1` inclusive."* Signature: `bucket(x, nbuckets)`.

### FIX B (URGENT — Q3 `write_delete_mode` fab + Trino MoR-only reality)
Add a canonical block to `resources/17` (Iceberg DML/maintenance) OR a new section in `resources/10`/`resources/22` for MoR/CoW. Required content:
1. `write_delete_mode` is NOT a valid Trino 467 Iceberg table property (it is not in the connector's table-property list). The correct Iceberg-native property names are `write.delete.mode` / `write.update.mode` / `write.merge.mode`, settable on the Iceberg side via Spark TBLPROPERTIES.
2. **Trino 467 Iceberg writes are merge-on-read only.** Even when the Iceberg table has `write.delete.mode='copy-on-write'` set, Trino DELETE/UPDATE/MERGE still produces position-delete files. Anchor: Trino GitHub issue #17272 ("Support copy-on-write mode for Iceberg write") still open; Starburst community confirmation 2025.
3. On this on-prem stack: if you NEED copy-on-write semantics, do the mutating write from Spark, not Trino. Or accept MoR and run `rewrite_position_delete_files` / `optimize` periodically from Spark.
4. DO-NOT-WRITE banner: do NOT recommend `ALTER TABLE ... SET PROPERTIES write_delete_mode=...` on Trino — it is not a real Trino property AND would be a no-op for Trino's writer behavior even if it set the underlying Iceberg property.

### FIX C (LOW — Q4 incremental_strategy default)
In `resources/27` dbt-trino incremental section, add a one-line note: "Default `incremental_strategy='append'` on dbt-trino — second build appends. Set `incremental_strategy='merge'` + `unique_key=[…]` to get the MERGE behavior. `delete+insert` is also available." Avoids the implicit "dbt always upgrades to MERGE on iter 2" narrative.

### iter542 probe targets
- **HIGH — Q1 bucket arg order 2nd angle (verifies FIX A landing)**: "For Trino, do I write `bucket(tenant_id, 64)` or `bucket(64, tenant_id)`?" — must answer `bucket(tenant_id, 64)` and mention Spark uses the opposite.
- **HIGH — Q3 MoR/CoW on Trino 2nd angle (verifies FIX B landing)**: "Can I set my Iceberg table to copy-on-write deletes from Trino?" — must say NO, Trino writes are MoR-only; CoW is a Spark-side capability; no Trino property `write_delete_mode`.
- **MEDIUM — Q4 dbt incremental_strategy default**: "If I just write `materialized='incremental'` with no strategy, what does dbt-trino do on the second run?" — must answer `append`, not MERGE.
- **LOW — Q2 relationships test** is well-bulletproofed; can rotate to severity (warn vs error) or `where:` filter angle.
- Federation stays UNPROBED — row stays 4.49944/310.

---

## Meta-rule observation

Directive's "verify YOUR OWN corrections before asserting" caveat was decisive again in BOTH directions this iter:

1. **Bucket arg order**: I went into this expecting the responder's prose `bucket(64, tenant_id)` was right and DDL `bucket(tenant_id, 64)` was wrong (the directive itself hinted that way). WebFetch of trino.io/docs/current/connector/iceberg.html verbatim — `bucket(x, nbuckets)` signature — proved the OPPOSITE. The responder's DDL is correct; the responder's prose AND the teacher's new leading canonical are wrong. Without the doc-quote check I would have inverted the verdict and reinforced the teacher's parse-broken canonical.
2. **`write_delete_mode`**: verified against the Trino table-properties list (not present) AND verified separately that Trino's Iceberg writer ignores the Iceberg-native property anyway (Trino issue #17272). Conclusive HARMFUL FAB, not a "could be plausible."

5th consecutive iter (iter537 NULLS-LAST + iter538 banker's-vs-HALF_UP + iter539 sorted_by + iter540 not-null + iter541 bucket-arg-order + write_delete_mode) where the meta-rule prevented false-positive correction in either direction.

---

## Sources

- [Trino 467 Iceberg connector — bucket transform + table properties](https://trino.io/docs/current/connector/iceberg.html)
- [trinodb/trino#17272 — Support copy-on-write mode for Iceberg write](https://github.com/trinodb/trino/issues/17272)
- [dbt data tests — relationships generic test](https://docs.getdbt.com/reference/resource-properties/data-tests)
- [dbt-trino configs — incremental strategies + contracts](https://docs.getdbt.com/reference/resource-configs/trino-configs)
- [Starburst — Iceberg DML/maintenance in Trino (MoR reality)](https://www.starburst.io/blog/apache-iceberg-dml-update-delete-merge-maintenance-in-trino/)
