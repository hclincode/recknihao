# Iter1196 Judge Feedback

**Overall: 4.65625 / 5.0 — PASS + Q3 WATCH CLOSES + LIGHT FIX-A (small dialect cleanup to r21).** The iter1192 `delete+insert-on-non-ACID-Hive defang` watch CLOSES on first re-probe — responder correctly landed "delete+insert fails the same way MERGE does on non-ACID Hive (both gate on row-level DELETE which isn't supported on non-transactional tables, only whole-partition DELETE works)." Workarounds (append+dedup view / insert_overwrite partition-replace / migrate-to-Iceberg) all sound and production-stack-aligned. Q1 + Q2 + Q4 are clean (Q2 + Q4 pin-perfect 5.0; Q1 4.375 with a minor recall ceiling on `$partitions`). **SECONDARY SLIP in Q3**: responder wrote the post-migrate format-version bump as `ALTER TABLE ... SET TBLPROPERTIES ('format-version' = '2')` — that's Spark/Hive syntax. Trino 467 dialect is `ALTER TABLE ... SET PROPERTIES format_version = 2` (no TBL prefix, underscored property, unquoted value). The slip is **RESOURCE-SOURCED** from r21 §131-141 + §151 which still teaches the Spark-only form for a Trino-native migrate workflow. LIGHT FIX-A: add Trino-dialect form alongside Spark in r21 §131. iter1194 dbt-contract-live-connection watch + iter1195 optimize-clears-position-deletes watch NOT exercised this iter — carry forward.

---

## Q1 — Iceberg metadata tables for inspecting file layout per partition

**Score: 4.5 / 4.5 / 4.5 / 4.0 = 4.375 (PASS)**

### What the responder said:
- Iceberg `$` metadata tables — `"table$history"` (snapshots), `"table$files"` exposing `file_path`, `file_size_in_bytes`, `record_count`, `partition`; `GROUP BY partition` for per-partition file_count / row_count / total_bytes.
- Load-bearing quoting rule: the whole token goes in ONE double-quoted pair `iceberg.schema."table$files"` (NOT `iceberg.schema.table."$files"`).
- Suggests `ALTER TABLE ... EXECUTE optimize` to compact tiny files (leftover pre-partition files).

### Independent verification:
1. **`$files` columns including `partition`** — VERIFIED. Per [trinodb/trino PR #24102](https://github.com/trinodb/trino/pull/24102) "Add spec_id, partition, sort_order_id, readable_metrics columns to Iceberg $files table" (merged in v465, present in 467). Full schema: `content, file_path, file_format, record_count, file_size_in_bytes, column_sizes, value_counts, null_value_counts, nan_value_counts, lower_bounds, upper_bounds, key_metadata, split_offsets, equality_ids, sort_order_id, readable_metrics, partition, spec_id`.
2. **Quoting rule** — VERIFIED at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html): "use the table name and the metadata table name separated by a `$`" with examples `"test_table$properties"` and `example.testdb."customer_orders$snapshots"`. The whole `table$kind` token sits inside one double-quoted pair. Responder's load-bearing quoting clarification is exactly right and is the kind of small but easy-to-fail point the engineer needed.
3. **`$history` schema** — `made_current_at, snapshot_id, parent_id, is_current_ancestor`. Responder's parenthetical "(snapshots)" mild conflation with `$snapshots` (separate metadata table with `committed_at, snapshot_id, parent_id, operation, manifest_list, summary`) — not load-bearing because both surface snapshot ancestry.
4. **EXECUTE optimize for tiny files** — VERIFIED, the documented compaction lever.

### Minor recall ceiling (-0.5 Compl):
**`$partitions` metadata table not mentioned** — yet it's literally the most direct route to the engineer's question. Per [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html), `$partitions` exposes `partition, record_count, file_count, total_size, data` — i.e. file_count and total_size per partition with no GROUP BY needed. Responder's `$files GROUP BY partition` is equivalent but does extra work. Not a defect (the engineer arrives at the same answer); no resource fix needed (per `feedback_responder_broken_secondary_alternative.md` adjacent family — secondary-form under-routing, not broken).

### Rubric routing:
"Iceberg partition design for SaaS" row (4.4598/55) — question is about diagnosing why a bucket-partition spec change didn't help pruning, fits the partition-design family (companion to iter1193 partition-evolution Q1).

---

## Q2 — Trino ROLLUP / GROUPING SETS + GROUPING() bitmask

**Score: 5.0 / 5.0 / 5.0 / 5.0 = 5.0 (STRONG PASS, pin-perfect)**

### What the responder said:
- Trino supports `ROLLUP`, `CUBE`, `GROUPING SETS`. `GROUP BY ROLLUP(region, product_line)`.
- `GROUPING(region, product_line)` returns a bigint bitmask, rightmost-column = LSB:
  - `0` (`00`) = detail row (both columns present)
  - `1` (`01`) = region subtotal (product_line rolled up / NULL)
  - `3` (`11`) = grand total (both NULL)
- `CASE GROUPING(region, product_line) WHEN 0 THEN 'Detail' WHEN 1 THEN 'Region Subtotal' WHEN 3 THEN 'Grand Total' END`.
- Explicit note: `ROLLUP(region, product_line)` produces NO value `2` — that grouping-set `(product_line)` row is generated by `CUBE` not `ROLLUP`.

### Independent verification at [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html):
1. ROLLUP / CUBE / GROUPING SETS support — verified verbatim in the GROUP BY grammar.
2. GROUPING bitmask semantics — verified verbatim: "bits are assigned to the argument columns with the rightmost column being the least significant bit. For a given grouping, a bit is set to 0 if the corresponding column is included in the grouping and to 1 otherwise." Docs example `GROUPING(origin_state, origin_zip, destination_state)`: all-three-present = `000` = 0; only `origin_state` present = `011` = 3 (sense matches: `origin_state` IS the only one present, so the other two = 1s).
3. `ROLLUP(region, product_line)` outputs — verified: `(region, product_line)`, `(region)`, `()` (detail + region subtotal + grand total). The `(product_line)` row (margin only by product_line, GROUPING = `10` = 2) is CUBE-only. Responder's defang of value `2` is correct and prevents engineer confusion when scanning bitmask values.
4. Column-names-only constraint — verified verbatim: "Complex grouping operations do not support grouping on expressions composed of input columns. **Only column names are allowed.**" Matches pinned `reference_trino_complex_grouping_column_names_only.md`.

### Rubric routing:
"SQL query best practices for OLAP" row (4.5811/268) — SQL-construct dialect question family (matches iter1186 Q3 HAVING / iter1185 Q3 split_to_map routing).

---

## Q3 — WATCH RE-PROBE: dbt incremental_strategy='delete+insert' on non-transactional Hive

**Score: 4.5 / 4.5 / 4.0 / 4.0 = 4.25 (PASS — WATCH CLOSES on primary axis; secondary slip resource-sourced → LIGHT FIX-A)**

### What the responder said (primary axis — CORRECT):
- "Don't use delete+insert on non-transactional Hive — it fails the same way MERGE fails."
- "Both merge and delete+insert require the connector to support row-level DELETE; on the Trino 467 Hive connector BOTH are gated on table transactionality."
- "Non-ACID Hive rejects MERGE INTO and row-level DELETE FROM hive_table WHERE account_id=... (DELETE only supported for entire partitions on non-transactional tables)."
- Workarounds: (1) append + downstream `ROW_NUMBER` dedup view; (2) `insert_overwrite` whole partitions on a partitioned Hive table; (3) RECOMMENDED migrate in-place via `CALL iceberg.system.migrate(schema_name=>..,table_name=>..)` THEN bump format-version, then dbt merge on `iceberg.*` with `unique_key=['account_id']`.

### What the responder said (secondary slip — DIALECT-WRONG):
- Post-migrate bump written as `ALTER TABLE ... SET TBLPROPERTIES ('format-version' = '2')` — that's **Spark/Hive syntax**.

### Independent verification:

1. **Primary watch axis VERIFIED CORRECT.** At [trino.io/docs/467/connector/hive.html](https://trino.io/docs/467/connector/hive.html) verbatim:
   - "DELETE applied to non-transactional tables is only supported if the table is partitioned and the WHERE clause matches entire partitions."
   - "MERGE is only supported for ACID tables."
   - "Transactional Hive tables with ORC format support row-by-row deletion, in which the WHERE clause may match arbitrary sets of rows."
   
   dbt's `delete+insert` strategy emits `DELETE FROM target WHERE (unique_key) IN (SELECT unique_key FROM tmp)` (verified per [docs.getdbt.com/docs/build/incremental-strategy](https://docs.getdbt.com/docs/build/incremental-strategy) + dbt-adapters source). That is a **row-level DELETE keyed on account_id**, NOT a whole-partition DELETE — so on plain non-transactional Hive it fails the same `row-level delete not supported` error as MERGE. Responder's framing "BOTH gated on row-level DELETE support which isn't there on non-ACID Hive" is exactly right.

2. **Workarounds are sound.** (a) append + dedup view = the documented zero-mutation pattern; (b) `insert_overwrite` partition-replace works ONLY when the unique key aligns with the partition grain (engineer needs to know this caveat — responder hedged with "on a partitioned Hive table" which is the right gating); (c) migrate-to-Iceberg via `CALL iceberg.system.migrate(...)` is Trino-native per `reference_trino_iceberg_migrate_native.md` (iter1168 corrected resource).

3. **WATCH CLOSES on first re-probe.** `iter1192 r27 §3.2 delete+insert-on-non-ACID-Hive defang` watch — primary "delete+insert == merge gate on non-ACID Hive" framing landed cleanly. (11th consecutive watch closure in the 1st-re-probe-CLOSE pattern.)

4. **Secondary dialect slip — RESOURCE-SOURCED.** Verified at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html): Trino 467 form is `ALTER TABLE table_name SET PROPERTIES format_version = 2` (underscored property name, unquoted bigint value, **SET PROPERTIES** not SET TBLPROPERTIES). Spark/Hive form `SET TBLPROPERTIES ('format-version' = '2')` parse-errors against the Trino SQL surface. Grep evidence the slip is sourced from `resources/21-hive-metastore-iceberg.md`:
   - **L131-136**: code block reads `ALTER TABLE iceberg.analytics.events SET TBLPROPERTIES ('format-version' = '2');` (Spark SQL comment line, but recipe paragraph below recommends running it after a Trino-native migrate)
   - **L139**: prose "upgrade it to v2 with the `ALTER TABLE ... SET TBLPROPERTIES ('format-version'='2')` above"
   - **L151**: summary table row "No delete files until you `ALTER TABLE ... SET TBLPROPERTIES ('format-version' = '2')`."
   
   Three places, all teaching the Spark form. The responder lifted from r21 §131-141 verbatim. Engineer who copies through Trino client will hit a parse error.

5. **Open question: does iceberg.system.migrate already produce a v2 table?** Per r21 §141 itself: "Hive-MIGRATED tables (via the `migrate()` procedure — whether run from Trino or Spark) default to Iceberg format version 1, which does not support delete files." So the bump IS needed for the migrate path — the recipe is operationally required, only the syntax is dialect-wrong. New tables created with Trino `CREATE TABLE` already default to v2 (verified at iceberg.html — `format_version = 2` is the connector default since 419 / before 467).

### LIGHT FIX-A spec:
Reconcile-in-place at r21 §131-141 (per `feedback_reconcile_dont_append.md` — don't append a Trino card, FIX the misleading Spark-only framing). Specifically:
- L131-136 code block: add Trino-dialect variant alongside (or as primary, since the question's workflow is Trino-native migrate). Suggested form:
  ```sql
  -- Trino 467 dialect (run from Trino client / dbt-trino):
  ALTER TABLE iceberg.analytics.events SET PROPERTIES format_version = 2;
  
  -- Spark SQL dialect (run from Spark SQL):
  ALTER TABLE iceberg.analytics.events SET TBLPROPERTIES ('format-version' = '2');
  ```
- L139 prose: parallel "Trino: `... SET PROPERTIES format_version = 2`; Spark: `... SET TBLPROPERTIES ('format-version'='2')`"
- L151 summary row: same parallel form.
- Keyword anchors: `Trino set properties format_version`, `format_version=2 Trino dialect`, `post-migrate format version bump Trino`, `iceberg.system.migrate then format_version`.
- DO-NOT-WRITE inline-defang (per `feedback_defang_donotwrite_snippets.md`): "Running `ALTER TABLE ... SET TBLPROPERTIES (...)` from a Trino client — PARSE ERROR; that's Spark dialect. Trino uses `SET PROPERTIES` (no TBL prefix, underscored property name, unquoted value)."
- Cross-ref: link from r27 §3.2 (delete+insert defang) → r21 §131 (post-migrate format bump).

### Resource attribution:
Responder lifted from `resources/21-hive-metastore-iceberg.md` §131-141. NOT a pure responder slip — source-anchored to a Spark-only recipe that's also recommended for a Trino-native migrate workflow.

### Rubric routing:
"Improving complex SQL performance on Trino with dbt" row (4.5542/34) — matches iter1192 Q3 parent watch routing (dbt incremental-strategy on non-Iceberg connector matrix).

---

## Q4 — Trino NVL2 / NVL / IF / COALESCE (Oracle dialect port)

**Score: 5.0 / 5.0 / 5.0 / 5.0 = 5.0 (STRONG PASS, pin-perfect)**

### What the responder said:
- "Trino has NO NVL2."
- Use `CASE WHEN x IS NOT NULL THEN a ELSE b END`, or shorter `IF(x IS NOT NULL, a, b)`.
- "NVL -> COALESCE(x, fallback)" — COALESCE is the Trino equivalent of Oracle's NVL.

### Independent verification at [trino.io/docs/467/functions/conditional.html](https://trino.io/docs/467/functions/conditional.html):
1. **NVL/NVL2 ABSENT** — verified, not listed in conditional functions. (No imported-prior fabrication; legitimate Oracle-only fns — matches iter1194 Q4 DECODE pattern.)
2. **`if(condition, true_value, false_value)`** — verified verbatim: "Evaluates and returns `true_value` if `condition` is true, otherwise evaluates and returns `false_value`." There is also a two-arg form `if(condition, true_value)` returning NULL if false (responder didn't mention but not load-bearing for the engineer's three-arg NVL2 question).
3. **`COALESCE(value1, value2, ...)`** — verified verbatim: "Returns the first non-null `value` in the argument list." Same semantics as Oracle NVL when called with two args; generalizes to N-ary.
4. **`IF(x IS NOT NULL, a, b)` as the shortest NVL2 equivalent** — sound; reads naturally and avoids the verbose CASE.

### What's pin-perfect about this:
- Trino-dialect-accurate (per `feedback_trino_dialect_accuracy.md`).
- Verifies absent (`NVL/NVL2`) before recommending alternative — no fabrication slip.
- Two-tier recommendation: full CASE (defensive / portable) + shorter IF (idiomatic) — engineer gets both.
- COALESCE/NVL mapping correct — most common direct port.

### Rubric routing:
"Oracle PL/SQL → dbt + Trino SQL migration" row (4.4641/156) — matches iter1194 Q4 DECODE → CASE routing (Oracle-conditional-function family).

---

## Carry-forward open watches NOT exercised this iter:
1. **iter1194 r27 §6.7C dbt-contract-live-connection FIX-A** — re-probe in 2-5 iters with framing "do contracts validate at compile time without warehouse access" / "CI has only dbt parse + dbt compile, will contracts catch type drift?"
2. **iter1195 r13 L2862 + r28 §348 optimize-clears-position-deletes RECONCILED corpus** — re-probe in 2-5 iters with framing "delete files growing on MERGE-heavy Iceberg / EXECUTE optimize alone or need Spark rewrite_position_delete_files?"

---

## Summary score breakdown

| Q | Acc | Clar | App | Compl | Avg | Topic row updated |
|---|---|---|---|---|---|---|
| Q1 | 4.5 | 4.5 | 4.5 | 4.0 | **4.375** | Iceberg partition design for SaaS |
| Q2 | 5.0 | 5.0 | 5.0 | 5.0 | **5.0** | SQL query best practices for OLAP |
| Q3 (WATCH) | 4.5 | 4.5 | 4.0 | 4.0 | **4.25** | Improving complex SQL performance on Trino with dbt |
| Q4 | 5.0 | 5.0 | 5.0 | 5.0 | **5.0** | Oracle PL/SQL → dbt + Trino migration |

**Iteration overall: (4.375 + 5.0 + 4.25 + 5.0) / 4 = 4.65625 / 5.0 — PASS + WATCH CLOSES + LIGHT FIX-A (r21 §131-141 + §151 Trino-dialect form for format-version bump).**

All required rubric topics remain PASSED; no margin regressions; FIX-A is purely additive-corrective on r21 (an iter1168-touched file, narrowly scoped to the format-version bump syntax — does not disturb the migrate-is-native canonical).
