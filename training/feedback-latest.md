# Iteration 1258 — Judge Feedback

## Verdict

**Overall: 4.219 PASS — Q1+Q2 LIFT the thinnest required topic (query-perf-basics) +0.026 across two correct EXPLAIN-ANALYZE / EXPLAIN-DISTRIBUTED probes; Q3 SELECT * EXCEPT FABRICATION = responder recall-variance regression (resources already correct + heavily defanged, NO FIX-A); Q4 sign() existence correctly AFFIRMED with minor truncate over-generalization in unrequested adjacent-function list.** Q1 (4.6875) physicalInputDataSize on TableScan = MinIO I/O metric + per-fragment CPU-vs-Scheduled ratio for CPU-vs-I/O-bound — both verified against [trino.io/docs/467/sql/explain-analyze.html](https://trino.io/docs/467/sql/explain-analyze.html). Q2 (4.625) EXPLAIN (TYPE DISTRIBUTED) constraint-annotation on TableScan + Filter-above-scan pruning-broke diagnostic + physicalInputDataSize-relative-to-column-count projection check + naked-range fix. Q3 (3.125) PRIMARY ROW_NUMBER()=1 CTE is correct + idiomatic — but the responder fabricated `SELECT * EXCEPT(rn)` as "Trino syntax" in the secondary "more concise dbt form" alternative, **directly contradicting** (a) resources r23 §3368 + r27 §2003 which already heavily defang it AND (b) the responder's OWN iter1255 Q3 answer which correctly said "NO SELECT * EXCEPT in Trino." Q4 (4.4375) `sign()` existence correctly affirmed (good — not assumed-absence; pinned `reference_trino_to_char_exists.md`/`reference_trino_listagg_native.md` family); minor shave on tangential "truncate works exactly like Oracle" over-generalization (Trino 467 truncate is 1-arg only, no Oracle TRUNC(n,d)).

---

## Topic-lift ledger

| Topic | Before | After | Δ | Notes |
|---|---|---|---|---|
| Query performance basics (THINNEST required) | 4.1697/36 | **4.1953/38** | +0.0256 | Q1+Q2 both correct EXPLAIN-ANALYZE / EXPLAIN-DISTRIBUTED probes; margin lifted +0.026 — modest but real on the load-bearing thinnest topic. Still THINNEST going into iter1259 but trending up. |
| Analytical query patterns on Iceberg+Trino | 4.5158/184 | 4.5083/185 | -0.0075 | Q3 dedup ROW_NUMBER (primary correct, fabricated secondary). Topic margin +1.0083, very comfortable. |
| Oracle PL/SQL → dbt+Trino migration | 4.4781/224 | 4.4779/225 | -0.00009 | Q4 sign() existence correctly affirmed. Topic margin +0.9779, stable. |

---

## Per-question detail

### Q1 — EXPLAIN ANALYZE wall of text / ONE metric to ctrl-F for MinIO I/O + ONE for CPU

**Score: 4.6875** (Acc 4.75 / Clar 4.5 / Prac 5.0 / Compl 4.5)

**Strong, well-routed query-perf answer.** Responder named both metrics correctly:

- **MinIO I/O bottleneck → `physicalInputDataSize` on the TableScan operator** (actual bytes read from storage, distinct from `inputDataSize` which is logical post-decompression / decoding). VERIFIED via WebFetch of [trino.io/docs/467/sql/explain-analyze.html](https://trino.io/docs/467/sql/explain-analyze.html): example fragment shows `Physical Input: 4.51MB`. Metric documented per [trinodb/trino PR #23874](https://github.com/trinodb/trino/pull/23874).
- **CPU bottleneck → per-fragment `CPU` vs `Scheduled` time ratio**:
  - `CPU ≈ Scheduled` → CPU-bound (workers actually running, add parallelism)
  - `Scheduled >> CPU` → workers blocked (typically I/O wait or upstream-fragment-waiting; correlates with the I/O metric above)
  VERIFIED via WebFetch: fragment header lists "CPU: 22.58ms, Scheduled: 96.72ms" — the documented per-fragment metric pair.
- **Routing**: "find the fragment dominating total query time, then read its CPU/Scheduled split to know which lever to pull next" — exactly the right localize-the-culprit playbook.

**Minor Acc shave (-0.25):** Trino docs hedge "the relative cost of the plan nodes is based on wall time, which may or may not be correlated to CPU time" — responder framed the ratio as a clean binary, but on a real 7-8 minute query the engineer is well past noise floors (small queries, GC pauses) so the heuristic holds in practice.

**Verified against:**
- [trino.io/docs/467/sql/explain-analyze.html](https://trino.io/docs/467/sql/explain-analyze.html) — Physical Input + CPU/Scheduled per-fragment metrics
- [trinodb/trino PR #23874](https://github.com/trinodb/trino/pull/23874) — physicalInputDataSize at operator level

**Lifts thinnest topic +0.014 on this Q alone.**

---

### Q2 — 60-col fct_events day-partitioned / 3-col SELECT + WHERE event_date>='2026-05-01' 3+ min / verify projection + partition pruning + fix

**Score: 4.625** (Acc 4.5 / Clar 4.5 / Prac 5.0 / Compl 4.5)

**Strong diagnostic loop.** Responder gave the full ctrl-F-and-fix recipe:

1. **`EXPLAIN (TYPE DISTRIBUTED)`** and inspect the TableScan node layout.
2. **Partition-pruning check**: `constraint = day(event_date) >= DATE '2026-05-01'` annotation INSIDE the TableScan = pruning fired (Iceberg connector shows the partition-transform-aware predicate in the TableScan constraint). Conversely, a `Filter` node ABOVE the TableScan with the predicate AND no constraint on the scan = pruning broke (predicate didn't reach connector). Verified via [trinodb/trino #9309](https://github.com/trinodb/trino/issues/9309) + [#19266](https://github.com/trinodb/trino/issues/19266) (pruning fires via `Constraint.summary` TupleDomain, not opaque `Constraint.predicate`). The Filter-above-scan diagnostic is canonical.
3. **Projection check**: on a 60-col table reading 3 cols, `physicalInputDataSize` should be ~5% of full-row weight; if close to (rows × full-row-bytes), projection broke. (Reasonable heuristic; the more canonical check is reading the TableScan `layout = [...]` line listing only the 3 projected columns — responder missed that direct read but the heuristic gets engineer there.)
4. **Naked-range fix**: `event_date >= DATE '2026-05-01' AND event_date < DATE '2026-06-01'` on the raw column with no function-wrap (CAST, year(), date_trunc — though Unwrap{Cast,Year,DateTrunc}InComparison rules per pinned `reference_trino_unwrap_temporal_predicates.md` handle the temporal ones; bare-column form is still safest).

**Minor Acc shave (-0.5):** the constraint annotation form was given as `day(event_date)>=DATE '2026-05-01'` — partition-transform display is plausible but the actual TupleDomain rendering varies (`event_date:date IN [[2026-05-01..2026-06-01]]` is also common). Mental model is right; exact string match might not appear verbatim — engineer needs to recognize the partition-transform predicate in either rendering.

**Verified against:**
- [trino.io/docs/467/sql/explain.html](https://trino.io/docs/467/sql/explain.html) — EXPLAIN (TYPE DISTRIBUTED) form
- [trinodb/trino #9309](https://github.com/trinodb/trino/issues/9309) — Iceberg partition pruning via Constraint.summary
- [trinodb/trino #19266](https://github.com/trinodb/trino/issues/19266) — partition-transform pushdown
- pinned `reference_trino_unwrap_temporal_predicates.md` — function-wrap unwrap rules

**Lifts thinnest topic +0.012 on this Q. Combined Q1+Q2 lift = +0.026.**

---

### Q3 — Dedup keep latest per (user_id, session_id) by started_at DESC on 800M user_sessions / Oracle ROW_NUMBER works in Trino + more efficient?

**Score: 3.125** (Acc 2.5 / Clar 3.5 / Prac 2.5 / Compl 4.0)

**PRIMARY correct + FABRICATED secondary alternative.** This is a **responder recall-variance regression** on already-maximally-defanged resource content, NOT a resource defect.

**What landed correct (primary):**
```sql
WITH ranked AS (
  SELECT *,
         ROW_NUMBER() OVER (PARTITION BY user_id, session_id ORDER BY started_at DESC) AS rn
  FROM user_sessions
)
SELECT * FROM ranked WHERE rn = 1
```
Works directly in Trino 467 (lowercase keyword optional, same semantics as Oracle), parallelizes across the PARTITION BY. Standard / idiomatic.

**THE PROBLEM (Acc -2.5 / Prac -2.0):** responder appended a "more concise dbt form" alternative:
```sql
SELECT * EXCEPT(rn) FROM (... rn ...) WHERE rn = 1
```
and CLAIMED `SELECT * EXCEPT(rn)` is **"Trino syntax to drop the rn column from output."**

**FABRICATION** — VERIFIED via WebFetch of [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html): SELECT supports only `*`, `relation.*`, `row_expression.*`; `EXCEPT` in Trino is the set operator only (rows-difference, not column-projection). Multiple OPEN feature requests confirm absence:
- [trinodb/trino #23532](https://github.com/trinodb/trino/issues/23532) — Support select * exclude(...) like BigQuery/DuckDB/Snowflake
- [trinodb/trino #26402](https://github.com/trinodb/trino/issues/26402) — Feature Request: Support SELECT * EXCEPT
- [trinodb/trino #26969](https://github.com/trinodb/trino/issues/26969) — Support SELECT * EXCEPT / EXCLUDE

All unresolved. Engineer copying the secondary form gets a parse error.

**CRITICAL — this directly CONTRADICTS:**
1. **Resources which ALREADY defang it heavily** (grep-verified):
   - `resources/27-oracle-plsql-to-dbt-trino.md` L2003: "DO NOT write `SELECT * EXCEPT (rn)` — that BigQuery/Databricks projection is..."
   - `resources/23-sql-best-practices-olap.md` L3368: table row "**`SELECT * EXCEPT (col1, col2)`** (column-exclusion projection) | BigQuery, Databricks, ClickHouse | **NOT supported.** Parse error. Open feature request [trinodb/trino #26969]"
2. **The responder's OWN iter1255 Q3 answer** which correctly said "Trino 467 has NO SELECT * EXCEPT (rn) — that's BigQuery/Databricks."

**CLASSIFICATION**: responder recall-variance regression on already-maximally-defanged content. Resources are correct + dual-defanged (migration row + SQL-best-practices row). **NO FIX-A.** Per `feedback_responder_broken_secondary_alternative.md` family (iter936/943/948/950/954/1013/1019/1020 — primary correct, "for completeness" alternative invented/broken; per-instance one-off, NOT a resource defect — no single resource fix for responder padding).

**NEW WATCH `iter1258 Q3 SELECT * EXCEPT alternative-fabrication regression`**: re-probe under varied framings — "dedup ROW_NUMBER + drop the rn column" / "Oracle QUALIFY equivalent in Trino" / "BigQuery-flavored column-exclusion request" / "rewrite that drops the rank helper column" — within 4-8 iters. If 2+ recurrences after iter1255 correct precedent AND dual-resource defang, escalate to LIGHT FIX-A: add a copy-attractive enumerated-column variant `SELECT user_id, session_id, started_at, <other_cols> FROM ranked WHERE rn=1` next to the dedup card so the copy-attractive default doesn't reach for `*`.

**Verified against:**
- [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) — wildcard variants documented, no EXCEPT/EXCLUDE
- [trinodb/trino #26969](https://github.com/trinodb/trino/issues/26969) — open feature request
- resources/27 L2003 + resources/23 L3368 — already-correct defangs

---

### Q4 — Oracle SIGN(current_value - previous_value) → +1/0/-1; does Trino 467 have SIGN() or rewrite to CASE?

**Score: 4.4375** (Acc 4.0 / Clar 4.75 / Prac 4.5 / Compl 4.5)

**Core EXISTS-affirmation correct.** Responder: "Trino 467 HAS `sign()` — `sign(current_value - previous_value)` returns -1/0/+1, lowercase, Oracle-compatible. Your 30 queries migrate as-is (just lowercase SIGN→sign)."

**VERIFIED via WebFetch of [trino.io/docs/467/functions/math.html](https://trino.io/docs/467/functions/math.html)**: `sign(x)` returns "the signum function of x" — 0 for zero, 1 for positive, -1 for negative; for floating-point also returns -0/NaN/infinity correspondingly. Oracle-compatible return shape — engineer's 30-query bulk rename works.

**GOOD — not assumed-absence**: per pinned `reference_trino_listagg_native.md` / `reference_trino_to_char_exists.md` / `reference_trino_lateral_exists.md` / `reference_trino_starts_with_ends_with.md` family — most foreign-looking funcs ARE in Trino 467; responder correctly affirmed existence rather than guessing absence, which is the systemic responder failure mode the pinned references guard against.

**MINOR Acc shave (-0.5)**: responder appended an adjacent-functions list "abs/ceil/floor/round/truncate work exactly like Oracle" — **`truncate` is NOT exactly like Oracle TRUNC(n,d) on Trino 467** per pinned iter1240 reference:
- Trino 467 `truncate(x)` is **1-arg only** (rounds toward zero to integer)
- NO 2-arg `truncate(n, d)` form like Oracle `TRUNC(price, 2)`
- 30-query bulk rename hitting any `TRUNC(price, 2)` form WILL break; workaround: `round(price * power(10, 2)) / power(10, 2)` or `CAST(price * 100 AS BIGINT) / 100.0`

Verified via same WebFetch: "truncate(x) → double, Returns x rounded to integer by dropping digits after decimal point" — no 2-arg overload. truncate was NOT the asked function (sign was), so the over-generalization is tangential — engineer's primary sign() bulk rename works as advertised, but the unrequested adjacent-list framing would silently miss the TRUNC(n,d) cases if the engineer took it at face value during the broader sweep.

**Classification**: responder broken-secondary-alternative family (same pattern as Q3 above — primary correct, unrequested "for completeness" assertion slips). NO FIX-A (pinned `reference_trino_cast_to_integer_rounds.md` already documents the truncate semantics + r27 covers Oracle TRUNC migration). Same `feedback_responder_broken_secondary_alternative.md` family — per-instance one-off re-probe, no resource churn.

**Verified against:**
- [trino.io/docs/467/functions/math.html](https://trino.io/docs/467/functions/math.html) — sign(x) + truncate(x) (1-arg only)
- pinned `reference_trino_cast_to_integer_rounds.md` — truncate semantics
- pinned `reference_trino_to_char_exists.md` — assumed-absence guard (foreign-looking funcs ARE in Trino)

**SOFT WATCH `iter1258 Q4 truncate-1-arg-only over-generalization in unrequested adjacent-list`**: re-probe under "Oracle TRUNC(price, 2) decimal-truncation migrate to Trino" within 4-8 iters; if the engineer asks about TRUNC(n,d) directly, responder MUST route to the round(x * 10^d) / 10^d workaround.

---

## Watches summary going into iter1259

**NEW watches opened this iter:**
- `iter1258 Q3 SELECT * EXCEPT alternative-fabrication regression` — responder regressed from correct iter1255 answer; resources already dual-defanged (r23 L3368 + r27 L2003); NO FIX-A. Re-probe within 4-8 iters under varied "drop rn column / column-exclusion" framings; 2+ recurrences → LIGHT FIX-A on copy-attractive enumerated-column variant.
- `iter1258 Q4 truncate-1-arg-only over-generalization (unrequested adjacent-list)` — soft watch; sign() core answer correct; re-probe on direct TRUNC(price, 2) migration question within 4-8 iters.

**Watches closed:** none this iter (Q1+Q2 were breadth probes for the thin topic, no specific watch closure).

**Watches still OPEN going into iter1259:**
- iter1258 Q3 SELECT * EXCEPT (NEW)
- iter1258 Q4 truncate-1-arg-only (NEW, soft)
- iter1257 Q4 strpos-arithmetic (soft)
- iter1255 Q1 bloom-CREATE-syntax
- iter1255 Q3 INSERT-OVERWRITE-broken-secondary
- iter1253 Q4 regexp_extract-2arg
- iter1248 Q3 MATCH_RECOGNIZE-adjacency
- iter1241 concat-auto-coerces
- iter1236 rn=1-within-batch
- iter1215 strpos-3-arg (soft arithmetic only now)
- iter1229 @v1-Spark

---

## Explicit answers to the verification-block questions

**(1) Did Q1+Q2 lift the thin query-perf-basics topic? Were they strong/correct?**
**YES, both were strong + correct + lifted +0.026 net.** Q1 (4.6875) named physicalInputDataSize on TableScan as the MinIO-I/O metric + per-fragment CPU/Scheduled ratio as the CPU-bottleneck localizer — both verified against the trino.io 467 EXPLAIN ANALYZE doc. Q2 (4.625) gave the full EXPLAIN-DISTRIBUTED constraint-annotation + Filter-above-scan + naked-range-fix diagnostic loop. Topic 4.1697/36 → 4.1953/38, margin +0.6953 above pass threshold. STILL THINNEST required topic but trending up; recommend further breadth probes on partition design / file layout / Iceberg compaction next sweep to continue lifting.

**(2) Q3 SELECT * EXCEPT fabrication = responder-slip-no-FIX-A (resources already correct + defanged)?**
**CONFIRMED.** Grep-verified: `resources/23-sql-best-practices-olap.md` L3368 has the **exact** "NOT supported. Parse error. Open feature request #26969" defang in a cross-engine SQL-divergence table row; `resources/27-oracle-plsql-to-dbt-trino.md` L2003 has the "DO NOT write `SELECT * EXCEPT (rn)` — that BigQuery/Databricks projection is..." DO-NOT-WRITE block. Resources are correct + dual-defanged in the EXACT two rows the responder should have routed to. The responder's iter1255 Q3 answer correctly affirmed the absence. Iter1258 is recall-variance regression — same content, contradicted itself on a re-probe. Classification: per-instance responder slip (broken-secondary-alternative family per `feedback_responder_broken_secondary_alternative.md`), NO FIX-A. NEW WATCH opened for 4-8-iter re-probe under varied "drop rn column" / "BigQuery-flavored exclusion" / "Oracle QUALIFY equivalent" framings.

**(3) New watches:**
- NEW: `iter1258 Q3 SELECT * EXCEPT alternative-fabrication regression` (4-8 iter re-probe; LIGHT FIX-A escalation only on 2+ recurrences)
- NEW (soft): `iter1258 Q4 truncate-1-arg-only over-generalization in unrequested adjacent-list` (re-probe on direct TRUNC(price, 2) migration Q)

---

## Iteration arithmetic

Per-question scores: Q1=4.6875 / Q2=4.625 / Q3=3.125 / Q4=4.4375
**Iter1258 average: 4.219 PASS** (above 3.5 floor by +0.719; below recent strong-pass band 4.7-4.95 owing to Q3 regression).

All required topics remain PASSED. Query-perf-basics lifted +0.026 (the goal of this iter), still thinnest at 4.1953/38, margin +0.6953. Recommend continued breadth probes on query-perf-basics + partition design next sweep to widen the margin further.
