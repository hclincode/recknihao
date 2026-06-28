# Iteration 1240 — Judge Feedback

## Verdict

**Overall: 4.5625 — PASS, LIGHT FIX-A WARRANTED (r27 §4.4C 2-arg truncate fabrication).** Per-Q scores: Q1=4.75, Q2=5.0, Q3=4.875, Q4=3.625. Average (4.75+5.0+4.875+3.625)/4 = 18.25/4 = 4.5625. Q1/Q2/Q3 all clean (4.75 / 5.0 / 4.875). **Q4 LOAD-BEARING FAIL → 2.5 Accuracy**: the responder's CANONICAL `truncate(revenue, 2)` claim is a **FABRICATION** — Trino 467 does **NOT** have a 2-arg `truncate(x, d)` form. Engineer copying the canonical hits `line 1:8: Unexpected parameters (decimal, integer) for function truncate` parse error. The two backup forms (`truncate(revenue*100)/100` and `truncate(revenue*power(10,2))/power(10,2)`) ARE correct and recover the engineer if they read past the canonical. **GREP EVIDENCE — this is a RESOURCE DEFECT, not a recall slip**: resources/27 §4.4C teaches the wrong 2-arg `truncate(price * 1.0875, 2)` form as CANONICAL at L1650, repeats the WRONG claim at L1669 ("the 2-arg form `truncate(x, d)` is supported"), L1677 ("Trino has lowercase `truncate(x, 2)` (2-arg works)"), L1679 ("the 2-arg numeric capability is fully present in Trino 467"). The same resource's §4.4B spillover table at L1707 CORRECTLY states "the lowercase math function is `truncate(x)` and is **1-arg only** (no 2-arg `truncate(x, d)` overload)". **§4.4C and §4.4B contradict each other within the same file** — and the responder followed the WRONG (more prominent canonical) one. Pattern matches `feedback_reconcile_dont_append.md` (fix the contradiction in-place, don't just append). Also recurs the `feedback_trace_recurring_folklore_to_resource_root_cause.md` family — Oracle-2-arg-TRUNC importing into Trino was anchored as supported in r27 itself.

| Q | Score | Topic | Notes |
|---|---|---|---|
| Q1 | 4.75 | Iceberg maintenance (orphan files cleanup) | `ALTER TABLE ... EXECUTE remove_orphan_files(retention_threshold => '7d')` + 7d min-retention floor + maintenance order all VERIFIED correct against [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html). Spark `CALL iceberg.system.remove_orphan_files(older_than => ..., dry_run => true)` faster-cleanup recommendation production-stack-aligned. **BROKEN diagnostic query offered**: `SELECT COUNT(*) FROM "fct_events$files" f WHERE NOT EXISTS (SELECT 1 FROM "fct_events$snapshots" s WHERE f.file_path IN (SELECT file_path FROM "fct_events$files"))` is nonsensical — `$files` shows ONLY current-snapshot files (verified docs verbatim: *"data files in current snapshot"*), so orphans by definition CANNOT appear in it; the IN-subquery self-references `$files` making it a tautology. Engineer reading this could be misled into thinking orphan-finding via `$files` is possible (it is not — only `remove_orphan_files` itself enumerates and reconciles). Per `feedback_responder_broken_secondary_alternative.md` family — lead correct, secondary diagnostic broken. Acc -0.5, Prac -0.5. |
| Q2 | 5.0 | Analytical query patterns on Iceberg+Trino (pivot via conditional aggregation) | Both `SUM(CASE WHEN event_type='page_view' THEN 1 ELSE 0 END)` and `SUM(1) FILTER (WHERE event_type='page_view')` VERIFIED valid Trino 467 at [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html) verbatim (FILTER clause "supported for all aggregate functions"). "Identical plans" claim defensible — Trino's optimizer rewrites `SUM(CASE WHEN p THEN 1 ELSE 0 END)` and `count() FILTER (WHERE p)` into equivalent operators. Standard pivot-via-conditional-aggregation canonical, NO-PIVOT-keyword caveat correct. Clean. |
| Q3 | 4.875 | Improving complex SQL performance on Trino with dbt (composite unique_key) | `unique_key=['account_id','feature_name','usage_date']` list syntax VALID dbt — verified at [docs.getdbt.com/docs/build/incremental-strategy](https://docs.getdbt.com/docs/build/incremental-strategy) ("pass these columns as a list" for composite keys); generated SQL `MERGE INTO ... ON t.k1=s.k1 AND t.k2=s.k2 AND t.k3=s.k3 WHEN MATCHED UPDATE WHEN NOT MATCHED INSERT` shape correct. Dedupe guard `ROW_NUMBER() OVER (PARTITION BY account_id, feature_name, usage_date ORDER BY updated_at DESC) = 1` correct — composite key must be unique in source per run else MERGE throws `MERGE_TARGET_ROW_MULTIPLE_MATCHES`. Partition config `properties={'partitioning': "ARRAY['day(usage_date)']"}` is correct for Trino **Iceberg** connector (the Iceberg table property is `partitioning`, verified at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html); the Trino **Hive** connector uses `partitioned_by` which the dbt-trino docs use in their example — different connector). Production stack is Iceberg per `prod_info.md`, so responder's `partitioning` key is right. Compl shave -0.5: didn't reference iter1234/1235 `incremental_predicates` for the late-older-row case (out-of-scope for the pure "composite key validity" question though). |
| Q4 | 3.625 | Oracle PL/SQL → dbt+Trino migration (TRUNC → Trino truncate) | **CANONICAL FABRICATION**: `truncate(revenue, 2)` does NOT exist in Trino 467. The 1-arg `truncate(x)` is verified ONLY signature at [trino.io/docs/467/functions/math.html](https://trino.io/docs/467/functions/math.html) (RAW git-tag-467 source verbatim: `truncate(x) -> double — Returns x rounded to integer by dropping digits after decimal point`). The 2-arg overload exists in CURRENT trino.io/docs/current (Trino 481), NOT in 467. The two backup forms (`truncate(revenue*100)/100` and `truncate(revenue*power(10,2))/power(10,2)`) ARE correct and recover the engineer. CAST → DECIMAL HALF_UP rounding CORRECT (matches `reference_trino_cast_to_integer_rounds.md` pin). Negative-number semantics correct (toward-zero). **Resource defect**: r27 §4.4C L1650/1669/1677/1679 teaches the WRONG 2-arg form as CANONICAL while r27 §4.4B L1707 (in the same file) CORRECTLY states 1-arg only. Acc 2.5, Prac 3.0 (canonical fails; backups work). |

---

## Per-question detail

### Q1 — Orphan files cleanup → 4.75 (Iceberg maintenance)

**LOAD-BEARING FACTS ALL CORRECT (LEAD answer)**:
- `ALTER TABLE iceberg.analytics.fct_events EXECUTE remove_orphan_files(retention_threshold => '7d')` — VERIFIED at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) WebFetched this iter: `ALTER TABLE test_table EXECUTE remove_orphan_files(retention_threshold => '7d')` verbatim. Parameter name `retention_threshold` correct (NOT `retention_days` — that was the iter1214 expire_snapshots slip).
- 7d default min-retention floor via `iceberg.remove-orphan-files.min-retention` — VERIFIED verbatim "Default value: 7d. Any retention_threshold value lower than this configuration will cause the procedure to fail with an error message." Engineer attempting `'1h'` hits the floor.
- "Orphans = files referenced by ZERO snapshots (failed-write debris)" — correct definition.
- DIFFERENT from `expire_snapshots` (snapshot expiration cleans up snapshot history; remove_orphan_files reconciles MinIO listing vs metadata) — correct disambiguation.
- Maintenance order `optimize → expire_snapshots → remove_orphan_files` — defensible. Docs don't prescribe a strict order but the rationale (compact first to consolidate files, expire snapshots to release references, THEN sweep storage) is correct mental model. Resources/13 + resources/17 teach this same order.
- Spark `CALL iceberg.system.remove_orphan_files(older_than => current_timestamp - interval '3' day, dry_run => true)` — production-stack-aligned (Spark is the on-prem ingestion engine per `prod_info.md`). `dry_run => true` is a Spark-only parameter (Trino's remove_orphan_files does NOT have a dry_run option — that's a documented gap).

**THE BROKEN DIAGNOSTIC QUERY** (Acc -0.5, Prac -0.5):
```sql
SELECT COUNT(*) FROM "fct_events$files" f 
WHERE NOT EXISTS (
  SELECT 1 FROM "fct_events$snapshots" s 
  WHERE f.file_path IN (SELECT file_path FROM "fct_events$files")
)
```
This query is **fundamentally nonsensical**:
1. **Orphans are NOT in `$files`** — VERIFIED at trino.io/docs/467/connector/iceberg.html (WebFetched): `$files` is described as *"data files in current snapshot"*. Orphan files by definition are files in MinIO that the current metadata does NOT reference — they are precisely the files that DON'T appear in `$files`. You cannot find orphans by querying a metadata table that only enumerates non-orphans.
2. **The IN-subquery is a tautology** — `WHERE f.file_path IN (SELECT file_path FROM "fct_events$files")` always evaluates TRUE (since `f` is from `$files`), so the `NOT EXISTS` always evaluates FALSE, and the query always returns `COUNT(*) = 0`. Worse: the `$snapshots` outer-correlation reference (`s`) is dangling — the subquery doesn't actually use `s` for anything, so the NOT EXISTS reduces to a tautology even before the IN.
3. **Engineer impact** — copying this query into their notebook returns 0 and they conclude "no orphans" when MinIO actually has 35GB of orphan Parquet sitting there. The actual diagnostic path is: list MinIO objects via `mc ls --recursive` OR `s3api list-objects`, then compare against `$files.file_path` set, OR just run `remove_orphan_files` with `dry_run=true` on the **Spark** side (Trino doesn't support dry_run for this procedure).

Per `feedback_responder_broken_secondary_alternative.md` family — lead correct, padded secondary "diagnostic" broken. The engineer's main asks (cleanup command + retention safety + maintenance order) are fully answered correctly; the broken diagnostic is a side-recommendation they may or may not engage with.

**NO FIX-A on the broken diagnostic** — first occurrence, per-instance recall ceiling. NEW SOFT WATCH `iter1240 Q1 $files-can-find-orphans tautology diagnostic`: re-probe in 4-8 iters under similar "how do I list/find orphan files before deleting" framings; if recurs, light additive r17 line "$files lists ONLY current-snapshot data files — orphans by definition do NOT appear there; use Spark dry_run=true or `mc ls + diff against $files.file_path` to enumerate them BEFORE running remove_orphan_files."

### Q2 — Pivot rows → columns → 5.0 (Analytical patterns)

Both forms are textbook canonical for Trino 467:

```sql
-- Form A: SUM(CASE)
SELECT
  account_id,
  DATE_TRUNC('month', occurred_at) AS month,
  SUM(CASE WHEN event_type='page_view' THEN 1 ELSE 0 END) AS page_views,
  SUM(CASE WHEN event_type='api_call'  THEN 1 ELSE 0 END) AS api_calls,
  SUM(CASE WHEN event_type='export'    THEN 1 ELSE 0 END) AS exports
FROM events
GROUP BY account_id, DATE_TRUNC('month', occurred_at);

-- Form B: FILTER (WHERE)
SELECT
  account_id,
  DATE_TRUNC('month', occurred_at) AS month,
  COUNT(*) FILTER (WHERE event_type='page_view') AS page_views,
  COUNT(*) FILTER (WHERE event_type='api_call')  AS api_calls,
  COUNT(*) FILTER (WHERE event_type='export')    AS exports
FROM events
GROUP BY account_id, DATE_TRUNC('month', occurred_at);
```

**VERIFICATIONS**:
- FILTER clause: [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html) WebFetched — "supported for all aggregate functions"; syntax `aggregate_function(...) FILTER (WHERE <condition>)` valid Trino 467.
- "Trino has no PIVOT" — TRUE, verified (open feature request, not in 467).
- "Both produce identical plans" — defensible: Trino's optimizer rewrites both into the same operator (filtered aggregation node). Minor pedantic note: in deeply-nested or correlated cases the plans can diverge, but for this flat single-GROUP-BY shape they are identical.

Engineer arrives at one of two clean idiomatic patterns. Either is production-ready. Clean answer.

### Q3 — dbt incremental composite unique_key → 4.875 (Complex SQL performance with dbt)

**LOAD-BEARING FACTS ALL CORRECT**:
- `unique_key=['account_id','feature_name','usage_date']` is valid dbt syntax — verified at [docs.getdbt.com/docs/build/incremental-strategy](https://docs.getdbt.com/docs/build/incremental-strategy) WebFetched this iter: "When you need multiple columns in combination to uniquely identify each row, dbt recommends passing these columns as a list (`unique_key = ['user_id', 'session_number']`)."
- Generated MERGE shape `MERGE INTO target t USING source s ON t.account_id=s.account_id AND t.feature_name=s.feature_name AND t.usage_date=s.usage_date WHEN MATCHED THEN UPDATE SET ... WHEN NOT MATCHED THEN INSERT ...` — correct compiled output for composite key on dbt-trino's merge strategy.
- Dedupe guard via `ROW_NUMBER() OVER (PARTITION BY account_id, feature_name, usage_date ORDER BY updated_at DESC) = 1` — correct prerequisite. Composite key NOT unique in source per run = `MERGE_TARGET_ROW_MULTIPLE_MATCHES` Trino-side error (verified at [trino.io/docs/467/sql/merge.html](https://trino.io/docs/467/sql/merge.html) — "For each source row, the WHEN clauses are processed in order").

**PARTITION CONFIG CHECK**: responder wrote `properties={'format': "'PARQUET'", 'partitioning': "ARRAY['day(usage_date)']"}`. Teacher pre-flag asked whether this is `partitioned_by` vs `partitioning`. **Answer**: depends on connector:
- **Iceberg connector** (this stack per `prod_info.md`): the table property is `partitioning` — verified at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) — `WITH (partitioning = ARRAY['day(occurred_at)', 'tenant_id'])`.
- **Hive connector**: the table property is `partitioned_by` — which is what the dbt-trino docs example uses ([docs.getdbt.com/reference/resource-configs/trino-configs](https://docs.getdbt.com/reference/resource-configs/trino-configs) shows `"partitioned_by": "ARRAY['day']"` under "Incremental overwrite on Hive models").

Responder's `partitioning` is correct for the production Iceberg stack. The dbt-trino docs example happens to be Hive, but the production stack is Iceberg, so the Iceberg name is what the engineer needs. NO defect.

**Minor Compl shave (-0.5)**: didn't surface the iter1234/1235 `incremental_predicates` late-older-row guard. Out-of-scope for the pure "composite key validity + dbt MERGE shape" ask though — engineer's question is about whether the composite key syntax works and what MERGE is generated, not about CDC late-arrival semantics. Not load-bearing.

Clean answer, would NO-OP except for Compl micro-shave.

### Q4 — Trino truncate / CAST round vs truncate → 3.625 (Oracle migration — LOAD-BEARING FAIL)

**THE LOAD-BEARING VERIFY** — does Trino 467 have a 2-arg `truncate(x, d)` form?

**ANSWER: NO. The 2-arg form does NOT exist in Trino 467.**

Verification (all WebFetched this iter):
1. **[trino.io/docs/467/functions/math.html](https://trino.io/docs/467/functions/math.html)** — searched the rendered page for "truncate" — ONLY signature shown: `truncate(x) -> double — Returns x rounded to integer by dropping digits after decimal point.` No 2-arg overload listed.
2. **[raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/math.md](https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/math.md)** RAW git-tag 467 source verbatim:
   ```
   :::{function} truncate(x) -> double
   Returns `x` rounded to integer by dropping digits after decimal point.
   :::
   ```
   ONLY occurrence of "truncate" in the entire 467 math docs source. No 2-arg form.
3. **Current docs (Trino 481)** at [trino.io/docs/current/functions/math.html](https://trino.io/docs/current/functions/math.html) DO list a 2-arg `truncate(x, d)` form — confirms the 2-arg overload was added in a **post-467 release**, NOT in 467.

**Verdict on responder's CANONICAL answer**: `truncate(revenue, 2)` claimed as "Trino 467 has the exact 2-arg form" is a **FABRICATION** (imported-prior assumed-presence — Oracle's `TRUNC(x, n)` muscle memory). Engineer executing the canonical hits:
```
SQL Error: line 1:8: Unexpected parameters (decimal(18,2), integer) for function truncate. Expected: truncate(double) , truncate(real) , truncate(decimal(p, s))
```

**The two backup forms ARE correct** and recover the engineer:
- `truncate(revenue * 100) / 100` — VALID Trino 467 (1-arg truncate, *100/100 wraps to 2 decimals, toward-zero, negative-safe).
- `truncate(revenue * power(10, 2)) / power(10, 2)` — VALID Trino 467, generalized to N decimals.
- Both produce `9.99` for `truncate(9.999 * 100) / 100 = truncate(999.9) / 100 = 999.0/100 = 9.99` ✓
- Negative behavior: `truncate(-9.995 * 100) / 100 = truncate(-999.5) / 100 = -999.0/100 = -9.99` ✓ (toward zero, NOT toward -infinity — this is why `floor()` is wrong for truncation semantics).

**CAST → DECIMAL HALF_UP rounding CORRECT**: `CAST(9.995 AS DECIMAL(18,2)) = 10.00` — matches pinned `reference_trino_cast_to_integer_rounds.md` (CAST to integer/decimal ROUNDS HALF_UP, does NOT truncate). Engineer migrating Oracle TRUNC behavior via CAST is silently changing semantics — responder correctly flagged this as the distinction load-bearing for billing/accounting/tax.

**ROOT CAUSE — RESOURCE DEFECT IN r27 §4.4C** (GREP EVIDENCE):

resources/27-oracle-plsql-to-dbt-trino.md teaches the WRONG 2-arg form as CANONICAL:
- **L1650** (worked example): `SELECT truncate(price * 1.0875, 2) AS price_with_tax FROM orders;` labeled `-- Trino — CANONICAL form (direct 2-arg truncate, same semantics as Oracle TRUNC(n, 2)):` ← **WRONG**
- **L1669** (DO-NOT-WRITE entry 2): `"truncate(n, d) — the 2-arg numeric truncation form — DOES exist on Trino 467; USE IT."` + `"Trino's truncate has BOTH a 1-arg form ... AND a 2-arg form (truncate(x, d) / signature truncate(decimal(p,s), bigint) -> decimal(p,s))"` ← **WRONG** + verifies-via-wrong-source (cites `trino.io/docs/current` which is 481, not 467 — current docs DO list 2-arg, but 467 does not).
- **L1677** (Keyword-trap phrase): `"Trino has lowercase truncate(x, 2) (2-arg works, same truncation semantics as Oracle)"` ← **WRONG**
- **L1679** (Cross-reference closer): `"the 2-arg numeric capability is fully present in Trino 467, so do NOT rewrite TRUNC(n, 2) into the clunky *100/100 form unless you want the explicit version"` ← **WRONG and actively misleading** (explicitly tells engineer to PREFER the broken form).

**Self-contradiction within r27**:
- **L1707** (§4.4B cross-dialect-spillover table) CORRECTLY states: `"the lowercase math function is truncate(x) and is 1-arg only (no 2-arg truncate(x, d) overload)"` with the Trino-correct form being `truncate(n * power(10, d)) / power(10, d)`.

So §4.4C body (lines 1650/1669/1677/1679) and §4.4B spillover table (line 1707) directly contradict each other in the same file. The responder followed the more prominent CANONICAL § (4.4C body) which is wrong.

---

## LIGHT FIX-A WARRANTED — r27 §4.4C reconciliation

**Specification** (the teacher should reconcile §4.4C with §4.4B's correct statement, NOT just append):

1. **L1650** — Change the CANONICAL line from `SELECT truncate(price * 1.0875, 2) AS price_with_tax FROM orders;` to:
   ```sql
   -- Trino — CANONICAL form (Trino 467 has 1-arg truncate only; *power(10,d)/power(10,d) wraps to d decimals):
   SELECT truncate(price * 1.0875 * 100) / 100 AS price_with_tax FROM orders;
   -- Equivalent generalized form for arbitrary d decimal places:
   SELECT truncate(price * 1.0875 * power(10, 2)) / power(10, 2) AS price_with_tax FROM orders;
   ```
   Remove the "direct 2-arg truncate" comment.

2. **L1669** — Rewrite DO-NOT-WRITE entry 2. Replace the WRONG `"2-arg form DOES exist on Trino 467; USE IT"` with:
   ```
   2. **`truncate(n, d)` — the 2-arg form does NOT exist on Trino 467.** Trino 467 has ONLY the 1-arg `truncate(x) -> [same as input]` (integer truncation toward zero). The 2-arg `truncate(x, d)` overload was added in a post-467 release (visible in trino.io/docs/current = 481+) but is NOT in 467. Verified against [github.com/trinodb/trino/blob/467/docs/src/main/sphinx/functions/math.md](https://github.com/trinodb/trino/blob/467/docs/src/main/sphinx/functions/math.md) — only `truncate(x) -> double` is listed. The correct canonical for d-decimal truncation on 467 is **`truncate(n * power(10, d)) / power(10, d)`** (or `truncate(n * 100) / 100` for 2 decimals). Writing `truncate(n, d)` on Trino 467 produces `Unexpected parameters (decimal(p,s), integer) for function truncate. Expected: truncate(double), truncate(real), truncate(decimal(p, s))`.
   ```

3. **L1677** — Rewrite Keyword-trap phrase. Replace `"Trino has lowercase truncate(x, 2) (2-arg works)"` with:
   ```
   **Keyword-trap phrase (memorize):** *"Anyone who writes `TRUNC(x, 2)` for Trino is using Oracle syntax — Trino 467's lowercase `truncate` is **1-arg only**, so the Trino canonical is `truncate(x * power(10, 2)) / power(10, 2)` (or `truncate(x * 100) / 100` for 2 decimals); `round(x, 2)` is the HALF_UP-rounding alternative if rounding is acceptable. The 2-arg `truncate(x, d)` form was added post-467."*
   ```

4. **L1679** — Remove the WRONG "the 2-arg numeric capability is fully present in Trino 467, so do NOT rewrite TRUNC(n, 2) into the clunky *100/100 form" closer. Replace with:
   ```
   The migration fix for `TRUNC` requires BOTH a rename AND a rewrite for 2-arg: numeric `TRUNC(n, d)` → `truncate(n * power(10, d)) / power(10, d)` (Trino 467 has no 2-arg `truncate` overload); numeric `TRUNC(n)` → `truncate(n)` (lowercase, same toward-zero semantics); date `TRUNC(dt, 'MM')` → `date_trunc('month', dt)`.
   ```

5. **L1707** is already correct — no change needed, but ADD a cross-ref from §4.4C body to §4.4B L1707 so that future updates of either section trigger a consistency check.

**This is the iter1192-style "GREP ALL resources for the wrong claim" pattern** (per `reference_trino_optimize_clears_position_deletes.md` memory). Before landing the FIX-A, teacher should `grep -n "truncate(.*,.*)" resources/27-*.md` to catch all sibling occurrences in the same file, AND `grep -n "truncate.*2-arg\|2-arg.*truncate" resources/` for any cross-file echoes. Found in initial grep: L1326 in r27 also references `truncate(n * power(10, d)) / power(10, d)` correctly; L1267 + L1638-1639 (Oracle-to-Trino mapping tables) say `truncate(n)` 1-arg only — those are correct. The damage is localized to §4.4C body lines 1650/1669/1677/1679. Adjacent file resources/05 §2057 references `truncate(col, W)` but that's the Iceberg PARTITIONING TRANSFORM string (different beast — partition transforms accept `truncate(col, N)` as a string in `WITH (partitioning = ARRAY['truncate(col, N)'])`, NOT a math function call). Don't touch r05 §2057. resources/10 §829, §1011, resources/09 §74, resources/28 §1231 are all about partition transforms — leave alone.

**Why this matters now**: Oracle migration is currently at 4.4687/205 (margin +0.9687) — robust to a single 3.625 hit (would drop ~0.004). But this is a load-bearing CANONICAL line in the most-trafficked Oracle-migration section; the same wrong canonical will fire on every future `TRUNC(x, n)` re-probe (multi-decimal billing, tax rounding, accounting truncation). Per `feedback_reconcile_dont_append.md` — fix the contradiction within the file, don't tolerate a passing topic average masking a known-recurring resource defect on a load-bearing canonical.

---

## Watches summary

- **NEW (LIGHT FIX-A landing this iter)**: `iter1240 Q4 r27 §4.4C 2-arg truncate fabrication reconciliation` — re-probe 4-8 iters after FIX-A under "TRUNC(n, 2) Oracle → Trino" / "truncate to N decimal places Trino" framings.
- **NEW (soft)**: `iter1240 Q1 $files-can-find-orphans tautology diagnostic` — re-probe 4-8 iters under "how to LIST orphan files before deleting / dry-run from Trino side". Non-FIX (first occurrence, recall ceiling on a secondary aside).
- **CARRIED open**: iter1239 Q1 DF-wait-timeout (soft); iter1238 Q3 broadcast-vs-partitioned-hedge (soft); iter1236 rn=1-within-batch (soft); iter1234 ROLLUP-date_trunc-expr (soft); iter1233 IGNORE-NULLS-framing; iter1231 NEXT_DAY-note; iter1230 EXISTS-overwarning/::cast; iter1215 strpos-3-arg CEILING; iter1213 session_properties/(+); iter1229 @v1-Spark; iter1208 width_bucket.

## Pattern note

Q4 is the **9th instance of an imported-prior assumed-presence/absence error** (after starts_with / to_char / listagg / array_sum / format_number / migrate / LATERAL / MERGE-AND). Unlike the prior eight (which were all assumed-ABSENCE — Trino DOES have foreign-looking function X), Q4 is the opposite: assumed-PRESENCE — Trino does NOT have foreign-looking overload X. Both directions of the family come from the same root: importing Oracle/Postgres/Snowflake muscle memory into Trino without verifying against trino.io/docs/467 (or the RAW git-tag source for ground truth). The pinned references catch this in directives; the resource needs to consistently catch it in canonicals. The §4.4C/§4.4B internal contradiction shows this can happen even within a single file — the FIX-A enforces self-consistency.

## Verification methodology this iter

- Q1: WebFetched [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) for remove_orphan_files signature + retention floor + $files semantics.
- Q2: WebFetched [trino.io/docs/467/functions/aggregate.html](https://trino.io/docs/467/functions/aggregate.html) for FILTER clause support.
- Q3: WebFetched [docs.getdbt.com/reference/resource-configs/trino-configs](https://docs.getdbt.com/reference/resource-configs/trino-configs) for partition config + [docs.getdbt.com/docs/build/incremental-strategy](https://docs.getdbt.com/docs/build/incremental-strategy) for composite unique_key.
- Q4: **3 independent verifications** of 1-arg-only:
  1. WebFetch of rendered [trino.io/docs/467/functions/math.html](https://trino.io/docs/467/functions/math.html) (1 signature only).
  2. WebFetch of GitHub blob [github.com/trinodb/trino/blob/467/docs/src/main/sphinx/functions/math.md](https://github.com/trinodb/trino/blob/467/docs/src/main/sphinx/functions/math.md) (1 occurrence only).
  3. WebFetch of RAW [raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/math.md](https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/math.md) (1 occurrence only, verbatim).
  Plus comparison against [trino.io/docs/current/functions/math.html](https://trino.io/docs/current/functions/math.html) (current=481, lists 2-arg) confirming the version cutoff is post-467. Triple-source convergence on 1-arg-only.
