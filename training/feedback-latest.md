# Iter1170 — Judge Feedback

## Verdict: STRONG PASS — Average 4.8125 / 5.0

| Q | Topic row | Score | Verdict |
|---|---|---:|---|
| Q1 to_char numeric '2026-06-27 14:30:00' / Oracle teammate "Trino has no TO_CHAR" (WATCH RE-PROBE) | SQL query best practices for OLAP | 4.625 | **WATCH CLOSES — r27 to_char-exists-numeric-only FIX-A reaches with minor hh-vs-hh24 imprecision** |
| Q2 listagg / array_join(array_agg(DISTINCT x ORDER BY x), ', ') for dedup+sorted-comma-string | SQL query best practices for OLAP | 4.875 | pin-perfect dedup-listagg-via-array_join canonical + #20725 restriction correctly cited |
| Q3 730 day-partitions / planner scan-every-partition-metadata myth / Iceberg manifest-list pruning | Iceberg partition design for SaaS | 4.8125 | clean metadata-driven pruning canonical + rewrite_manifests-Spark-only caveat |
| Q4 ISO week extraction / EXTRACT(WEEK) vs week_of_year() | SQL query best practices for OLAP | 4.9375 | week_of_year + EXTRACT(WEEK) both verified, ISO-8601 Monday-start |

Iter average = (4.625 + 4.875 + 4.8125 + 4.9375) / 4 = **4.8125 STRONG PASS** (margin +1.3125 over 3.5 threshold).

**Watch status:** `r27 to_char-exists-numeric-only FIX-A iter1169` — **CLOSED** on first re-probe (no "to_char not registered" regression; responder affirms to_char EXISTS in Trino 467 Teradata module, lowercase-numeric-only codes, Oracle-uppercase fails).

**No new FIX-A required.** No new watch. Per-question minor shaves are recall-ceiling / one-off responder slips, not resource-sourced.

---

## Per-question detail

### Q1 (4.625 — Acc 4.5 / Clar 4.5 / App 4.5 / Compl 5.0) — to_char numeric '2026-06-27 14:30:00' (WATCH RE-PROBE)

**WATCH `r27 to_char-exists-numeric-only FIX-A iter1169` — CLOSES on first re-probe.**

Iter1169 the responder wrongly said "Trino has no to_char"; the FIX-A reconciled r27 (5 spots) to state Trino 467 HAS `to_char(timestamp, format)` (Teradata module, lowercase-numeric-only codes, no month names, no uppercase). Iter1170 Q1 (numeric-only format, engineer voices the Oracle-prior myth) tests whether the responder now correctly affirms to_char EXISTS.

**Iter1170 Q1 reaches the FIX-A canonical:**
- "YES Trino 467 HAS `to_char(timestamp, format)` (Teradata module)" — correct existence affirmation, NO "not registered" regression.
- "Lowercase-numeric-only" — correct.
- "Oracle uppercase 'YYYY-MM-DD HH24:MI:SS' FAILS" — correct (verified [trino.io/docs/467/functions/teradata.html](https://trino.io/docs/467/functions/teradata.html) "Case insensitivity is not currently supported. All specifiers must be lowercase").
- Recommended canonical: `date_format(created_at, '%Y-%m-%d %H:%i:%s')` OR `format_datetime(created_at, 'yyyy-MM-dd HH:mm:ss')` — both correct for 24-hour numeric `2026-06-27 14:30:00`:
  - `%H` = 24-hour hour (00-23), `%i` = minute (00-59), `%s` = second (00-59) — matches Trino MySQL date-format codes.
  - `format_datetime` Joda `HH` = 24-hour, `mm` = minute, `ss` = second — correct.
- Joda caveat noted (`MM` = month, `mm` = minute) — anti-trap for engineers porting from MySQL-style `%m`.

**MINOR IMPRECISION (-0.5 across Acc / Clar / App):** The responder's lowercase to_char example used `'yyyy-mm-dd hh:mi:ss'` — per Trino Teradata docs `hh` is the 12-HOUR code (1-12); for 24-hour the correct code is `hh24` (0-23). The engineer's literal requirement was "all numeric, no month names, 24-hour", so the strictly-correct lowercase to_char form would be `to_char(created_at, 'yyyy-mm-dd hh24:mi:ss')`. NOT load-bearing because:
- The responder explicitly framed lowercase to_char as a possible-but-not-recommended alternative ("would technically work with lowercase").
- The RECOMMENDED forms (`date_format('%H')` / `format_datetime('HH')`) both correctly produce 24-hour output.
- Engineer following the recommendation gets correct output `2026-06-27 14:30:00`.

This is responder recall ceiling on a secondary alternative aside (consistent with pinned `feedback_responder_broken_secondary_alternative`), NOT a resource defect — r27 FIX-A names the `hh24` code in the format-code table. Re-probing this exact slip in a future sweep would risk over-attractor (per `feedback_new_card_over_attracts_adjacent`); NO RESOURCE FIX.

Cites r27. Watch CLOSES on first re-probe (consistent with the recent "first NO-OP/LIGHT-FIX-A → close on next re-probe" pattern).

### Q2 (4.875 — Acc 5.0 / Clar 4.5 / App 5.0 / Compl 5.0) — listagg / dedup-sorted-comma-string

Canonical reached cleanly with the correct two-form distinction:

- **Already-unique input**: `listagg(product_sku, ', ') WITHIN GROUP (ORDER BY product_sku)` — verified at [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html) syntax `LISTAGG(expression [, separator] [ON OVERFLOW overflow_behaviour]) WITHIN GROUP (ORDER BY sort_item, [...])`; `WITHIN GROUP (ORDER BY ...)` is mandatory.
- **Dedup required**: `array_join(array_agg(DISTINCT CAST(product_sku AS varchar) ORDER BY CAST(product_sku AS varchar)), ', ')` — listagg has NO DISTINCT slot (verified — docs syntax has no DISTINCT keyword), so dedup must be pushed into array_agg.

**ORDER BY-must-match-DISTINCT restriction correctly cited:** the responder named "Trino issue #20725" — verified at [github.com/trinodb/trino/issues/20725](https://github.com/trinodb/trino/issues/20725) "Support distinct aggregation with ordering over different expressions". The restriction is real: `array_agg(DISTINCT concat(value, value) ORDER BY value)` fails because the ORDER BY expression (`value`) doesn't match the aggregated expression (`concat(value, value)`). Error message: "For aggregate function with DISTINCT, ORDER BY expressions must appear in arguments". CAST-wrap on both DISTINCT and ORDER BY is the canonical fix — character-identical match.

Minor clarity shave (-0.5 Clar): the framing "for already-unique use listagg, for dedup use array_join+array_agg" is correct but engineer might wonder when to assume already-unique (answer: when upstream guarantees it; safest default for ambiguous data is array_join form). Not load-bearing — both forms presented + engineer chooses based on data shape.

Cites r07. NO RESOURCE FIX.

### Q3 (4.8125 — Acc 4.75 / Clar 4.5 / App 5.0 / Compl 5.0) — 730-partitions metadata-scan myth

Misconception correctly debunked + Iceberg metadata-driven pruning canonical reached:

- **NO, Trino does NOT open/inspect every partition's metadata at plan time.** Correct.
- **Iceberg manifest list contains partition value range stats per manifest** — planner evaluates query predicate (e.g. `occurred_at >= DATE '2026-06-20' AND occurred_at < DATE '2026-06-27'`) against manifest-list partition summaries → skips entire manifests whose ranges don't overlap. Verified at [trino.io/blog/2023/04/11/date-predicates.html](https://trino.io/blog/2023/04/11/date-predicates.html) + [iceberg.apache.org/spec/](https://iceberg.apache.org/spec/) "The manifest list stores the snapshot's list of manifests, along with the range of values for each partition field... making it possible to plan without reading all manifests".
- **Two-level pruning correctly named**: (1) partition-level pruning at manifest-list scope skips whole manifests; (2) file-level pruning within surviving manifests via per-file column min/max stats. One-week query on 730-day-partitioned table reads only ~7 of 730 days' files.
- **Day-transform predicate handling**: the partition transform `day(occurred_at)` is applied to the filter so raw-timestamp predicates against `occurred_at` prune partitions correctly (consistent with pinned `reference_trino_unwrap_temporal_predicates.md`).
- **Caveat correctly stated**: manifest list + surviving manifests ARE read each query — large/disorganized manifests add planning overhead. Lever = `rewrite_manifests` to cluster manifests by partition column.
- **rewrite_manifests Spark-only on 467** — verified at [github.com/trinodb/trino/issues/14821](https://github.com/trinodb/trino/issues/14821) "Add the functionality of the Iceberg rewrite_manifests procedure" still OPEN; Trino 467 does NOT support `CALL iceberg.system.rewrite_manifests(...)` — Spark Iceberg procedure required. Production-stack-aligned (Spark ingestion already on-prem per `prod_info.md`).

Minor accuracy shave (-0.25 Acc): the responder said "manifests in a tree optimized for pruning" — manifests are flat files referenced by the manifest list (which acts as an index over manifests); "tree" is loose framing for what's actually a two-level (manifest-list → manifests → data-files) hierarchy. Not load-bearing — mental model still correct.

Cites r10. NO RESOURCE FIX.

### Q4 (4.9375 — Acc 5.0 / Clar 5.0 / App 5.0 / Compl 4.75) — ISO week extraction

Pin-perfect ISO-week canonical:

- **`week_of_year(date)` exists in Trino 467** — verified at [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/467/functions/datetime.html) "week_of_year(x) is an alias for week()".
- **`EXTRACT(WEEK FROM date)` works** — `WEEK` is in the official EXTRACT field list alongside YEAR/QUARTER/MONTH/DAY/DAY_OF_MONTH/DAY_OF_WEEK/DOW/DAY_OF_YEAR/DOY/YEAR_OF_WEEK/YOW/HOUR/MINUTE/SECOND/TIMEZONE_HOUR/TIMEZONE_MINUTE.
- **Both equivalent** — same underlying ISO-8601 implementation: week 1-53, Monday start, defined per ISO-8601 (week 1 = week containing the first Thursday of the year).
- **GROUP BY application**: `GROUP BY week_of_year(event_date)` works directly (plain GROUP BY accepts expressions per pinned `reference_trino_complex_grouping_column_names_only.md` — only GROUPING SETS/CUBE/ROLLUP require column names).

Minor completeness shave (-0.25 Compl): didn't mention `EXTRACT(YEAR_OF_WEEK FROM date)` (a.k.a. `YOW`) as the companion field for getting the ISO-week-year when crossing year boundaries (e.g. 2024-12-30 belongs to ISO week 1 of YEAR_OF_WEEK 2025). For multi-year reports grouped by ISO week, engineers typically need both fields to avoid "week 1" of multiple years collapsing into one bucket. Recall ceiling; not load-bearing — the engineer's literal ask (single year, plain number) is satisfied by `week_of_year` alone.

Cites r07/r13. NO RESOURCE FIX.

---

## Cross-question patterns

**Watch closure pattern continues:** `r27 to_char-exists-numeric-only FIX-A iter1169` closes on first re-probe — 10 of last 10 watches close on first re-probe in the established "first NO-OP/LIGHT-FIX-A → close on next re-probe" pattern (iter1144 RANGE-INTERVAL three-surfaces, iter1145 IGNORE-NULLS-placement, iter1149 EXTRACT-YEAR_MONTH-MySQL-import, iter1155 sessionization-final-count, iter1162 percent-of-total OVER, iter1166 broadcast-CASE+OVER, iter1167 relational-division-COUNT-DISTINCT, iter1169 migrate-Trino-native, iter1170 to_char-exists).

**Imported-prior family — clean run:** Q1 (to_char-from-Oracle), Q2 (listagg-from-Oracle), Q4 (week_of_year-from-Postgres/Oracle) all asked about Oracle/Postgres functions and whether they exist in Trino 467. All three correctly answered EXIST + dialect-specific syntax. Consistent with pinned `reference_trino_to_char_exists.md` + `reference_trino_listagg_native.md` + `reference_trino_starts_with_ends_with.md` family — verify-existence-before-asserting-absence has held this iter.

**No resource defects surfaced.** All three minor shaves (Q1 hh-vs-hh24, Q2 framing, Q3 "tree" loose framing, Q4 YEAR_OF_WEEK omission) are responder recall ceilings or framing slips, not findability gaps. NO FIX-A required.

**Production-stack fit:** All four answers fit on-prem Trino 467 + Iceberg + MinIO + Hive Metastore stack. Q3 explicitly named `rewrite_manifests` as Spark-only — Spark ingestion already in-stack per `prod_info.md`, so the recommendation is actionable. No cloud-only or Trino-469+ traps recommended.

---

## Iter1170 decision: STRONG PASS NO-OP

- Topic averages all comfortably above passing threshold.
- Watch closes cleanly.
- Per-question shaves are responder ceiling, not resource-anchored.
- No re-probe queue additions; continue breadth probing on the remaining lower-margin topics (storage tiering, dbt snapshots SCD2, query performance basics — bottom three by margin).
