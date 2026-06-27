# Iter1188 Judge Feedback

**Overall verdict: PASS (thin) — 2 FIX-A items** (avg **3.7344 / 5**, above 3.5 threshold but Q2 + Q4 both FAIL on accuracy).

- **Q1 (THIN query-perf-basics row) — STRONG, lifts the row.** Three Trino-on-Iceberg degradation causes — manifest/small-file explosion, stale ANALYZE statistics, function-wrap-on-predicate killing partition pruning — all factually correct + paired with the right diagnostic command (`EXPLAIN ANALYZE`, `SHOW STATS`, `EXPLAIN (TYPE DISTRIBUTED)`). LOWER()-on-predicate-column IS a real Trino 467 pruning-killer (the `reference_trino_unwrap_temporal_predicates.md` exception covers `year(col)`/`date_trunc`/`CAST AS DATE`/`EXTRACT(YEAR)` only; non-temporal string functions like LOWER are NOT unwrapped).
- **Q2 (Iceberg-maintenance) — RECURRING EXPIRE/ORPHAN ROLE INVERSION → LIGHT FIX-A.** Responder INVERTED: "Step 1 expire_snapshots ... just marks files as orphaned. Step 2 remove_orphan_files actually deletes them from disk." This is BACKWARDS. Per [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html): `expire_snapshots` "removes all snapshots and all related metadata AND data files" — it PHYSICALLY ISSUES the S3 DELETE for data files exclusively referenced by expired snapshots. `remove_orphan_files` is a DIFFERENT, smaller class — files NEVER committed to any snapshot (failed-write debris), found by directory-listing MinIO and diffing against ALL reachable metadata. THIS IS THE SECOND RECURRENCE — iter1155 Q3 had the same wrong claim and was scoped as a responder slip with the watch contract "if recurrent → consider additive r17 callout 'expire_snapshots issues S3 DELETE during execution, not a deferred cleanup' with cross-ref to remove_orphan_files as the different tool for different garbage." That contract NOW triggers.
- **Q3 (SQL best practices dialect) — STRONG, pin-perfect.** `array_distinct(customer_tags)` — same ARRAY(VARCHAR) type, removes dups, no UNNEST. Verified at [trino.io/docs/467/functions/array.html](https://trino.io/docs/467/functions/array.html).
- **Q4 (Analytical query patterns) — BROKEN HEATMAP AVERAGE.** EXTRACT(DAY_OF_WEEK) → ISO 1=Mon..7=Sun and EXTRACT(HOUR) → 0-23 BOTH correct (verified at [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html); already pinned at r07 §2245-2272). GROUP BY (EXTRACT calls) correct. BUT the `ROUND(AVG(event_count) OVER (PARTITION BY day_of_week, hour_of_day), 2) AS avg_events` column is SEMANTICALLY BROKEN: after GROUP BY (dow, hour), each partition contains exactly ONE row, so the window AVG returns that one row's value = `event_count` itself, a NO-OP. ALSO referencing the SELECT-list alias `event_count` inside a window-function expression at the same SELECT level is not generally legal in Trino (aliases visible in GROUP BY/ORDER BY only) — likely parses as a different name resolution path. The engineer's literal "Tuesday 2pm averages 450" requires a TWO-LEVEL aggregation (count per DAY, then average those daily counts per (dow, hour)) which the responder missed. Engineer who copies gets COUNT(*) totals (~13× too large for a 90-day window) labeled as "avg_events".

Total iter1188 score: (4.6875 + 2.625 + 5.0 + 2.625) / 4 = **3.7344 / 5**.

| Q | Topic | Score | Note |
|---|---|---|---|
| 1 | Query performance basics (Trino plan degrades over time on Iceberg) | 4.6875 | Three causes + diagnostics all correct: small-file/manifest bloat + EXECUTE optimize, stale stats + SHOW STATS distinct_values_count NULL + ANALYZE, predicate-wrap LOWER() + EXPLAIN DISTRIBUTED Filter-above-TableScan. THIN row lifts. |
| 2 | Iceberg-maintenance (expire_snapshots vs remove_orphan_files) | 2.625 | **RECURRING ROLE INVERSION — LIGHT FIX-A**. Responder says "expire just marks, orphan deletes" — BACKWARDS. expire_snapshots PHYSICALLY deletes exclusively-owned data files; remove_orphan_files handles failed-write debris. iter1155 watch contract triggers. r17 §2135 has the correct CRITICAL DISTINCTION but findability gap from "MinIO storage grows despite DELETEs" framing. |
| 3 | SQL best practices — array_distinct | 5.0 | Pin-perfect. `array_distinct(customer_tags)` verified at trino.io/docs/467/functions/array.html. |
| 4 | Analytical query patterns (heatmap 2D average) | 2.625 | EXTRACT(DAY_OF_WEEK 1..7) + EXTRACT(HOUR 0..23) + GROUP BY all correct, but `AVG(event_count) OVER (PARTITION BY day_of_week, hour_of_day)` is a NO-OP single-row window (and likely an alias-in-window parse error). Engineer copies → COUNT(*) totals labeled "avg_events" ~13× too large. Missed the two-level per-day-count-then-avg pattern. Responder synthesis ceiling. |

---

## Per-question detail

### Q1 — Why a 3s join query degrades to 60s+ over 6 weeks with SQL unchanged + flat data volume (THIN query-perf-basics ROW LIFT)

**Score 4.6875** — three causes accurate, paired with the right diagnostic per cause. Lifts the thin query-perf-basics row.

**Cause A — Manifest / small-file explosion + planning overhead.** Correct. Each Spark micro-batch ingest commits a new Iceberg snapshot with new manifest files; over 6 weeks of frequent writes the planner has to read an ever-growing manifest pile + per-file Parquet footers. Diagnostic: `EXPLAIN ANALYZE` and inspect `planningTime` (Trino reports this in the analyze output) — a planning-time component that has grown from milliseconds to seconds is the smoking gun for manifest bloat. Fix: `ALTER TABLE ... EXECUTE optimize(file_size_threshold => '256MB')` (Trino 467 native — verified at trino.io/docs/467/connector/iceberg.html) merges small Parquet files; for manifest consolidation specifically, Spark `CALL iceberg.system.rewrite_manifests(...)` is the 467 path (`optimize_manifests` is Trino 470+ only — verified at [trinodb/trino PR #24678](https://github.com/trinodb/trino/pull/24678) merged Feb 4 2025 milestoned 470).

**Cause B — Stale ANALYZE statistics → CBO picks bad join order / wrong join distribution.** Correct and important. As the events table grows from ~200M to ~400M without re-`ANALYZE`, the CBO continues to use stats that reflect the old shape (NDV, null-fraction, row counts), then picks the wrong build-side / wrong join order. Diagnostic: `SHOW STATS FOR <table>` — `distinct_values_count = NULL` for a column means it has never been analyzed and the CBO is blind on that column. Fix: `ANALYZE iceberg.<schema>.<table> WITH (columns = ARRAY['col_1','col_2', ...])` (limit to the join/filter columns on a 400M-row table — full-table ANALYZE on every column is expensive). Verified at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) ("You can specify a subset of columns to be analyzed with the optional `columns` property"). Stats are stored in the Iceberg Puffin file as `apache-datasketches-theta-v1` NDV sketches.

**Cause C — Partition pruning regression from a function-wrapped predicate.** Correct framing for the LOWER()/string-function case. The responder describes a BI tool wrapping the predicate in `LOWER(account_email) = 'x'`, which prevents Trino from matching the predicate against partition-column values for pruning. Diagnostic: `EXPLAIN (TYPE DISTRIBUTED) <query>` and look for `Filter` above `TableScan` (predicate didn't push into the scan) instead of `constraint=` inside the TableScan (predicate pushed for pruning). Fix: remove the function wrap.

**IMPORTANT CALIBRATION — temporal-predicate exception is correctly handled.** Trino 467 has unwrap rules that DO push temporal-function predicates back into bare-column comparisons (`year(col)=2025` / `date_trunc('day', ts)=DATE '2025-01-01'` / `CAST(ts AS DATE)` / `EXTRACT(YEAR FROM ts)` — verified per pinned `reference_trino_unwrap_temporal_predicates.md`). LOWER() and other string functions are NOT in the unwrap set, so the responder's "function-wrap kills pruning" claim is correct FOR string functions specifically. No imported-prior slip here.

Scoring breakdown:
- Tech: 5.0/5 — all three causes verified; LOWER() unwrap exception correctly excluded
- Clar: 4.5/5 — uses "manifest list", "CBO", "broadcast vs shuffle" without re-explaining each; minor jargon load
- Practical: 4.75/5 — every cause paired with concrete diagnostic command + concrete fix
- Complete: 4.5/5 — three causes is solid coverage; could add "dynamic filtering disabled" (`enable-dynamic-filtering=false` debug toggle), and concurrency/queueing as 4th cause for queries that degrade with cluster load growth

---

### Q2 — MinIO storage grows ~20%/mo despite DELETEs + flat live row counts (RECURRING EXPIRE/ORPHAN INVERSION → LIGHT FIX-A)

**Score 2.625** — diagnosis of WHY storage grows is correct, but the two-step RECLAIM recipe INVERTS the roles of `expire_snapshots` and `remove_orphan_files`.

**Correct parts.**
- Iceberg holds old snapshots indefinitely by default → past DELETE-snapshots' data files stay live as long as any old snapshot still references them. CORRECT.
- Partition-aligned DELETE (filter only on identity-partitioned column) is METADATA-ONLY — no position-delete files. CORRECT per [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) ("the deletion of entire partitions if the `WHERE` clause specifies filters only on the identity-transformed partitioning columns") and r17 §157-180.
- Row-level MoR DELETE on a non-partition predicate writes position-delete files → `rewrite_position_delete_files` (Spark-only on Trino 467 per [trinodb/trino #27371](https://github.com/trinodb/trino/issues/27371)). CORRECT.

**WRONG — load-bearing role inversion.** Responder says:

> "Step 1: EXECUTE expire_snapshots(retention_threshold => '7d') — expiring old metadata pointers.
> Step 2: EXECUTE remove_orphan_files(retention_threshold => '7d') — physically delete data files no snapshot references.
> Step 1 alone doesn't free MinIO space — it just marks files as orphaned. Step 2 actually deletes them from disk."

This is BACKWARDS:

| Procedure | What it ACTUALLY does (verified) | What responder claimed |
|---|---|---|
| `expire_snapshots(retention_threshold => '7d')` | Drops old snapshot metadata AND **physically deletes (issues S3 DELETE) the data files those expired snapshots EXCLUSIVELY owned**. This IS the primary mechanism that reclaims storage from "deleted-row data files" once the deleting snapshots have aged out. | "Just marks files as orphaned; doesn't free MinIO space." — FALSE |
| `remove_orphan_files(retention_threshold => '7d')` | A different, smaller GC class — sweeps files **NEVER COMMITTED to any snapshot at all** (e.g., a Spark write job uploaded a Parquet file then crashed before the manifest commit). Found by a full directory scan of MinIO + diff against all reachable metadata. | "Actually deletes data files that no snapshot references." — DESCRIPTION CONFLATES Class-1 (snapshot-released) with Class-2 (failed-write debris) |

Verified per Trino 467 docs ([trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html)) + Apache Iceberg spec/maintenance docs + r17 internal canonicals at §235, §1659-1663, §2133, §2135-2140.

r17 §2135 has the EXACT CRITICAL DISTINCTION the responder violated (verbatim quote from r17):
> "**`expire_snapshots`** handles **Class 1 garbage**: data files that *were* properly committed into snapshots, but those snapshots have now aged out. When a snapshot expires, `expire_snapshots` deletes the files it exclusively owned.
> **`remove_orphan_files`** handles **Class 2 garbage**: data files that *were never committed into any snapshot at all* — e.g., a Spark write job uploaded a Parquet file to MinIO, then crashed before writing the Iceberg manifest commit.
> `expire_snapshots` alone does NOT catch failed-write orphans. `remove_orphan_files` alone does NOT clean up the data files freed by snapshot expiry (they aren't orphans — they were in a snapshot; they just need the snapshot expired first before `expire_snapshots` can delete them)."

**RECURRENCE CHECK — this is the SECOND instance.**
- iter1155 Q3 (`r17 expire_snapshots metadata-only-vs-physical-delete responder caveat iter1155` watch): same inversion ("expire_snapshots is about *metadata* — the actual data files stay around until a later maintenance cycle. Storage reclamation is incremental across weekly maintenance windows.") Scoped as responder slip, watch + footnote contract: "if recurrent → consider additive r17 callout 'expire_snapshots issues S3 DELETE during execution, not a deferred cleanup' with cross-ref to remove_orphan_files as the different tool for different garbage."
- iter1188 Q2: same inversion, DIFFERENT framing ("MinIO storage grows despite DELETEs / two-step reclaim").

**GREP EVIDENCE — r17 IS CORRECT at multiple anchors:**

| r17 anchor | Quote |
|---|---|
| §235 (Procedures summary table) | `expire_snapshots`: "Drops old snapshot metadata; **physically deletes data files referenced ONLY by dropped snapshots**." |
| §236 (Procedures summary table) | `remove_orphan_files`: "Sweeps unreferenced files from MinIO/S3 left by **failed writers**." |
| §1661 (Maintenance order callout) | "`expire_snapshots` **physically deletes them** from MinIO (issues S3 DELETE calls). These files are NOT orphans and are NOT handled by `remove_orphan_files`; `expire_snapshots` handles them directly." |
| §2133 (expire_snapshots What-it-does) | "removes old snapshot **metadata** ... AND **physically deletes** the data files that are no longer referenced by any surviving live snapshot ... not just marked eligible, actually removed." |
| §2135-2140 (CRITICAL DISTINCTION) | Class-1 vs Class-2 garbage framing (full quote above). |

→ Resource is CORRECT. Responder confabulates the wrong story DESPITE r17's correct canonical in 5 separate places. Per `feedback_synthesis_ceiling_stop_churning.md` + `feedback_new_card_over_attracts_adjacent.md`, NO new keyword-magnet card. But per the iter1155 watch contract, the recurrence triggers a NARROW DO-NOT-WRITE inline-WRONG defang where the question routes.

**LIGHT FIX-A SPEC (NARROW — DO-NOT-WRITE inline-WRONG row only):**

Add ONE row to the existing DO-NOT-WRITE table at r17 §176-180 (the GDPR/retention LEADING CANONICAL inline-WRONG table — that's where the keyword chain "MinIO storage grows / despite DELETEs / two-step reclaim / expire vs orphan" routes from the question phrasing). New row:

```
| "Step 1 `expire_snapshots` only marks files as orphaned; Step 2 `remove_orphan_files` actually deletes them from disk." | **FALSE — INVERTED.** `expire_snapshots` PHYSICALLY DELETES data files (issues S3 DELETE) for files exclusively referenced by expired snapshots — that IS the primary storage-reclaim mechanism after DELETEs. `remove_orphan_files` handles a different garbage class: files never committed to any snapshot (failed-write debris from crashed Spark jobs). Both are needed for different reasons; their roles are NOT marker-then-deleter. | Run `EXECUTE expire_snapshots(retention_threshold => '7d')` — storage WILL drop on MinIO once that completes (no separate "actually delete" step). Run `EXECUTE remove_orphan_files(retention_threshold => '7d')` as a separate sweep for failed-write debris, not as Step 2 of the same reclaim. |
```

Plus a one-line keyword anchor extension at §159 to route the iter1188 framing: add to the existing anchor list: `MinIO storage growing despite DELETEs, why is storage growing when DELETEs run, two-step reclaim expire then orphan, expire vs orphan-files which one frees space, does expire_snapshots actually delete data files, is expire_snapshots just metadata, expire snapshots free disk space`.

Cross-ref: link FROM the new DO-NOT-WRITE row TO §2135-2140 CRITICAL DISTINCTION block ("see § Class-1 vs Class-2 garbage framing for the full mechanism").

**Watch label**: `r17 expire-vs-orphan role-inversion DO-NOT-WRITE-row FIX-A iter1188`. Re-probe in 5-10 iters with structurally different framing ("compaction ran but MinIO usage didn't drop / what's the order I should run expire and orphan / is one redundant").

**Production-stack alignment.** Both `EXECUTE expire_snapshots` and `EXECUTE remove_orphan_files` are Trino 467 native (verified at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html)) — fits prod_info.md Trino-on-Iceberg via Hive Metastore stack. The `retention_threshold => '7d'` parameter form is correct (NOT `retention_duration` / NOT `INTERVAL '7' DAY`).

Scoring breakdown:
- Tech: 1.5/5 — diagnosis correct but core reclaim mechanism inverted
- Clar: 4.0/5 — well-structured two-step format
- Practical: 2.5/5 — engineer who blindly runs BOTH gets right outcome; engineer who internalizes "Step 1 alone doesn't free space" walks away with wrong mental model + may skip Step 1 if remove_orphan_files alone seems "enough"
- Complete: 2.5/5 — covers structural growth causes; broken on the core reclaim mechanism

---

### Q3 — Dedupe each row's ARRAY(VARCHAR) without UNNEST+GROUP BY+array_agg

**Score 5.0** — pin-perfect.

```sql
SELECT array_distinct(customer_tags) AS deduped_tags FROM accounts
```
- `array_distinct(x) → array` verified verbatim at [trino.io/docs/467/functions/array.html](https://trino.io/docs/467/functions/array.html): "Remove duplicate values from the array `x`."
- Same `ARRAY(VARCHAR)` type in / out. CORRECT.
- One-row-in / one-row-out (no UNNEST fanout / re-aggregation). CORRECT — the engineer's literal "without UNNEST+GROUP BY+array_agg" constraint is satisfied.
- Family routing also clean — paired with `array_remove(x, element)` (remove ALL occurrences of a specific value) for the "drop one specific tag from everyone" use case (iter1175 Q2 canonical).

Scoring breakdown:
- Tech: 5.0/5 — verified
- Clar: 5.0/5 — short + on-point
- Practical: 5.0/5 — one-liner
- Complete: 5.0/5 — answers the literal ask

---

### Q4 — Heatmap: avg event count per (day-of-week, hour-of-day) = "Tuesday 2pm averages 450"

**Score 2.625** — extraction + GROUP BY correct, **BROKEN AVG**.

**Correct parts:**
- `EXTRACT(DAY_OF_WEEK FROM event_timestamp)` → ISO 1=Mon..7=Sun. VERIFIED at [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html); `DAY_OF_WEEK` is an accepted EXTRACT field, alias `DOW` also accepted, returns 1..7 (Monday..Sunday) — already pinned at r07 §2245-2272 and `iter665 FIX-A` (busiest-weekday-per-user inoculation).
- `EXTRACT(HOUR FROM event_timestamp)` → 0..23. VERIFIED at same docs page.
- `GROUP BY EXTRACT(DAY_OF_WEEK FROM ts), EXTRACT(HOUR FROM ts)` is valid Trino 467 (plain GROUP BY accepts expressions per pinned `reference_trino_complex_grouping_column_names_only.md`; only GROUPING SETS/CUBE/ROLLUP require column names).
- 90-day WHERE filter for partition pruning is fine.
- `ORDER BY day_of_week, hour_of_day` (using SELECT aliases) valid in Trino 467 ORDER BY.

**BROKEN — the `avg_events` column is a NO-OP redundant column at best, parse error at worst.**

```sql
ROUND(AVG(event_count) OVER (PARTITION BY day_of_week, hour_of_day), 2) AS avg_events
```

Two problems:

1. **Semantic NO-OP.** After `GROUP BY (dow, hour)`, the query produces EXACTLY ONE row per (dow, hour) cell — there are at most ~7×24 = 168 such cells. The window function then partitions by `(day_of_week, hour_of_day)`, but each partition contains EXACTLY ONE ROW (the one grouped cell). `AVG` over a single-row partition returns that row's value unchanged. So `avg_events == event_count` for every row — a redundant column. The "average across the ~13 Tuesday-2pm occurrences in 90 days" computation the engineer wants is NOT performed.

2. **Likely alias-in-window analysis error.** `AVG(event_count) OVER (...)` references the SELECT-list alias `event_count` (= `COUNT(*)`) at the same SELECT level. Trino SELECT-list aliases are visible in GROUP BY / ORDER BY (Trino extension) but NOT inside other SELECT-list expressions including window-function arguments. The query likely fails to analyze with "Column 'event_count' cannot be resolved" before semantic concerns even apply.

**What the engineer actually wants (TWO-LEVEL aggregation):**

```sql
WITH per_day AS (
  SELECT DATE(event_timestamp)                        AS d,
         EXTRACT(DAY_OF_WEEK FROM event_timestamp)    AS dow,
         EXTRACT(HOUR FROM event_timestamp)           AS hr,
         COUNT(*)                                     AS daily_count
  FROM events
  WHERE event_timestamp >= CURRENT_DATE - INTERVAL '90' DAY
  GROUP BY 1, 2, 3
)
SELECT dow, hr, ROUND(AVG(daily_count), 2) AS avg_events
FROM per_day
GROUP BY dow, hr
ORDER BY dow, hr;
```

Inner CTE produces ~7×24×13 ≈ 2184 (date, dow, hour, count) rows. Outer averages the ~13 daily counts per (dow, hour) cell → 168 rows where Tuesday-2pm ≈ 450 as the engineer expects. Responder gave neither this two-level shape nor any equivalent (e.g., COUNT-then-divide-by-distinct-dates).

**Practical impact.** Engineer who copies the responder's query gets:
- `event_count` column = ~5850 for Tuesday-2pm (sum of all events on all 13 Tuesdays at 2pm) — CORRECT as a total, MISLEADING as an "average"
- `avg_events` column = ~5850 (same, due to single-row window NO-OP) — labeled "avg" but is the total

Either the query parse-errors (alias-in-window case → engineer gets an error, retries), or it returns 13× too large for the "average" interpretation. Silently wrong is worse than parse error.

**Classification.** Responder synthesis ceiling on a two-level analytical pattern. Per `feedback_responder_broken_secondary_alternative.md` adjacent family — except here the broken SQL is in the PRIMARY query not a secondary "alternative form," so a degree more serious. Per `feedback_synthesis_ceiling_stop_churning.md`, no resource fix (no specific "heatmap-cell average" canonical in r07; adding one risks `feedback_new_card_over_attracts_adjacent.md` over-attracting adjacent 2D-aggregation Qs). NO FIX-A. Watch label `r07 two-level cell-average heatmap synthesis ceiling iter1188`; re-probe in 5-10 iters with structurally different framing ("avg orders per (channel, week-of-year)", "avg latency per (region, hour)", "avg revenue per (plan_tier, signup_month)") to confirm one-off vs recurring.

Scoring breakdown:
- Tech: 2.0/5 — extract right, count right, but the AVG attempt is a NO-OP single-row window + likely alias-in-window parse error; missed the two-level CTE pattern
- Clar: 3.5/5 — clear explanations of DOW (ISO 1..7) and HOUR (0..23) numbering and the GROUP-BY-repeats-EXTRACT-call rule; the `avg_events` column is presented confidently as if it computed the average
- Practical: 2.0/5 — engineer copies → wrong numbers labeled as "averages" (either parse error or ~13× off); engineer's stated goal "Tuesday 2pm averages 450" not actually produced
- Complete: 3.0/5 — the two literal sub-questions ("Extract numeric DOW + hour" + "GROUP BY for 2D breakdown") were both answered correctly; missed the per-day-count-then-avg two-level pattern which is the entire framing of "average per cell"

---

## Source classification summary

| Q | Defect class | Resource fix? |
|---|---|---|
| Q1 | No defect | No |
| Q2 | **2nd recurrence of expire-vs-orphan role-inversion folklore**. r17 §235/§236/§1661/§2133/§2135-2140 ARE CORRECT — responder confabulates inversion despite multiple correct anchors. Per iter1155 watch contract trigger. | **LIGHT FIX-A** — NARROW DO-NOT-WRITE inline-WRONG row added to existing r17 §176-180 GDPR-purge DO-NOT-WRITE table (where "MinIO storage grows + reclaim + expire/orphan" keyword chain routes) + extend §159 keyword anchors. NOT a new keyword-magnet card. Watch label `r17 expire-vs-orphan role-inversion DO-NOT-WRITE-row FIX-A iter1188`. |
| Q3 | No defect | No |
| Q4 | Responder synthesis ceiling — broken two-level aggregation on heatmap-style cell-average pattern. NOT resource-sourced — no resource teaches a single-row window AVG of COUNT(*) shape. | **NO FIX-A** — per `feedback_synthesis_ceiling_stop_churning.md` + `feedback_new_card_over_attracts_adjacent.md`. Watch label `r07 two-level cell-average heatmap synthesis ceiling iter1188`; re-probe with structurally different domain (avg orders per (channel, week-of-year) / avg latency per (region, hour) / avg revenue per (plan_tier, signup_month)). If RECURS → consider additive r07 mini-block "count-per-period-then-avg-per-bucket" canonical near §2245 EXTRACT(DAY_OF_WEEK) area; if ONE-OFF → leave untouched. |

---

## Rubric updates

| Topic | Old | + iter1188 Q | New | Δ |
|---|---|---|---|---|
| **Query performance basics** (Q1) | 4.1758 / 28 | +4.6875 | **4.1934 / 29** | +0.0176, margin +0.6934, **still thinnest required-topic** |
| **Iceberg table maintenance** (Q2) | 4.4608 / 203 | +2.625 | **4.4518 / 204** | -0.0090, margin +0.9518, FIX-A pending |
| **SQL query best practices for OLAP** (Q3) | 4.5783 / 266 | +5.0 | **4.5798 / 267** | +0.0015, margin +1.0798 |
| **Analytical query patterns on Iceberg+Trino** (Q4) | 4.5152 / 136 | +2.625 | **4.5014 / 137** | -0.0138, margin +1.0014, cushion absorbs |

---

## Watches

- **OPEN FIX-A** — `r17 expire-vs-orphan role-inversion DO-NOT-WRITE-row FIX-A iter1188`. Narrow inline-WRONG row in r17 §176-180 DO-NOT-WRITE table + §159 keyword-anchor extension. NOT a new keyword-magnet card (per over-attractor risk). Re-probe in 5-10 iters under structurally different framing ("compaction ran but MinIO usage didn't drop / order to run expire vs orphan / is one redundant when DELETEs are already done").
- **Watch (NO-OP)** — `r07 two-level cell-average heatmap synthesis ceiling iter1188`. Responder synthesis ceiling, NOT resource-sourced. Re-probe in 5-10 iters under structurally different 2D-aggregation domain.
- **Closed watches (carry-over)** — `r17 object_store_layout_enabled semantics-card FIX-A iter1184` closed at iter1185.

Next-iteration recommendation: TEACHER lands the LIGHT FIX-A (one DO-NOT-WRITE row + keyword-anchor extension in r17). Next sweep should re-probe query-perf-basics (still thinnest at 4.1934/29, well above 3.5 but exposed) and heatmap/2D-aggregation patterns under different domain framing. Avoid churning Iceberg-maintenance unless a 3rd recurrence appears; the cushion (+0.9518 margin) absorbs this fail.
