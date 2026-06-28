# Iteration 1218 — Judge Feedback

**Verdict: 4.20 PASS + LIGHT FIX-A on Q3.** Q1 closes the `iter1214 retention_days` param-fab watch CLEANLY (4.5625 — responder correctly flagged the wrong `retention_days => 7` form and substituted `retention_threshold => '7d'` + correctly framed expire-vs-planning + correctly routed `rewrite_manifests` to Spark per Trino 467 / Trino 470+ optimize_manifests cutoff). Q2 weighted-avg canonical pin-perfect (4.75). **Q3 dbt `accepted_values`-doesn't-catch-NULL DEFECT (2.75 FAIL)** — responder claimed "NULL and 'none' will BOTH be caught" but `accepted_values` compiles to `NOT IN (...)` and `NULL NOT IN (...)` evaluates UNKNOWN, so NULL rows pass silently. **Resource-sourced**: r28 §242 + r27 §3006 show the compiled SQL without making the NULL exclusion explicit. **LIGHT FIX-A**: add explicit NULL-trap caveat + pair-with-`not_null` guidance in both locations. Q4 Oracle DECODE → CASE WHEN with Oracle-NULL=NULL-TRUE vs Trino-IS-NULL nuance (4.75) — 5th consistent DECODE pass.

---

## Per-question scores

### Q1 — Slow Iceberg planning (Spark streaming 200 commits/day × 8 months; coworker ran `expire_snapshots(retention_days => 7)`) — **WATCH RE-PROBE**

| Dimension | Score |
|---|---|
| Technical accuracy | 5.0 |
| Beginner clarity | 4.5 |
| Practical applicability | 4.75 |
| Completeness | 4.0 |
| **Average** | **4.5625 STRONG PASS** |

**Verifications (this iter, all sources cited):**

1. **`expire_snapshots(retention_days => 7)` is WRONG on Trino 467** — verified at [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) (WebFetched this iter): correct form is `expire_snapshots(retention_threshold => '7d')` (VARCHAR duration string), AND must meet `iceberg.expire-snapshots.min-retention` floor (default `7d`). Coworker would have hit `Unknown procedure argument: retention_days` parse error. Optional args `retain_last` (default 1) + `clean_expired_metadata` (default false) also documented. Responder correctly named the right param name.
2. **Planning bloat causal model correct** — 200 commits/day × ~240 days = ~48,000 snapshots, each producing manifest commits. The CURRENT snapshot's manifest count grows even after `expire_snapshots` because expire reclaims STORAGE of historical snapshots but does NOT reduce the current snapshot's manifest list size; manifest-list + per-manifest scan at plan time is the actual 18s planning cost. Confirmed by Trino issue [trinodb/trino#14821](https://github.com/trinodb/trino/issues/14821) ("Add rewrite_manifests procedure to consolidate") still OPEN.
3. **`rewrite_manifests` Spark-only on Trino 467, `optimize_manifests` is Trino 470+** — verified at trino.io/docs/467/connector/iceberg.html (procedures list only `register_table` / `unregister_table` / `migrate` / `add_files`) + [release-470.html](https://trino.io/docs/current/release/release-470.html) "Add the optimize_manifests table procedure" + matches r17 §24 / §211 / §235 / §685 / §810 verbatim "Trino 470, NOT 467" gating. Responder's "Spark or Trino 470+" precisely matches the resource pin.
4. **`$manifests` metadata table diagnostic** — Iceberg `$manifests` is a valid Trino 467 metadata table (columns include `path`, `length`, `added_snapshot_id`, `partition_summaries`). `SELECT COUNT(*), SUM(length)/1024/1024 FROM "events$manifests"` is a correct diagnostic — >200 manifests is a sensible red-flag threshold for the planning-time bottleneck.

**Minor completeness shave (-0.5 Compl):** Did NOT mention `EXECUTE optimize(file_size_threshold => '256MB')` as a complementary lever — compacting small data files indirectly reduces manifest count over time (fewer entries per manifest, fewer total manifests). For Spark-streaming-200-commits/day this is structurally important: even after `rewrite_manifests` you have to address the small-file generator. Recall-ceiling, not a resource defect (r17 §61 step 1-3 teach optimize-then-rewrite_manifests as a sequence).

**WATCH CLOSURE — `iter1214 retention_days` param-fab CLOSES on first re-probe (4 iters later).** Responder went from FABRICATING `retention_days => 7` (iter1214) to CORRECTLY CALLING OUT `retention_days => 7` as wrong and substituting `retention_threshold => '7d'` (this iter, iter1218). Findability + recall both reach the canonical. No FIX-A; clean watch close (12th consecutive closure in 1st-re-probe-CLOSE pattern across recent iters).

**Topic**: `Iceberg table maintenance: compaction, snapshot expiry, orphan file cleanup` — was 4.4488/221, → (982.7848 + 4.5625)/222 = 987.3473/222 = **4.4475/222 PASSED** (-0.0013, margin +0.9475).

---

### Q2 — Weighted average for `api_calls(customer_id, response_time_ms)` skewed by high-volume customers

| Dimension | Score |
|---|---|
| Technical accuracy | 5.0 |
| Beginner clarity | 4.5 |
| Practical applicability | 5.0 |
| Completeness | 4.5 |
| **Average** | **4.75 STRONG PASS** |

**Verifications:**

1. **No `weighted_avg()` in Trino 467** — verified at [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html); aggregate function list has `avg(x)` + variants but no `weighted_avg`. (Approx-percentile takes an optional `weight` arg per [issue #12276](https://github.com/trinodb/trino/issues/12276), but that's percentile-specific.) Responder correctly bails "no built-in, write the formula."
2. **`SUM(value*weight) / NULLIF(SUM(weight), 0)` canonical** — verified at [interviewquery.com SQL weighted average guide](https://www.interviewquery.com/p/weighted-average-sql-guide) + multiple Trino-tagged StackOverflow answers; NULLIF guard prevents DIVISION_BY_ZERO for empty/zero-weight groups (responder pinned `reference_trino_division_by_zero.md` family — INTEGER `/` 0 THROWS, NULLIF is the canonical guard).
3. **Per-customer-aggregate reconstruction `SUM(avg*count)/SUM(count)`** — algebraically correct: `sum_over_customers(per_customer_avg × per_customer_count) / sum_over_customers(per_customer_count) = sum_over_all_rows(value) / count_of_all_rows`. Equivalent to grand-AVG over raw data; correctly recovers the call-weighted mean from already-aggregated per-customer stats.
4. **Raw-data observation `SUM(response_time_ms) / COUNT(*)` = `AVG(response_time_ms)` = call-weighted** — correct: plain AVG over raw rows is mathematically a call-weighted average because each row counts once. Responder's framing that "AVG on raw data is inherently call-weighted" is the load-bearing insight that resolves the engineer's confusion ("why does my AVG-of-AVGs skew low-volume?" → AVG-of-AVGs is customer-weighted not call-weighted).

**Minor compl shave (-0.5):** Could have spelled out the algebra ("AVG-of-AVGs gives each customer 1/N weight regardless of call count; SUM/COUNT gives each CALL 1/total_calls weight") to drive home WHY the original was skewed. Engineer arrives at the right code regardless.

**Topic**: `SQL query best practices for OLAP` — was 4.5878/278, → (1275.4084 + 4.75)/279 = 1280.1584/279 = **4.5884/279 PASSED** (+0.0006, margin +1.0884).

---

### Q3 — dbt test to fail build when `fct_subscriptions.plan_tier` has unexpected values (engineer scenario: NULL **and** literal 'none' both introduced)

| Dimension | Score |
|---|---|
| Technical accuracy | 2.0 |
| Beginner clarity | 4.0 |
| Practical applicability | 2.5 |
| Completeness | 2.5 |
| **Average** | **2.75 FAIL** |

**DEFECT — `accepted_values` does NOT catch NULL; responder claim is FALSE.**

Responder's exact quote: *"NULL and 'none' will BOTH be caught because they are NOT in the allowed list."*

**This is factually wrong for NULL.** Verified via [docs.getdbt.com/reference/resource-properties/data-tests](https://docs.getdbt.com/reference/resource-properties/data-tests) + [dbt-core issue #8543](https://github.com/dbt-labs/dbt-core/issues/8543) ("[CT-3070] [Bug] accepted_values test passes despite NULL values") + [dbt-utils issue #287](https://github.com/dbt-labs/dbt-utils/issues/287) ("Schema Test - Accepted Values for null value"):

- `accepted_values` compiles to roughly `SELECT col FROM model GROUP BY col HAVING col NOT IN ('v1', 'v2', ...)` (or equivalent `WHERE col NOT IN (...)`).
- **SQL trap**: `NULL NOT IN ('free','starter','pro','enterprise')` evaluates to **UNKNOWN**, NOT TRUE. UNKNOWN rows are NOT returned by `WHERE`/`HAVING`.
- Therefore the NULL row is **silently EXCLUDED** from the failing-rows result — the test passes despite NULL being a value the user didn't allow.
- Verbatim from docs.getdbt.com: *"the `accepted_values` test validates that all of the **non-null** values in a column are present in a supplied list of values"* (non-null is documented but easy to miss).

**Engineer's stated scenario explicitly had BOTH NULL and 'none' introduced.** If they follow the responder's advice verbatim, `dbt build` runs the `accepted_values` test, the 'none' rows fail (good — caught), but the NULL rows pass silently — and downstream is STILL silently wrong. The engineer thinks they're protected, but they're only half-protected. This is exactly the silent-bug failure mode the test was supposed to prevent.

**Correct answer** (what should have been said): pair `accepted_values` WITH `not_null` on the same column:
```yaml
- name: plan_tier
  data_tests:
    - not_null                                                  # catches NULL
    - accepted_values:
        values: ['free', 'starter', 'pro', 'enterprise']         # catches 'none' and any other unexpected literal
```
Both run as `severity: error` (default), both must pass for downstream to proceed.

**Resource-sourced? YES — LIGHT FIX-A WARRANTED.**

Grep evidence:
- **r28 §242** (`resources/28-complex-sql-performance-trino-dbt.md` line 242): teaches the compiled SQL `SELECT status FROM fct_users WHERE status NOT IN ('active','churned','trial')` but does **NOT** call out that NULL is excluded by NOT-IN semantics. The DO-NOT-WRITE row at §272 mentions `unique` is NULL-tolerant but says nothing about `accepted_values` NULL behavior.
- **r27 §3006** (`resources/27-oracle-plsql-to-dbt-trino.md`): teaches `accepted_values` compiles to `WHERE <col> NOT IN ('v1', 'v2', ...) [AND <col> IS NOT NULL]` with the IS NOT NULL clause in BRACKETS (suggesting "optional"). This is technically wrong — dbt-core's `accepted_values.sql` macro does NOT emit an explicit IS NOT NULL filter; the NULL exclusion is purely NOT-IN UNKNOWN semantics. Either way, the engineer reading §3006 won't notice that NULL is excluded.

Neither location pairs `accepted_values` guidance with "also add `not_null`" guidance for catching NULLs. This is exactly the same shape as the iter948 r07 HAVING-trims-memory folklore (recurring slip traced to a wrong/incomplete resource claim) — `feedback_trace_recurring_folklore_to_resource_root_cause.md` applies.

**LIGHT FIX-A spec:**
- **r28 §242 (the compiled-SQL bullet for `accepted_values`)** — add explicit one-sentence caveat right after the compiled-SQL line: *"**NULL trap:** NULL rows are silently excluded because `NULL NOT IN (...)` evaluates to UNKNOWN (not TRUE), so NULL rows do NOT appear in the failing-rows set. To catch BOTH unexpected literal values AND NULL, pair `accepted_values` with `not_null` on the same column."*
- **r28 §272 DO-NOT-WRITE table** — add a new row: *WRONG: `accepted_values` alone on a column that must reject NULL → RIGHT: pair with `not_null` (`accepted_values` catches `'none'` / typos / new values, `not_null` catches NULL — both run by default `severity: error`).*
- **r27 §3006** — drop the misleading `[AND <col> IS NOT NULL]` bracket (dbt-core does NOT emit this), reconcile to: *"compiles to roughly `SELECT <col> FROM <model> WHERE <col> NOT IN ('v1', 'v2', ...)` — note NULL rows pass silently per `NULL NOT IN (...)` UNKNOWN semantics; pair with `not_null` to catch NULL."*
- **Watch label**: `iter1218 r28+r27 accepted_values-doesnt-catch-NULL FIX-A`; re-probe with framing like *"my plan_tier has nulls and unexpected strings, single dbt test or two?"* or *"if a column allows NULL legitimately, can I still use accepted_values to catch typos?"* within 4-8 iters.

**Topic**: `dbt model contracts` (same routing as iter1216 Q3 relationships, per "structurally identical data-integrity declaration as model-contracts family") — was 4.5655/11, → (50.2205 + 2.75)/12 = 52.9705/12 = **4.4142/12 PASSED** (-0.1513, margin still +0.9142 — large hit on a thin 12-Q row, but row remains comfortably above threshold).

---

### Q4 — Oracle `DECODE(plan_tier, 'free', 0, 'starter', 29, 'pro', 99, 999)` → Trino equivalent

| Dimension | Score |
|---|---|
| Technical accuracy | 5.0 |
| Beginner clarity | 4.5 |
| Practical applicability | 5.0 |
| Completeness | 4.5 |
| **Average** | **4.75 STRONG PASS** |

**Verifications:**

1. **No `DECODE` in Trino 467** — verified at [trino.io/docs/current/functions/conditional.html](https://trino.io/docs/current/functions/conditional.html); conditional functions are `CASE` / `IF` / `COALESCE` / `NULLIF` / `TRY`. No DECODE alias. Matches r27 §6.4 Oracle-function-translation table.
2. **CASE WHEN rewrite is the correct translation** — responder gave the verbatim form:
   ```sql
   CASE WHEN plan_tier = 'free' THEN 0
        WHEN plan_tier = 'starter' THEN 29
        WHEN plan_tier = 'pro' THEN 99
        WHEN plan_tier = 'enterprise' THEN 199
        ELSE 999
   END
   ```
   1:1 translation of Oracle DECODE position arguments to CASE WHEN branches with the trailing default mapped to ELSE.
3. **Oracle NULL=NULL semantics caveat correctly named** — Oracle `DECODE(x, NULL, 'is_null', ...)` matches NULL inputs (DECODE treats NULL=NULL as TRUE, unique to DECODE among Oracle expressions); Trino's `CASE WHEN x = NULL` evaluates UNKNOWN (standard SQL three-valued logic), so the NULL branch never matches. Responder correctly routed to **searched CASE** with `WHEN plan_tier IS NULL THEN ...` as the FIRST branch — this is the canonical translation for DECODE rows that explicitly handle NULL.

**5th consistent DECODE pass.** Past 4 DECODE re-probes (iter1067 / iter1133 / iter1170 / iter1213-ish) all landed cleanly with the same NULL-nuance disambiguation. This is a well-internalized canonical now.

**Topic**: `Oracle PL/SQL procedure → dbt + Trino SQL migration` — was 4.4547/181, → (806.3007 + 4.75)/182 = 811.0507/182 = **4.4563/182 PASSED** (+0.0016, margin +0.9563).

---

## Watch / monitor status

**Watches CLOSED:**
- **`iter1214 retention_days` param-fab + expire-vs-planning conflation** → **CLOSED on first re-probe** (4 iters later). Responder this iter correctly flagged the wrong `retention_days => 7` form, substituted `retention_threshold => '7d'`, AND framed expire-vs-planning distinction correctly (storage hygiene vs metadata-bloat fix). 12th consecutive watch-closure in 1st-re-probe-CLOSE pattern.

**Watches NEWLY OPENED:**
- **`iter1218 r28+r27 accepted_values-doesnt-catch-NULL` LIGHT FIX-A** — resource-sourced (r28 §242 + r28 §272 + r27 §3006). Reconcile-in-place per `feedback_reconcile_dont_append.md`: drop r27 §3006 misleading `[AND <col> IS NOT NULL]` brackets, add explicit NULL-trap caveat at r28 §242 + new DO-NOT-WRITE row at §272. Re-probe within 4-8 iters under framing variants like *"if my column allows NULL legitimately, can I still use accepted_values?"* / *"is there ONE dbt test that catches both NULL and unexpected literals?"*

**Watches STILL OPEN (no churn this iter):**
- **`iter1215 strpos-3-arg`** CONFIRMED-CEILING — recall ceiling on responder, NO churn; re-probe in 6-10 iters.
- **`iter1213 session_properties + (+)-mnemonic`** — re-probe 4-7 iters.
- **`iter1206 LIKE-on-ROW + $partitions-omission`** — re-probe 4-8 iters.

---

## Pattern observations

- **Q3 family meta-pattern**: 3rd instance in recent ~20 iters where responder confidently asserts a built-in dbt test catches MORE cases than it actually does (similar to iter941+946 HAVING-trims-memory folklore traced to wrong resource claim). The two-sentence NULL-trap caveat in r28/r27 closes the recurring slip surface. Per `feedback_trace_recurring_folklore_to_resource_root_cause.md`, resource trace was successful (r28 §242 + r27 §3006 confirmed source-anchored, not pure responder slip).
- **iter1214 watch closure timing**: 4-iter gap (1214 → 1218) is the median observed re-probe latency. Watch system functioning as designed; param-fab family (retention_days fab) now joins starts_with-fab / to_char-fab / array_sum-fab / format_number-fab / migrate-fab / LATERAL-absence-fab / register_table-arg-shape in the "imported-prior assumed-fact" family, all now closed.
- **Recall ceilings (NO churn)**: Q1 omitted `EXECUTE optimize` as a complementary lever; Q2 didn't spell out the AVG-of-AVGs weighting algebra. Both are recall-ceiling completeness shaves on otherwise pin-perfect canonicals — no resource action.

---

## Iteration summary

- **Per-Q scores**: Q1 4.5625 / Q2 4.75 / Q3 2.75 / Q4 4.75
- **Iteration avg**: (4.5625 + 4.75 + 2.75 + 4.75) / 4 = **4.2031 PASS + LIGHT FIX-A**
- **FIX-A required**: r28 §242 + r28 §272 + r27 §3006 — `accepted_values`-doesn't-catch-NULL caveat + pair-with-`not_null` guidance.
- **All required topics still PASSED** (Q3 hit r-dbt-model-contracts row to 4.4142/12, margin +0.9142 — comfortable; FIX-A protects against future regression).
