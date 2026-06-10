# iter946 Feedback (EXTENDED PHASE, ZERO-edit RE-PROBE sweep)

**Overall: 4.65625 PASS** (margin +1.15625; OVERALL AVERAGE governs; no per-Q veto). FEDERATION NOT PROBED (4.49944/310 row UNCHANGED). All dialect verified vs trino.io/docs/467 (connector/iceberg.html, sql/create-table.html, sql/select.html, functions/aggregate.html) via WebFetch 2026-06-10 — NOT against resources/.

## Per-question scores

### Q1 — Iceberg CREATE TABLE partitioning (THE RE-PROBE of iter945 Q2 PARTITIONED-BY foreign-DDL slip): **5.00**
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5
- Responder LED with `CREATE TABLE iceberg.analytics.events (...) WITH (partitioning = ARRAY['month(event_time)', 'bucket(tenant_id, 64)'], format='PARQUET', format_version=2)` — VERIFIED VERBATIM against trino.io/docs/467/connector/iceberg.html example `CREATE TABLE example.testdb.customer_orders ... WITH (partitioning = ARRAY['month(order_date)', 'bucket(account_number, 10)', 'country'])`. All five claims confirmed:
  - (a) `WITH (partitioning = ARRAY[...])` is the Trino Iceberg form — CONFIRMED (sql/create-table.html shows NO PARTITIONED BY clause; properties go through WITH only).
  - (b) `month(event_time)` is a valid Iceberg partition transform — CONFIRMED.
  - (c) `bucket(tenant_id, 64)` is COLUMN-FIRST per Trino convention — CONFIRMED via docs example `bucket(account_number, 10)`.
  - (d) `format_version=2` and `format='PARQUET'` are valid table properties — CONFIRMED.
  - (e) Hive-vs-Trino contrast table (PARTITIONED BY → WITH (partitioning=ARRAY[...]); bucket count-first Spark → column-first Trino; TBLPROPERTIES → WITH; omit USING iceberg) — accurate per pinned reference_trino_bucket_arg_order.md + verified docs.
- Bucket-over-identity multi-tenant advice sound: bucket(tenant_id, 64) bounds partition cardinality vs identity(tenant_id) which creates one partition per tenant (partition-explosion risk for many-tenant SaaS); WHERE tenant_id='acme' still prunes via the bucket transform because Iceberg hashes the predicate value through the same transform function — CONFIRMED architecturally correct (Iceberg partition pruning applies the transform to predicate literals).
- **★ ★ ★ Q1 RE-PROBE VERDICT = PARTITIONED-BY FOREIGN-DDL SLIP ONE-OFF / SLIP CLOSED ★ ★ ★**: iter945 Q2 PARTITIONED BY foreign-DDL slip DID NOT RECUR. Responder correctly used WITH (partitioning = ARRAY[...]) AND explicitly WRONG-marked PARTITIONED BY as Hive/Spark not Trino with a side-by-side contrast table. Pedagogy is proactively defensive (heads off the exact slip pattern the iter945 responder fell into). Findability assessment (state.json) validated. NO FIX-A needed.

### Q2 — LEFT JOIN + COUNT(non-null right col) for zero-comment posts: **5.00**
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5
- `SELECT p.id, p.title, COUNT(c.id) AS comment_count FROM blog_posts p LEFT JOIN comments c ON c.post_id=p.id GROUP BY p.id, p.title` — VERIFIED VALID 467.
- COUNT(c.id) NOT COUNT(*) — CONFIRMED canonical. Per aggregate.html: `count(x)` "Returns the number of non-null input values" while `count(*)` "Returns the number of input rows". For a zero-comment post, the LEFT JOIN produces one row with NULL-padded right side → COUNT(c.id) sees NULL and excludes it (returns 0); COUNT(*) sees the row and includes it (returns 1) — the classic anti-COUNT(*)-after-LEFT-JOIN trap.
- Responder's explicit WRONG-mark on COUNT(*) is correct pedagogy (textbook).
- GROUP BY p.id, p.title valid; p.title in GROUP BY required since not functionally-determined-by p.id from Trino's perspective (no PRIMARY KEY metadata).

### Q3 — JOIN + SUM GROUP BY + ORDER BY alias + Trino-vs-Postgres performance framing: **5.00**
- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5
- `SELECT s.store_id, s.store_name, SUM(o.amount) AS total_sales FROM orders o JOIN stores s ON s.store_id=o.store_id WHERE o.order_date >= current_date - INTERVAL '30' DAY GROUP BY s.store_id, s.store_name ORDER BY total_sales DESC` — VERIFIED VALID 467.
- INTERVAL '30' DAY — valid qualifier (DAY in YEAR/MONTH/DAY/HOUR/MINUTE/SECOND set per pinned reference_trino_interval_qualifiers.md).
- `current_date - INTERVAL '30' DAY` — valid temporal arithmetic; bare-column predicate `o.order_date >= ...` unwraps cleanly (no date()/CAST wrapping needed) per pinned reference_trino_unwrap_temporal_predicates.md.
- Performance claims accurate vs Postgres:
  - Columnar projection — CORRECT (Parquet columnar, only amount/store_id/order_date columns read).
  - Partition pruning via WHERE order_date — CORRECT (date predicate unwrap reaches Iceberg pruning).
  - Automatic broadcast join of small dim table (stores) — CORRECT (Trino CBO broadcasts small-side automatically when join input fits memory; broadcast_threshold default 100MB session config).
  - No B-tree indexes (min/max file stats + partition transforms instead) — CORRECT (Iceberg's per-file column min/max in manifest + partition spec is the substitute for Postgres index lookups).
  - CBO on by default — CORRECT (Trino 467 optimizer always on; CBO joins enabled when statistics present via ANALYZE).
- ORDER BY total_sales DESC (alias reference) — VALID 467 (responder's intent aligns with widely-documented Trino behavior; ORDER BY accepts SELECT-output aliases — confirmed in iter941/942/944 sweeps).

### Q4 — GROUP BY email HAVING COUNT(*) > 1 (duplicate detection): **3.625**
- Accuracy 4 / Completeness 3 / Clarity 4 / Actionability 3.5
- Main answer `SELECT email, COUNT(*) AS occurrence_count FROM users GROUP BY email HAVING COUNT(*) > 1 ORDER BY occurrence_count DESC` — VERIFIED VALID 467 and CORRECT canonical duplicate-detection idiom. ARRAY_AGG(user_id ORDER BY user_id) variant valid (ordered aggregation supported per aggregate.html). WHERE-vs-HAVING pedagogy correct.
- **★ DEFECT — Q4 "HAVING trims memory" folklore aside CONFIRMED MISLEADING (loose perf claim, NOT dialect error)**: secondary aside claims "add HAVING COUNT(*) > 1 early to trim memory pressure on high-cardinality GROUP BY." This is FOLKLORE WRONG: per sql/select.html (verified verbatim WebFetch 2026-06-10) "HAVING filters groups after groups and aggregates are computed." HAVING runs AFTER aggregation — by the time the COUNT(*) > 1 predicate is evaluated, the per-email working set (one entry per distinct email) has already been built and the aggregation memory footprint is fixed. HAVING only trims OUTPUT rows; it does NOT reduce aggregation memory pressure or speed up the GROUP BY hash table build. Pre-aggregation memory reduction requires a WHERE predicate (which the duplicate-detection use-case can't have since we don't know which emails are dupes until we count). Same loose perf-folklore was flagged at iter941 Q1 ("HAVING COUNT(*) > N reduces high-cardinality GROUP BY memory") — this is now the 2nd cumulative recurrence of the "HAVING trims memory" colloquialism.
- SCOPE: minor Comp/Clarity/Act ding on the secondary aside (not the main answer). The main HAVING COUNT(*) > 1 for duplicate-detection is correct.
- RESPONDER SLIP (loose perf colloquialism on otherwise clean resources). NOT a findable resource gap (resources teach HAVING-runs-after-aggregation accurately). NOT a dialect error.

## Overall

**(5.00 + 5.00 + 5.00 + 3.625) / 4 = 18.625 / 4 = 4.65625 PASS** (margin +1.15625).

## Scope of defects

- **Q1**: NO RESOURCE DEFECT / NO RESPONDER SLIP / NO FINDABLE GAP — iter945 Q2 PARTITIONED-BY foreign-DDL slip CONFIRMED ONE-OFF (did not recur even when directly re-probed; responder additionally proactively WRONG-marked the foreign form).
- **Q2**: NO RESOURCE DEFECT / NO RESPONDER SLIP / NO FINDABLE GAP — textbook clean.
- **Q3**: NO RESOURCE DEFECT / NO RESPONDER SLIP / NO FINDABLE GAP — textbook clean.
- **Q4**: NO RESOURCE DEFECT in main answer / RESPONDER SLIP on secondary "HAVING trims memory" perf-folklore aside (2nd cumulative recurrence after iter941 Q1; same loose perf colloquialism) / NOT findable gap — resources teach HAVING-runs-after-aggregation accurately, this is the responder importing folklore on top of correct foundations.

## Recommendations for next iteration

**iter947 = DEFAULT NO-OP — teacher ZERO edits.**

Rationale:
- Q1 PARTITIONED-BY RE-PROBE CLOSED the iter945 Q2 slip on the first probe — strong evidence the iter945 slip was one-off and the resources at r09 / r10 / r28 (state.json's findability map) are durable. No FIX-A needed; no PARTITIONED-BY defang card needed.
- Q4 "HAVING trims memory" folklore is 2nd cumulative recurrence (iter941 Q1 was 1st) — borderline for escalation but RE-PROBE-DON'T-CHURN still applies: it's a SECONDARY aside, the MAIN answer is correct, and writing a dedicated "HAVING does not reduce aggregation memory" defang card risks New-Card-over-attracts-adjacent (the COUNT(*)/HAVING/GROUP-BY-perf neighborhood is dense). Threshold for FIX-A: 1+ further recurrence in next 3 sweeps without intervening clean answer on a HAVING-perf question.
- RE-PROBE next sweep: a Q with explicit "make this GROUP BY faster" / "reduce memory of GROUP BY" framing — verify responder leads with WHERE (or pre-aggregation/sampling) NOT HAVING for pre-aggregation memory reduction.
- Federation (4.49944/310) only un-passed row — bulletproofed angles only, no new edits.

## Pins reinforced

- Trino Iceberg CREATE TABLE partitioning = `WITH (partitioning = ARRAY['transform(col)', ...])` NOT `PARTITIONED BY (...)` (Hive/Spark form); VERBATIM trino.io/docs/467/connector/iceberg.html example.
- Trino Iceberg bucket transform COLUMN-FIRST `bucket(col, N)` (Spark count-first `bucket(N, col)`).
- month()/day()/year()/hour()/truncate()/bucket()/identity() — valid Iceberg partition transforms.
- format_version=2 + format='PARQUET' valid table properties.
- LEFT JOIN + `COUNT(non_null_right_col)` returns 0 for unmatched rows; `COUNT(*)` returns 1 for unmatched rows (the trap); per aggregate.html count(x) non-null vs count(*) all-rows.
- Trino has NO B-tree indexes — partition pruning + min/max file stats are the substitute.
- Broadcast join of small dim table is automatic per CBO when small side fits memory.
- `current_date - INTERVAL '30' DAY` valid; DAY is a valid INTERVAL qualifier (YEAR/MONTH/DAY/HOUR/MINUTE/SECOND).
- `GROUP BY x HAVING COUNT(*) > 1` is the canonical duplicate-detection idiom.
- `ARRAY_AGG(x ORDER BY y)` ordered aggregation valid 467.
- ORDER BY can reference SELECT alias.
- **★ HAVING runs AFTER aggregation per select.html — does NOT reduce aggregation working-set memory; only trims output rows. "HAVING COUNT(*) > N to reduce memory" is folklore — pre-aggregation memory reduction belongs in WHERE.**

PIN 467. DO NOT bump training/state.json (orchestrator does that).
