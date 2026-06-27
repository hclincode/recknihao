# Iter1191 Judge Feedback

**Overall: 4.906 / 5.0 — STRONG PASS NO-OP.** No FIX-A. iter1190 watch on dbt merge connector matrix is NOT exercised this iter; carry forward unchanged.

---

## Q1 — Iceberg rollback to pre-job snapshot (Trino 467 CALL form + $history discovery)

**Score: 5.0 / 5.0 / 5.0 / 5.0 = 5.0**

Pin-perfect maintenance/Iceberg-time-travel canonical reach. All load-bearing facts verified:

1. **`$history` metadata table columns** — VERIFIED at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) `$history` table exposes `made_current_at`, `snapshot_id`, `parent_id`, `is_current_ancestor`. Responder picked the RIGHT metadata table — `$snapshots` carries `committed_at / snapshot_id / parent_id / operation / manifest_list / summary` but does NOT carry `is_current_ancestor`, so `$history` is the correct choice for "find the snapshot just before the bad job AND confirm it's on the current lineage." Routing nuance correctly handled.

2. **`is_current_ancestor` semantics** — TRUE means the snapshot is an ancestor of the CURRENT pinned snapshot (still on the live lineage); FALSE means it was branched/orphaned by a prior rollback. Correctly described as "tells if it's on current lineage."

3. **CALL form for Trino 467** — `CALL iceberg.system.rollback_to_snapshot('analytics', 'events', 4823511203987654321)` is the CORRECT 467 form. VERIFIED at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) verbatim example `CALL example.system.rollback_to_snapshot('testdb', 'customer_orders', 8954597067493422955)`. Three positional args (schema, table, snapshot_id-as-BIGINT). The `ALTER TABLE ... EXECUTE rollback_to_snapshot(snapshot_id)` form is 469+ ONLY — responder correctly used CALL, not EXECUTE. Pinned-reference correctly applied (`reference_trino_rollback_snapshot_form.md`).

4. **Metadata-only** — VERIFIED. Iceberg rollback updates the HMS `metadata_location` pointer to a previous metadata.json snapshot; no data files are rewritten or moved. "Just moves the current-snapshot pointer back, no data rewrite, bad files remain on MinIO but unseen" is exactly right — the bad-job files remain referenced by the rolled-back-from snapshot's metadata chain until `expire_snapshots` is called.

5. **Operationally complete** — responder gives engineer a runnable two-step workflow: (a) browse `$history` ORDER BY made_current_at DESC + filter `is_current_ancestor=true`, (b) run the CALL with the pre-job snapshot_id. No bail.

Cites r17. Clean canonical reach. Naturally chains with iter1188+1189 expire-vs-orphan canonical (rolling back doesn't reclaim the bad files until expire_snapshots runs).

---

## Q2 — CDC dedup to one-row-per-user latest via ROW_NUMBER

**Score: 5.0 / 5.0 / 5.0 / 5.0 = 5.0**

Pin-perfect latest-row-per-key dedup canonical. All facts verified:

1. **`ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY updated_at DESC) AS rn` + `WHERE rn = 1`** — confirmed at [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html): "Returns a unique, sequential number for each row, starting with one, according to the ordering of rows within the window partition." Standard Trino 467 window function. Single-pass over the 50M-row table (one partitioned-sort scan), no self-join overhead.

2. **`max_by(payload_col, updated_at)`** — valid Trino aggregate (verified prior at functions/aggregate.html), correctly framed as a SINGLE-COLUMN alternative when only one field from the latest row is needed. Responder correctly disambiguated: ROW_NUMBER + WHERE rn=1 for "all columns of latest row per user_id", `max_by` for "only one column from latest row." Selection rule sound.

3. **Self-join + MAX-GROUP-BY performance aside** — reasonable in general (self-join reads the same 50M-row table twice, ROW_NUMBER reads once + sorts in one pass). Slightly soft phrasing but not over-warning per `feedback_responder_overwarning_folklore` — ROW_NUMBER IS the idiomatic single-pass choice on this row count, so the "heavier" framing on self-join is accurate. No over-warning slip.

No broken secondary alternative per `feedback_responder_broken_secondary_alternative` family.

---

## Q3 — dbt model contracts: do they FAIL the build, and dbt-trino specifics

**Score: 4.0 / 5.0 / 5.0 / 4.5 = 4.625**

Core load-bearing answer correct, but ONE phrasing imprecision worth flagging.

### Verified correct:

1. **Contracts ACTIVELY FAIL the build (not just docs)** — VERIFIED at [docs.getdbt.com/reference/resource-configs/contract](https://docs.getdbt.com/reference/resource-configs/contract) "before dbt has materialized it as a table in the database, you will see this error" + `Compilation Error in model dim_customers / This model has an enforced contract that failed` + mismatch table showing column_name / definition_type / contract_type / mismatch_reason. Build halts; downstream models skipped. Correct.

2. **YAML config** — `config: contract: enforced: true` + `columns:` with `name + data_type + constraints` — correct shape, matches docs.

3. **dbt-trino constraint matrix** — VERIFIED at [docs.getdbt.com/reference/resource-configs/trino-configs](https://docs.getdbt.com/reference/resource-configs/trino-configs) verbatim: "The `dbt-trino` adapter supports model contracts. Currently, only constraints with `type` as `not_null` are supported." Responder's framing matches: only `not_null` is RUNTIME-enforced (Iceberg writes column as NOT NULL DDL, INSERT of NULL fails at write); `primary_key / unique / foreign_key` definable-but-not-enforced — pair with `dbt test` unique/not_null/relationships for runtime validation. Correct.

### Imprecision (-1.0 Tech, -0.5 Compl):

**"Build-time / preflight check before Trino is hit"** is mildly inaccurate. Per [docs.getdbt.com/docs/mesh/govern/model-contracts](https://docs.getdbt.com/docs/mesh/govern/model-contracts) dbt enforces contracts via TWO mechanisms:

> (1) dbt will run a "preflight" check to ensure that the model's query will return a set of columns with names and data types matching the ones you have defined.
>
> (2) dbt will include the column names, data types, and constraints in the DDL statements it submits to the data platform, which will be enforced while building or updating the model's table.

The preflight check in practice issues an introspection query (e.g., `SELECT * FROM (compiled_model_sql) WHERE 1=0`) AGAINST the warehouse to get back the actual column types — meaning Trino IS hit (just doesn't materialize anything). "Before Trino is hit" collapses this into a pure-local-compile claim which is technically wrong. The engineer's actionable outcome (build fails fast, no table materialized, downstream skipped) is still correct — load-bearing fail-fast behavior is right — but the mechanism framing is imprecise.

**NOT a resource fix.** This is a phrasing slip not source-anchored in any resource. Recall ceiling — no FIX-A. If recurs in structurally different framing, consider a one-line clarifier in the dbt-contracts canonical. **SOFT WATCH:** re-probe contract mechanics in 5-10 iters with framing like "does dbt need a live Trino connection to enforce contracts" or "can contracts be validated in CI without warehouse access" to test whether the responder lands the two-phase (preflight introspection-query + DDL-time enforcement) distinction.

---

## Q4 — Oracle LISTAGG → Trino direct equivalent

**Score: 5.0 / 5.0 / 5.0 / 5.0 = 5.0**

Pin-perfect Oracle-to-Trino direct port canonical. All load-bearing facts verified at [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html):

1. **`LISTAGG(expr [, sep] [ON OVERFLOW ...]) WITHIN GROUP (ORDER BY ...) [FILTER (WHERE ...)]`** — exact 467 syntax. Correctly framed as a DIRECT Oracle-equivalent (Oracle 11g/12c LISTAGG WITHIN GROUP shape is structurally identical). Pinned `reference_trino_listagg_native.md` correctly applied.

2. **`ON OVERFLOW TRUNCATE '...' WITH COUNT`** — VERIFIED. Docs example `listagg(value, ',' ON OVERFLOW TRUNCATE '.....' WITH COUNT) WITHIN GROUP (ORDER BY value)`. Default truncation filler '...', optional WITH/WITHOUT COUNT for omitted-value count. Default-on-overflow behavior is to THROW; ON OVERFLOW TRUNCATE switches to truncate-with-filler.

3. **1 MiB / 1,048,576 bytes per-result byte limit** — VERIFIED verbatim in docs. Without ON OVERFLOW clause, an aggregated string > 1 MiB ERRORS. Correctly named with the size figure.

4. **NULL skipping** — VERIFIED per Trino aggregate-function general rule "all of these aggregate functions ignore null values and return null for no input rows or when all values are null." Matches Oracle LISTAGG's NULL-skip behavior — drop-in semantic equivalence.

5. **No window/OVER form** — VERIFIED verbatim in docs: "The current implementation of `listagg` function does not support window frames." Responder correctly named the workaround (ROW_NUMBER subquery + then aggregate). Correct framing.

6. **`array_join(array_agg(... ORDER BY ...), ', ')` alternative** — valid Trino 467 fallback; useful when caller needs window-frame semantics (which listagg can't do), needs custom NULL handling, or wants to deduplicate via `array_agg(DISTINCT ...)` before joining. Correctly framed as supplementary, not primary.

Clean direct-port answer for an Oracle engineer. Cites r27 (Oracle-migration dialect-spillover guardrail) + r23 (string-agg canonical).

---

## Topic routing + score updates

| Q | Topic | Score | Prior | New |
|---|---|---|---|---|
| Q1 | Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup (rollback canonical) | 5.0 | 4.4533/205 | 4.4560/206 |
| Q2 | Analytical query patterns on Iceberg+Trino: funnels, cohorts, time-series SQL (latest-row-per-key dedup canonical) | 5.0 | 4.5076/139 | 4.5111/140 |
| Q3 | dbt model contracts | 4.625 | 4.4808/8 | 4.4968/9 |
| Q4 | Oracle PL/SQL → dbt + Trino SQL migration (LISTAGG direct port) | 5.0 | 4.4631/150 | 4.4667/151 |

All four touched topics remain comfortably PASSED. dbt model contracts row gets its 9th datapoint and lifts despite the Q3 imprecision.

---

## Open watches

1. **iter1190 soft-watch — dbt merge connector matrix (Iceberg native vs Hive limited).** NOT exercised this iter (no merge connector-matrix question). Continue carrying forward; re-probe in next 5-8 iters with framing like "we're on hive.* catalog and getting merge unsupported errors — is this an adapter limit or a connector limit?" to test whether responder lands the Iceberg-native-vs-Hive-limited distinction without over-absolute framing.

2. **iter1191 NEW soft-watch — dbt model contract enforcement mechanism (preflight introspection-query vs pure-local-compile).** Q3 phrasing "before Trino is hit" collapses dbt's two-phase enforcement (preflight introspection-query against warehouse + DDL-time constraints) into a misleading pure-offline-compile claim. Load-bearing fail-fast outcome correct; mechanism framing imprecise. NO FIX-A. Re-probe in 5-10 iters with framing like "do contracts need a live Trino connection" or "can contracts be validated in CI before deploy" to test whether the two-phase distinction lands. If recurs, consider one-line clarifier in the contracts canonical (e.g., "preflight introspects column types via a `WHERE 1=0` query — Trino IS hit but no data is materialized").

---

## Next iteration suggestion (iter1192)

BREADTH continuation. Avoid re-probing today's exact angles. Suggested rotation:

- **Q1**: an Iceberg maintenance angle not recently hit — e.g., snapshot retention floor (`retention_threshold` minimum 7 days enforcement / how to override `iceberg.expire_snapshots.min-retention`), or manifest rewrite (`rewrite_manifests` Spark-only on Trino 467, alternatives).
- **Q2**: an analytical-pattern angle — e.g., conditional aggregation with FILTER clause, gap-detection / first-of-streak pattern (different from gaps-and-islands ceiling per `feedback_synthesis_ceiling_stop_churning`).
- **Q3**: dbt OR best-practices — try the open iter1190 soft-watch on **merge connector matrix** with explicit Hive-vs-Iceberg framing.
- **Q4**: Oracle-habit dialect function not recently tested — e.g., `INSTR` → `strpos` / `position(... IN ...)`, or `NVL2(expr, val_if_not_null, val_if_null)` → `IF(expr IS NOT NULL, ..., ...)` / `COALESCE`-CASE.

All required topics PASSED.

## Sources (verification)

- [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) — rollback_to_snapshot signature, `$history` columns
- [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html) — listagg syntax + ON OVERFLOW + 1 MiB limit + no-window-frame note
- [trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html) — row_number()
- [docs.getdbt.com/reference/resource-configs/contract](https://docs.getdbt.com/reference/resource-configs/contract) — contract failure mode + error message shape
- [docs.getdbt.com/docs/mesh/govern/model-contracts](https://docs.getdbt.com/docs/mesh/govern/model-contracts) — two-phase enforcement (preflight + DDL)
- [docs.getdbt.com/reference/resource-configs/trino-configs](https://docs.getdbt.com/reference/resource-configs/trino-configs) — dbt-trino: only `not_null` constraint supported
