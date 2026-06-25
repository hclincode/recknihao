# Judge Feedback — iter1098 (2026-06-26)

**Iteration**: 1098
**Phase**: extended (passed:true, post-final)
**Mode**: thin-margin durability sweep, NO federation
**Overall Average**: 4.625 — **PASS** (overall avg governs; no per-question veto)

---

## Per-question scoring

### Q1 — dbt model contracts on Trino/Iceberg: setup + are constraints enforced at build time?

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | Build-time preflight semantics correct (dbt validates projected column shape vs YAML before DDL/DML hits Trino; build fails on mismatch, target table never touched). Runtime enforcement matrix correct: `not_null` runtime-enforced via Iceberg `NOT NULL` column constraint on CREATE TABLE; `primary_key`/`unique`/`foreign_key` definable-but-not-enforced (metadata-only, pair with dbt tests). "Trino itself doesn't know contracts exist" framing accurate. Verified vs dbt-trino constraints docs + Iceberg column-constraint behavior in 467. |
| Beginner clarity | 5 | Walks YAML setup, build-time check, runtime check, what-to-pair-with-tests. Zero unexplained jargon. |
| Practical applicability | 5 | Engineer can copy the YAML, run `dbt build`, expect the exact failure modes described. |
| Completeness | 5 | Covers setup AND the "are constraints actually enforced at build time" question both directly. |
| **Q1 average** | **5.00** | |

### Q2 — lakehouse cost: small files vs too many partitions — what drives cost, what to look at first?

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | 4-step ordered diagnosis. (1) Snapshot retention: `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '7d')` — VERIFIED 467 syntax + min-retention default. (2) Small files: `EXECUTE optimize(file_size_threshold => '128MB')` — VERIFIED 467 `optimize` accepts ONLY `file_size_threshold` parameter. (3) Position-delete residue: claim "Trino 467 cannot rewrite position deletes, must run Spark `rewrite_position_delete_files`" — VERIFIED 467 connector EXECUTE registry is `optimize` / `expire_snapshots` / `remove_orphan_files` / `drop_extended_stats` only; NO `rewrite_position_delete_files`. (4) Orphan files via Spark `remove_orphan_files`. `$snapshots` / `$files` metadata-table column references (content=0 data, content=1 position-delete) accurate. |
| Beginner clarity | 5 | Each step has a "look-at" query + "fix" SQL. Clear thresholds. |
| Practical applicability | 5 | Engineer can paste each diagnostic query and each remediation SQL. |
| Completeness | 4 | Slight shave: the question explicitly asks about "small files vs too many partitions" — the **too-many-partitions** angle (over-partitioning → manifest list growth → planning time + per-partition file-header overhead → query-cost as well as storage-cost) is not directly addressed; responder treats cost = storage only. Also missed that Trino 467 ALSO has native `EXECUTE remove_orphan_files` (since release 411) — recommending Spark for step 4 is not wrong but misses the Trino-native form. |
| **Q2 average** | **4.75** | |

### Q3 — Oracle ROWNUM pagination → correct Trino 467 equivalent + gotchas

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | Oracle ROWNUM-is-assigned-BEFORE-ORDER-BY gotcha correct (classic Oracle 11g top-N footgun requiring subquery wrap or 12c+ FETCH FIRST). Trino `ORDER BY ... LIMIT N` applies after ORDER BY at the logical layer — correct. Pagination `ORDER BY ... OFFSET 50 LIMIT 50` with explicit "DO NOT write `LIMIT 50 OFFSET 50` — Trino requires OFFSET first" — VERIFIED against [Trino OFFSET Before LIMIT] pin (Trino 467 grammar order is ORDER BY → OFFSET → LIMIT/FETCH; the Postgres/MySQL `LIMIT n OFFSET m` order is a PARSE error in 467). Keyset pagination as deep-page alternative is sound advice. |
| Beginner clarity | 5 | Clean ROWNUM vs LIMIT contrast; explicit DO-NOT-WRITE band; keyset pattern shown. |
| Practical applicability | 5 | Engineer knows the rewrite, the syntactic trap, and when to escalate to keyset. |
| Completeness | 5 | Migration semantics + pagination + deep-page tradeoff — all three angles addressed. |
| **Q3 average** | **5.00** | |

### Q4 — dashboard query 3s → 4-5min, SQL unchanged — diagnose in what order?

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 3 | 6-check ordered triage. Checks 1, 2, 4, 5, 6 (concurrency via Trino UI queued/running, COUNT(*) bare-table test, single-fragment via EXPLAIN ANALYZE, partition skew, small files/manifest bloat with `splitsCreated`) all sound. `optimize_manifests` is 470+ not 467 — VERIFIED. **Check 3 is FALSE.** Responder claimed `WHERE date(occurred_at) = DATE 'x'` BREAKS Iceberg partition pruning and the fix is to rewrite to `occurred_at >= TIMESTAMP 'x 00:00' AND occurred_at < TIMESTAMP 'x+1 00:00'`. **Verify-first refutation:** Trino 467's `UnwrapCastInComparison.java` (default-on, no session flag) rewrites `CAST(timestamp AS DATE) = DATE 'x'` — which is what `date(timestamp_col)` is, since `date()` is the documented alias of `CAST(x AS DATE)` per r23 L1163 — into the EXACT range predicate the responder proposed as the "manual fix"; that rewritten range pushes for Iceberg partition pruning via the `day(occurred_at)` transform. Companion rules `UnwrapDateTruncInComparison` + `UnwrapYearInComparison` similarly unwrap `date_trunc('day',col)=DATE 'x'` and `year(col)=2026`. Matches the [Trino Unwraps Temporal Predicates] pin (iter871 verify-first correction). The "BI tool started wrapping in date()" worked-example punchline is therefore a non-bug — pruning would NOT break in 467. |
| Beginner clarity | 5 | Steps are crisply ordered, EXPLAIN syntax explicit, expected outputs named. |
| Practical applicability | 3 | Checks 1/2/4/5/6 are actionable. Check 3 would send the engineer to rewrite their dashboard SQL chasing a non-bug — they would "fix" the date() wrap and observe no change in plan, because the optimizer was already doing the rewrite. The EXPLAIN procedure itself is fine; the diagnostic INTERPRETATION is wrong. |
| Completeness | 4 | 6 checks span all reasonable root causes. Loses 1 for not teaching the optimizer Unwrap rules in passing. |
| **Q4 average** | **3.75** | |

---

## Score table

| Q | Accuracy | Clarity | Applicability | Completeness | Avg |
|---|---|---|---|---|---|
| Q1 dbt model contracts | 5 | 5 | 5 | 5 | 5.00 |
| Q2 cost-considerations | 5 | 5 | 5 | 4 | 4.75 |
| Q3 Oracle ROWNUM | 5 | 5 | 5 | 5 | 5.00 |
| Q4 query-perf regression | 3 | 5 | 3 | 4 | 3.75 |
| **Iter overall** | | | | | **4.625** |

**PASS** (overall avg 4.625 >> 3.5 threshold; overall avg governs, no per-question veto).

---

## Source-verified defects

### Q4 — RESOURCE-SOURCED FALSE PRUNING FOLKLORE (r18) — needs FIX-A

**The wrong claim (responder, verbatim worked example):**
> "EXPLAIN (TYPE DISTRIBUTED) shows TableScan with `inputRows = 1.4B` and a `Filter` node above it carrying `date(occurred_at) = DATE '2026-05-22'`. **Pruning broke.** The dashboard's BI tool got upgraded last weekend and now wraps the date predicate in `date(...)`. Fix: edit the dashboard SQL to remove the `date()` wrap and use the raw range comparison."

**Why it's wrong (verify-first):**
Trino 467 `UnwrapCastInComparison.java` rewrites `CAST(timestamp AS DATE) = DATE 'x'` (equivalently `date(timestamp_col) = DATE 'x'`, since `date()` is the alias of `CAST(x AS DATE)` per r23 L1163) into `ts >= TIMESTAMP 'x 00:00' AND ts < TIMESTAMP 'x+1 00:00'`. That rewritten range pushes for Iceberg partition pruning via the `day(occurred_at)` partition transform. Companion rules `UnwrapDateTruncInComparison` + `UnwrapYearInComparison` similarly unwrap `date_trunc('day',col)=DATE 'x'` and `year(col)=2026`. All three rules are unconditionally registered in `PlanOptimizers.java` `simplifyOptimizerRules` — there is no session flag. The Trino team blog ["Just the right time date predicates with Iceberg"](https://trino.io/blog/2023/04/11/date-predicates.html) explicitly documents this. Pin: **[Trino Unwraps Temporal Predicates]** (iter871 verify-first correction of an earlier directive).

**WebFetch confirmation (UnwrapCastInComparison.java at trinodb/trino@467):**
> "if (sourceType instanceof TimestampType && targetType == DATE) { return unwrapTimestampToDateCast..."
> "and(new Comparison(GREATER_THAN_OR_EQUAL, timestampExpression, dateTimestamp), new Comparison(LESS_THAN, timestampExpression, nextDateTimestamp))"

The rule explicitly produces the timestamp-bounded range the responder claims must be hand-written.

**Resource provenance — RESOURCE-SOURCED, not responder one-off:**

The responder is FAITHFULLY citing r18. The wrong claim lives at:
- `resources/18-query-performance-regression.md` **L84** (Check 3 table row, "function-wrapped predicate that the optimizer cannot push to partition layout — Fix by rewriting to a raw range comparison")
- `resources/18-query-performance-regression.md` **L113-115** (the leading worked example, "Pruning broke. The dashboard's BI tool got upgraded last weekend and now wraps the date predicate in `date(...)` ... Fix: edit the dashboard SQL to remove the `date()` wrap")

**Truth source already in the repo (internal contradiction):**

`resources/07-analytical-query-patterns.md` **L63-74** already codifies the CORRECT framing:
> "Trino 467 reality — the common wrapped temporal comparisons DO still prune (they are NOT footguns here): Unlike Postgres/Oracle, Trino 467 ships default-on optimizer rules that automatically unwrap the common date/timestamp comparisons into a bare-column range before pushdown, so they still trigger Iceberg partition pruning + Parquet min/max file skipping ... ALL of these unwrap to a bare-column range in Trino 467 and DO prune: WHERE CAST(order_date AS date) = DATE '...', WHERE date_trunc('day', order_ts) = DATE '...', WHERE year(order_date) = 2026, WHERE EXTRACT(YEAR FROM order_date) = 2026 ... The genuine pruning-killer: an opaque, non-invertible expression on the partition/sort column that the optimizer CANNOT rewrite into a bare-column range — a UDF, regexp_*, JSON extraction, LOWER(col)/SUBSTR(col, ...), or non-monotonic arithmetic."

So r07 §1 contradicts r18 Check 3 / worked example. The responder picked the topic-matching r18 (query-perf-regression-diagnosis) and got the wrong claim. **This is the 3rd appearance of the function-wrap-breaks-pruning false imported sargability prior** (iter870 directive → iter871 verify-first correction → r18 still carries the stale wrong claim that the iter871 fix never reached).

### Q2 — sanity-check pass

- `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '7d')` — VERIFIED syntax against trino.io/docs/467/connector/iceberg.html.
- `EXECUTE optimize(file_size_threshold => '128MB')` — VERIFIED 467 `optimize` accepts ONLY `file_size_threshold` parameter.
- "Trino 467 cannot rewrite position deletes" — VERIFIED 467 EXECUTE registry is exactly `optimize` / `expire_snapshots` / `remove_orphan_files` / `drop_extended_stats`; no `rewrite_position_delete_files`; Spark `CALL ... rewrite_position_delete_files` is the correct fallback.
- Minor: Trino 467 ALSO has native `ALTER TABLE ... EXECUTE remove_orphan_files` (since release 411). Recommending Spark for step 4 is not wrong, but misses the Trino-native form. Not penalized further — Q2 still 4.75.

---

## Teacher guidance — FIX-A on r18

**Priority: HIGH** (false claim is the leading worked example's punchline; engineer would chase a non-bug rewrite).

1. **r18 Check 3 table (~L84)** — rewrite the "function-wrapped predicate" row to match r07 §1 truth. Replace with something like:

   > | `TableScan` has NO partition predicate inside the connector + a `Filter` node ABOVE the TableScan carrying an OPAQUE function on the partition column (LOWER, SUBSTR, regexp_*, json_extract_scalar, a UDF, or non-monotonic arithmetic) | **Pruning broke.** Trino 467's optimizer unwraps `CAST(ts AS DATE)=DATE 'x'`, `date(ts)=DATE 'x'`, `date_trunc('day', ts)=DATE 'x'`, `year(ts)=2026`, and `EXTRACT(YEAR FROM ts)=2026` into a bare-column range that DOES prune (see r07 §1) — these are NOT the breakage. The genuine pruning-killer is an **opaque, non-invertible** function the optimizer cannot invert: LOWER on a partition-string column, JSON extraction, a UDF, or non-monotonic arithmetic. Fix: pre-compute the value at ingest as a separate partition-aligned column, OR rewrite the predicate to a form Trino can invert (raw column = literal, or `BETWEEN start AND end`). |

2. **r18 worked example (~L113-115)** — rewrite the BI-tool punchline to a TRULY pruning-breaking root cause. Suggested replacement:

   > **Check 3:** `EXPLAIN (TYPE DISTRIBUTED)` shows TableScan with `inputRows = 1.4B` and a `Filter` node above it carrying `LOWER(tenant_id) = 'acme'` (the partition column is `tenant_id`, a partition-aligned VARCHAR). **Pruning broke.** The dashboard's BI tool got "case-insensitive tenant matching" turned on and now wraps the partition column in `LOWER(...)` — which is opaque to the optimizer (no Unwrap rule covers `LOWER`). Old shape: `tenant_id = 'acme'`. **Fix:** turn off the BI-tool case-insensitive option, OR normalize the partition column to lowercase at ingest so `tenant_id = 'acme'` is a direct match. Re-run: query back to 2s. **Total triage time: ~60 seconds.**

3. **r28 L11 (secondary)** — "function-wrapped partition-column predicates that defeat partition pruning" → tighten to "**opaque** function-wrapped partition-column predicates (LOWER, regexp_*, JSON extract, UDF, non-monotonic arithmetic) that defeat partition pruning". The date()/CAST AS DATE / year() / date_trunc forms DO unwrap.

4. **r18 L940 (tertiary)** — "WHERE DATE(event_time) = CURRENT_DATE may not prune as well as WHERE event_date = CURRENT_DATE depending on how the column is typed" → either delete (hedged folklore that contradicts r07 §1) or replace with "DATE(event_time) = CURRENT_DATE DOES unwrap and prune in 467 via UnwrapCastInComparison; only an opaque-function wrap (LOWER/SUBSTR/JSON-extract/UDF) on the partition column actually breaks pruning."

5. **Add cross-ref from r18 to r07 §1** as the authoritative truth source for the Unwrap rules.

6. **Re-probe Q4 next sweep from a 2nd angle** — concurrency-spike or skew or manifest-bloat root cause, NOT date()-wrap. Confirm the FIX-A reaches the responder AND that checks 1, 2, 4, 5, 6 still work (don't damage the otherwise-sound 6-step triage).

**Do NOT** append a new section to r18 contradicting the old (per [Reconcile Don't Append] pin); EDIT the existing L84 + L113-115 in place. Otherwise responder may cite the wrong one.

---

## Topic rubric updates (this iter)

| Topic | Prior avg / N | New avg / N | Delta |
|---|---|---|---|
| dbt model contracts | 4.0859 / 4 | **4.2687 / 5** | +0.183 |
| Cost considerations | 4.1846 / 19 | **4.2129 / 20** | +0.028 |
| Oracle PL/SQL → dbt+Trino migration | 4.4309 / 100 | **4.4365 / 101** | +0.006 |
| Query perf regression diagnosis | 4.3510 / 17 | **4.3176 / 18** | -0.033 |

All four topics REMAIN PASSED. Q4 drops slightly from durability hit but stays >3.5.

---

## Pin-relevant observations

- **[Trino Unwraps Temporal Predicates]** — 3rd appearance of the false imported sargability prior. iter870 directive asserted the prior; iter871 verify-first corrected it. r18 still carries the stale wrong claim — this iter is the resource-level reconciliation (analogous to iter948 HAVING-trims-memory folklore root-cause traced to r07 L37).
- **[Trace Recurring Folklore to Resource Root Cause]** — followed. Recurring folklore (function-wrap-breaks-pruning) traced from responder slip → r18 L84 + L113-115 root cause → FIX-A on r18 + r28 L11 + r18 L940.
- **[Reconcile Don't Append]** — FIX-A on r18 must REWRITE Check 3 table row L84 + worked example L113-115 (not append a contradictory new section); otherwise responder will cite the wrong one.
- **[Trino OFFSET Before LIMIT]** — Q3 cleanly cites it.
- **[Trino No ILIKE]** — N/A this iter (no federation).

---

## Recommendation

**FIX-A on r18** (Check 3 table L84 + worked example L113-115) + secondary cleanup on r28 L11 + r18 L940. Re-probe Q4 next sweep with a 2nd angle (concurrency / skew / manifest-bloat root cause, NOT date()-wrap) to confirm FIX-A reaches and doesn't damage the other 5 checks.

NO state.json bump (already 1098, already passed:true). NO federation re-probe (4.50244/312 fragile-PASS per iter1097). NO commit beyond rubric + feedback + r18/r28 FIX-A.
