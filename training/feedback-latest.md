# Iter1142 Judge Feedback

**Verdict: 4.9688 STRONG PASS NO-OP — iter1141 r18 TopN-disambiguation LIGHT FIX-A REACHED CLEANLY ON FIRST RE-PROBE. Q1 nails the canonical answer the FIX-A card was designed to produce: ORDER BY ... LIMIT 50 → TopN bounded heap of 50 (not full sort), spill on ordering step unlikely for small n, real bottleneck = unfiltered 300M-row TableScan, fix = partition/time predicate, verify via EXPLAIN looking for `TopN[50]` + a `TableScan` with `constraint=` (partition pruning), explicit "Don't do: turn on disk spill or bump cluster memory." The two iter1141 misconceptions (`ORDER BY+LIMIT = full sort`, `lower query_max_memory_per_node to spill earlier`) BOTH absent. Q2/Q3/Q4 clean breadth angles, Q3 a minor completeness shave only (didn't mention `arrays_overlap` direct boolean alternative). r18 TopN-disambiguation WATCH: CLOSED.**

---

## Score table

| Q | Topic | Acc | Clar | App | Compl | Avg |
|---|---|---:|---:|---:|---:|---:|
| Q1 | Query performance basics — ORDER BY+LIMIT TopN-vs-spill diagnosis (FIX-A re-probe) | 5.0 | 5.0 | 5.0 | 5.0 | **5.000** |
| Q2 | Analytical query patterns / ranking — DENSE_RANK ties-no-skip vs RANK ties-with-skip vs ROW_NUMBER all-distinct | 5.0 | 5.0 | 5.0 | 5.0 | **5.000** |
| Q3 | SQL best practices for OLAP — array_intersect + cardinality > 0 (share-at-least-one-flag WHERE filter) | 5.0 | 5.0 | 5.0 | 4.5 | **4.875** |
| Q4 | dbt sources / source freshness — warn_after/error_after, loaded_at_field required on dbt-trino, separate CI stage gate (does NOT auto-block dbt build DAG) | 5.0 | 5.0 | 5.0 | 5.0 | **5.000** |

**Iter average: (5.000 + 5.000 + 4.875 + 5.000) / 4 = 19.875 / 4 = 4.96875 → 4.9688 STRONG PASS**

Margin above 3.5 threshold: **+1.4688** (second-highest in the 24-iter sustainment band, after iter1137's 5.000).

---

## Per-question analysis

### Q1 (5.000) — `SELECT * FROM events ORDER BY created_at DESC LIMIT 50` on 300M rows takes 90s; engineer assumes Trino sorts all 300M; teammate says "bump memory / enable spill" — is that the right mental model?

**Responder answer (canonical, CORRECT)**:
- **NO** — Trino does NOT sort all 300M rows. Trino rewrites `ORDER BY ... LIMIT 50` into a **TopN operator** with a bounded heap of only the top 50 rows.
- Per-worker operator memory for the ordering step is bounded by ~`n=50` rows, NOT by the table size — so spill on the ordering step is unlikely for a small `n`.
- The actual bottleneck on a 300M-row, 90s `SELECT *` is the **unfiltered TableScan reading all 300M rows** (and 200+ columns via `SELECT *`).
- Adding cluster memory or enabling spill won't fix it — wrong knob, wrong mechanism.
- **Fix**: add a partition/time predicate, e.g. `WHERE created_at >= TIMESTAMP '2025-06-01 00:00:00'` so the scan prunes; also drop `SELECT *` for narrow columns.
- **Verify with `EXPLAIN`**: look for a `TopN[50]` node (or `TopNPartial` + final `TopN`) — that confirms the ordering is already bounded; then on the `TableScan` look for `constraint=` (partition-pruning predicate) and `inputRows` near the filtered range, not near 300M.
- Explicit defang: **"Don't do: turn on disk spill or bump cluster memory."**

**iter1141 r18 TopN-disambiguation FIX-A REACH VERDICT: CONFIRMED REACHED CLEANLY on first re-probe.**

The new r18 §288-300 DIAGNOSIS GUARD card (added iter1141, sitting right next to the spill section so the "ORDER BY + spilling" keyword path lands on it before the FTE sidebar) pulled the responder to the canonical TopN framing. Both iter1141 misconceptions are absent:

- **No "ORDER BY + LIMIT requires sorting all input rows before the LIMIT cuts"** framing. Responder explicitly states "TopN heap of 50 rows" / "spill on ordering step unlikely for small n" / "memory ~ n=50, not table size" — exact wording cluster from the FIX-A card.
- **No "lower `query_max_memory_per_node` to spill earlier"** misconception. Responder correctly tells engineer NOT to touch memory caps at all.

Verified against:
- [trino.io/docs/current/optimizer/pushdown.html](https://trino.io/docs/current/optimizer/pushdown.html) — TopN pushdown distinct from full-sort.
- Trino 467 source `core/trino-main/src/main/java/io/trino/operator/TopNOperator.java` — "Returns the top N rows from the source sorted according to the specified ordering" with memory tracked via `MemoryTrackingContext`.
- r23 §2387 (already in resources): *"LIMIT only enables the cheaper TopN operator (heap of size N vs full sort)"*.

**Watch label "r18 TopN-disambiguation iter1141" → CLOSED.**

The EXPLAIN verification step (look for `TopN[50]` + `TableScan` with `constraint=`) is the kind of concrete next-action signal that turns a correct mental model into a debuggable workflow. The `SELECT *` callout for column-pruning is a nice secondary fix on top of the partition predicate. Clean 5.0.

**Recommendation: NO-OP.** FIX-A reach confirmed; watch closes.

---

### Q2 (5.000) — leaderboard rank by total revenue; tied accounts get different numbers with ROW_NUMBER; is there a ranking function that gives ties the same rank, and does it skip after a tie?

**Responder answer (CORRECT)**: use `DENSE_RANK()` — same rank for ties, **no skip** in the sequence.

Comparison table given (paraphrased):

| Revenue | ROW_NUMBER | RANK | DENSE_RANK |
|---|---:|---:|---:|
| 1000 | 1 | 1 | 1 |
| 1000 | 2 | 1 | 1 |
| 800 | 3 | 3 (skips 2) | 2 (no skip) |
| 500 | 4 | 4 | 3 |

Query shape:

```sql
SELECT account_id, total_revenue,
       DENSE_RANK() OVER (ORDER BY total_revenue DESC) AS leaderboard_rank
FROM (SELECT account_id, SUM(revenue) AS total_revenue
      FROM orders GROUP BY account_id) t;
```

For top-10-including-all-ties: wrap and filter `WHERE leaderboard_rank <= 10` (note this returns MORE than 10 rows if there's a tie at rank 10 — which is the desired leaderboard behavior).

Verified at [trino.io/docs/current/functions/window.html](https://trino.io/docs/current/functions/window.html):
- `row_number()` — "Returns a unique, sequential number for each row, starting with one, according to the ordering of rows within the window partition."
- `rank()` — "Returns the rank of a value in a group of values. The rank is one plus the number of rows preceding the row that are not peer with the row. Thus, tie values in the ordering will produce gaps in the sequence."
- `dense_rank()` — "Returns the rank of a value in a group of values. This is similar to rank(), except that tie values do not produce gaps in the sequence."

Responder framing matches exactly. The 4-row example table is concrete and the leaderboard wrap-and-filter is the canonical "top-N including ties" idiom. Clean 5.0.

**Recommendation: NO-OP.**

---

### Q3 (4.875) — `feature_flags` array column; find users who share at least one flag with `ARRAY['billing_v2', 'new_dashboard', 'export_csv']`; is there a function that takes two arrays and returns overlapping elements usable in WHERE?

**Responder answer (CORRECT primary)**: `array_intersect(a, b)` returns the overlapping elements (no duplicates).

```sql
WHERE cardinality(array_intersect(feature_flags,
                                  ARRAY['billing_v2','new_dashboard','export_csv'])) > 0
```

Alternative offered: `WHERE array_intersect(...) != ARRAY[]`.

Verified at [trino.io/docs/current/functions/array.html](https://trino.io/docs/current/functions/array.html):
- `array_intersect(x, y) -> array(E)` — "Returns an array of the elements in the intersection of x and y, without duplicates."
- `cardinality(array(E)) -> bigint` — array length.

Both forms are valid Trino 467 syntax. `cardinality(...) > 0` is the safer canonical because:
1. It returns a plain `bigint` comparison — no array-equality typing edge cases.
2. The `!= ARRAY[]` alternative has a minor typing fiddliness: the empty array literal `ARRAY[]` infers as `array(unknown)`, and while Trino will coerce it for the comparison, the safer/more conventional form across dialects is the cardinality check.

**Completeness shave — 4.5 on Compl**: the responder did NOT mention the more direct boolean primitive `arrays_overlap(x, y) -> boolean`, which is the most natural fit for the question's exact phrasing "share at least one flag":

```sql
WHERE arrays_overlap(feature_flags,
                     ARRAY['billing_v2','new_dashboard','export_csv'])
```

`arrays_overlap` returns `true` if the two arrays share any non-null element (with NULL semantics: returns NULL if there are no shared non-nulls AND either array contains NULL). For a non-NULL flag column, this is the simplest and most expressive form. The question explicitly asked for "a function that takes two arrays" and the most direct one-step answer is `arrays_overlap`, not `cardinality(array_intersect(...)) > 0`.

This is NOT a defect — the responder's `array_intersect + cardinality > 0` IS correct and IS the canonical form taught widely. It's just a missed-completeness opportunity on the more idiomatic `arrays_overlap` direct form. Probably ranks alongside the "responder bias toward minimum-sufficient answer" / recall-ceiling pattern from iter1140 Q1, NOT a resource defect.

**Classification**: minor completeness shave, recall ceiling. NOT a defect; NOT a watch-worthy gap. No resource fix recommended — `arrays_overlap` is in the resource catalogue.

**Recommendation: NO-OP** on the resource. Optional re-probe queue idea: probe specifically for "do these two arrays share an element" phrasing to see if `arrays_overlap` lead is reachable (not urgent).

---

### Q4 (5.000) — hourly Postgres→Iceberg ETL silently fails occasionally; table goes 4-6h stale; can dbt auto-check source recency and warn / stop downstream if too old?

**Responder answer (CORRECT)**:

**Mechanism**: `dbt source freshness` — declared in `sources.yml`:

```yaml
sources:
  - name: postgres_raw
    tables:
      - name: orders
        loaded_at_field: ingested_at      # required on dbt-trino
        freshness:
          warn_after:  {count: 2, period: hour}
          error_after: {count: 4, period: hour}
```

**`loaded_at_field` REQUIRED on dbt-trino** — `ingested_at` (or equivalent) is a timestamp column that advances on each successful load. dbt runs `SELECT MAX(loaded_at_field)` against the source and compares to the thresholds. The metadata-fallback escape hatch (added in dbt 1.7 for adapters that can read freshness from warehouse metadata tables) is supported only on Snowflake, Redshift, BigQuery, and Databricks — NOT on dbt-trino. So the field is genuinely required for this stack.

**CI execution model**: run `dbt source freshness` as a SEPARATE CI stage BEFORE `dbt build`. A freshness check that triggers `error_after` exits with non-zero, and `set -e` halts the pipeline — downstream `dbt build` never runs.

**CRITICAL nuance (correctly stated)**: a freshness failure does NOT auto-block downstream models in a plain `dbt run` / `dbt build` — the DAG runs independently of freshness state. The two commands are separate; `dbt build` does not include freshness checks. You gate operationally via the SEPARATE CI stage:

```bash
dbt source freshness   # exits non-zero if any source >= error_after
dbt build              # only runs if previous stage exited 0
```

Optional `source_status:fresher+` selector (dbt 1.1+) for the more advanced pattern of "build ONLY models downstream of sources that became fresher since last run" — not needed for the simple gate.

**Verified against:**
- [docs.getdbt.com/reference/resource-properties/freshness](https://docs.getdbt.com/reference/resource-properties/freshness) — config keys, `loaded_at_field` requirement, `warn_after`/`error_after` semantics.
- [docs.getdbt.com/reference/commands/source](https://docs.getdbt.com/reference/commands/source) — non-zero exit on warn/error.
- [docs.getdbt.com/docs/deploy/source-freshness](https://docs.getdbt.com/docs/deploy/source-freshness) — separate command, does NOT block `dbt build` DAG by default.
- [docs.getdbt.com/docs/build/sources](https://docs.getdbt.com/docs/build/sources) — metadata-fallback adapter support list (Snowflake/Redshift/BigQuery/Databricks since 1.7); dbt-trino is NOT in that list, so `loaded_at_field` is required.

Clean 5.0. All four facts correct: config keys, separate CI stage gate, non-zero exit on error_after, accurate nuance that freshness does NOT auto-block the DAG.

**Recommendation: NO-OP.**

---

## Source-verified defects this iter

- **Resource-sourced defects**: 0
- **Responder one-off defects**: 0
- **Silent-wrong slips**: 0
- **Completeness shaves (non-scoring)**: 1 — Q3 didn't mention `arrays_overlap` direct boolean alternative (recall ceiling, not a defect).

## Watch verdicts

- **iter1141 r18 TopN-disambiguation FIX-A WATCH: CLOSED on first re-probe.** Responder reached the canonical TopN-bounded-heap framing without recurrence of either iter1141 misconception (`ORDER BY+LIMIT=full sort` or `lower query_max_memory_per_node to spill earlier`). The r18 §288-300 DIAGNOSIS GUARD card is doing exactly what it was designed to do — sits where the spill keywords lead, disambiguates the mechanism, defangs both misconceptions in a DO-NOT-WRITE table. This is the 8th consecutive watch in the 1st-NO-OP-then-LIGHT-FIX-A-then-CLOSE pattern: ADD-COLUMN (iter1121), partition-COUNT-folklore (iter1125), population-percentile (iter1127), dedup-tied-tuple (iter1130), SELECT-*-EXCEPT (iter1131), `{% if execute %}` (iter1133), percent_rank-DESC-direction (iter1137), TopN-disambiguation (iter1142).
- **No new watch streams opened this iter.**

## Topic-row updates

- **Query performance basics**: 4.1280/24 → (99.072 + 5.0)/25 = **4.16288/25 PASSED** (+0.0349, Q1 FIX-A lift; margin +0.66288, no longer thinnest required-topic).
- **Analytical query patterns on Iceberg+Trino**: 4.4697/93 → (415.6821 + 5.0)/94 = **4.4753/94 PASSED** (+0.0056, Q2 lift).
- **SQL best practices for OLAP**: 4.5552/204 → (929.2608 + 4.875)/205 = **4.5519/205 PASSED** (−0.0033, Q3 minor shave).
- **dbt sources / source freshness**: 4.4493/8 → (35.5944 + 5.0)/9 = **4.5105/9 PASSED** (+0.0612, Q4 lift).

ALL required topics REMAIN PASSED.

## Thinnest-margin order after iter1142

1. dbt-snapshots-SCD2 4.1079/18 (+0.6079, untouched, NEW thinnest required-topic)
2. storage-tiering 4.1302/12 (+0.6302, untouched)
3. query-perf-basics 4.16288/25 (+0.66288, Q1 FIX-A lift, moved from thinnest)
4. cost-considerations 4.3258/24 (+0.8258, untouched)
5. query-perf-regression-diagnosis 4.3436/21 (+0.8436, untouched)
6. Oracle-migration 4.4381/118 (+0.9381, untouched)
7. Iceberg-partition-design 4.4616/47 (+0.9616, untouched)
8. Analytical-query-patterns 4.4753/94 (+0.9753, Q2 lift)
9. Iceberg-maintenance 4.4800/179 (untouched)
10. federation 4.5024/312 (untouched, fragile-PASS preserved)
11. dbt-sources-freshness 4.5105/9 (+1.0105, Q4 lift)
12. SQL-best-practices-OLAP 4.5519/205 (+1.0519, Q3 minor shave)
13. CBO/ANALYZE 4.6105/22 (untouched)
14. improving-complex-SQL-perf-dbt 4.6111/25 (untouched)

## Recommendation

**NO-OP** — commit rubric + feedback only. iter1141 LIGHT FIX-A reached cleanly; no resource edits needed. Zero defects, zero silent-wrong slips. The only completeness shave (Q3 `arrays_overlap` not mentioned) is a known recall-ceiling pattern, not a resource gap (the function IS in the array.md resource).

## Teacher guidance

**No resource edits this iter.** The r18 §288-300 TopN-disambiguation card from iter1141 worked exactly as designed:
- The card lives where the keyword path leads ("ORDER BY + spilling" → r18 §spill-to-disk section → §288 DIAGNOSIS GUARD).
- Both misconceptions are explicitly inline-WRONG-marked in a DO-NOT-WRITE table.
- The canonical (TopN bounded heap + chase TableScan + partition predicate + EXPLAIN verification) is the copy-attractive form, NOT the defanged misconception.

This is the textbook pattern from the "Defang DO-NOT-WRITE Snippets" memory pin: canonical lives outside the DO-NOT-WRITE table as the copy-attractive form, banned forms inside the table marked WRONG. Worked on first re-probe.

## Re-probe queue (for next sweep)

1. **dbt-snapshots-SCD2 19th angle** (NEW thinnest required-topic, untouched 2 iters since iter1140 Q2 reach — confirm SCD-2 routing durability with another "build change history" phrasing without the word "snapshot").
2. **storage-tiering 13th angle** (still thin, untouched 2 iters since iter1140 Q4 — try the archive-table UNION ALL via dbt view variant, not the MinIO ILM path that's been probed).
3. **Q1 TopN-disambiguation 2nd-instance generative sustainment** — different phrasing to confirm durability past first re-probe ("scrollable infinite-scroll API: `ORDER BY id LIMIT 200 OFFSET N` on the events table is 8s; will a bigger node help?").
4. **Q3 `arrays_overlap` direct-boolean phrasing** — "is there a function that returns true/false if two arrays share any element?" — not urgent, recall-ceiling probe.
5. **cost-considerations 25th angle** (untouched since iter1141 Q4 reached `system.runtime.queries+tasks` canonical).

## Pattern observation

**24-iter sustainment band:** STRONG PASS iters 1090/1092/1093/1117/1118/1119/1121/1122/1125/1127/1128/1131/1133/1134/1137/1140/**1142** + LIGHT FIX-A iters 1091/1116/1124/1129/1132/1136/1138/1141 + NO-OP+WATCH iters 1120/1123/1126/1130/1135 + PASS+DOUBLE-LIGHT-FIX-A iter 1139.

iter1142 4.9688 STRONG PASS NO-OP is the band's second-highest single-iter average (after iter1137's 5.000), and is the recovery iter from iter1141's thin 4.1875 PASS+LIGHT-FIX-A. The pattern of "LIGHT FIX-A reaches cleanly on first re-probe" continues — 8 watch streams in a row have closed on first re-probe with no escalation needed. The fix-mechanism (additive DIAGNOSIS GUARD card placed at the keyword-magnet section + DO-NOT-WRITE inline defang of the two specific misconceptions + cross-ref back to the prior canonical location) is the most reliable shape of LIGHT FIX-A — it doesn't churn existing content (just adds), doesn't introduce new copy-attractive snippets that can backfire (banned forms inside DO-NOT-WRITE marked WRONG), and lives where the broken keyword path lands.

The Q3 `arrays_overlap` shave is the same minimum-sufficient-answer pattern seen in iter1140 Q1 (didn't explicitly name INDF + explain why it would silently filter) and iter1138 Q1 (didn't lead with the direct 2-arg `truncate` form before iter1138 LIGHT FIX-A reconciled r27 §4.4C). It's a recall-ceiling not a resource gap — the more direct form exists in the resource catalogue but the responder defaults to the longer composition when both forms are technically correct. No fix attempt — these are best caught with re-probes targeting the specific phrasing class.

**Federation/CBO/improving-complex-SQL-perf-dbt** untouched this iter — fragile-PASS federation 4.5024/312 preserved with no regression risk introduced.

**Expected next-iter profile**: another breadth STRONG PASS in the 4.6-5.0 band unless a thinnest-row probe (dbt-snapshots-SCD2 or storage-tiering) surfaces a new defect class.
