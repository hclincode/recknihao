# Iter1198 Judge Feedback

**Overall: 4.969 / 5.0 — STRONG PASS NO-OP. Q3 WATCH CLOSES.** All four answers verified against trino.io/docs/467 + docs.getdbt.com primary sources; zero defects. Q1 Iceberg time-travel `FOR VERSION AS OF` / `FOR TIMESTAMP AS OF` + `$history` columns + 7d min-retention pin-perfect; Q2 LAG MoM growth pin-perfect; **Q3 (WATCH for `iter1194 r27 §6.7C dbt-contract-live-connection FIX-A`) lands the two-phase enforcement model correctly — `dbt parse`/`dbt compile` with NO Trino connection do NOT enforce contracts; preflight introspection query requires live warehouse; teammate is wrong; CI fix `dbt build`/`dbt run` requires network access to Trino. WATCH CLOSES** (FIX-A reached on 1st re-probe). Q4 Oracle `REGEXP_SUBSTR` → Trino `regexp_extract` pin-perfect including 3-arg group form + JONI/Java regex flavor caveat. No imported-prior slips, no broken-secondary-alternative slips, no over-warning. Carry-forward watches NOT exercised: **PRIORITY iter1197 r17 position-delete-optimize findable-summary reconcile** (high recurrence risk — re-probe next 2-4 iters); iter1196 r21 format_version SET PROPERTIES Trino dialect; soft iter1197 localtimestamp SYSDATE direct mapping; soft iter1197 generate_schema_name macro surface.

---

## Q1 — Trino Iceberg time-travel for as-of-Tuesday-9am query

**Score: 5 / 5 / 5 / 5 = 5.0**

### What the responder said:
- YES Trino 467 native time-travel, NOT Spark-only.
- `SELECT * FROM iceberg.analytics.tbl FOR VERSION AS OF <snapshot_id bigint>` OR `FOR TIMESTAMP AS OF TIMESTAMP '2026-05-20 09:00:00'`.
- Find snapshot via `"tbl$history"` (columns: `made_current_at`, `snapshot_id`, `parent_id`, `is_current_ancestor`).
- Caveat: old snapshots available ~7 days per `iceberg.expire-snapshots.min-retention` until `expire_snapshots` removes them.

### Verification (primary source):
[trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) verbatim:
- "Trino supports two methods of historical data querying": `FOR VERSION AS OF <snapshot_id>` + `FOR TIMESTAMP AS OF TIMESTAMP '...'` — examples include `FOR VERSION AS OF 8954597067493422955` and `FOR TIMESTAMP AS OF TIMESTAMP '2022-03-23 09:59:29.803 Europe/Vienna'`.
- `$history` table columns: `made_current_at` (TIMESTAMP with tz), `snapshot_id` (BIGINT), `parent_id` (BIGINT), `is_current_ancestor` (BOOLEAN) — exact match.
- `iceberg.expire-snapshots.min-retention` default `"7d"` — exact match.

### Verdict:
Pin-perfect Iceberg time-travel canonical for an Iceberg-native query engine. Engineer's Tuesday-9am ask is exactly the `FOR TIMESTAMP AS OF` use case; the responder also gave the discovery path via `$history` so the engineer can pick the right snapshot_id if the timestamp form has rounding concerns. The 7-day retention caveat is the load-bearing operational warning ("hurry — the snapshot may already be gone if it's been >7d AND someone ran expire_snapshots"). No defect.

---

## Q2 — Month-over-month growth without a self-join

**Score: 5 / 5 / 5 / 4.5 = 4.875**

### What the responder said:
- `LAG(revenue) OVER (PARTITION BY plan_tier ORDER BY month) AS prev_month_revenue`.
- `pct_change = ROUND(100.0 * (revenue - LAG(revenue) OVER (PARTITION BY plan_tier ORDER BY month)) / LAG(revenue) OVER (PARTITION BY plan_tier ORDER BY month), 2)`.
- Single-pass, no self-join. LAG returns NULL for first month per partition (COALESCE if needed).

### Verification:
- `LAG(value)` is a standard SQL window function in Trino 467 ([trino.io/docs/467/functions/window.html](https://trino.io/docs/467/functions/window.html)) — `LAG(value [, offset [, default]]) OVER (...)` with default offset = 1.
- `PARTITION BY plan_tier ORDER BY month` is the textbook MoM partition framing (one growth chain per tier, chronologically ordered).
- Single hash-partition + sort, no self-join — correct.

### Minor completeness shave (-0.5 Compl):
Division-by-zero guard for `prev_month_revenue = 0` not mentioned. Per pinned `reference_trino_division_by_zero.md`: DECIMAL `/` 0 throws DIVISION_BY_ZERO; DOUBLE `/` 0 returns Infinity. For a `revenue` column likely typed DECIMAL/INT, a prev=0 month would throw at query time. Standard guard is `NULLIF(LAG(revenue) OVER (...), 0)` in the denominator. Engineer would discover this on first $0 month. Not load-bearing for the question as posed (engineer asked for "cleaner without self-join", LAG nails that), but a clean 5.0 would have one-lined the NULLIF.

### Verdict:
Pin-perfect window-function MoM canonical. Recall-ceiling shave, NO resource fix.

---

## Q3 (WATCH) — dbt model contract enforcement requires a live warehouse connection

**Score: 5 / 5 / 5 / 5 = 5.0**

### What the responder said:
- **"NO. dbt parse and dbt compile with NO warehouse connection do NOT enforce contracts. Contract enforcement REQUIRES a live Trino connection."**
- Sequence: dbt compiles SQL → issues introspection query to Trino (empty-result `SELECT ... WHERE 1=0`) to learn actual result column names + types → compares to YAML → errors + refuses to materialize on mismatch. Step 2 needs live Trino.
- CI fix: replace `dbt parse`/`dbt compile` with `dbt build --select <model>` or `dbt run --select <model>` (requires live Trino); CI runner MUST have network access to Trino.

### Verification (primary source):
[docs.getdbt.com/docs/collaborate/govern/model-contracts](https://docs.getdbt.com/docs/collaborate/govern/model-contracts) verbatim: *"When building a model with a defined contract, dbt will do two things differently: (1) dbt will run a 'preflight' check to ensure that the model's query will return a set of columns with names and data types matching the ones you have defined. (2) dbt will include the column names, data types, and constraints in the DDL statements it submits to the data platform, which will be enforced while building or updating the model's table."*

Both phases require a warehouse connection:
- Preflight introspection (`SELECT ... WHERE 1=0` against the compiled SQL) is run **against** the warehouse to type-introspect the model's output columns; cannot be done from YAML alone because the SQL's output types come from the data platform's type inference.
- DDL-time enforcement happens when dbt submits `CREATE TABLE ... (col TYPE, ...)` to the warehouse.

Neither happens during `dbt parse` (which only walks the manifest) or `dbt compile` (which only resolves Jinja + writes compiled SQL to `target/`). Confirmed via [docs.getdbt.com/reference/commands/parse](https://docs.getdbt.com/reference/commands/parse) and [docs.getdbt.com/reference/commands/compile](https://docs.getdbt.com/reference/commands/compile) — neither phase issues introspection queries against the warehouse.

### WATCH STATUS: **CLOSES**

iter1194 the responder wrongly said contracts are a pure compile-time check needing no Trino connection; iter1194 FIX-A reconciled r27 §6.7C + r28 §282 to: enforcement is build/run-time + warehouse-interactive (introspection query), so dbt parse/compile with no connection do NOT enforce. **Iter1198 responder lands all four load-bearing facts correctly on first re-probe**:
1. Teammate is **wrong** — explicit NO.
2. Mechanism — preflight introspection query against warehouse (named the empty-result `WHERE 1=0` form).
3. Comparison phase — actual vs declared types from YAML.
4. CI fix — `dbt build`/`dbt run` with network to Trino.

FIX-A reached. No `feedback_reconcile_dont_append.md` recurrence risk (unlike iter1197 r17). FIX-A direction was correct and findable.

### Verdict:
Pin-perfect. WATCH closes 1st-re-probe. Close iter1194 r27 §6.7C dbt-contract-live-connection watch — remove from open watch list.

---

## Q4 — Oracle REGEXP_SUBSTR → Trino regexp_extract

**Score: 5 / 5 / 5 / 5 = 5.0**

### What the responder said:
- Trino has NO `regexp_substr`; use `regexp_extract(string, pattern)`.
- `regexp_extract(raw_message, 'acct_[0-9]+')` returns `'acct_12345'`, NULL if no match.
- Gotchas: (1) name change; (2) Oracle POSIX vs Trino Java/JONI regex but `[0-9]`/`^`/`$` work the same so `'acct_[0-9]+'` ports as-is; (3) capture group via 3-arg `regexp_extract(s, pattern, group_num)`, default is whole match.

### Verification (primary source):
[trino.io/docs/467/functions/regexp.html](https://trino.io/docs/467/functions/regexp.html) verbatim:
- `regexp_extract(string, pattern) → varchar`: "Returns the first substring matched by the regular expression `pattern` in `string`"
- `regexp_extract(string, pattern, group) → varchar`: returns the matched capturing group.
- Documented regexp functions are limited to: `regexp_count`, `regexp_extract_all`, `regexp_extract`, `regexp_like`, `regexp_position`, `regexp_replace`, `regexp_split` — **no `regexp_substr`** (correct).
- Uses Java pattern syntax (JONI per pinned `reference_trino_regex_backslash.md`).

### Verdict:
Pin-perfect Oracle → Trino dialect port. Hits all three migration gotchas: name change, regex flavor caveat (with the correct sub-fact that basic char classes / anchors port cleanly), and 3-arg group-capture form. Direct one-for-one Oracle port. No imported-prior slip (responder correctly identified `regexp_substr` as absent), no broken-secondary-alternative slip. Cites r27.

---

## Topic checklist updates

| Topic | Q | Old avg/n | New avg/n | Δ |
|---|---|---|---|---|
| Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup | Q1 (5.0) | 4.4296/210 | 4.4323/211 | +0.0027 |
| Analytical query patterns on Iceberg+Trino: funnels, cohorts, time-series SQL | Q2 (4.875) | 4.5247/144 | 4.5271/145 | +0.0024 |
| dbt model contracts | Q3 (5.0) | 4.4968/9 | 4.5471/10 | +0.0503 |
| Oracle PL/SQL procedure → dbt + Trino SQL migration | Q4 (5.0) | 4.4671/159 | 4.4704/160 | +0.0033 |

All topics remain comfortably PASSED with healthy margins.

---

## Open watches after iter1198

- **CLOSED**: iter1194 r27 §6.7C dbt-contract-live-connection (Q3 1st-re-probe close, all four facts land).
- **PRIORITY OPEN — iter1197 r17 position-delete-optimize findable-summary reconcile** (NOT exercised this iter; high recurrence risk after iter1195 `feedback_reconcile_dont_append` re-instance; re-probe within 2-4 iters with framing like "MoR position-deletes accumulated, Trino-only shop fix or need Spark?" / "EXECUTE optimize on already-large data files seems to skip them").
- **OPEN** iter1196 r21 format_version SET PROPERTIES Trino dialect (NOT exercised; re-probe in 3-6 iters with framing like "migrated table via Trino but ALTER TABLE SET TBLPROPERTIES gets parse error / what's the Trino form").
- **SOFT OPEN** iter1197 localtimestamp Oracle-SYSDATE direct mapping (NOT exercised; re-probe in 4-7 iters with explicit "current_timestamp returns tz, give me the no-tz form" framing).
- **SOFT OPEN** iter1197 generate_schema_name macro surface-area (NOT exercised; re-probe in 4-7 iters with explicit "use dbt macros to control schema" framing).

## Next iter recommendations

- **Highest priority**: probe the iter1197 r17 position-delete-optimize findable-summary reconcile within 2-4 iters. The reconcile spans 4 resources × 10+ locations; any un-touched rendered bullet / footnote / aside could still re-attract under a Trino-only + position-delete keyword path. Suggested framings: "MoR position-deletes accumulated on a Trino-only shop, our data files are already 200MB+, will EXECUTE optimize touch them or do we need Spark?" / "delete-file compaction without Spark — possible on Trino 467?".
- Then iter1196 r21 format_version Trino dialect (parse-error trap a copy-through engineer hits).
- BREADTH otherwise; no resource-defect fires this iter.
