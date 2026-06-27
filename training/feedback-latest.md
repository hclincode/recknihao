# Iter1192 Judge Feedback

**Overall: 4.625 / 5.0 — PASS + LIGHT FIX-A.** Q1 / Q2 / Q4 clean 5.0. Q3 (WATCH iter1190 dbt merge connector matrix) lands the primary merge-Iceberg-vs-Hive distinction correctly but the Option-2 `delete+insert` fallback is imprecise on plain non-ACID Hive tables — engineer who follows it on a default Hive table will hit a connector-level error. WATCH `iter1190 dbt merge connector matrix` **CLOSES** on the merge-supported-on-Iceberg-only / not-on-Hive primary axis. **NEW soft-watch opens: iter1192 dbt delete+insert-on-non-ACID-Hive precision.**

---

## Q1 — Iceberg manifest compaction: what manifests are, why planning slows, Spark-vs-Trino fix path

**Score: 5.0 / 5.0 / 5.0 / 5.0 = 5.0**

Pin-perfect Iceberg-maintenance/manifest-compaction canonical reach. All load-bearing facts verified:

1. **Manifest definition** — Correct: an Iceberg manifest file is a metadata-layer index listing which data files belong to a snapshot, with per-data-file column statistics (min/max/null-count) used at planning time for file pruning. The snapshot's `manifest_list` points to the set of manifest files; each manifest references the actual Parquet data files.

2. **Planning-time slowdown mechanism** — Correct. A 5-min Spark micro-batch over 6 months yields ~52K micro-batch writes; each write tends to produce small, tiny manifests if not compacted. At plan time Trino's coordinator reads the manifest list and then opens EACH manifest to filter data files by partition / min-max stats. With thousands of tiny manifests this becomes O(N) metadata I/O against MinIO BEFORE a single data row is scanned — hence "several seconds before rows stream" is exactly the manifest-explosion symptom. Correctly distinguished from data-file compaction (`optimize`) which is a separate axis.

3. **Trino 467 has NO native manifest-rewrite procedure** — **VERIFIED**. `optimize_manifests` was added in Trino **470 (5 Feb 2025)**, NOT 467 (6 Dec 2024). Confirmed via [trinodb/trino PR #25378](https://github.com/trinodb/trino/pull/25378) "Optimize manifests per top-level partition in Iceberg" + [Release 470 notes](https://trino.io/docs/current/release/release-470.html) + [trinodb/trino#14821](https://github.com/trinodb/trino/issues/14821) "Add the functionality of the Iceberg rewrite_manifests procedure (e.g. in OPTIMIZE)" — that issue tracks the feature request that landed as `optimize_manifests` in 470. Trino 467 has neither `optimize_manifests` nor a `rewrite_manifests` procedure of its own. Responder's "optimize_manifests is Trino 470+, NOT 467" framing is exactly right.

4. **Recommended Spark CALL** — Correct routing. On a 467 deployment, manifest compaction must be done from Spark via `CALL <catalog>.system.rewrite_manifests(table => 'analytics.events')`. Spark Iceberg's `rewrite_manifests` named-arg syntax `table => 'schema.table'` is the documented form. Fits production stack (Spark is the ingestion engine per `prod_info.md`).

5. **Weekly cadence + chain with optimize** — Operationally sound. Spark `rewrite_manifests` after a regular data-file `optimize` is the standard maintenance sequence (data-file compaction reduces the manifest contents that get rolled up; doing optimize FIRST means the rewritten manifests reference the freshly-compacted larger data files).

No imported-prior slip on the 470-vs-467 cutoff (which is exactly the kind of version-cliff this pin-set guards against).

---

## Q2 — Three side-by-side per-account event metrics in one pass without subquery joins

**Score: 5.0 / 5.0 / 5.0 / 5.0 = 5.0**

Pin-perfect conditional-aggregation canonical. Both forms verified valid Trino 467 and both genuinely single-pass:

1. **`COUNT(CASE WHEN event_type='x' THEN 1 END)` form** — standard Trino 467 conditional-aggregation. Aggregates within the GROUP BY pass, no separate scan, no join. Engineer's "three subqueries joined" pattern collapses to ONE table scan + ONE hash aggregation grouped by `account_id`. Correct.

2. **`MAX(CASE WHEN event_type='x' THEN 1 ELSE 0 END) AS has_x`** — standard boolean-flag pattern, correctly used for the "did each event ever happen" columns. Also single-pass.

3. **`COUNT(*) FILTER (WHERE event_type='x')` form** — VERIFIED at [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html). FILTER clause is supported on aggregate functions in Trino 467. Equivalent to the CASE-WHEN form in semantics and in execution plan; the planner translates both to the same conditional-aggregation operator. Responder's "both scan once" claim is correct.

4. **GROUP BY account_id + 6 conditional aggregates in one SELECT** — exact pattern the engineer needs to replace their three-subquery join. Concrete actionable rewrite delivered.

No broken-secondary-alternative slip per `feedback_responder_broken_secondary_alternative`. No over-warning per `feedback_responder_overwarning_folklore`. Clean canonical.

---

## Q3 (WATCH `iter1190 dbt merge connector matrix`) — dbt incremental `merge` on Iceberg vs Hive connector

**Score: 3.5 / 4.0 / 3.0 / 3.5 = 3.5 (THRESHOLD PASS + LIGHT FIX-A)**

Primary merge-Iceberg-vs-Hive distinction CORRECTLY nailed (watch CLOSES on that axis). But the Option-2 `delete+insert` fallback recommendation has a precision defect that will mislead the engineer.

### Verified correct (primary watch axis closes):

1. **`incremental_strategy='merge'` is connector-dependent, not pure dbt-handled** — Correct. dbt-trino emits a Trino `MERGE INTO` statement; the question of whether it succeeds is governed by the target connector's MERGE support. Per [docs.getdbt.com/reference/resource-configs/trino-configs](https://docs.getdbt.com/reference/resource-configs/trino-configs) verbatim: *"With the `merge` incremental strategy, dbt-trino constructs a Trino `MERGE` statement to insert new records and update existing records, based on the `unique_key` property. Be aware that there are some Trino connectors that don't support `MERGE` or have limited support."*

2. **Iceberg connector supports MERGE INTO** — Correct. Verified at [trino.io/docs/467/sql/merge.html](https://trino.io/docs/current/sql/merge.html) + [iceberg connector docs](https://trino.io/docs/467/connector/iceberg.html). Iceberg's row-level delete/update via position-delete files makes MERGE first-class on this connector.

3. **Hive connector does NOT support MERGE INTO on standard tables** — Correct. Verified at [trino.io/docs/467/connector/hive.html](https://trino.io/docs/467/connector/hive.html) verbatim: *"MERGE is only supported for ACID tables."* For ordinary non-transactional Hive tables (the default on most legacy deployments), MERGE INTO fails at connector level. dbt-trino merge fails on Hive non-ACID — matches the engineer's observed FAIL.

4. **Option 1: `CALL iceberg.system.migrate(schema_name=>..,table_name=>..)` then switch catalog to `iceberg.*` and use `merge`** — Correct. Iceberg's `migrate` procedure is native in Trino 467 (pinned `reference_trino_iceberg_migrate_native.md`). This IS the right load-bearing recommendation for this production stack.

### Defect on Option 2 — `delete+insert` as a Hive fallback is imprecise (LIGHT FIX-A):

Responder framed Option 2 as: *"keep Hive table, use incremental_strategy='delete+insert' with unique_key='order_id', which dbt-trino compiles to `DELETE FROM hive... WHERE order_id IN (SELECT order_id FROM new_rows); INSERT INTO ... SELECT`."*

The mechanism description is **literally what dbt-trino emits**, but the implied claim that this WORKS on a plain Hive-connector table is **wrong for the same reason MERGE doesn't work**. Verified at [trino.io/docs/467/connector/hive.html](https://trino.io/docs/467/connector/hive.html) verbatim:

> "DELETE applied to non-transactional tables is only supported if the table is partitioned and the WHERE clause matches entire partitions."
>
> "Transactional Hive tables with ORC format support 'row-by-row' deletion, in which the WHERE clause may match arbitrary sets of rows."

Concretely:
- `DELETE FROM hive_table WHERE order_id IN (SELECT order_id FROM new_rows)` is a **row-level DELETE** (WHERE clause matches arbitrary rows, not entire partitions).
- On a **non-ACID Hive table** (the default, and almost certainly what "legacy Hive-connector catalog" refers to), row-level DELETE is **unsupported** — same connector-capability gap as MERGE.
- On a **transactional/ACID Hive table** (ORC format, Hive 3.x metastore, configured with `transactional=true` TBLPROPERTY), row-level DELETE works and `delete+insert` would succeed (and MERGE would too, making the Option-2 reasoning self-contradictory at that point).

So `delete+insert` on a plain non-ACID Hive table fails with the SAME row-level-delete-not-supported connector error as MERGE. The engineer who follows Option 2 will run dbt, get a connector-level error mid-build, and have to come back for clarification.

**Practical impact for engineer:** Option 1 (migrate to Iceberg) is the actual single-recommendation answer for the typical case. Option 2 should be reframed as: (a) `incremental_strategy='append'` (insert-only — works on plain Hive, but the engineer loses the "update existing rows" semantics from `unique_key`); or (b) full-refresh on Hive (heavy but works); or (c) if the Hive table IS ORC + transactional + Hive 3.x metastore, `delete+insert` AND `merge` both work — but then there's no reason to avoid merge.

### Why LIGHT FIX-A and not just recall-ceiling:

- Engineer is on the production "Trino 467 + Iceberg + Hive Metastore" stack per `prod_info.md`. The "legacy Hive-connector catalog" question is a realistic on-prem migration scenario, and the engineer will follow the responder's option list.
- The defect is **actively misleading**, not a benign omission. Option 2 currently reads as "this will work as a fallback" when it will fail at connector level.
- Resource grep check: searched resources/ for the exact failure mode — `delete\+insert.*hive`, `delete.*WHERE.*non.transactional`, `MERGE.*ACID`, `row.level.*delete.*hive`. The Hive-connector ACID-vs-non-ACID distinction for row-level DELETE has thin coverage. Recommend a small additive card in r28 (or wherever the dbt-trino incremental-strategy matrix is canonicalized) capturing: dbt-trino emits `DELETE FROM target WHERE key IN (...) ; INSERT INTO target SELECT...` for `delete+insert`, and the DELETE half requires either Iceberg connector or ACID/transactional Hive table — same connector-capability gate as MERGE. Plain non-ACID Hive falls back to `append` or full-refresh.

**FIX-A spec:**

- **Where**: r28 dbt-strategies section (or wherever the merge/append/delete+insert matrix lives), plus a cross-reference from r27 Hive-vs-Iceberg connector capability matrix.
- **What to add (1 small card)**: "dbt-trino `delete+insert` on Hive connector — same connector gate as merge."
  - dbt-trino compiles `delete+insert` to `DELETE FROM <table> WHERE <unique_key> IN (...)` + `INSERT INTO <table> SELECT ...`.
  - That DELETE is a row-level delete; same Hive-connector capability gate as MERGE: works on transactional/ACID ORC Hive 3.x tables, FAILS on plain non-ACID Hive tables.
  - On plain non-ACID Hive, viable incremental options: `append` (insert-only, no update-existing-rows semantics) or full-refresh. For update-existing-rows semantics on Hive, migrate to Iceberg via `CALL iceberg.system.migrate(...)`.
- **DO-NOT-WRITE inline defang** (per `feedback_defang_donotwrite_snippets`): mark "delete+insert as a workaround when MERGE fails on Hive" as WRONG inline; make the migrate-to-Iceberg path the copy-attractive canonical.
- **Keyword anchors**: `delete+insert hive`, `delete+insert non-ACID`, `Hive connector merge unsupported fallback`, `dbt incremental Hive connector`, `Hive row-level delete unsupported`, `legacy Hive catalog merge`.

### WATCH `iter1190 dbt merge connector matrix` resolution:

**CLOSES on the primary axis** (merge=Iceberg-native, Hive=not supported, migrate-to-Iceberg as load-bearing fallback). Responder did NOT repeat the iter1190 over-absolute "merge is fully supported" framing; this iter's framing is appropriately connector-gated.

**NEW soft watch opens: `iter1192 dbt delete+insert-on-non-ACID-Hive precision`.** Re-probe in 5-10 iters with framing like "on Hive we tried delete+insert but get a row-level-delete error — what now?" or "we switched merge→delete+insert on the Hive catalog and it still fails" to test whether after LIGHT FIX-A the responder lands the connector-capability-gate-is-the-same answer.

---

## Q4 — Oracle INSTR port to Trino strpos / position

**Score: 5.0 / 5.0 / 5.0 / 5.0 = 5.0**

Pin-perfect Oracle-to-Trino direct port. All facts verified at [trino.io/docs/467/functions/string.html](https://trino.io/docs/current/functions/string.html):

1. **`strpos(string, substring)`** — 1-indexed, returns 0 if not found. Verified verbatim semantics match Oracle `INSTR(column, 'substring')` first-occurrence behavior (Oracle INSTR is also 1-indexed and returns 0 on not-found). Drop-in semantic equivalence — same predicate `WHERE INSTR(error_message,'timeout') > 0` becomes `WHERE strpos(error_message,'timeout') > 0` with identical semantics.

2. **`position('timeout' IN error_message)`** — SQL-standard form, identical semantics to `strpos`. Verified — Trino 467 supports both. Correctly framed as a stylistic alternative.

3. **Slicing: `SUBSTR(s, strpos(s,'timeout'), 7)`** — valid Trino 467. `substr(string, start, length)` is 1-indexed; passing the strpos result directly into substr position works because both share the 1-indexed convention. Note: when the substring is NOT found, strpos returns 0 and `substr(s, 0, 7)` returns the first 7 chars from position 0 in Trino (which is treated as position 1 — `substr` clamps start ≤ 0 to start of string in Trino, NOT empty-string). Engineer would want to guard with a `WHERE strpos(...) > 0` or `IF(strpos(...) > 0, substr(...), NULL)` pattern; responder's `WHERE strpos > 0` filter already supplies that guard for the predicate use, and the slicing example follows a WHERE so it's implicitly guarded too. Operationally correct.

4. **No fabrication, no over-warning, no broken secondary alternative.** Both forms (`strpos` + `position(... IN ...)`) are real, both work, both 1-indexed/0-on-miss. Clean canonical for an Oracle engineer.

Cites r27 Oracle-migration dialect-spillover guardrail.

---

## Topic routing + score updates

| Q | Topic | Score | Prior | New |
|---|---|---|---|---|
| Q1 | Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup (manifest-compaction canonical) | 5.0 | 4.4560/206 | 4.4582/207 |
| Q2 | Analytical query patterns on Iceberg+Trino: funnels, cohorts, time-series SQL (conditional aggregation / FILTER clause) | 5.0 | 4.5111/140 | 4.5146/141 |
| Q3 | Improving complex SQL performance on Trino with dbt (incremental strategies + connector matrix) | 3.5 | 4.5731/32 | 4.5407/33 |
| Q4 | Oracle PL/SQL → dbt + Trino SQL migration (INSTR → strpos / position direct port) | 5.0 | 4.4667/151 | 4.4702/152 |

All four touched topics remain comfortably PASSED. Q3 row dips slightly but holds well above the 4.5 raised-threshold-not-applicable bar (this row's threshold is 3.5; current 4.54 retains +1.04 margin).

---

## Open watches (carry / new)

1. **iter1190 dbt merge connector matrix — CLOSES this iter.** Responder correctly distinguished Iceberg=native-merge vs Hive=not-supported on the primary axis. No more iter1190 over-absolute "merge fully supported" framing.

2. **iter1191 dbt-contract two-phase mechanism — carry forward, NOT exercised this iter.** Soft watch on whether responder lands the preflight-introspection-query + DDL-time two-phase enforcement distinction when probed with "do contracts need a live Trino connection" / "CI without warehouse" framing. Re-probe in next 5-8 iters.

3. **NEW iter1192 dbt delete+insert-on-non-ACID-Hive precision — opens this iter.** Responder framed `delete+insert` as a viable `merge`-fallback on plain Hive tables, but the underlying row-level DELETE has the same connector-capability gate as MERGE — both fail on non-ACID Hive. LIGHT FIX-A specified above; re-probe in 5-8 iters after r28/r27 update.

---

## Next iteration suggestion (iter1193)

BREADTH continuation. Suggested rotation:

- **Q1**: an Iceberg maintenance angle not recently hit — `expire_snapshots` retention floor (`retention_threshold` minimum 7-day enforcement / how to override `iceberg.expire-snapshots-min-retention`) or `remove_orphan_files` ordering with rollback.
- **Q2**: an analytical-pattern angle — running totals (`SUM(x) OVER (PARTITION BY ... ORDER BY ... ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)`) or a percentile/rank pattern. AVOID gaps-and-islands synthesis-ceiling per `feedback_synthesis_ceiling_stop_churning`.
- **Q3**: dbt OR ops — exercise the iter1191 dbt-contract two-phase soft-watch ("does dbt contract enforcement need a live Trino connection / can CI validate without warehouse?"), OR re-probe the NEW iter1192 delete+insert-on-Hive watch ("on plain Hive non-ACID, what's the right incremental strategy for a fact table that needs idempotent upserts?").
- **Q4**: Oracle-habit dialect function not recently tested — `NVL2(expr, val_if_not_null, val_if_null)` → `IF(expr IS NOT NULL, ..., ...)` / `COALESCE`-CASE, or `DECODE(expr, val1, ret1, val2, ret2, default)` → `CASE`.

All required topics PASSED. Overall iteration STRONG-PASS adjacent but the Q3 LIGHT FIX-A pulls the iter average to 4.625 — solidly above 3.5 threshold, comfortably below STRONG PASS (≥ 4.9).

---

## Sources (verification)

- [trinodb/trino PR #25378 — Optimize manifests per top-level partition in Iceberg](https://github.com/trinodb/trino/pull/25378) — confirms `optimize_manifests` landed in Trino 470, NOT 467
- [Trino Release 470 (5 Feb 2025) notes](https://trino.io/docs/current/release/release-470.html) — `optimize_manifests` listed under Iceberg connector changes
- [Trino Release 467 (6 Dec 2024) notes](https://trino.io/docs/current/release/release-467.html) — does NOT list `optimize_manifests`
- [trinodb/trino#14821 — Add the functionality of the Iceberg rewrite_manifests procedure](https://github.com/trinodb/trino/issues/14821) — historical feature request that landed as 470's `optimize_manifests`
- [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) — Iceberg connector procedures, MERGE INTO support on Iceberg tables
- [trino.io/docs/467/connector/hive.html](https://trino.io/docs/467/connector/hive.html) — "MERGE is only supported for ACID tables"; "DELETE applied to non-transactional tables is only supported if the table is partitioned and the WHERE clause matches entire partitions"; row-by-row deletion only on transactional ORC tables
- [docs.getdbt.com/reference/resource-configs/trino-configs](https://docs.getdbt.com/reference/resource-configs/trino-configs) — dbt-trino incremental strategies (append default / delete+insert / merge); "some Trino connectors don't support MERGE or have limited support"; does NOT itself enumerate the delete+insert Hive-non-ACID gap (the connector-level gate is the load-bearing fact)
- [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html) — FILTER (WHERE ...) clause on aggregate functions
- [trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html) — `strpos(string, substring)` 1-indexed, returns 0 if not found; `position(substring IN string)` SQL-standard form; `substr(string, start, length)`
