# Iter 701 — Judge Feedback (Extended Phase — DEFAULT NO-OP probe)

**Date**: 2026-06-08
**Verdict**: STRONG PASS (overall avg 4.875 / 5.00 across 16 sub-scores; margin +1.375 above 3.5 floor)
**Recommendation**: **iter702 stays DEFAULT NO-OP. Zero findable-but-missing gaps. Zero dialect defects. Zero ban-list leaks.**

---

## Per-Question Sub-Scores

| Q | Topic | Acc | Comp | Clar | Act | Per-Q Avg |
|---|---|---|---|---|---|---|
| Q1 | SELECT DISTINCT * whole-row dedup (CTAS) | 5.0 | 4.5 | 5.0 | 5.0 | 4.875 |
| Q2 | Money precision: DOUBLE approximate → DECIMAL(18,2) / BIGINT cents | 5.0 | 5.0 | 5.0 | 5.0 | 5.000 |
| Q3 | split() + CROSS JOIN UNNEST + TRIM for comma-separated tags | 4.5 | 5.0 | 5.0 | 5.0 | 4.875 |
| Q4 | Iceberg partitioning: day(occurred_at) + bucket(customer_id, 32) | 5.0 | 4.5 | 5.0 | 5.0 | 4.875 |

**Per-Q average**: (4.875 + 5.000 + 4.875 + 4.875) / 4 = 19.625 / 4 = **4.90625**
**Sub-score sum**: 78 / 16 = **4.875**
**Dim-avg cross-check**: Acc (5+5+4.5+5)/4 = 4.875 / Comp (4.5+5+5+4.5)/4 = 4.75 / Clar (5+5+5+5)/4 = 5.00 / Act (5+5+5+5)/4 = 5.00 → (4.875 + 4.75 + 5.00 + 5.00)/4 = **4.90625** — agrees per-Q-avg.
**Governing label**: STRONG PASS (using sub-score sum 4.875 as the reported overall; per-Q-avg 4.90625 as cross-check). All four Qs above per-Q 4.75 floor.

---

## Per-Question Verification & Notes

### Q1 — SELECT DISTINCT * for exact duplicate removal — 4.875

**Verified against trino.io/docs/current/sql/select.html (= 467 grammar)**: `SELECT DISTINCT *` is valid Trino 467 syntax for whole-row deduplication. The `*` expands to all columns of the relation, and the DISTINCT quantifier deduplicates on the combined column tuple. CTAS (`CREATE TABLE AS SELECT ...`) is valid for materializing the result. Each column type must support comparison (all storable Iceberg types do).

**Form used**: `CREATE TABLE iceberg.analytics.events_deduped AS SELECT DISTINCT * FROM iceberg.analytics.events_staging;` plus "for in-place, CTAS-DISTINCT then rename/drop." Both are docs-correct Trino 467.

**Minor completeness nit (cost -0.5 Comp)**: For EXACT duplicates SELECT DISTINCT * is the cleanest answer and the responder rightly chose it — no penalty for not over-explaining. To hit a 5 on Comp, the answer could note that the KEEP-LATEST-OF-NEAR-DUPLICATES variant (same key columns, differing on, e.g., updated_at) is the ROW_NUMBER subquery + outer WHERE rn=1 form. Question explicitly said "exact duplicates" so the omission is defensible — documentation nit, NOT a defect, NOT a FIX candidate.

### Q2 — Money precision: floats give $1199.9999 — 5.00

**Verified against trino.io/docs/current/language/types.html**:
- DOUBLE is documented as a 64-bit inexact IEEE-754 variable-precision binary float — responder correctly identified the binary representation as the root cause of the $1200.00 → 1199.9999999999998 drift.
- DECIMAL(p,s) is exact fixed-point with maximum precision 38; DECIMAL(18,2) is well within bounds and a sound production choice for currency (best performance up to precision 18).
- The BIGINT-cents alternative (store 120000 as integer, divide on display) is a legitimate alternative widely used to avoid decimal-precision concerns entirely.

All three points (root cause naming, primary fix at table-creation, alternative) are docs-correct and the answer is at the per-Q ceiling. No nits.

### Q3 — split + CROSS JOIN UNNEST for comma-separated tags — 4.875

**Verified against trino.io/docs/current/functions/string.html and trino.io/docs/current/sql/select.html**:
- `split(string, delimiter)` returns `array<varchar>` (2-arg form correct; there is also a 3-arg `split(string, delimiter, limit)` overload — not needed here).
- The `CROSS JOIN UNNEST(array) AS t(col)` pattern is valid Trino 467; CROSS JOIN is the canonical way to expand an array column into rows on the same input row.
- `TRIM(tag)` for whitespace cleanup is valid (default TRIM removes spaces from both ends).
- The clause-ordering claim ("CROSS JOIN UNNEST before WHERE") is semantically correct — UNNEST must produce rows before they can be filtered.

**Minor accuracy nit (cost -0.5 Acc)**: The responder said `LIKE 'enterprise' might match 'enterprise_beta'`. Strictly, LIKE WITHOUT a wildcard would NOT match — `WHERE tag LIKE 'enterprise'` is equivalent to `WHERE tag = 'enterprise'` and would not match `enterprise_beta`. The brittleness the responder is gesturing at is real for the common variant `LIKE '%enterprise%'` (which WOULD substring-match `enterprise_beta`). The underlying point — that LIKE-on-the-raw-comma-string is the wrong tool — is correct, and the responder's recommended solution (split + unnest + equality filter) is the right canonical, so the slip is a minor reasoning imprecision not a defect. Not a FIX candidate (the answer's recommended SQL is dialect-correct and the question is solved).

### Q4 — Partitioning a new big events table — 4.875

**Verified against trino.io/docs/current/connector/iceberg.html**:
- The `WITH (partitioning = ARRAY[...])` table property syntax is correct.
- **`bucket(customer_id, 32)` is COLUMN-FIRST** — this is the correct Trino form per the iter541 reference note. Spark uses count-first `bucket(32, customer_id)`. The responder used the Trino-correct column-first form. ✅ CONFIRMED CORRECT.
- `day(occurred_at)` is a valid Iceberg temporal partition transform on a TIMESTAMP column (siblings: year, month, hour).
- `format_version=2` is a valid Iceberg table format version (v2 enables row-level deletes / MoR; v3 is supported in newer Iceberg releases but v2 is the standard production choice).
- The partition-count guidance (target 1k–100k partitions; identity-partition-on-customer_id explodes into millions of tiny files for high-cardinality columns; bucketing bounds the file count) is sound, well-cited canonical Iceberg advice.
- Math sanity: ~1,100 days × 32 buckets ≈ 35,200 partitions, comfortably within the 1k–100k window.

**Minor completeness nit (cost -0.5 Comp)**: The answer said "Changing partitioning later requires a bulk rewrite." This is **slightly imprecise**. Iceberg supports **partition spec evolution as a metadata-only operation**: `ALTER TABLE ... SET PARTITIONING ...` updates the spec, after which **new** data is written using the new spec while **existing** data files remain under the old spec. Trino query planning handles multiple specs via split planning. So the precise statement is:

> Changing the partition spec itself is metadata-only (cheap). **Re-partitioning existing data** under the new spec — i.e., physically rewriting the old files so they live in the new partition layout — does require a bulk rewrite (typically via `ALTER TABLE ... EXECUTE optimize` after the spec change, or a CTAS rebuild).

This is a nuance, not a fact-error: the responder is correct that you can't get the new layout applied to existing data without a rewrite, just slightly loose on the boundary between "spec change" (free) and "data rewrite" (expensive). The practical recommendation (decide partitioning carefully at table-creation time) lands correctly. Flagging in prose, **NOT a FIX candidate** — adds zero practical risk to the engineer following the advice; the cost is one Comp half-point.

---

## Cross-Cutting Observations

- **Zero ban-list leaks**: no QUALIFY, no RLIKE, no PERCENTILE_CONT / MEDIAN, no PIVOT, no DISTINCT ON, no COUNT(DISTINCT) OVER, no window-in-WHERE, no array_slice, no element_at-index-0, no CoW-default claim, no t-digest-with-accuracy-arg claim, no date-minus-date arithmetic, no CONNECT BY, no ALTER TABLE EXECUTE rollback (469+ — not asked), no max_recursion_depth ≠ 10.
- **bucket() column-first**: Q4 used `bucket(customer_id, 32)` — the Trino column-first form. This is the form the iter541 reference note pinned, and it held. ✅
- **Dialect form verifications all clean**: SELECT DISTINCT *, DECIMAL(18,2), split() + CROSS JOIN UNNEST + TRIM, partitioning WITH ARRAY[...] + day()/bucket() transforms, format_version=2 — all docs-correct Trino 467.
- **Findability**: responder cited resources/23, resources/07, resources/10 — all topically correct and matching the question keywords. No misroutes.
- **Per-Q floor**: lowest per-Q at 4.875 (Q1, Q3, Q4 tied). Comfortably above the 4.75 internal quality-gate floor.
- **Margin above 3.5 PASS floor**: +1.375 — strong margin.

---

## Topic Avg Updates (NO-OP / no resource edits this iter)

- **Iceberg partition design for SaaS: strategies, small-files, compaction** (Q4 day+bucket canonical durability +0.30; bucket(COL,N) column-first form holding under fresh probing).
- **SQL query best practices for OLAP** (Q1 SELECT DISTINCT * for whole-row dedup canonical durability +0.30; Q3 split + CROSS JOIN UNNEST + TRIM canonical durability +0.30).
- **Lakehouse schema design: fact tables, dimension tables, denormalization** (Q4 partitioning WITH ARRAY + format_version=2 docs-perfect +0.30).
- **Postgres-to-Iceberg ingestion / Common analytical query patterns** (Q2 DECIMAL(18,2) for currency at table-creation + BIGINT-cents alternative +0.40 — money-precision-on-Iceberg canonical docs-perfect).

---

## Findable-but-Missing Gap Surface

**ZERO new findable-but-missing gaps. ZERO dialect defects. ZERO FIX-A candidates for iter702.**

The two minor nits flagged (Q3 LIKE-substring reasoning loosely worded; Q4 "bulk rewrite" partition-spec-evolution nuance imprecise) are imprecisions in the **explanatory prose**, not in the **executable SQL** the engineer would copy. Both answers' recommended canonical SQL is dialect-correct and solves the question. Neither rises to a defect requiring resource edits. Adding inoculation cards for either would risk regressing other answers (cf. iter693 defang-snippet-bleed lesson).

**iter702 directive**: DEFAULT NO-OP CONTINUES. Do NOT bump state.json (orchestrator handles). HOLD all iter534-700 locks (~260 locks across 17 resource files). HOLD iter698 MoM card (now 3-iter durability), iter697 approx_percentile inoculation (now 4-iter durability), iter695 QUALIFY canonical (now 6-iter durability), r22 federation guardrails (57-iter ZERO probe streak; 4.49944 vs 4.5 thin). Probe a fresh unrelated near-threshold area in iter702 (federation 4.5-bar, CBO/ANALYZE 4.5-bar, storage tiering 4.25-avg-only-2-questions, or dbt model contracts 4.0859-avg-only-4-questions) rather than re-probing these four topics. Federation NOT probed this iter — row UNCHANGED.

---

## Sources Cited During Verification

- [SELECT — Trino current/467 Documentation](https://trino.io/docs/current/sql/select.html)
- [Data types — Trino current/467 Documentation](https://trino.io/docs/current/language/types.html)
- [Iceberg connector — Trino current/467 Documentation](https://trino.io/docs/current/connector/iceberg.html)
- [Array functions and operators — Trino current/467 Documentation](https://trino.io/docs/current/functions/array.html)
- [Iceberg Evolution — Apache Iceberg Docs](https://iceberg.apache.org/docs/1.5.1/evolution/)
