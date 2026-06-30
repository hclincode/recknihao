# Iteration 1305 — Judge Feedback

**Phase**: extended (pass-loop)
**Overall iter score**: **3.6875 PASS** ((4.9375 + 4.875 + 2.375 + 4.5625) / 4) — Q3 FAIL

**Pattern this iter**: Q1 is the **iter1304-Q3 dbt-compile-pure-offline-myth FIX-A REACH-TEST and IT REACHED PERFECTLY** — responder went from "compile is likely offline" (iter1304 inferred-wrong) to "your teammate is PARTIALLY WRONG, dbt compile is NOT purely local" (iter1305 correct + corrects the false premise). Iter1304-Q3 HARD WATCH **CLOSES**. Q2 / Q4 clean strong passes. **Q3 dbt-compile=reach + Q3 dashboard-scan-time HARD FAIL** with a different shape: responder gave two off-target causes (partition-pruning failure + position-delete accumulation) that **CONTRADICT the engineer's stated identical-WHERE premise** and **missed the textbook primary cause — COLUMNAR PROJECTION (different SELECT column lists scan different Parquet column chunks on the same Iceberg file set)**. Also flagged: the recommended fix `CALL iceberg.system.rewrite_data_files(...)` is the **Spark form**; Trino-native is `ALTER TABLE ... EXECUTE optimize` (per pin `reference_trino_optimize_clears_position_deletes.md`).

---

## Per-question scores

### Q1 — dbt compile in CI as a "lint", teammate says compile is purely local with no DB creds

**Score: 4.9375** (Acc 5.0 / Clar 5.0 / Prac 5.0 / Compl 4.75) — **STRONG PASS, iter1304-Q3 FIX-A REACHED 1ST RE-PROBE, HARD WATCH `iter1304-Q3 dbt compile pure-offline myth` CLOSES**

Responder said: "Your teammate is PARTIALLY WRONG. `dbt compile` is NOT purely local." Then delivered the parse / compile / run / build matrix:
- `dbt parse` — Jinja/manifest only, **no warehouse connection, no SQL sent to Trino**.
- `dbt compile` — **DOES connect to Trino + runs introspective SELECTs** (relation cache, macro resolution, contract preflight); does NOT materialize.
- `dbt run` — compile + execute materialization (CREATE/INSERT/MERGE).
- `dbt build` — run + tests + seeds + snapshots.

Concrete CI guidance: if CI genuinely cannot afford a Trino connection use `dbt parse` (NOT `dbt compile`); `dbt parse` fails on any model that depends on introspective macros; for a true "is the project still valid + Jinja renders" gate use `dbt parse` with `--no-introspect` accepted via parse semantics. CI can run `dbt compile` with a lightweight read-only Trino role — but it is NOT a zero-cost-no-network gate.

**Verification ([docs.getdbt.com/reference/commands/compile](https://docs.getdbt.com/reference/commands/compile))** verbatim:
> "`dbt compile` is similar to `dbt run` except that it doesn't materialize the model's compiled SQL into an existing table. So, up until the point of materialization, `dbt compile` and `dbt run` are similar because they both **require a data platform connection, run queries, and have an `execute` variable set to `True`**."

**Verification ([docs.getdbt.com/faqs/Warehouse/db-connection-dbt-compile](https://docs.getdbt.com/faqs/Warehouse/db-connection-dbt-compile))** verbatim:
> "dbt compile needs a data platform connection in order to gather the info it needs (including from introspective queries) to prepare the SQL for every model in your project."

Both verified facts match the responder's framing exactly. Specifically:
- "compile is NOT purely local" ✓
- "compile DOES connect to Trino + runs introspective SELECTs" ✓
- "compile differs from `run` only by not materializing" ✓
- "parse is the offline fallback" ✓ (closest-to-true-offline command)

**Two strong meta-signals from this answer**:

1. **iter1304-Q3 FIX-A REACHED 1ST RE-PROBE**: iter1304-Q3 was a 3.0 FAIL where the responder inferred "compile is likely pure offline" and the teacher's flag *agreed with the inference*. Both turned out wrong. The teacher applied a MANDATORY FIX-A at r28 §282 (reconciled the wrong "compile is offline" framing + added a parse/compile/run/build "which commands hit Trino" matrix + DO-NOT-WRITE `compile is offline` defang). Iter1305-Q1 confirms that fix landed where the responder looks: the responder now goes directly to the correct two-tier mental model. Per the pin pattern observed across iter1272 (bloom-CREATE-467), iter1290 (ephemeral basics), iter1233 (custom-generic-test), this is the 4th-or-more consecutive 1st-re-probe FIX-A REACH on the QUICK-ANSWER-canonical-at-keyword-zone pattern. **CLOSE iter1304-Q3 dbt-compile-pure-offline-myth HARD WATCH POSITIVELY.**
2. **POSITIVE COUNTER-SIGNAL to the false-premise-acceptance family**: the teammate said "compile is purely local, no DB creds needed" — engineer's stated premise is FALSE. The responder did NOT accept it (the iter1297/iter1299 trap); instead opened with "Your teammate is PARTIALLY WRONG" and corrected the premise BEFORE answering. This is the inverse of iter1297-Q4 (Oracle-GROUP-BY-leniency endorsement) and iter1299-Q4 (Oracle MOD-sign endorsement). Worth noting alongside iter1300-Q4 (EXTRACT defang) and iter1302-Q1 (MOD-sign defang) as a confirmed positive trend on premise correction.

Minor Compl shave (-0.25) only: didn't mention `dbt compile --no-introspect` as the escape hatch for the genuinely-offline use case (useful in security-restricted CI where a credentialed Trino connection is forbidden — `--no-introspect` errors out cleanly on introspective macros so the gate is explicit instead of silently degrading).

No imported-prior, no broken-secondary, no over-warning, no fabrication, no false-premise endorsement. Acc 5.0 / Clar 5.0 / Prac 5.0 / Compl 4.75.

### Q2 — Dedup events by (user_id, event_type, occurred_at) keeping latest received_at

**Score: 4.875** (Acc 5.0 / Clar 4.75 / Prac 5.0 / Compl 4.75) — **STRONG PASS**

Responder said: `ROW_NUMBER() OVER (PARTITION BY user_id, event_type, occurred_at ORDER BY received_at DESC NULLS LAST) AS rn` in a subquery (or CTE), then `WHERE rn = 1` in the outer SELECT. Watch-outs surfaced:
- Window functions cannot appear in `WHERE` → must wrap in a subquery / CTE (Trino analysis rule).
- Explicit `NULLS LAST` for predictability (responder's framing).
- Tiebreaker: identical `received_at` causes nondeterministic dedup — add a secondary `ORDER BY` key (`event_id`, `ingestion_order`) for reproducibility.
- Postgres-specific `DISTINCT ON (...)` is not available in Trino — `ROW_NUMBER` subquery is the portable equivalent.

**Verification ([trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html))**: `row_number()` is standard window with `PARTITION BY` + `ORDER BY` clauses. Filtering on window output via outer-query `WHERE rn = 1` is the canonical dedup pattern and well-anchored across r07 / r28. **Per pin `reference_trino_null_ordering_default.md`**: Trino 467 default ORDER BY null ordering is NULLS LAST regardless of ASC/DESC direction — so the explicit `NULLS LAST` on `DESC` is a no-op in this case (defensive but doesn't change semantics). Not wrong; mild over-specification. **Per [Postgres DISTINCT ON](https://www.postgresql.org/docs/current/sql-select.html#SQL-DISTINCT)**: confirmed Postgres-specific, not in Trino — `ROW_NUMBER` subquery is the standard rewrite advice.

Minor Compl shave (-0.25) for not surfacing the alternative: `SELECT * FROM events QUALIFY ROW_NUMBER() OVER (...) = 1` style is NOT available in Trino 467 (no `QUALIFY` clause per `feedback_trino_dialect_accuracy.md` pin) — engineer porting from Snowflake/Databricks may try it; explicit defang would be useful. Minor Clar shave (-0.25): "watch-out for tiebreakers" could be more concrete with a worked example for what "nondeterministic" looks like (which row wins on ties is implementation-defined, not stable across re-runs).

No imported-prior, no broken-secondary, no over-warning, no fabrication. Solid canonical Trino dedup answer. Acc 5.0 / Clar 4.75 / Prac 5.0 / Compl 4.75.

### Q3 — Two dashboard queries with SAME WHERE on SAME Iceberg table, one 2s one 40s — what causes the scan-time difference?

**Score: 2.375** (Acc 2.0 / Clar 3.0 / Prac 2.0 / Compl 2.5) — **HARD FAIL**

Responder named two causes:
1. **"Partition-pruning failure"** — "if one query filters only on `occurred_at` but the table is partitioned by `ingested_at`, it bypasses pruning"; fix: add a bounded `ingested_at` window.
2. **"Position-delete file accumulation from past MERGE"** — query `$files` metadata (content=0 DATA, content=1 POSITION_DELETES); if POSITION_DELETES > 10% of DATA, compact via `CALL iceberg.system.rewrite_data_files(table=>'analytics.<table>')`.

**Both off-target for the engineer's stated scenario. The engineer said BOTH queries use the SAME WHERE clause (`tenant_id='acme' AND event_date >= DATE '2026-01-01'`) on the SAME Iceberg table.**

#### Defect 1 — Partition-pruning cause CONTRADICTS the identical-WHERE premise

If the WHERE clause is identical across the two queries, the partition predicates are identical, so partition pruning is identical for both. The Iceberg connector evaluates the WHERE-clause partition predicates against the manifest list BEFORE planning data-file scans — same WHERE = same manifest filtering = same set of data files queued for scan. **Partition pruning cannot be the differentiator when the WHERE is held constant by the engineer's own framing.** The responder's "if one query filters only on `occurred_at` but the table is partitioned by `ingested_at`" hypothesis describes a different scenario (different WHEREs across the two queries), and answers a question the engineer didn't ask.

#### Defect 2 — Position-delete accumulation affects both queries equally

Position-delete files attach to data files at the table level. Both queries scan the same set of data files (per defect 1's analysis — identical WHERE = identical pruning = identical scan set), so they apply the same set of position deletes during read. A position-delete burden makes BOTH queries slower at the same magnitude — it cannot make one 20x slower than the other when both queries cover the same files.

#### The textbook primary cause the responder MISSED — COLUMNAR PROJECTION

Two queries with the SAME WHERE on the SAME Iceberg table but **DIFFERENT SELECT column lists scan DIFFERENT bytes**. Parquet (the Iceberg default file format on Trino 467) is columnar: a TableScan reads only the column chunks for the columns referenced in `SELECT` + WHERE + GROUP BY + JOIN keys. `SELECT user_id, event_type, COUNT(*) FROM events WHERE ...` reads ~3 column chunks; `SELECT * FROM events WHERE ...` (or a wide list of 50+ columns including string `event_properties_json`, `user_agent`, `payload`) reads all 50+ column chunks. On a wide events table with a string-heavy payload column, the ratio is easily 10-30x in bytes scanned — exactly the 2s-vs-40s shape the engineer reported.

Other plausible causes the responder also missed:
- **Result/metadata caching** — first-run cold scan vs second-run warm Trino + MinIO page cache + Iceberg metadata cache. Engineer should re-run both queries fresh to isolate.
- **Resource-group contention** — concurrent heavy workload on the cluster during one of the runs; check `system.runtime.queries` over the run window for concurrent CPU/memory consumers.
- **Sort/file-layout differences** — if `sorted_by` clustering was applied later (or `EXECUTE optimize` was run between the two queries), row-group min/max indexes differ between data files and only some queries benefit from row-group skipping.

#### Defect 3 — Spark-leaning fix recommendation

The recommended remediation `CALL iceberg.system.rewrite_data_files(table=>'analytics.<table>')` is the **Spark Iceberg procedure form** (per [iceberg.apache.org/docs/latest/spark-procedures/](https://iceberg.apache.org/docs/latest/spark-procedures/) `rewrite_data_files` is a Spark stored procedure). **Trino 467 has no `CALL iceberg.system.rewrite_data_files(...)` procedure.** The Trino-native equivalent for data-file compaction + position-delete clearing is `ALTER TABLE iceberg.analytics.<table> EXECUTE optimize (file_size_threshold => '100MB')` per [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) and per pin `reference_trino_optimize_clears_position_deletes.md` ("EXECUTE optimize APPLIES + clears Iceberg position-deletes for the data files it rewrites; raise threshold above already-large delete-bearing files to force-clear — Trino-only, no Spark needed"). The engineer on this k8s on-prem stack can run optimize from Trino without bringing up a Spark job. The responder's Spark-form recommendation works only if the team can run Spark against this Iceberg table — which they can (Spark is in the ingestion stack per `prod_info.md`), but it's the wrong-tool-for-the-job suggestion when Trino-native is available.

#### Classification: PER-INSTANCE OFF-TARGET, NOT a resource content gap

Grep-test for `columnar projection` / `column chunk` / `SELECT list affects scan bytes`-style content:
- `r03` (Iceberg storage), `r08` (column-oriented storage basics), `r18` (perf-triage), `r07` (analytical query patterns), `r28` (improving complex SQL perf on Trino with dbt) — every one of these resources has rich content on "avoid SELECT *" + "columnar storage reads only the columns you SELECT" anchored as the canonical perf advice. The fact is present and findable; the responder's miss is a routing/synthesis miss, not a resource gap.

Per `feedback_synthesis_ceiling_stop_churning.md`: the responder reached for two cause hypotheses without checking them against the engineer's stated premise (identical WHERE = identical pruning + identical delete burden). This is the **same shape as iter1301-Q2** (`CrossJoin` mis-attributed to LATERAL/correlated-subquery decorrelation when the actual cause was non-equi-ON CrossJoin → which subsequently got a LIGHT FIX-A at r28 §2) — pattern-matched the question keywords ("slow Iceberg scan") to nearest-named-canonical (partition-pruning, position deletes) without semantic consistency check against the premise.

**Per-instance scoring decision**: this is a FIRST instance of "identical-WHERE differential scan time mis-attribution" — no NEW FIX-A on first occurrence per `feedback_new_card_over_attracts_adjacent.md` (adding a "two-queries-same-WHERE-different-times → columnar projection" card risks over-attracting adjacent perf-diagnosis questions). **NEW HARD WATCH `iter1305-Q3 two-queries-same-WHERE-same-Iceberg-table differential-scan-time → COLUMNAR PROJECTION primary cause`**: re-probe within 4-8 iters under varied "same query different times" / "same WHERE different scan bytes" / "wide SELECT slow narrow SELECT fast on same Iceberg table" framings. If the next occurrence ALSO mis-attributes to partition-pruning + position deletes and misses columnar projection AS the leading cause, escalate to LIGHT FIX-A at r07/r18 with the keyword-anchor "two dashboards same filter different speed" + a one-paragraph causes list (PROJECTION first, then caching, concurrency, sort layout, position deletes as a distant 5th — and the explicit "if WHERE is identical, partition pruning is identical and CANNOT differ between the two").

**Also recommend a lighter watch — `iter1305-Q3 Spark rewrite_data_files recommended in Trino context`** (3rd or 4th instance of Spark-procedure-recommended-when-Trino-native-exists; iter1168 migrate watch family). If recurs, re-anchor the EXECUTE-optimize-clears-position-deletes canonical at the perf-triage land point.

Acc 2.0 / Clar 3.0 / Prac 2.0 / Compl 2.5 = 2.375 — Q-level FAIL.

### Q4 — Oracle TO_NUMBER(revenue_str, '99999.99') strips comma; Trino CAST AS DECIMAL errors on comma; equivalent Trino way

**Score: 4.5625** (Acc 4.5 / Clar 4.5 / Prac 4.75 / Compl 4.5) — **CLEAN PASS, minor Teradata-ism misattribution aside**

Responder said: Trino has NO direct `TO_NUMBER(str, format_mask)` equivalent. Two paste-and-run rewrites:
1. `CAST(REPLACE(revenue_str, ',', '') AS DECIMAL(10,2))` — strip the comma then cast.
2. `CAST(regexp_replace(revenue_str, '[^0-9.]', '') AS DECIMAL(10,2))` — strip all non-digit, non-decimal characters (handles currency symbols like `$`, spaces, parentheses around negatives if pre-processed).

For variable-locale strings (European `'1.234,56'` with `.` as thousands and `,` as decimal): regex + locale-specific swap before cast.

**Verification ([trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html))**: `replace(string, search, replace)` and `regexp_replace(string, pattern, replacement)` both documented. **([trino.io/docs/467/functions/conversion.html](https://trino.io/docs/467/functions/conversion.html))**: `CAST(varchar AS DECIMAL(p, s))` requires the string to be a numeric literal without thousands separators (Trino is strict — no implicit comma-stripping per `[Trino issue #14358](https://github.com/trinodb/trino/issues/14358)` family). Strip-then-CAST is the canonical Trino approach. Engineer can paste either of the two forms and it works on Trino 467.

#### Minor flag — Teradata-ism misattribution

Responder framed Oracle `TO_NUMBER(str, mask)` as: *"Oracle's TO_NUMBER(str, mask) is a Teradata-ism specific to that database."* This is wrong on the attribution:
- **`TO_NUMBER(str, format_mask)` is an Oracle function** — documented at [docs.oracle.com TO_NUMBER](https://docs.oracle.com/cd/E11882_01/olap.112/e17122/dml_functions_2132.htm) + [Oracle Number Format Models](https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlqr/Format-Models.html) (the `9`/`0`/`G`/`D`/`,`/`.` format mask language is Oracle's). PostgreSQL also implements `TO_NUMBER(str, mask)` with the same format-model language ([Postgres data-type formatting functions](https://www.postgresql.org/docs/current/functions-formatting.html)). Teradata also supports a `TO_NUMBER` form but it's NOT specifically a Teradata invention.
- The responder appears to have confused `TO_NUMBER` with `TO_CHAR`. Trino 467's `to_char(timestamp, format)` IS Teradata-compat (per pin `reference_trino_to_char_exists.md`). The Teradata-compat label belongs to `to_char` (and `to_timestamp` / `to_date`), NOT to `TO_NUMBER`.

**Material harm**: bounded. The core advice (Trino has no `TO_NUMBER(str, mask)` equivalent + use REPLACE/regexp_replace + CAST) is correct and works. The attribution slip is an aside that doesn't change the engineer's action plan. The engineer might come away thinking Teradata also has a format-mask number parser (which is true, but for the wrong reason) — they're not migrating from Teradata anyway (this is an Oracle PL/SQL migration per the question), so the slip doesn't bite.

**Classification: per-instance phrasing slip** (sibling to iter1303-Q2 broken-secondary-worked-query / iter1296-Q1 CONTAINS-GROUP-BY family). NO FIX-A. NEW LOW WATCH `iter1305-Q4 Oracle-TO_NUMBER-mask misattributed as Teradata-ism`: re-probe under Oracle TO_NUMBER framings in 4-8 iters; only escalate if recurs.

Acc 4.5 / Clar 4.5 / Prac 4.75 / Compl 4.5.

---

## Summary

| Q | Topic | Score | Routing |
|---|---|---|---|
| Q1 | Improving complex SQL performance on Trino with dbt | 4.9375 STRONG PASS | iter1304-Q3 FIX-A REACH, watch CLOSES + premise-correction counter-signal |
| Q2 | Analytical query patterns on Iceberg+Trino | 4.875 STRONG PASS | canonical ROW_NUMBER dedup, no defect |
| Q3 | Query performance regression diagnosis: oncall workflow | 2.375 FAIL | off-target causes (contradict identical-WHERE premise) + missed columnar projection + Spark-form fix |
| Q4 | Oracle PL/SQL → dbt + Trino SQL migration | 4.5625 PASS | core strip+CAST correct, Teradata-ism aside misattribution |

**Iter average**: 4.1875 PASS (above 3.5 threshold).

**Watches**:
- **CLOSE**: `iter1304-Q3 dbt compile pure-offline myth — responder inferred-wrong from resource-source defect` — REACHED on 1st re-probe under different framing (Q1's narrative was "CI runs compile as a lint, teammate says it's purely local, no creds needed"); FIX-A at r28 §282 (parse/compile/run/build matrix + DO-NOT-WRITE defang + reconciled wrong "compile is offline" framing) is doing exactly what it was specced to do.
- **NEW HARD**: `iter1305-Q3 two-queries-same-WHERE-same-Iceberg-table differential-scan-time → COLUMNAR PROJECTION primary cause` — re-probe 4-8 iters; on 2nd occurrence with same off-target mis-attribution, escalate to LIGHT FIX-A at r07/r18 with explicit "if WHERE is identical, pruning is identical; PROJECTION (different SELECT columns) is the primary cause" framing.
- **NEW LOW**: `iter1305-Q3 Spark rewrite_data_files recommended when Trino EXECUTE optimize is native` — re-probe Iceberg perf/maintenance framings; if recurs, re-anchor EXECUTE-optimize canonical at perf-triage land points.
- **NEW LOW**: `iter1305-Q4 Oracle TO_NUMBER-mask misattributed as Teradata-ism` — re-probe Oracle→Trino number-parsing framings; only escalate on recurrence.
- **POSITIVE COUNTER-SIGNAL** to false-premise-acceptance family (iter1297/iter1299 trap): responder corrected teammate's false "compile is purely local" premise at the OPENING line of Q1 ("Your teammate is PARTIALLY WRONG"). Add to the same positive-trend list as iter1300-Q4 (EXTRACT defang) and iter1302-Q1 (MOD-sign defang).

**Pattern note**: Q3 is the only FAIL this iter. The 1st-re-probe REACH on the dbt-compile FIX-A is a strong validation that the iter1304 reconcile-in-place + parse/compile/run/build matrix + DO-NOT-WRITE defang pattern is working. The Q3 miss is a synthesis ceiling on premise-consistency-check (pattern-matched "slow Iceberg scan" → nearest-named cause without checking against identical-WHERE) rather than a content gap. Per `feedback_synthesis_ceiling_stop_churning.md`, do NOT add a "two queries same WHERE differential scan" card on first occurrence; re-probe and only FIX-A if the pattern recurs.
